#!/bin/bash

# --- Цвета для оформления ---
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

install_packages() {
    local to_install=""
    for pkg in "$@"; do
        if ! dpkg -l | grep -q -w "^ii  $pkg "; then
            to_install="$to_install $pkg"
        fi
    done
    if [ -n "$to_install" ]; then
        apt-get update >> $LOG_FILE 2>&1
        apt-get install -y $to_install >> $LOG_FILE 2>&1
    fi
}

detect_params() {
    SERVER_IP=$(curl -s -4 ifconfig.me || ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n')
    WG_IFACE=$(ip link show | grep -E 'amn[0-9]+|wg[0-9]+|awg[0-9]+' | grep -v 'warp' | awk -F': ' '{print $2}' | tr -d ' ' | head -n 1)
    WG_IFACE=${WG_IFACE:-amn0}
}

get_random_endpoint() {
    # Список проверенных подсетей Cloudflare
    local subnets=("162.159.192" "162.159.193" "162.159.195" "188.114.96" "188.114.97")
    # Список поддерживаемых портов
    local ports=("2408" "500" "1701" "4500")

    # Выбираем случайную подсеть
    local rand_subnet=${subnets[$RANDOM % ${#subnets[@]}]}
    # Генерируем случайный последний октет (от 1 до 254)
    local rand_host=$((1 + RANDOM % 254))
    # Выбираем случайный порт
    local rand_port=${ports[$RANDOM % ${#ports[@]}]}

    # Собираем всё вместе
    echo "${rand_subnet}.${rand_host}:${rand_port}"
}

generate_config() {
    local private_key=$1
    local server_ip=$2
    local iface=$3
    
    # Генерируем случайный эндпоинт ПЕРЕД созданием файла
    local endpoint=$(get_random_endpoint)

    cat << EOF > /etc/wireguard/warp.conf
[Interface]
PrivateKey = $private_key
Address = 172.16.0.2/32
MTU = 1280
Table = 123

PostUp = ip rule add to 172.16.0.0/12 table main priority 90
PostDown = ip rule del to 172.16.0.0/12 table main priority 90
PostUp = ip rule add to $server_ip table main priority 91
PostDown = ip rule del to $server_ip table main priority 91
EOF

    local rule_num=1

    # Исправленный, железобетонный парсер портов
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

    # Завершаем конфигурацию
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
        wget -q -O /root/wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
        chmod +x /root/wgcf
    fi

    cd /root
    rm -f wgcf-account.toml wgcf-profile.conf
    
    ./wgcf register --accept-tos >> $LOG_FILE 2>&1
    ./wgcf generate >> $LOG_FILE 2>&1
    
    NEW_KEY=$(awk '/PrivateKey/ {print $3}' wgcf-profile.conf 2>/dev/null)
    
    if [ -z "$NEW_KEY" ]; then
        echo -e "${RED}Ошибка: Не удалось получить ключ от Cloudflare.${NC}"
        exit 1
    fi
    
    generate_config "$NEW_KEY" "$SERVER_IP" "$WG_IFACE"
    
    # Автоматическая очистка мусора перед запуском (страховка)
    ip rule del to 172.16.0.0/12 table main priority 90 2>/dev/null
    ip rule del to $SERVER_IP table main priority 91 2>/dev/null
    ip rule del fwmark 0x123 table 123 priority 100 2>/dev/null
    
    systemctl enable wg-quick@warp >> $LOG_FILE 2>&1
    systemctl restart wg-quick@warp >> $LOG_FILE 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Туннель WARP запущен. Новый IP: $(curl -s --interface warp ifconfig.me)${NC}"
    else
        echo -e "${RED}❌ Ошибка при запуске туннеля WARP.${NC}"
    fi
}

if [[ "$1" == "--auto-renew" ]]; then
    do_renew
    exit 0
fi

# ==========================================
# МОДУЛЬ 2: ВЕБ-СЕРВЕР И SSL
# ==========================================
# (Здесь остаются функции get_domain, setup_nginx, setup_ssl, web_menu, я пропустил их для экономии места, они без изменений)
# ==========================================

while true; do
    echo -e "\n${BLUE}=======================================${NC}"
    echo -e "${GREEN}   AWG 2.0 Mega Panel v6   ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${YELLOW}--- СЕТЬ И МАРШРУТИЗАЦИЯ ---${NC}"
    echo "1. 🚀 Установить WARP / Обновить ключи"
    echo "2. 📅 Настроить авто-обновление WARP (каждое ВС)"
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
            echo -e "WARP: $(ip link show warp >/dev/null 2>&1 && echo -e "${GREEN}РАБОТАЕТ${NC}" || echo -e "${RED}ВЫКЛЮЧЕН${NC}")"
            echo -e "IP: ${YELLOW}$(curl -s --interface warp ifconfig.me)${NC}"
            wg show warp transfer 2>/dev/null
            ;;
        4) web_menu ;; # не забудь вставить
        5) 
            systemctl disable wg-quick@warp >/dev/null 2>&1
            wg-quick down warp >/dev/null 2>&1
            rm -f /etc/wireguard/warp.conf /root/wgcf*
            echo -e "${YELLOW}WARP полностью удален.${NC}"
            ;;
        6) tail -n 50 $LOG_FILE ;;
        0) exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}" ;;
    esac
done
