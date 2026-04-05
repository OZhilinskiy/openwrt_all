apk update
apk add curl

add_mark() {
    # создаем таблицу маршрутизации. 
    grep -q "99 vpn" /etc/iproute2/rt_tables || echo '99 vpn' >> /etc/iproute2/rt_tables
    
    #Добавляем правило, чтоб весь маркированный трафик уходил в созданную таблицу. Через UCI:
    if ! uci show network | grep -q mark0x1; then
        printf "\033[32;1mConfigure mark rule\033[0m\n"
        uci add network rule
        uci set network.@rule[-1].name='mark0x1'
        uci set network.@rule[-1].mark='0x1'
        uci set network.@rule[-1].priority='100'
        uci set network.@rule[-1].lookup='vpn'
        uci commit
    fi
}

add_mark

#Добавляем правило для таблицы маршрутизации, чтоб весь трафик, направленный в эту таблицу, уходил в туннель.
add_vpn_route() {
# Проверяем существует ли секция с именем vpn_route
if uci -q get network.vpn_route > /dev/null; then
    echo "Маршрут vpn_route уже существует"
else
    echo "Создаём маршрут vpn_route"
    uci set network.vpn_route=route
    uci set network.vpn_route.interface='wg0'
    uci set network.vpn_route.table='vpn'
    uci set network.vpn_route.target='0.0.0.0/0'
    uci commit network
fi
}

add_vpn_route

#Необходимо создать зону для туннеля, чтобы разрешить хождение трафика через туннель
configure_vpn_ipset_and_rule() {
    local IPSET_NAME="vpn_domains"
    local RULE_NAME="mark_domains"
    local NEED_RELOAD=0
    
    # 1. Работа с ipset
    local ipset_id=$(uci show firewall 2>/dev/null | grep -E "@ipset.*name='$IPSET_NAME'" | awk -F'[][{}]' '{print $2}' | head -1)
    
    if [ ! -z "$ipset_id" ]; then
        echo "✓ ipset '$IPSET_NAME' уже существует (id: $ipset_id)"
        
        # Проверяем параметры и обновляем если нужно
        local current_match=$(uci get firewall.@ipset[$ipset_id].match 2>/dev/null)
        local current_family=$(uci get firewall.@ipset[$ipset_id].family 2>/dev/null)
        
        if [ "$current_match" != "dst_net" ]; then
            uci set firewall.@ipset[$ipset_id].match='dst_net'
            NEED_RELOAD=1
            echo "  Обновлён параметр match"
        fi
        
        if [ "$current_family" != "ipv4" ]; then
            uci set firewall.@ipset[$ipset_id].family='ipv4'
            NEED_RELOAD=1
            echo "  Обновлён параметр family"
        fi
    else
        echo "Создаём ipset '$IPSET_NAME'"
        uci add firewall ipset
        uci set firewall.@ipset[-1].name="$IPSET_NAME"
        uci set firewall.@ipset[-1].match='dst_net'
        uci set firewall.@ipset[-1].family='ipv4'
        uci set firewall.@ipset[-1].timeout='3600'
        NEED_RELOAD=1
        echo "✓ ipset создан"
    fi
    
    # 2. Работа с правилом
    local rule_id=$(uci show firewall 2>/dev/null | grep -E "@rule.*name='$RULE_NAME'" | awk -F'[][{}]' '{print $2}' | head -1)
    
    if [ ! -z "$rule_id" ]; then
        echo "✓ Правило '$RULE_NAME' уже существует (id: $rule_id)"
        
        # Проверяем параметры правила
        local current_src=$(uci get firewall.@rule[$rule_id].src 2>/dev/null)
        local current_ipset=$(uci get firewall.@rule[$rule_id].ipset 2>/dev/null)
        local current_mark=$(uci get firewall.@rule[$rule_id].set_mark 2>/dev/null)
        local current_target=$(uci get firewall.@rule[$rule_id].target 2>/dev/null)
        
        if [ "$current_src" != "lan" ]; then
            uci set firewall.@rule[$rule_id].src='lan'
            NEED_RELOAD=1
            echo "  Обновлён параметр src"
        fi
        
        if [ "$current_ipset" != "$IPSET_NAME" ]; then
            uci set firewall.@rule[$rule_id].ipset="$IPSET_NAME"
            NEED_RELOAD=1
            echo "  Обновлён параметр ipset"
        fi
        
        if [ "$current_mark" != "0x1" ]; then
            uci set firewall.@rule[$rule_id].set_mark='0x1'
            NEED_RELOAD=1
            echo "  Обновлён параметр set_mark"
        fi
        
        if [ "$current_target" != "MARK" ]; then
            uci set firewall.@rule[$rule_id].target='MARK'
            NEED_RELOAD=1
            echo "  Обновлён параметр target"
        fi
    else
        echo "Создаём правило '$RULE_NAME'"
        uci add firewall rule
        uci set firewall.@rule[-1].name="$RULE_NAME"
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest='*'
        uci set firewall.@rule[-1].proto='all'
        uci set firewall.@rule[-1].ipset="$IPSET_NAME"
        uci set firewall.@rule[-1].set_mark='0x1'
        uci set firewall.@rule[-1].target='MARK'
        uci set firewall.@rule[-1].family='ipv4'
        NEED_RELOAD=1
        echo "✓ Правило создано"
    fi
    
    if [ $NEED_RELOAD -eq 1 ]; then
        uci commit firewall
        echo "✓ Настройки сохранены"
        
        # Перезапускаем firewall
        echo "Перезапуск firewall..."
        /etc/init.d/firewall reload
        echo "✓ Firewall перезапущен"
    else
        echo "✓ Изменений не требуется, всё уже настроено"
    fi
}

