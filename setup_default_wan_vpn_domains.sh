#!/bin/sh

setup_default_wan_vpn_domains() {
    local VPN_IFACE="wg0"
    local WAN_IFACE="wan"
    local VPN_TABLE="vpn"
    local VPN_MARK="0x10000"
    local NFT_SET="vpn_domains"
    
    echo "=========================================="
    echo "Setup: Default WAN, Specific Domains → WG"
    echo "=========================================="
    
    # ========== ШАГ 1: Проверка интерфейсов ==========
    echo "1. Checking interfaces..."
    if ! ip link show "$VPN_IFACE" >/dev/null 2>&1; then
        echo "❌ ERROR: $VPN_IFACE not found!"
        return 1
    fi
    
    if ! ip link show "$WAN_IFACE" >/dev/null 2>&1; then
        echo "⚠️  WARNING: $WAN_IFACE not found, using default route"
        WAN_IFACE=$(ip route show default | grep -o 'dev [^ ]*' | cut -d' ' -f2 | head -1)
        echo "  Using $WAN_IFACE as WAN interface"
    fi
    
    echo "✅ VPN: $VPN_IFACE, WAN: $WAN_IFACE"
    
    # ========== ШАГ 2: Установка пакетов ==========
    echo "2. Installing packages..."
    apk update
    apk add pbr dnsmasq-full nftables curl
    
    # ========== ШАГ 3: Создание необходимых директорий ==========
    echo "3. Creating directories..."
    mkdir -p /etc/pbr
    mkdir -p /etc/dnsmasq.d
    mkdir -p /usr/local/bin
    mkdir -p /var/log
    
    # ========== ШАГ 4: Остановка сервисов ==========
    echo "4. Stopping services..."
    /etc/init.d/pbr stop 2>/dev/null
    /etc/init.d/dnsmasq stop 2>/dev/null
    
    # ========== ШАГ 5: Настройка таблицы маршрутизации ==========
    echo "5. Setting up VPN routing table..."
    
    # Добавляем таблицу маршрутизации
    if ! grep -q "^200 $VPN_TABLE" /etc/iproute2/rt_tables; then
        echo "200 $VPN_TABLE" >> /etc/iproute2/rt_tables
    fi
    
    # Очищаем таблицу
    ip route flush table $VPN_TABLE 2>/dev/null
    
    # Добавляем маршрут по умолчанию через VPN в отдельную таблицу
    ip route add default dev "$VPN_IFACE" table $VPN_TABLE
    
    echo "✅ VPN routing table created"
    
    # ========== ШАГ 6: Проверка основного маршрута ==========
    echo "6. Verifying default route through WAN..."
    DEFAULT_ROUTE=$(ip route show default | grep -v "table" | head -1)
    if [ -z "$DEFAULT_ROUTE" ]; then
        echo "⚠️  No default route found, please check WAN connection"
    else
        echo "  Default route: $DEFAULT_ROUTE"
    fi
    
    # ========== ШАГ 7: Создание nftables set ==========
    echo "7. Creating nftables set..."
    nft add table inet fw4 2>/dev/null || true
    nft delete set inet fw4 "$NFT_SET" 2>/dev/null || true
    nft add set inet fw4 "$NFT_SET" '{ type ipv4_addr; flags dynamic; }'
    echo "✅ nftset created: $NFT_SET"
    
    # ========== ШАГ 8: Настройка правил маршрутизации ==========
    echo "8. Setting up routing rules..."
    
    # Удаляем старые правила
    ip rule del fwmark $VPN_MARK table $VPN_TABLE 2>/dev/null
    ip rule del priority 1000 2>/dev/null
    
    # Добавляем правило: пакеты с маркером идут в таблицу VPN
    ip rule add fwmark $VPN_MARK table $VPN_TABLE priority 1000
    
    echo "✅ Routing rule added"
    
    # ========== ШАГ 9: Настройка PBR ==========
    echo "9. Configuring PBR..."

    rm -f /etc/config/pbr
    rm -f /tmp/pbr_*
    
    # Создаем чистую конфигурацию PBR
    cat > /etc/config/pbr << EOF
config pbr 'config'
    option enabled '1'
    option verbosity '2'
    option resolver_set 'dnsmasq.nftset'
    option strict_enforcement '0'
    option boot_timeout '30'
    option ipv6_enabled '0'

config interface
    option name 'vpn'
    option enabled '1'
    option interface '$VPN_IFACE'
    option table '$VPN_TABLE'
    option fwmark '$VPN_MARK'
    option priority '1000'

config policy
    option name 'vpn_domains'
    option interface 'vpn'
    option enabled '1'
    option lookup '$VPN_TABLE'
    option priority '100'
    option nftset '4#inet#fw4#$NFT_SET'
    option proto 'all'
    option src_addr ''
    option dest_addr ''
EOF
    
    echo "✅ PBR configured"
    
    # ========== ШАГ 10: Настройка dnsmasq ==========
    echo "10. Configuring dnsmasq..."
    
    # Создаем конфигурацию для VPN доменов
    cat > /etc/dnsmasq.d/99-vpn-domains.conf << 'EOF'
nftset=/2ip.ru/4#inet#fw4#vpn_domains
nftset=/ifconfig.me/4#inet#fw4#vpn_domains
nftset=/ipinfo.io/4#inet#fw4#vpn_domains
nftset=/facebook.com/4#inet#fw4#vpn_domains
nftset=/instagram.com/4#inet#fw4#vpn_domains
nftset=/twitter.com/4#inet#fw4#vpn_domains
nftset=/x.com/4#inet#fw4#vpn_domains
nftset=/t.me/4#inet#fw4#vpn_domains
nftset=/telegram.org/4#inet#fw4#vpn_domains
nftset=/vk.com/4#inet#fw4#vpn_domains
nftset=/ok.ru/4#inet#fw4#vpn_domains
nftset=/google.com/4#inet#fw4#vpn_domains
nftset=/yandex.ru/4#inet#fw4#vpn_domains
nftset=/bing.com/4#inet#fw4#vpn_domains
nftset=/youtube.com/4#inet#fw4#vpn_domains
nftset=/netflix.com/4#inet#fw4#vpn_domains
nftset=/rutube.ru/4#inet#fw4#vpn_domains
nftset=/github.com/4#inet#fw4#vpn_domains
nftset=/gitlab.com/4#inet#fw4#vpn_domains
nftset=/docker.com/4#inet#fw4#vpn_domains
nftset=/rutracker.org/4#inet#fw4#vpn_domains
nftset=/nnm-club.me/4#inet#fw4#vpn_domains
nftset=/kinozal.tv/4#inet#fw4#vpn_domains
EOF
    
    # ========== ШАГ 11: Создание файла для пользовательских доменов ==========
    cat > /etc/pbr/custom_domains.txt << 'EOF'
# Add your custom domains here
# One domain per line
# Example:
# my-site.com
# *.my-domain.ru
EOF
    
    # ========== ШАГ 12: Добавление пользовательских доменов ==========
    echo "11. Adding custom domains..."
    
    if [ -f /etc/pbr/custom_domains.txt ]; then
        while IFS= read -r domain || [ -n "$domain" ]; do
            echo "$domain" | grep -q '^#' && continue
            [ -z "$domain" ] && continue
            domain=$(echo "$domain" | xargs)
            [ -z "$domain" ] && continue
            
            if ! grep -q "nftset=/$domain/" /etc/dnsmasq.d/99-vpn-domains.conf 2>/dev/null; then
                echo "nftset=/$domain/4#inet#fw4#$NFT_SET" >> /etc/dnsmasq.d/99-vpn-domains.conf
                echo "  Added: $domain"
            fi
        done < /etc/pbr/custom_domains.txt
    fi
    
    # Убираем дубликаты
    sort -u /etc/dnsmasq.d/99-vpn-domains.conf -o /etc/dnsmasq.d/99-vpn-domains.conf
    
    DOMAIN_COUNT=$(grep -c '^nftset=' /etc/dnsmasq.d/99-vpn-domains.conf 2>/dev/null || echo "0")
    echo "✅ Total domains configured: $DOMAIN_COUNT"
    
    # ========== ШАГ 13: Включение логирования ==========
    echo "12. Enabling logging..."
    uci set dhcp.@dnsmasq[0].logqueries=1
    uci set dhcp.@dnsmasq[0].logfacility="/var/log/dnsmasq.log"
    uci commit dhcp
    
    # ========== ШАГ 14: Запуск сервисов в правильном порядке ==========
    echo "13. Starting services..."
    
    # Сначала запускаем dnsmasq
    /etc/init.d/dnsmasq start
    sleep 3
    
    # Затем запускаем PBR
    /etc/init.d/pbr start
    sleep 3
    
    # ========== ШАГ 15: Создание скрипта управления ==========
    echo "14. Creating management script..."
    
    cat > /usr/local/bin/vpn-domain << 'EOF'
#!/bin/sh

NFT_SET="vpn_domains"
CONFIG_FILE="/etc/dnsmasq.d/99-vpn-domains.conf"

case "$1" in
    add)
        if [ -z "$2" ]; then
            echo "Usage: vpn-domain add example.com"
            exit 1
        fi
        if grep -q "nftset=/$2/" "$CONFIG_FILE" 2>/dev/null; then
            echo "⚠️  Domain $2 already exists"
        else
            echo "nftset=/$2/4#inet#fw4#$NFT_SET" >> "$CONFIG_FILE"
            sort -u "$CONFIG_FILE" -o "$CONFIG_FILE"
            /etc/init.d/dnsmasq restart
            echo "✅ Added: $2"
            nslookup "$2" 127.0.0.1 > /dev/null 2>&1
        fi
        ;;
    
    remove)
        if [ -z "$2" ]; then
            echo "Usage: vpn-domain remove example.com"
            exit 1
        fi
        sed -i "/nftset=\/$2\//d" "$CONFIG_FILE"
        /etc/init.d/dnsmasq restart
        echo "✅ Removed: $2"
        ;;
    
    list)
        echo "VPN domains:"
        grep '^nftset=' "$CONFIG_FILE" 2>/dev/null | sed 's/nftset=\///' | sed 's/\/4#inet#fw4.*//' | sort
        ;;
    
    status)
        echo "=========================================="
        echo "VPN Domain Status"
        echo "=========================================="
        IP_COUNT=$(nft list set inet fw4 "$NFT_SET" 2>/dev/null | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' | wc -l)
        echo "Active IPs in VPN set: $IP_COUNT"
        echo ""
        if [ $IP_COUNT -gt 0 ]; then
            echo "Last 10 IPs added:"
            nft list set inet fw4 "$NFT_SET" 2>/dev/null | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -10
        fi
        echo ""
        echo "Configured domains: $(grep -c '^nftset=' "$CONFIG_FILE" 2>/dev/null)"
        ;;
    
    test)
        if [ -z "$2" ]; then
            echo "Usage: vpn-domain test example.com"
            exit 1
        fi
        echo "Testing domain: $2"
        echo ""
        nslookup "$2" 127.0.0.1
        echo ""
        sleep 2
        IP_COUNT=$(nft list set inet fw4 "$NFT_SET" 2>/dev/null | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' | wc -l)
        echo "Total IPs in VPN set: $IP_COUNT"
        ;;
    
    route)
        if [ -z "$2" ]; then
            echo "Usage: vpn-domain route example.com"
            exit 1
        fi
        IP=$(nslookup "$2" 127.0.0.1 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')
        if [ -n "$IP" ]; then
            echo "IP: $IP"
            ip route get "$IP"
        else
            echo "Could not resolve domain"
        fi
        ;;
    
    *)
        echo "VPN Domain Manager for WireGuard"
        echo ""
        echo "Usage: vpn-domain {add|remove|list|status|test|route} [domain]"
        echo ""
        echo "Commands:"
        echo "  add DOMAIN     - Add domain to VPN routing"
        echo "  remove DOMAIN  - Remove domain from VPN routing"
        echo "  list           - List all VPN domains"
        echo "  status         - Show active IPs in VPN set"
        echo "  test DOMAIN    - Test domain resolution"
        echo "  route DOMAIN   - Show route for domain IP"
        echo ""
        echo "Examples:"
        echo "  vpn-domain add example.com"
        echo "  vpn-domain remove example.com"
        echo "  vpn-domain list"
        echo "  vpn-domain status"
        echo "  vpn-domain test google.com"
        echo "  vpn-domain route rutracker.org"
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/vpn-domain
    
    # ========== ШАГ 16: Проверка работы ==========
    echo ""
    echo "=========================================="
    echo "VERIFICATION"
    echo "=========================================="
    
    echo "1. Default route (WAN):"
    ip route show default | grep -v "table" | head -1
    
    echo ""
    echo "2. VPN routing table:"
    ip route show table vpn 2>/dev/null || echo "  No routes"
    
    echo ""
    echo "3. Routing rules:"
    ip rule show | grep -E "(fwmark|vpn)"
    
    echo ""
    echo "4. Testing DNS resolution..."
    echo "  Resolving 2ip.ru..."
    nslookup 2ip.ru 127.0.0.1 > /dev/null 2>&1
    
    echo "  Waiting for IPs to be added..."
    sleep 5
    
    IP_COUNT=$(nft list set inet fw4 $NFT_SET 2>/dev/null | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' | wc -l)
    echo "  IPs in VPN set: $IP_COUNT"
    
    if [ $IP_COUNT -gt 0 ]; then
        echo "  ✅ VPN set contains IP addresses"
        echo ""
        echo "  Sample IPs:"
        nft list set inet fw4 $NFT_SET 2>/dev/null | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -5
        
        echo ""
        echo "  Testing route for first IP:"
        TEST_IP=$(nft list set inet fw4 $NFT_SET 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        if [ -n "$TEST_IP" ]; then
            ip route get "$TEST_IP"
        fi
    else
        echo "  ⚠️  No IPs in VPN set yet"
        echo ""
        echo "  Check dnsmasq logs:"
        tail -5 /var/log/dnsmasq.log 2>/dev/null || echo "  No logs yet"
        echo ""
        echo "  Try manual test: vpn-domain test 2ip.ru"
    fi
    
    echo ""
    echo "=========================================="
    echo "✅ Setup Complete!"
    echo "=========================================="
    echo ""
    echo "📊 Default routing: ALL traffic → WAN"
    echo "🔒 VPN routing: Only specified domains → WireGuard"
    echo ""
    echo "Management commands:"
    echo "  vpn-domain add example.com      # Add domain to VPN"
    echo "  vpn-domain remove example.com   # Remove domain"
    echo "  vpn-domain list                 # List all VPN domains"
    echo "  vpn-domain status               # Show active IPs"
    echo "  vpn-domain test example.com     # Test domain"
    echo "  vpn-domain route example.com    # Check route"
    echo ""
    echo "Monitor:"
    echo "  tail -f /var/log/dnsmasq.log    # DNS queries"
    echo "  watch -n 2 'vpn-domain status'  # IPs in VPN set"
    echo ""
    echo "Test VPN routing:"
    echo "  curl --interface wg0 ifconfig.me  # Should show VPN IP"
    echo "  curl ifconfig.me                   # Should show WAN IP"
}

# Запускаем функцию
setup_default_wan_vpn_domains