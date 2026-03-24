#!/bin/sh

setup_dynamic_vpn() {
    local VPN_IFACE="wg0"
    local VPN_TABLE="vpn"
    local VPN_MARK="0x10000"
    local NFT_SET="vpn_domains"
    
    echo "=========================================="
    echo "Dynamic VPN Setup: dnsmasq + nftset"
    echo "Traffic to specific domains → WireGuard"
    echo "=========================================="
    
    # ========== 1. Установка пакетов ==========
    echo "1. Installing packages..."
    apk update
    apk add dnsmasq-full nftables curl
    
    # ========== 2. Создание директорий ==========
    echo "2. Creating directories..."
    mkdir -p /etc/dnsmasq.d
    mkdir -p /var/log
    mkdir -p /etc/nftables.d
    
    # ========== 3. Настройка таблицы маршрутизации ==========
    echo "3. Setting up routing table..."
    if ! grep -q "^200 $VPN_TABLE" /etc/iproute2/rt_tables; then
        echo "200 $VPN_TABLE" >> /etc/iproute2/rt_tables
    fi
    
    # Очищаем и добавляем маршрут
    ip route flush table $VPN_TABLE 2>/dev/null
    ip route add default dev "$VPN_IFACE" table $VPN_TABLE
    
    # Добавляем правило для маркированных пакетов
    ip rule del fwmark $VPN_MARK table $VPN_TABLE 2>/dev/null
    ip rule add fwmark $VPN_MARK table $VPN_TABLE priority 1000
    
    echo "✅ Routing configured"
    
    # ========== 4. Настройка nftables ==========
    echo "4. Configuring nftables..."
    
    # Очищаем и создаем таблицу
    nft flush ruleset 2>/dev/null
    nft add table inet fw4
    
    # Создаем nftset для VPN доменов (динамический)
    nft add set inet fw4 $NFT_SET '{ 
        type ipv4_addr; 
        flags dynamic, timeout; 
        timeout 1h; 
    }'
    
    # Создаем цепочки для маркировки на разных этапах
    nft add chain inet fw4 mangle_prerouting '{ 
        type filter hook prerouting priority -150; 
        policy accept; 
    }'
    
    nft add chain inet fw4 mangle_output '{ 
        type route hook output priority -150; 
        policy accept; 
    }'
    
    nft add chain inet fw4 mangle_forward '{ 
        type filter hook forward priority -150; 
        policy accept; 
    }'
    
    # Правила маркировки: все пакеты к IP из набора получают маркер
    nft add rule inet fw4 mangle_prerouting ip daddr @$NFT_SET meta mark set $VPN_MARK
    nft add rule inet fw4 mangle_output ip daddr @$NFT_SET meta mark set $VPN_MARK
    nft add rule inet fw4 mangle_forward ip daddr @$NFT_SET meta mark set $VPN_MARK
    
    echo "✅ nftables configured"
    
    # ========== 5. Настройка dnsmasq ==========
    echo "5. Configuring dnsmasq..."
    
    # Создаем список VPN доменов
    cat > /etc/dnsmasq.d/99-vpn-domains.conf << 'EOF'
# ============================================
# VPN DOMAINS - Traffic goes through WireGuard
# ============================================

# IP Checkers
nftset=/2ip.ru/4#inet#fw4#vpn_domains
nftset=/ifconfig.me/4#inet#fw4#vpn_domains
nftset=/ipinfo.io/4#inet#fw4#vpn_domains
nftset=/whatismyip.com/4#inet#fw4#vpn_domains

# Social Networks
nftset=/facebook.com/4#inet#fw4#vpn_domains
nftset=/instagram.com/4#inet#fw4#vpn_domains
nftset=/twitter.com/4#inet#fw4#vpn_domains
nftset=/x.com/4#inet#fw4#vpn_domains
nftset=/t.me/4#inet#fw4#vpn_domains
nftset=/telegram.org/4#inet#fw4#vpn_domains
nftset=/vk.com/4#inet#fw4#vpn_domains
nftset=/ok.ru/4#inet#fw4#vpn_domains

