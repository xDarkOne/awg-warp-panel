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
# БЛОК 1: SMART BENCHMARK (ПОИСК ЛУЧШЕГО ШЛЮЗА)
# ==========================================

get_best_endpoints() {
    local ips=("162.159.192.1" "162.159.193.1" "162.159.195.1" "188.114.96.1" "188.114.97.1" "188.114.98.1" "188.114.99.1")
    local ports=("2408" "500" "1701" "4500")
    local results=()

    echo -e "${CYAN}[*] Запуск Benchmark (тестируем 28 комбинаций на задержку)...${NC}"
    
    for ip in "${ips[@]}"; do
        for port in "${ports[@]}"; do
            # Замеряем время отклика (пинг через UDP сокет bash)
            local start=$(date +%s%N)
            if timeout 0.4 bash -c "cat < /dev/null > /dev/udp/$ip/$port" 2>/dev/null; then
                local end=$(date +%s%N)
                local diff=$(( (end - start) / 1000000 ))
                results+=("$diff|$ip:$port")
                echo -e "${BLUE}[>] $ip:$port - ${diff}ms${NC}"
            fi
        done
    done

    # Сортируем: сверху самые быстрые
    if [ ${#results[@]} -eq 0 ]; then
        echo -e "${RED}❌ Не удалось найти ни одного живого шлюза. Проверьте интернет или firewall.${NC}"
        exit 1
    fi
    printf "%s\n" "${results[@]}" | sort -n | awk -F'|' '{print $2}'
}

# ==========================================
# БЛОК 2: СИСТЕМНЫЕ ПРОВЕРКИ И ПАРАМЕТРЫ
# ==========================================

install_packages() {
    local to_install=""
    for pkg in "$@"; do
        if ! dpkg -l | grep -q -w "^ii  $pkg "; then to_install="$to_install $pkg"; fi
    done
    if [ -n "$to_install" ]; then
        echo -e "${CYAN}[*] Установка необходимых пакетов:$to_install...${NC}"
        apt-get update >> $LOG_FILE 2>&1
        apt-get install -y $to_install >> $LOG_FILE 2>&1
    fi
}

detect_params() {
    echo -e "${CYAN}[*] Сбор данных о системе и Docker портах...${NC}"
    SERVER_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me || ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n')
    WG_IFACE=$(ip link show | grep -E 'amn[0-9]+|wg[0-9]+|awg[0-9]+' | grep -v 'warp' | awk -F': ' '{print $2}' | tr -d ' ' | head -n 1)
    WG_IFACE=${WG_IFACE:-amn0}

    # Автоматический поиск портов Amnezia (AWG, Xray, Shadowsocks)
    EXCLUDE_PORTS_UDP=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' 2>/dev/null | grep '/udp' | grep -oP '0.0.0.0:\K\d+' | sort -u)
    EXCLUDE_PORTS_TCP=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' 2>/dev/null | grep '/tcp' | grep -oP '0.0.0.0:\K\d+' | sort -u)
    
    # Если Docker пуст, берем порт WireGuard хоста
    if [ -z "$EXCLUDE_PORTS_UDP" ] && command -v wg &> /dev/null; then
        EXCLUDE_PORTS_UDP=$(wg show $WG_IFACE listen-port 2>/dev/null || echo "36532")
    fi
}

# ==========================================
# БЛОК 3: ГЕНЕРАЦИЯ И МАРШРУТИЗАЦИЯ
# ==========================================

generate_config() {
    local private_key=$1; local server_ip=$2; local iface=$3; local endpoint=$4
    
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

    local idx=1
    for p in $EXCLUDE_PORTS_UDP; do
        echo "PostUp = iptables -t mangle -I PREROUTING $idx -i $iface -p udp --sport $port -j ACCEPT" >> /etc/wireguard/warp.conf
        echo "PostDown = iptables -t mangle -D PREROUTING -i $iface -p udp --sport $port -j ACCEPT" >> /etc/wireguard/warp.conf
        ((idx++))
    done
    for p in $EXCLUDE_PORTS_TCP; do
        echo "PostUp = iptables -t mangle -I PREROUTING $idx -i $iface -p tcp --sport $port -j ACCEPT" >> /etc/wireguard/warp.conf
        echo "PostDown = iptables -t mangle -D PREROUTING -i $iface -p tcp --sport $port -j ACCEPT" >> /etc/wireguard/warp.conf
        ((idx++))
    done

    cat << EOF >> /etc/wireguard/warp.conf
PostUp = iptables -t mangle -I PREROUTING $idx -i $iface -j MARK --set-mark 0x123
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
    install_packages wireguard-tools iptables curl wget bc
    detect_params

    if [ ! -f /root/wgcf ]; then
        wget -q -O /root/wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
        chmod +x /root/wgcf
    fi

    echo -e "${YELLOW}--- НАСТРОЙКА CLOUDFLARE ---${NC}"
    read -p "Ключ WARP+ (Enter для бесплатного): " warp_key
    
    cd /root
    rm -f wgcf-account.toml wgcf-profile.conf
    ./wgcf register --accept-tos >> $LOG_FILE 2>&1
    [[ -n "$warp_key" ]] && ./wgcf update --license "$warp_key" >> $LOG_FILE 2>&1
    ./wgcf generate >> $LOG_FILE 2>&1
    
    local pk=$(awk '/PrivateKey/ {print $3}' wgcf-profile.conf 2>/dev/null)
    [[ -z "$pk" ]] && { echo -e "${RED}❌ Ошибка получения ключей.${NC}"; exit 1; }

    # Получаем список лучших по пингу адресов
    local best_endpoints=($(get_best_endpoints))
    local success=false

    for endpoint in "${best_endpoints[@]}"; do
        echo -ne "${BLUE}[>] Пробуем шлюз $endpoint... ${NC}"
        generate_config "$pk" "$SERVER_IP" "$WG_IFACE" "$endpoint"
        
        # Полная очистка перед стартом
        wg-quick down warp 2>/dev/null
        for p in 90 91 95 100; do ip rule del priority $p 2>/dev/null; done
        
        wg-quick up warp >> $LOG_FILE 2>&1
        
        # Проверка IP через туннель
        local check_ip=$(curl -4 -s --interface warp --connect-timeout 4 ifconfig.me)
        
        if [[ -n "$check_ip" ]]; then
            echo -e "${GREEN}OK! IP: $check_ip${NC}"
            echo -e "${YELLOW}Этот IP подходит? (Для уникальности на разных серверах можно поискать другой)${NC}"
            read -p "Оставить этот? (y/n): " choice
            if [[ "$choice" == "y" || -z "$choice" ]]; then
                success=true; break
            fi
        else
            echo -e "${RED}не удалось соединиться${NC}"
        fi
    done
    [[ "$success" = "false" ]] && echo -e "${RED}❌ Не удалось найти рабочий шлюз.${NC}"
}

# ==========================================
# БЛОК 4: ВЕБ-СЕРВЕР И SSL
# ==========================================

get_domain() {
    if [ -f /root/.xdark_domain ]; then DOMAIN=$(cat /root/.xdark_domain); else
        read -p "Введите ваш домен (или IP): " DOMAIN
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
    echo -e "${GREEN}✅ SSL сертификат готов.${NC}"
}

web_menu() {
    while true; do
        echo -e "\n${YELLOW}=== УПРАВЛЕНИЕ ВЕБ-САЙТОМ ===${NC}"
        echo "1. 🛠️ Установить Nginx и домен"
        echo "2. 🔒 SSL сертификат (Let's Encrypt)"
        echo "3. 🎨 Поставить заглушку (Спиннер)"
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
    echo -e "${GREEN}   AWG 2.0 Mega Panel v8.0 (Master)   ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo "1. 🚀 Установить / Обновить (Smart Benchmark)"
    echo "2. 📅 Авто-обновление (каждое воскресенье)"
    echo "3. 📊 Статус туннеля и IP"
    echo "4. 🌍 Управление сайтом"
    echo "5. 🗑️ Удалить WARP"
    echo "6. 📜 Посмотреть логи"
    echo "0. ❌ Выход"
    echo -e "${BLUE}=======================================${NC}"
    read -p "Выберите пункт: " choice

    case $choice in
        1) do_renew ;;
        2) (crontab -l 2>/dev/null | grep -v "xdark_warp.sh"; echo "0 5 * * 0 /root/xdark.sh --auto-renew") | crontab -
           echo -e "${GREEN}Расписание в cron настроено.${NC}" ;;
        3) 
            echo -e "WARP: $(ip link show warp >/dev/null 2>&1 && echo -e "${GREEN}UP${NC}" || echo -e "${RED}DOWN${NC}")"
            if ip link show warp >/dev/null 2>&1; then
                echo -e "IP: ${YELLOW}$(curl -4 -s --interface warp --connect-timeout 5 ifconfig.me)${NC}"
                echo -e "Endpoint: ${CYAN}$(grep 'Endpoint' /etc/wireguard/warp.conf | awk '{print $3}')${NC}"
                wg show warp transfer
            fi ;;
        4) web_menu ;;
        5) wg-quick down warp 2>/dev/null; systemctl disable wg-quick@warp; rm -f /etc/wireguard/warp.conf; echo -e "${YELLOW}WARP удален.${NC}" ;;
        6) tail -n 50 $LOG_FILE ;;
        0) exit 0 ;;
    esac
done
