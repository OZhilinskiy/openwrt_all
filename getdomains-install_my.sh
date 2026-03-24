#!/bin/sh

# ---------------- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ----------------
WG_ENDPOINT=""
WG_ENDPOINT_PORT="51820"
WG_PRIVATE_KEY=""
WG_IP=""
WG_PUBLIC_KEY=""
WG_PRESHARED_KEY=""
WG_ENDPOINT_IP=""

setup_dnscrypt_proxy() {
    echo "=========================================="
    echo "Setting up dnscrypt-proxy with server names"
    echo "=========================================="

    # ---------------- Install ----------------
    apk update
    apk add dnscrypt-proxy

    # ---------------- Stop existing service ----------------
    killall dnscrypt-proxy 2>/dev/null
    /etc/init.d/dnscrypt-proxy stop 2>/dev/null

    # ---------------- Clean old config ----------------
    rm -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml
    mkdir -p /etc/dnscrypt-proxy

    # ---------------- Create new config ----------------
    cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml << 'EOF'
listen_addresses = ['127.0.0.1:5353']
max_clients = 250
ipv4_servers = true
ipv6_servers = false
force_tcp = false
timeout = 2500
log_level = 2
log_file = '/var/log/dnscrypt-proxy.log'

# DNS servers to use (must exist in resolvers list)
server_names = ['google', 'yandex', 'scaleway-fr']

# Sources for resolvers list
[sources]
  [sources.'public-servers']
  urls = ['https://dnscrypt.info/public-servers/']
  cache_file = '/tmp/public-servers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 72
EOF

    # ---------------- Start dnscrypt-proxy ----------------
    /etc/init.d/dnscrypt-proxy restart
    echo "Waiting for dnscrypt-proxy to download resolvers list..."

    # Wait for resolvers list to download (max 30 seconds)
    for i in $(seq 1 30); do
        if [ -f /tmp/public-servers.md ]; then
            echo "✅ Resolvers list downloaded"
            break
        fi
        sleep 1
    done

    sleep 3

    # ---------------- Check if running ----------------
    if ss -tulpn | grep -q 5353; then
        echo "✅ dnscrypt-proxy is running on port 5353"
        echo "   Servers: google, yandex, scaleway-fr"
    else
        echo "⚠️ dnscrypt-proxy failed to start"
        echo "Checking logs..."
        tail -30 /var/log/dnscrypt-proxy.log 2>/dev/null
        return 1
    fi

    # ---------------- Configure dnsmasq ----------------
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci set dhcp.@dnsmasq[0].localuse='1'
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
    uci commit dhcp

    /etc/init.d/dnsmasq restart

    echo ""
    echo "=========================================="
    echo "✅ dnscrypt-proxy configured!"
    echo "=========================================="
    echo "📊 Servers: google, yandex, scaleway-fr"
    echo "📊 Check: ss -tulpn | grep 5353"
    echo "📊 Test: nslookup -port=5353 google.com 127.0.0.1"
}

setup_split_vpn_domains() {
    BASE_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
    CUSTOM_FILE="/etc/vpn/domains.lst"
    VPN_IFACE="wg0"
    PBR_SET="vpn_domains"

    echo "=========================================="
    echo "Setting up Split VPN Routing with PBR + dnscrypt-proxy2 (IPv4 only)"
    echo "=========================================="

    # ---------------- WireGuard ----------------
    if ! ip link show "$VPN_IFACE" >/dev/null 2>&1; then
        echo "❌ ERROR: Interface $VPN_IFACE not found!"
        return 1
    fi
    ip link set "$VPN_IFACE" up 2>/dev/null

    # ---------------- Packages ----------------
    apk update
    apk add curl pbr dnsmasq-full nftables dnscrypt-proxy2

    # ---------------- Directories ----------------
    mkdir -p /etc/vpn /etc/dnsmasq.d /etc/dnscrypt-proxy
    touch "$CUSTOM_FILE"
    rm -f /etc/dnsmasq.d/vpn_domains_ipset.conf

    # ---------------- Detect or create PBR set ----------------
    TARGET_SET=$(nft list sets inet fw4 2>/dev/null | grep -o 'pbr_wg0_4_dst_ip_cfg[0-9a-f]*' | head -1)
    if [ -z "$TARGET_SET" ]; then
        TARGET_SET="$PBR_SET"
        nft add table inet fw4 2>/dev/null || true
        nft add set inet fw4 $TARGET_SET '{ type ipv4_addr; flags dynamic; }' 2>/dev/null || true
    fi

    # ---------------- dnscrypt-proxy2 ----------------
    setup_dnscrypt_proxy

    # ---------------- Download + convert domain list ----------------
    TEMP_LIST="/tmp/vpn_domains.txt"
    curl -s -o "$TEMP_LIST" "$BASE_URL"

    sed 's/#inet#fw4#vpn_domains/#inet#fw4#'$TARGET_SET'/g' "$TEMP_LIST" > /etc/dnsmasq.d/vpn_domains.conf

    if [ -f "$CUSTOM_FILE" ] && [ -s "$CUSTOM_FILE" ]; then
        while read -r DOMAIN; do
            [ -z "$DOMAIN" ] && continue
            echo "$DOMAIN" | grep -q "^#" && continue
            DOMAIN=$(echo "$DOMAIN" | xargs)
            [ -z "$DOMAIN" ] && continue
            echo "nftset=/$DOMAIN/4#inet#fw4#$TARGET_SET" >> /etc/dnsmasq.d/vpn_domains.conf
        done < "$CUSTOM_FILE"
    fi

    sort -u /etc/dnsmasq.d/vpn_domains.conf -o /etc/dnsmasq.d/vpn_domains.conf

    # ---------------- PBR config ----------------
    cat > /etc/config/pbr << PBRCONF
config pbr 'config'
    option enabled '1'
    option verbosity '2'
    option resolver_set 'dnsmasq.nftset'
    option strict_enforcement '0'
    option boot_timeout '30'
    option ipv6_enabled '0'
    option nft_rule_counter '0'
    option nft_set_auto_merge '1'
    list supported_interface '$VPN_IFACE'

config policy
    option name 'vpn_domains'
    option interface '$VPN_IFACE'
    option dest_addr '$TARGET_SET.set'
    option enabled '1'
    option proto 'all'
    option chain 'prerouting'
PBRCONF

    # routing table
    grep -q '^200 vpn' /etc/iproute2/rt_tables || echo "200 vpn" >> /etc/iproute2/rt_tables
    ip route add table vpn default dev "$VPN_IFACE" 2>/dev/null || true
    ip rule add fwmark 0x10000 table vpn 2>/dev/null || true

    /etc/init.d/pbr enable
    /etc/init.d/pbr restart

    echo "=========================================="
    echo "✅ IPv4-only Split VPN Setup Complete!"
    echo "=========================================="
    echo "📊 Check dnscrypt-proxy: netstat -tulpn | grep 5353"
    echo "📊 Check domains set: nft list set inet fw4 $TARGET_SET"
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
        echo "Configuring SPLIT tunnel via WG... -"

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