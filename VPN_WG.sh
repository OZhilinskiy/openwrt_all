#!/bin/sh

setup_wg_client() {

    printf "\033[32;1mConfigure WireGuard\033[0m\n"

    # Проверка установки пакета через apk
    if apk info wireguard-tools >/dev/null 2>&1; then
        echo "✓ WireGuard already installed"
    else
        echo "Installing wireguard-tools and luci-proto-wireguard..."
        apk update
        apk add wireguard-tools luci-proto-wireguard
        if [ $? -ne 0 ]; then
            echo "Error: Failed to install packages"
            return 1
        fi
    fi

    # Удаляем старые настройки
    echo "Cleaning old configuration..."
    uci delete network.wg0 2>/dev/null
    uci delete network.wg0_client 2>/dev/null
    uci commit network

    # Ввод приватного ключа
    while true; do
        read -r -p "Enter the private key (from [Interface]): " WG_PRIVATE_KEY
        if [ -n "$WG_PRIVATE_KEY" ]; then
            break
        else
            echo "Private key cannot be empty. Please repeat"
        fi
    done

    # Ввод IP адреса с валидацией
    while true; do
        read -r -p "Enter internal IP address with subnet, example 10.0.0.2/24 (from [Interface]): " WG_IP
        if echo "$WG_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'; then
            break
        else
            echo "Invalid format. Please enter in format: 10.0.0.2/24"
        fi
    done

    # Ввод публичного ключа
    while true; do
        read -r -p "Enter the public key (from [Peer]): " WG_PUBLIC_KEY
        if [ -n "$WG_PUBLIC_KEY" ]; then
            break
        else
            echo "Public key cannot be empty. Please repeat"
        fi
    done

    # Ввод PresharedKey (опционально)
    read -r -p "If use PresharedKey, enter it (from [Peer]). If you don't use, leave blank: " WG_PRESHARED_KEY

    # Ввод endpoint host
    while true; do
        read -r -p "Enter Endpoint host (Domain or IP) (from [Peer]): " WG_ENDPOINT
        if [ -n "$WG_ENDPOINT" ]; then
            break
        else
            echo "Endpoint host cannot be empty. Please repeat"
        fi
    done

    # Ввод порта с значением по умолчанию
    read -r -p "Enter Endpoint port (from [Peer]) [51820]: " WG_ENDPOINT_PORT
    WG_ENDPOINT_PORT=${WG_ENDPOINT_PORT:-51820}

    # Ввод DNS (опционально)
    read -r -p "Enter DNS servers (space separated) [8.8.8.8 1.1.1.1]: " WG_DNS
    WG_DNS=${WG_DNS:-"8.8.8.8 1.1.1.1"}

    # Создаем интерфейс
    echo "Creating WireGuard interface..."
    uci set network.wg0=interface
    uci set network.wg0.proto='wireguard'
    uci set network.wg0.private_key="$WG_PRIVATE_KEY"
    uci set network.wg0.listen_port='51820'
    uci add_list network.wg0.addresses="$WG_IP"
    uci set network.wg0.defaultroute='0'  # Отключаем маршрут по умолчанию

    # Добавляем DNS
    for dns in $WG_DNS; do
        uci add_list network.wg0.dns="$dns"
    done

    # Добавляем пира
    echo "Adding peer..."
    uci set network.wg0_client=wireguard_wg0
    uci set network.wg0_client.public_key="$WG_PUBLIC_KEY"
    
    if [ -n "$WG_PRESHARED_KEY" ]; then
        uci set network.wg0_client.preshared_key="$WG_PRESHARED_KEY"
    fi
    
    uci set network.wg0_client.route_allowed_ips='0'  # НЕ добавлять маршруты автоматически
    uci set network.wg0_client.persistent_keepalive='25'
    uci set network.wg0_client.endpoint_host="$WG_ENDPOINT"
    uci set network.wg0_client.endpoint_port="$WG_ENDPOINT_PORT"
    uci add_list network.wg0_client.allowed_ips='0.0.0.0/0'

    # Сохраняем настройки сети
    uci commit network

    # Настройка брандмауэра
    echo "Configuring firewall..."
    
    # Удаляем старую зону если есть
    for i in $(uci show firewall | grep "=zone" | cut -d[ -f2 | cut -d] -f1); do
        if [ "$(uci get firewall.@zone[$i].name 2>/dev/null)" = "vpn_wg0" ]; then
            uci delete firewall.@zone[$i]
        fi
    done    
    
    # Создаем новую зону
    uci add firewall zone
    uci set firewall.@zone[-1].name='vpn_wg0'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='ACCEPT'
    uci set firewall.@zone[-1].masq='1'
    uci add_list firewall.@zone[-1].network='wg0'

    # Разрешаем пересылку из LAN в VPN
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='lan'
    uci set firewall.@forwarding[-1].dest='vpn_wg0'

    # Разрешаем VPN в WAN
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='vpn_wg0'
    uci set firewall.@forwarding[-1].dest='wan'

    uci commit firewall

    # Перезапуск сервисов
    echo "Restarting services..."
    /etc/init.d/network restart
    sleep 3
    /etc/init.d/firewall restart

    echo ""
    echo "=========================================="
    echo "WireGuard setup completed!"
    echo "=========================================="
    echo ""
    echo "Checking WireGuard status:"
    wg show
    echo ""
    echo "Checking default route (should be WAN, not wg0):"
    ip route show | grep default
}

# Вызов функции
setup_wg_client
