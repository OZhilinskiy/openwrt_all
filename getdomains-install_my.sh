#!/bin/sh

# ---------------- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ----------------
WG_ENDPOINT=""
WG_ENDPOINT_PORT="51820"
WG_PRIVATE_KEY=""
WG_IP=""
WG_PUBLIC_KEY=""
WG_PRESHARED_KEY=""
WG_ENDPOINT_IP=""

#!/bin/sh

setup_split_vpn_domains() {
    DOMAINS_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
    echo "Using NFT domain list: $DOMAINS_URL"

    # ---------------- пакеты ----------------
    apk add curl dnsmasq-full nftables 2>/dev/null

    # ---------------- таблица маршрутов ----------------
    grep -q '^200 vpn' /etc/iproute2/rt_tables 2>/dev/null || echo "200 vpn" >> /etc/iproute2/rt_tables
    ip rule add fwmark 1 table vpn 2>/dev/null || true

    # ---------------- firewall ipset (fw4 way) ----------------
    if ! uci show firewall | grep -q "name='vpn_domains'"; then
        echo "Creating fw4 nft set..."
        uci add firewall ipset
        uci set firewall.@ipset[-1].name='vpn_domains'
        uci set firewall.@ipset[-1].family='ipv4'
        uci set firewall.@ipset[-1].match='dest_ip'
        uci commit firewall
    fi

    # ---------------- правило маркировки ----------------
    if ! uci show firewall | grep -q "mark_domains"; then
        echo "Creating fwmark rule..."
        uci add firewall rule
        uci set firewall.@rule[-1].name='mark_domains'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest='*'
        uci set firewall.@rule[-1].proto='all'
        uci set firewall.@rule[-1].ipset='vpn_domains'
        uci set firewall.@rule[-1].set_mark='0x1'
        uci set firewall.@rule[-1].target='MARK'
        uci set firewall.@rule[-1].family='ipv4'
        uci commit firewall
    fi

    /etc/init.d/firewall restart

    # ---------------- dnsmasq ----------------
    mkdir -p /tmp/dnsmasq.d

    uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
    uci commit dhcp

    echo "Downloading domain list..."
    curl -s "$DOMAINS_URL" > /tmp/dnsmasq.d/vpn_domains.conf

    # ---------------- кастомные домены ----------------
    uci show dhcp | grep "list domain" | while read -r line; do
        DOMAIN=$(echo "$line" | sed -n "s/.*'\([^']*\)'.*/\1/p")
        [ -n "$DOMAIN" ] && echo "nftset=/$DOMAIN/inet#fw4#vpn_domains" >> /tmp/dnsmasq.d/vpn_domains.conf
    done

    /etc/init.d/dnsmasq restart

    # ---------------- убираем full tunnel ----------------
    echo "Disabling full tunnel..."

    ip route del default dev wg0 2>/dev/null || true

    uci set network.@wireguard_wg0[0].route_allowed_ips='0'
    uci commit network

    /etc/init.d/network restart

    # ---------------- маршрут через wg ----------------
    ip route add table vpn default dev wg0 2>/dev/null || true

    # ---------------- hotplug ----------------
    cat << 'EOF' > /etc/hotplug.d/iface/30-vpnroute
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
if [ "$INTERFACE" = "wg0" ]; then
    ip route add table vpn default dev wg0 2>/dev/null || true
fi
EOF
    chmod +x /etc/hotplug.d/iface/30-vpnroute

    echo "✅ NFT split-tunnel configured!"
}

# ---------------- ФУНКЦИЯ ROUTE ----------------
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

        # Получаем IP endpoint
        if [ -z "$WG_ENDPOINT_IP" ] && echo "$WG_ENDPOINT" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            WG_ENDPOINT_IP="$WG_ENDPOINT"
        fi

        if [ -z "$WG_ENDPOINT_IP" ]; then
            WG_ENDPOINT_IP=$(nslookup "$WG_ENDPOINT" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n1)
        fi

        if [ -z "$WG_ENDPOINT_IP" ]; then
            WG_ENDPOINT_IP=$(nslookup "$WG_ENDPOINT" 8.8.8.8 2>/dev/null | awk '/^Address: / {print $2}' | tail -n1)
        fi

        if [ -z "$WG_ENDPOINT_IP" ]; then
            echo -n "ERROR: cannot resolve WG endpoint automatically. Enter WG endpoint IP manually: "
            read WG_ENDPOINT_IP
        fi

        echo "WG endpoint IP: $WG_ENDPOINT_IP"

        # WAN gateway
        WAN_IF=$(ip route | awk '/default/ {print $5}' | head -n1)
        WAN_GW=$(ip route | awk '/default/ {print $3}' | head -n1)

        # маршрут к серверу WG через WAN
        ip route add $WG_ENDPOINT_IP via $WAN_GW dev $WAN_IF 2>/dev/null || true

        # default route через wg0
        ip route replace default dev wg0

        echo "✅ FULL tunnel enabled"
    fi

    if [ "$MODE" = "split" ]; then
        echo "Configuring SPLIT tunnel via WG..."

        setup_split_vpn_domains
    fi
}

