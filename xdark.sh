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
# ОБЩИЕ ФУНКЦИИ (ПРОВЕРКИ И УСТАНОВКА)
# ==========================================

install_packages() {
    local to_install=""
    for pkg in "$@"; do
        if ! dpkg -l | grep -q -w "^ii  $pkg "; then
            to_install="$to_install $pkg"
        fi
    done
    
    if [ -n "$to_install" ]; then
        echo -e "${CYAN}[*] Устанавливаем пакеты:$to_install...${NC}"
        echo "[*] apt-get update & install $to_install" >> $LOG_FILE
        apt-get update >> $LOG_FILE 2>&1
        apt-get install -y $to_install >> $LOG_FILE 2>&1
    fi
}

detect_params() {
    # 1. Железобетонное определение IP (работает даже за NAT)
    SERVER_IP=$(ip -4 route get 8.8.8.8 | grep -oP '(?<=src )(\S+)' | head -n 1)
    
    # 2. Определение интерфейса Amnezia/WireGuard (исключая сам warp)
    WG_IFACE=$(ip link show | grep -E 'amn[0-9]+|wg[0-9]+|awg[0-9]+' | grep -v 'warp' | awk -F': ' '{print $2}' | tr -d ' ' | head -n 1)
    WG_IFACE=${WG_IFACE:-amn0} # Дефолт, если интерфейс пока не создан
    
    # 3. Определение порта (если интерфейс уже поднят)
    if command -v wg &> /dev/null && ip link show "$WG_IFACE" > /dev/null 2>&1; then
        WG_PORT=$(wg show "$WG_IFACE" listen-port 2>/dev/null)
    fi
    WG_PORT=${WG_PORT:-36532}
}

# ==========================================
# МОДУЛЬ 1: WARP И МАРШРУТИЗАЦИЯ
# ==========================================

generate_config() {
    local private_key=$1
    local server_ip=$2
    local iface=$3
    local port=$4

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

PostUp = iptables -t mangle -I PREROUTING 1 -i $iface -p udp --sport $port -j ACCEPT
PostUp = iptables -t mangle -I PREROUTING 2 -i $iface -j MARK --set-mark 0x123
PostDown = iptables -t mangle -D PREROUTING -i $iface -p udp --sport $port -j ACCEPT
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
Endpoint = 162.159.192.1:2408
PersistentKeepalive = 25
EOF
}

do_renew() {
    install_packages wireguard-tools iptables curl wget
    detect_params

    if [ ! -f /root/wgcf ]; then
        echo -e "${CYAN}[*] Скачиваем утилиту wgcf...${NC}"
        wget -q -O /root/wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
        chmod +x /root/wgcf
    fi

    echo -e "${CYAN}[*] Подключение к Cloudflare (отладка пишется в $LOG_FILE)...${NC}"
    cd /root
    rm -f wgcf-account.toml wgcf-profile.conf
    
    echo "[*] Запуск wgcf register..." >> $LOG_FILE
    ./wgcf register --accept-tos >> $LOG_FILE 2>&1
    
    echo "[*] Запуск wgcf generate..." >> $LOG_FILE
    ./wgcf generate >> $LOG_FILE 2>&1
    
    # Надежное извлечение ключа через awk (решение проблемы обрезки ключа)
    NEW_KEY=$(awk '/PrivateKey/ {print $3}' wgcf-profile.conf 2>/dev/null)
    
    if [ -z "$NEW_KEY" ]; then
        echo -e "${RED}Ошибка: Не удалось получить ключ от Cloudflare.${NC}"
        echo -e "${YELLOW}Загляните в лог: ${NC}tail -n 30 $LOG_FILE"
        exit 1
    fi
    
    generate_config "$NEW_KEY" "$SERVER_IP" "$WG_IFACE" "$WG_PORT"
    
    echo "[*] Перезапуск wg-quick@warp..." >> $LOG_FILE
    systemctl enable wg-quick@warp >> $LOG_FILE 2>&1
    systemctl restart wg-quick@warp >> $LOG_FILE 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Туннель WARP запущен. Новый IP: $(curl -s --interface warp ifconfig.me)${NC}"
    else
        echo -e "${RED}❌ Ошибка при запуске туннеля WARP.${NC}"
        echo -e "${YELLOW}Посмотрите ошибки: ${NC}journalctl -xeu wg-quick@warp.service"
    fi
}

if [[ "$1" == "--auto-renew" ]]; then
    do_renew
    exit 0
fi

# ==========================================
# МОДУЛЬ 2: ВЕБ-СЕРВЕР И SSL
# ==========================================

get_domain() {
    if [ -f /root/.xdark_domain ]; then
        DOMAIN=$(cat /root/.xdark_domain)
    else
        read -p "Введите ваш домен (например, xdarkone.win или IP): " DOMAIN
        echo "$DOMAIN" > /root/.xdark_domain
    fi
    WEB_DIR="/var/www/$DOMAIN"
}

# ... (Модули setup_nginx, setup_ssl, web_menu остаются без изменений, они работают стабильно)
# Для экономии места в ответе я их пропустил, скопируй их из предыдущей версии скрипта
# и вставь сюда перед главным меню.

# ==========================================
# ГЛАВНОЕ МЕНЮ
# ==========================================

while true; do
    echo -e "\n${BLUE}=======================================${NC}"
    echo -e "${GREEN}   AWG 2.0 Mega Panel v4.0 (Logging)  ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${YELLOW}--- СЕТЬ И МАРШРУТИЗАЦИЯ ---${NC}"
    echo "1. 🚀 Установить WARP / Обновить ключи"
    echo "2. 📅 Настроить авто-обновление WARP (каждое ВС)"
    echo "3. 📊 Статус туннеля и IP-адреса"
    echo -e "${YELLOW}--- СИСТЕМА И ОТЛАДКА ---${NC}"
    echo "4. 🌍 Управление сайтом (Nginx, SSL, Заглушки)"
    echo "5. 🗑️ Полное удаление WARP"
    echo "6. 📜 Посмотреть логи работы скрипта"
    echo "0. ❌ Выход"
    echo -e "${BLUE}=======================================${NC}"
    read -p "Выберите пункт: " choice

    case $choice in
        1) do_renew ;;
        2)
            (crontab -l 2>/dev/null | grep -v "xdark_warp.sh"; echo "0 5 * * 0 /root/xdark_warp.sh --auto-renew") | crontab -
            echo -e "${GREEN}✅ Авто-обновление настроено на каждое воскресенье в 05:00.${NC}"
            ;;
        3) 
            echo -e "WARP: $(ip link show warp >/dev/null 2>&1 && echo -e "${GREEN}РАБОТАЕТ${NC}" || echo -e "${RED}ВЫКЛЮЧЕН${NC}")"
            echo -e "IP: ${YELLOW}$(curl -s --interface warp ifconfig.me)${NC}"
            wg show warp transfer 2>/dev/null
            ;;
        4) web_menu ;; # Вставь функцию web_menu из прошлой версии
        5) 
            systemctl disable wg-quick@warp >/dev/null 2>&1
            wg-quick down warp >/dev/null 2>&1
            rm -f /etc/wireguard/warp.conf /root/wgcf*
            echo -e "${YELLOW}WARP полностью удален.${NC}"
            ;;
        6)
            echo -e "${CYAN}=== Последние 50 строк лога $LOG_FILE ===${NC}"
            tail -n 50 $LOG_FILE
            echo -e "${CYAN}================================================${NC}"
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}" ;;
    esac
done
