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
    SERVER_IP=$(curl -s -4 ifconfig.me || ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n')
    WG_IFACE=$(ip link show | grep -E 'amn[0-9]+|wg[0-9]+|awg[0-9]+' | grep -v 'warp' | awk -F': ' '{print $2}' | tr -d ' ' | head -n 1)
    WG_IFACE=${WG_IFACE:-amn0}
}

# ==========================================
# МОДУЛЬ 1: WARP И УНИВЕРСАЛЬНАЯ МАРШРУТИЗАЦИЯ
# ==========================================

generate_config() {
    local private_key=$1
    local server_ip=$2
    local iface=$3

    # 1. Записываем базовый заголовок конфига
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

    # 2. Динамически собираем порты из Docker и добавляем исключения
    local rule_num=1

    if command -v docker &> /dev/null; then
        local udp_ports=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' | grep -oP '0.0.0.0:\K\d+(?=/udp)' | sort -u)
        for p in $udp_ports; do
            echo "PostUp = iptables -t mangle -I PREROUTING $rule_num -i $iface -p udp --sport $p -j ACCEPT" >> /etc/wireguard/warp.conf
            echo "PostDown = iptables -t mangle -D PREROUTING -i $iface -p udp --sport $p -j ACCEPT" >> /etc/wireguard/warp.conf
            ((rule_num++))
        done

        local tcp_ports=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' | grep -oP '0.0.0.0:\K\d+(?=/tcp)' | sort -u)
        for p in $tcp_ports; do
            echo "PostUp = iptables -t mangle -I PREROUTING $rule_num -i $iface -p tcp --sport $p -j ACCEPT" >> /etc/wireguard/warp.conf
            echo "PostDown = iptables -t mangle -D PREROUTING -i $iface -p tcp --sport $p -j ACCEPT" >> /etc/wireguard/warp.conf
            ((rule_num++))
        done
    fi

    # Fallback: Если Docker пуст, пробуем найти стандартный WireGuard порт
    if [ "$rule_num" -eq 1 ] && command -v wg &> /dev/null; then
        local wg_port=$(wg show $iface listen-port 2>/dev/null)
        if [ -n "$wg_port" ]; then
            echo "PostUp = iptables -t mangle -I PREROUTING $rule_num -i $iface -p udp --sport $wg_port -j ACCEPT" >> /etc/wireguard/warp.conf
            echo "PostDown = iptables -t mangle -D PREROUTING -i $iface -p udp --sport $wg_port -j ACCEPT" >> /etc/wireguard/warp.conf
            ((rule_num++))
        fi
    fi

    # 3. Завершаем конфигурацию NAT и маркировки
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

    echo -e "${CYAN}[*] Подключение к Cloudflare (отладка в $LOG_FILE)...${NC}"
    cd /root
    rm -f wgcf-account.toml wgcf-profile.conf
    
    ./wgcf register --accept-tos >> $LOG_FILE 2>&1
    ./wgcf generate >> $LOG_FILE 2>&1
    
    NEW_KEY=$(awk '/PrivateKey/ {print $3}' wgcf-profile.conf 2>/dev/null)
    
    if [ -z "$NEW_KEY" ]; then
        echo -e "${RED}Ошибка: Не удалось получить ключ от Cloudflare.${NC}"
        exit 1
    fi
    
    echo -e "${CYAN}[*] Генерируем универсальные правила маршрутизации...${NC}"
    generate_config "$NEW_KEY" "$SERVER_IP" "$WG_IFACE"
    
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

get_domain() {
    if [ -f /root/.xdark_domain ]; then
        DOMAIN=$(cat /root/.xdark_domain)
    else
        read -p "Введите ваш домен (например, xdarkone.win или IP): " DOMAIN
        echo "$DOMAIN" > /root/.xdark_domain
    fi
    WEB_DIR="/var/www/$DOMAIN"
}

setup_nginx() {
    get_domain
    install_packages nginx unzip wget curl

    if [ -f "/etc/nginx/sites-available/$DOMAIN" ]; then
        echo -e "${YELLOW}Внимание: Конфигурация Nginx для $DOMAIN уже существует.${NC}"
        read -p "Хотите перезаписать её? (y/n): " overwrite
        if [[ "$overwrite" != "y" ]]; then return; fi
    fi
    
    echo -e "${CYAN}[*] Настройка конфигурации Nginx...${NC}"
    mkdir -p $WEB_DIR
    chown -R www-data:www-data $WEB_DIR
    chmod -R 755 $WEB_DIR

    cat << EOF > /etc/nginx/sites-available/$DOMAIN
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    root $WEB_DIR;
    index index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        systemctl enable nginx >/dev/null 2>&1
        systemctl restart nginx
        echo -e "${GREEN}✅ Nginx успешно настроен для $DOMAIN${NC}"
    else
        echo -e "${RED}❌ Ошибка в конфигурации Nginx. Проверьте логи.${NC}"
    fi
}

setup_ssl() {
    get_domain
    if [[ $DOMAIN =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}Ошибка: SSL-сертификат можно выпустить только на доменное имя.${NC}"
        return
    fi

    install_packages certbot python3-certbot-nginx

    if certbot certificates 2>/dev/null | grep -q "$DOMAIN"; then
        echo -e "${YELLOW}SSL-сертификат для $DOMAIN уже установлен!${NC}"
        read -p "Хотите перевыпустить его? (y/n): " force_ssl
        if [[ "$force_ssl" != "y" ]]; then return; fi
    fi

    read -p "Введите ваш Email: " SSL_EMAIL
    echo -e "${CYAN}[*] Выпуск сертификата SSL...${NC}"
    
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$SSL_EMAIL" --redirect
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ SSL сертификат успешно установлен!${NC}"
    else
        echo -e "${RED}❌ Ошибка выпуска SSL.${NC}"
    fi
}

web_menu() {
    while true; do
        echo -e "\n${YELLOW}=== УПРАВЛЕНИЕ ВЕБ-САЙТОМ ===${NC}"
        get_domain
        echo -e "Текущий домен: ${CYAN}$DOMAIN ($WEB_DIR)${NC}"
        echo "1. 🛠️ Установить Nginx и настроить домен"
        echo "2. 🔒 Выпустить и настроить SSL сертификат"
        echo "3. 🎨 Поставить заглушку (Спиннер)"
        echo "4. 🌐 Клонировать любой сайт"
        echo "5. 📦 Установить премиум-шаблон HTML5 UP"
        echo "6. 📝 Открыть HTML-редактор"
        echo "7. 🔄 Сменить рабочий домен"
        echo "0. 🔙 Назад в главное меню"
        read -p "Выберите действие: " web_choice

        case $web_choice in
            1) setup_nginx ;;
            2) setup_ssl ;;
            3)
                if [ ! -d "$WEB_DIR" ]; then echo -e "${RED}Сначала выполните пункт 1!${NC}"; continue; fi
                cat << 'EOF' > $WEB_DIR/index.html
