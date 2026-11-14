#!/usr/bin/env bash
# =============================================================================
# site-gw —— Armbian 旁路网关一键安装 WireGuard 隧道（零参数）
#
#   用法：
#     cd /opt/wireguard                      # 把 wg-easy 导出的配置 scp 到这个目录
#     curl -fsSL https://raw.githubusercontent.com/thatinjury2011/wg-easy/master/site-gw/install.sh | sudo bash
#
#   脚本做的事：装依赖 → 把配置装成 wg0 常驻隧道 → 开机自启 → 留一份副本供重跑
#   不触碰：Docker 容器/网络/iptables 链、FORWARD 默认策略、主机路由、nps、npm
#
#   可选参数（日常不用）：
#     --dry-run        只打印动作，不改任何东西
#     --rollback       停用并移除本脚本安装的一切
#     --conf=<路径>    指定配置文件（默认自动查找）
#     --lan=<CIDR>     本站 LAN 网段（默认自动探测默认路由网卡）
#     --mtu=<N>        覆盖 MTU（默认：1420 自动降为 1380）
#     --force          允许 AllowedIPs 含 0.0.0.0/0（全流量走 VPN）
# =============================================================================
set -euo pipefail

CONF_DIR="/opt/wireguard"
IFACE="wg0"
DST_CONF="/etc/wireguard/${IFACE}.conf"
SYSCTL_FILE="/etc/sysctl.d/99-site-gw.conf"
DROPIN_DIR="/etc/systemd/system/wg-quick@${IFACE}.service.d"
DROPIN_FILE="${DROPIN_DIR}/50-site-gw.conf"
HASH_FILE="/var/lib/site-gw/config.sha256"
UNIT="wg-quick@${IFACE}"

DRY_RUN=0; FORCE=0; ROLLBACK=0; LAN_CIDR=""; NEW_MTU=""; CONF_ARG=""

