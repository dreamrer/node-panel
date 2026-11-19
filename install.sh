#!/usr/bin/env bash
# node-panel · 一键安装与管理
#
#   安装:  bash <(curl -fsSL https://raw.githubusercontent.com/dreamrer/node-panel/main/install.sh)
#   管理:  np
#
set -euo pipefail

REPO="dreamrer/node-panel"
GH="https://github.com/$REPO/releases/latest/download"
MIRROR="https://dl.quasarapp.net/panel"
NAME="node-panel"
DIR="/opt/node-panel"
BIN="$DIR/$NAME"
CONF="$DIR/config.json"
SVC="node-panel"
RUNAS="nodepanel"
CLI="/usr/local/bin/np"
CADDYFILE="/etc/caddy/Caddyfile"
SITE="/etc/caddy/conf.d/node-panel.caddy"
PORT="${NP_PORT:-8080}"

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
info(){ printf '%s\n' "${B}▸${N} $*" >&2; }
ok(){   printf '%s\n' "${G}✓${N} $*" >&2; }
warn(){ printf '%s\n' "${Y}!${N} $*" >&2; }
die(){  printf '%s\n' "${R}✗${N} $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

need_root(){ [ "$(id -u)" = 0 ] || die "请用 root 运行"; }
need_systemd(){ have systemctl || die "需要 systemd（本脚本不支持 OpenRC / 容器内无 init 的环境）"; }
arch(){ case "$(uname -m)" in
  x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;;
  *) die "不支持的架构 $(uname -m)（只提供 amd64 / arm64）" ;; esac; }
installed(){ [ -x "$BIN" ] && [ -f "/etc/systemd/system/$SVC.service" ]; }

# ---------- 下载（GitHub 拉不动自动切镜像） ----------
fetch(){ curl -fsSL --connect-timeout 10 -m 600 -o "$2" "$1"; }
get_asset(){
  local f="$1" d="$2"
  fetch "$GH/$f" "$d" && return 0
  warn "GitHub 下载失败，改用镜像"
  fetch "$MIRROR/$f" "$d" || die "下载 $f 失败（GitHub 与镜像都不通，检查服务器网络/DNS）"
}
# 下载并校验，结果放进 $1 指定的目录，回显二进制路径
pull_binary(){
  local tmp="$1" a want got src
  a=$(arch)
  info "下载 $NAME ($a)"
  get_asset "$NAME-linux-$a.tar.gz" "$tmp/p.tgz"
  get_asset "SHA256SUMS" "$tmp/sums"
  want=$(awk -v f="$NAME-linux-$a.tar.gz" '$2==f{print $1}' "$tmp/sums" | head -1)
  [ -n "$want" ] || die "SHA256SUMS 里没有 $NAME-linux-$a.tar.gz"
  got=$(sha256sum "$tmp/p.tgz" | cut -d' ' -f1)
  [ "$want" = "$got" ] || die "校验不一致（下载不完整或被篡改），已中止"
  ok "校验通过 ${got:0:16}…"
  tar -xzf "$tmp/p.tgz" -C "$tmp"
  src=$(find "$tmp" -type f -size +1M ! -name '*.tgz' ! -name '*.tar.gz' | head -1)
  [ -n "$src" ] || die "压缩包里没找到程序文件"
  printf '%s' "$src"
}

