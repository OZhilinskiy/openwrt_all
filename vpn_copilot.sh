#!/bin/sh
install_apk() {

echo "=== 0. Устанавливаем необходимые пакеты через apk ==="
apk update

# dnsmasq-full нужен для nftset
if apk info --installed dnsmasq-full >/dev/null 2>&1; then
    echo "dnsmasq-full уже установлен"
else
    echo "Устанавливаем dnsmasq-full..."
    apk del dnsmasq 2>/dev/null
    apk add dnsmasq-full
fi

# nftables (обычно уже есть)
apk add nftables

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

    echo "$COUNTRY_URL" > /etc/getdomains.url

    mkdir -p /etc/dnsmasq.d
    touch /etc/dnsmasq.d/domains.custom

    echo "Create script /etc/init.d/getdomains"

cat << 'EOF' > /etc/init.d/getdomains
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
    local DOMAINS_URL="$(cat /etc/getdomains.url)"
    local TMP_FILE="/etc/dnsmasq.d/domains.lst"
    local CUSTOM_FILE="/etc/dnsmasq.d/domains.custom"
    local count=0

    mkdir -p /etc/dnsmasq.d

    while true; do
        if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
            wget -qO "$TMP_FILE" "$DOMAINS_URL" && break
        else
            echo "Internet not available [$count]"
            count=$((count+1))
            sleep 5
        fi
    done

    # Проверка dnsmasq
    if dnsmasq --test >/dev/null 2>&1; then
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

setup_route(){

echo "=== 1. Enable dnsmasq nftset ==="
mkdir -p /etc/dnsmasq.d
uci set dhcp.@dnsmasq[0].nftset='1'
uci add_list dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
uci commit dhcp
/etc/init.d/dnsmasq restart

echo "=== 2. Create nft set definition ==="
cat > /etc/nft-vpn-set.nft << 'EOF'
set vpn_domains {
    type ipv4_addr
    flags interval, timeout
    timeout 1h
    auto-merge
}
EOF

echo "=== 3. Create nft mark rules ==="
cat > /etc/nft-vpn-mark.nft << 'EOF'
ip daddr @vpn_domains meta mark set 0x1
EOF

echo "=== 4. Add UCI includes for fw4 ==="

# include for set (must be table 'fw4', not table-post)
uci add firewall include
uci set firewall.@include[-1].type='nftables'
uci set firewall.@include[-1].path='/etc/nft-vpn-set.nft'
uci commit firewall


# include for marking (must be chain 'prerouting')
uci add firewall include
uci set firewall.@include[-1].type='nftables'
uci set firewall.@include[-1].path='/etc/nft-vpn-mark.nft'
uci set firewall.@include[-1].position='prerouting'

uci commit firewall

echo "=== 5. Add routing table ==="
grep -q "^100 vpn" /etc/iproute2/rt_tables || echo "100 vpn" >> /etc/iproute2/rt_tables

echo "=== 6. Add static route via wg0 ==="
uci add network route
uci set network.@route[-1].interface='wg0'
uci set network.@route[-1].target='0.0.0.0/0'
uci set network.@route[-1].table='100'
uci commit network

echo "=== 7. Add fwmark rule ==="
uci add network rule
uci set network.@rule[-1].name='vpn_mark'
uci set network.@rule[-1].mark='0x1'
uci set network.@rule[-1].priority='100'
uci set network.@rule[-1].lookup='100'
uci commit network

echo "=== 8. Restart firewall and network ==="
/etc/init.d/firewall restart
/etc/init.d/network restart

echo "=== DONE ==="
echo "Reboot recommended."

}

setup_pbr(){
    apk update
    apk add pbr luci-app-pbr

    #2. Создать файл со списком доменов
    mkdir -p /etc/pbr
    cat << 'EOF' > /etc/pbr/domains.lst
    youtube.com
    netflix.com
    EOF

    #3. Включить DNS‑prefetch в конфиге PBR
    #Полностью заменить конфиг:

cat << 'EOF' > /etc/config/pbr
config pbr 'config'
    option enabled '1'
    option verbosity '1'
    option strict_enforcement '1'
    option resolver_set 'dnsmasq.nftset'
    option resolver_prio '0'
    option dns_prefetch '1'
    option dns_file '/etc/pbr/domains.lst'
    option ipv6_enabled '0'

config policy
    option name 'domains_vpn'
    option interface 'wg0'
    option dest_addr 'pbr.dnsprefetch'
EOF

/etc/init.d/pbr restart

}


setup_wg_client() {

    printf "\033[32;1mConfigure WireGuard\033[0m\n"

    # --- Install packages ---
    if ! apk info --installed wireguard-tools >/dev/null 2>&1; then
        echo "Installing wireguard-tools..."
        apk update
        apk add wireguard-tools
    else
        echo "✓ WireGuard already installed"
    fi

    # luci-proto-wireguard may not exist in apk builds — skip silently
    apk add luci-proto-wireguard 2>/dev/null

    echo "Cleaning old configuration..."
    uci -q delete network.wg0
    uci -q delete network.@wireguard_wg0[0]
    uci commit network

    # --- Input private key ---
    while true; do
        read -r -p "Enter the private key (from [Interface]): " WG_PRIVATE_KEY
        [ -n "$WG_PRIVATE_KEY" ] && break
        echo "Private key cannot be empty."
    done

    # --- Input IP ---
    while true; do
        read -r -p "Enter internal IP address with subnet (e.g. 10.0.0.2/24): " WG_IP
        echo "$WG_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$' && break
        echo "Invalid format."
    done

    # --- Input public key ---
    while true; do
        read -r -p "Enter the public key (from [Peer]): " WG_PUBLIC_KEY
        [ -n "$WG_PUBLIC_KEY" ] && break
        echo "Public key cannot be empty."
    done

    # --- Optional preshared key ---
    read -r -p "Enter PresharedKey (optional): " WG_PSK

    # --- Endpoint host ---
    while true; do
        read -r -p "Enter Endpoint host (domain or IP): " WG_ENDPOINT
        [ -n "$WG_ENDPOINT" ] && break
        echo "Endpoint cannot be empty."
    done

    # --- Endpoint port ---
    read -r -p "Enter Endpoint port [51820]: " WG_ENDPOINT_PORT
    WG_ENDPOINT_PORT=${WG_ENDPOINT_PORT:-51820}

    # --- DNS ---
    read -r -p "Enter DNS servers [8.8.8.8 1.1.1.1]: " WG_DNS
    WG_DNS=${WG_DNS:-"8.8.8.8 1.1.1.1"}

    echo "Creating WireGuard interface..."

    uci set network.wg0="interface"
    uci set network.wg0.proto="wireguard"
    uci set network.wg0.private_key="$WG_PRIVATE_KEY"
    uci add_list network.wg0.addresses="$WG_IP"
    uci set network.wg0.listen_port="51820"
    uci set network.wg0.defaultroute="0"

    for dns in $WG_DNS; do
        uci add_list network.wg0.dns="$dns"
    done

    echo "Adding peer..."

    uci add network wireguard_wg0
    uci set network.@wireguard_wg0[-1].public_key="$WG_PUBLIC_KEY"
    [ -n "$WG_PSK" ] && uci set network.@wireguard_wg0[-1].preshared_key="$WG_PSK"
    uci set network.@wireguard_wg0[-1].endpoint_host="$WG_ENDPOINT"
    uci set network.@wireguard_wg0[-1].endpoint_port="$WG_ENDPOINT_PORT"
    uci set network.@wireguard_wg0[-1].persistent_keepalive="25"
    uci add_list network.@wireguard_wg0[-1].allowed_ips="0.0.0.0/0"
    uci set network.@wireguard_wg0[-1].route_allowed_ips="0"

    uci commit network

    echo "Configuring firewall..."

    # Remove old wg0 zone
    for i in $(uci show firewall | grep "=zone" | cut -d[ -f2 | cut -d] -f1); do
        [ "$(uci -q get firewall.@zone[$i].name)" = "wg0" ] && uci delete firewall.@zone[$i]
    done

    # Create new zone
    uci add firewall zone
    uci set firewall.@zone[-1].name="wg0"
    uci set firewall.@zone[-1].input="ACCEPT"
    uci set firewall.@zone[-1].output="ACCEPT"
    uci set firewall.@zone[-1].forward="ACCEPT"
    uci set firewall.@zone[-1].masq="1"
    uci add_list firewall.@zone[-1].network="wg0"

    # LAN → WG0
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src="lan"
    uci set firewall.@forwarding[-1].dest="wg0"

    # WG0 → WAN
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src="wg0"
    uci set firewall.@forwarding[-1].dest="wan"

    uci commit firewall

    echo "Restarting services..."
    /etc/init.d/network restart
    sleep 2
    /etc/init.d/firewall restart

    echo ""
    echo "=========================================="
    echo "WireGuard setup completed!"
    echo "=========================================="
    echo ""

    echo "WireGuard status:"
    wg show

    echo ""
    echo "Default route (should be WAN):"
    ip route show | grep default
    sleep 3
    /etc/init.d/uhttpd restart
    sleep 3

}






echo "=========================================="
echo "WireGuard Setup Script"
echo "=========================================="
echo ""
echo "  1. Configure WG for policy-based routing (split tunneling)"
echo "  2. Route all traffic through WG"
echo "  3. Настройка автообновления доменов"
echo "  4. Настройка точечной маршрутизации"
echo "  4. Выход"
echo ""
read -r -p "Select option (1-3): " choice

case "$choice" in
    1)
        echo ""
        setup_wg_client
        #Setup_VPN_SPLIT
        ;;
    2)
        echo "Skipped"
        
        #setup_bpr
        setup_uci_routing
        ;;
    3)
        add_getdomains
        ;;
    4)
        install_apk
        setup_pbr
        ;;
    *)
        echo "Invalid option"
        ;;
esac
