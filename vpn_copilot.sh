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

# iproute2-full нужен для ip rule / ip route table
apk add iproute2
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

echo "=== 1. Включаем поддержку кастомных nft-файлов ==="
uci set firewall.@defaults[0].include_config='1'
uci commit firewall

echo "=== 2. Настраиваем dnsmasq для nftset ==="
mkdir -p /etc/dnsmasq.d
uci set dhcp.@dnsmasq[0].nftset='1'
uci add_list dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
uci commit dhcp
/etc/init.d/dnsmasq restart

echo "=== 3. Создаём nft-набор vpn_domains ==="
cat > /etc/nftables.d/90-vpnset.nft << 'EOF'
table inet fw4 {
    set vpn_domains {
        type ipv4_addr
        flags interval, timeout
        timeout 1h
        auto-merge
    }
}
EOF

echo "=== 4. Добавляем правила маркировки трафика ==="
cat > /etc/nftables.d/91-vpn-mark.nft << 'EOF'
table inet fw4 {
    chain mangle_output {
        ip daddr @vpn_domains meta mark set 0x1
    }

    chain mangle_prerouting {
        ip daddr @vpn_domains meta mark set 0x1
    }
}
EOF

echo "=== 5. Добавляем таблицу маршрутизации ==="
grep -q "^100 vpn" /etc/iproute2/rt_tables || echo "100 vpn" >> /etc/iproute2/rt_tables

echo "=== 6. Создаём постоянный маршрут через wg0 ==="
uci add network route
uci set network.@route[-1].interface='wg0'
uci set network.@route[-1].target='0.0.0.0/0'
uci set network.@route[-1].table='100'
uci commit network

echo "=== 7. Создаём постоянное правило fwmark ==="
uci add network rule
uci set network.@rule[-1].name='vpn_traffic'
uci set network.@rule[-1].mark='0x1'
uci set network.@rule[-1].priority='100'
uci set network.@rule[-1].lookup='100'
uci commit network

echo "=== 8. Перезапускаем firewall и сеть ==="
/etc/init.d/firewall restart
/etc/init.d/network restart

echo "=== Готово! Перезагрузи роутер и протестируй ==="
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
        ;;
    *)
        echo "Invalid option"
        ;;
esac
