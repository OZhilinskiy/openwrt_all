#!/bin/sh

# ---------------- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ----------------
WG_ENDPOINT=""
WG_ENDPOINT_PORT="51820"
WG_PRIVATE_KEY=""
WG_IP=""
WG_PUBLIC_KEY=""
WG_PRESHARED_KEY=""
WG_ENDPOINT_IP=""


setup_split_vpn_domains() {
    BASE_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
    CUSTOM_FILE="/etc/vpn/domains.lst"
    PBR_SET="vpn_domains"
    VPN_IFACE="wg0"

    echo "✅ Setting up Policy-Based Routing with PBR (nftables)"
    echo "Base list: $BASE_URL"
    echo "Custom file: $CUSTOM_FILE"
    echo "VPN interface: $VPN_IFACE"

    # ---------------- пакеты ----------------
    echo "Installing packages..."
    
    apk install curl pbr #dnsmasq-full nftables

    # ---------------- директории ----------------
    mkdir -p /etc/vpn /etc/dnsmasq.d
    touch "$CUSTOM_FILE"

    # ---------------- создаём nftables set ----------------
    echo "Creating nftables set..."
    nft add table inet pbr 2>/dev/null || true
    nft add set inet pbr $PBR_SET '{ type ipv4_addr; flags interval; auto-merge; }' 2>/dev/null || true

    # ---------------- обновляем список доменов ----------------
    echo "Downloading base domains..."
    TEMP_LIST="/tmp/vpn_domains.txt"
    curl -s "$BASE_URL" > "$TEMP_LIST"

    if [ -f "$CUSTOM_FILE" ]; then
        echo "Adding custom domains..."
        cat "$CUSTOM_FILE" >> "$TEMP_LIST"
    fi

    # ---------------- создаём конфиг для dnsmasq ----------------
    echo "Creating dnsmasq configuration..."
    > /etc/dnsmasq.d/vpn_domains.conf

    while read -r DOMAIN; do
        # Пропускаем пустые строки и комментарии
        [ -z "$DOMAIN" ] && continue
        echo "$DOMAIN" | grep -q "^#" && continue
        
        # Формат: nftset=/domain/4#inet#pbr#setname
        echo "nftset=/$DOMAIN/4#inet#pbr#$PBR_SET" >> /etc/dnsmasq.d/vpn_domains.conf
    done < "$TEMP_LIST"

    DOMAIN_COUNT=$(grep -c '^nftset=' /etc/dnsmasq.d/vpn_domains.conf)
    echo "Added $DOMAIN_COUNT domains to configuration"

    # ---------------- настройка PBR через UCI ----------------
    echo "Configuring PBR..."
    
    # Базовая конфигурация PBR
    uci set pbr.config=pbr
    uci set pbr.config.enabled='1'
    uci set pbr.config.verbosity='2'
    uci set pbr.config.resolver_set='dnsmasq.nftset'
    uci set pbr.config.strict_enforcement='0'
    uci set pbr.config.boot_timeout='30'
    uci set pbr.config.ipv6_enabled='0'
    uci set pbr.config.nft_rule_counter='0'
    uci set pbr.config.nft_set_auto_merge='1'
    
    # Добавляем политику
    uci add pbr policy
    uci set pbr.@policy[-1].name='vpn_domains'
    uci set pbr.@policy[-1].interface="$VPN_IFACE"
    uci set pbr.@policy[-1].dest_addr="$PBR_SET.set"
    uci set pbr.@policy[-1].enabled='1'
    uci set pbr.@policy[-1].proto='all'
    uci set pbr.@policy[-1].chain='prerouting'
    
    uci commit pbr

    # ---------------- настройка маршрутизации ----------------
    echo "Configuring routing..."
    
    # Добавляем таблицу маршрутизации
    if ! grep -q '^200 vpn' /etc/iproute2/rt_tables 2>/dev/null; then
        echo "200 vpn" >> /etc/iproute2/rt_tables
    fi
    
    # Добавляем правило для маркированных пакетов (pbr использует марку 0x10000)
    ip rule add fwmark 0x10000 table vpn 2>/dev/null || true
    
    # Добавляем маршрут в таблице vpn
    ip route add table vpn default dev "$VPN_IFACE" 2>/dev/null || true

    # ---------------- скрипт обновления ----------------
    echo "Creating update script..."
    cat > /etc/vpn/update-pbr-domains.sh << EOF
#!/bin/sh
BASE_URL="$BASE_URL"
CUSTOM_FILE="$CUSTOM_FILE"
PBR_SET="$PBR_SET"
TEMP_LIST="/tmp/vpn_domains_updated.txt"

echo "Updating VPN domain list..."

# Скачиваем список
curl -s "\$BASE_URL" > "\$TEMP_LIST"

# Добавляем кастомные домены
if [ -f "\$CUSTOM_FILE" ]; then
    cat "\$CUSTOM_FILE" >> "\$TEMP_LIST"
fi

# Обновляем конфиг dnsmasq
> /etc/dnsmasq.d/vpn_domains.conf

while read -r DOMAIN; do
    [ -z "\$DOMAIN" ] && continue
    echo "\$DOMAIN" | grep -q "^#" && continue
    echo "nftset=/\$DOMAIN/4#inet#pbr#\$PBR_SET" >> /etc/dnsmasq.d/vpn_domains.conf
done < "\$TEMP_LIST"

# Перезапускаем dnsmasq
/etc/init.d/dnsmasq restart

# Перезапускаем PBR
/etc/init.d/pbr restart

echo "Domain list updated: \$(grep -c '^nftset=' /etc/dnsmasq.d/vpn_domains.conf) domains"

rm -f "\$TEMP_LIST"
EOF
    
    chmod +x /etc/vpn/update-pbr-domains.sh

    # ---------------- init скрипт для автообновления ----------------
    echo "Creating init script..."
    cat > /etc/init.d/update-vpn-domains << 'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=0

start() {
    /etc/vpn/update-pbr-domains.sh
    logger -t vpn-domains "Domain list updated via init"
}

stop() {
    logger -t vpn-domains "Update service stopped"
}
EOF
    
    chmod +x /etc/init.d/update-vpn-domains
    /etc/init.d/update-vpn-domains enable

    # ---------------- cron ----------------
    echo "Setting up cron..."
    (crontab -l 2>/dev/null | grep -v update-pbr-domains; \
     echo "0 */6 * * * /etc/vpn/update-pbr-domains.sh") | crontab -

    # ---------------- запуск ----------------
    echo "Starting services..."
    
    # Запускаем dnsmasq с новой конфигурацией
    /etc/init.d/dnsmasq restart
    
    # Запускаем PBR
    /etc/init.d/pbr enable
    /etc/init.d/pbr start
    
    # Запускаем cron
    /etc/init.d/cron restart

    # ---------------- проверка ----------------
    echo ""
    echo "✅ Setup complete!"
    echo ""
    echo "📊 Status check:"
    echo "  - nftables set: $(nft list set inet pbr $PBR_SET 2>/dev/null | grep -c '^[0-9]' || echo "empty")"
    echo "  - PBR status: $(/etc/init.d/pbr status 2>/dev/null | grep -c running || echo "checking...")"
    echo ""
    echo "📝 Useful commands:"
    echo "  - Manual update: /etc/vpn/update-pbr-domains.sh"
    echo "  - Add custom domains: $CUSTOM_FILE"
    echo "  - Check PBR rules: nft list chain inet pbr pbr_prerouting"
    echo "  - View logs: logread | grep -E '(pbr|vpn-domains)'"
    echo "  - Check routing: ip route show table vpn"
    echo ""
    echo "🔍 Debug if not working:"
    echo "  - Check nftables set: nft list sets inet pbr"
    echo "  - Check dnsmasq config: cat /etc/dnsmasq.d/vpn_domains.conf | head -5"
    echo "  - Restart services: /etc/init.d/dnsmasq restart; /etc/init.d/pbr restart"
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