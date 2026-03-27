#!/bin/sh

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

setup_dnsmasq_delete() {
    
    # Проверка установки пакета через apk
    if apk info --installed dnsmasq-full >/dev/null 2>&1; then
        echo "✓ dnsmasq-full already installed"
    else
        echo "Installing dnsmasq-full..."
        apk update
        apk del dnsmasq
        apk add dnsmasq-full
        
        if [ $? -ne 0 ]; then
            echo "Error: Failed to install packages"
            return 1
        fi
    fi

    # Удаляем временные конфиги, которые могли быть DNS
    rm -f /etc/dnsmasq.d/vpn-domains.conf
    rm -f /etc/dnsmasq.d/vpn.conf

    # Удаляем confdir из настроек (если он там есть)
    uci delete dhcp.@dnsmasq[0].confdir 2>/dev/null
    uci commit dhcp

    # Создаем директорию для дополнительных конфигов (если её нет)
    mkdir -p /etc/dnsmasq.d

    # Восстанавливаем стандартные настройки DNS
    uci set dhcp.@dnsmasq[0].resolvfile='/tmp/resolv.conf.d/resolv.conf.auto'
    uci set dhcp.@dnsmasq[0].localservice='1'
    uci set dhcp.@dnsmasq[0].nonwildcard='1'
    uci set dhcp.@dnsmasq[0].filter_aaaa='0'
    uci set dhcp.@dnsmasq[0].filter_aaaa='0'

    # Удаляем нестандартные настройки
    uci delete dhcp.@dnsmasq[0].logqueries 2>/dev/null
    uci delete dhcp.@dnsmasq[0].nftset 2>/dev/null
    uci commit dhcp
     
    uci add_list dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
    uci commit dhcp
    /etc/init.d/dnsmasq restart

    # Создаем набор vpnset в таблице inet fw4
    # 4. Проверяем nftables набор
    if ! nft list sets inet fw4 2>/dev/null | grep -q "vpnset"; then
        echo "Creating vpnset..."
        nft add set inet fw4 vpnset { type ipv4_addr\; flags interval, timeout\; timeout 1h\; auto-merge\; }
        echo "✓ vpnset created"
    else
        echo "✓ vpnset already exists"
    fi

    # Проверяем, что набор создан
    nft list sets inet fw4
}

setup_dnsmasq() {

    if apk info --installed dnsmasq-full >/dev/null 2>&1; then
        echo "✓ dnsmasq-full already installed"
    else
        echo "Installing dnsmasq-full..."
        apk update
        apk del dnsmasq
        apk add dnsmasq-full || return 1
    fi

    # Очистка старых настроек
    uci delete dhcp.@dnsmasq[0].confdir 2>/dev/null
    uci delete dhcp.@dnsmasq[0].nftset 2>/dev/null

     # 👉 ВАЖНО: удаляем ВСЕ существующие confdir
    while uci -q delete dhcp.@dnsmasq[0].confdir; do
        echo "Removing existing confdir entry"
    done

    # Базовые настройки
    uci set dhcp.@dnsmasq[0].resolvfile='/tmp/resolv.conf.d/resolv.conf.auto'
    uci set dhcp.@dnsmasq[0].localservice='1'
    uci set dhcp.@dnsmasq[0].nonwildcard='1'

    # Создаем директорию для дополнительных конфигов (если её нет)
    mkdir -p /etc/dnsmasq.d

    # Настройка dnsmasq через UCI для использования nftset
    uci set dhcp.@dnsmasq[0].nftset_support='1'
    uci add_list dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'

    uci commit dhcp
    # Запускаем dnsmasq
    /etc/init.d/dnsmasq restart
    
    # Ждем и проверяем статус
    sleep 3
    if /etc/init.d/dnsmasq running; then
        echo "✓ dnsmasq is running"
    else
        echo "✗ dnsmasq failed to start. Checking logs..."
        logread | tail -10 | grep dnsmasq
        return 1
    fi

}

setup_nftables() {

    cat > /etc/nftables.d/10-vpn-domains.nft << 'EOF'
# Определяем таблицу inet vpn для изоляции наших правил
# Это предотвратит конфликты с основной таблицей fw4
table inet vpn_domains {
    # Набор для хранения IP-адресов разрешенных доменов
    set vpn_domains_set {
        type ipv4_addr
        flags interval, timeout
        auto-merge
        timeout 1h
        # Принудительно создаем набор, даже если он пуст
        elements = { }
    }

    # Цепочка для маркировки трафика
    chain prerouting {
        type filter hook prerouting priority filter; policy accept;
        # Если пакет идет на IP из нашего набора, ставим метку (mark) 0x1
        ip daddr @vpn_domains_set meta mark set 0x1
    }
}
EOF
}