# ---------------- ФУНКЦИЯ ADD WIREGUARD ----------------
add_wireguard() {
    echo "WireGuard setup:"
    echo "1) Configure new WireGuard"
    echo "2) Use existing WireGuard (skip setup)"

    while true; do
        echo -n "Select: "
        read WG_MODE
        case "$WG_MODE" in
            1) WG_MODE="new"; break ;;
            2) WG_MODE="skip"; break ;;
            *) echo "Choose 1 or 2";;
        esac
    done

    # ---------------- ПРОПУСК ----------------
    if [ "$WG_MODE" = "skip" ]; then
        echo "⏭ Skipping WireGuard setup (using existing wg0)"
        return
    fi

    echo "Configure WireGuard tunnel with optional DNSCrypt-proxy2"

    # ---------------- Установка пакетов ----------------
    if ! apk info -e wireguard-tools >/dev/null 2>&1; then
        echo "Installing WireGuard..."
        apk add wireguard-tools luci-proto-wireguard
    else
        echo "WireGuard already installed"
    fi

    if ! apk info -e dnscrypt-proxy2 >/dev/null 2>&1; then
        echo "Installing DNSCrypt-proxy2..."
        apk add dnscrypt-proxy2
    else
        echo "DNSCrypt-proxy2 already installed"
    fi

    # ---------------- Настройка DNS ----------------
    uci set dhcp.@dnsmasq[0].noresolv="1"
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server="127.0.0.53#53"
    uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
    uci commit dhcp
    /etc/init.d/dnsmasq reload
    /etc/init.d/dnscrypt-proxy restart

    # ---------------- Сбор данных ----------------
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
    echo -n "Enter preshared key (optional): "
    read WG_PRESHARED_KEY
    echo -n "Enter endpoint host: "
    read WG_ENDPOINT
    echo -n "Enter endpoint port [51820]: "
    read WG_ENDPOINT_PORT
    WG_ENDPOINT_PORT=${WG_ENDPOINT_PORT:-51820}

    # ---------------- Очистка ----------------
    if uci show network | grep -q '^network.wg0='; then
        uci -q delete network.wg0
    fi
    uci -q delete network.@wireguard_wg0[-1]

    # ---------------- Интерфейс ----------------
    uci set network.wg0=interface
    uci set network.wg0.proto='wireguard'
    uci set network.wg0.private_key="$WG_PRIVATE_KEY"
    uci set network.wg0.listen_port="$WG_ENDPOINT_PORT"
    uci set network.wg0.addresses="$WG_IP"

    # ---------------- Peer ----------------
    uci add network wireguard_wg0
    uci set network.@wireguard_wg0[-1].name='wg0_client'
    uci set network.@wireguard_wg0[-1].public_key="$WG_PUBLIC_KEY"
    [ -n "$WG_PRESHARED_KEY" ] && uci set network.@wireguard_wg0[-1].preshared_key="$WG_PRESHARED_KEY"
    uci set network.@wireguard_wg0[-1].allowed_ips='0.0.0.0/0'
    uci set network.@wireguard_wg0[-1].route_allowed_ips='1'
    uci set network.@wireguard_wg0[-1].persistent_keepalive='25'
    uci set network.@wireguard_wg0[-1].endpoint_host="$WG_ENDPOINT"
    uci set network.@wireguard_wg0[-1].endpoint_port="$WG_ENDPOINT_PORT"

    uci commit network

    # ---------------- Firewall ----------------
    uci -q delete firewall.wg
    uci -q delete firewall.lan_wg

    uci set firewall.wg=zone
    uci set firewall.wg.name='wg'
    uci set firewall.wg.network='wg0'
    uci set firewall.wg.input='REJECT'
    uci set firewall.wg.forward='REJECT'
    uci set firewall.wg.output='ACCEPT'
    uci set firewall.wg.masq='1'

    uci set firewall.lan_wg=forwarding
    uci set firewall.lan_wg.src='lan'
    uci set firewall.lan_wg.dest='wg'

    uci commit firewall

    /etc/init.d/firewall restart
    /etc/init.d/network restart

    echo "✅ WireGuard and DNSCrypt-proxy2 configured successfully!"
}

# ---------------- ВЫЗОВ ФУНКЦИЙ ----------------
add_wireguard
route_vpn

# Пустая строка в конце файла обязательна