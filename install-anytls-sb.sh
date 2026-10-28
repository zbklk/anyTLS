#!/usr/bin/env bash
# AnyTLS v2 · sing-box official core · independent instance
# Managed by zbklk/anyTLS v2; never overwrites /etc/sing-box or the sing-box service.
set -Eeuo pipefail
umask 077

APP="sing-box-anytls"
DIR="/etc/$APP"
BIN="/usr/local/libexec/$APP/sing-box"
STATE="$DIR/state.json"
CONF="$DIR/config.json"
SERVICE_SYS="/etc/systemd/system/$APP.service"
SERVICE_RC="/etc/init.d/$APP"
BACKUP_DIR="/var/backups/$APP"
WORK=""
PKG=""
INIT=""
ARCH=""
CORE_TAG=""
ACTIVE_BEFORE=0
HAD_DIR=0
HAD_BIN=0

info(){ printf '\033[36m[信息]\033[0m %s\n' "$*"; }
ok(){ printf '\033[32m[成功]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[注意]\033[0m %s\n' "$*" >&2; }
fail(){ printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }
clean(){ if [ -n "$WORK" ] && [ -d "$WORK" ]; then rm -rf -- "$WORK"; fi; }
trap clean EXIT
fresh(){ clean; WORK="$(mktemp -d -t sing-box-anytls.XXXXXXXX)"; }
require_root(){ [ "$(id -u)" -eq 0 ] || fail "请使用 sudo bash 或 root 运行。"; }

detect(){
  [ "$(uname -s)" = Linux ] || fail "仅支持 Linux。"
  [ -r /etc/os-release ] || fail "缺少 /etc/os-release。"
  . /etc/os-release
  case " $ID ${ID_LIKE:-} " in
    *alpine*) PKG=apk ;;
    *debian*|*ubuntu*) PKG=apt ;;
    *fedora*|*rhel*|*rocky*|*almalinux*|*centos*|*ol*)
      if has dnf; then PKG=dnf; else PKG=yum; fi ;;
    *) fail "暂不支持发行版：$ID" ;;
  esac
  if has systemctl && [ -d /run/systemd/system ]; then INIT=systemd
  elif has rc-service && [ -x /sbin/openrc-run ]; then INIT=openrc
  else fail "需要运行中的 systemd 或 OpenRC 服务管理器。"; fi
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l|armv7) ARCH=armv7 ;;
    i386|i686) ARCH=386 ;;
    *) fail "不支持架构：$(uname -m)" ;;
  esac
}

install_deps(){
  local missing=() c
  for c in curl jq openssl tar gzip sha256sum; do has "$c" || missing+=("$c"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    info "安装系统依赖：${missing[*]}"
    case "$PKG" in
      apt) export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq curl jq openssl tar gzip coreutils ca-certificates ;;
      apk) apk add --no-cache curl jq openssl tar gzip coreutils ca-certificates ;;
      dnf) dnf install -y curl jq openssl tar gzip coreutils ca-certificates ;;
      yum) yum install -y curl jq openssl tar gzip coreutils ca-certificates ;;
    esac
  fi
  for c in curl jq openssl tar gzip sha256sum; do has "$c" || fail "仍缺少依赖 $c"; done
}
install_qr(){
  has qrencode && return 0
  info "尝试安装二维码工具 qrencode（失败不会影响节点）..."
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode >/dev/null 2>&1 || true ;;
    apk) apk add --no-cache qrencode >/dev/null 2>&1 || true ;;
    dnf) dnf install -y qrencode >/dev/null 2>&1 || true ;;
    yum) yum install -y qrencode >/dev/null 2>&1 || true ;;
  esac
  has qrencode
}

ask(){
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value || fail "输入中断"
  printf '%s' "${value:-$default}"
}
confirm(){
  local ans
  read -r -p "$1 [y/N]: " ans || return 1
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
port_ok(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
name_ok(){ [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]]; }
host_ok(){ [ -n "$1" ] && [ "${#1}" -le 253 ] && [[ "$1" =~ ^[a-zA-Z0-9.:_-]+$ ]] && [[ "$1" != *'..'* ]]; }
sni_ok(){ [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ "$1" == *.* ]] && [[ "$1" != *'..'* ]] && [ "${#1}" -le 253 ]; }
is_ip(){ [[ "$1" =~ ^[0-9.]+$ || "$1" == *:* ]]; }
urlenc(){ jq -rn --arg v "$1" '$v|@uri'; }
random_password(){ openssl rand -hex 24; }
public_ip(){ curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true; }
port_busy(){
  if has ss; then ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq ":${1}$"
  elif has netstat; then netstat -lnt 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq ":${1}$"
  else warn "无 ss/netstat，无法自动检测端口冲突。"; return 1; fi
}

