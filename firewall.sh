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