# ---------- 面板本体 ----------
ensure_user(){ id "$RUNAS" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$RUNAS"; }
gen_pass(){ openssl rand -hex 10 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 20; }
write_conf(){
  [ -f "$CONF" ] && { info "沿用已有 config.json"; return 0; }
  cat > "$CONF" <<JSON
{
  "listen": "127.0.0.1:$PORT",
  "admin_user": "admin",
  "admin_password": "$(gen_pass)",
  "data_dir": "data",
  "trust_proxy": true
}
JSON
  chmod 600 "$CONF"
}
write_service(){
  cat > "/etc/systemd/system/$SVC.service" <<UNIT
[Unit]
Description=$NAME
After=network.target

[Service]
User=$RUNAS
Group=$RUNAS
WorkingDirectory=$DIR
ExecStart=$BIN -c $CONF
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable "$SVC" >/dev/null 2>&1 || true
}
panel_up(){
  local i
  systemctl restart "$SVC"
  for i in $(seq 1 15); do
    curl -fsS -m 3 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && { ok "面板已启动"; return 0; }
    sleep 1
  done
  warn "面板没能在 15 秒内就绪，最近日志："
  journalctl -u "$SVC" -n 15 --no-pager 2>/dev/null || true
  return 1
}

# ---------- 反向代理 ----------
ports_busy(){ ss -ltn 2>/dev/null | grep -qE '[:.](80|443)[[:space:]]'; }
ports_owner(){ ss -ltnp 2>/dev/null | grep -E '[:.](80|443)[[:space:]]' | grep -oE 'users:\(\("[^"]+' | grep -oE '"[^"]+' | tr -d '"' | sort -u | tr '\n' ' '; }
my_ip(){ curl -fsS -m 8 https://api.ipify.org 2>/dev/null || curl -fsS -m 8 https://ifconfig.me 2>/dev/null || true; }

# 0=解析指向本机 1=没有解析 2=指向别处（多半挂了 CDN）
dns_state(){
  local d="$1" ip me
  ip=$(getent hosts "$d" 2>/dev/null | awk '{print $1}' | head -1)
  [ -n "$ip" ] || return 1
  me=$(my_ip); [ -n "$me" ] || return 0
  [ "$ip" = "$me" ] && return 0
  DNS_IP="$ip"; MY_IP="$me"; return 2
}

install_caddy(){
  have caddy && return 0
  info "安装 Caddy（自动 HTTPS）"
  if have apt-get; then
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg >/dev/null 2>&1 || true
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq caddy >/dev/null 2>&1
  elif have dnf; then
    dnf install -y -q 'dnf-command(copr)' >/dev/null 2>&1 && dnf copr enable -y @caddy/caddy >/dev/null 2>&1 && dnf install -y -q caddy >/dev/null 2>&1
  fi
  have caddy || install_caddy_static
  have caddy || die "Caddy 安装失败，请先自行装好 Caddy 或 nginx 再重试"
}
install_caddy_static(){
  warn "包管理器装不上，改用官方静态二进制"
  curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$(arch)" -o /usr/local/bin/caddy || return 1
  chmod 755 /usr/local/bin/caddy
  id caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy
  mkdir -p /etc/caddy /var/lib/caddy && chown caddy:caddy /var/lib/caddy
  cat > /etc/systemd/system/caddy.service <<'UNIT'
[Unit]
Description=Caddy
After=network.target

[Service]
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
Restart=on-abnormal
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload && systemctl enable caddy >/dev/null 2>&1
}

write_caddy_site(){
  local d="$1" mode="$2"
  mkdir -p /etc/caddy/conf.d
  if [ "$mode" = cdn ]; then
    cat > "$SITE" <<EOF
# CDN 模式：https 由 CDN 边缘提供，回源走 http。
# 这里只在 80 上服务且不强跳 https，否则回源会被 308 弹回去、形成死循环。
http://$d {
	reverse_proxy 127.0.0.1:$PORT
}
EOF
  else
    cat > "$SITE" <<EOF
$d {
	reverse_proxy 127.0.0.1:$PORT
}
EOF
  fi
  touch "$CADDYFILE"
  grep -q 'conf.d/\*.caddy' "$CADDYFILE" || printf '\nimport conf.d/*.caddy\n' >> "$CADDYFILE"
  if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
    systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy
    ok "反代已配置（$([ "$mode" = cdn ] && echo 'CDN 模式 · http 回源' || echo '自动 HTTPS')）"
  else
    die "Caddyfile 校验失败，已写入 $SITE 但未生效，请人工检查"
  fi
}

print_vhost(){
  local d="$1"
  cat <<EOF

${Y}80/443 已被其它服务占用：$(ports_owner)${N}
脚本不会去改别人的配置。面板已在 ${B}127.0.0.1:$PORT${N} 跑起来了，
把下面这段加到你现有的 nginx / 宝塔「反向代理」里即可（${Y}别开缓存${N}）：

${D}location ^~ / {
    proxy_pass http://127.0.0.1:$PORT;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_buffering off;
    proxy_cache off;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    client_max_body_size 64m;
}${N}

要点：WebSocket（网页终端）、关缓冲（实时刷新）、64m（大批上报）缺一不可。
站点记得开 HTTPS —— 节点令牌和机场通讯密钥都在请求里。
EOF
  [ -d /www/server/panel ] && printf '%s\n' "${B}检测到宝塔${N}：网站 → 设置 → 反向代理 → 添加，目标 http://127.0.0.1:$PORT，再把上面这段贴进它的配置文件。"
}

setup_proxy(){
  local d="$1" mode="${2:-}"
  if [ -z "$mode" ]; then
    mode=direct
    set +e; dns_state "$d"; local s=$?; set -e
    case $s in
      1) warn "$d 还没有 DNS 解析记录；先把它解析到本机再装会更顺"
         read -rp "仍要继续吗？[y/N] " a; [ "${a,,}" = y ] || die "已中止" ;;
      2) warn "$d 解析到 ${DNS_IP}，本机是 ${MY_IP} —— 多半挂了 CDN"
         read -rp "按 CDN 模式配置吗（回源走 http，避免 308 死循环）？[Y/n] " a
         [ "${a,,}" = n ] || mode=cdn ;;
    esac
  fi
  if ports_busy; then
    if ports_owner | grep -q caddy; then install_caddy; write_caddy_site "$d" "$mode"; return 0; fi
    print_vhost "$d"; return 0
  fi
  install_caddy; write_caddy_site "$d" "$mode"
}

