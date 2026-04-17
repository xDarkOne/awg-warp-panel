#!/bin/bash

# --- Цвета оформления ---
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

# Список гарантированно рабочих Anycast-адресов Cloudflare
get_shuffled_endpoints() {
    local ips=("162.159.192.1" "162.159.193.1" "162.159.195.1" "188.114.96.1" "188.114.97.1" "188.114.98.1" "188.114.99.1")
    local ports=("2408" "500" "1701" "4500")
    local combined=()
    for ip in "${ips[@]}"; do
        for port in "${ports[@]}"; do
            combined+=("$ip:$port")
        done
    done
    printf "%s\n" "${combined[@]}" | shuf
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
    echo -e "${CYAN}[*] Сканирование портов и интерфейсов VPN...${NC}"
    SERVER_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me || ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n')
    WG_IFACE=$(ip link show | grep -E 'amn[0-9]+|wg[0-9]+|awg[0-9]+' | grep -v 'warp' | awk -F': ' '{print $2}' | tr -d ' ' | head -n 1)
    WG_IFACE=${WG_IFACE:-amn0}

    EXCLUDE_PORTS_UDP=""
    EXCLUDE_PORTS_TCP=""
    if command -v docker &> /dev/null; then
        EXCLUDE_PORTS_UDP=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' | grep '/udp' | grep -oP '0.0.0.0:\K\d+' | sort -u)
        EXCLUDE_PORTS_TCP=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' | grep '/tcp' | grep -oP '0.0.0.0:\K\d+' | sort -u)
    fi
    if [ -z "$EXCLUDE_PORTS_UDP" ] && command -v wg &> /dev/null; then
        EXCLUDE_PORTS_UDP=$(wg show $WG_IFACE listen-port 2>/dev/null || echo "36532")
    fi
}

# ==========================================
# МОДУЛЬ МАРШРУТИЗАЦИИ
# ==========================================

generate_config() {
    local private_key=$1
    local server_ip=$2
    local iface=$3
    local endpoint=$4

    cat << EOF > /etc/wireguard/warp.conf
[Interface]
PrivateKey = $private_key
Address = 172.16.0.2/32
MTU = 1280
Table = 123

PostUp = ip rule add from 172.16.0.2 table 123 priority 95
PostDown = ip rule del from 172.16.0.2 table 123 priority 95
PostUp = ip rule add to $server_ip table main priority 91
PostDown = ip rule del to $server_ip table main priority 91
PostUp = ip rule add to 172.16.0.0/12 table main priority 90
PostDown = ip rule del to 172.16.0.0/12 table main priority 90
EOF

    local rule_idx=1
    for port in $EXCLUDE_PORTS_UDP; do
        echo "PostUp = iptables -t mangle -I PREROUTING $rule_idx -i $iface -p udp --sport $port -j ACCEPT" >> /etc/wireguard/warp.conf
        echo "PostDown = iptables -t mangle -D PREROUTING -i $iface -p udp --sport $port -j ACCEPT" >> /etc/wireguard/warp.conf
        ((rule_idx++))
    done
    for port in $EXCLUDE_PORTS_TCP; do
        echo "PostUp = iptables -t mangle -I PREROUTING $rule_idx -i $iface -p tcp --sport $port -j ACCEPT" >> /etc/wireguard/warp.conf
        echo "PostDown = iptables -t mangle -D PREROUTING -i $iface -p tcp --sport $port -j ACCEPT" >> /etc/wireguard/warp.conf
        ((rule_idx++))
    done

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

    echo -e "${YELLOW}--- CLOUDFLARE AUTO-RENEW ---${NC}"
    read -p "Ключ WARP+ (Enter для Free): " warp_key
    
    cd /root
    rm -f wgcf-account.toml wgcf-profile.conf
    ./wgcf register --accept-tos >> $LOG_FILE 2>&1
    [[ -n "$warp_key" ]] && ./wgcf update --license "$warp_key" >> $LOG_FILE 2>&1
    ./wgcf generate >> $LOG_FILE 2>&1
    
    local private_key=$(awk '/PrivateKey/ {print $3}' wgcf-profile.conf 2>/dev/null)
    [[ -z "$private_key" ]] && { echo -e "${RED}❌ Ошибка ключей.${NC}"; exit 1; }

    local endpoints=($(get_shuffled_endpoints))
    local success=false

    echo -e "${CYAN}[*] Поиск рабочего шлюза (перебор ${#endpoints[@]} вариантов)...${NC}"

    for endpoint in "${endpoints[@]}"; do
        echo -ne "${BLUE}[>] Проверка: $endpoint... ${NC}"
        generate_config "$private_key" "$SERVER_IP" "$WG_IFACE" "$endpoint"
        
        wg-quick down warp 2>/dev/null
        ip rule del priority 90 2>/dev/null
        ip rule del priority 91 2>/dev/null
        ip rule del priority 95 2>/dev/null
        ip rule del priority 100 2>/dev/null
        
        wg-quick up warp >> $LOG_FILE 2>&1
        
        NEW_IP=$(curl -4 -s --interface warp --connect-timeout 4 ifconfig.me)
        
        if [[ -n "$NEW_IP" ]]; then
            echo -e "${GREEN}OK! IP: $NEW_IP${NC}"
            success=true
            break
        else
            echo -e "${RED}нет ответа${NC}"
        fi
    done

    [[ "$success" = "false" ]] && echo -e "${RED}❌ Все шлюзы недоступны.${NC}"
}

