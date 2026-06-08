#!/usr/bin/env bash
# AnyTLS interactive installer for sing-box with NAT port mapping support
# Author: ChatGPT
# Target: Debian/Ubuntu/Alpine/CentOS/RHEL-like Linux

set -Eeuo pipefail

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CLIENT_FILE="${CONFIG_DIR}/client-anytls.json"
INFO_FILE="${CONFIG_DIR}/anytls-info.txt"
CERT_DIR="${CONFIG_DIR}/certs"
SERVICE_NAME="sing-box"
SB_BIN=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

msg() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*" >&2; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
fatal() { err "$*"; exit 1; }

need_root() {
  [ "${EUID}" -eq 0 ] || fatal "请用 root 运行：sudo bash $0"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

read_default() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value
  echo "${value:-$default}"
}

read_required() {
  local prompt="$1" value
  while true; do
    read -r -p "$prompt: " value
    [ -n "$value" ] && { echo "$value"; return; }
    warn "不能为空，请重新输入。"
  done
}

yes_no() {
  local prompt="$1" default="${2:-y}" ans
  local tip="Y/n"
  [ "$default" = "n" ] && tip="y/N"
  read -r -p "$prompt [$tip]: " ans
  ans="${ans:-$default}"
  case "$ans" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

validate_port() {
  local port="$1" label="$2"
  [[ "$port" =~ ^[0-9]+$ ]] || fatal "${label}必须是数字。"
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fatal "${label}范围必须是 1-65535。"
}

random_password() {
  if has_cmd openssl; then
    openssl rand -base64 32 | tr '+/' '-_' | tr -d '=' | cut -c1-32
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
  fi
}

json_escape() {
  # simple JSON string escaping using python when available, fallback for common chars
  local s="$1"
  if has_cmd python3; then
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1])[1:-1])' "$s"
  else
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; echo "$s"
  fi
}

urlencode() {
  local LC_ALL=C s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v out '%s%%%02X' "$out" "'$c" ;;
    esac
  done
  echo "$out"
}

install_base_deps() {
  info "安装基础依赖 curl / wget / tar / openssl ..."
  if has_cmd apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget tar gzip ca-certificates openssl coreutils procps
  elif has_cmd apk; then
    apk add --no-cache curl wget tar gzip ca-certificates openssl coreutils procps
  elif has_cmd dnf; then
    dnf install -y curl wget tar gzip ca-certificates openssl procps-ng
  elif has_cmd yum; then
    yum install -y curl wget tar gzip ca-certificates openssl procps-ng
  else
    warn "未识别包管理器，请确保 curl/wget/tar/openssl 已安装。"
  fi
}

normalize_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    i386|i686) echo "386" ;;
    *) uname -m ;;
  esac
}

version_ge() {
  # return 0 if $1 >= $2
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

singbox_version() {
  if has_cmd sing-box; then
    sing-box version 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++){if($i ~ /^[0-9]+\./){print $i; exit}}}'
  fi
}

find_singbox_bin() {
  if has_cmd sing-box; then
    SB_BIN="$(command -v sing-box)"
  elif [ -x /usr/local/bin/sing-box ]; then
    SB_BIN="/usr/local/bin/sing-box"
  elif [ -x /usr/bin/sing-box ]; then
    SB_BIN="/usr/bin/sing-box"
  else
    SB_BIN=""
  fi
}

download_singbox_from_github() {
  local arch os latest url tmpdir asset
  arch="$(normalize_arch)"
  os="linux"
  tmpdir="$(mktemp -d)"

  latest="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n1)"
  [ -n "$latest" ] || fatal "无法获取 sing-box 最新版本号，请检查 GitHub 访问。"

  asset="sing-box-${latest}-${os}-${arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${latest}/${asset}"
  info "从 GitHub 下载 ${asset}"
  curl -fL --retry 3 --connect-timeout 15 "$url" -o "${tmpdir}/sing-box.tgz" \
    || fatal "下载失败：${url}。可能是架构不支持或 GitHub 网络问题。"
  tar -xzf "${tmpdir}/sing-box.tgz" -C "$tmpdir"
  local bin
  bin="$(find "$tmpdir" -type f -name sing-box -perm -111 | head -n1 || true)"
  [ -n "$bin" ] || fatal "压缩包内未找到 sing-box 可执行文件。"
  install -m 0755 "$bin" /usr/local/bin/sing-box
  rm -rf "$tmpdir"
  msg "sing-box 已安装到 /usr/local/bin/sing-box"
}

