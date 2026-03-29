#1. Создаём набор для VPN IP---------------------------------------------

# Создаём файл с набором
cat > /etc/nftables.d/90-vpnset.nft << 'EOF'
add table inet fw4
add set inet fw4 vpn_domains { type ipv4_addr; flags interval,timeout; timeout 1h; auto-merge; }
EOF

# Применяем
nft -f /etc/nftables.d/90-vpnset.nft

#2. Настраиваем dnsmasq для добавления IP в набор--------------------------

if apk info --installed dnsmasq-full >/dev/null 2>&1; then
        echo "✓ dnsmasq-full already installed"
    else
        echo "Installing dnsmasq-full..."
        apk update
        apk del dnsmasq
        apk add dnsmasq-full || return 1
    fi

# Создаём конфигурацию dnsmasq
mkdir -p /tmp/dnsmasq.d

# Настраиваем dnsmasq через UCI
uci set dhcp.@dnsmasq[0].nftset='1'
uci add_list dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
uci commit dhcp

# Перезапускаем dnsmasq
/etc/init.d/dnsmasq restart

#3. Добавляем маркировку трафика-------------------------------------------------

# Создаём файл с правилами маркировки
cat > /etc/nftables.d/91-vpn-mark.nft << 'EOF'
add rule inet fw4 mangle_output ip daddr @vpn_domains meta mark set 0x1
add rule inet fw4 mangle_prerouting ip daddr @vpn_domains meta mark set 0x1
EOF

# Применяем
nft -f /etc/nftables.d/91-vpn-mark.nft

#4. Настраиваем таблицу маршрутизации --------------------------------------------------------

# Добавляем таблицу маршрутизации
echo "100 vpn" >> /etc/iproute2/rt_tables

# Добавляем маршрут через wg0 в таблицу vpn
ip route add default dev wg0 table vpn

# Добавляем правило для маркированного трафика
ip rule add fwmark 0x1 lookup vpn priority 

#5. Делаем настройки постоянными через UCI-----------------------------------------------

# Сохраняем маршрут
uci add network route
uci set network.@route[-1].interface='wg0'
uci set network.@route[-1].target='0.0.0.0/0'
uci set network.@route[-1].table='100'
uci commit network

# Сохраняем правило
uci add network rule
uci set network.@rule[-1].name='vpn_traffic'
uci set network.@rule[-1].mark='0x1'
uci set network.@rule[-1].priority='100'
uci set network.@rule[-1].lookup='100'
uci commit network

#6. Проверяем работу-----------------------------------------------------------------

# 1. Проверяем набор
nft list set inet fw4 vpn_domains

# 2. Запрашиваем домен (должен добавиться IP в набор)
nslookup yandex.ru

# 3. Проверяем что IP добавился в набор
nft list set inet fw4 vpn_domains | grep -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'

# 4. Получаем IP yandex
YANDEX_IP=$(nslookup yandex.ru 127.0.0.1 | grep "Address 1" | tail -1 | awk '{print $3}')

# 5. Проверяем маршрут
ip route get $YANDEX_IP

# 6. Тестируем пинг
ping -c 2 $YANDEX_IP