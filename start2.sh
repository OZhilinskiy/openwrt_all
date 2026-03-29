
Setup_VPN_SPLIT() {
#1 NFTables (VPN IP + маркировка) ------------------------------------------------------------
#Создаём два файла:

mkdir -p /etc/nftables.d

# 1. Набор VPN
cat > /etc/nftables.d/90-vpnset.nft << 'EOF'
add table inet fw4
add set inet fw4 vpn_domains { type ipv4_addr; flags interval,timeout; timeout 1h; auto-merge; }
EOF

# 2. Маркировка трафика
cat > /etc/nftables.d/91-vpn-mark.nft << 'EOF'
add rule inet fw4 mangle_output ip daddr @vpn_domains meta mark set 0x1
add rule inet fw4 mangle_prerouting ip daddr @vpn_domains meta mark set 0x1
EOF

#2 Настройка dnsmasq-full ----------------------------------------------------------------------
#Устанавливаем dnsmasq-full (если нужно):


if apk info --installed dnsmasq-full >/dev/null 2>&1; then
        echo "✓ dnsmasq-full already installed"
    else
        echo "Installing dnsmasq-full..."
        apk update
        apk del dnsmasq
        apk add dnsmasq-full || return 1
    fi

# Создаём конфигурацию dnsmasq
mkdir -p /etc/dnsmasq.d

# Настраиваем dnsmasq через UCI
uci set dhcp.@dnsmasq[0].nftset='1'
uci add_list dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
uci commit dhcp

# Перезапускаем dnsmasq
/etc/init.d/dnsmasq restart

#3 Автоскрипт запуска VPN Тунеля
cat > /root/vpn-policy.sh << 'EOF'
#!/bin/sh

echo "[VPN] Starting policy routing setup..."

# 1. Ждём wg0 (до 30 секунд)
COUNT=0
while [ $COUNT -lt 30 ]; do
    if ip link show wg0 >/dev/null 2>&1; then
        echo "[VPN] wg0 is up"
        break
    fi
    sleep 1
    COUNT=$((COUNT+1))
done

if ! ip link show wg0 >/dev/null 2>&1; then
    echo "[VPN] ERROR: wg0 not found!"
    exit 1
fi

# 2. Поднимаем интерфейс (на всякий случай)
ip link set wg0 up 2>/dev/null

# 3. nftables
echo "[VPN] Loading nftables rules..."
nft -f /etc/nftables.d/90-vpnset.nft 2>/dev/null
nft -f /etc/nftables.d/91-vpn-mark.nft 2>/dev/null

# 4. Таблица маршрутизации
grep -q "100 vpn" /etc/iproute2/rt_tables || echo "100 vpn" >> /etc/iproute2/rt_tables

# 5. Чистим старые правила
ip rule del fwmark 0x1 lookup vpn priority 100 2>/dev/null
ip route flush table vpn 2>/dev/null

# 6. Добавляем маршрут
echo "[VPN] Adding route..."
ip route add default dev wg0 table vpn

# 7. Добавляем правило
echo "[VPN] Adding rule..."
ip rule add fwmark 0x1 lookup vpn priority 100

echo "[VPN] Done!"
EOF

chmod +x /root/vpn-policy.sh

#АВТОЗАПУСК------------------------------------------------------
#Добавь в /etc/rc.local перед exit 0:
/root/vpn-policy.sh &
}

add_getdomains() {
    echo "Choose your country"
    echo "1) Russia inside"
    echo "2) Russia outside"
    echo "3) Ukraine"
    echo "4) Skip"

    while true; do
        read -r COUNTRY
        case $COUNTRY in 
        1) COUNTRY_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"; break ;;
        2) COUNTRY_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-dnsmasq-nfset.lst"; break ;;
        3) COUNTRY_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Ukraine/inside-dnsmasq-nfset.lst"; break ;;
        4) echo "Skipped"; return ;;
        *) echo "Choose 1-4";;
        esac
    done

    echo "Create script /etc/init.d/getdomains"

cat << EOF > /etc/init.d/getdomains
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
    local count=0
    local DOMAINS_URL="$COUNTRY_URL"
    local TMP_FILE="/etc/dnsmasq.d/domains.lst"

    mkdir -p /etc/dnsmasq.d

    while true; do
        if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
            wget -qO "\$TMP_FILE" "\$DOMAINS_URL" && break
        else
            echo "Internet not available [\$count]"
            count=\$((count+1))
            sleep 5
        fi
    done

    if dnsmasq --test --conf-file="\$TMP_FILE" 2>&1 | grep -q "syntax check OK"; then
        echo "Config OK, restarting dnsmasq"
        /etc/init.d/dnsmasq restart
    else
        echo "dnsmasq config error"
    fi
}
EOF

    chmod +x /etc/init.d/getdomains
    /etc/init.d/getdomains enable

    echo "Setup cron..."

    # Включаем cron если выключен
    /etc/init.d/cron enable
    /etc/init.d/cron start

    if crontab -l 2>/dev/null | grep -q getdomains; then
        echo "Crontab already exists"
    else
        (crontab -l 2>/dev/null; echo "0 */8 * * * /etc/init.d/getdomains start") | crontab -
        echo "Crontab added"
    fi

    echo "Start script"
    /etc/init.d/getdomains start
}