install_or_update_singbox() {
  install_base_deps

  local cur=""
  cur="$(singbox_version || true)"
  if [ -n "$cur" ] && version_ge "$cur" "1.12.0"; then
    msg "检测到 sing-box ${cur}，已支持 AnyTLS。"
    find_singbox_bin
    return
  fi

  if [ -n "$cur" ]; then
    warn "当前 sing-box ${cur} 低于 1.12.0，将尝试升级。"
  else
    info "未检测到 sing-box，将安装最新版。"
  fi

  if has_cmd apk; then
    # Alpine first tries apk, then official installer, then GitHub binary fallback.
    apk add --no-cache sing-box || true
  fi

  cur="$(singbox_version || true)"
  if [ -z "$cur" ] || ! version_ge "$cur" "1.12.0"; then
    if curl -fsSL https://sing-box.app/install.sh | sh; then
      msg "已通过官方 install.sh 安装/升级 sing-box。"
    else
      warn "官方 install.sh 未成功，尝试 GitHub release 二进制安装。"
      download_singbox_from_github
    fi
  fi

  find_singbox_bin
  [ -n "$SB_BIN" ] || fatal "sing-box 安装后仍未找到可执行文件。"
  cur="$(singbox_version || true)"
  [ -n "$cur" ] && version_ge "$cur" "1.12.0" || fatal "sing-box 版本仍低于 1.12.0，AnyTLS 不可用。当前：${cur:-unknown}"
  msg "sing-box 版本：${cur}"
}

ensure_cron_for_acme() {
  # acme.sh needs crontab for automatic certificate renewal. Minimal Alpine images often do not include it.
  if has_cmd crontab; then
    return 0
  fi

  info "未检测到 crontab，正在安装 cron/cronie，供 acme.sh 自动续签证书使用 ..."
  if has_cmd apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y cron
    if has_cmd systemctl && [ -d /run/systemd/system ]; then
      systemctl enable --now cron >/dev/null 2>&1 || true
    elif has_cmd service; then
      service cron start >/dev/null 2>&1 || true
    fi
  elif has_cmd apk; then
    apk add --no-cache cronie
    if has_cmd rc-update; then
      rc-update add crond default >/dev/null 2>&1 || true
    fi
    if has_cmd rc-service; then
      rc-service crond start >/dev/null 2>&1 || true
    fi
  elif has_cmd dnf; then
    dnf install -y cronie
    if has_cmd systemctl && [ -d /run/systemd/system ]; then
      systemctl enable --now crond >/dev/null 2>&1 || true
    fi
  elif has_cmd yum; then
    yum install -y cronie
    if has_cmd systemctl && [ -d /run/systemd/system ]; then
      systemctl enable --now crond >/dev/null 2>&1 || true
    fi
  else
    warn "未识别包管理器，无法自动安装 crontab；将尝试强制安装 acme.sh。"
  fi

  if ! has_cmd crontab; then
    warn "仍未检测到 crontab。acme.sh 可强制安装，但证书不会自动续签，需要你后续手动处理。"
    return 1
  fi
  msg "crontab 已可用。"
  return 0
}

make_cert_self_signed() {
  local domain="$1" cert_path="$2" key_path="$3"
  mkdir -p "$(dirname "$cert_path")"
  info "生成自签名证书：${cert_path}"
  if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -days 3650 -nodes \
      -keyout "$key_path" -out "$cert_path" -subj "/CN=${domain}" \
      -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1; then
    warn "当前 openssl 不支持 -addext，改用 RSA 自签名证书。"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$key_path" -out "$cert_path" -subj "/CN=${domain}" >/dev/null 2>&1
  fi
  chmod 600 "$key_path"
}

issue_cert_acme_http() {
  local domain="$1" email="$2" cert_path="$3" key_path="$4"
  warn "申请 Let's Encrypt 证书需要：域名 A/AAAA 已指向本机，80 端口可从公网访问，且未被 Nginx/Caddy/Apache 占用。"
  yes_no "确认继续申请证书吗" "y" || fatal "已取消申请证书。"

  if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
    info "安装 acme.sh ..."
    if ensure_cron_for_acme; then
      curl https://get.acme.sh | sh -s email="$email"
    else
      warn "未安装 crontab，将使用 --force 强制安装 acme.sh；证书自动续签可能不可用。"
      curl https://get.acme.sh | sh -s email="$email" --force
    fi
  fi
  [ -x "$HOME/.acme.sh/acme.sh" ] || fatal "acme.sh 安装失败。"

  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
  "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$domain" --keylength ec-256 --force
  mkdir -p "$(dirname "$cert_path")"
  "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" --ecc \
    --fullchain-file "$cert_path" \
    --key-file "$key_path" \
    --reloadcmd "if command -v systemctl >/dev/null 2>&1; then systemctl restart sing-box || true; elif command -v rc-service >/dev/null 2>&1; then rc-service sing-box restart || true; fi"
  chmod 600 "$key_path"
}