# Запуск
configure_vpn_ipset_and_rule
    
#/etc/init.d/network restart

# Настраиваем dnsmasq через UCI
configure_dnsmasq() {
    local NEED_RESTART=0
    
    # 1. Включаем поддержку nftset
    local current_nftset=$(uci get dhcp.@dnsmasq[0].nftset 2>/dev/null)
    if [ "$current_nftset" != "1" ]; then
        echo "Включаем поддержку nftset в dnsmasq"
        uci set dhcp.@dnsmasq[0].nftset='1'
        NEED_RESTART=1
    else
        echo "✓ nftset уже включён"
    fi
    
    # 2. Добавляем директорий для конфигов (если ещё не добавлена)
    if uci show dhcp 2>/dev/null | grep -q "confdir='/etc/dnsmasq.d'"; then
        echo "✓ Директория /etc/dnsmasq.d уже добавлена"
    else
        echo "Добавляем директорию /etc/dnsmasq.d"
        uci add_list dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
        NEED_RESTART=1
    fi
    
    if [ $NEED_RESTART -eq 1 ]; then
        uci commit dhcp
        echo "✓ Настройки сохранены"
        
        # Проверяем конфигурацию перед перезапуском
        if dnsmasq --test 2>/dev/null; then
            /etc/init.d/dnsmasq restart
            echo "✓ Dnsmasq перезапущен"
        else
            echo "✗ Ошибка в конфигурации dnsmasq!"
            return 1
        fi
    else
        echo "✓ Изменений не требуется"
    fi
}

configure_dnsmasq

