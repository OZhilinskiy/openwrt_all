установка wg
bash <(wget -O - https://raw.githubusercontent.com/OZhilinskiy/openwrt_all/main/wireguard-install.sh)

# Download the script first
wget https://raw.githubusercontent.com/OZhilinskiy/openwrt_all/main/wireguard-install.sh

# Review the script content
cat wireguard-install.sh
# or use less: less wireguard-install.sh

# Make it executable
chmod +x wireguard-install.sh

# Run it
./wireguard-install.sh