setup_certificate() {
  local domain="$1" mode cert_path key_path email
  mkdir -p "$CERT_DIR"
  echo
  echo "请选择证书方式："
  echo "  1) 使用已有证书路径（推荐：acme.sh / 宝塔 / Caddy 已有证书）"
  echo "  2) 自动申请 Let's Encrypt 证书（HTTP-01，要求 80 端口公网可用）"
  echo "  3) 生成自签名证书（最省事，但客户端需允许 insecure/跳过证书验证）"
  read -r -p "请输入选项 [1/2/3，默认 3]: " mode
  mode="${mode:-3}"

  case "$mode" in
    1)
      cert_path="$(read_required "请输入 fullchain/cert 证书路径")"
      key_path="$(read_required "请输入 private key 私钥路径")"
      [ -f "$cert_path" ] || fatal "证书文件不存在：$cert_path"
      [ -f "$key_path" ] || fatal "私钥文件不存在：$key_path"
      INSECURE="false"
      CERT_PATH="$cert_path"
      KEY_PATH="$key_path"
      ;;
    2)
      email="$(read_default "请输入邮箱，用于 Let's Encrypt 通知" "admin@${domain}")"
      cert_path="${CERT_DIR}/${domain}.fullchain.cer"
      key_path="${CERT_DIR}/${domain}.key"
      issue_cert_acme_http "$domain" "$email" "$cert_path" "$key_path"
      INSECURE="false"
      CERT_PATH="$cert_path"
      KEY_PATH="$key_path"
      ;;
    3|*)
      cert_path="${CERT_DIR}/${domain}.self.crt"
      key_path="${CERT_DIR}/${domain}.self.key"
      make_cert_self_signed "$domain" "$cert_path" "$key_path"
      INSECURE="true"
      CERT_PATH="$cert_path"
      KEY_PATH="$key_path"
      ;;
  esac
}

write_config() {
  local domain="$1" listen_port="$2" external_port="$3" user="$4" pass="$5" listen="$6" profile="$7"
  local j_domain j_user j_pass j_listen j_cert j_key j_profile
  j_domain="$(json_escape "$domain")"
  j_user="$(json_escape "$user")"
  j_pass="$(json_escape "$pass")"
  j_listen="$(json_escape "$listen")"
  j_cert="$(json_escape "$CERT_PATH")"
  j_key="$(json_escape "$KEY_PATH")"
  j_profile="$(json_escape "$profile")"

  mkdir -p "$CONFIG_DIR"
  if [ -f "$CONFIG_FILE" ]; then
    cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    warn "已备份原配置：${CONFIG_FILE}.bak.*"
  fi

  cat > "$CONFIG_FILE" <<EOF_JSON
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "${j_listen}",
      "listen_port": ${listen_port},
      "users": [
        {
          "name": "${j_user}",
          "password": "${j_pass}"
        }
      ],
      "padding_scheme": [
        "stop=8",
        "0=30-30",
        "1=100-400",
        "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
        "3=9-9,500-1000",
        "4=500-1000",
        "5=500-1000",
        "6=500-1000",
        "7=500-1000"
      ],
      "tls": {
        "enabled": true,
        "server_name": "${j_domain}",
        "certificate_path": "${j_cert}",
        "key_path": "${j_key}",
        "min_version": "1.2"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF_JSON

  cat > "$CLIENT_FILE" <<EOF_JSON
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 10808
    }
  ],
  "outbounds": [
    {
      "type": "anytls",
      "tag": "${j_profile}",
      "server": "${j_domain}",
      "server_port": ${external_port},
      "password": "${j_pass}",
      "idle_session_check_interval": "30s",
      "idle_session_timeout": "30s",
      "min_idle_session": 5,
      "tls": {
        "enabled": true,
        "server_name": "${j_domain}",
        "insecure": ${INSECURE},
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "${j_profile}"
  }
}
EOF_JSON

  msg "服务端配置已写入：$CONFIG_FILE"
  msg "客户端 sing-box 示例已写入：$CLIENT_FILE"

  find_singbox_bin
  "$SB_BIN" check -c "$CONFIG_FILE" || fatal "sing-box 配置检查失败，请查看上方错误。"
}

