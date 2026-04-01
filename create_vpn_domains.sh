create_vpn_domains() {
    local DOMAINS_DIR="/etc/vpn_custom_domains"
    local REMOTE_FILE="$DOMAINS_DIR/domains.list"
    local CUSTOM_FILE="$DOMAINS_DIR/domains.custom"
    local FINAL_FILE="$DOMAINS_DIR/domains.final"
    local DNSMASQ_DIR="/etc/dnsmasq.d"
    local DNSMASQ_FILE="$DNSMASQ_DIR/vpn_domains.conf"
    local URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
    local MAX_RETRIES=5
    local RETRY_DELAY=3
    local attempt=1
    
    # Создаем директории
    mkdir -p "$DOMAINS_DIR"
    mkdir -p "$DNSMASQ_DIR"
    
    echo "=========================================="
    echo "Настройка VPN доменов"
    echo "=========================================="
    
    # 1. Создаем файл для ручных доменов, если его нет
    if [ ! -f "$CUSTOM_FILE" ]; then
        echo "Создаем файл для ручных доменов: $CUSTOM_FILE"
        cat > "$CUSTOM_FILE" << 'EOF'
# ============================================
# Ручной список доменов для VPN
# Формат: любой из перечисленных ниже
# ============================================
# 
# 1. Просто домен (будет автоматически преобразован):
# example.com
#
# 2. В формате dnsmasq:
# server=/youtube.com/8.8.8.8
# address=/github.com/1.1.1.1
#
# 3. Уже в правильном формате:
# nftset=/google.com/4#inet#fw4#vpn_domains
#
# ============================================

# Добавьте свои домены ниже (после символа #):
# youtube.com
# google.com
# github.com

EOF
        echo "✓ Файл создан. Отредактируйте его при необходимости:"
        echo "  vi $CUSTOM_FILE"
    else
        echo "✓ Файл ручных доменов уже существует: $CUSTOM_FILE"
    fi
    
    # 2. Скачиваем удаленный файл с 5 попытками
    echo ""
    echo "Загрузка удаленного списка доменов..."
    
    while [ $attempt -le $MAX_RETRIES ]; do
        echo "  Попытка $attempt из $MAX_RETRIES..."
        
        # Проверяем интернет и скачиваем
        if command -v wget >/dev/null 2>&1; then
            if wget -q -O "$REMOTE_FILE" "$URL" 2>/dev/null && [ -s "$REMOTE_FILE" ]; then
                echo "  ✓ Удачная загрузка"
                break
            else
                echo "  ✗ Ошибка загрузки"
            fi
        elif command -v curl >/dev/null 2>&1; then
            if curl -s -o "$REMOTE_FILE" "$URL" 2>/dev/null && [ -s "$REMOTE_FILE" ]; then
                echo "  ✓ Удачная загрузка"
                break
            else
                echo "  ✗ Ошибка загрузки"
            fi
        else
            echo "  ✗ Ошибка: ни wget, ни curl не установлены"
            break
        fi
        
        if [ $attempt -lt $MAX_RETRIES ]; then
            echo "  Повторная попытка через $RETRY_DELAY секунд..."
            sleep $RETRY_DELAY
        fi
        attempt=$((attempt + 1))
    done
    
    # 3. Проверяем результат загрузки
    if [ -f "$REMOTE_FILE" ] && [ -s "$REMOTE_FILE" ]; then
        local remote_lines=$(wc -l < "$REMOTE_FILE")
        echo "  Загружено строк: $remote_lines"
    else
        echo "  ⚠ Внимание: удаленный файл не загружен, используем только ручные домены"
        rm -f "$REMOTE_FILE"
    fi
    
    # 4. Нормализуем ручные домены и создаем итоговый файл
    echo ""
    echo "Формирование итогового файла: $FINAL_FILE"
    
    # Очищаем итоговый файл
    > "$FINAL_FILE"
    
    # Функция для нормализации домена в правильный формат
    normalize_domain_line() {
        local line="$1"
        local domain=""
        
        # Пропускаем пустые строки и комментарии
        [ -z "$line" ] && return 1
        echo "$line" | grep -q '^[[:space:]]*#' && return 1
        
        # Удаляем пробелы
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Извлекаем домен в зависимости от формата
        if echo "$line" | grep -q '^nftset=/' 2>/dev/null; then
            # Уже в правильном формате
            domain=$(echo "$line" | sed -n 's/^nftset=\/\([^/]*\)\/.*/\1/p')
            if [ -n "$domain" ]; then
                echo "$line"
                return 0
            fi
        elif echo "$line" | grep -q '^[a-zA-Z0-9.-]*\.[a-zA-Z]\{2,\}$' 2>/dev/null; then
            # Просто домен
            domain="$line"
            echo "nftset=/$domain/4#inet#fw4#vpn_domains"
            return 0
        elif echo "$line" | grep -q '^\(server\|address\)=/' 2>/dev/null; then
            # Формат server=/domain/... или address=/domain/...
            domain=$(echo "$line" | sed -n 's/^[^=]*=\/\([^/]*\)\/.*/\1/p')
            if [ -n "$domain" ]; then
                echo "nftset=/$domain/4#inet#fw4#vpn_domains"
                return 0
            fi
        else
            # Пробуем извлечь любой домен из строки
            domain=$(echo "$line" | grep -oE '[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | head -1)
            if [ -n "$domain" ]; then
                echo "nftset=/$domain/4#inet#fw4#vpn_domains"
                return 0
            fi
        fi
        
        return 1
    }
    
    # Добавляем ручные домены (в любом формате)
    if [ -f "$CUSTOM_FILE" ]; then
        local custom_count=0
        echo "  Обработка ручных доменов..."
        
        while IFS= read -r line; do
            result=$(normalize_domain_line "$line")
            if [ $? -eq 0 ] && [ -n "$result" ]; then
                echo "$result" >> "$FINAL_FILE"
                custom_count=$((custom_count + 1))
            fi
        done < "$CUSTOM_FILE"
        
        echo "  Добавлено ручных доменов: $custom_count"
    fi
    
    # Добавляем удаленные домены (они уже в правильном формате)
    if [ -f "$REMOTE_FILE" ] && [ -s "$REMOTE_FILE" ]; then
        local remote_count=0
        echo "  Добавление удаленных доменов..."
        
        while IFS= read -r line; do
            # Проверяем, что строка в правильном формате
            if echo "$line" | grep -q '^nftset=/' 2>/dev/null; then
                echo "$line" >> "$FINAL_FILE"
                remote_count=$((remote_count + 1))
            fi
        done < "$REMOTE_FILE"
        
        echo "  Добавлено удаленных доменов: $remote_count"
    fi
    
    # 5. Удаляем дубликаты (сортируем по домену)
    if [ -s "$FINAL_FILE" ]; then
        echo ""
        echo "Удаление дубликатов..."
        
        # Сортируем по домену (второе поле после /)
        sort -t'/' -k2,2 -u "$FINAL_FILE" > "${FINAL_FILE}.tmp"
        mv "${FINAL_FILE}.tmp" "$FINAL_FILE"
        
        local final_count=$(wc -l < "$FINAL_FILE")
        echo "✓ Итоговый файл содержит $final_count уникальных доменов"
        
        # Показываем пример содержимого
        echo ""
        echo "Пример содержимого (первые 5 строк):"
        head -5 "$FINAL_FILE" | sed 's/^/  /'
    else
        echo "✗ Ошибка: не удалось создать итоговый файл"
        return 1
    fi
    
    # 6. Переносим файл в dnsmasq
    echo ""
    echo "Перенос файла в dnsmasq..."
    
    if [ -s "$FINAL_FILE" ]; then
        cp "$FINAL_FILE" "$DNSMASQ_FILE"
        echo "✓ Файл скопирован: $DNSMASQ_FILE"
        
        # Проверяем права доступа
        chmod 644 "$DNSMASQ_FILE"
        
        # Проверяем владельца
        if command -v chown >/dev/null 2>&1; then
            chown root:root "$DNSMASQ_FILE" 2>/dev/null || true
        fi
    else
        echo "✗ Ошибка: итоговый файл пуст, не могу скопировать"
        return 1
    fi
    
    # 7. Проверяем конфигурацию dnsmasq и перезапускаем
    echo ""
    echo "Проверка конфигурации dnsmasq..."
    
    if command -v dnsmasq >/dev/null 2>&1; then
        # Проверяем синтаксис
        if dnsmasq --test 2>/dev/null; then
            echo "✓ Конфигурация dnsmasq корректна"
            
            # Перезапускаем dnsmasq в зависимости от системы
            echo "Перезапуск dnsmasq..."
            
            if command -v systemctl >/dev/null 2>&1; then
                # systemd
                if systemctl restart dnsmasq 2>/dev/null; then
                    echo "✓ dnsmasq перезапущен (systemctl)"
                else
                    echo "⚠ Не удалось перезапустить через systemctl, пробуем service..."
                    service dnsmasq restart 2>/dev/null || true
                fi
            elif command -v service >/dev/null 2>&1; then
                # sysvinit
                service dnsmasq restart 2>/dev/null && echo "✓ dnsmasq перезапущен (service)"
            elif [ -f "/etc/init.d/dnsmasq" ]; then
                # OpenWrt/LEDE
                /etc/init.d/dnsmasq restart 2>/dev/null && echo "✓ dnsmasq перезапущен (init.d)"
            else
                echo "⚠ Не найден способ перезапуска dnsmasq, попробуйте вручную:"
                echo "  systemctl restart dnsmasq  # для systemd"
                echo "  service dnsmasq restart    # для sysvinit"
                echo "  /etc/init.d/dnsmasq restart # для OpenWrt"
            fi
            
            # Проверяем статус
            sleep 1
            if command -v pgrep >/dev/null 2>&1; then
                if pgrep dnsmasq >/dev/null 2>&1; then
                    echo "✓ dnsmasq работает"
                else
                    echo "⚠ Внимание: dnsmasq не запущен"
                fi
            fi
        else
            echo "✗ Ошибка: неверный синтаксис конфигурации dnsmasq!"
            echo "  Проверьте файл: $DNSMASQ_FILE"
            echo "  Запустите для диагностики: dnsmasq --test"
            return 1
        fi
    else
        echo "⚠ Внимание: dnsmasq не установлен"
        echo "  Установите dnsmasq командой:"
        echo "    apt install dnsmasq    # для Debian/Ubuntu"
        echo "    opkg install dnsmasq   # для OpenWrt"
    fi
    
    # 8. Выводим информацию
    echo ""
    echo "=========================================="
    echo "Готово!"
    echo "=========================================="
    echo "Файлы находятся в:"
    echo "  $DOMAINS_DIR/domains.list    - загруженный удаленный список"
    echo "  $DOMAINS_DIR/domains.custom  - ваш ручной список (редактируйте здесь)"
    echo "  $DOMAINS_DIR/domains.final   - итоговый объединенный список"
    echo "  $DNSMASQ_FILE                - активный файл для dnsmasq"
    echo ""
    echo "Для добавления своих доменов:"
    echo "  echo \"example.com\" >> $CUSTOM_FILE"
    echo "  # или отредактируйте файл: vi $CUSTOM_FILE"
    echo "  # затем запустите скрипт снова"
    echo ""
    echo "Для просмотра итогового списка:"
    echo "  cat $DNSMASQ_FILE | head -20"
    echo "  wc -l $DNSMASQ_FILE"
    echo ""
    echo "Для проверки статуса dnsmasq:"
    echo "  systemctl status dnsmasq     # для systemd"
    echo "  service dnsmasq status       # для sysvinit"
    echo "  /etc/init.d/dnsmasq status   # для OpenWrt"
    echo "=========================================="
    
    return 0
}

create_vpn_domains