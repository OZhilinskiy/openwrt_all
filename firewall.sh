# Проверяем содержимое скрипта
cat /etc/init.d/vpn-mark

# Если скрипт пустой или некорректный, создаем заново
cat > /etc/init.d/vpn-mark << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

start() {
    echo "Loading VPN mark rules..."
    
    # Создаем набор
    nft add set inet fw4 vpn_domains { type ipv4_addr\; flags interval, timeout\; timeout 1h\; auto-merge\; }
    echo "  - Created vpn_domains set"
    
    # Добавляем правило в mangle_prerouting
    nft add rule inet fw4 mangle_prerouting ip daddr @vpn_domains meta mark set 0x1
    echo "  - Added rule to mangle_prerouting"
    
    # Добавляем правило в mangle_output
    nft add rule inet fw4 mangle_output ip daddr @vpn_domains meta mark set 0x1
    echo "  - Added rule to mangle_output"
    
    echo "VPN mark rules loaded successfully"
}

stop() {
    echo "Removing VPN mark rules..."
    
    # Удаляем правила
    nft delete rule inet fw4 mangle_prerouting ip daddr @vpn_domains meta mark set 0x1 2>/dev/null
    nft delete rule inet fw4 mangle_output ip daddr @vpn_domains meta mark set 0x1 2>/dev/null
    
    # Удаляем набор
    nft delete set inet fw4 vpn_domains 2>/dev/null
    
    echo "VPN mark rules removed"
}

restart() {
    stop
    sleep 1
    start
}
EOF

# Делаем исполняемым
chmod +x /etc/init.d/vpn-mark

#Запускаем скрипт
/etc/init.d/vpn-mark start

# Проверяем результат
nft list set inet fw4 vpn_domains
nft list chain inet fw4 mangle_prerouting
nft list chain inet fw4 mangle_output

--------------------------------------------------------

# Проверяем содержимое скрипта
cat /etc/init.d/vpn-mark

# Если скрипт пустой или некорректный, создаем заново
cat > /etc/init.d/vpn-mark << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

start() {
    echo "Loading VPN mark rules..."

    # создаём set безопасно
    nft list set inet fw4 vpn_domains >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        nft add set inet fw4 vpn_domains { type ipv4_addr\; flags interval, timeout\; timeout 1h\; auto-merge\; }
    fi

    # удаляем старые правила (анти-дубликаты)
    nft flush chain inet fw4 prerouting 2>/dev/null
    nft flush chain inet fw4 output 2>/dev/null

    # ПРАВИЛЬНЫЕ цепи fw4
    nft add rule inet fw4 prerouting ip daddr @vpn_domains meta mark set 0x1
    nft add rule inet fw4 output ip daddr @vpn_domains meta mark set 0x1

    echo "VPN mark rules loaded successfully"
}

stop() {
    echo "Removing VPN mark rules..."
    
    # Удаляем правила
    nft delete rule inet fw4 mangle_prerouting ip daddr @vpn_domains meta mark set 0x1 2>/dev/null
    nft delete rule inet fw4 mangle_output ip daddr @vpn_domains meta mark set 0x1 2>/dev/null
    
    # Удаляем набор
    nft delete set inet fw4 vpn_domains 2>/dev/null
    
    echo "VPN mark rules removed"
}

restart() {
    stop
    sleep 1
    start
}
EOF

# Делаем исполняемым
chmod +x /etc/init.d/vpn-mark

#Запускаем скрипт
/etc/init.d/vpn-mark start

---------------------------------------------------------------------------
#nftables (только mark)
cat > /etc/init.d/vpn-mark << 'EOF'
#!/bin/sh /etc/rc.common

START=99

start() {
    echo "Loading VPN mark rules..."

    # ждём fw4
    sleep 5

    # создаём set если нет
    nft list set inet fw4 vpn_domains >/dev/null 2>&1 || \
    nft add set inet fw4 vpn_domains { type ipv4_addr\; flags interval, timeout\; timeout 1h\; auto-merge\; }

    # создаём цепочку
    nft list chain inet fw4 vpn_mark >/dev/null 2>&1 || \
    nft add chain inet fw4 vpn_mark { type filter hook prerouting priority mangle \; }

    # чистим
    nft flush chain inet fw4 vpn_mark

    # добавляем правило
    nft add rule inet fw4 vpn_mark ip daddr @vpn_domains meta mark set 0x1

    echo "VPN mark rules loaded"
}
EOF

chmod +x /etc/init.d/vpn-mark
/etc/init.d/vpn-mark enable
/etc/init.d/vpn-mark start




---
cat > /etc/firewall.user << 'EOF'

# VPN mark chain (safe hook into fw4)
nft add chain inet fw4 vpn_mark { type filter hook prerouting priority mangle\; policy accept\; } 2>/dev/null

# rule
nft add rule inet fw4 vpn_mark ip daddr @vpn_domains meta mark set 0x1 2>/dev/null

EOF



vi /etc/config/firewall

config include
    option type 'nftables'
    option path '/etc/nftables.d/vpn-mark.nft'


fw4 restart

#Проверяем что присутствует правило марк 01
nft list chain inet fw4 vpn_mark

#Проверка 
nft list set inet fw4 vpn_domains
nft list chain inet fw4 mangle_prerouting
nft list chain inet fw4 mangle_output

#3. таблица маршрутов
#echo "100 vpn" >> /etc/iproute2/rt_tables

cat > /etc/hotplug.d/iface/99-vpn-policy << 'EOF'
#!/bin/sh

[ "$INTERFACE" = "wg0" ] || exit 0
[ "$ACTION" = "ifup" ] || exit 0

logger "VPN policy routing setup..."

ip route add default dev wg0 table vpn
ip rule add fwmark 0x1 table vpn
EOF

chmod +x /etc/hotplug.d/iface/99-vpn-policy

#Проверка
ip rule
ip route show table vpn