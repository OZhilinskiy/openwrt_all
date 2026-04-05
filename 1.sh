# Создаём файл с набором
uci add firewall ipset
uci set firewall.@ipset[-1].name='vpn_domains'
uci set firewall.@ipset[-1].family='ipv4'
uci set firewall.@ipset[-1].match='dst_net'
uci set firewall.@ipset[-1].timeout='3600'
uci commit firewall
/etc/init.d/firewall restart


# Проверить существующие таблицы и sets
nft list tables
nft list sets
nft list set inet fw4 vpn_domains


# маркировка в nftables
#firewall4 уже создаёт цепочки, поэтому чаще безопаснее использовать include + append chain, например
# Создаём правило маркировки
uci add firewall rule
uci set firewall.@rule[-1].name="Mark VPN domains"
uci set firewall.@rule[-1].family="ipv4"
uci set firewall.@rule[-1].proto="all"
uci set firewall.@rule[-1].ipset="vpn_domains"
uci set firewall.@rule[-1].set_mark="0x1"
uci set firewall.@rule[-1].target="MARK"
uci commit firewall
/etc/init.d/firewall restart



nft list ruleset

/etc/init.d/firewall restart
-------------------------------------------------------------
# 3. Настраиваем маршрутизацию для маркированных пакетов

--------------------------------------------
# Добавляем правило в rc.local
cat >> /etc/rc.local << 'EOF'

# VPN routing for marked packets
ip rule add fwmark 0x1 table vpn priority 1000 2>/dev/null
ip route add default dev wg0 table vpn 2>/dev/null

exit 0
EOF

chmod +x /etc/rc.local


/etc/init.d/firewall restart
/etc/init.d/network restart
# Применяем сейчас
ip rule add fwmark 0x1 table vpn priority 1000 2>/dev/null
ip route add default dev wg0 table vpn 2>/dev/null

# Проверяем
ip rule list | grep fwmark
ip route get 8.8.8.8 mark 0x1