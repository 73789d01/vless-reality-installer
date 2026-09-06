#!/usr/bin/env bash
# VLESS + TCP + Reality + xtls-rprx-vision toolbox for an authorized VPS.
set -Eeuo pipefail

XRAY_INSTALLER_URL="${XRAY_INSTALLER_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_META="/usr/local/etc/xray/client.env"
XRAY_SERVICE="/etc/systemd/system/xray.service"
DEFAULT_SNI="${SNI:-www.cloudflare.com}"
PORT_START=20000
PORT_END=60000

die() { echo "错误：$*" >&2; return 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1"; }
prompt() {
  local message="$1" variable="$2"
  if [[ -r /dev/tty ]]; then
    IFS= read -r -p "$message" "$variable" </dev/tty
  else
    IFS= read -r -p "$message" "$variable"
  fi
}
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
port_in_use() { ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\]):${1}$"; }
find_available_port() {
  local i random_hex candidate
  for i in {1..30}; do
    random_hex="$(openssl rand -hex 2)"
    candidate=$((16#$random_hex % (PORT_END - PORT_START + 1) + PORT_START))
    port_in_use "$candidate" || { printf '%s' "$candidate"; return; }
  done
  die "找不到可用随机端口，请手动指定"
}
get_xray_bin() {
  XRAY_BIN="$(command -v xray || true)"
  [[ -x "${XRAY_BIN:-}" ]] || XRAY_BIN="/usr/local/bin/xray"
  [[ -x "$XRAY_BIN" ]] || die "找不到 xray 可执行文件"
}
backup_config() {
  [[ -f "$XRAY_CONFIG" ]] && cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
}
config_value() {
  local key="$1" default="$2" value
  [[ -f "$XRAY_CONFIG" ]] || { printf '%s' "$default"; return; }
  value="$(sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" "$XRAY_CONFIG" | head -n1)"
  [[ -n "$value" ]] || value="$(sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\[\"([^\"]+)\".*/\1/p" "$XRAY_CONFIG" | head -n1)"
  printf '%s' "${value:-$default}"
}
config_port() { [[ -f "$XRAY_CONFIG" ]] || return 0; sed -nE 's/.*"port"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$XRAY_CONFIG" | head -n1; }
config_uuid() { [[ -f "$XRAY_CONFIG" ]] || return 0; sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$XRAY_CONFIG" | head -n1; }
config_private_key() { [[ -f "$XRAY_CONFIG" ]] || return 0; sed -nE 's/.*"privateKey"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$XRAY_CONFIG" | head -n1; }
write_service() {
  cat > "$XRAY_SERVICE" <<UNIT
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
WorkingDirectory=$(dirname "$XRAY_BIN")

[Install]
WantedBy=multi-user.target
UNIT
  chmod 0644 "$XRAY_SERVICE"
}
restart_xray() {
  systemctl daemon-reload
  systemctl enable xray >/dev/null
  systemctl restart xray
  systemctl is-active --quiet xray || {
    systemctl --no-pager --full status xray >&2 || true
    journalctl -u xray -n 30 --no-pager >&2 || true
    die "Xray 服务启动失败"
  }
}
generate_keys() {
  local output
  output="$("$XRAY_BIN" x25519 2>/dev/null)" || die "无法生成 Reality 密钥"
  PRIVATE_KEY="$(printf '%s\n' "$output" | awk '
    index($0, "PrivateKey:") == 1 || index($0, "Private key:") == 1 {
      sub(/^[^:]*:[[:space:]]*/, ""); print; exit
    }')"
  PUBLIC_KEY="$(printf '%s\n' "$output" | awk '
    index($0, "Password (PublicKey):") == 1 || index($0, "Password:") == 1 ||
    index($0, "PublicKey:") == 1 || index($0, "Public key:") == 1 {
      sub(/^[^:]*:[[:space:]]*/, ""); print; exit
    }')"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "无法解析 Reality 密钥"
}
write_config() {
  install -d -m 0755 "$(dirname "$XRAY_CONFIG")"
  backup_config
  local tmp_config
  tmp_config="$(mktemp "${TMPDIR:-/tmp}/xray-config.XXXXXX.json")"
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
  "$XRAY_BIN" run -test -format json -config "$tmp_config" >/dev/null || {
    rm -f "$tmp_config"
    die "Xray 配置校验失败"
  }
  install -m 0600 "$tmp_config" "$XRAY_CONFIG"
  rm -f "$tmp_config"
  printf 'PUBLIC_KEY=%q\nSERVER_ADDRESS=%q\n' "$PUBLIC_KEY" "${SERVER_ADDRESS:-}" > "${XRAY_META}.tmp"
  install -m 0600 "${XRAY_META}.tmp" "$XRAY_META"
  rm -f "${XRAY_META}.tmp"
}
install_xray() {
  local tmp
  tmp="$(mktemp)"
  if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$XRAY_INSTALLER_URL" -o "$tmp"; then
    rm -f "$tmp"
    die "下载 Xray 官方安装器失败"
  fi
  grep -q "Xray" "$tmp" || { rm -f "$tmp"; die "下载内容不像 Xray 官方安装器"; }
  echo "正在执行 Xray 官方安装器..."
  if ! bash "$tmp" install </dev/null; then
    rm -f "$tmp"
    die "Xray 官方安装器执行失败，请检查上方输出"
  fi
  rm -f "$tmp"
  get_xray_bin
  "$XRAY_BIN" version >/dev/null 2>&1 || die "Xray 安装器执行完成，但未找到可用的 Xray 二进制"
}
ask_values() {
  SERVER_ADDRESS="${SERVER_ADDRESS:-$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)}"
  prompt "服务器公网 IP 或域名 [${SERVER_ADDRESS:-必填}]: " input
  SERVER_ADDRESS="${input:-$SERVER_ADDRESS}"
  [[ -n "$SERVER_ADDRESS" ]] && valid_host "$SERVER_ADDRESS" || die "服务器地址格式不正确"
  PORT="${PORT:-$(find_available_port)}"
  prompt "服务端口 [${PORT}]: " input
  PORT="${input:-$PORT}"
  valid_port "$PORT" || die "端口格式不正确"
  SNI="${SNI:-$DEFAULT_SNI}"
  prompt "Reality SNI [${SNI}]: " input
  SNI="${input:-$SNI}"
  valid_sni "$SNI" || die "SNI 格式不正确"
  DEST="${DEST:-${SNI}:443}"
  prompt "Reality dest [${DEST}]: " input
  DEST="${input:-$DEST}"
  valid_dest "$DEST" || die "dest 格式不正确"
}
install_flow() {
  ask_values
  UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
  SHORT_ID="${SHORT_ID:-$(openssl rand -hex 8)}"
  valid_uuid "$UUID" || die "UUID 格式不正确"
  valid_hex "$SHORT_ID" || die "ShortID 必须是十六进制字符串"
  install_xray
  generate_keys
  write_config
  write_service
  restart_xray
  show_info
}
show_info() {
  local port uuid sni dest short_id public_key address
  if [[ ! -f "$XRAY_CONFIG" ]]; then
    echo "尚未检测到 Xray 配置，请先选择 1 安装，或输入 TZ 进入修复。"
    return 0
  fi
  port="$(config_port)"; uuid="$(config_uuid)"
  sni="$(config_value serverNames "$DEFAULT_SNI")"
  dest="$(config_value target "${sni}:443")"
  short_id="$(config_value shortIds "")"
  public_key=""
  address="${SERVER_ADDRESS:-}"
  if [[ -f "$XRAY_META" ]]; then
    unset PUBLIC_KEY META_ADDRESS
    # shellcheck disable=SC1090
    source "$XRAY_META"
    public_key="${PUBLIC_KEY:-}"
    address="${address:-${SERVER_ADDRESS:-}}"
  fi
  echo
  echo "Xray 状态：$(systemctl is-active xray 2>/dev/null || echo 未运行)"
  echo "配置文件：$XRAY_CONFIG"
  echo "监听端口：${port:-未知}"
  echo "UUID：${uuid:-未知}"
  echo "SNI：${sni:-未知}"
  echo "目标：${dest:-未知}"
  echo "ShortID：${short_id:-未知}"
  echo "PublicKey：${public_key:-未知}"
  [[ -n "$address" && -n "$port" && -n "$uuid" && -n "$public_key" ]] &&
    echo "VLESS 链接：vless://${uuid}@${address}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#reality"
}
uninstall_flow() {
  prompt "确认卸载？输入 YES 继续： " confirm
  [[ "$confirm" == "YES" ]] || { echo "已取消"; return; }
  systemctl disable --now xray 2>/dev/null || true
  rm -f "$XRAY_SERVICE" /usr/local/bin/xray "$XRAY_CONFIG" "$XRAY_META"
  systemctl daemon-reload
  echo "已停止并删除 Xray 服务及主配置；备份和防火墙规则未删除。"
}
modify_flow() {
  get_xray_bin
  local old_port old_sni old_dest old_uuid answer
  old_port="$(config_port)"; old_sni="$(config_value serverNames "$DEFAULT_SNI")"
  old_dest="$(config_value target "${old_sni}:443")"; old_uuid="$(config_uuid)"
  PORT="$old_port"; SNI="$old_sni"; DEST="$old_dest"; UUID="$old_uuid"
  prompt "新端口 [${PORT}，回车保持]: " answer; PORT="${answer:-$PORT}"
  prompt "新 SNI [${SNI}，回车保持]: " answer; SNI="${answer:-$SNI}"
  prompt "新 dest [${DEST}，回车保持]: " answer; DEST="${answer:-$DEST}"
  valid_port "$PORT" || die "端口格式不正确"
  valid_sni "$SNI" || die "SNI 格式不正确"
  valid_dest "$DEST" || die "dest 格式不正确"
  SHORT_ID="$(config_value shortIds "$(openssl rand -hex 8)")"
  PRIVATE_KEY="$(config_private_key)"
  [[ -n "$PRIVATE_KEY" ]] || generate_keys
  write_config; write_service; restart_xray
  echo "配置已更新。"
}
repair_flow() {
  [[ -x /usr/local/bin/xray ]] || install_xray
  get_xray_bin
  if [[ ! -f "$XRAY_CONFIG" ]]; then install_flow; return; fi
  if ! "$XRAY_BIN" run -test -format json -config "$XRAY_CONFIG" >/dev/null 2>&1; then
    echo "当前配置校验失败，进入修改流程。"
    modify_flow
  else
    write_service; restart_xray; echo "服务文件已修复，Xray 当前运行正常。"
  fi
}
regenerate_flow() {
  get_xray_bin
  PORT="$(config_port)"; UUID="$(config_uuid)"
  SNI="$(config_value serverNames "$DEFAULT_SNI")"
  DEST="$(config_value target "${SNI}:443")"
  SHORT_ID="$(openssl rand -hex 8)"
  generate_keys; write_config; write_service; restart_xray
  echo "密钥已重新生成，旧链接已失效。PublicKey: $PUBLIC_KEY"
}
toolbox() {
  while true; do
    echo
    echo "===== VLESS Reality 工具箱 ====="
    echo "1) 安装或重新安装"
    echo "2) 查看状态和配置"
    echo "3) 卸载"
    echo "TZ) 修复 / 修改 / 密钥 / 日志"
    echo "4) 退出"
    prompt "请输入命令： " command
    case "${command^^}" in
      1) install_flow ;;
      2) show_info ;;
      3) uninstall_flow ;;
      TZ)
        echo "1) 修复服务  2) 修改配置  3) 重新生成密钥  4) 查看日志  0) 返回"
        prompt "请选择： " command
        case "$command" in
          1) repair_flow ;;
          2) modify_flow ;;
          3) regenerate_flow ;;
          4) journalctl -u xray -n 50 --no-pager ;;
          0|"") ;;
          *) echo "无效选项" ;;
        esac ;;
      4|0|"") break ;;
      *) echo "无效命令，请输入 1、2、3、TZ 或 4" ;;
    esac
  done
}

[[ "$(id -u)" == "0" ]] || die "请使用 root 运行，或使用 sudo bash install.sh"
for command in curl openssl sed awk grep systemctl install mktemp ss; do need "$command"; done
if [[ $# -gt 0 ]]; then
  case "${1^^}" in
    1|INSTALL) install_flow ;;
    2|STATUS|SHOW) show_info ;;
    3|UNINSTALL) uninstall_flow ;;
    TZ|REPAIR|MODIFY) repair_flow ;;
    *) die "用法：sudo bash install.sh [1|2|3|TZ]" ;;
  esac
else
  toolbox
fi
