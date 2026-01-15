#!/bin/bash
# filename: v2ray_ws_tls_caddy_ubuntu.sh
# 一键安装 v2ray + ws + tls1.3 (Ubuntu 16.04+)，使用 Caddy 自动 HTTPS
# Author: Ubuntu+Caddy 版本
# 说明：
# - 请先将你的域名 DNS A 记录解析到本机公网 IP
# - Caddy 会自动申请/续期证书（默认使用 Let’s Encrypt/ZeroSSL）
# - Caddy 需要 80/443 端口可用，务必释放占用

set -euo pipefail

# 彩色输出
blue(){ echo -e "\033[34m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }

# 变量
SYSTEM_PACKAGE="apt-get"
V2RAY_CONF_DIR="/usr/local/etc/v2ray"
V2RAY_SERVICE="v2ray.service"
CADDY_SERVICE="caddy.service"
CADDYFILE="/etc/caddy/Caddyfile"
WEB_ROOT="/var/www/html"
your_domain=""
newpath=""
v2uuid=""

check_os() {
  green "系统支持检测"
  sleep 1s

  if ! grep -Eiq "Ubuntu" /etc/os-release; then
    red "==============="
    red "当前系统不是 Ubuntu，脚本仅支持 Ubuntu 16.04+"
    red "==============="
    exit 1
  fi
  UBUNTU_VER=$(grep VERSION_ID /etc/os-release | sed -E 's/.*"([0-9.]+)".*/\1/')
  if dpkg --compare-versions "$UBUNTU_VER" lt "16.04"; then
    red "==============="
    red "当前 Ubuntu 版本 ($UBUNTU_VER) 太低，不受支持"
    red "==============="
    exit 1
  fi

  $SYSTEM_PACKAGE update -y >/dev/null 2>&1
  green "开始安装依赖"
  $SYSTEM_PACKAGE install -y curl wget unzip tar net-tools socat ufw ca-certificates lsb-release >/dev/null 2>&1

  # 开放 ufw 80/443（仅当 ufw 已启用）
  if systemctl is-active --quiet ufw; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
  fi
}

check_env() {
  green "安装环境监测"
  sleep 1s

  Port80=$(netstat -tlpn | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 80 || true)
  Port443=$(netstat -tlpn | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 443 || true)

  if [ -n "$Port80" ]; then
    process80=$(netstat -tlpn | awk -F '[: ]+' '$5=="80"{print $9}' | head -n1)
    red "==========================================================="
    red "检测到 80 端口被占用，占用进程为：${process80}，请先释放该端口"
    red "==========================================================="
    exit 1
  fi
  if [ -n "$Port443" ]; then
    process443=$(netstat -tlpn | awk -F '[: ]+' '$5=="443"{print $9}' | head -n1)
    red "============================================================="
    red "检测到 443 端口被占用，占用进程为：${process443}，请先释放该端口"
    red "============================================================="
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
      red "===================================="
      red "域名解析地址(${real_addr})与本VPS IP(${local_addr})不一致"
      red "若你确认解析成功你可强制脚本继续运行"
      red "===================================="
      read -p "是否强制运行 ?请输入 [Y/n] :" yn
      [ -z "${yn:-}" ] && yn="y"
      if [[ ! "$yn" =~ ^[Yy]$ ]]; then
        exit 1
      fi
    else
      green "=========================================="
      green "         域名解析正常，开始安装"
      green "=========================================="
    fi
  fi
}

install_caddy() {
  green "安装 Caddy（自动 HTTPS/HTTP2/HTTP3）"
  # 官方仓库
  apt install -y debian-keyring debian-archive-keyring gnupg >/dev/null 2>&1 || true
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | tee /etc/apt/sources.list.d/caddy-stable.list
  $SYSTEM_PACKAGE update -y >/dev/null 2>&1
  $SYSTEM_PACKAGE install -y caddy >/dev/null 2>&1

  mkdir -p "$(dirname "$CADDYFILE")" "$WEB_ROOT"

  # 简单静态主页
  echo "<!doctype html><html><head><meta charset='utf-8'><title>Welcome</title></head><body><h1>Welcome</h1></body></html>" > "$WEB_ROOT/index.html"

  # 随机 ws 路径
  newpath=$(head -c 32 /dev/urandom | md5sum | head -c 4)

  # 写入 Caddyfile
  cat > "$CADDYFILE" <<EOF
{
  email admin@${your_domain}
}

${your_domain} {
  root * ${WEB_ROOT}
  file_server

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

  systemctl enable "$CADDY_SERVICE"
  systemctl restart "$CADDY_SERVICE"
}

install_v2ray() {
  green "安装 v2ray"
  bash <(curl -L -s https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

  mkdir -p "$V2RAY_CONF_DIR"
  v2uuid=$(cat /proc/sys/kernel/random/uuid)

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
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF

  systemctl enable "$V2RAY_SERVICE"
  systemctl restart "$V2RAY_SERVICE"

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
  green "         安装已经完成"
  green "===========配置参数============"
  green "地址：$your_domain"
  green "端口：443"
  green "uuid：$v2uuid"
  green "额外id：0"
  green "加密方式：aes-128-gcm"
  green "传输协议：ws"
  green "路径：/$newpath"
  green "底层传输：tls（Caddy）"
}

remove_all() {
  yellow "开始卸载 Caddy 与 v2ray"

  systemctl stop "$CADDY_SERVICE" || true
  systemctl disable "$CADDY_SERVICE" || true
  $SYSTEM_PACKAGE purge -y caddy || true
  $SYSTEM_PACKAGE autoremove -y || true
  rm -rf /etc/caddy "$WEB_ROOT" || true

  systemctl stop "$V2RAY_SERVICE" || true
  systemctl disable "$V2RAY_SERVICE" || true
  rm -rf /usr/local/bin/v2ray /usr/local/bin/v2ctl || true
  rm -rf /usr/local/share/v2ray/ "$V2RAY_CONF_DIR" || true
  rm -rf /etc/systemd/system/v2ray* || true
  systemctl daemon-reload || true

  green "Caddy、v2ray 已删除"
}

start_menu() {
  clear
  green " ==============================================="
  green " Info       : onekey script install v2ray+ws+tls (Ubuntu + Caddy)"
  green " OS support : Ubuntu 16.04+"
  green " Author     : A (Caddy adapted)"
  green " ==============================================="
  echo
  green " 1. Install v2ray+ws+tls1.3 (Caddy)"
  green " 2. Update v2ray"
  red   " 3. Remove v2ray & Caddy"
  yellow " 0. Exit"
  echo
  read -p "Pls enter a number: " num
  case "$num" in
    1)
      check_os
      check_env
      prompt_domain
      install_caddy
      install_v2ray
      ;;
    2)
      bash <(curl -L -s https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
      systemctl restart "$V2RAY_SERVICE"
      ;;
    3)
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
