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
    VPN_IFACE="wg0"
    PBR_SET="vpn_domains"
    
    echo "=========================================="
    echo "Setting up Split VPN Routing with PBR"
    echo "=========================================="
    echo "Base list: $BASE_URL"
    echo "Custom file: $CUSTOM_FILE"
    echo "VPN interface: $VPN_IFACE"
    echo ""
    
    # ---------------- проверка WireGuard ----------------
    echo "[1/7] Checking WireGuard interface..."
    if ! ip link show "$VPN_IFACE" >/dev/null 2>&1; then
        echo "❌ ERROR: Interface $VPN_IFACE not found!"
        echo "   Please configure WireGuard first."
        return 1
    fi
    echo "✅ Interface $VPN_IFACE exists"
    
    if ! ip link show "$VPN_IFACE" | grep -q "UP"; then
        echo "   Bringing up $VPN_IFACE..."
        ip link set "$VPN_IFACE" up
    fi
    echo "✅ Interface $VPN_IFACE is UP"
    
    # ---------------- пакеты ----------------
    echo ""
    echo "[2/7] Installing packages..."
    apk update
    # Пробуем разные варианты названия пакета dnscrypt
    apk add curl pbr dnsmasq-full nftables
    apk add dnscrypt-proxy 2>/dev/null || apk add dnscrypt-proxy2 2>/dev/null || echo "⚠️  dnscrypt-proxy not found, will use standard DNS"
    echo "✅ Packages installed"
    
    # ---------------- директории ----------------
    echo ""
    echo "[3/7] Creating directories..."
    mkdir -p /etc/vpn /etc/dnsmasq.d
    touch "$CUSTOM_FILE"
    echo "✅ Directories created"
    
    # ---------------- создаём nftables set ----------------
    echo ""
    echo "[4/7] Creating nftables set..."
    nft add table inet pbr 2>/dev/null || true
    nft add set inet pbr $PBR_SET '{ type ipv4_addr; flags interval; auto-merge; }' 2>/dev/null || true
    echo "✅ nftables set created"
    
    # ---------------- настройка dnscrypt-proxy (если установлен) ----------------
    echo ""
    echo "[5/7] Configuring DNS resolver..."
    
    # Проверяем, какой dnscrypt установлен
    if [ -f /etc/init.d/dnscrypt-proxy2 ]; then
        DNSCRYPT_INIT="dnscrypt-proxy2"
        DNSCRYPT_CONFIG="/etc/dnscrypt-proxy2/dnscrypt-proxy.toml"
        DNSCRYPT_DIR="/etc/dnscrypt-proxy2"
    elif [ -f /etc/init.d/dnscrypt-proxy ]; then
        DNSCRYPT_INIT="dnscrypt-proxy"
        DNSCRYPT_CONFIG="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
        DNSCRYPT_DIR="/etc/dnscrypt-proxy"
    else
        DNSCRYPT_INIT=""
        echo "   dnscrypt-proxy not installed, using standard DNS"
    fi
    
    if [ -n "$DNSCRYPT_INIT" ]; then
        echo "   Configuring $DNSCRYPT_INIT as upstream..."
        
        # Останавливаем сервисы
        /etc/init.d/dnsmasq stop 2>/dev/null
        /etc/init.d/$DNSCRYPT_INIT stop 2>/dev/null
        
        # Создаём конфиг для dnscrypt-proxy
        mkdir -p "$DNSCRYPT_DIR"
        cat > "$DNSCRYPT_CONFIG" << DNSCRYPT
