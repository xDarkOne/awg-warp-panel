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
  echo -e "${RED}Ошибка: Запустите скрипт от имени root (sudo -i).${NC}"
  exit 1
fi

echo "=== Запуск скрипта: $(date) ===" >> $LOG_FILE

# ==========================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==========================================

# Генерация случайного входа Cloudflare для уникальности IP
get_random_endpoint() {
    # Только гарантированно рабочие шлюзы Cloudflare
    local gateways=("162.159.192.1" "162.159.193.1" "162.159.195.1" "188.114.96.1" "188.114.97.1")
    # Рабочие порты
    local ports=("2408" "500" "1701" "4500")

    local rand_gw=${gateways[$RANDOM % ${#gateways[@]}]}
    local rand_port=${ports[$RANDOM % ${#ports[@]}]}

    echo "${rand_gw}:${rand_port}"
}
install_packages() {
    local to_install=""
    for pkg in "$@"; do
        if ! dpkg -l | grep -q -w "^ii  $pkg "; then to_install="$to_install $pkg"; fi
    done
    if [ -n "$to_install" ]; then
        echo -e "${CYAN}[*] Установка пакетов:$to_install...${NC}"
        apt-get update >> $LOG_FILE 2>&1
        apt-get install -y $to_install >> $LOG_FILE 2>&1
    fi
}

detect_params() {
    echo -e "${CYAN}[*] Сканирование системы и поиск VPN портов...${NC}"
    SERVER_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me || ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n')
    # Ищем интерфейс Amnezia (amn0, awg0 или wg0)
    WG_IFACE=$(ip link show | grep -E 'amn[0-9]+|wg[0-9]+|awg[0-9]+' | grep -v 'warp' | awk -F': ' '{print $2}' | tr -d ' ' | head -n 1)
    WG_IFACE=${WG_IFACE:-amn0}

    # Собираем список всех UDP и TCP портов Amnezia из Docker для исключений
    EXCLUDE_PORTS_UDP=""
    EXCLUDE_PORTS_TCP=""
    if command -v docker &> /dev/null; then
        EXCLUDE_PORTS_UDP=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' | grep '/udp' | grep -oP '0.0.0.0:\K\d+' | sort -u)
        EXCLUDE_PORTS_TCP=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' | grep '/tcp' | grep -oP '0.0.0.0:\K\d+' | sort -u)
    fi
    # Если Docker пуст, берем стандартный порт из wg show
    if [ -z "$EXCLUDE_PORTS_UDP" ] && command -v wg &> /dev/null; then
        EXCLUDE_PORTS_UDP=$(wg show $WG_IFACE listen-port 2>/dev/null || echo "36532")
    fi
}

# ==========================================
# ЯДРО: ГЕНЕРАЦИЯ КОНФИГА И МАРШРУТИЗАЦИЯ
# ==========================================

generate_config() {
    local private_key=$1
    local server_ip=$2
    local iface=$3
    local endpoint=$(get_random_endpoint)

    cat << EOF > /etc/wireguard/warp.conf
[Interface]
PrivateKey = $private_key
Address = 172.16.0.2/32
MTU = 1280
Table = 123

# Правило, чтобы сервер сам видел свой IP
PostUp = ip rule add from 172.16.0.2 table 123 priority 95
PostDown = ip rule del from 172.16.0.2 table 123 priority 95

# Защита SSH и локальной сети
PostUp = ip rule add to $server_ip table main priority 91
PostDown = ip rule del to $server_ip table main priority 91
PostUp = ip rule add to 172.16.0.0/12 table main priority 90
PostDown = ip rule del to 172.16.0.0/12 table main priority 90
EOF

    local rule_idx=1
    # Добавляем исключения для всех найденных UDP портов (чтобы Amnezia не теряла связь)
    for port in $EXCLUDE_PORTS_UDP; do
        echo "PostUp = iptables -t mangle -I PREROUTING $rule_idx -i $iface -p udp --sport $port -j ACCEPT" >> /etc/wireguard/warp.conf
        echo "PostDown = iptables -t mangle -D PREROUTING -i $iface -p udp --sport $port -j ACCEPT" >> /etc/wireguard/warp.conf
        ((rule_idx++))
    done
    # Добавляем исключения для TCP (Xray/Shadowsocks)
    for port in $EXCLUDE_PORTS_TCP; do
        echo "PostUp = iptables -t mangle -I PREROUTING $rule_idx -i $iface -p tcp --sport $port -j ACCEPT" >> /etc/wireguard/warp.conf
        echo "PostDown = iptables -t mangle -D PREROUTING -i $iface -p tcp --sport $port -j ACCEPT" >> /etc/wireguard/warp.conf
        ((rule_idx++))
    done

    # Финальная маркировка и NAT
    cat << EOF >> /etc/wireguard/warp.conf
PostUp = iptables -t mangle -I PREROUTING $rule_idx -i $iface -j MARK --set-mark 0x123
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

    echo -e "${YELLOW}--- CLOUDFLARE SETUP ---${NC}"
    read -p "Ключ WARP+ (Enter для Free): " warp_key

    cd /root
    rm -f wgcf-account.toml wgcf-profile.conf
    echo -e "${CYAN}[*] Регистрация устройства...${NC}"
    ./wgcf register --accept-tos >> $LOG_FILE 2>&1

    if [ -n "$warp_key" ]; then
        ./wgcf update --license "$warp_key" >> $LOG_FILE 2>&1
    fi

    ./wgcf generate >> $LOG_FILE 2>&1
    NEW_KEY=$(awk '/PrivateKey/ {print $3}' wgcf-profile.conf 2>/dev/null)

    if [ -z "$NEW_KEY" ]; then
        echo -e "${RED}❌ Ошибка получения ключей.${NC}"
        exit 1
    fi

    generate_config "$NEW_KEY" "$SERVER_IP" "$WG_IFACE"

    echo -e "${CYAN}[*] Перезапуск туннеля...${NC}"
    # Тщательная очистка перед стартом
    wg-quick down warp 2>/dev/null
    ip rule del priority 90 2>/dev/null
    ip rule del priority 91 2>/dev/null
    ip rule del priority 95 2>/dev/null
    ip rule del priority 100 2>/dev/null

    systemctl enable wg-quick@warp >> $LOG_FILE 2>&1
    systemctl restart wg-quick@warp >> $LOG_FILE 2>&1

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Успех! Проверка IP (ждем 5 сек)...${NC}"
        NEW_IP=$(curl -4 -s --interface warp --connect-timeout 5 ifconfig.me)
        echo -e "${GREEN}Новый IP: ${YELLOW}${NEW_IP:-"Определяется..."}${NC}"
    else
        echo -e "${RED}❌ Ошибка запуска. Проверь логи (пункт 6).${NC}"
    fi
}

# ... (web_menu и остальные функции) ...

while true; do
    echo -e "\n${BLUE}=======================================${NC}"
    echo -e "${GREEN}   AWG 2.0 Mega Panel v7.0 (Ultimate) ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${YELLOW}--- СЕТЬ И МАРШРУТИЗАЦИЯ ---${NC}"
    echo "1. 🚀 Установить / Обновить (Авто-порты)"
    echo "2. 📅 Авто-обновление по расписанию"
    echo "3. 📊 Статус туннеля и IP"
    echo "4. 🌍 Управление сайтом"
    echo "5. 🗑️ Удалить WARP"
    echo "6. 📜 Посмотреть логи"
    echo "0. ❌ Выход"
    read -p "Выберите пункт: " choice

    case $choice in
        1) do_renew ;;
        2) (crontab -l 2>/dev/null | grep -v "xdark_warp.sh"; echo "0 5 * * 0 /root/xdark.sh --auto-renew") | crontab - ;;
        3)
            echo -e "WARP: $(ip link show warp >/dev/null 2>&1 && echo -e "${GREEN}UP${NC}" || echo -e "${RED}DOWN${NC}")"
            echo -e "IP: ${YELLOW}$(curl -4 -s --interface warp --connect-timeout 5 ifconfig.me)${NC}"
            echo -e "Endpoint: ${CYAN}$(grep 'Endpoint' /etc/wireguard/warp.conf | awk '{print $3}')${NC}"
            wg show warp transfer 2>/dev/null
            ;;
        4) web_menu ;;
        5) wg-quick down warp; systemctl disable wg-quick@warp; rm -f /etc/wireguard/warp.conf ;;
        6) tail -n 50 $LOG_FILE ;;
        0) exit 0 ;;
    esac
done