log()  { printf '\033[1;32m[site-gw]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[site-gw]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[site-gw]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'HELP'
site-gw 零参数安装：
  curl -fsSL https://raw.githubusercontent.com/thatinjury2011/wg-easy/master/site-gw/install.sh | sudo bash
配置文件查找顺序：当前目录唯一的 *.conf → ./1.conf → ./wg0.conf → /opt/wireguard/1.conf → /opt/wireguard/*.conf（唯一时）
可选：--dry-run | --rollback | --conf=<路径> | --lan=192.168.31.0/24 | --mtu=1380 | --force
HELP
}

for a in "$@"; do
  case "$a" in
    --dry-run)  DRY_RUN=1 ;;
    --force)    FORCE=1 ;;
    --rollback) ROLLBACK=1 ;;
    --lan=*)    LAN_CIDR="${a#*=}" ;;
    --mtu=*)    NEW_MTU="${a#*=}" ;;
    --conf=*)   CONF_ARG="${a#*=}" ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "未知参数: $a（-h 查看用法）" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "请用 root 运行：curl -fsSL https://raw.githubusercontent.com/thatinjury2011/wg-easy/master/site-gw/install.sh | sudo bash"

run() {
  if [[ ${DRY_RUN} -eq 1 ]]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi
}

write_file() {
  local dest="$1" mode="${2:-644}"
  if [[ ${DRY_RUN} -eq 1 ]]; then
    printf '  [dry-run] 写入 %s (mode %s)\n' "$dest" "$mode"
    cat > /dev/null
  else
    mkdir -p "$(dirname "$dest")"
    cat > "$dest"
    chmod "$mode" "$dest"
    printf '  ok 写入 %s\n' "$dest"
  fi
}

find_conf() {
  local arr=() c
  shopt -s nullglob
  arr=(./*.conf)
  if ((${#arr[@]} == 1)); then shopt -u nullglob; printf '%s' "${arr[0]}"; return 0; fi
  for c in ./1.conf ./wg0.conf "${CONF_DIR}/1.conf" "${CONF_DIR}/wg0.conf" /root/1.conf; do
    if [[ -f $c ]]; then shopt -u nullglob; printf '%s' "$c"; return 0; fi
  done
  arr=("${CONF_DIR}"/*.conf)
  if ((${#arr[@]} == 1)); then shopt -u nullglob; printf '%s' "${arr[0]}"; return 0; fi
  shopt -u nullglob
  return 1
}

# ---------------------------------------------------------------- 回滚
if [[ ${ROLLBACK} -eq 1 ]]; then
  log "回滚：停用并移除 ${IFACE}"
  run systemctl disable --now "$UNIT" || true
  run rm -f "$DST_CONF" "$DROPIN_FILE" "$HASH_FILE"
  run rmdir "$DROPIN_DIR" 2>/dev/null || true
  run systemctl daemon-reload || true
  warn "已回滚。net.ipv4.ip_forward=1 保留（Docker 也依赖它）。"
  exit 0
fi

# ---------------------------------------------------------------- 找配置
if [[ -n ${CONF_ARG} ]]; then
  SRC_CONF=${CONF_ARG}
elif ! SRC_CONF="$(find_conf)"; then
  cat >&2 <<'MSG'
[site-gw] 当前目录没有找到配置文件（也没有找到 /opt/wireguard/*.conf）。
先把 wg-easy 面板导出的配置 scp 过来，再在同一个目录里执行：

  scp 1.conf root@<这台设备>:/opt/wireguard/1.conf
  cd /opt/wireguard && curl -fsSL https://raw.githubusercontent.com/thatinjury2011/wg-easy/master/site-gw/install.sh | sudo bash

如果目录里有多个 .conf 无法自动选择，用 --conf=<路径> 指定。
MSG
  exit 1
fi
[[ -f ${SRC_CONF} ]] || die "配置文件不存在：${SRC_CONF}"
log "使用配置文件：$(cd "$(dirname "$SRC_CONF")" && pwd)/$(basename "$SRC_CONF")"

grep -q '^\[Interface\]' "$SRC_CONF" || die "不是有效的 wg-quick 配置（缺少 [Interface]）"
grep -q '^\[Peer\]'      "$SRC_CONF" || die "缺少 [Peer] 段"
if grep -qiE '^[[:space:]]*AllowedIPs[[:space:]]*=.*(0\.0\.0\.0/0|::/0)' "$SRC_CONF" && [[ ${FORCE} -eq 0 ]]; then
  die "AllowedIPs 含 0.0.0.0/0，会让本机全部流量走 VPN，影响 Docker/npm/nps。确认需要请加 --force"
fi
command -v docker >/dev/null 2>&1 && log "检测到 Docker（不会触碰容器、网络、Docker 的 iptables 链）"

# ---------------------------------------------------------------- 依赖
pkgs=()
command -v wg       >/dev/null 2>&1 || pkgs+=(wireguard-tools)
command -v iptables >/dev/null 2>&1 || pkgs+=(iptables)
if ((${#pkgs[@]} > 0)); then
  log "安装：${pkgs[*]}（不执行 apt upgrade，不动内核）"
  run apt-get update -qq
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${pkgs[@]}"
else
  log "wireguard-tools / iptables 已存在，跳过安装"
fi
run modprobe wireguard || true

# ---------------------------------------------------------------- LAN 网段
if [[ -z ${LAN_CIDR} ]]; then
  def_if="$(ip -o -4 route show to default | awk '{print $5}' | head -n1)"
  LAN_CIDR="$(ip -o -4 addr show dev "${def_if}" | awk '{print $4}' | head -n1)"
  log "自动探测 LAN 网段：${LAN_CIDR}（网卡 ${def_if}）"
fi
[[ -n ${LAN_CIDR} ]] || die "无法确定 LAN 网段，请用 --lan=192.168.31.0/24 指定"

# ---------------------------------------------------------------- 渲染配置
tmp_cfg="$(mktemp)"; tmp_cfg2="$(mktemp)"
trap 'rm -f "$tmp_cfg" "$tmp_cfg2"' EXIT

sed 's/\r$//' "$SRC_CONF" > "$tmp_cfg"
sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$tmp_cfg"

if [[ -z ${NEW_MTU} ]] && grep -qE '^[[:space:]]*MTU[[:space:]]*=[[:space:]]*1420' "$tmp_cfg"; then
  NEW_MTU=1380
fi
if [[ -n ${NEW_MTU} ]]; then
  if grep -qiE '^[[:space:]]*MTU[[:space:]]*=' "$tmp_cfg"; then
    sed -i "s/^[[:space:]]*MTU[[:space:]]*=.*/MTU = ${NEW_MTU}/" "$tmp_cfg"
  else
    sed -i "0,/^\[Peer\]/s//MTU = ${NEW_MTU}\n\n[Peer]/" "$tmp_cfg"
  fi
  log "MTU = ${NEW_MTU}"
fi

if ! grep -q 'site-gw:masq' "$tmp_cfg"; then
  awk -v lan="${LAN_CIDR}" '
    /^\[Peer\]/ && !done {
      print "PostUp   = iptables -t nat -A POSTROUTING -s " lan " -o %i -j MASQUERADE   # site-gw:masq";
      print "PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT   # site-gw:fwd";
      print "PostUp   = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu   # site-gw:mss";
      print "PostDown = iptables -t nat -D POSTROUTING -s " lan " -o %i -j MASQUERADE   # site-gw:masq";
      print "PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT   # site-gw:fwd";
      print "PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu   # site-gw:mss";
      print "";
      done=1
    }
    { print }
  ' "$tmp_cfg" > "$tmp_cfg2"
  mv "$tmp_cfg2" "$tmp_cfg"
  log "已注入本站 NAT/转发/MSS 规则（${LAN_CIDR}）"
fi

if [[ ${DRY_RUN} -eq 1 ]]; then
  echo "  ---- 将写入 ${DST_CONF} 的内容（私钥已隐藏）----"
  sed -E 's/^([[:space:]]*(PrivateKey|PresharedKey)[[:space:]]*=[[:space:]]*).*/\1<hidden>/I' "$tmp_cfg" | sed 's/^/  | /'
  echo "  ------------------------------------------------"
fi

write_file "$DST_CONF" 600 < "$tmp_cfg"

# 留一份副本，方便以后在任意目录重跑（内容与已启用的一致）
src_abs="$(cd "$(dirname "$SRC_CONF")" && pwd)/$(basename "$SRC_CONF")"
cache_conf="${CONF_DIR}/1.conf"
if [[ ${src_abs} != "${cache_conf}" ]]; then
  write_file "$cache_conf" 600 < "$tmp_cfg"
fi

# ---------------------------------------------------------------- 转发持久化
if grep -qsE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' /etc/sysctl.conf "$SYSCTL_FILE"; then
  log "ip_forward 已持久化，跳过"
else
  printf 'net.ipv4.ip_forward=1\n' | write_file "$SYSCTL_FILE" 644
fi
run sysctl --system >/dev/null 2>&1 || run sysctl -w net.ipv4.ip_forward=1

# ---------------------------------------------------------------- 开机顺序
printf '[Unit]\nAfter=network-online.target\nWants=network-online.target\n' | write_file "$DROPIN_FILE" 644

# ---------------------------------------------------------------- 启动（配置没变就不重启）
new_hash="$(sha256sum "$tmp_cfg" | awk '{print $1}')"
old_hash="$(cat "$HASH_FILE" 2>/dev/null || true)"
run systemctl daemon-reload
if systemctl is-active --quiet "$UNIT" 2>/dev/null && [[ ${new_hash} == "${old_hash}" ]]; then
  log "配置未变化且隧道已运行，无需重启"
else
  if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
    log "应用新配置（约 2 秒中断）"
    run systemctl restart "$UNIT"
  else
    run systemctl enable "$UNIT"
    run systemctl start "$UNIT"
  fi
  if [[ ${DRY_RUN} -eq 0 ]]; then
    mkdir -p "$(dirname "$HASH_FILE")"
    printf '%s\n' "$new_hash" > "$HASH_FILE"
  fi
fi

# ---------------------------------------------------------------- 验证
if [[ ${DRY_RUN} -eq 0 ]]; then
  sleep 2
  echo
  log "---- 验证 ----"
  systemctl is-active "$UNIT" || true
  wg show "$IFACE" || true
  echo
  log "本机公钥：$(wg pubkey < <(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$DST_CONF"))"
  echo
  log "改动：${DST_CONF}(600) / ${cache_conf}(600) / ${SYSCTL_FILE} / ${DROPIN_FILE} / ${UNIT} enabled"
  log "未触碰：Docker、FORWARD 默认策略、主机路由、nps、npm"
  log "回滚：curl -fsSL https://raw.githubusercontent.com/thatinjury2011/wg-easy/master/site-gw/install.sh | sudo bash -s -- --rollback"
fi