# ==========================================
# МОДУЛЬ 2: ВЕБ-СЕРВЕР И SSL
# ==========================================

get_domain() {
    if [ -f /root/.xdark_domain ]; then DOMAIN=$(cat /root/.xdark_domain); else
        read -p "Введите домен: " DOMAIN
        echo "$DOMAIN" > /root/.xdark_domain
    fi
    WEB_DIR="/var/www/$DOMAIN"
}

setup_nginx() {
    get_domain
    install_packages nginx unzip wget curl
    mkdir -p $WEB_DIR
    cat << EOF > /etc/nginx/sites-available/$DOMAIN
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    root $WEB_DIR;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    systemctl restart nginx
    echo -e "${GREEN}✅ Nginx настроен.${NC}"
}

setup_ssl() {
    get_domain
    install_packages certbot python3-certbot-nginx
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" --redirect
    echo -e "${GREEN}✅ SSL готов.${NC}"
}

web_menu() {
    while true; do
        echo -e "\n${YELLOW}=== УПРАВЛЕНИЕ ВЕБ-САЙТОМ ===${NC}"
        echo "1. 🛠️ Установить Nginx"
        echo "2. 🔒 SSL Сертификат"
        echo "3. 🎨 Заглушка (Спиннер)"
        echo "0. 🔙 Назад"
        read -p "Выбор: " wc
        case $wc in
            1) setup_nginx ;;
            2) setup_ssl ;;
            3)
                cat << 'EOF' > $WEB_DIR/index.html
<!DOCTYPE html><html><head><meta charset="UTF-8"><style>body{background:#0d1117;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;}.spin{width:40px;height:40px;border:4px solid #30363d;border-top:4px solid #8a2be2;border-radius:50%;animation:s 1s linear infinite;}@keyframes s{100%{transform:rotate(360deg);}}</style></head><body><div class="spin"></div></body></html>
EOF
                echo -e "${GREEN}Заглушка создана.${NC}" ;;
            0) break ;;
        esac
    done
}

# ==========================================
# ГЛАВНОЕ МЕНЮ
# ==========================================

while true; do
    echo -e "\n${BLUE}=======================================${NC}"
    echo -e "${GREEN}   AWG 2.0 Mega Panel v7.5 (Ultimate) ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo "1. 🚀 Установить / Обновить (Auto-Bruteforce)"
    echo "2. 📅 Авто-обновление по воскресеньям"
    echo "3. 📊 Статус туннеля и IP"
    echo "4. 🌍 Управление сайтом"
    echo "5. 🗑️ Удалить WARP"
    echo "6. 📜 Логи"
    echo "0. ❌ Выход"
    read -p "Выберите пункт: " choice

    case $choice in
        1) do_renew ;;
        2) (crontab -l 2>/dev/null | grep -v "xdark_warp.sh"; echo "0 5 * * 0 /root/xdark.sh --auto-renew") | crontab -
           echo -e "${GREEN}Расписание настроено.${NC}" ;;
        3) 
            echo -e "WARP: $(ip link show warp >/dev/null 2>&1 && echo -e "${GREEN}UP${NC}" || echo -e "${RED}DOWN${NC}")"
            if ip link show warp >/dev/null 2>&1; then
                echo -e "IP: ${YELLOW}$(curl -4 -s --interface warp --connect-timeout 5 ifconfig.me)${NC}"
                echo -e "Endpoint: ${CYAN}$(grep 'Endpoint' /etc/wireguard/warp.conf | awk '{print $3}')${NC}"
                wg show warp transfer
            fi ;;
        4) web_menu ;;
        5) wg-quick down warp 2>/dev/null; systemctl disable wg-quick@warp; rm -f /etc/wireguard/warp.conf; echo -e "${YELLOW}Удалено.${NC}" ;;
        6) tail -n 50 $LOG_FILE ;;
        0) exit 0 ;;
    esac
done