# ---------- 安装 ----------
do_install(){
  need_root; need_systemd
  installed && { warn "已经装过了，进入管理菜单"; sleep 1; menu; return; }
  for c in curl tar sha256sum ss; do have "$c" || die "缺少命令 $c，请先安装（Debian/Ubuntu: apt install -y curl tar coreutils iproute2）"; done

  local domain="${1:-}" mode="${2:-}"
  if [ -z "$domain" ]; then
    printf '%s\n' "${B}面板域名${N}（给机场主打开后台、以及用户订阅用；留空则只监听本机、反代自理）"
    read -rp "域名: " domain
  fi

  local tmp src; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  src=$(pull_binary "$tmp")
  ensure_user
  mkdir -p "$DIR"
  install -m 755 "$src" "$BIN"
  write_conf
  mkdir -p "$DIR/data"
  chown -R "$RUNAS:$RUNAS" "$DIR"
  chmod 700 "$DIR/data"
  write_service
  panel_up || die "面板启动失败，看上面的日志"

  [ -n "$domain" ] && setup_proxy "$domain" "$mode" || warn "没填域名：面板只监听 127.0.0.1:$PORT，反代请自行配置"

  install_cli
  echo "$domain" > "$DIR/.domain" 2>/dev/null || true
  echo; ok "装好了"; show_info; next_steps
}

install_cli(){
  # 本脚本可能是经 bash <(curl ...) 跑的，$0 是管道、不能直接复制，所以重新拉一份
  if curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install.sh" -o "$CLI.tmp" 2>/dev/null \
     || curl -fsSL "$MIRROR/install.sh" -o "$CLI.tmp" 2>/dev/null; then
    mv -f "$CLI.tmp" "$CLI"
  elif [ -f "$0" ] && head -1 "$0" | grep -q bash; then
    cp -f "$0" "$CLI"
  else
    rm -f "$CLI.tmp"; warn "没装上 np 命令（网络不通），可稍后重跑安装命令补上"; return 0
  fi
  chmod 755 "$CLI"; ok "管理命令已装好：np"
}

