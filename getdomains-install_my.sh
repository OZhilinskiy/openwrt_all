#!/bin/sh

route_vpn() {
    echo "Select routing mode:"
    echo "1) Route ALL traffic via WireGuard"
    echo "2) Route ONLY selected domains via WireGuard (split-tunnel)"

    while true; do
        echo -n "Select: "
        read MODE
        case "$MODE" in
            1) MODE="all"; break ;;
            2) MODE="split"; break ;;
            *) echo "Choose 1 or 2";;
        esac
    done

    # ---------------- FULL TUNNEL ----------------
    if [ "$MODE" = "all" ]; then
        echo "Configuring FULL tunnel via WG..."

        # включаем full tunnel в UCI
        uci set network.@wireguard_wg0[0].route_allowed_ips='1'
        uci set network.@wireguard_wg0[0].allowed_ips='0.0.0.0/0'
        uci commit network

        # получаем endpoint
        WG_ENDPOINT=$(uci get network.@wireguard_wg0[0].endpoint_host)
        WG_PORT=$(uci get network.@wireguard_wg0[0].endpoint_port)

        # получаем IP endpoint
        WG_ENDPOINT_IP=$(nslookup "$WG_ENDPOINT" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n1)

        if [ -z "$WG_ENDPOINT_IP" ]; then
            echo "ERROR: cannot resolve WG endpoint"
            return 1
        fi

        echo "WG endpoint IP: $WG_ENDPOINT_IP"

        # находим WAN gateway
        WAN_GW=$(ip route | awk '/default/ {print $3}' | head -n1)

        # добавляем маршрут к серверу WG через WAN
        ip route add $WG_ENDPOINT_IP via $WAN_GW dev wan 2>/dev/null || true

        # переключаем default route на WG
        ip route replace default dev wg0

        echo "✅ FULL tunnel enabled"

    fi

    # ---------------- SPLIT TUNNEL ----------------
    if [ "$MODE" = "split" ]; then
        echo "Configuring SPLIT tunnel via WG..."

        # таблица маршрутов
        grep -q '^200 vpn' /etc/iproute2/rt_tables 2>/dev/null || echo "200 vpn" >> /etc/iproute2/rt_tables

        # hotplug
        cat << 'EOF' > /etc/hotplug.d/iface/30-vpnroute
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0

if [ "$INTERFACE" = "wg0" ]; then
    ip route add table vpn default dev wg0 2>/dev/null || true
fi
EOF

        chmod +x /etc/hotplug.d/iface/30-vpnroute

        # правило
        ip rule add fwmark 1 table vpn 2>/dev/null || true

        echo "✅ Split-tunnel enabled (нужен ipset + iptables)"
    fi
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

    # ---------------- Firewall ----------------
    echo "Configuring firewall..."
    uci -q delete firewall.wg
    uci set firewall.wg=zone
    uci set firewall.wg.name='wg'
    uci set firewall.wg.network='wg0'
    uci set firewall.wg.input='REJECT'
    uci set firewall.wg.forward='ACCEPT'
    uci set firewall.wg.output='ACCEPT'
    uci set firewall.wg.masq='1'

    uci -q delete firewall.lan_wg
    uci set firewall.lan_wg=forwarding
    uci set firewall.lan_wg.src='lan'
    uci set firewall.lan_wg.dest='wg'

    uci commit firewall
    /etc/init.d/firewall restart

    /etc/init.d/network restart
    echo "WireGuard and DNSCrypt-proxy2 configured successfully!"
}

# вызов функции
add_wireguard

# пустая строка в конце файла обязательна!