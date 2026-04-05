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
# проверяем существование интерфейса
    if ! ip link show wg0 > /dev/null 2>&1; then
        echo "✗ Ошибка: интерфейс wg0 не найден"
        echo "  Убедитесь, что WireGuard настроен"
        return 1
    fi

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
    # Редактируем /etc/dnscrypt-proxy2/dnscrypt-proxy.toml
    sed -i 's/^listen_addresses = .*/listen_addresses = ["127.0.0.1:5353"]/' /etc/dnscrypt-proxy2/dnscrypt-proxy.toml
    sed -i 's/^# server_names =.*/server_names = ["cloudflare", "google"]/' /etc/dnscrypt-proxy2/dnscrypt-proxy.toml

    /etc/init.d/dnscrypt-proxy restart
    sleep 30

    if [ -f /etc/dnscrypt-proxy2/relays.md ]; then
        uci set dhcp.@dnsmasq[0].noresolv="1"
        uci -q delete dhcp.@dnsmasq[0].server
        uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#5353"
        uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
        uci commit dhcp
        
        printf "\033[32;1mDnsmasq restart\033[0m\n"

        /etc/init.d/dnsmasq restart
    else
        printf "\033[31;1mDNSCrypt not download list on /etc/dnscrypt-proxy2. Repeat install DNSCrypt by script.\033[0m\n"
    fi
fi
}

#configure_dnscrypt

update_domain_list() {
    cat > /usr/bin/vpn-domains-update << 'EOF'
#!/bin/sh

create_vpn_domains() {
    local DOMAINS_DIR="/etc/vpn_custom_domains"
    local REMOTE_FILE="$DOMAINS_DIR/domains.list"
    local CUSTOM_FILE="$DOMAINS_DIR/domains.custom"
    local FINAL_FILE="$DOMAINS_DIR/domains.final"
    local DNSMASQ_DIR="/etc/dnsmasq.d"
    local DNSMASQ_FILE="$DNSMASQ_DIR/vpn_domains.conf"
    local URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
    local MAX_RETRIES=3
    local RETRY_DELAY=3
    local attempt=1

    mkdir -p "$DOMAINS_DIR" "$DNSMASQ_DIR"

    echo "=========================================="
    echo "VPN Domains Update - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================="

    # Создаём кастомный файл, если его нет
    if [ ! -f "$CUSTOM_FILE" ]; then
        printf '# Manual domains for VPN\n# One domain per line\nexample.com\n' > "$CUSTOM_FILE"
        echo "Created custom file: $CUSTOM_FILE"
    fi

    echo ""
    echo "Downloading remote domain list..."

    while [ $attempt -le $MAX_RETRIES ]; do
        echo "  Attempt $attempt of $MAX_RETRIES..."
        if wget -q -O "$REMOTE_FILE" "$URL" && [ -s "$REMOTE_FILE" ]; then
            echo "  ✓ Download successful"
            break
        else
            echo "  ✗ Download failed"
        fi
        [ $attempt -lt $MAX_RETRIES ] && sleep $RETRY_DELAY
        attempt=$((attempt + 1))
    done

    [ -s "$REMOTE_FILE" ] && echo "  Downloaded: $(wc -l < "$REMOTE_FILE") lines" \
                          || echo "  ⚠ Using only custom domains"

    echo ""
    echo "Building final domain list..."
    > "$FINAL_FILE"

    #
    # === ОБРАБОТКА КАСТОМНЫХ ДОМЕНОВ ===
    #
    custom_count=0
    while IFS= read -r line || [ -n "$line" ]; do
        # Убираем CRLF и пробелы
        line=$(echo "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Пропускаем пустые строки и комментарии
        [ -z "$line" ] && continue
        echo "$line" | grep -q '^#' && continue

        # Если пользователь сам написал nftset=/... — добавляем как есть
        if echo "$line" | grep -q '^nftset=/'; then
            echo "$line" >> "$FINAL_FILE"
            custom_count=$((custom_count + 1))
            continue
        fi

        # Проверка домена
        if echo "$line" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
            echo "nftset=/$line/4#inet#fw4#vpn_domains" >> "$FINAL_FILE"
            custom_count=$((custom_count + 1))
        else
            echo "⚠ Skipped invalid custom entry: $line"
        fi
    done < "$CUSTOM_FILE"

    echo "  Custom domains: $custom_count"

    #
    # === ОБРАБОТКА УДАЛЁННОГО СПИСКА ===
    #
    remote_count=0
    if [ -s "$REMOTE_FILE" ]; then
        while IFS= read -r line; do
            echo "$line" | grep -q '^nftset=/' || continue
            echo "$line" >> "$FINAL_FILE"
            remote_count=$((remote_count + 1))
        done < "$REMOTE_FILE"
    fi

    echo "  Remote domains: $remote_count"

    #
    # === УДАЛЕНИЕ ДУБЛИКАТОВ ===
    #
    sort -t'/' -k2,2 -u "$FINAL_FILE" > "${FINAL_FILE}.tmp"
    mv "${FINAL_FILE}.tmp" "$FINAL_FILE"

    final_count=$(wc -l < "$FINAL_FILE")
    echo ""
    echo "✓ Total unique domains: $final_count"

    #
    # === КОПИРОВАНИЕ В DNSMASQ ===
    #
    cp "$FINAL_FILE" "$DNSMASQ_FILE"
    chmod 644 "$DNSMASQ_FILE"

    echo ""
    echo "Restarting dnsmasq..."
    /etc/init.d/dnsmasq restart && echo "✓ dnsmasq restarted" || echo "✗ Failed to restart dnsmasq"

    echo ""
    echo "=========================================="
    echo "Done! - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Domains count: $final_count"
    echo "Config: $DNSMASQ_FILE"
    echo "=========================================="
}

create_vpn_domains
EOF

    chmod +x /usr/bin/vpn-domains-update
    
    # Добавляем в crontab с проверкой
    local CRON_FILE="/etc/crontabs/root"
    local CRON_JOB="0 */8 * * * /usr/bin/vpn-domains-update"
    local CRON_RESTART=0
    
    # Создаём файл если нет
    [ ! -f "$CRON_FILE" ] && touch "$CRON_FILE"
    
    # Проверяем и добавляем
    if grep -q "vpn-domains-update" "$CRON_FILE" 2>/dev/null; then
        echo "✓ Cron job already exists"
        # Проверяем точное совпадение
        if ! grep -q "^0 \*/8 \* \* \* /usr/bin/vpn-domains-update$" "$CRON_FILE" 2>/dev/null; then
            echo "  Updating to correct schedule..."
            sed -i '/vpn-domains-update/d' "$CRON_FILE"
            echo "$CRON_JOB" >> "$CRON_FILE"
            CRON_RESTART=1
        fi
    else
        echo "Adding cron job: $CRON_JOB"
        echo "$CRON_JOB" >> "$CRON_FILE"
        CRON_RESTART=1
    fi
    
    # Перезапускаем cron только если были изменения
    if [ $CRON_RESTART -eq 1 ] && [ -f "/etc/init.d/cron" ]; then
        /etc/init.d/cron restart
        echo "✓ Cron restarted"
    elif [ $CRON_RESTART -eq 1 ]; then
        echo "✓ Cron job added (cron daemon may need manual restart)"
    fi
    
    echo ""
    echo "To run manually: /usr/bin/vpn-domains-update"
}

# Запуск
update_domain_list