next_steps(){
  local d; d=$(cat "$DIR/.domain" 2>/dev/null || true)
  cat <<EOF

${B}接下来${N}
  1. 打开后台 → 左边「使用说明」有从 0 到 1 的完整教程
  2. 「机场面板」添加机场的 Xboard（地址 + 通讯密钥）
  3. 「节点」登记节点并标记，再按教程给落地装节点后端
  4. ${B}让 veil 节点进到用户订阅里${N} —— 按机场装没装 apex 加密插件二选一：

     ${G}① 机场装了 apex 加密插件（最省事，订阅地址完全不用改）${N}
       在插件设置「③ veil 节点」里填两样：
         面板地址  ${G}https://${d:-你的域名}${N}
         面板令牌  在后台「机场面板 →（这家）→ 插件令牌」点生成后复制
       ${D}插件渲染好订阅、加密之前送到本面板补上 veil 节点，再由插件自己加密。
       机场的加密密钥不会发给面板；面板连不上时插件原样加密下发，订阅不中断。${N}

     ${G}② 机场没装插件 —— 让订阅经过本面板${N}
       在后台「机场面板 →（这家）→ veil 接入」里配订阅域名或路径前缀，
       或直接用内置地址：机场 Xboard 的${B}订阅地址 subscribe_url${N} 填
         ${G}https://${d:-你的域名}/sub${N}
       ${D}⚠️ 这会改到机场的订阅地址，所有老用户的订阅链接会跟着变。
          站点地址 app_url 保持机场自己的域名不要动。${N}

     ${D}两种方式都不用你配反代：面板自己会去机场 Xboard 取订阅（机场地址和
     通讯密钥第 2 步已经填过了）。机场自定义过订阅路径也不用管，原样转发。${N}

  以后管理随时敲 ${G}np${N}
EOF
}

show_info(){
  local d st u p
  d=$(cat "$DIR/.domain" 2>/dev/null || true)
  systemctl is-active --quiet "$SVC" && st="${G}运行中${N}" || st="${R}已停止${N}"
  u=$(grep -oE '"admin_user"[^,]*' "$CONF" 2>/dev/null | cut -d'"' -f4)
  p=$(grep -oE '"admin_password"[^,]*' "$CONF" 2>/dev/null | cut -d'"' -f4)
  cat <<EOF

  ${B}面板${N}   $st   $(sha256sum "$BIN" 2>/dev/null | cut -c1-7)
  ${B}地址${N}   ${G}https://${d:-<未配域名>}/admin/${N}
  ${B}账号${N}   ${u:-admin}
  ${B}密码${N}   ${p:-<见 $CONF>}
  ${D}配置 $CONF · 数据 $DIR/data${N}
EOF
}