setup_route() {

    # Создать таблицу маршрутизации для wg0
    echo "100     wg0" >> /etc/iproute2/rt_tables

    # Добавить маршрут по умолчанию для таблицы wg0
    #ip route add default dev wg0 table wg0

    # 4. Добавить правило для помеченного трафика
    #ip rule add fwmark 0x1 lookup wg0 priority 100

    # 5. Добавить правило маркировки в nftables
    #nft add rule inet fw4 output ip daddr @vpnset meta mark set 0x1

    if ! ip route show table wg0 | grep -q default; then
        echo "Adding default route to table wg0..."
        ip route add default dev wg0 table wg0
        echo "✓ Route added"
    else
        echo "✓ Route already exists"
    fi      

    # 3. Проверяем правило fwmark
    if ! ip rule show | grep -q "fwmark 0x1 lookup wg0"; then
        echo "Adding fwmark rule..."
        ip rule add fwmark 0x1 lookup wg0 priority 100
        echo "✓ Rule added"
    else
        echo "✓ Rule already exists"
    fi


    # 5. Проверяем правило маркировки
    if ! nft list chain inet fw4 output 2>/dev/null | grep -q "ip daddr @vpnset"; then
        echo "Adding marking rule..."
        # Проверяем существование цепочки output
        if ! nft list chain inet fw4 output 2>/dev/null | grep -q "chain output"; then
            nft add chain inet fw4 output { type filter hook output priority 0 \; }
        fi
        nft add rule inet fw4 output ip daddr @vpnset meta mark set 0x1
        echo "✓ Marking rule added"
    else
        echo "✓ Marking rule already exists"
    fi

    echo ""
    echo "=== Verification ==="
    echo ""
    echo "Table wg0:"
    ip route show table wg0
    echo ""
    echo "Rules:"
    ip rule show | grep fwmark
    echo ""
    echo "vpnset elements:"
    nft list set inet fw4 vpnset 2>/dev/null || echo "  (empty)"
    echo ""
    echo "=== Done ==="
    echo ""
    echo "To add IP to VPN routing:"
    echo "  nft add element inet fw4 vpnset { 8.8.8.8 }"
    echo ""
    echo "To add a device IP to VPN:"
    echo "  nft add element inet fw4 vpnset { 192.168.1.100 }"
    echo ""
    echo "To add a whole subnet:"
    echo "  nft add element inet fw4 vpnset { 192.168.1.0/24 }"

}

setup_bpr() {
    
    #if apk info --installed luci-app-pbr >/dev/null 2>&1; then
    if apk list --installed 2>/dev/null | grep -q "luci-app-pbr"; then
        echo "✓ pbr already installed"
    else
        echo "Installing pbr..."
        apk update
        apk add pbr luci-app-pbr || return 1
    fi

    # Включаем PBR
    uci set pbr.config.enabled='1'
    uci set pbr.config.verbosity='2'
    uci set pbr.config.boot_delay='10'

    # Указываем, что набор уже существует (не управляется PBR)
    # Это критически важно, чтобы PBR не пытался удалить наш набор
    uci set pbr.config.nft_file_support='0'

    # Игнорируем wg интерфейс для предотвращения конфликтов
    uci set pbr.config.ignored_interface='wg0'

    # Создаем политику, ссылающуюся на наш существующий набор
    echo "Введите вашу LAN подсеть (например, 192.168.1.0/24):"
    echo "Подсеть можно узнать командой: ifconfig br-lan | grep inet"
    echo ""
    read -p "LAN подсеть: " LAN_SUBNET

    # Проверяем, что ввели не пустую строку
    if [ -z "$LAN_SUBNET" ]; then
        echo "Ошибка: подсеть не может быть пустой!"
        exit 1
    fi

    uci add pbr policy
    uci set pbr.@policy[-1].name='vpn_by_domains'
    uci set pbr.@policy[-1].src_addr="$LAN_SUBNET"  # Ваша LAN подсеть
    uci set pbr.@policy[-1].nftset='vpn_domains_set'   # Имя набора из шага 2
    uci set pbr.@policy[-1].interface='wg0'
    uci set pbr.@policy[-1].enabled='1'

    # Важно: указываем, что набор находится в таблице vpn_domains (а не fw4 по умолчанию)
    uci set pbr.@policy[-1].nftset_table='vpn_domains'

    uci commit pbr
    /etc/init.d/pbr restart
}

echo "=========================================="
echo "WireGuard Setup Script"
echo "=========================================="
echo ""
echo "  1. Configure WG for policy-based routing (split tunneling)"
echo "  2. Route all traffic through WG"
echo "  3. Skip"
echo ""
read -r -p "Select option (1-3): " choice

case "$choice" in
    1)
        echo ""
        setup_wg_client
        ;;
    2)
        echo "Skipped"
        setup_dnsmasq
        setup_nftables
        setup_bpr
        #setup_route
        ;;
    3)
        echo "Skipped"
        
        ;;
    *)
        echo "Invalid option"
        ;;
esac


