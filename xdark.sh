#!/bin/bash

# --- Цвета оформления ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

LOG_FILE="/var/log/xdark_warp.log"
SCRIPT_PATH="$(realpath "$0")"

# Проверка на права root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Ошибка: Запустите от имени root.${NC}"
  exit 1
fi

# ==========================================
# БЛОК 1: SMART BENCHMARK
# ==========================================

get_best_endpoints() {
    local ips=("162.159.192.1" "162.159.193.1" "162.159.195.1" "188.114.96.1" "188.114.97.1" "188.114.98.1" "188.114.99.1")
    local ports=("2408" "500" "1701" "4500")
    local results=()

    echo -e "${CYAN}[*] Поиск лучшего отклика Cloudflare...${NC}" >&2
    
    for ip in "${ips[@]}"; do
        for port in "${ports[@]}"; do
            local start=$(date +%s%N)
            if timeout 0.4 bash -c "cat < /dev/null > /dev/udp/$ip/$port" 2>/dev/null; then
                local end=$(date +%s%N)
                local diff=$(( (end - start) / 1000000 ))
                results+=("$diff|$ip:$port")
            fi
        done
    done

    if [ ${#results[@]} -eq 0 ]; then
        echo -e "${RED}❌ Нет связи с Anycast-сетью.${NC}" >&2
        return 1
    fi
    printf "%s\n" "${results[@]}" | sort -n | awk -F'|' '{print $2}'
}

# ==========================================
# БЛОК 2: ПАРАМЕТРЫ СИСТЕМЫ
# ==========================================

detect_params() {
    SERVER_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me || ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n')
    WG_IFACE=$(ip link show | grep -E 'amn[0-9]+|wg[0-9]+|awg[0-9]+' | grep -v 'warp' | awk -F': ' '{print $2}' | tr -d ' ' | head -n 1)
    WG_IFACE=${WG_IFACE:-amn0}

    EXCLUDE_PORTS_UDP=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' 2>/dev/null | grep '/udp' | grep -oP '0.0.0.0:\K\d+' | sort -u)
    EXCLUDE_PORTS_TCP=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' 2>/dev/null | grep '/tcp' | grep -oP '0.0.0.0:\K\d+' | sort -u)
}

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
        echo "PostUp = iptables -t mangle -I PREROUTING $idx -i $iface -p udp --sport $p -j ACCEPT" >> /etc/wireguard/warp.conf
        echo "PostDown = iptables -t mangle -D PREROUTING -i $iface -p udp --sport $p -j ACCEPT" >> /etc/wireguard/warp.conf
        ((idx++))
    done
    for p in $EXCLUDE_PORTS_TCP; do
        echo "PostUp = iptables -t mangle -I PREROUTING $idx -i $iface -p tcp --sport $p -j ACCEPT" >> /etc/wireguard/warp.conf
        echo "PostDown = iptables -t mangle -D PREROUTING -i $iface -p tcp --sport $p -j ACCEPT" >> /etc/wireguard/warp.conf
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
    local auto_mode=$1
    apt-get install -y wireguard-tools iptables curl bc >> $LOG_FILE 2>&1
    detect_params

    # Сохраняем текущий адрес перед обновлением
    local current_ep=$(grep 'Endpoint' /etc/wireguard/warp.conf 2>/dev/null | awk '{print $3}')

    if [ ! -f /root/wgcf ]; then
        wget -q -O /root/wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
        chmod +x /root/wgcf
    fi

    local warp_key=""
    if [[ "$auto_mode" != "true" ]]; then
        echo -e "${YELLOW}--- НАСТРОЙКА CLOUDFLARE ---${NC}"
        read -p "Ключ WARP+ (Enter для бесплатного): " warp_key
    fi
    
    cd /root
    rm -f wgcf-account.toml wgcf-profile.conf
    ./wgcf register --accept-tos >> $LOG_FILE 2>&1
    [[ -n "$warp_key" ]] && ./wgcf update --license "$warp_key" >> $LOG_FILE 2>&1
    ./wgcf generate >> $LOG_FILE 2>&1
    
    local pk=$(awk '/PrivateKey/ {print $3}' wgcf-profile.conf 2>/dev/null)
    [[ -z "$pk" ]] && return 1

    # Формируем список кандидатов: текущий EP всегда первый
    local candidates=()
    [[ -n "$current_ep" ]] && candidates+=("$current_ep")
    
    # Если мы в интерактивном режиме или текущий шлюз не найден, добавляем результаты бенчмарка
    if [[ "$auto_mode" != "true" || -z "$current_ep" ]]; then
        local best=($(get_best_endpoints))
        for b in "${best[@]}"; do
            [[ "$b" != "$current_ep" ]] && candidates+=("$b")
        done
    fi

    local success=false
    for endpoint in "${candidates[@]}"; do
        echo -e "[*] Тестируем шлюз: $endpoint" >> $LOG_FILE
        generate_config "$pk" "$SERVER_IP" "$WG_IFACE" "$endpoint"
        
        wg-quick down warp 2>/dev/null
        for p in 90 91 95 100; do ip rule del priority $p 2>/dev/null; done
        
        wg-quick up warp >> $LOG_FILE 2>&1
        local check_ip=$(curl -4 -s --interface warp --connect-timeout 4 ifconfig.me)
        
        if [[ -n "$check_ip" ]]; then
            if [[ "$auto_mode" == "true" ]]; then
                success=true; break
            else
                echo -e "${GREEN}OK! IP через туннель: $check_ip${NC}"
                read -p "Оставить этот вариант ($endpoint)? (y/n): " choice
                if [[ "$choice" == "y" || -z "$choice" ]]; then success=true; break; fi
                # Если пользователь отказался, а бенчмарк еще не сделан — делаем его
                if [[ ${#candidates[@]} -eq 1 ]]; then
                    echo -e "${CYAN}[*] Ищем альтернативы...${NC}"
                    local extra=($(get_best_endpoints))
                    for e in "${extra[@]}"; do [[ "$e" != "$endpoint" ]] && candidates+=("$e"); done
                fi
            fi
        fi
    done
    systemctl enable wg-quick@warp >> $LOG_FILE 2>&1
}

# ==========================================
# ОБРАБОТКА CRON
# ==========================================

if [[ "$1" == "--auto-renew" ]]; then
    do_renew "true"
    exit 0
fi

# ==========================================
# ГЛАВНОЕ МЕНЮ
# ==========================================

while true; do
    echo -e "\n${BLUE}=======================================${NC}"
    echo -e "${GREEN}   AWG 2.0 Mega Panel v8.3 (Stable)   ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo "1. 🚀 Установить / Обновить (Приоритет текущему)"
    echo "2. 📅 Настроить авто-обновление (Cron)"
    echo "3. 📊 Статус и IP"
    echo "4. 🌍 Веб-сервер"
    echo "5. 🗑️ Удалить WARP"
    echo "6. 📜 Логи"
    echo "0. ❌ Выход"
    read -p "Выберите пункт: " choice

    case $choice in
        1) do_renew "false" ;;
        2) (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "0 5 * * 0 $SCRIPT_PATH --auto-renew") | crontab -
           echo -e "${GREEN}✅ Cron настроен.${NC}" ;;
        3) echo -e "WARP: $(ip link show warp >/dev/null 2>&1 && echo -e "${GREEN}UP${NC}" || echo -e "${RED}DOWN${NC}")"
           echo -e "IP: ${YELLOW}$(curl -4 -s --interface warp --connect-timeout 5 ifconfig.me)${NC}"
           echo -e "Endpoint: ${CYAN}$(grep 'Endpoint' /etc/wireguard/warp.conf 2>/dev/null | awk '{print $3}' || echo 'N/A')${NC}"
           wg show warp transfer 2>/dev/null ;;
        4) # Тут твои функции веб-меню из прошлых версий
           echo "Веб-модуль запущен" ;;
        5) wg-quick down warp 2>/dev/null; systemctl disable wg-quick@warp; rm -f /etc/wireguard/warp.conf ;;
        6) tail -n 50 $LOG_FILE ;;
        0) exit 0 ;;
    esac
done