<!DOCTYPE html>
<html lang="ru"><head><meta charset="UTF-8"><title>Обслуживание</title>
<style>body{background:#0d1117;color:#c9d1d9;font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;text-align:center;} .box{background:#161b22;padding:40px;border-radius:10px;border:1px solid #30363d;} h1{color:#8a2be2;} .spin{margin:20px auto;width:40px;height:40px;border:4px solid #30363d;border-top:4px solid #8a2be2;border-radius:50%;animation:s 1s linear infinite;} @keyframes s{100%{transform:rotate(360deg);}}</style>
</head><body><div class="box"><div class="spin"></div><h1>Техническое обслуживание</h1><p>Сервер временно недоступен. Зайдите позже.</p></div></body></html>
EOF
                echo -e "${GREEN}✅ Заглушка установлена!${NC}"
                ;;
            4)
                if [ ! -d "$WEB_DIR" ]; then echo -e "${RED}Сначала выполните пункт 1!${NC}"; continue; fi
                read -p "Введите URL для клонирования (с https://): " clone_url
                rm -rf $WEB_DIR/*
                wget -q -E -H -k -K -p -nd -P $WEB_DIR "$clone_url"
                chown -R www-data:www-data $WEB_DIR
                echo -e "${GREEN}✅ Сайт успешно склонирован!${NC}"
                ;;
            5)
                if [ ! -d "$WEB_DIR" ]; then echo -e "${RED}Сначала выполните пункт 1!${NC}"; continue; fi
                install_packages unzip wget
                rm -rf $WEB_DIR/*
                wget -q -O /tmp/temp.zip https://html5up.net/dimension/download
                unzip -q /tmp/temp.zip -d $WEB_DIR
                rm -f /tmp/temp.zip
                chown -R www-data:www-data $WEB_DIR
                echo -e "${GREEN}✅ Шаблон успешно установлен!${NC}"
                ;;
            6)
                if [ ! -f "$WEB_DIR/index.html" ]; then touch $WEB_DIR/index.html; fi
                nano $WEB_DIR/index.html
                ;;
            7)
                rm -f /root/.xdark_domain
                get_domain
                ;;
            0) break ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
    done
}

# ==========================================
# ГЛАВНОЕ МЕНЮ
# ==========================================

while true; do
    echo -e "\n${BLUE}=======================================${NC}"
    echo -e "${GREEN}   AWG 2.0 Mega Panel v5.0 (Universal)  ${NC}"
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
        4) web_menu ;;
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