# Search Engines
nftset=/google.com/4#inet#fw4#vpn_domains
nftset=/yandex.ru/4#inet#fw4#vpn_domains
nftset=/bing.com/4#inet#fw4#vpn_domains
nftset=/duckduckgo.com/4#inet#fw4#vpn_domains

# Media
nftset=/youtube.com/4#inet#fw4#vpn_domains
nftset=/netflix.com/4#inet#fw4#vpn_domains
nftset=/rutube.ru/4#inet#fw4#vpn_domains
nftset=/kinopoisk.ru/4#inet#fw4#vpn_domains

# Development
nftset=/github.com/4#inet#fw4#vpn_domains
nftset=/gitlab.com/4#inet#fw4#vpn_domains
nftset=/docker.com/4#inet#fw4#vpn_domains
nftset=/hub.docker.com/4#inet#fw4#vpn_domains

# Torrents
nftset=/rutracker.org/4#inet#fw4#vpn_domains
nftset=/nnm-club.me/4#inet#fw4#vpn_domains
nftset=/kinozal.tv/4#inet#fw4#vpn_domains
nftset=/lostfilm.tv/4#inet#fw4#vpn_domains
EOF
    
    # Включаем логирование dnsmasq для отладки
    uci set dhcp.@dnsmasq[0].logqueries=1
    uci set dhcp.@dnsmasq[0].logfacility="/var/log/dnsmasq.log"
    uci commit dhcp
    
    echo "✅ dnsmasq configured with $(grep -c '^nftset=' /etc/dnsmasq.d/99-vpn-domains.conf) domains"
    
    # ========== 6. Создание файла для пользовательских доменов ==========
    cat > /etc/vpn-domains.custom << 'EOF'
# Add your custom domains here
# One domain per line
# Example:
# my-site.com
# *.my-domain.ru
EOF
    
    # ========== 7. Скрипт для управления доменами ==========
    cat > /usr/bin/vpn-domain << 'EOF'
#!/bin/sh

NFT_SET="vpn_domains"
CONFIG_FILE="/etc/dnsmasq.d/99-vpn-domains.conf"
CUSTOM_FILE="/etc/vpn-domains.custom"

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
            # Trigger DNS resolution
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
        echo "Dynamic VPN Status"
        echo "=========================================="
        IP_COUNT=$(nft list set inet fw4 "$NFT_SET" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | wc -l)
        echo "Active IPs in VPN set: $IP_COUNT"
        echo ""
        if [ $IP_COUNT -gt 0 ]; then
            echo "Recent IPs added (last 10):"
            nft list set inet fw4 "$NFT_SET" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -10
        fi
        echo ""
        echo "Configured domains: $(grep -c '^nftset=' "$CONFIG_FILE" 2>/dev/null)"
        echo ""
        echo "Routing:"
        ip rule show | grep fwmark
        ip route show table vpn 2>/dev/null
        ;;
    
    test)
        if [ -z "$2" ]; then
            echo "Usage: vpn-domain test example.com"
            exit 1
        fi
        echo "Testing domain: $2"
        echo ""
        echo "DNS Resolution:"
        nslookup "$2" 127.0.0.1
        echo ""
        sleep 2
        echo "Checking route to resolved IPs:"
        for ip in $(nslookup "$2" 127.0.0.1 2>/dev/null | grep "Address:" | tail -n +2 | awk '{print $2}'); do
            echo "  $ip: $(ip route get $ip 2>/dev/null | head -1)"
        done
        ;;
    
    monitor)
        echo "Monitoring DNS queries in real-time..."
        echo "Press Ctrl+C to stop"
        tail -f /var/log/dnsmasq.log | grep --line-buffered "nftset"
        ;;
    
    *)
        echo "Dynamic VPN Domain Manager"
        echo ""
        echo "Usage: vpn-domain {add|remove|list|status|test|monitor} [domain]"
        echo ""
        echo "Commands:"
        echo "  add DOMAIN     - Add domain to VPN routing"
        echo "  remove DOMAIN  - Remove domain from VPN routing"
        echo "  list           - List all configured VPN domains"
        echo "  status         - Show current VPN status (IPs, routes)"
        echo "  test DOMAIN    - Test domain resolution and routing"
        echo "  monitor        - Monitor DNS queries in real-time"
        echo ""
        echo "Examples:"
        echo "  vpn-domain add example.com"
        echo "  vpn-domain remove example.com"
        echo "  vpn-domain list"
        echo "  vpn-domain status"
        echo "  vpn-domain test google.com"
        echo "  vpn-domain monitor"
        ;;
