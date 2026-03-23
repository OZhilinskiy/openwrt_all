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

    if [ "$MODE" = "all" ]; then
        echo "Configuring FULL tunnel via WG..."
        uci set network.@wireguard_wg0[0].route_allowed_ips='1'
        uci set network.@wireguard_wg0[0].allowed_ips='0.0.0.0/0'
        uci commit network

        # Пробуем получить IP WG endpoint
        WG_ENDPOINT=$(uci get network.@wireguard_wg0[0].endpoint_host)
        WG_PORT=$(uci get network.@wireguard_wg0[0].endpoint_port)
        WG_ENDPOINT_IP=$(nslookup "$WG_ENDPOINT" 8.8.8.8 2>/dev/null | awk '/^Address: / {print $2}' | tail -n1)

        if [ -z "$WG_ENDPOINT_IP" ]; then
            echo "ERROR: cannot resolve WG endpoint automatically."
            echo -n "Enter WG endpoint IP manually: "
            read WG_ENDPOINT_IP
        fi

        echo "WG endpoint IP: $WG_ENDPOINT_IP"

        WAN_GW=$(ip route | awk '/default/ {print $3}' | head -n1)
        ip route add $WG_ENDPOINT_IP via $WAN_GW dev wan 2>/dev/null || true
        ip route replace default dev wg0

        echo "✅ FULL tunnel enabled"
    fi

    if [ "$MODE" = "split" ]; then
        echo "Configuring SPLIT tunnel via WG..."
        grep -q '^200 vpn' /etc/iproute2/rt_tables 2>/dev/null || echo "200 vpn" >> /etc/iproute2/rt_tables

        cat << 'EOF' > /etc/hotplug.d/iface/30-vpnroute
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
if [ "$INTERFACE" = "wg0" ]; then
    ip route add table vpn default dev wg0 2>/dev/null || true
fi
EOF

        chmod +x /etc/hotplug.d/iface/30-vpnroute
        ip rule add fwmark 1 table vpn 2>/dev/null || true

        echo "✅ Split-tunnel enabled (нужен ipset + iptables для доменов!)"
    fi
}

add_wireguard() {
    echo "Configure WireGuard tunnel with optional DNSCrypt-proxy2"

    # ---------------- Install packages via apk ----------------
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

    # ---------------- Setup DNSCrypt ----------------
    uci set dhcp.@dnsmasq[0].noresolv="1"
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server="127.0.0.53#53"
    uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
    uci commit dhcp
    /etc/init.d/dnsmasq reload
    /etc/init.d/dnscrypt-proxy restart

    # ---------------- Collect WireGuard info ----------------
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

    # ---------------- Configure wg0 ----------------
    uci set network.wg0=interface
    uci set network.wg0.proto='wireguard'
    uci set network.wg0.private_key="$WG_PRIVATE_KEY"
    uci set network.wg0.listen_port='51820'
    uci set network.wg0.addresses="$WG_IP"

    # ---------------- Configure peer ----------------
    if ! uci show network | grep -q wireguard_wg0; then
        uci add network wireguard_wg0
    fi
    uci set network.@wireguard_wg0[0]=wireguard_wg0
    uci set network.@wireguard_wg0[0].name='wg0_client'
    uci set network.@wireguard_wg0[0].public_key="$WG_PUBLIC_KEY"
    [ -n "$WG_PRESHARED_KEY" ] && uci set network.@wireguard_wg0[0].preshared_key="$WG_PRESHARED_KEY"
    uci set network.@wireguard_wg0[0].allowed_ips='0.0.0.0/0'
    uci set network.@wireguard_wg0[0].route_allowed_ips='0'
    uci set network.@wireguard_wg0[0].persistent_keepalive='25'
    uci set network.@wireguard_wg0[0].endpoint_host="$WG_ENDPOINT"
    uci set network.@wireguard_wg0[0].endpoint_port="$WG_ENDPOINT_PORT"
    uci commit network

    # ---------------- Firewall ----------------
    # Проверяем, есть ли зона wg
    ZONE_IDX=$(uci show firewall | grep -E "@zone.*name='wg'" | awk -F '[][{}]' '{print $2}' | head -n1)
    if [ -z "$ZONE_IDX" ]; then
        uci add firewall zone
        ZONE_IDX=$(uci show firewall | grep -E "@zone.*name='wg'" | awk -F '[][{}]' '{print $2}' | head -n1)
    fi

    uci set firewall.@zone[$ZONE_IDX].name='wg'
    uci set firewall.@zone[$ZONE_IDX].network='wg0'
    uci set firewall.@zone[$ZONE_IDX].input='REJECT'
    uci set firewall.@zone[$ZONE_IDX].forward='ACCEPT'
    uci set firewall.@zone[$ZONE_IDX].output='ACCEPT'
    uci set firewall.@zone[$ZONE_IDX].masq='1'

    # Проверяем forwarding lan->wg
    FORWARD_IDX=$(uci show firewall | grep -E "@forwarding.*src='lan'.*dest='wg'" | awk -F '[][{}]' '{print $2}' | head -n1)
    if [ -z "$FORWARD_IDX" ]; then
        uci add firewall forwarding
        FORWARD_IDX=$(uci show firewall | grep -E "@forwarding.*src='lan'.*dest='wg'" | awk -F '[][{}]' '{print $2}' | head -n1)
    fi

    uci set firewall.@forwarding[$FORWARD_IDX].src='lan'
    uci set firewall.@forwarding[$FORWARD_IDX].dest='wg'

    uci commit firewall
    /etc/init.d/firewall restart
    /etc/init.d/network restart

    echo "WireGuard and DNSCrypt-proxy2 configured successfully!"
}

# ---------------- Run ----------------
add_wireguard
route_vpn