owned(){
  local target
  if [ "$INIT" = systemd ]; then target="$SERVICE_SYS"; else target="$SERVICE_RC"; fi
  if [ -e "$target" ] && ! grep -q 'Managed by zbklk/anyTLS v2' "$target"; then
    fail "同名服务不是本脚本创建的，拒绝覆盖：$target"
  fi
}
service_ctl(){
  if [ "$INIT" = systemd ]; then systemctl "$1" "$APP"
  else
    case "$1" in
      enable) rc-update add "$APP" default ;;
      disable) rc-update del "$APP" default ;;
      *) rc-service "$APP" "$1" ;;
    esac
  fi
}
active(){
  if [ "$INIT" = systemd ]; then systemctl is-active --quiet "$APP"
  else rc-service "$APP" status >/dev/null 2>&1; fi
}
unit_install(){
  owned
  if [ "$INIT" = systemd ]; then
    if [ ! -f "$SERVICE_SYS" ]; then
      cat > "$SERVICE_SYS" <<EOF
# Managed by zbklk/anyTLS v2
[Unit]
Description=Independent AnyTLS sing-box (zbklk v2)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
      chmod 644 "$SERVICE_SYS"
      systemctl daemon-reload
    fi
  else
    if [ ! -f "$SERVICE_RC" ]; then
      cat > "$SERVICE_RC" <<EOF
#!/sbin/openrc-run
# Managed by zbklk/anyTLS v2
name="$APP"
command="$BIN"
command_args="run -c $CONF"
command_background=true
pidfile="/run/$APP.pid"
output_log="/var/log/$APP.log"
error_log="/var/log/$APP.err"
depend() { need net; }
EOF
      chmod 755 "$SERVICE_RC"
    fi
  fi
}
unit_remove(){
  owned
  service_ctl stop >/dev/null 2>&1 || true
  service_ctl disable >/dev/null 2>&1 || true
  if [ "$INIT" = systemd ]; then
    rm -f "$SERVICE_SYS"
    systemctl daemon-reload
  else
    rm -f "$SERVICE_RC"
  fi
}

latest_core(){
  info "查询 sing-box 官方稳定版 Release..."
  local release tag version asset url digest file
  release="$(curl -fLsS --connect-timeout 12 --max-time 50 --retry 2 -H 'Accept: application/vnd.github+json' https://api.github.com/repos/SagerNet/sing-box/releases/latest)" || fail "无法查询官方 Release。"
  tag="$(jq -r '.tag_name // empty' <<< "$release")"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "最新 Release 版本号异常：$tag"
  version="${tag#v}"
  if [ "$PKG" = apk ]; then
    asset="sing-box-$version-linux-$ARCH-musl.tar.gz"
  else
    asset="sing-box-$version-linux-$ARCH.tar.gz"
  fi
  url="$(jq -r --arg asset "$asset" '.assets[] | select(.name==$asset) | .browser_download_url' <<< "$release")"
  digest="$(jq -r --arg asset "$asset" '.assets[] | select(.name==$asset) | .digest // empty' <<< "$release")"
  [ "$url" = "https://github.com/SagerNet/sing-box/releases/download/$tag/$asset" ] || fail "官方没有适合本机架构的资产 $asset"
  [[ "$digest" =~ ^sha256:[a-fA-F0-9]{64}$ ]] || fail "官方资产没有可信 SHA-256 摘要，取消安装。"
  file="$WORK/$asset"
  info "下载 $tag / $asset"
  curl -fL --connect-timeout 15 --retry 3 -o "$file" "$url" || fail "内核下载失败"
  printf '%s  %s\n' "${digest#sha256:}" "$file" | sha256sum --check --status || fail "下载文件 SHA-256 校验失败"
  mkdir -p "$WORK/extract"
  tar -xzf "$file" -C "$WORK/extract" || fail "解压失败"
  local source
  source="$(find "$WORK/extract" -type f -name sing-box | head -n 1)"
  [ -n "$source" ] || fail "压缩包中未找到 sing-box"
  install -m 755 "$source" "$WORK/new-core"
  "$WORK/new-core" version >/dev/null || fail "最新 sing-box 二进制无法在本机运行"
  CORE_TAG="$tag"
  ok "内核下载和校验通过：$tag"
}
replace_core(){
  mkdir -p "$(dirname "$BIN")"
  chmod 700 "$(dirname "$BIN")"
  install -m 755 "$1" "$BIN.new.$$"
  mv -f "$BIN.new.$$" "$BIN"
}
snapshot(){
  HAD_DIR=0; HAD_BIN=0; ACTIVE_BEFORE=0
  [ -d "$DIR" ] && { cp -a "$DIR" "$WORK/prev-dir"; HAD_DIR=1; }
  [ -f "$BIN" ] && { cp -p "$BIN" "$WORK/prev-bin"; HAD_BIN=1; }
  active && ACTIVE_BEFORE=1 || true
}
rollback(){
  warn "准备恢复操作前的配置与内核..."
  service_ctl stop >/dev/null 2>&1 || true
  if [ "$HAD_DIR" = 1 ]; then
    rm -rf -- "$DIR"; cp -a "$WORK/prev-dir" "$DIR"
  else rm -rf -- "$DIR"; fi
  if [ "$HAD_BIN" = 1 ]; then replace_core "$WORK/prev-bin"
  else rm -f "$BIN"; fi
  if [ "$HAD_DIR" = 0 ]; then unit_remove
  elif [ "$ACTIVE_BEFORE" = 1 ]; then service_ctl start >/dev/null 2>&1 || warn "旧服务自动恢复失败，请检查日志"
  fi
}