listen_addresses = ['127.0.0.1:5353']
max_clients = 250
ipv4_servers = true
ipv6_servers = false
require_dns_over_https = true
require_nolog = true
require_nofilter = true
force_tcp = false
timeout = 2500
keepalive = 30
lb_strategy = 'p2'
log_level = 2
DNSCRYPT
        
        # Создаём файл с серверами
        echo "cloudflare" > "$DNSCRYPT_DIR/server_names.txt"
        
        # Настраиваем dnsmasq использовать dnscrypt-proxy
        uci set dhcp.@dnsmasq[0].noresolv='1'
        uci set dhcp.@dnsmasq[0].localuse='1'
        uci set dhcp.@dnsmasq[0].server='127.0.0.1#5353'
        uci commit dhcp
        
        echo "✅ $DNSCRYPT_INIT configured on port 5353"
    else
        # Используем стандартные DNS-серверы
        echo "   Using standard DNS servers (Cloudflare, Google)..."
        uci set dhcp.@dnsmasq[0].noresolv='1'
        uci set dhcp.@dnsmasq[0].localuse='1'
        uci set dhcp.@dnsmasq[0].server='1.1.1.1'
        uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
        uci commit dhcp
        echo "✅ Standard DNS configured"
    fi
    
    # ---------------- скачиваем и конвертируем домены ----------------
    echo ""
    echo "[6/7] Downloading and converting domain list..."
    TEMP_LIST="/tmp/vpn_domains.txt"
    
    echo "   Downloading from $BASE_URL ..."
    curl -s -o "$TEMP_LIST" "$BASE_URL"
    
    # Проверяем, что скачалось
    DOWNLOADED_COUNT=$(grep -c '^nftset=' "$TEMP_LIST" 2>/dev/null || echo "0")
    echo "   Downloaded $DOWNLOADED_COUNT entries from base URL"
    
    # Создаём конфиг dnsmasq: конвертируем fw4 -> pbr
    echo "   Converting fw4 -> pbr..."
    sed 's/#inet#fw4#vpn_domains/#inet#pbr#vpn_domains/g' "$TEMP_LIST" > /etc/dnsmasq.d/vpn_domains.conf
    
    # Добавляем кастомные домены
    if [ -f "$CUSTOM_FILE" ] && [ -s "$CUSTOM_FILE" ]; then
        echo "   Adding custom domains from $CUSTOM_FILE..."
        CUSTOM_COUNT=$(grep -v '^#' "$CUSTOM_FILE" | grep -v '^$' | wc -l)
        echo "   Adding $CUSTOM_COUNT custom domains"
        
        while read -r DOMAIN; do
            [ -z "$DOMAIN" ] && continue
            echo "$DOMAIN" | grep -q "^#" && continue
            DOMAIN=$(echo "$DOMAIN" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$DOMAIN" ] && continue
            echo "nftset=/$DOMAIN/4#inet#pbr#$PBR_SET" >> /etc/dnsmasq.d/vpn_domains.conf
        done < "$CUSTOM_FILE"
    fi
    
    # Удаляем дубликаты
    sort -u /etc/dnsmasq.d/vpn_domains.conf -o /etc/dnsmasq.d/vpn_domains.conf
    
    DOMAIN_COUNT=$(grep -c '^nftset=' /etc/dnsmasq.d/vpn_domains.conf)
    echo "✅ Added $DOMAIN_COUNT unique entries to configuration"
    
    # Показываем примеры
    echo ""
    echo "   📋 Example entries (first 3):"
    head -3 /etc/dnsmasq.d/vpn_domains.conf | sed 's/^/     /'
    
    # ---------------- настройка PBR ----------------
    echo ""
    echo "[7/7] Configuring PBR and routing..."
    
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
    option dest_addr '$PBR_SET.set'
    option enabled '1'
    option proto 'all'
    option chain 'prerouting'
PBRCONF
    
    # Таблица маршрутизации
    if ! grep -q '^200 vpn' /etc/iproute2/rt_tables 2>/dev/null; then
        echo "200 vpn" >> /etc/iproute2/rt_tables
    fi
    
    ip route add table vpn default dev "$VPN_IFACE" 2>/dev/null || true
    ip rule add fwmark 0x10000 table vpn 2>/dev/null || true
    
    echo "✅ PBR and routing configured"
    
    # ---------------- скрипт обновления ----------------
    cat > /etc/vpn/update-pbr-domains.sh << 'UPDATE'
#!/bin/sh
BASE_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
CUSTOM_FILE="/etc/vpn/domains.lst"
PBR_SET="vpn_domains"
TEMP_LIST="/tmp/vpn_domains_updated.txt"

echo "Updating VPN domain list..."

curl -s -o "$TEMP_LIST" "$BASE_URL"

# Конвертируем fw4 -> pbr
sed 's/#inet#fw4#vpn_domains/#inet#pbr#vpn_domains/g' "$TEMP_LIST" > /etc/dnsmasq.d/vpn_domains.conf

# Добавляем кастомные домены
if [ -f "$CUSTOM_FILE" ]; then
    while read -r DOMAIN; do
        [ -z "$DOMAIN" ] && continue
        echo "$DOMAIN" | grep -q "^#" && continue
        DOMAIN=$(echo "$DOMAIN" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$DOMAIN" ] && continue
        echo "nftset=/$DOMAIN/4#inet#pbr#$PBR_SET" >> /etc/dnsmasq.d/vpn_domains.conf
    done < "$CUSTOM_FILE"
fi

# Удаляем дубликаты
sort -u /etc/dnsmasq.d/vpn_domains.conf -o /etc/dnsmasq.d/vpn_domains.conf

/etc/init.d/dnsmasq restart
/etc/init.d/pbr restart

echo "Domain list updated: $(grep -c '^nftset=' /etc/dnsmasq.d/vpn_domains.conf) domains"

rm -f "$TEMP_LIST"
UPDATE
    
    chmod +x /etc/vpn/update-pbr-domains.sh
    
    # ---------------- hotplug скрипт ----------------
    mkdir -p /etc/hotplug.d/iface
    cat > /etc/hotplug.d/iface/90-pbr-wg << HOTPLUG
#!/bin/sh
if [ "\$INTERFACE" = "$VPN_IFACE" ]; then
    logger -t pbr "Interface $VPN_IFACE \$ACTION, reloading..."
    /etc/init.d/pbr restart
fi
HOTPLUG
    chmod +x /etc/hotplug.d/iface/90-pbr-wg
    
    # ---------------- cron ----------------
    (crontab -l 2>/dev/null | grep -v update-pbr-domains; \
     echo "0 */6 * * * /etc/vpn/update-pbr-domains.sh") | crontab - 2>/dev/null
    
    # ---------------- перезапуск сервисов ----------------
    echo ""
    echo "Starting services..."
    
    # Запускаем dnscrypt-proxy если установлен
    if [ -n "$DNSCRYPT_INIT" ]; then
        /etc/init.d/$DNSCRYPT_INIT start
        sleep 2
    fi
    
    # Запускаем dnsmasq
    /etc/init.d/dnsmasq start
    
    # Запускаем PBR
    /etc/init.d/pbr enable
    /etc/init.d/pbr restart
    
    /etc/init.d/cron restart 2>/dev/null || true
    
    # ---------------- финальная проверка ----------------
    echo ""
    echo "=========================================="
    echo "✅ Setup Complete!"
    echo "=========================================="
    echo ""
    echo "📊 DNS Architecture:"
    echo "  LAN Clients (192.168.2.0/24)"
    echo "       ↓"
    echo "  dnsmasq :53 (nftset + forwarding)"
    if [ -n "$DNSCRYPT_INIT" ]; then
        echo "       ↓"
        echo "  $DNSCRYPT_INIT :5353 (DNS-over-HTTPS)"
    else
        echo "       ↓"
        echo "  Upstream DNS: 1.1.1.1, 8.8.8.8"
    fi
    echo ""
    echo "📊 Service Status:"
    /etc/init.d/pbr status
    echo ""
    echo "📁 Config files:"
    echo "  - Domains config:  /etc/dnsmasq.d/vpn_domains.conf ($DOMAIN_COUNT entries)"
    echo "  - Custom domains:  $CUSTOM_FILE"
    echo ""
    echo "📌 ADD CUSTOM DOMAINS:"
    echo "  echo 'telegram.org' >> $CUSTOM_FILE"
    echo "  /etc/vpn/update-pbr-domains.sh"
    echo ""
    echo "📝 Commands:"
    echo "  Update domains:     /etc/vpn/update-pbr-domains.sh"
    echo "  Check nftables set: nft list set inet pbr $PBR_SET"
    echo "  Check DNS ports:    netstat -tulpn | grep :53"
    echo ""
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