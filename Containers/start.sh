#!/bin/sh
echo "Starting Xray container setup..."
sleep 1

SERVER_IP_ADDRESS=$(ping -c 1 $SERVER_ADDRESS | awk -F'[()]' '{print $2}')

NET_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|tun' | head -n1 | cut -d'@' -f1)

if [ -z "$SERVER_IP_ADDRESS" ]; then
  echo "Failed to resolve $SERVER_ADDRESS"
  echo "Please configure DNS on MikroTik"
  exit 1
fi

echo "Resolved $SERVER_ADDRESS to $SERVER_IP_ADDRESS"

# Setup TUN interface
ip tuntap del mode tun dev tun0 2>/dev/null
ip tuntap add mode tun dev tun0
ip addr add 172.31.200.1/30 dev tun0
ip link set dev tun0 up

# Routing - route everything through tun0 except Xray server
ip route del default 2>/dev/null
ip route add default via 172.31.200.2
ip route add $SERVER_IP_ADDRESS/32 via 172.18.20.5

# DNS configuration
rm -f /etc/resolv.conf
echo "nameserver 172.18.20.5" > /etc/resolv.conf

# Generate Xray config
cat <<EOF > /opt/xray/config/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 10800,
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": {
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "proxy",
      "settings": {
        "vnext": [
          {
            "address": "$SERVER_ADDRESS",
            "port": $SERVER_PORT,
            "users": [
              {
                "id": "$ID",
                "encryption": "$ENCRYPTION",
                "flow": "$FLOW",
                "level": 8
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "${NETWORK:-tcp}",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "$FP",
          "serverName": "$SNI",
          "publicKey": "$PBK",
          "shortId": "$SID",
          "spiderX": "${SPX:-}"
        },
        "xhttpSettings": {
          "path": "${XHTTP_PATH:-/}",
          "mode": "${XHTTP_MODE:-auto}",
          "host": "${XHTTP_HOST:-}"
        }
      },
      "mux": {
        "enabled": false,
        "concurrency": 50,
        "xudpConcurrency": 128,
        "xudpProxyUDP443": "allow"
      }
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": []
  }
}
EOF

echo "Preparing Xray and tun2socks..."

# Extract Xray
rm -rf /tmp/xray/ && mkdir -p /tmp/xray/
7z x /opt/xray/xray.7z -o/tmp/xray/ -y
chmod 755 /tmp/xray/xray

# Extract tun2socks
rm -rf /tmp/tun2socks/ && mkdir -p /tmp/tun2socks/
7z x /opt/tun2socks/tun2socks.7z -o/tmp/tun2socks/ -y
chmod 755 /tmp/tun2socks/tun2socks

echo "Starting Xray core..."
/tmp/xray/xray run -config /opt/xray/config/config.json &

# Wait for Xray to start
echo "Waiting for Xray SOCKS port 10800..."
for i in $(seq 1 15); do
    if nc -z 127.0.0.1 10800 2>/dev/null; then
        echo "✓ SOCKS port is up!"
        break
    fi
    echo "Attempt $i/15: Port not ready, retrying..."
    sleep 1
done

if ! nc -z 127.0.0.1 10800 2>/dev/null; then
    echo "ERROR: Xray failed to start"
    exit 1
fi

echo "Starting tun2socks..."
/tmp/tun2socks/tun2socks -loglevel warn \
    -tcp-sndbuf 3m -tcp-rcvbuf 3m \
    -device tun0 \
    -proxy socks5://127.0.0.1:10800 \
    -interface $NET_IFACE &

sleep 2
echo "✓ Container setup complete!"