write_systemd_service() {
  find_singbox_bin
  [ -n "$SB_BIN" ] || fatal "找不到 sing-box 可执行文件。"
  cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF_UNIT
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
ExecStart=${SB_BIN} run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF_UNIT
  systemctl daemon-reload
  systemctl enable ${SERVICE_NAME} >/dev/null 2>&1 || true
  systemctl restart ${SERVICE_NAME}
  systemctl --no-pager --full status ${SERVICE_NAME} || true
}

write_openrc_service() {
  find_singbox_bin
  [ -n "$SB_BIN" ] || fatal "找不到 sing-box 可执行文件。"
  cat > /etc/init.d/${SERVICE_NAME} <<EOF_RC
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="${SB_BIN}"
command_args="run -c ${CONFIG_FILE}"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"

depend() {
    need net
    after firewall
}
EOF_RC
  chmod +x /etc/init.d/${SERVICE_NAME}
  rc-update add ${SERVICE_NAME} default >/dev/null 2>&1 || true
  rc-service ${SERVICE_NAME} restart
  rc-service ${SERVICE_NAME} status || true
}

restart_service() {
  if has_cmd systemctl && [ -d /run/systemd/system ]; then
    write_systemd_service
  elif has_cmd rc-service; then
    write_openrc_service
  else
    warn "未检测到 systemd/openrc，使用 nohup 临时启动。"
    pkill -f "sing-box run -c ${CONFIG_FILE}" >/dev/null 2>&1 || true
    nohup "$SB_BIN" run -c "$CONFIG_FILE" >/var/log/sing-box.log 2>&1 &
    msg "已用 nohup 启动，日志：/var/log/sing-box.log"
  fi
}

open_firewall_port() {
  local port="$1"
  yes_no "是否尝试自动放行 TCP ${port} 端口" "y" || return 0
  if has_cmd ufw; then
    ufw allow "${port}/tcp" || true
  fi
  if has_cmd firewall-cmd; then
    firewall-cmd --permanent --add-port="${port}/tcp" || true
    firewall-cmd --reload || true
  fi
  if has_cmd iptables; then
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || true
  fi
  if has_cmd ip6tables; then
    ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT || true
  fi
  msg "防火墙规则已尝试添加。NAT 面板/服务商映射仍需确认：外部端口要映射到本机 TCP ${port}。"
}

save_info() {
  local domain="$1" listen_port="$2" external_port="$3" user="$4" pass="$5" profile="$6"
  local enc_pass uri insecure_text
  enc_pass="$(urlencode "$pass")"
  uri="anytls://${enc_pass}@${domain}:${external_port}#$(urlencode "$profile")"
  insecure_text="否"
  [ "$INSECURE" = "true" ] && insecure_text="是，自签名证书客户端要允许 insecure/跳过证书验证"

  cat > "$INFO_FILE" <<EOF_INFO
AnyTLS / sing-box 信息
======================
节点名称: ${profile}
协议: AnyTLS
地址: ${domain}
服务端本机监听端口: ${listen_port}
客户端外部连接端口: ${external_port}
用户: ${user}
密码: ${pass}
SNI / server_name: ${domain}
客户端是否需要 insecure: ${insecure_text}
证书: ${CERT_PATH}
私钥: ${KEY_PATH}
服务端配置: ${CONFIG_FILE}
客户端 sing-box 示例: ${CLIENT_FILE}

NAT 端口说明：
  服务端 sing-box 只监听本机端口 ${listen_port}；客户端、订阅链接、mihomo 片段都使用外部端口 ${external_port}。
  请在 NAT 面板确认：外部 TCP ${external_port} -> 本机 TCP ${listen_port}。

通用 URI（支持情况取决于客户端版本）:
${uri}

mihomo/Clash Meta 参考片段：
proxies:
  - name: ${profile}
    type: anytls
    server: ${domain}
    port: ${external_port}
    password: ${pass}
    sni: ${domain}
    skip-cert-verify: ${INSECURE}
    udp: true

常用命令：
  查看状态: systemctl status sing-box --no-pager    或 rc-service sing-box status
  重启服务: systemctl restart sing-box              或 rc-service sing-box restart
  查看日志: journalctl -u sing-box -f               或 tail -f /var/log/sing-box.log
  配置检查: sing-box check -c ${CONFIG_FILE}
EOF_INFO
  chmod 600 "$INFO_FILE" || true
  msg "节点信息已保存：$INFO_FILE"
  echo
  cat "$INFO_FILE"
  echo
  if has_cmd qrencode; then
    echo "URI 二维码："
    qrencode -t ANSIUTF8 "$uri" || true
  else
    info "如需终端显示二维码，可安装 qrencode。"
  fi
}