state_valid(){
  jq -e '
    (.listen_port|type)=="number" and (.listen_port>=1 and .listen_port<=65535) and
    (.external_port|type)=="number" and (.external_port>=1 and .external_port<=65535) and
    (.listen|type)=="string" and (.address|type)=="string" and
    (.sni|type)=="string" and (.users|type)=="array" and
    (.users|length)>0 and all(.users[]; (.name|type)=="string" and (.password|type)=="string" and (.password|length)>0) and
    (.cert_path|type)=="string" and (.key_path|type)=="string"
  ' "$1" >/dev/null 2>&1
}
gen_config(){
  jq -n --slurpfile s "$1" '
    $s[0] as $x |
    {log:{level:"info",timestamp:true},
     inbounds:[{type:"anytls",tag:"anytls-in",listen:$x.listen,listen_port:$x.listen_port,
       users:$x.users,
       tls:{enabled:true,server_name:$x.sni,certificate_path:$x.cert_path,key_path:$x.key_path,min_version:"1.2"}}],
     outbounds:[{type:"direct",tag:"direct"}]}
  ' > "$2"
}
check_cert(){
  local cert="$1" key="$2" domain="$3"
  [ -s "$cert" ] && [ -s "$key" ] || fail "证书或私钥文件不存在"
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || fail "证书格式无效"
  openssl pkey -in "$key" -noout >/dev/null 2>&1 || fail "私钥格式无效"
  openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1 || fail "证书已过期"
  openssl x509 -in "$cert" -checkhost "$domain" -noout >/dev/null 2>&1 || fail "证书域名不匹配：$domain"
  local a b
  a="$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
  b="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
  [ "$a" = "$b" ] || fail "证书与私钥不匹配"
}
apply_state(){
  local proposed="$1" new_core="${2:-}"
  state_valid "$proposed" || { warn "节点元数据不合法"; rollback; return 1; }
  mkdir -p "$DIR" "$(dirname "$BIN")"
  chmod 700 "$DIR" "$(dirname "$BIN")"
  gen_config "$proposed" "$WORK/candidate.json"
  local usebin="$BIN"
  [ -n "$new_core" ] && usebin="$new_core"
  [ -x "$usebin" ] || { rollback; fail "内核不存在"; }
  if ! "$usebin" check -c "$WORK/candidate.json"; then rollback; fail "新配置未通过 sing-box check"; fi
  [ -z "$new_core" ] || replace_core "$new_core"
  install -m 600 "$proposed" "$STATE"
  install -m 600 "$WORK/candidate.json" "$CONF"
  unit_install
  service_ctl enable >/dev/null 2>&1 || warn "开机自启设置未确认"
  if ! service_ctl restart >/dev/null 2>&1; then rollback; fail "服务重启失败，已回滚"; fi
  sleep 1
  if ! active; then rollback; fail "服务启动后退出，已回滚"; fi
  ok "配置已生效，$APP 正在运行。"
}

