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
    
    # ========== ШАГ 2: Установка пакетов (apk для OpenWrt 25) ==========
    echo "2. Installing packages..."
    apk update
    apk add pbr dnsmasq-full nftables curl
    
    # ========== ШАГ 3: Создание необходимых директорий ==========
    echo "3. Creating directories..."
    mkdir -p /etc/pbr
    mkdir -p /etc/dnsmasq.d
    mkdir -p /usr/local/bin
    mkdir -p /var/log
    
    # ========== ШАГ 4: Настройка таблицы маршрутизации ==========
    echo "4. Setting up VPN routing table..."
    
    # Добавляем таблицу маршрутизации
    if ! grep -q "^200 $VPN_TABLE" /etc/iproute2/rt_tables; then
        echo "200 $VPN_TABLE" >> /etc/iproute2/rt_tables
    fi
    
    # Очищаем таблицу
    ip route flush table $VPN_TABLE 2>/dev/null
    
    # Добавляем маршрут по умолчанию через VPN в отдельную таблицу
    ip route add default dev "$VPN_IFACE" table $VPN_TABLE
    
    echo "✅ VPN routing table created"
    
    # ========== ШАГ 5: Проверка основного маршрута через WAN ==========
    echo "5. Verifying default route through WAN..."
    
    DEFAULT_ROUTE=$(ip route show default | grep -v "table" | head -1)
    if [ -z "$DEFAULT_ROUTE" ]; then
        echo "⚠️  No default route found, please check WAN connection"
    else
        echo "  Default route: $DEFAULT_ROUTE"
    fi
    
    # ========== ШАГ 6: Создание nftables set ==========
    echo "6. Creating nftables set..."
    nft add table inet fw4 2>/dev/null || true
    nft delete set inet fw4 "$NFT_SET" 2>/dev/null || true
    nft add set inet fw4 "$NFT_SET" '{ type ipv4_addr; flags dynamic; }'
    echo "✅ nftset created: $NFT_SET"
    
    # ========== ШАГ 7: Настройка PBR ==========
    echo "7. Configuring PBR..."
    
    # Очищаем старую конфигурацию
    uci delete pbr 2>/dev/null
    
    # Базовая конфигурация через UCI
    uci set pbr.config="pbr"
    uci set pbr.config.enabled="1"
    uci set pbr.config.verbosity="2"
    uci set pbr.config.resolver_set="dnsmasq.nftset"
    uci set pbr.config.strict_enforcement="0"
    uci set pbr.config.boot_timeout="30"
    uci set pbr.config.ipv6_enabled="0"
    
    # Настройка интерфейса VPN (wg0)
    uci add pbr interface
    uci set pbr.@interface[-1].name="wireguard"
    uci set pbr.@interface[-1].enabled="1"
    uci set pbr.@interface[-1].interface="$VPN_IFACE"
    uci set pbr.@interface[-1].table="$VPN_TABLE"
    uci set pbr.@interface[-1].fwmark="$VPN_MARK"
    uci set pbr.@interface[-1].priority="1000"
    uci set pbr.@interface[-1].metric="100"
    
    # Политика для доменов (только они идут через VPN)
    uci add pbr policy
    uci set pbr.@policy[-1].name="vpn_domains"
    uci set pbr.@policy[-1].interface="wireguard"
    uci set pbr.@policy[-1].enabled="1"
    uci set pbr.@policy[-1].lookup="$VPN_TABLE"
    uci set pbr.@policy[-1].priority="100"
    uci set pbr.@policy[-1].proto="all"
    uci set pbr.@policy[-1].nftset="4#inet#fw4#$NFT_SET"
    
    uci commit pbr
    
    echo "✅ PBR configured"
    
    # ========== ШАГ 8: Настройка правил маршрутизации ==========
    echo "8. Setting up routing rules..."
    
    # Удаляем старые правила
    ip rule del fwmark $VPN_MARK table $VPN_TABLE 2>/dev/null
    
    # Добавляем правило: пакеты с маркером идут в таблицу VPN
    ip rule add fwmark $VPN_MARK table $VPN_TABLE priority 1000
    
    echo "✅ Routing rule added: packets with mark $VPN_MARK → table $VPN_TABLE"
    
    # ========== ШАГ 9: Настройка dnsmasq ==========
    echo "9. Configuring dnsmasq..."
    
    # Создаем конфигурацию для VPN доменов
    cat > /etc/dnsmasq.d/99-vpn-domains.conf << 'EOF'
# VPN Domains - Traffic through WireGuard
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
    
    # ========== ШАГ 10: Создание файла для пользовательских доменов ==========
    cat > /etc/pbr/custom_domains.txt << 'EOF'
# Add your custom domains here
# One domain per line
# Example:
# my-site.com
# *.my-domain.ru
EOF
    
    # ========== ШАГ 11: Добавление пользовательских доменов ==========
    echo "10. Adding custom domains..."
    
    if [ -f /etc/pbr/custom_domains.txt ]; then
        while IFS= read -r domain || [ -n "$domain" ]; do
            # Пропускаем комментарии и пустые строки
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
    
    # ========== ШАГ 12: Включение логирования ==========
    echo "11. Enabling logging..."
    uci set dhcp.@dnsmasq[0].logqueries=1
    uci set dhcp.@dnsmasq[0].logfacility="/var/log/dnsmasq.log"
    uci commit dhcp
    
    # ========== ШАГ 13: Запуск сервисов ==========
    echo "12. Starting services..."
    
    /etc/init.d/dnsmasq restart
    sleep 2
    
    /etc/init.d/pbr enable
    /etc/init.d/pbr restart
    sleep 3
    
    # ========== ШАГ 14: Создание скрипта для управления доменами ==========
    echo "13. Creating management script..."
    
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
            echo "  Testing resolution..."
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
        echo "Last 10 IPs added:"
        nft list set inet fw4 "$NFT_SET" 2>/dev/null | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -10
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
        echo "Checking if IPs added to VPN set..."
        IP_COUNT=$(nft list set inet fw4 "$NFT_SET" 2>/dev/null | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' | wc -l)
        echo "Total IPs in VPN set: $IP_COUNT"
        ;;
    
    route)
        if [ -z "$2" ]; then
            echo "Usage: vpn-domain route example.com"
            exit 1
        fi
        echo "Checking route for domain: $2"
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
    
    # ========== ШАГ 15: Проверка ==========
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
    echo "4. PBR status:"
    /etc/init.d/pbr status | head -5
    
    echo ""
    echo "5. Testing domain resolution..."
    echo "  Resolving 2ip.ru (VPN domain)..."
    nslookup 2ip.ru 127.0.0.1 > /dev/null 2>&1
    sleep 2
    
    IP_COUNT=$(nft list set inet fw4 $NFT_SET 2>/dev/null | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' | wc -l)
    echo "  IPs in VPN set: $IP_COUNT"
    
    if [ $IP_COUNT -gt 0 ]; then
        echo "  ✅ VPN set contains IP addresses"
        echo ""
        echo "  Sample IPs:"
        nft list set inet fw4 $NFT_SET 2>/dev/null | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -5
    else
        echo "  ⚠️  No IPs in VPN set yet"
        echo "  Check: tail -f /var/log/dnsmasq.log"
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