esac
EOF
    
    chmod +x /usr/bin/vpn-domain
    
    # ========== 8. Запуск сервисов ==========
    echo "6. Starting services..."
    
    # Запускаем dnsmasq
    /etc/init.d/dnsmasq restart
    sleep 2
    
    # ========== 9. Сохранение правил nftables ==========
    echo "7. Saving nftables rules..."
    nft list ruleset > /etc/nftables.d/ruleset.nft
    
    # Создаем init скрипт для восстановления правил
    cat > /etc/init.d/nftables-vpn << 'EOF'
#!/bin/sh /etc/rc.common
START=45
STOP=90

start() {
    if [ -f /etc/nftables.d/ruleset.nft ]; then
        nft -f /etc/nftables.d/ruleset.nft
    fi
    ip rule add fwmark 0x10000 table vpn priority 1000 2>/dev/null
    ip route add default dev wg0 table vpn 2>/dev/null
}

stop() {
    nft flush ruleset
    ip rule del fwmark 0x10000 table vpn 2>/dev/null
    ip route flush table vpn 2>/dev/null
}
EOF
    
    chmod +x /etc/init.d/nftables-vpn
    /etc/init.d/nftables-vpn enable
    
    # ========== 10. Проверка ==========
    echo ""
    echo "=========================================="
    echo "VERIFICATION"
    echo "=========================================="
    
    echo "1. Routing table:"
    ip route show table vpn 2>/dev/null || echo "  No routes"
    
    echo ""
    echo "2. Routing rules:"
    ip rule show | grep fwmark
    
    echo ""
    echo "3. nftset:"
    nft list set inet fw4 $NFT_SET 2>/dev/null | head -10
    
    echo ""
    echo "4. Testing dynamic DNS..."
    nslookup 2ip.ru 127.0.0.1 > /dev/null 2>&1
    sleep 3
    
    IP_COUNT=$(nft list set inet fw4 $NFT_SET 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | wc -l)
    echo "  IPs in VPN set: $IP_COUNT"
    
    if [ $IP_COUNT -gt 0 ]; then
        echo "  ✅ Dynamic DNS working!"
        echo ""
        echo "  Sample IPs in VPN set:"
        nft list set inet fw4 $NFT_SET 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -5
    else
        echo "  ⚠️  No IPs yet. Check: tail -f /var/log/dnsmasq.log"
    fi
    
    echo ""
    echo "=========================================="
    echo "✅ Dynamic VPN Setup Complete!"
    echo "=========================================="
    echo ""
    echo "📊 Architecture:"
    echo "  1. DNS query → dnsmasq (127.0.0.1:53)"
    echo "  2. Domain match → IP added to nftset"
    echo "  3. nftables → mark packets with 0x10000"
    echo "  4. ip rule → packets to VPN table"
    echo "  5. VPN table → route through wg0"
    echo ""
    echo "Commands:"
    echo "  vpn-domain add example.com      # Add domain to VPN"
    echo "  vpn-domain remove example.com   # Remove domain"
    echo "  vpn-domain list                 # List all VPN domains"
    echo "  vpn-domain status               # Show status"
    echo "  vpn-domain test example.com     # Test domain"
    echo "  vpn-domain monitor              # Monitor DNS queries"
    echo ""
    echo "Monitor:"
    echo "  tail -f /var/log/dnsmasq.log    # DNS queries"
    echo "  watch -n 2 'vpn-domain status'  # Real-time status"
    echo ""
    echo "Test:"
    echo "  vpn-domain test 2ip.ru"
    echo "  curl --interface wg0 ifconfig.me  # VPN IP"
    echo "  curl ifconfig.me                   # WAN IP"
}

# Запускаем
setup_dynamic_vpn