#Устанавливаем DNSCrypt-proxy2
configure_dnscrypt() {
#ШАГ 1 — привести dnscrypt к стандарту OpenWrt
#Открывай:
#nano /etc/dnscrypt-proxy2/dnscrypt-proxy.toml

if apk list --installed 2>/dev/null | grep -q dnscrypt-proxy2; then
    printf "\033[32;1mDNSCrypt2 already installed\033[0m\n"
else
    printf "\033[32;1mInstalled dnscrypt-proxy2\033[0m\n"
    apk update
    apk add dnscrypt-proxy2
    if grep -q "# server_names" /etc/dnscrypt-proxy2/dnscrypt-proxy.toml; then
        sed -i "s/^# server_names =.*/server_names = ['google', 'cloudflare', 'scaleway-fr', 'yandex']/g" /etc/dnscrypt-proxy2/dnscrypt-proxy.toml
    fi

    printf "\033[32;1mDNSCrypt restart\033[0m\n"
    service dnscrypt-proxy restart
    printf "\033[32;1mDNSCrypt needs to load the relays list. Please wait\033[0m\n"
    sleep 30

    if [ -f /etc/dnscrypt-proxy2/relays.md ]; then
        uci set dhcp.@dnsmasq[0].noresolv="1"
        uci -q delete dhcp.@dnsmasq[0].server
        uci add_list dhcp.@dnsmasq[0].server="127.0.0.53#53"
        uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
        uci commit dhcp
        
        printf "\033[32;1mDnsmasq restart\033[0m\n"

        /etc/init.d/dnsmasq restart
    else
        printf "\033[31;1mDNSCrypt not download list on /etc/dnscrypt-proxy2. Repeat install DNSCrypt by script.\033[0m\n"
    fi
fi
}

configure_dnscrypt

update_domain_list() {
cat > /usr/bin/vpn-domains-update << 'EOF'
#!/bin/sh

update_vpn_domains() {
    local DIR="/etc/vpn_domains"
    local LIST="$DIR/domains.list"
    local CUSTOM="$DIR/domains.custom"
    local OUTPUT="$DIR/domains.conf"
    local URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
    
    mkdir -p "$DIR"
    
    echo "[$(date '+%H:%M:%S')] Начинаю обновление..."
    
    # Создаем файл для ручных доменов если нет
    if [ ! -f "$CUSTOM" ]; then
        echo "# Добавьте свои домены (по одному на строку)" > "$CUSTOM"
        echo "example.com" >> "$CUSTOM"
        echo "Создан файл для ручных доменов: $CUSTOM"
    fi
    
    # Скачиваем список
    echo "Скачиваю список..."
    wget -q -O "$LIST" "$URL" 2>/dev/null
    
    if [ ! -s "$LIST" ]; then
        echo "Ошибка: не удалось скачать список"
        rm -f "$LIST"
        return 1
    fi
    
    echo "Скачано $(wc -l < "$LIST") строк"
    
    # Собираем финальный файл
    > "$OUTPUT"
    
    # Добавляем ручные домены
    if [ -f "$CUSTOM" ]; then
        while read line; do
            case "$line" in
                ""|\#*) continue ;;
                *) echo "$line" | grep -q '^nftset=/' && echo "$line" || echo "nftset=/$line/4#inet#fw4#vpn_domains" ;;
            esac
        done < "$CUSTOM" >> "$OUTPUT"
    fi
    
    # Добавляем скачанные домены
    grep '^nftset=/' "$LIST" >> "$OUTPUT" 2>/dev/null
    
    # Удаляем дубликаты
    sort -u "$OUTPUT" -o "$OUTPUT"
    
    local COUNT=$(wc -l < "$OUTPUT")
    echo "Всего доменов: $COUNT"
    
    # Копируем в dnsmasq
    cp "$OUTPUT" "/etc/dnsmasq.d/vpn.conf"
    
    # Перезапускаем dnsmasq
    /etc/init.d/dnsmasq restart
    
    echo "Готово! Dnsmasq перезапущен"
    echo "---"
}

update_vpn_domains
EOF

chmod +x /usr/bin/vpn-domains-update

# Добавляем в crontab
# Проверить наличие команды в crontab
if grep -q "vpn-domains-update" /etc/crontabs/root 2>/dev/null; then
    echo "✓ Запись уже существует"
else
    echo "✗ Записи нет, добавляем..."
    echo "0 */8 * * * /usr/bin/vpn-domains-update" >> /etc/crontabs/root
fi

# Перезапускаем cron
/etc/init.d/cron restart

# Для ручного запуска просто выполните
/usr/bin/vpn-domains-update
}

update_domain_list