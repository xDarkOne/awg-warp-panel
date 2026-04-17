#!/bin/bash

# --- Цвета ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

LOG_FILE="/var/log/xdark_warp.log"
SCRIPT_PATH="$(realpath "$0")"

# Проверка root
[[ "$EUID" -ne 0 ]] && { echo -e "${RED}Ошибка: Запустите от root.${NC}"; exit 1; }

# ==========================================
# БЛОК 1: SMART BENCHMARK
# ==========================================

get_best_endpoints() {
    local ips=("162.159.192.1" "162.159.193.1" "162.159.195.1" "188.114.96.1" "188.114.97.1" "188.114.98.1" "188.114.99.1")
    local ports=("2408" "500" "1701" "4500")
    local results=()

    echo -e "${CYAN}[*] Запуск Benchmark: замеряем задержку до шлюзов...${NC}" >&2
    
    for ip in "${ips[@]}"; do
        for port in "${ports[@]}"; do
            local start=$(date +%s%N)
            if timeout 0.4 bash -c "cat < /dev/null > /dev/udp/$ip/$port" 2>/dev/null; then
                local end=$(date +%s%N)
                local diff=$(( (end - start) / 1000000 ))
                # Сохраняем в формате ПИНГ|IP:ПОРТ
                results+=("$diff|$ip:$port")
            fi
        done
    done

    if [ ${#results[@]} -eq 0 ]; then
        echo -e "${RED}❌ Cloudflare Anycast недоступен.${NC}" >&2
        return 1
    fi

    # Сортируем по пингу и выдаем весь список
    printf "%s\n" "${results[@]}" | sort -n
}

# ==========================================
# БЛОК 2: ПАРАМЕТРЫ И КОНФИГ
# ==========================================

detect_params() {
    SERVER_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me || ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n')
    WG_IFACE=$(ip link show | grep -E 'amn[0-9]+|wg[0-9]+|awg[0-9]+' | grep -v 'warp' | awk -F': ' '{print $2}' | tr -d ' ' | head -n 1)
    WG_IFACE=${WG_IFACE:-amn0}

    EXCLUDE_PORTS_UDP=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' 2>/dev/null | grep '/udp' | grep -oP '0.0.0.0:\K\d+' | sort -u)
    EXCLUDE_PORTS_TCP=$(docker ps --filter "name=amnezia" --format '{{.Ports}}' 2>/dev/null | grep '/tcp' | grep -oP '0.0.0.0:\K\d+' | sort -u)
}

generate_config() {
    local pk=$1; local sip=$2; local iface=$3; local ep=$4
    cat << EOF > /etc/wireguard/warp.conf
[Interface]
PrivateKey = $pk
Address = 172.16.0.2/32
MTU = 1280
Table = 123
PostUp = ip rule add from 172.16.0.2 table 123 priority 95
PostDown = ip rule del from 172.16.0.2 table 123 priority 95
PostUp = ip rule add to $sip table main priority 91
PostDown = ip rule del to $sip table main priority 91
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
Endpoint = $ep
PersistentKeepalive = 25
EOF
}

# ==========================================
# БЛОК 3: ОБНОВЛЕНИЕ КЛЮЧЕЙ И ВЫБОР IP
# ==========================================

apply_and_test() {
    local pk=$1; local ep=$2; local auto=$3
    
    generate_config "$pk" "$SERVER_IP" "$WG_IFACE" "$ep"
    
    wg-quick down warp 2>/dev/null
    for p in 90 91 95 100; do ip rule del priority $p 2>/dev/null; done
    
    if wg-quick up warp >> $LOG_FILE 2>&1; then
        local ip_check=$(curl -4 -s --interface warp --connect-timeout 5 ifconfig.me)
        if [[ -n "$ip_check" ]]; then
            [[ "$auto" != "true" ]] && echo -e "${GREEN}✅ Успех! Туннель поднят. Внешний IP: $ip_check${NC}"
            systemctl enable wg-quick@warp >> $LOG_FILE 2>&1
            return 0
        else
            [[ "$auto" != "true" ]] && echo -e "${RED}[!] Туннель поднялся, но интернета нет (шлюз блокирует трафик).${NC}"
            return 1
        fi
    else
        [[ "$auto" != "true" ]] && echo -e "${RED}❌ Ошибка запуска интерфейса.${NC}"
        return 1
    fi
}

do_renew() {
    local auto=$1
    apt-get install -y wireguard-tools iptables curl bc >> $LOG_FILE 2>&1
    detect_params
    
    local current_ep=$(grep 'Endpoint' /etc/wireguard/warp.conf 2>/dev/null | awk '{print $3}')
    
    [[ "$auto" != "true" ]] && echo -e "${YELLOW}--- УСТАНОВКА / ОБНОВЛЕНИЕ WARP ---${NC}"
    
    cd /root
    rm -f wgcf-account.toml wgcf-profile.conf
    ./wgcf register --accept-tos >> $LOG_FILE 2>&1
    
    if [[ "$auto" != "true" ]]; then
        read -p "Ключ WARP+ (Enter для Free): " warp_key
        [[ -n "$warp_key" ]] && ./wgcf update --license "$warp_key" >> $LOG_FILE 2>&1
    fi
    
    ./wgcf generate >> $LOG_FILE 2>&1
    local pk=$(awk '/PrivateKey/ {print $3}' wgcf-profile.conf 2>/dev/null)
    if [[ -z "$pk" ]]; then
        echo -e "${RED}❌ Ошибка получения ключей от Cloudflare.${NC}"
        return 1
    fi

    # ЛОГИКА АВТООБНОВЛЕНИЯ (CRON)
    if [[ "$auto" == "true" ]]; then
        if [[ -n "$current_ep" ]]; then
            echo "Авто-обновление: используем текущий адрес $current_ep" >> $LOG_FILE
            if apply_and_test "$pk" "$current_ep" "true"; then
                echo "Успешно обновлено." >> $LOG_FILE
                return 0
            fi
            # Если старый адрес "сдох", делаем фоновый поиск нового
            echo "Старый адрес недоступен, ищем новый..." >> $LOG_FILE
        fi
        
        local fallback_list=($(get_best_endpoints))
        for item in "${fallback_list[@]}"; do
            local ep=$(echo "$item" | cut -d'|' -f2)
            if apply_and_test "$pk" "$ep" "true"; then return 0; fi
        done
        return 1
    fi

    # ЛОГИКА РУЧНОЙ НАСТРОЙКИ (ВЫБОР ИЗ СПИСКА)
    local best_list=($(get_best_endpoints))
    [[ ${#best_list[@]} -eq 0 ]] && return 1

    echo -e "\n${YELLOW}Доступные шлюзы (отсортированы по задержке):${NC}"
    local i=1
    local ep_array=()
    
    # Формируем и выводим меню
    for res in "${best_list[@]}"; do
        local ping=$(echo "$res" | cut -d'|' -f1)
        local ep=$(echo "$res" | cut -d'|' -f2)
        
        # Помечаем текущий шлюз, если он совпадает
        if [[ "$ep" == "$current_ep" ]]; then
            echo -e "  ${GREEN}$i) $ep (${ping}ms) <-- ТЕКУЩИЙ${NC}"
        else
            echo -e "  $i) $ep (${ping}ms)"
        fi
        
        ep_array[$i]=$ep
        ((i++))
    done

    echo ""
    local selected_ep=""
    while true; do
        read -p "Введите номер нужного шлюза (1-$((i-1))): " ep_choice
        if [[ "$ep_choice" =~ ^[0-9]+$ ]] && [ "$ep_choice" -ge 1 ] && [ "$ep_choice" -lt "$i" ]; then
            selected_ep=${ep_array[$ep_choice]}
            break
        else
            echo -e "${RED}Неверный ввод. Введите число от 1 до $((i-1)).${NC}"
        fi
    done

    echo -e "${CYAN}[*] Применяем настройки для $selected_ep...${NC}"
    if ! apply_and_test "$pk" "$selected_ep" "false"; then
        echo -e "${YELLOW}Попробуйте выбрать другой шлюз из списка.${NC}"
    fi
}

# ==========================================
# CRON И МЕНЮ
# ==========================================

if [[ "$1" == "--auto-renew" ]]; then
    do_renew "true"
    exit 0
fi

while true; do
    echo -e "\n${BLUE}=======================================${NC}"
    echo -e "${GREEN}   AWG 2.0 Mega Panel v9.0 (Interactive)${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo "1. 🚀 Установить / Обновить (Выбор из списка)"
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
           echo -e "${GREEN}✅ Cron настроен на воскресенье 05:00.${NC}" ;;
        3) 
            echo -e "WARP: $(ip link show warp >/dev/null 2>&1 && echo -e "${GREEN}UP${NC}" || echo -e "${RED}DOWN${NC}")"
            if ip link show warp >/dev/null 2>&1; then
                echo -e "IP: ${YELLOW}$(curl -4 -s --interface warp --connect-timeout 5 ifconfig.me)${NC}"
                echo -e "Endpoint: ${CYAN}$(grep 'Endpoint' /etc/wireguard/warp.conf 2>/dev/null | awk '{print $3}')${NC}"
                wg show warp transfer
            fi ;;
        4) echo "Веб-модуль заглушен (используй свои функции из модуля 2)" ;;
        5) wg-quick down warp 2>/dev/null; systemctl disable wg-quick@warp; rm -f /etc/wireguard/warp.conf; echo -e "${YELLOW}Удалено.${NC}" ;;
        6) tail -n 50 $LOG_FILE ;;
        0) exit 0 ;;
    esac
done