install_anytls() {
  need_root
  install_or_update_singbox

  echo
  local domain listen_port external_port user pass listen profile
  domain="$(read_required "请输入绑定域名/SNI，例如 node.example.com")"
  listen_port="$(read_default "请输入服务端本机监听端口（NAT 内部端口，例如 443）" "443")"
  validate_port "$listen_port" "服务端本机监听端口"
  external_port="$(read_default "请输入客户端外部连接端口（NAT 外部端口，普通 VPS 填同上）" "$listen_port")"
  validate_port "$external_port" "客户端外部连接端口"

  if [ "$listen_port" != "$external_port" ]; then
    warn "已启用 NAT 端口分离：服务端监听 ${listen_port}，客户端连接 ${external_port}。"
    warn "请确认服务商 NAT 面板已设置 TCP ${external_port} -> ${listen_port}，否则客户端无法连接。"
  fi

  user="$(read_default "请输入用户名" "user1")"
  pass="$(read_default "请输入密码，留空则使用默认随机密码" "$(random_password)")"
  listen="$(read_default "监听地址：:: 表示 IPv6/多数系统双栈，0.0.0.0 表示仅 IPv4" "::")"
  profile="$(read_default "请输入节点名称" "AnyTLS-${domain}")"

  setup_certificate "$domain"
  write_config "$domain" "$listen_port" "$external_port" "$user" "$pass" "$listen" "$profile"
  open_firewall_port "$listen_port"
  restart_service
  save_info "$domain" "$listen_port" "$external_port" "$user" "$pass" "$profile"
}

show_info() {
  if [ -f "$INFO_FILE" ]; then
    cat "$INFO_FILE"
  else
    warn "未找到 $INFO_FILE，请先安装 AnyTLS。"
  fi
}

show_logs() {
  if has_cmd journalctl && has_cmd systemctl && [ -d /run/systemd/system ]; then
    journalctl -u ${SERVICE_NAME} -n 80 --no-pager
  elif [ -f /var/log/sing-box.log ]; then
    tail -n 80 /var/log/sing-box.log
  else
    warn "未找到日志。"
  fi
}

restart_only() {
  need_root
  find_singbox_bin
  [ -n "$SB_BIN" ] || fatal "未安装 sing-box。"
  [ -f "$CONFIG_FILE" ] || fatal "未找到配置：$CONFIG_FILE"
  "$SB_BIN" check -c "$CONFIG_FILE" || fatal "配置检查失败。"
  restart_service
  msg "sing-box 已重启。"
}

uninstall_config() {
  need_root
  warn "这会停止 sing-box，并移动 /etc/sing-box 到备份目录；不会删除 sing-box 二进制。"
  yes_no "确认卸载配置吗" "n" || return 0
  if has_cmd systemctl && [ -d /run/systemd/system ]; then
    systemctl stop ${SERVICE_NAME} >/dev/null 2>&1 || true
    systemctl disable ${SERVICE_NAME} >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload || true
  elif has_cmd rc-service; then
    rc-service ${SERVICE_NAME} stop >/dev/null 2>&1 || true
    rc-update del ${SERVICE_NAME} default >/dev/null 2>&1 || true
    rm -f /etc/init.d/${SERVICE_NAME}
  fi
  if [ -d "$CONFIG_DIR" ]; then
    mv "$CONFIG_DIR" "${CONFIG_DIR}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  msg "已停止服务并备份配置目录。"
}

menu() {
  while true; do
    echo
    echo "========== AnyTLS / sing-box 交互脚本 =========="
    echo "1) 安装 / 重装 AnyTLS 节点"
    echo "2) 查看节点信息"
    echo "3) 重启 sing-box"
    echo "4) 查看日志"
    echo "5) 卸载配置（不删除 sing-box 二进制）"
    echo "0) 退出"
    read -r -p "请选择 [0-5]: " choice
    case "$choice" in
      1) install_anytls ;;
      2) show_info ;;
      3) restart_only ;;
      4) show_logs ;;
      5) uninstall_config ;;
      0) exit 0 ;;
      *) warn "无效选项。" ;;
    esac
  done
}

main() {
  need_root
  menu
}

main "$@"
