#!/usr/bin/env bash
# VLESS + TCP + Reality + xtls-rprx-vision installer for a user's own VPS.
set -Eeuo pipefail

XRAY_INSTALLER_URL="${XRAY_INSTALLER_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

die() { echo "错误：$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1，请先安装后重试"; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)); }
valid_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; }
valid_hex() { [[ "$1" =~ ^[0-9a-fA-F]+$ ]]; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9.-]+$ || "$1" =~ ^\[[0-9A-Fa-f:]+\]$ ]]; }
valid_sni() { [[ "$1" =~ ^[A-Za-z0-9.-]+$ && "$1" == *.* && "$1" != .* && "$1" != *. ]]; }
valid_dest() {
  local host="${1%:*}" port="${1##*:}"
  [[ "$1" == *:* && "$host" != "$1" ]] || return 1
  valid_host "$host" && valid_port "$port"
}

[[ "$(id -u)" == "0" ]] || die "请使用 root 运行，或使用 sudo bash install.sh"
need curl
need openssl
need sed
need awk
need grep
need systemctl
need install

SERVER_ADDRESS="${SERVER_ADDRESS:-}"
if [[ -z "$SERVER_ADDRESS" ]]; then
  SERVER_ADDRESS="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
fi
read -r -p "服务器公网 IP 或域名 [${SERVER_ADDRESS:-必填}]: " input
SERVER_ADDRESS="${input:-$SERVER_ADDRESS}"
[[ -n "$SERVER_ADDRESS" ]] || die "服务器地址不能为空"
valid_host "$SERVER_ADDRESS" || die "服务器地址只能包含域名、IPv4 或方括号包裹的 IPv6"

PORT="${PORT:-443}"
read -r -p "服务端口 [${PORT}]: " input
PORT="${input:-$PORT}"
valid_port "$PORT" || die "端口必须是 1-65535 的数字"

SNI="${SNI:-www.cloudflare.com}"
read -r -p "Reality SNI [${SNI}]: " input
SNI="${input:-$SNI}"
valid_sni "$SNI" || die "SNI 格式不正确"

DEST="${DEST:-${SNI}:443}"
read -r -p "Reality dest [${DEST}]: " input
DEST="${input:-$DEST}"
valid_dest "$DEST" || die "dest 应为 host:port 格式"

UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
valid_uuid "$UUID" || die "UUID 格式不正确"
SHORT_ID="${SHORT_ID:-$(openssl rand -hex 8)}"
valid_hex "$SHORT_ID" || die "SHORT_ID 必须是十六进制字符串"

tmp_installer="$(mktemp)"
trap 'rm -f "$tmp_installer"' EXIT
echo "正在下载 Xray 官方安装器：$XRAY_INSTALLER_URL"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$XRAY_INSTALLER_URL" -o "$tmp_installer"
grep -q "Xray" "$tmp_installer" || die "下载内容不像 Xray 官方安装器，已中止"
bash "$tmp_installer" install

XRAY_BIN="$(command -v xray || true)"
[[ -x "$XRAY_BIN" ]] || XRAY_BIN="/usr/local/bin/xray"
[[ -x "$XRAY_BIN" ]] || die "找不到 xray 可执行文件"

# Xray v26+ prints PrivateKey/Password (PublicKey); older releases print Private key/Public key.
key_output="$($XRAY_BIN x25519 2>/dev/null)" || die "无法生成 Reality 密钥，请检查 Xray 版本"
PRIVATE_KEY="$(printf '%s\n' "$key_output" | awk '
  index($0, "PrivateKey:") == 1 || index($0, "Private key:") == 1 {
    sub(/^[^:]*:[[:space:]]*/, ""); print; exit
  }')"
PUBLIC_KEY="$(printf '%s\n' "$key_output" | awk '
  index($0, "Password (PublicKey):") == 1 ||
  index($0, "Password:") == 1 ||
  index($0, "PublicKey:") == 1 ||
  index($0, "Public key:") == 1 {
    sub(/^[^:]*:[[:space:]]*/, ""); print; exit
  }')"
[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "无法解析 Reality 密钥输出"

install -d -m 0755 "$(dirname "$XRAY_CONFIG")"
if [[ -f "$XRAY_CONFIG" ]]; then
  cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
fi

tmp_config="$(mktemp)"
trap 'rm -f "$tmp_installer" "$tmp_config"' EXIT
cat > "$tmp_config" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "target": "${DEST}",
        "xver": 0,
        "serverNames": ["${SNI}"],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": ["${SHORT_ID}"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
JSON

if ! validation_output="$("$XRAY_BIN" run -test -config "$tmp_config" 2>&1)"; then
  echo "$validation_output" >&2
  die "Xray 配置校验失败，请根据上面的具体错误修正"
fi
install -m 0600 "$tmp_config" "$XRAY_CONFIG"
systemctl enable xray >/dev/null
systemctl restart xray
systemctl --no-pager --full status xray | sed -n '1,12p'

echo
echo "安装完成。请确认云厂商安全组和系统防火墙已放行 TCP ${PORT}。"
echo "服务器地址: ${SERVER_ADDRESS}"
echo "端口: ${PORT}"
echo "UUID: ${UUID}"
echo "Flow: xtls-rprx-vision"
echo "SNI: ${SNI}"
echo "PublicKey: ${PUBLIC_KEY}"
echo "ShortID: ${SHORT_ID}"
echo
echo "VLESS 分享链接（请妥善保管）："
echo "vless://${UUID}@${SERVER_ADDRESS}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#reality"