# ---------- 管理子命令 ----------
cmd_update(){
  need_root; installed || die "还没安装"
  local tmp src cur new; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  cur=$(sha256sum "$BIN" | cut -d' ' -f1)
  src=$(pull_binary "$tmp")
  new=$(sha256sum "$src" | cut -d' ' -f1)
  [ "$cur" = "$new" ] && { ok "已经是最新版（${cur:0:16}…）"; return 0; }
  cp -p "$BIN" "$BIN.bak"
  install -m 755 -o "$RUNAS" -g "$RUNAS" "$src" "$BIN"
  if panel_up; then ok "已升级 ${cur:0:7} → ${new:0:7}（旧版留在 $BIN.bak）"
  else warn "新版起不来，回滚"; cp -p "$BIN.bak" "$BIN"; systemctl restart "$SVC"; die "已回滚到旧版"; fi
}
cmd_domain(){
  need_root; installed || die "还没安装"
  local d="${1:-}" mode="${2:-}"
  [ -n "$d" ] || read -rp "新域名: " d
  [ -n "$d" ] || die "没填域名"
  setup_proxy "$d" "$mode"
  echo "$d" > "$DIR/.domain"
  ok "域名已切到 $d"
  warn "别忘了：面板「设置 → 对外地址」改成 https://$d"
  printf '%s\n' "${D}  用 apex 加密插件接入的，把插件里的「中转面板地址」也改成 https://$d${N}" >&2
}
cmd_backup(){
  need_root; local f="/root/$NAME-backup-$(date +%Y%m%d%H%M).tar.gz"
  tar -czf "$f" -C "$DIR" config.json data && ok "已备份到 $f"
  warn "备份里含全部密钥，妥善保管"
}
cmd_restore(){
  need_root; local f="${1:-}"
  [ -n "$f" ] || read -rp "备份文件路径: " f
  [ -f "$f" ] || die "找不到 $f"
  read -rp "将覆盖现有配置与数据，继续？[y/N] " a; [ "${a,,}" = y ] || die "已取消"
  systemctl stop "$SVC"; tar -xzf "$f" -C "$DIR"; chown -R "$RUNAS:$RUNAS" "$DIR"; panel_up && ok "已恢复"
}
cmd_uninstall(){
  need_root
  read -rp "确认卸载 $NAME？[y/N] " a; [ "${a,,}" = y ] || die "已取消"
  systemctl disable --now "$SVC" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$SVC.service"; systemctl daemon-reload
  rm -f "$SITE"; [ -f "$CADDYFILE" ] && { caddy validate --config "$CADDYFILE" >/dev/null 2>&1 && systemctl reload caddy >/dev/null 2>&1 || true; }
  read -rp "连同数据一起删掉吗（不可恢复）？[y/N] " b
  if [ "${b,,}" = y ]; then rm -rf "$DIR"; userdel "$RUNAS" 2>/dev/null || true; ok "已彻底卸载"
  else ok "程序已卸载，数据保留在 $DIR"; fi
  rm -f "$CLI"
}

menu(){
  need_root; installed || { do_install "$@"; return; }
  while :; do
    clear 2>/dev/null || true
    show_info
    cat <<EOF

   1) 查看状态 / 后台地址与密码        6) 重置管理员密码
   2) 启动 · 停止 · 重启              7) 关闭两步验证
   3) 实时日志                        8) 备份 / 恢复数据
   4) 升级面板                        9) 卸载
   5) 更换域名（直连 / CDN）           0) 退出
EOF
    read -rp "   选择: " c
    case "$c" in
      1) show_info; next_steps ;;
      2) read -rp "   1 启动 / 2 停止 / 3 重启: " s
         case "$s" in 1) systemctl start "$SVC";; 2) systemctl stop "$SVC";; 3) systemctl restart "$SVC";; esac; ok "完成" ;;
      3) journalctl -u "$SVC" -f --no-pager ;;
      4) cmd_update ;;
      5) cmd_domain ;;
      6) systemctl stop "$SVC"; "$BIN" -c "$CONF" -reset-password; systemctl start "$SVC" ;;
      7) systemctl stop "$SVC"; "$BIN" -c "$CONF" -reset-2fa; systemctl start "$SVC" ;;
      8) read -rp "   1 备份 / 2 恢复: " s; case "$s" in 1) cmd_backup;; 2) cmd_restore;; esac ;;
      9) cmd_uninstall; return ;;
      0) return ;;
    esac
    read -rp "   回车继续…" _
  done
}

case "${1:-}" in
  install)   shift; do_install "${1:-}" "${2:-}" ;;
  -d)        do_install "${2:-}" "${3:-}" ;;
  status)    show_info ;;
  log|logs)  journalctl -u "$SVC" -f --no-pager ;;
  start|stop|restart) systemctl "$1" "$SVC" && ok "完成" ;;
  update)    cmd_update ;;
  domain)    shift; cmd_domain "${1:-}" "${2:-}" ;;
  backup)    cmd_backup ;;
  restore)   shift; cmd_restore "${1:-}" ;;
  uninstall) cmd_uninstall ;;
  ""|menu)   menu ;;
  *) cat <<EOF
用法: np [命令]
  (无参数)        管理菜单
  status          状态与后台地址
  log             实时日志
  start|stop|restart
  update          升级面板
  domain <域名> [cdn]   更换域名
  backup | restore <文件>
  uninstall       卸载
EOF
;;
esac
