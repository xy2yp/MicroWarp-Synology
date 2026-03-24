#!/bin/sh
set -e

WG_CONF="/etc/wireguard/wg0.conf"
WG_IF="wg0"
WG_TABLE="51820"
TMP_WG_CONF=""
mkdir -p /etc/wireguard

log() {
    echo "==> [MicroWARP] $*"
}

error() {
    echo "==> [ERROR] $*" >&2
}

cleanup_wg() {
    ip -4 route del 0.0.0.0/0 dev "$WG_IF" table "$WG_TABLE" 2>/dev/null || true
    ip -4 rule del table main suppress_prefixlength 0 2>/dev/null || true
    ip -4 rule del not fwmark "$WG_TABLE" table "$WG_TABLE" 2>/dev/null || true
    ip link del "$WG_IF" 2>/dev/null || true
    if [ -n "$TMP_WG_CONF" ] && [ -f "$TMP_WG_CONF" ]; then
        rm -f "$TMP_WG_CONF"
    fi
}

build_runtime_wg_conf() {
    TMP_WG_CONF=$(mktemp)
    awk '
        /^\[Interface\]/ { print; section="interface"; next }
        /^\[Peer\]/ { print; section="peer"; next }
        /^[[:space:]]*$/ { next }
        section == "interface" && $0 ~ /^(PrivateKey|ListenPort|FwMark)[[:space:]]*=/ { print; next }
        section == "peer" && $0 ~ /^(PublicKey|PresharedKey|AllowedIPs|Endpoint|PersistentKeepalive)[[:space:]]*=/ { print; next }
    ' "$WG_CONF" > "$TMP_WG_CONF"

    if ! grep -q '^PrivateKey[[:space:]]*=' "$TMP_WG_CONF"; then
        error "wg0.conf 缺少 PrivateKey，无法启动 WireGuard。"
        return 1
    fi

    if ! grep -q '^\[Peer\]' "$TMP_WG_CONF"; then
        error "wg0.conf 缺少 [Peer] 段，无法启动 WireGuard。"
        return 1
    fi
}

start_wg_interface() {
    WG_ADDRESS=$(awk -F'=[[:space:]]*' '/^Address[[:space:]]*=/{print $2; exit}' "$WG_CONF")
    WG_MTU=$(awk -F'=[[:space:]]*' '/^MTU[[:space:]]*=/{print $2; exit}' "$WG_CONF")

    if [ -z "$WG_ADDRESS" ]; then
        error "wg0.conf 缺少 Address，无法配置 wg0 地址。"
        return 1
    fi

    cleanup_wg
    build_runtime_wg_conf

    ip link add dev "$WG_IF" type wireguard
    wg setconf "$WG_IF" "$TMP_WG_CONF"
    ip address add "$WG_ADDRESS" dev "$WG_IF"

    if [ -n "$WG_MTU" ]; then
        ip link set mtu "$WG_MTU" up dev "$WG_IF"
    else
        ip link set up dev "$WG_IF"
    fi

    wg set "$WG_IF" fwmark "$WG_TABLE"
    ip -4 rule add not fwmark "$WG_TABLE" table "$WG_TABLE"
    ip -4 rule add table main suppress_prefixlength 0
    ip -4 route add 0.0.0.0/0 dev "$WG_IF" table "$WG_TABLE"
    sysctl -q net.ipv4.conf.all.src_valid_mark=1

    rm -f "$TMP_WG_CONF"
    TMP_WG_CONF=""
}

# ==========================================
# 1. 账号全自动申请与配置生成 (阅后即焚)
# ==========================================
if [ ! -f "$WG_CONF" ]; then
    log "未检测到配置，正在全自动初始化 Cloudflare WARP..."
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) WGCF_ARCH="amd64" ;;
        aarch64) WGCF_ARCH="arm64" ;;
        *) error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    
    wget -qO wgcf "https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${WGCF_ARCH}"
    chmod +x wgcf
    
    log "正在向 CF 注册设备..."
    ./wgcf register --accept-tos > /dev/null
    
    log "正在生成 WireGuard 配置文件..."
    ./wgcf generate > /dev/null
    
    mv wgcf-profile.conf "$WG_CONF"
    
    # 【核心安全】阅后即焚：删除注册工具和生成的账号明文文件
    rm -f wgcf wgcf-account.toml
    log "节点配置生成成功！"
else
    log "检测到已有持久化配置，跳过注册。"
fi

# ==========================================
# 2. 强力洗白与内核兼容性处理 (魔改 wg0.conf)
# ==========================================
# 删除多余的内网 IP 路由和 DNS，让全局流量通过 wg0
sed -i '/^AllowedIPs.*/d' "$WG_CONF"
sed -i '/^\[Peer\]/a AllowedIPs = 0.0.0.0\/0' "$WG_CONF"
sed -i '/Address.*:/d' "$WG_CONF" 
sed -i '/^DNS.*/d' "$WG_CONF"

# 【新增：抗断流绝杀】强制注入 15 秒 UDP 心跳保活，对抗运营商 QoS 丢包
if ! grep -q "PersistentKeepalive" "$WG_CONF"; then
    sed -i '/\[Peer\]/a PersistentKeepalive = 15' "$WG_CONF"
else
    sed -i 's/PersistentKeepalive.*/PersistentKeepalive = 15/g' "$WG_CONF"
fi

# 【新增：防阻断绝杀】针对 HK/US 强校验机房，注入自定义优选 Endpoint IP
if [ -n "$ENDPOINT_IP" ]; then
    log "检测到自定义 Endpoint IP，正在覆盖默认节点: $ENDPOINT_IP"
    sed -i "s/^Endpoint.*/Endpoint = $ENDPOINT_IP/g" "$WG_CONF"
fi

# ==========================================
# 3. 拉起内核网卡
# ==========================================
log "正在启动 Linux 内核级 wg0 网卡..."
if ! start_wg_interface; then
    error "手动拉起 wg0 失败。"
    cleanup_wg
    exit 1
fi

log "当前出口 IP 已成功变更为："
# 获取最新的 CF 溯源 IP (加入 || true 防止网络波动导致脚本退出)
curl -s https://1.1.1.1/cdn-cgi/trace | grep ip= || true

# ==========================================
# 4. 启动 C 语言 SOCKS5 代理服务 (带高级参数绑定)
# ==========================================
# 读取环境变量，如果未设置则使用默认值 0.0.0.0 和 1080
LISTEN_ADDR=${BIND_ADDR:-"0.0.0.0"}
LISTEN_PORT=${BIND_PORT:-"1080"}

if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    log "身份认证已开启 (User: $SOCKS_USER)"
    log "MicroSOCKS 引擎已启动，正在监听 ${LISTEN_ADDR}:${LISTEN_PORT}"
    # 使用 exec 接管进程，实现 Zero-Overhead 的底层进程控制
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" -u "$SOCKS_USER" -P "$SOCKS_PASS"
else
    log "未设置密码，当前为公开访问模式"
    log "MicroSOCKS 引擎已启动，正在监听 ${LISTEN_ADDR}:${LISTEN_PORT}"
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT"
fi
