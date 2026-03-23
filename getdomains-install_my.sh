#!/bin/sh

route_vpn() {
    echo "Configuring VPN routing for WireGuard..."

    # Добавляем таблицу vpn если её нет
    grep -q '^200 vpn' /etc/iproute2/rt_tables 2>/dev/null || echo "200 vpn" >> /etc/iproute2/rt_tables

    # Создаём hotplug-скрипт
    cat << 'EOF' > /etc/hotplug.d/iface/30-vpnroute
#!/bin/sh

# выполняем только при поднятии интерфейса
[ "$ACTION" = "ifup" ] || exit 0

# только для wg0
if [ "$INTERFACE" = "wg0" ]; then
    echo "Adding default route to table vpn via wg0"
    ip route add table vpn default dev wg0 2>/dev/null || true
fi
EOF

    chmod +x /etc/hotplug.d/iface/30-vpnroute

    echo "Done: wg0 will use routing table vpn"
}

add_wireguard() {
    echo "Configure WireGuard tunnel with optional DNSCrypt-proxy2"

    # Install WireGuard & DNSCrypt
    if ! apk info wireguard-tools >/dev/null 2>&1; then
        echo "Installing WireGuard..."
        apk add wireguard-tools luci-proto-wireguard
    else
        echo "WireGuard already installed"
    fi

    if ! apk info dnscrypt-proxy2 >/dev/null 2>&1; then
        echo "Installing DNSCrypt-proxy2..."
        apk add dnscrypt-proxy2
    else
        echo "DNSCrypt-proxy2 already installed"
    fi

    # Setup DNSCrypt
    uci set dhcp.@dnsmasq[0].noresolv="1"
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server="127.0.0.53#53"
    uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
    uci commit dhcp
    /etc/init.d/dnsmasq reload
    /etc/init.d/dnscrypt-proxy restart

    # Configure VPN route
    route_vpn

    # Collect WireGuard info
    echo -n "Enter your private key: "
    read WG_PRIVATE_KEY

    while true; do
        echo -n "Enter internal IP/subnet (e.g., 192.168.100.5/24): "
        read WG_IP
        echo "$WG_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$' && break
        echo "Invalid IP format. Try again."
    done

    echo -n "Enter peer public key: "
    read WG_PUBLIC_KEY
    echo -n "Enter preshared key (optional, leave blank if none): "
    read WG_PRESHARED_KEY
    echo -n "Enter endpoint host: "
    read WG_ENDPOINT
    echo -n "Enter endpoint port [51820]: "
    read WG_ENDPOINT_PORT
    WG_ENDPOINT_PORT=${WG_ENDPOINT_PORT:-51820}

    # Configure wg0
    uci set network.wg0=interface
    uci set network.wg0.proto='wireguard'
    uci set network.wg0.private_key="$WG_PRIVATE_KEY"
    uci set network.wg0.listen_port='51820'
    uci set network.wg0.addresses="$WG_IP"

    # Configure peer
    if ! uci show network | grep -q wireguard_wg0; then
        uci add network wireguard_wg0
    fi
    uci set network.@wireguard_wg0[0]=wireguard_wg0
    uci set network.@wireguard_wg0[0].name='wg0_client'
    uci set network.@wireguard_wg0[0].public_key="$WG_PUBLIC_KEY"
    if [ -n "$WG_PRESHARED_KEY" ]; then
        uci set network.@wireguard_wg0[0].preshared_key="$WG_PRESHARED_KEY"
    fi
    uci set network.@wireguard_wg0[0].allowed_ips='0.0.0.0/0'
    uci set network.@wireguard_wg0[0].route_allowed_ips='0'
    uci set network.@wireguard_wg0[0].persistent_keepalive='25'
    uci set network.@wireguard_wg0[0].endpoint_host="$WG_ENDPOINT"
    uci set network.@wireguard_wg0[0].endpoint_port="$WG_ENDPOINT_PORT"
    uci commit network

    /etc/init.d/network restart
    echo "WireGuard and DNSCrypt-proxy2 configured successfully!"
}

# вызов функции
add_wireguard

# пустая строка в конце файла обязательна!