#1. Создаём набор для VPN IP---------------------------------------------

# Создаём файл с набором
cat > /etc/nftables.d/90-vpnset.nft << 'EOF'
set vpn_domains {
    type ipv4_addr
    flags interval, timeout
    timeout 1h
    auto-merge
}
EOF

# Применяем
/etc/init.d/firewall restart

#Проверка:
nft list set inet fw4 vpn_domains

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
mkdir -p /etc/dnsmasq.d

# Настраиваем dnsmasq через UCI
uci set dhcp.@dnsmasq[0].nftset='1'
uci add_list dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
uci commit dhcp

# Перезапускаем dnsmasq
/etc/init.d/dnsmasq restart

#3. Добавляем маркировку трафика-------------------------------------------------

cat > /etc/nftables.d/91-vpn-mark.nft << 'EOF'
chain vpn_mark_prerouting {
    type filter hook prerouting priority mangle; policy accept;
    ip daddr @vpn_domains meta mark set 0x1
}

chain vpn_mark_output {
    type filter hook output priority mangle; policy accept;
    ip daddr @vpn_domains meta mark set 0x1
}
EOF


/etc/init.d/firewall restart

#4. Настраиваем таблицу маршрутизации --------------------------------------------------------

# Добавляем таблицу маршрутизации
echo "100 vpn" >> /etc/iproute2/rt_tables

/etc/init.d/network restart
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