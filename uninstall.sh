#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$(id -u)" == "0" ]] || { echo "请使用 root 运行" >&2; exit 1; }
if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now xray 2>/dev/null || true
fi
if [[ -x /usr/local/bin/xray ]]; then
  rm -f /usr/local/bin/xray
fi
rm -f /usr/local/etc/xray/config.json
echo "已停止 Xray 并删除主配置；防火墙规则和备份文件未自动删除。"
