#!/bin/bash

# --- Цвета ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

LOG_FILE="/var/log/xdark_warp.log"

# Проверка на права root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Ошибка: Запустите скрипт от имени root.${NC}"
  exit 1
fi

echo "=== Запуск скрипта: $(date) ===" >> $LOG_FILE

# --- Вспомогательные функции ---

get_random_endpoint() {
    local subnets=("162.159.192" "162.159.193" "162.159.195" "188.114.96" "188.114.97")
    local ports=("2408" "500" "1701" "4500")
    local rand_subnet=${subnets[$RANDOM % ${#subnets[@]}]}
    local rand_host=$((1 + RANDOM % 254))
    local rand_port=${ports[$RANDOM % ${#ports[@]}]}
    echo "${rand_subnet}.${rand_host}:${rand_port}"
}

install_packages() {
    local to_install=""
    for pkg in "$@"; do
        if ! dpkg -l | grep -q -w "^ii  $pkg "; then
            to_install="$to_install $pkg"
        fi
    done
    if [ -n "$to_install" ]; then
        echo -e "${CYAN}[*] Установка системных пакетов:$to_install...${NC}"
        apt-get update >> $LOG_FILE 2>&1
        apt-get install -y $to_install
    fi
}

detect_params() {
    echo -e "${CYAN}[*] Определение сетевых параметров...${NC}"
    # Тайм-аут 5 секунд на определение внешнего IP
    SERVER_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me || ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n')
    WG_IFACE=$(ip link show | grep -E 'amn[0-9]+|wg[0-9]+|awg[0-9]+' | grep -v 'warp' | awk -F': ' '{print $2}' | tr -d ' ' | head -n 1)
    WG_IFACE=${WG_IFACE:-amn0}
}

generate_config() {
    local private_key=$1
    local server_ip=$2
    local iface=$3
    local endpoint=$(get_random_endpoint)

    echo -e "${CYAN}[*] Генерация конфигурации WireGuard (Endpoint: $endpoint)...${NC}"
    cat << EOF > /etc/wireguard/warp.conf
[Interface]
PrivateKey = $private_key
Address = 172.16.0.2/32
MTU = 1280
Table = 123

PostUp = ip rule add from 172.16.0.2 table 123 priority 95
PostDown = ip rule del from 172.16.0.2 table 123 priority 95
PostUp = ip rule add to 172.16.0.0/12 table main priority 90
PostDown = ip rule del to 172.16.0.0/12 table main priority 90
PostUp = ip rule add to $server_ip table main priority 91
PostDown = ip rule del to $server_ip table main priority 91
EOF

    local rule_num=1
    if command -v docker &> /dev/null; then
        local udp_ports=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' | grep '/udp' | grep -oP '0.0.0.0:\K\d+' | sort -u)
        for p in $udp_ports; do
            echo "PostUp = iptables -t mangle -I PREROUTING $rule_num -i $iface -p udp --sport $p -j ACCEPT" >> /etc/wireguard/warp.conf
            echo "PostDown = iptables -t mangle -D PREROUTING -i $iface -p udp --sport $p -j ACCEPT" >> /etc/wireguard/warp.conf
            ((rule_num++))
        done
        local tcp_ports=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' | grep '/tcp' | grep -oP '0.0.0.0:\K\d+' | sort -u)
        for p in $tcp_ports; do
            echo "PostUp = iptables -t mangle -I PREROUTING $rule_num -i $iface -p tcp --sport $p -j ACCEPT" >> /etc/wireguard/warp.conf
            echo "PostDown = iptables -t mangle -D PREROUTING -i $iface -p tcp --sport $p -j ACCEPT" >> /etc/wireguard/warp.conf
            ((rule_num++))
        done
    fi

    cat << EOF >> /etc/wireguard/warp.conf
PostUp = iptables -t mangle -I PREROUTING $rule_num -i $iface -j MARK --set-mark 0x123
PostDown = iptables -t mangle -D PREROUTING -i $iface -j MARK --set-mark 0x123
PostUp = ip rule add fwmark 0x123 table 123 priority 100
PostDown = ip rule del fwmark 0x123 table 123 priority 100
PostUp = iptables -t nat -I POSTROUTING 1 -o warp -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o warp -j MASQUERADE
PostUp = iptables -I FORWARD 1 -i $iface -o warp -j ACCEPT
PostUp = iptables -I FORWARD 1 -i warp -o $iface -j ACCEPT
PostDown = iptables -D FORWARD -i $iface -o warp -j ACCEPT
PostDown = iptables -D FORWARD -i warp -o $iface -j ACCEPT
PostUp = iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1060
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1060
PostUp = iptables -I FORWARD 1 -i $iface -p udp --dport 443 -j REJECT
PostDown = iptables -D FORWARD -i $iface -p udp --dport 443 -j REJECT

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
Endpoint = $endpoint
PersistentKeepalive = 25
EOF
}

do_renew() {
    install_packages wireguard-tools iptables curl wget
    detect_params

    if [ ! -f /root/wgcf ]; then
        echo -e "${CYAN}[*] Скачивание wgcf...${NC}"
        wget -q -O /root/wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
        chmod +x /root/wgcf
    fi

    echo -e "${YELLOW}--- НАСТРОЙКА CLOUDFLARE ---${NC}"
    read -p "У вас есть ключ WARP+? (Нажмите Enter для бесплатного): " warp_key

    cd /root
    rm -f wgcf-account.toml wgcf-profile.conf
    
    echo -e "${CYAN}[*] Регистрация в Cloudflare (может занять 5-10 сек)...${NC}"
    ./wgcf register --accept-tos
    
    if [ -n "$warp_key" ]; then
        echo -e "${CYAN}[*] Активация ключа $warp_key...${NC}"
        ./wgcf update --license "$warp_key"
    fi
    
    ./wgcf generate
    NEW_KEY=$(awk '/PrivateKey/ {print $3}' wgcf-profile.conf 2>/dev/null)
    
    if [ -z "$NEW_KEY" ]; then
        echo -e "${RED}❌ Ошибка: Не удалось получить ключи от wgcf.${NC}"
        exit 1
    fi
    
    generate_config "$NEW_KEY" "$SERVER_IP" "$WG_IFACE"
    
    echo -e "${CYAN}[*] Очистка старых правил маршрутизации...${NC}"
    ip rule del priority 90 2>/dev/null
    ip rule del priority 91 2>/dev/null
    ip rule del priority 95 2>/dev/null
    ip rule del priority 100 2>/dev/null
    wg-quick down warp 2>/dev/null
    
    echo -e "${CYAN}[*] Запуск интерфейса WARP...${NC}"
    wg-quick up warp
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Туннель поднят!${NC}"
        echo -ne "${CYAN}[*] Проверка нового IP (ждем до 10 сек)...${NC}"
        # Тайм-аут 10 секунд на получение IP через туннель
        NEW_IP=$(curl -4 -s --interface warp --connect-timeout 10 ifconfig.me)
        if [ -n "$NEW_IP" ]; then
            echo -e "\r${GREEN}✅ Новый IP: $NEW_IP${NC}"
        else
            echo -e "\r${RED}⚠️  Туннель поднят, но IP не определился (тайм-аут).${NC}"
            echo -e "${YELLOW}Проверьте интернет в Amnezia на телефоне.${NC}"
        fi
    else
        echo -e "${RED}❌ Ошибка запуска туннеля.${NC}"
    fi
}

# --- Остальные функции (web_menu и т.д.) оставить из v6.0 ---

while true; do
    echo -e "\n${BLUE}=======================================${NC}"
    echo -e "${GREEN}   AWG 2.0 Mega Panel v6.1 (Verbose)  ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${YELLOW}--- СЕТЬ И МАРШРУТИЗАЦИЯ ---${NC}"
    echo "1. 🚀 Установить / Обновить"
    echo "2. 📅 Настроить авто-обновление"
    echo "3. 📊 Статус туннеля и IP-адреса"
    echo -e "${YELLOW}--- СИСТЕМА И ОТЛАДКА ---${NC}"
    echo "4. 🌍 Управление сайтом"
    echo "5. 🗑️ Полное удаление WARP"
    echo "6. 📜 Посмотреть логи"
    echo "0. ❌ Выход"
    echo -e "${BLUE}=======================================${NC}"
    read -p "Выберите пункт: " choice

    case $choice in
        1) do_renew ;;
        2)
            (crontab -l 2>/dev/null | grep -v "xdark_warp.sh"; echo "0 5 * * 0 /root/xdark_warp.sh --auto-renew") | crontab -
            echo -e "${GREEN}✅ Авто-обновление настроено.${NC}"
            ;;
        3) 
            echo -ne "${CYAN}Проверка статуса...${NC}"
            IS_UP=$(ip link show warp >/dev/null 2>&1 && echo -e "${GREEN}РАБОТАЕТ${NC}" || echo -e "${RED}ВЫКЛЮЧЕН${NC}")
            echo -e "\rWARP: $IS_UP"
            if ip link show warp >/dev/null 2>&1; then
                IP=$(curl -4 -s --interface warp --connect-timeout 5 ifconfig.me || echo -e "${RED}тайм-аут${NC}")
                echo -e "IP: ${YELLOW}$IP${NC}"
                echo -e "Endpoint: ${BLUE}$(grep 'Endpoint' /etc/wireguard/warp.conf | awk '{print $3}')${NC}"
                wg show warp transfer
            fi
            ;;
        4) web_menu ;; 
        5) 
            wg-quick down warp 2>/dev/null
            systemctl disable wg-quick@warp 2>/dev/null
            rm -f /etc/wireguard/warp.conf
            echo -e "${YELLOW}Удалено.${NC}"
            ;;
        6) tail -n 50 $LOG_FILE ;;
        0) exit 0 ;;
        *) echo -e "${RED}Неверно.${NC}" ;;
    esac
done
