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

    # ---------------- Configure VPN route ----------------
    route_vpn

    # ---------------- Collect WireGuard info ----------------
    read -r -p "Enter your private key: " WG_PRIVATE_KEY

    while true; do
        read -r -p "Enter internal IP/subnet (e.g., 192.168.100.5/24): " WG_IP
        if echo "$WG_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'; then
            break
        else
            echo "Invalid IP format. Try again."
        fi
    done

    read -r -p "Enter peer public key: " WG_PUBLIC_KEY
    read -r -p "Enter preshared key (optional, leave blank if none): " WG_PRESHARED_KEY
    read -r -p "Enter endpoint host (Domain or IP): " WG_ENDPOINT
    read -r -p "Enter endpoint port [51820]: " WG_ENDPOINT_PORT
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

    /etc/init.d/network restart
    echo "WireGuard and DNSCrypt-proxy2 configured successfully!"
}

add_wireguard