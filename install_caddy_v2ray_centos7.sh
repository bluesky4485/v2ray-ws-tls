#!/bin/bash
# filename: install_caddy_v2ray_centos7.sh
# CentOS 7: Install Caddy (auto HTTPS) + V2Ray (ws behind Caddy)
# TLS is terminated by Caddy; V2Ray listens on 127.0.0.1:11234 (ws)
# This script handles potential repo issues by using fallback installers.

set -euo pipefail

# Colored output
blue(){ echo -e "\033[34m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }

# Globals
SYSTEM_PACKAGE="yum"
V2RAY_CONF_DIR="/usr/local/etc/v2ray"
V2RAY_SERVICE="v2ray.service"
CADDY_SERVICE="caddy.service"
CADDYFILE="/etc/caddy/Caddyfile"
WEB_ROOT="/var/www/html"
CADDY_BIN="/usr/bin/caddy"
CADDY_USER="caddy"
CADDY_GROUP="caddy"
your_domain=""
newpath=""
v2uuid=""

require_root() {
  if [ "$EUID" -ne 0 ]; then
    red "请以 root 身份运行（使用 sudo 或切换 root）"
    exit 1
  fi
}

check_os() {
  green "系统支持检测"
  sleep 1s
  if ! grep -Eqi "CentOS Linux.*7" /etc/os-release && ! grep -Eqi "CentOS.*release 7" /etc/redhat-release; then
    red "当前系统并非 CentOS 7，脚本仅支持 CentOS 7"
    exit 1
  fi

  # Make YUM faster/more reliable
  $SYSTEM_PACKAGE -y install epel-release >/dev/null 2>&1 || true
  $SYSTEM_PACKAGE -y install curl wget unzip tar net-tools socat jq >/dev/null 2>&1 || true

  # SELinux: allow 80/443 if enforcing
  if command -v getenforce >/dev/null 2>&1; then
    SEL=$(getenforce || echo Permissive)
    if [ "$SEL" = "Enforcing" ]; then
      green "检测到 SELinux Enforcing，开放 http(s) 端口"
      $SYSTEM_PACKAGE -y install policycoreutils-python >/dev/null 2>&1 || true
      semanage port -a -t http_port_t -p tcp 80 >/dev/null 2>&1 || semanage port -m -t http_port_t -p tcp 80 || true
      semanage port -a -t http_port_t -p tcp 443 >/dev/null 2>&1 || semanage port -m -t http_port_t -p tcp 443 || true
    fi
  fi

  # Firewalld: open 80/443
  if systemctl is-active --quiet firewalld; then
    green "开放 firewalld 80/443"
    firewall-cmd --zone=public --add-service=http --permanent || firewall-cmd --zone=public --add-port=80/tcp --permanent
    firewall-cmd --zone=public --add-service=https --permanent || firewall-cmd --zone=public --add-port=443/tcp --permanent
    firewall-cmd --reload || true
  fi
}

check_env() {
  green "安装环境监测"
  sleep 1s
  Port80=$(netstat -tlpn | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 80 || true)
  Port443=$(netstat -tlpn | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 443 || true)

  if [ -n "$Port80" ]; then
    process80=$(netstat -tlpn | awk -F '[: ]+' '$5=="80"{print $9}' | head -n1)
    red "检测到 80 端口被占用：${process80}，请先释放该端口"
    exit 1
  fi
  if [ -n "$Port443" ]; then
    process443=$(netstat -tlpn | awk -F '[: ]+' '$5=="443"{print $9}' | head -n1)
    red "检测到 443 端口被占用：${process443}，请先释放该端口"
    exit 1
  fi
}

prompt_domain() {
  green "======================="
  blue "请输入绑定到本VPS的域名（需已解析到本机IP）"
  green "======================="
  read -r your_domain

  real_addr=$(ping -4 -c 1 "$your_domain" | sed '1{s/[^(]*(//;s/).*//;q}' || true)
  local_addr=$(curl -s ipv4.icanhazip.com || true)

  if [ -z "$real_addr" ] || [ -z "$local_addr" ]; then
    yellow "无法校验域名解析或本机 IP，是否仍要继续？[Y/n]"
    read -r yn
    [ -z "${yn:-}" ] && yn="y"
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
      exit 1
    fi
  else
    if [ "$real_addr" != "$local_addr" ]; then
      red "域名解析地址(${real_addr})与本机 IP(${local_addr})不一致"
      read -p "是否强制继续安装？[Y/n] " yn
      [ -z "${yn:-}" ] && yn="y"
      if [[ ! "$yn" =~ ^[Yy]$ ]]; then
        exit 1
      fi
    else
      green "域名解析正常，开始安装"
    fi
  fi
}

install_caddy_repo_or_fallback() {
  green "安装 Caddy（优先官方仓库，失败则回退为二进制安装）"

  # Try official RPM repo
  repo_ok=0
  if command -v rpm >/dev/null 2>&1; then
    # Import Caddy repo via copr (historically) or cloudsmith; CentOS7 often needs cloudsmith
    # Cloudsmith repo route:
    $SYSTEM_PACKAGE -y install yum-plugin-copr >/dev/null 2>&1 || true
    $SYSTEM_PACKAGE -y install gnupg ca-certificates >/dev/null 2>&1 || true

    if curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/rpm/el/7/x86_64/ | head -n1 >/dev/null 2>&1; then
      cat >/etc/yum.repos.d/caddy-stable.repo <<'REPO'
[caddy-stable]
name=Caddy Stable - $basearch
baseurl=https://dl.cloudsmith.io/public/caddy/stable/rpm/el/7/$basearch/
repo_gpgcheck=1
gpgcheck=1
enabled=1
gpgkey=https://dl.cloudsmith.io/public/caddy/stable/gpg.key
       https://dl.cloudsmith.io/public/caddy/stable/rpm/el/7/$basearch/repodata/repomd.xml.key
REPO
      if yum -y install caddy >/dev/null 2>&1; then
        repo_ok=1
      fi
    fi
  fi

  if [ "$repo_ok" -eq 0 ]; then
    yellow "仓库安装失败，尝试使用静态二进制安装 Caddy"
    # Fallback: download latest caddy linux amd64 from GitHub releases
    # We avoid relying on yum when repos are broken
    tmpdir=$(mktemp -d)
    cd "$tmpdir"
    if ! command -v jq >/dev/null 2>&1; then
      $SYSTEM_PACKAGE -y install jq >/dev/null 2>&1 || true
    fi
    # Get latest release URL
    api_json=$(curl -fsSL https://api.github.com/repos/caddyserver/caddy/releases/latest)
    dl_url=$(echo "$api_json" | jq -r '.assets[] | select(.name | test("caddy_.*_linux_amd64.tar.gz")) | .browser_download_url' | head -n1)
    if [ -z "$dl_url" ]; then
      red "无法获取 Caddy 二进制下载链接，请检查网络或 GitHub API 访问"
      exit 1
    fi
    curl -fsSL "$dl_url" -o caddy.tar.gz
    tar xzf caddy.tar.gz
    # tar contains caddy binary
    install -m 0755 caddy "$CADDY_BIN"
    # Create caddy user and group (no-login)
    getent group "$CADDY_GROUP" >/dev/null 2>&1 || groupadd --system "$CADDY_GROUP"
    id -u "$CADDY_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin -g "$CADDY_GROUP" "$CADDY_USER"
    mkdir -p /etc/caddy /var/lib/caddy "$WEB_ROOT"
    chown -R "$CADDY_USER":"$CADDY_GROUP" /etc/caddy /var/lib/caddy
    # Systemd unit
    cat >/etc/systemd/system/caddy.service <<'UNIT'
[Unit]
Description=Caddy web server
After=network.target

[Service]
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
Restart=on-failure
TimeoutStopSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
  fi

  mkdir -p /etc/caddy "$WEB_ROOT"
  # Simple index page
  echo "<!doctype html><html><head><meta charset='utf-8'><title>Welcome</title></head><body><h1>Welcome</h1></body></html>" > "$WEB_ROOT/index.html"

  # Random ws path
  newpath=$(head -c 32 /dev/urandom | md5sum | head -c 8)

  # Write Caddyfile (HSTS header simplified to single-line valid syntax)
  cat > "$CADDYFILE" <<EOF
{
  email admin@${your_domain}
  # Optional: increase timeouts etc.
}

${your_domain} {
  root * ${WEB_ROOT}
  file_server

  # HSTS（谨慎开启：确认全站 HTTPS 后使用）
  header Strict-Transport-Security "max-age=31536000"

  @v2ws {
    path /${newpath}*
  }
  reverse_proxy @v2ws 127.0.0.1:11234 {
    header_up Host {host}
    header_up X-Real-IP {remote}
    header_up X-Forwarded-For {remote}
    header_up X-Forwarded-Proto {scheme}
  }
}
EOF

  systemctl daemon-reload
  systemctl enable "$CADDY_SERVICE"
  systemctl restart "$CADDY_SERVICE"

  # Validate Caddyfile if possible
  if "$CADDY_BIN" validate --config "$CADDYFILE" >/dev/null 2>&1; then
    green "Caddy 配置验证通过"
  else
    yellow "Caddy 配置验证失败，但已尝试启动。请执行：caddy validate --config $CADDYFILE 查看详情"
  fi
}

install_v2ray_repo_or_fallback() {
  green "安装 V2Ray（优先官方脚本，失败则回退到 release 安装）"

  if bash <(curl -L -s https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh); then
    :
  else
    yellow "官方安装脚本失败，回退到二进制安装"
    tmpdir=$(mktemp -d)
    cd "$tmpdir"
    # 查询最新发行版
    api_json=$(curl -fsSL https://api.github.com/repos/v2fly/v2ray-core/releases/latest)
    dl_url=$(echo "$api_json" | jq -r '.assets[] | select(.name | test("linux-64.zip$")) | .browser_download_url' | head -n1)
    if [ -z "$dl_url" ]; then
      red "无法获取 V2Ray 下载链接，请检查网络或 GitHub API 访问"
      exit 1
    fi
    curl -fsSL "$dl_url" -o v2ray.zip
    unzip v2ray.zip -d v2ray >/dev/null 2>&1
    install -m 0755 v2ray/v2ray /usr/local/bin/v2ray
    install -m 0755 v2ray/v2ctl /usr/local/bin/v2ctl
    mkdir -p "$V2RAY_CONF_DIR" /usr/local/share/v2ray
    # 复制 geo 数据（若存在）
    [ -f v2ray/geoip.dat ] && install -m 0644 v2ray/geoip.dat /usr/local/share/v2ray/geoip.dat
    [ -f v2ray/geosite.dat ] && install -m 0644 v2ray/geosite.dat /usr/local/share/v2ray/geosite.dat
    # Systemd unit
    cat >/etc/systemd/system/v2ray.service <<'UNIT'
[Unit]
Description=V2Ray Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/v2ray -config /usr/local/etc/v2ray/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable v2ray.service
  fi

  mkdir -p "$V2RAY_CONF_DIR"
  v2uuid=$(cat /proc/sys/kernel/random/uuid)

  # V2Ray config: inbound ws at 127.0.0.1:11234, path = /$newpath
  cat > "$V2RAY_CONF_DIR/config.json" <<EOF
{
  "inbounds": [
    {
      "port": 11234,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$v2uuid",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/$newpath"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF

  systemctl restart "$V2RAY_SERVICE"

  # Local config summary
  cat > "$V2RAY_CONF_DIR/myconfig.txt" <<EOF
===========配置参数=============
地址：$your_domain
端口：443
uuid：$v2uuid
额外id：0
加密方式：aes-128-gcm（客户端可按需设置）
传输协议：ws
路径：/$newpath
底层传输：tls（由 Caddy 终止）
别名：myws
================================
EOF

  green "=============================="
  green "安装完成：请在客户端设置"
  green "地址：$your_domain 端口：443 协议：vmess 传输：ws 路径：/$newpath TLS：开启"
}

remove_all() {
  yellow "开始卸载 Caddy 与 V2Ray"

  systemctl stop "$CADDY_SERVICE" || true
  systemctl disable "$CADDY_SERVICE" || true
  $SYSTEM_PACKAGE -y remove caddy >/dev/null 2>&1 || true
  rm -f "$CADDY_BIN" || true
  rm -rf /etc/caddy "$WEB_ROOT" /var/lib/caddy || true
  rm -f /etc/yum.repos.d/caddy-stable.repo || true

  systemctl stop "$V2RAY_SERVICE" || true
  systemctl disable "$V2RAY_SERVICE" || true
  rm -rf /usr/local/bin/v2ray /usr/local/bin/v2ctl || true
  rm -rf /usr/local/share/v2ray/ "$V2RAY_CONF_DIR" || true
  rm -rf /etc/systemd/system/v2ray.service || true

  systemctl daemon-reload || true

  green "Caddy、V2Ray 已卸载"
}

start_menu() {
  clear
  green " ==============================================="
  green " Info       : onekey install Caddy+V2Ray (CentOS 7)"
  green " OS support : CentOS 7"
  green " Author     : A (Caddy+V2Ray)"
  green " ==============================================="
  echo
  green " 1. Install Caddy + V2Ray (ws+tls via Caddy)"
  green " 2. Update V2Ray (official script)"
  red   " 3. Remove Caddy & V2Ray"
  yellow " 0. Exit"
  echo
  read -p "Pls enter a number: " num
  case "$num" in
    1)
      require_root
      check_os
      check_env
      prompt_domain
      install_caddy_repo_or_fallback
      install_v2ray_repo_or_fallback
      ;;
    2)
      bash <(curl -L -s https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
      systemctl restart "$V2RAY_SERVICE"
      ;;
    3)
      require_root
      remove_all
      ;;
    0)
      exit 0
      ;;
    *)
      red "Enter the correct number"
      sleep 1s
      start_menu
      ;;
  esac
}

start_menu