acme_bin(){
  if has acme.sh; then command -v acme.sh
  elif [ -x "$HOME/.acme.sh/acme.sh" ]; then printf '%s' "$HOME/.acme.sh/acme.sh"
  else printf ''; fi
}
acme_ensure(){
  local binary
  binary="$(acme_bin)"
  [ -n "$binary" ] && return 0
  warn "申请证书需要安装 acme.sh，官方安装器会设置证书续签任务。"
  confirm "是否从 get.acme.sh 安装 acme.sh（需信任其安装程序）？" || fail "已取消证书申请"
  curl -fLsS --retry 2 https://get.acme.sh -o "$WORK/install-acme.sh" || fail "无法获取 acme.sh 官方安装器"
  local email
  email="$(ask 'ACME 联系邮箱（请输入真实邮箱）' '')"
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail "ACME 联系邮箱格式无效"
  sh "$WORK/install-acme.sh" "email=$email" || fail "acme.sh 安装失败（请检查 crontab 与安装日志）"
  [ -n "$(acme_bin)" ] || fail "没有找到 acme.sh"
}
acme_issue(){
  local sni="$1" method="$2" plugin="${3:-}"
  acme_ensure
  local acme base reload
  acme="$(acme_bin)"
  "$acme" --set-default-ca --server letsencrypt || fail "无法设置 Let's Encrypt CA"
  base="$DIR/certs/issued-$(date +%Y%m%d%H%M%S)-$$"
  CERT_PATH="$base.crt"; KEY_PATH="$base.key"; CERT_MODE="acme"
  mkdir -p "$DIR/certs"; chmod 700 "$DIR/certs"

  # 证书续签时，若服务尚未创建也不应导致证书安装失败。
  if [ "$INIT" = openrc ]; then
    reload="rc-service $APP restart >/dev/null 2>&1 || true"
  else
    reload="systemctl try-restart $APP >/dev/null 2>&1 || true"
  fi

  # 已存在有效证书时直接复用，避免 --issue 的「Domains not changed / Skipping」
  # 导致 set -e 提前退出，也避免不必要的 ACME 重复签发。
  if "$acme" --install-cert -d "$sni" --ecc \
      --fullchain-file "$CERT_PATH" --key-file "$KEY_PATH" \
      --reloadcmd "$reload" >/dev/null 2>&1 \
      && (check_cert "$CERT_PATH" "$KEY_PATH" "$sni") >/dev/null 2>&1; then
    chmod 600 "$KEY_PATH" "$CERT_PATH"
    ok "已复用并验证已有的 Let's Encrypt 证书：$sni（无需重新申请）"
    return 0
  fi

  # 尚无有效 ECC 证书：申请新证书；不会使用 --force 强制重复签发。
  rm -f -- "$CERT_PATH" "$KEY_PATH"
  info "未找到可复用的有效 ECC 证书，开始申请：$sni"
  if [ "$method" = http ]; then
    warn "HTTP-01 需要域名解析到本 VPS，公网 TCP/80 可连接且没有其他程序监听"
    port_busy 80 && fail "本机 TCP/80 已占用，请换用 DNS-01 或已有证书"
    if ! "$acme" --issue --standalone -d "$sni" --keylength ec-256; then
      fail "HTTP-01 申请未成功。请检查域名解析、Cloudflare 灰云及公网 80/TCP；不会强制重新签发。"
    fi
  else
    warn "DNS-01 插件 $plugin 必须已正确配置 DNS API Token"
    if ! "$acme" --issue --dns "$plugin" -d "$sni" --keylength ec-256; then
      fail "DNS-01 申请未成功。请检查 DNS API 插件及授权。"
    fi
  fi

  "$acme" --install-cert -d "$sni" --ecc \
    --fullchain-file "$CERT_PATH" --key-file "$KEY_PATH" \
    --reloadcmd "$reload" || fail "证书签发后安装失败，请检查 acme.sh 输出"
  chmod 600 "$KEY_PATH" "$CERT_PATH"
  check_cert "$CERT_PATH" "$KEY_PATH" "$sni"
  ok "新证书已签发、安装并验证：$sni"
}
cert_setup(){
  local domain="$1" choice
  printf '\nTLS 证书方式：\n  1) 使用已有有效证书（推荐）\n  2) Let’s Encrypt HTTP-01（公网 TCP/80）\n  3) Let’s Encrypt DNS-01（已配置 DNS API 插件）\n  4) 自签名证书（仅测试，客户端需允许不安全证书）\n'
  choice="$(ask '选择证书方式' 1)"
  case "$choice" in
    1)
      CERT_PATH="$(ask '已有证书绝对路径（fullchain）' '/etc/ssl/fullchain.pem')"
      KEY_PATH="$(ask '已有私钥绝对路径' '/etc/ssl/privkey.pem')"
      CERT_MODE="existing" ;;
    2) acme_issue "$domain" http ;;
    3)
      local plugin
      plugin="$(ask 'acme.sh DNS 插件名称' dns_cf)"
      [[ "$plugin" =~ ^dns_[a-zA-Z0-9_]+$ ]] || fail "DNS 插件名称不合法"
      acme_issue "$domain" dns "$plugin" ;;
    4)
      warn "自签名模式会让多数客户端需要开启跳过 TLS 证书验证，仅建议测试使用。"
      confirm "仍要创建自签名证书？" || fail "已取消"
      mkdir -p "$DIR/certs"; chmod 700 "$DIR/certs"
      local base="$DIR/certs/self-$(date +%Y%m%d%H%M%S)-$$"
      CERT_PATH="$base.crt"; KEY_PATH="$base.key"; CERT_MODE="selfsigned"
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -sha256 -days 365 -nodes -keyout "$KEY_PATH" -out "$CERT_PATH" \
        -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" >/dev/null 2>&1 || fail "生成自签名证书失败"
      chmod 600 "$CERT_PATH" "$KEY_PATH" ;;
    *) fail "选择无效" ;;
  esac
  [[ "$CERT_PATH" == /* && "$KEY_PATH" == /* ]] || fail "证书和私钥必须使用绝对路径"
  check_cert "$CERT_PATH" "$KEY_PATH" "$domain"
  ok "证书检查通过：$domain"
}
firewall_allow(){
  local port="$1"
  confirm "尝试放行 TCP/$port（不修改云厂商安全组）？" || return 0
  if has ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then ufw allow "$port/tcp" || true
  elif has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$port/tcp" || true
    firewall-cmd --reload || true
  else warn "未检测到已启用的 UFW 或 firewalld；请确认 VPS 自身防火墙及安全组。"; fi
}
install_node(){
  [ ! -e "$STATE" ] || { warn "已有 v2 节点，请使用管理菜单修改，避免意外更换密码。"; return; }
  owned; install_deps; fresh; snapshot
  local address port ext listen sni username pass
  address="$(ask '客户端连接地址（IPv4/IPv6/域名）' "$(public_ip)")"
  host_ok "$address" || fail "连接地址不合法"
  port="$(ask '本机 TCP 监听端口' 443)"; port_ok "$port" || fail "端口无效"
  if port_busy "$port"; then fail "TCP/$port 已被占用"; fi
  ext="$(ask '客户端外部端口（NAT VPS 可与本机端口不同）' "$port")"
  port_ok "$ext" || fail "外部端口无效"
  listen="$(ask '本地监听地址（0.0.0.0 或 ::）' '0.0.0.0')"
  [[ "$listen" == 0.0.0.0 || "$listen" == "::" ]] || fail "不支持的监听地址"
  sni="$(ask 'TLS 证书域名 / SNI（必须与证书匹配）' 'node.example.com')"
  sni_ok "$sni" || fail "SNI 应为真实域名"
  username="$(ask '首个用户名称' user1)"; name_ok "$username" || fail "用户名只能是英文字母开头，含字母数字_-，最长 32 位"
  pass="$(random_password)"
  cert_setup "$sni"
  latest_core
  jq -n --arg address "$address" --arg listen "$listen" --arg sni "$sni" \
    --arg cert "$CERT_PATH" --arg key "$KEY_PATH" --arg mode "$CERT_MODE" \
    --arg user "$username" --arg password "$pass" --argjson port "$port" --argjson external "$ext" \
    '{version:2,address:$address,listen:$listen,listen_port:$port,external_port:$external,
      sni:$sni,cert_path:$cert,key_path:$key,cert_mode:$mode,
      users:[{name:$user,password:$password}]}' > "$WORK/proposed.json"
  apply_state "$WORK/proposed.json" "$WORK/new-core"
  firewall_allow "$port"
  show_nodes
}
read_state(){
  [ -f "$STATE" ] && [ -x "$BIN" ] || fail "尚未安装 v2 节点，请先选择 1"
  owned; state_valid "$STATE" || fail "节点状态文件损坏"
}
uri_for(){
  local username="$1" pass="$2" address ext sni mode uri host label
  address="$(jq -r '.address' "$STATE")"
  ext="$(jq -r '.external_port' "$STATE")"
  sni="$(jq -r '.sni' "$STATE")"
  mode="$(jq -r '.cert_mode' "$STATE")"
  host="$address"; [[ "$host" == *:* ]] && host="[$host]"
  uri="anytls://$(urlenc "$pass")@$host:$ext?security=tls&sni=$(urlenc "$sni")"
  [ "$mode" = selfsigned ] && uri="$uri&insecure=1"
  label="AnyTLS-$(urlenc "$username")"
  printf '%s#%s' "$uri" "$label"
}
show_nodes(){
  read_state
  printf '\n服务：'; if active; then ok "运行中"; else warn "未运行"; fi
  jq -r '"服务器：\(.address)\n本机监听：\(.listen):\(.listen_port)\n外部端口：\(.external_port)\nSNI：\(.sni)\n证书模式：\(.cert_mode)\n用户数：\(.users|length)"' "$STATE"
  info "分享链接内含登录密码，请勿上传到 GitHub 或公开发送。"
  local name password
  while IFS=$'\t' read -r name password; do
    printf '\n[%s] %s\n' "$name" "$(uri_for "$name" "$password")"
  done < <(jq -r '.users[] | [.name,.password] | @tsv' "$STATE")
  if install_qr; then
    local chosen
    chosen="$(ask '显示哪个用户的二维码（回车显示第一个）' "$(jq -r '.users[0].name' "$STATE")")"
    password="$(jq -r --arg name "$chosen" '.users[] | select(.name==$name) | .password' "$STATE")"
    if [ -n "$password" ]; then uri_for "$chosen" "$password" | qrencode -t ANSIUTF8 || warn "二维码生成失败"
    else warn "用户不存在"; fi
  else warn "qrencode 不可用，直接复制上方的链接即可"; fi
  if [ "$(jq -r '.cert_mode' "$STATE")" = selfsigned ]; then
    warn "当前为自签名证书，部分客户端不识别 URI 中的 insecure 参数，需要手动开启跳过证书验证。"
  fi
}
create_user(){
  read_state; fresh; snapshot
  local name pass
  name="$(ask '新用户名称' user2)"
  name_ok "$name" || fail "用户名格式不正确"
  jq -e --arg name "$name" 'any(.users[];.name==$name)' "$STATE" >/dev/null && { warn "用户已存在"; return; }
  pass="$(random_password)"
  jq --arg name "$name" --arg pass "$pass" '.users += [{name:$name,password:$pass}]' "$STATE" > "$WORK/proposed.json"
  apply_state "$WORK/proposed.json"
  show_nodes
}
delete_user(){
  read_state
  local name count
  count="$(jq '.users|length' "$STATE")"
  [ "$count" -gt 1 ] || { warn "至少保留一名用户"; return; }
  jq -r '.users[].name' "$STATE"
  name="$(ask '删除哪个用户' '')"
  jq -e --arg name "$name" 'any(.users[];.name==$name)' "$STATE" >/dev/null || { warn "用户不存在"; return; }
  confirm "确认删除用户 $name（该用户立即无法继续连接）？" || return 0
  fresh; snapshot
  jq --arg name "$name" '.users |= map(select(.name!=$name))' "$STATE" > "$WORK/proposed.json"
  apply_state "$WORK/proposed.json"
}
change_network(){
  read_state
  local oldport port ext address listen sni certmode certkey
  oldport="$(jq -r '.listen_port' "$STATE")"
  address="$(ask '客户端连接地址' "$(jq -r '.address' "$STATE")")"
  host_ok "$address" || fail "地址无效"
  port="$(ask '本机 TCP 端口' "$oldport")"; port_ok "$port" || fail "端口无效"
  if [ "$port" != "$oldport" ] && port_busy "$port"; then fail "新端口已被占用"; fi
  ext="$(ask 'NAT 外部 TCP 端口' "$(jq -r '.external_port' "$STATE")")"; port_ok "$ext" || fail "端口无效"
  listen="$(ask '监听地址' "$(jq -r '.listen' "$STATE")")"
  [[ "$listen" == 0.0.0.0 || "$listen" == "::" ]] || fail "仅支持 0.0.0.0 或 ::"
  sni="$(ask 'TLS SNI（更改时须同步更换证书）' "$(jq -r '.sni' "$STATE")")"
  sni_ok "$sni" || fail "SNI 格式不合法"
  fresh; snapshot
  certmode="$(jq -r '.cert_mode' "$STATE")"
  CERT_PATH="$(jq -r '.cert_path' "$STATE")"
  KEY_PATH="$(jq -r '.key_path' "$STATE")"
  CERT_MODE="$certmode"
  if [ "$sni" != "$(jq -r '.sni' "$STATE")" ]; then cert_setup "$sni"; fi
  jq --arg address "$address" --arg listen "$listen" --arg sni "$sni" \
    --arg cert "$CERT_PATH" --arg key "$KEY_PATH" --arg mode "$CERT_MODE" \
    --argjson port "$port" --argjson ext "$ext" \
    '.address=$address | .listen=$listen | .listen_port=$port | .external_port=$ext |
     .sni=$sni | .cert_path=$cert | .key_path=$key | .cert_mode=$mode' "$STATE" > "$WORK/proposed.json"
  apply_state "$WORK/proposed.json"
  [ "$port" = "$oldport" ] || firewall_allow "$port"
  warn "旧防火墙放行规则不会自动删除。若更换了外部端口，请同步更新 NAT 映射和客户端。"
}
status(){
  read_state
  "$BIN" version | head -n 1
  if active; then ok "$APP 运行中"; else warn "$APP 未运行"; fi
  if has ss; then ss -ltn | grep -E ":$(jq -r '.listen_port' "$STATE")[[:space:]]" || true; fi
  jq -r '"节点端口：\(.listen_port)  外部端口：\(.external_port)  用户数：\(.users|length)"' "$STATE"
}
service_menu(){
  read_state
  printf '\n1) 启动\n2) 停止\n3) 重启\n'
  local v; v="$(ask '选择' 3)"
  case "$v" in
    1) service_ctl start; ok "服务已启动" ;;
    2) service_ctl stop; ok "服务已停止" ;;
    3) service_ctl restart; ok "服务已重启" ;;
    *) warn "无效选项" ;;
  esac
}
update_core(){
  read_state; install_deps; fresh
  latest_core
  local old
  old="$("$BIN" version | head -n 1)"
  if grep -Fq "$CORE_TAG" <<< "$old"; then ok "已经是官方最新稳定版 $CORE_TAG"; return; fi
  snapshot
  if ! "$WORK/new-core" check -c "$CONF"; then fail "新版本与现有配置不兼容，未升级"; fi
  replace_core "$WORK/new-core"
  if active; then
    if ! service_ctl restart >/dev/null 2>&1; then rollback; fail "更新后服务启动失败，已回滚"; fi
    sleep 1
    if ! active; then rollback; fail "更新后服务退出，已回滚"; fi
  fi
  ok "sing-box 已更新到 $CORE_TAG（节点密码和端口未改变）"
}
cert_menu(){
  read_state
  printf '\n当前证书：\n'
  jq -r '"域名：\(.sni)\n模式：\(.cert_mode)\n证书：\(.cert_path)"' "$STATE"
  openssl x509 -in "$(jq -r '.cert_path' "$STATE")" -noout -dates 2>/dev/null || true
  printf '\n1) 更换证书 / 重新申请\n2) 手动续签 acme.sh 证书\n3) 仅检查证书\n0) 返回\n'
  local v; v="$(ask '选择' 0)"
  case "$v" in
    1)
      fresh; snapshot
      CERT_PATH=""; KEY_PATH=""; CERT_MODE=""
      cert_setup "$(jq -r '.sni' "$STATE")"
      jq --arg cert "$CERT_PATH" --arg key "$KEY_PATH" --arg mode "$CERT_MODE" \
        '.cert_path=$cert | .key_path=$key | .cert_mode=$mode' "$STATE" > "$WORK/proposed.json"
      apply_state "$WORK/proposed.json" ;;
    2)
      if [ "$(jq -r '.cert_mode' "$STATE")" != acme ]; then warn "非 acme.sh 托管证书，无法由本工具续签"; return; fi
      local binary
      binary="$(acme_bin)"
      [ -n "$binary" ] || fail "acme.sh 不存在"
      "$binary" --renew -d "$(jq -r '.sni' "$STATE")" --ecc --force || fail "续签失败"
      service_ctl restart
      ok "续签操作完成，服务已重启" ;;
    3) check_cert "$(jq -r '.cert_path' "$STATE")" "$(jq -r '.key_path' "$STATE")" "$(jq -r '.sni' "$STATE")"; ok "证书匹配且未过期" ;;
    0) return ;;
    *) warn "无效选项" ;;
  esac
}
logs(){
  if [ "$INIT" = systemd ]; then journalctl -u "$APP" -n 80 --no-pager
  else
    [ ! -f "/var/log/$APP.err" ] || tail -n 50 "/var/log/$APP.err"
    [ ! -f "/var/log/$APP.log" ] || tail -n 50 "/var/log/$APP.log"
  fi
}
backup_node(){
  read_state
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  local name="$BACKUP_DIR/anytls-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
  tar -czf "$name" -C /etc "$APP"
  chmod 600 "$name"
  ok "备份成功：$name"
  warn "备份含账号密码和证书私钥；请只存放于可信位置。"
}
restore_node(){
  read_state
  local archive
  archive="$(ask '备份包的绝对路径（tar.gz）' "$BACKUP_DIR/anytls-backup.tar.gz")"
  [ -f "$archive" ] || fail "文件不存在"
  fresh
  if ! tar -tzf "$archive" > "$WORK/members"; then fail "备份包无法读取"; fi
  if ! awk '
    {if ($0 !~ /^sing-box-anytls(\/|$)/ && $0 !~ /^\.\/sing-box-anytls(\/|$)/) exit 1;
     if ($0 ~ /(^|\/)\.\.(\/|$)/) exit 1}
  ' "$WORK/members"; then fail "备份包内有异常路径，拒绝恢复"; fi
  mkdir -p "$WORK/unpacked"
  tar -xzf "$archive" -C "$WORK/unpacked" || fail "备份包解压失败"
  local restored="$WORK/unpacked/$APP"
  [ -f "$restored/state.json" ] || [ -f "$WORK/unpacked/./$APP/state.json" ] || fail "备份包缺少 state.json"
  state_valid "$restored/state.json" || fail "备份状态不合法"
  snapshot
  rm -rf -- "$DIR"; cp -a "$restored" "$DIR"
  gen_config "$STATE" "$WORK/candidate.json"
  if ! "$BIN" check -c "$WORK/candidate.json"; then rollback; fail "恢复配置检查失败，已回滚"; fi
  install -m 600 "$WORK/candidate.json" "$CONF"
  if ! service_ctl restart >/dev/null 2>&1; then rollback; fail "恢复后启动失败，已回滚"; fi
  sleep 1
  if ! active; then rollback; fail "恢复后服务退出，已回滚"; fi
  ok "备份恢复成功；密钥/用户与备份保持一致。"
}
backup_menu(){
  printf '\n1) 备份配置和证书\n2) 恢复本项目备份\n0) 返回\n'
  local v; v="$(ask '选择' 0)"
  case "$v" in 1) backup_node ;; 2) restore_node ;; 0) return ;; *) warn "无效选项" ;; esac
}
uninstall_node(){
  read_state
  warn "将仅卸载本 v2 管理的 $APP 服务、配置和独立内核，不触碰 sing-box 主服务。"
  warn "已有备份保存在 $BACKUP_DIR，默认不删除。"
  local token
  read -r -p '输入 REMOVE 确认卸载：' token || return
  [ "$token" = REMOVE ] || { warn "已取消"; return; }
  unit_remove
  rm -rf -- "$DIR" "$(dirname "$BIN")"
  ok "已卸载独立 AnyTLS；未清理防火墙规则和备份。"
}
main(){
  require_root; detect
  while true; do
    printf '\n========== AnyTLS / sing-box v2（独立服务）==========\n'
    printf '系统：%s | CPU：%s | 服务：%s\n' "$PKG" "$ARCH" "$INIT"
    printf ' 1. 一键安装 AnyTLS 节点\n 2. 查看节点信息 / 二维码\n'
    printf ' 3. 新增 / 删除用户\n 4. 修改监听端口、IP、域名及 NAT 映射\n'
    printf ' 5. 查看服务状态\n 6. 启动 / 停止 / 重启服务\n'
    printf ' 7. 更新官方 sing-box 内核\n 8. 管理 TLS 证书及续签\n'
    printf ' 9. 查看日志\n10. 备份 / 恢复配置\n11. 卸载独立服务\n 0. 退出\n'
    local choice; read -r -p '请选择 [0-11]：' choice || break
    case "$choice" in
      1) install_node ;;
      2) install_deps; show_nodes ;;
      3)
        printf '1) 添加用户  2) 删除用户\n'
        local act; act="$(ask '选择' 1)"
        case "$act" in 1) install_deps; create_user ;; 2) install_deps; delete_user ;; esac ;;
      4) install_deps; change_network ;;
      5) install_deps; status ;;
      6) service_menu ;;
      7) install_deps; update_core ;;
      8) install_deps; cert_menu ;;
      9) logs ;;
      10) install_deps; backup_menu ;;
      11) install_deps; uninstall_node ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