setup_wg_client() {

    printf "\033[32;1mConfigure WireGuard\033[0m\n"

    # Проверка установки пакета через apk
    if apk info --installed wireguard-tools >/dev/null 2>&1; then
        echo "✓ WireGuard already installed"
    else
        echo "Installing wireguard-tools..."
        apk update
        apk add wireguard-tools luci-proto-wireguard
        
        if [ $? -ne 0 ]; then
            echo "Error: Failed to install packages"
            return 1
        fi
    fi

    # Удаляем старые настройки
    echo "Cleaning old configuration..."
    uci delete network.wg0 2>/dev/null
    uci delete network.wg0_client 2>/dev/null
    uci commit network

    # Ввод приватного ключа
    while true; do
        read -r -p "Enter the private key (from [Interface]): " WG_PRIVATE_KEY
        if [ -n "$WG_PRIVATE_KEY" ]; then
            break
        else
            echo "Private key cannot be empty. Please repeat"
        fi
    done

    # Ввод IP адреса с валидацией
    while true; do
        read -r -p "Enter internal IP address with subnet, example 10.0.0.2/24 (from [Interface]): " WG_IP
        if echo "$WG_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'; then
            break
        else
            echo "Invalid format. Please enter in format: 10.0.0.2/24"
        fi
    done

    # Ввод публичного ключа
    while true; do
        read -r -p "Enter the public key (from [Peer]): " WG_PUBLIC_KEY
        if [ -n "$WG_PUBLIC_KEY" ]; then
            break
        else
            echo "Public key cannot be empty. Please repeat"
        fi
    done

    # Ввод PresharedKey (опционально)
    read -r -p "If use PresharedKey, enter it (from [Peer]). If you don't use, leave blank: " WG_PRESHARED_KEY

    # Ввод endpoint host
    while true; do
        read -r -p "Enter Endpoint host (Domain or IP) without port (from [Peer]): " WG_ENDPOINT
        if [ -n "$WG_ENDPOINT" ]; then
            break
        else
            echo "Endpoint host cannot be empty. Please repeat"
        fi
    done

    # Ввод порта с значением по умолчанию
    read -r -p "Enter Endpoint port (from [Peer]) [51820]: " WG_ENDPOINT_PORT
    WG_ENDPOINT_PORT=${WG_ENDPOINT_PORT:-51820}

    # Ввод DNS (опционально)
    read -r -p "Enter DNS servers (space separated) [8.8.8.8 1.1.1.1]: " WG_DNS
    WG_DNS=${WG_DNS:-"8.8.8.8 1.1.1.1"}

    # Создаем интерфейс
    echo "Creating WireGuard interface..."
    uci set network.wg0=interface
    uci set network.wg0.proto='wireguard'
    uci set network.wg0.private_key="$WG_PRIVATE_KEY"
    uci set network.wg0.listen_port='51820'
    uci add_list network.wg0.addresses="$WG_IP"
    uci set network.wg0.defaultroute='0'  # Отключаем маршрут по умолчанию

    # Добавляем DNS
    for dns in $WG_DNS; do
        uci add_list network.wg0.dns="$dns"
    done

    # Добавляем пира
    echo "Adding peer..."
    uci set network.wg0_client=wireguard_wg0
    uci set network.wg0_client.public_key="$WG_PUBLIC_KEY"
    
    if [ -n "$WG_PRESHARED_KEY" ]; then
        uci set network.wg0_client.preshared_key="$WG_PRESHARED_KEY"
    fi
    
    uci set network.wg0_client.route_allowed_ips='0'  # НЕ добавлять маршруты автоматически
    uci set network.wg0_client.persistent_keepalive='25'
    uci set network.wg0_client.endpoint_host="$WG_ENDPOINT"
    uci set network.wg0_client.endpoint_port="$WG_ENDPOINT_PORT"
    uci add_list network.wg0_client.allowed_ips='0.0.0.0/0'

    # Сохраняем настройки сети
    uci commit network

    # Настройка брандмауэра
    echo "Configuring firewall..."
    
    # Удаляем старую зону если есть
    for i in $(uci show firewall | grep "=zone" | cut -d[ -f2 | cut -d] -f1); do
        if [ "$(uci get firewall.@zone[$i].name 2>/dev/null)" = "wg0" ]; then
            uci delete firewall.@zone[$i]
        fi
    done    

    # Создаем новую зону
    uci add firewall zone
    uci set firewall.@zone[-1].name='wg0'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='ACCEPT'
    uci set firewall.@zone[-1].masq='1'
    uci add_list firewall.@zone[-1].network='wg0'

    # Разрешаем пересылку из LAN в VPN
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='lan'
    uci set firewall.@forwarding[-1].dest='wg0'

    # Разрешаем VPN в WAN
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='wg0'
    uci set firewall.@forwarding[-1].dest='wan'

    uci commit firewall

    # Перезапуск сервисов
    echo "Restarting services..."
    /etc/init.d/network restart
    sleep 3
    /etc/init.d/firewall restart

    echo ""
    echo "=========================================="
    echo "WireGuard setup completed!"
    echo "=========================================="
    echo ""
    echo "Checking WireGuard status:"
    wg show
    echo ""
    echo "Checking default route (should be WAN, not wg0):"
    sleep 3
    ip route show | grep default
}



echo "=========================================="
echo "WireGuard Setup Script"
echo "=========================================="
echo ""
echo "  1. Configure WG for policy-based routing (split tunneling)"
echo "  2. Route all traffic through WG"
echo "  3. Выход"
echo ""
read -r -p "Select option (1-3): " choice

case "$choice" in
    1)
        echo ""
        add_getdomains
        setup_wg_client
        #Setup_VPN_SPLIT
        ;;
    2)
        echo "Skipped"
        add_getdomains
        setup_nftables
        setup_dnsmasq
        
        #setup_bpr
        setup_uci_routing
        ;;
    3)
        echo "Skipped"
        
        ;;
    *)
        echo "Invalid option"
        ;;
esac
