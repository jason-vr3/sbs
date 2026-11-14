#!/bin/bash
# sbs - sing-box 一键安装与管理脚本（官方源版，专注 VLESS-Reality + Hysteria2）
# 版本: 1.0
# GitHub: https://github.com/jason-vr3/sbs (公开版本 v1.0)
# 适用: Debian 12 / Ubuntu 22.04 / 24.04，amd64 / arm64
# 用法: bash sbs.sh ，首次运行后直接输入 sbs 即可进入管理菜单
# 注意: 本脚本只使用两个官方来源：
#   1. sing-box 官方安装脚本 https://sing-box.app/install.sh
#   2. acme.sh 官方安装脚本 https://get.acme.sh
# 配置仅使用单个 /etc/sing-box/config.json，所有配置备份、密钥记录与导出片段统一存放在 /root/ 下。

SCRIPT_VERSION="1.0"
# 如果你将本脚本上传到了自己的 GitHub 仓库，可将下方变量填为你的 Raw 直链地址，即可在菜单 12 中直接回车一键更新
DEFAULT_SCRIPT_URL="https://raw.githubusercontent.com/jason-vr3/sbs/main/sbs.sh"

SB_DIR="/etc/sing-box"
SB_CONFIG="/etc/sing-box/config.json"
SB_SERVICE="sing-box"
SBS_BIN="/usr/local/bin/sbs"
KEYS_FILE="/root/sbs-keys.txt"
CLASH_FILE="/root/sbs-clash.yaml"
SB_CLIENT_FILE="/root/sbs-client-outbounds.json"
ACME_HOME="${HOME}/.acme.sh"
ACME_SH="${ACME_HOME}/acme.sh"

# 开启未定义变量报错和管道错误传递；不开启 -e 以便交互菜单平稳处理取消与空输入
set -uo pipefail

# 全局当前配置缓存变量（由 read_current_values 填充，无任何个人硬编码域名）
CUR_UUID=""
CUR_PRIV=""
CUR_PUB=""
CUR_SHORT=""
CUR_VLESS_PORT="443"
CUR_SNI="www.icloud.com"
CUR_HY2_PASS=""
CUR_OBFS=""
CUR_HY2_PORT="8443"
CUR_HY2_DOMAIN="www.bing.com"
CUR_UP="100"
CUR_DOWN="100"

# ---------- 终端退格键 (^H) 修复与颜色输出 ----------
fix_terminal_backspace() {
	if [[ -t 0 ]]; then
		stty erase '^H' 2>/dev/null || true
		bind '"\C-h": backward-delete-char' 2>/dev/null || true
		bind '"\C-?": backward-delete-char' 2>/dev/null || true
	fi
}

red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }
blue() { echo -e "\033[36m\033[01m$1\033[0m"; }
plain() { echo -e "$1"; }

# 使用 echo -ne 打印彩色提示符 + read -er 启用 readline 行编辑，彻底解决退格出现 ^H 及光标错位问题
readp() {
	read -rp $'\001\033[33m\033[01m\002'"$1"$'\001\033[0m\002' "$2"
}

press_any_key() {
	echo ""
	read -rp $'\001\033[33m\033[01m\002按回车继续...\001\033[0m\002' _dummy || true
}

# ---------- 基础检查 ----------
need_root() {
	if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		red "请以 root 权限运行本脚本"
		exit 1
	fi
}

check_os() {
	local os_id=""
	if [[ -f /etc/os-release ]]; then
		os_id="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
	fi
	case "$os_id" in
	debian | ubuntu) return 0 ;;
	*)
		red "本脚本仅支持 Debian / Ubuntu，当前系统 ID 为：${os_id:-未知}，已退出"
		exit 1
		;;
	esac
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

get_arch() {
	case "$(uname -m)" in
	x86_64) echo "amd64" ;;
	aarch64) echo "arm64" ;;
	*)
		red "不支持的架构：$(uname -m)，仅支持 x86_64 / aarch64"
		exit 1
		;;
	esac
}

get_ip() {
	local ip=""
	ip="$(curl -fsS -4 -m 5 https://api.ipify.org 2>/dev/null || curl -fsS -4 -m 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
	if [[ -z "$ip" ]]; then
		ip="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i !~ /:/) {print $i; exit}}')"
	fi
	if [[ -z "$ip" ]]; then
		ip="$(curl -fsS -6 -m 5 https://api64.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
	fi
	printf '%s' "$ip"
}

# 针对 IPv6 地址在 URI 中自动包裹方括号
format_host_for_uri() {
	local h="$1"
	if [[ "$h" == *:* && "$h" != \[*\] ]]; then
		printf '[%s]' "$h"
	else
		printf '%s' "$h"
	fi
}

# ---------- 注册 sbs 快捷启动命令 ----------
install_sbs_command() {
	local quiet="${1:-0}"
	local src=""
	src="$(readlink -f "$0" 2>/dev/null || echo "$0")"
	if [[ -z "$src" || ! -f "$src" ]]; then
		[[ "$quiet" -eq 0 ]] && yellow "当前通过管道或临时流运行，无法直接复制脚本到 $SBS_BIN（建议先保存为 /root/sbs.sh 再运行）"
		return 0
	fi
	if [[ "$src" == "$SBS_BIN" ]]; then
		chmod +x "$SBS_BIN" 2>/dev/null || true
		[[ "$quiet" -eq 0 ]] && green "sbs 快捷命令已就绪（直接输入 sbs 即可进入菜单）"
		return 0
	fi
	if install -m 755 "$src" "$SBS_BIN" 2>/dev/null || cp -f "$src" "$SBS_BIN" 2>/dev/null; then
		chmod +x "$SBS_BIN" 2>/dev/null || true
		[[ "$quiet" -eq 0 ]] && green "已安装 sbs 快捷命令：以后直接输入 sbs 即可进入菜单"
	else
		[[ "$quiet" -eq 0 ]] && yellow "自动安装 sbs 命令失败，请手动执行：cp $src $SBS_BIN && chmod +x $SBS_BIN"
	fi
	return 0
}

# ---------- 依赖安装 ----------
install_deps() {
	echo "=== 检查并安装依赖 ==="
	if ! cmd_exists apt-get; then
		red "找不到 apt-get，本脚本只支持 Debian / Ubuntu"
		return 1
	fi
	apt-get update -y || {
		red "apt-get update 失败，请检查 VPS 网络或软件源"
		return 1
	}
	apt-get install -y jq curl openssl socat cron iproute2 procps ca-certificates tar qrencode iptables || {
		red "依赖软件包安装失败"
		return 1
	}
	for c in jq curl openssl socat ss; do
		if ! cmd_exists "$c"; then
			red "关键依赖 $c 安装后仍未找到，请手动检查系统环境"
			return 1
		fi
	done
	if cmd_exists systemctl; then
		systemctl enable --now cron >/dev/null 2>&1 || true
	fi
	green "依赖已就绪"
	return 0
}

ensure_qrencode() {
	if cmd_exists qrencode; then
		return 0
	fi
	yellow "检测到未安装 qrencode，正在通过 apt 自动安装..."
	if cmd_exists apt-get && apt-get update -y >/dev/null 2>&1 && apt-get install -y qrencode >/dev/null 2>&1; then
		green "qrencode 安装成功"
		return 0
	fi
	red "qrencode 自动安装失败，请手动执行: apt-get install -y qrencode"
	return 1
}

# ---------- 端口与域名校验 ----------
valid_port() {
	local p="$1"
	[[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]
}

valid_hostname() {
	local h="$1"
	[[ -n "$h" ]] && [[ "${#h}" -le 253 ]] && [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] && [[ "$h" == *.* ]] && [[ "$h" != *..* ]]
}

ask_port() {
	local prompt="$1" def="$2" varname="$3" val=""
	while true; do
		readp "$prompt（回车默认 $def）：" val
		val="${val:-$def}"
		if valid_port "$val"; then
			printf -v "$varname" '%s' "$val"
			return 0
		fi
		red "端口必须是 1-65535 的整数，请重新输入"
	done
}

# 询问带默认值的域名（用于伪装域名 SNI 等）
ask_hostname() {
	local prompt="$1" def="$2" varname="$3" val=""
	while true; do
		readp "$prompt（回车默认 $def）：" val
		val="${val:-$def}"
		if valid_hostname "$val"; then
			printf -v "$varname" '%s' "$val"
			return 0
		fi
		red "域名格式不正确，请输入合法的域名（例如 www.bing.com）"
	done
}

# 询问用户自有域名（无硬编码默认域名，必填或输入 0 取消）
ask_user_domain() {
	local prompt="$1" def="${2:-}" varname="$3" val=""
	while true; do
		if [[ -n "$def" && "$def" != "www.bing.com" ]]; then
			readp "$prompt（回车默认 $def，输入 0 取消）：" val
			val="${val:-$def}"
		else
			readp "$prompt（请输入已解析到本机的域名，输入 0 取消）：" val
		fi
		if [[ "$val" == "0" ]]; then
			return 1
		fi
		if valid_hostname "$val"; then
			printf -v "$varname" '%s' "$val"
			return 0
		fi
		red "域名格式不正确，请重新输入（例如 node.example.com，或输入 0 取消）"
	done
}

ask_number() {
	local prompt="$1" def="$2" varname="$3" val=""
	while true; do
		readp "$prompt（回车默认 $def）：" val
		val="${val:-$def}"
		if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -ge 1 ]]; then
			printf -v "$varname" '%s' "$val"
			return 0
		fi
		red "请输入大于等于 1 的正整数"
	done
}

# 排除 sing-box 自身进程后检测端口是否被其他服务占用
port_tcp_in_use_by_other() { ss -tlnp 2>/dev/null | grep -v '"sing-box"' | grep -qE ":${1}[[:space:]]"; }
port_udp_in_use_by_other() { ss -ulnp 2>/dev/null | grep -v '"sing-box"' | grep -qE ":${1}[[:space:]]"; }

check_port_free_or_warn() {
	local p="$1" proto="$2"
	if [[ "$proto" == "tcp" ]]; then
		if port_tcp_in_use_by_other "$p"; then
			yellow "注意：TCP 端口 $p 已被其他进程占用："
			ss -tlnp 2>/dev/null | grep -v '"sing-box"' | grep -E ":${p}[[:space:]]" || true
			return 1
		fi
	else
		if port_udp_in_use_by_other "$p"; then
			yellow "注意：UDP 端口 $p 已被其他进程占用："
			ss -ulnp 2>/dev/null | grep -v '"sing-box"' | grep -E ":${p}[[:space:]]" || true
			return 1
		fi
	fi
	return 0
}

# ---------- 配置与密钥持久化读写 ----------
fix_sb_perms() {
	if cmd_exists systemd-sysusers; then
		systemd-sysusers >/dev/null 2>&1 || true
	fi
	mkdir -p "$SB_DIR"
	chmod 755 "$SB_DIR" 2>/dev/null || true
	[[ -f "$SB_CONFIG" ]] && chmod 640 "$SB_CONFIG" 2>/dev/null || true
	[[ -f "$SB_DIR/fullchain.pem" ]] && chmod 644 "$SB_DIR/fullchain.pem" 2>/dev/null || true
	[[ -f "$SB_DIR/privkey.pem" ]] && chmod 600 "$SB_DIR/privkey.pem" 2>/dev/null || true
	if id -u sing-box >/dev/null 2>&1; then
		chown -R sing-box:sing-box "$SB_DIR" 2>/dev/null || chown -R sing-box "$SB_DIR" 2>/dev/null || true
	else
		[[ -f "$SB_CONFIG" ]] && chmod 644 "$SB_CONFIG" 2>/dev/null || true
	fi
}

config_exists() { [[ -f "$SB_CONFIG" ]]; }

backup_config() {
	if [[ -f "$SB_CONFIG" ]]; then
		local bak
		bak="/root/sing-box-config-$(date +%Y%m%d-%H%M%S).json"
		cp "$SB_CONFIG" "$bak" || return 1
		echo "$bak"
		return 0
	fi
	return 1
}

cfg_get() {
	local q="$1"
	if [[ -f "$SB_CONFIG" ]] && cmd_exists jq; then
		jq -r "$q // empty" "$SB_CONFIG" 2>/dev/null || true
	fi
}

keyfile_get() {
	local k="$1" old_k="${2:-}" val=""
	if [[ -f "$KEYS_FILE" ]]; then
		val="$(awk -F= -v key="$k" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$KEYS_FILE" 2>/dev/null || true)"
		if [[ -z "$val" && -n "$old_k" ]]; then
			val="$(awk -F= -v key="$old_k" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$KEYS_FILE" 2>/dev/null || true)"
		fi
	fi
	printf '%s' "$val"
}

cfg_vless_enabled() { [[ -n "$(cfg_get '.inbounds[] | select(.type=="vless") | .tag')" ]]; }
cfg_hy2_enabled() { [[ -n "$(cfg_get '.inbounds[] | select(.type=="hysteria2") | .tag')" ]]; }

cfg_vless_port() {
	local v
	v="$(cfg_get '.inbounds[] | select(.type=="vless") | .listen_port')"
	[[ -z "$v" ]] && v="$(keyfile_get "VLESS_PORT" "VLESS port")"
	echo "${v:-443}"
}

cfg_hy2_port() {
	local v
	v="$(cfg_get '.inbounds[] | select(.type=="hysteria2") | .listen_port')"
	[[ -z "$v" ]] && v="$(keyfile_get "HY2_PORT" "HY2 port")"
	echo "${v:-8443}"
}

cfg_hy2_domain() {
	local v
	v="$(cfg_get '.inbounds[] | select(.type=="hysteria2") | .tls.server_name')"
	[[ -z "$v" ]] && v="$(keyfile_get "HY2_DOMAIN" "HY2 domain")"
	echo "${v:-www.bing.com}"
}

cfg_reality_sni() {
	local v
	v="$(cfg_get '.inbounds[] | select(.type=="vless") | .tls.server_name')"
	[[ -z "$v" ]] && v="$(keyfile_get "VLESS_SNI" "VLESS SNI")"
	echo "${v:-www.icloud.com}"
}

read_current_values() {
	CUR_UUID="$(cfg_get '.inbounds[] | select(.type=="vless") | .users[0].uuid')"
	[[ -z "$CUR_UUID" ]] && CUR_UUID="$(keyfile_get "VLESS_UUID" "VLESS UUID")"

	CUR_PRIV="$(cfg_get '.inbounds[] | select(.type=="vless") | .tls.reality.private_key')"
	[[ -z "$CUR_PRIV" ]] && CUR_PRIV="$(keyfile_get "VLESS_PRIV" "VLESS PrivateKey")"

	CUR_PUB="$(keyfile_get "VLESS_PUB" "VLESS PublicKey")"

	CUR_SHORT="$(cfg_get '.inbounds[] | select(.type=="vless") | .tls.reality.short_id[0]')"
	[[ -z "$CUR_SHORT" ]] && CUR_SHORT="$(keyfile_get "VLESS_SHORT" "VLESS short_id")"

	CUR_VLESS_PORT="$(cfg_vless_port)"
	CUR_SNI="$(cfg_reality_sni)"

	CUR_HY2_PASS="$(cfg_get '.inbounds[] | select(.type=="hysteria2") | .users[0].password')"
	[[ -z "$CUR_HY2_PASS" ]] && CUR_HY2_PASS="$(keyfile_get "HY2_PASS" "HY2 password")"

	CUR_OBFS="$(cfg_get '.inbounds[] | select(.type=="hysteria2") | .obfs.password')"
	[[ -z "$CUR_OBFS" ]] && CUR_OBFS="$(keyfile_get "HY2_OBFS" "HY2 obfs password")"

	CUR_HY2_PORT="$(cfg_hy2_port)"
	CUR_HY2_DOMAIN="$(cfg_hy2_domain)"

	CUR_UP="$(cfg_get '.inbounds[] | select(.type=="hysteria2") | .up_mbps')"
	[[ -z "$CUR_UP" ]] && CUR_UP="$(keyfile_get "HY2_UP")"
	CUR_UP="${CUR_UP:-100}"

	CUR_DOWN="$(cfg_get '.inbounds[] | select(.type=="hysteria2") | .down_mbps')"
	[[ -z "$CUR_DOWN" ]] && CUR_DOWN="$(keyfile_get "HY2_DOWN")"
	CUR_DOWN="${CUR_DOWN:-100}"
}

save_keys_file() {
	local new_pub="${1:-}" ip=""
	read_current_values
	[[ -n "$new_pub" ]] && CUR_PUB="$new_pub"
	ip="$(get_ip)"
	local cert_mode="self_signed"
	if is_real_cert; then
		cert_mode="acme_ca"
	fi
	{
		echo "# sbs 密钥与配置记录（更新时间：$(date '+%Y-%m-%d %H:%M:%S')）"
		echo "VLESS_UUID=${CUR_UUID}"
		echo "VLESS_PRIV=${CUR_PRIV}"
		echo "VLESS_PUB=${CUR_PUB}"
		echo "VLESS_SHORT=${CUR_SHORT}"
		echo "VLESS_SNI=${CUR_SNI}"
		echo "VLESS_PORT=${CUR_VLESS_PORT}"
		echo "HY2_PASS=${CUR_HY2_PASS}"
		echo "HY2_OBFS=${CUR_OBFS}"
		echo "HY2_DOMAIN=${CUR_HY2_DOMAIN}"
		echo "HY2_CERT_MODE=${cert_mode}"
		echo "HY2_PORT=${CUR_HY2_PORT}"
		echo "HY2_UP=${CUR_UP}"
		echo "HY2_DOWN=${CUR_DOWN}"
		echo "VPS_IP=${ip}"
	} >"$KEYS_FILE"
	chmod 600 "$KEYS_FILE" || true
}

write_config() {
	local vless_on="$1" vless_port="$2" uuid="$3" priv="$4" short_id="$5" sni="$6"
	local hy2_on="$7" hy2_port="$8" hy2_pass="$9" obfs_pass="${10}" hy2_domain="${11}" up_mbps="${12}" down_mbps="${13}"
	local tmp="/tmp/sing-box-config.$$.json" bak=""

	if [[ "$vless_on" -eq 0 && "$hy2_on" -eq 0 ]]; then
		red "不能同时停用/删除所有协议（至少需保留一个启用协议），已取消写入"
		return 1
	fi

	if [[ -f "$SB_CONFIG" ]]; then
		bak="$(backup_config)" || {
			red "备份旧配置失败，已停止写入"
			return 1
		}
		yellow "旧配置已备份到 $bak"
	fi

	if ! jq -n \
		--argjson vless_on "$vless_on" \
		--argjson vless_port "$vless_port" \
		--arg uuid "$uuid" \
		--arg priv "$priv" \
		--arg short_id "$short_id" \
		--arg sni "$sni" \
		--argjson hy2_on "$hy2_on" \
		--argjson hy2_port "$hy2_port" \
		--arg hy2_pass "$hy2_pass" \
		--arg obfs_pass "$obfs_pass" \
		--arg hy2_domain "$hy2_domain" \
		--argjson up_mbps "$up_mbps" \
		--argjson down_mbps "$down_mbps" \
		'{
  log: {level: "info", timestamp: true},
  inbounds: (
    []
    + (if $vless_on == 1 then [{
        type: "vless",
        tag: "vless-in",
        listen: "::",
        listen_port: $vless_port,
        users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
        tls: {
          enabled: true,
          server_name: $sni,
          reality: {
            enabled: true,
            handshake: {server: $sni, server_port: 443},
            private_key: $priv,
            short_id: [$short_id]
          }
        }
      }] else [] end)
    + (if $hy2_on == 1 then [{
        type: "hysteria2",
        tag: "hy2-in",
        listen: "::",
        listen_port: $hy2_port,
        up_mbps: $up_mbps,
        down_mbps: $down_mbps,
        obfs: {type: "salamander", password: $obfs_pass},
        users: [{password: $hy2_pass}],
        ignore_client_bandwidth: false,
        tls: {
          enabled: true,
          server_name: $hy2_domain,
          alpn: ["h3"],
          certificate_path: "/etc/sing-box/fullchain.pem",
          key_path: "/etc/sing-box/privkey.pem"
        },
        masquerade: "https://www.bing.com"
      }] else [] end)
  ),
  outbounds: [{type: "direct", tag: "direct"}],
  route: {final: "direct"}
}' >"$tmp"; then
		red "生成 JSON 配置失败"
		rm -f "$tmp"
		return 1
	fi

	mkdir -p "$SB_DIR"
	if ! cmd_exists sing-box; then
		red "找不到 sing-box，无法校验配置"
		rm -f "$tmp"
		return 1
	fi
	if ! sing-box check -c "$tmp" >/dev/null 2>&1; then
		red "配置校验未通过，未替换正式配置，错误详情如下："
		sing-box check -c "$tmp" || true
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$SB_CONFIG"
	fix_sb_perms
	setup_traffic_rules >/dev/null 2>&1 || true
	green "配置已写入 $SB_CONFIG 并通过校验"
	return 0
}

# ---------- 证书管理（支持免域名自签与 ACME 真实证书双模式） ----------
is_real_cert() {
	if [[ ! -f "$SB_DIR/fullchain.pem" ]]; then
		return 1
	fi
	local subj issuer
	subj="$(openssl x509 -in "$SB_DIR/fullchain.pem" -noout -subject 2>/dev/null | sed 's/^subject=//' || true)"
	issuer="$(openssl x509 -in "$SB_DIR/fullchain.pem" -noout -issuer 2>/dev/null | sed 's/^issuer=//' || true)"
	[[ -n "$subj" && -n "$issuer" && "$subj" != "$issuer" ]]
}

# 生成免域名自签证书（参考 sing-box-yg：使用 EC prime256v1 或 RSA 自签，10年有效期）
make_self_signed() {
	local cn="${1:-www.bing.com}"
	mkdir -p "$SB_DIR"
	openssl ecparam -genkey -name prime256v1 -out "$SB_DIR/privkey.pem" 2>/dev/null || \
		openssl genrsa -out "$SB_DIR/privkey.pem" 2048 2>/dev/null || return 1
	openssl req -new -x509 -days 3650 -key "$SB_DIR/privkey.pem" -out "$SB_DIR/fullchain.pem" \
		-subj "/CN=$cn" -addext "subjectAltName=DNS:$cn" 2>/dev/null || \
		openssl req -new -x509 -days 3650 -key "$SB_DIR/privkey.pem" -out "$SB_DIR/fullchain.pem" \
		-subj "/CN=$cn" || return 1
	fix_sb_perms
	green "免域名自签证书已生成（伪装域名 CN=$cn，有效期 10 年）"
	return 0
}

acme_installed() { [[ -x "$ACME_SH" ]]; }

install_acme() {
	if ! cmd_exists cron && ! cmd_exists crontab; then
		yellow "未找到 cron，正在安装 cron（用于 acme.sh 自动续期）"
		apt-get install -y cron || {
			red "安装 cron 失败"
			return 1
		}
		systemctl enable --now cron >/dev/null 2>&1 || true
	fi
	if acme_installed; then
		return 0
	fi
	curl -fsSL https://get.acme.sh | sh || {
		red "acme.sh 安装失败"
		return 1
	}
	if ! acme_installed; then
		red "acme.sh 安装后未找到 $ACME_SH"
		return 1
	fi
	green "acme.sh 已安装"
	return 0
}

cert_dir_for_domain() {
	local d="$1"
	if [[ -d "${ACME_HOME}/${d}_ecc" ]]; then
		echo "${ACME_HOME}/${d}_ecc"
		return 0
	fi
	if [[ -d "${ACME_HOME}/${d}" ]]; then
		echo "${ACME_HOME}/${d}"
		return 0
	fi
	echo ""
}

cert_exists_for_domain() { [[ -n "$(cert_dir_for_domain "$1")" ]]; }

# 扫描并返回本机 ~/.acme.sh 下所有已签发且包含 fullchain.cer 的域名列表
list_local_acme_domains() {
	local d_path d_name
	[[ -d "$ACME_HOME" ]] || return 0
	for d_path in "${ACME_HOME}"/*; do
		[[ -d "$d_path" ]] || continue
		d_name="$(basename "$d_path")"
		[[ "$d_name" == .* || "$d_name" == "ca" || "$d_name" == "deploy" || "$d_name" == "dnsapi" || "$d_name" == "notify" ]] && continue
		if [[ -f "$d_path/fullchain.cer" || -f "$d_path/${d_name%_ecc}.cer" ]]; then
			echo "${d_name%_ecc}"
		fi
	done | awk '!seen[$0]++'
}

issue_cert() {
	local domain="$1"
	if ! install_acme; then return 1; fi

	local myip resolved=""
	myip="$(get_ip)"
	resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -n 1)"
	if [[ -z "$resolved" ]]; then
		resolved="$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -n 1)"
	fi
	if [[ -n "$resolved" && -n "$myip" && "$resolved" != "$myip" ]]; then
		yellow "警告：域名 $domain 当前解析到 $resolved，而本机 IP 为 $myip。"
		yellow "若开启了 Cloudflare 橙云代理，standalone 验证会失败，请先切换为灰云（仅 DNS）。"
		readp "是否仍要继续申请？（y 继续，其他取消）：" _ans
		if [[ "${_ans:-n}" != "y" && "${_ans:-n}" != "Y" ]]; then
			yellow "已取消申请证书"
			return 1
		fi
	elif [[ -z "$resolved" ]]; then
		yellow "警告：当前查询不到 $domain 的 DNS 解析记录，申请可能失败。"
	fi

	if cert_exists_for_domain "$domain"; then
		yellow "检测到 $domain 已有本地 acme 证书：$(cert_dir_for_domain "$domain")"
		echo "1）直接导入使用现有证书到 sing-box（推荐）"
		echo "2）强制续期现有证书"
		echo "3）重新签发（覆盖）"
		echo "0）取消"
		readp "请选择 [0-3]（回车默认 1）：" _c
		case "${_c:-1}" in
		1)
			install_cert_to_singbox "$domain"
			return $?
			;;
		2)
			if ss -tlnp 2>/dev/null | grep -qE ':80[[:space:]]'; then
				red "80 端口被占用，standalone 续期需要释放 80 端口"
				ss -tlnp 2>/dev/null | grep -E ':80[[:space:]]' || true
				return 1
			fi
			"$ACME_SH" --renew -d "$domain" --ecc --force || "$ACME_SH" --renew -d "$domain" --force || {
				red "续期失败"
				return 1
			}
			install_cert_to_singbox "$domain"
			return $?
			;;
		3) ;;
		*)
			yellow "已取消"
			return 1
			;;
		esac
	fi

	if ss -tlnp 2>/dev/null | grep -qE ':80[[:space:]]'; then
		red "80 端口已被占用，standalone 申请证书需要空出 TCP 80 端口："
		ss -tlnp 2>/dev/null | grep -E ':80[[:space:]]' || true
		red "请先暂停占用 80 端口的服务（如 Nginx / Caddy / Apache）后再试"
		return 1
	fi

	"$ACME_SH" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
	if ! "$ACME_SH" --issue -d "$domain" --standalone -k ec-256; then
		red "证书申请失败。请检查域名解析是否生效、Cloudflare 是否已关橙云、VPS 防火墙是否放行 80 端口。"
		return 1
	fi
	install_cert_to_singbox "$domain"
}

install_cert_to_singbox() {
	local domain="$1"
	mkdir -p "$SB_DIR"
	if [[ -d "${ACME_HOME}/${domain}_ecc" ]]; then
		"$ACME_SH" --install-cert -d "$domain" --ecc \
			--key-file "$SB_DIR/privkey.pem" --fullchain-file "$SB_DIR/fullchain.pem" \
			--reloadcmd "systemctl restart sing-box || true" || {
			red "安装 ECC 证书到 sing-box 失败"
			return 1
		}
	else
		"$ACME_SH" --install-cert -d "$domain" \
			--key-file "$SB_DIR/privkey.pem" --fullchain-file "$SB_DIR/fullchain.pem" \
			--reloadcmd "systemctl restart sing-box || true" || {
			red "安装证书到 sing-box 失败"
			return 1
		}
	fi
	fix_sb_perms
	green "ACME 真实证书已安装到 $SB_DIR/fullchain.pem 与 $SB_DIR/privkey.pem"
	return 0
}

# 交互式选择 Hysteria2 证书模式（免域名自签 vs 域名 ACME 证书）并完成证书部署
setup_hy2_cert_interactive() {
	local out_var="$1" chosen_domain="www.bing.com" mode_choice=""
	while true; do
		echo ""
		echo "=== 选择 Hysteria2 证书与连接模式（参考 sing-box-yg 双模式） ==="
		echo "1）免域名自签证书模式（默认推荐：无需购买域名，直接用 VPS IP 连接）"
		echo "2）自有域名 ACME 证书模式（需已将你的域名解析到本机 IP，支持直接复用本机已有证书）"
		readp "请选择模式 [1-2]（直接回车默认选 1 免域名模式）：" mode_choice
		mode_choice="${mode_choice:-1}"

		if [[ "$mode_choice" == "1" ]]; then
			ask_hostname "Hysteria2 自签伪装域名 (SNI)" "www.bing.com" chosen_domain
			if make_self_signed "$chosen_domain"; then
				printf -v "$out_var" '%s' "$chosen_domain"
				return 0
			else
				red "生成自签证书失败"
				return 1
			fi
		elif [[ "$mode_choice" == "2" ]]; then
			# 若本机已有 acme 证书，先提示可直接选择导入
			local existing_domains=() d_item
			while IFS= read -r d_item; do
				[[ -n "$d_item" ]] && existing_domains+=("$d_item")
			done < <(list_local_acme_domains)

			if [[ "${#existing_domains[@]}" -gt 0 ]]; then
				echo ""
				green "检测到本机 acme.sh 已存有以下域名证书："
				local i=1
				for d_item in "${existing_domains[@]}"; do
					echo "  ${i}）直接导入并使用：${d_item}"
					((i++))
				done
				echo "  n）输入其他新域名申请证书"
				local pick=""
				readp "请输入序号直接导入，或输入 n 填写新域名（回车默认 1）：" pick
				pick="${pick:-1}"
				if [[ "$pick" =~ ^[0-9]+$ && "$pick" -ge 1 && "$pick" -le "${#existing_domains[@]}" ]]; then
					chosen_domain="${existing_domains[$((pick - 1))]}"
					if install_cert_to_singbox "$chosen_domain"; then
						printf -v "$out_var" '%s' "$chosen_domain"
						return 0
					fi
				fi
			fi

			if ! ask_user_domain "请输入你的 Hysteria2 域名" "" chosen_domain; then
				yellow "已取消输入域名，返回重新选择证书模式"
				continue
			fi
			if issue_cert "$chosen_domain"; then
				printf -v "$out_var" '%s' "$chosen_domain"
				return 0
			else
				yellow "域名 $chosen_domain 真实证书申请未成功。"
				echo "1）重新输入域名或重试申请真实证书"
				echo "2）改用免域名自签证书模式继续安装（推荐兜底，无需域名）"
				echo "0）取消并退出本次安装"
				local fallback_c=""
				readp "请选择 [0-2]（回车默认 2）：" fallback_c
				case "${fallback_c:-2}" in
				1) continue ;;
				2)
					chosen_domain="www.bing.com"
					make_self_signed "$chosen_domain" || return 1
					printf -v "$out_var" '%s' "$chosen_domain"
					return 0
					;;
				*)
					return 1
					;;
				esac
			fi
		else
			red "输入有误，请输入 1 或 2"
		fi
	done
}

# 查看当前证书详情与 acme.sh 证书列表，并支持发现本机证书时直接导入和应用
show_cert() {
	echo "=== 当前 sing-box 使用中的证书信息 ==="
	if [[ -f "$SB_DIR/fullchain.pem" ]]; then
		if is_real_cert; then
			green "证书类型：CA 真实证书（ACME 签发）"
		else
			yellow "证书类型：免域名自签证书（证书指纹校验 pinSHA256；Xray 客户端用 insecure=0 + pinSHA256，官方 Hysteria2 客户端需 insecure=1 + pinSHA256）"
		fi
		openssl x509 -in "$SB_DIR/fullchain.pem" -noout -subject -issuer -dates 2>/dev/null || red "读取证书文件失败"
	else
		yellow "未找到证书文件：$SB_DIR/fullchain.pem"
	fi
	echo ""
	echo "=== acme.sh 已管理域名证书列表 ==="
	if acme_installed; then
		"$ACME_SH" --list 2>/dev/null || true
	else
		yellow "尚未安装 acme.sh（当前使用免域名自签模式无需安装 acme.sh）"
	fi
	echo ""
	echo "=== 自动续期定时任务 (Cron) ==="
	crontab -l 2>/dev/null | grep -i acme || echo "未找到 acme 自动续期任务"

	# 扫描本机可导入的 ACME 域名证书与 /root/cert 自定义证书
	local existing_domains=() d_item
	while IFS= read -r d_item; do
		[[ -n "$d_item" ]] && existing_domains+=("$d_item")
	done < <(list_local_acme_domains)

	echo ""
	echo "----------------------------------------------"
	if [[ "${#existing_domains[@]}" -gt 0 ]]; then
		green "检测到本机 acme.sh 中存在以下可直接导入使用的域名证书："
		local idx=1
		for d_item in "${existing_domains[@]}"; do
			local cur_tag=""
			if [[ -f "$SB_CONFIG" ]] && is_real_cert && [[ "$(cfg_hy2_domain)" == "$d_item" ]]; then
				cur_tag=" [当前正在使用]"
			fi
			echo "  ${idx}）导入并启用域名证书：${d_item}${cur_tag}"
			((idx++))
		done
		echo "  c）手动指定本机其他路径下的证书文件导入（如 /root/cert/）"
		echo "  0）不导入，返回上级菜单"
		local imp_choice=""
		readp "请选择要导入并应用的证书序号 [0-${#existing_domains[@]}/c]（直接回车返回）：" imp_choice
		if [[ -z "${imp_choice:-}" || "$imp_choice" == "0" ]]; then
			return 0
		elif [[ "$imp_choice" == "c" || "$imp_choice" == "C" ]]; then
			import_custom_cert_file
			return $?
		elif [[ "$imp_choice" =~ ^[0-9]+$ && "$imp_choice" -ge 1 && "$imp_choice" -le "${#existing_domains[@]}" ]]; then
			local target_d="${existing_domains[$((imp_choice - 1))]}"
			if install_cert_to_singbox "$target_d"; then
				read_current_values
				if [[ -f "$SB_CONFIG" ]]; then
					rewrite_with_current "$(current_on_off vless)" "$(current_on_off hy2)" "$CUR_VLESS_PORT" "$CUR_HY2_PORT" "$target_d" "$CUR_SNI" "$CUR_UP" "$CUR_DOWN" || true
					green "已成功导入并启用本机证书 ($target_d)，Hysteria2 节点配置已同步更新！"
					show_nodes || true
				else
					CUR_HY2_DOMAIN="$target_d"
					save_keys_file "$CUR_PUB"
					green "证书 ($target_d) 已导入到 $SB_DIR，后续安装时将自动生效！"
				fi
			fi
		else
			red "输入序号无效"
		fi
	else
		echo "提示：若本机其他目录（如 /root/cert/）已有现成的证书文件，可输入 c 手动导入。"
		local imp_c=""
		readp "是否手动指定本机证书文件路径导入？（输入 c 导入，直接回车返回）：" imp_c
		if [[ "${imp_c:-}" == "c" || "${imp_c:-}" == "C" ]]; then
			import_custom_cert_file
		fi
	fi
	return 0
}

# 导入本机自定义路径下的证书文件（如 /root/cert/ 下的公钥与私钥）并应用到 Hysteria2
import_custom_cert_file() {
	echo ""
	echo "=== 导入本机自定义证书文件 ==="
	local cert_file="" key_file="" custom_domain=""
	readp "请输入证书公钥完整路径（如 /root/cert/fullchain.pem 或 .crt，输入 0 取消）：" cert_file
	[[ -z "$cert_file" || "$cert_file" == "0" ]] && { yellow "已取消"; return 0; }
	if [[ ! -f "$cert_file" ]]; then
		red "找不到证书文件：$cert_file"
		return 1
	fi
	if ! openssl x509 -in "$cert_file" -noout >/dev/null 2>&1; then
		red "该文件不是有效的 X509 PEM 格式证书：$cert_file"
		return 1
	fi

	readp "请输入证书私钥完整路径（如 /root/cert/privkey.pem 或 .key，输入 0 取消）：" key_file
	[[ -z "$key_file" || "$key_file" == "0" ]] && { yellow "已取消"; return 0; }
	if [[ ! -f "$key_file" ]]; then
		red "找不到私钥文件：$key_file"
		return 1
	fi

	# 尝试从证书 CN 自动提取默认域名
	local detected_cn=""
	detected_cn="$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,\/]*\).*/\1/p' | head -n 1 || true)"
	if [[ "$detected_cn" == \*.* ]]; then
		detected_cn=""
	fi
	if ! ask_user_domain "请输入该证书对应的 Hysteria2 节点域名" "$detected_cn" custom_domain; then
		yellow "已取消"
		return 0
	fi

	mkdir -p "$SB_DIR"
	cp -f "$cert_file" "$SB_DIR/fullchain.pem" || { red "复制证书文件失败"; return 1; }
	cp -f "$key_file" "$SB_DIR/privkey.pem" || { red "复制私钥文件失败"; return 1; }
	fix_sb_perms
	green "本机证书已成功导入至 $SB_DIR/fullchain.pem 与 $SB_DIR/privkey.pem"

	read_current_values
	if [[ -f "$SB_CONFIG" ]]; then
		rewrite_with_current "$(current_on_off vless)" "$(current_on_off hy2)" "$CUR_VLESS_PORT" "$CUR_HY2_PORT" "$custom_domain" "$CUR_SNI" "$CUR_UP" "$CUR_DOWN" || true
		green "Hysteria2 节点已更新并启用域名 $custom_domain ！"
		show_nodes || true
	fi
	return 0
}

# 删除指定的 ACME 证书并妥善处理当前运行中的 sing-box 证书
delete_acme_cert() {
	if ! acme_installed; then
		yellow "尚未安装 acme.sh，没有任何已申请的 ACME 域名证书可删除。"
		return 0
	fi
	echo ""
	echo "=== 当前 acme.sh 管理的证书列表 ==="
	"$ACME_SH" --list 2>/dev/null || true
	echo ""

	local cert_domains=()
	local d_path d_name
	for d_path in "${ACME_HOME}"/*; do
		[[ -d "$d_path" ]] || continue
		d_name="$(basename "$d_path")"
		[[ "$d_name" == .* || "$d_name" == "ca" || "$d_name" == "deploy" || "$d_name" == "dnsapi" || "$d_name" == "notify" ]] && continue
		d_name="${d_name%_ecc}"
		if [[ "$d_name" == *.* ]]; then
			cert_domains+=("$d_name")
		fi
	done

	if [[ "${#cert_domains[@]}" -eq 0 ]]; then
		yellow "未检测到任何已签发的 ACME 域名证书目录。"
		return 0
	fi

	echo "检测到的已申请域名："
	local idx=1
	for d_name in "${cert_domains[@]}"; do
		echo "  ${idx}）${d_name}"
		((idx++))
	done
	echo "  0）取消返回"

	local sel="" target_domain=""
	readp "请输入要删除的序号或完整域名（输入 0 取消）：" sel
	if [[ -z "${sel:-}" || "$sel" == "0" ]]; then
		yellow "已取消删除"
		return 0
	fi
	if [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 1 ]] && [[ "$sel" -le "${#cert_domains[@]}" ]]; then
		target_domain="${cert_domains[$((sel - 1))]}"
	else
		target_domain="$sel"
	fi

	readp "确认彻底删除域名 $target_domain 的 ACME 证书记录与本地文件吗？（输入 y 确认）：" _confirm
	if [[ "${_confirm:-n}" != "y" && "${_confirm:-n}" != "Y" ]]; then
		yellow "已取消删除"
		return 0
	fi

	"$ACME_SH" --remove -d "$target_domain" --ecc >/dev/null 2>&1 || true
	"$ACME_SH" --remove -d "$target_domain" >/dev/null 2>&1 || true
	rm -rf "${ACME_HOME:?}/${target_domain}_ecc" "${ACME_HOME:?}/${target_domain}" 2>/dev/null || true
	green "已从 acme.sh 中彻底删除 $target_domain 的证书文件与续期任务。"

	read_current_values
	if [[ "$CUR_HY2_DOMAIN" == "$target_domain" ]] || { [[ -f "$SB_DIR/fullchain.pem" ]] && openssl x509 -in "$SB_DIR/fullchain.pem" -noout -subject 2>/dev/null | grep -qi "$target_domain"; }; then
		echo ""
		yellow "注意：你删除的证书正是当前 Hysteria2 使用中的证书 ($target_domain)。"
		echo "请选择接下来的处理方式（防止 sing-box 缺少证书报错）："
		echo "1）立即切换为免域名自签证书模式（www.bing.com，推荐默认）"
		echo "2）立即输入其他新域名申请并安装 ACME 证书"
		local next_act=""
		readp "请选择 [1-2]（回车默认 1）：" next_act
		if [[ "${next_act:-1}" == "2" ]]; then
			local new_d=""
			if ask_user_domain "请输入新的 Hysteria2 域名" "" new_d && issue_cert "$new_d"; then
				if [[ -f "$SB_CONFIG" ]]; then
					rewrite_with_current "$(current_on_off vless)" "$(current_on_off hy2)" "$CUR_VLESS_PORT" "$CUR_HY2_PORT" "$new_d" "$CUR_SNI" "$CUR_UP" "$CUR_DOWN" || true
				fi
				return 0
			fi
			yellow "新域名证书未就绪，自动回退为免域名自签证书以保障服务正常运行..."
		fi
		make_self_signed "www.bing.com" || true
		if [[ -f "$SB_CONFIG" ]]; then
			rewrite_with_current "$(current_on_off vless)" "$(current_on_off hy2)" "$CUR_VLESS_PORT" "$CUR_HY2_PORT" "www.bing.com" "$CUR_SNI" "$CUR_UP" "$CUR_DOWN" || true
		fi
	fi
	return 0
}

# ---------- 各协议实时流量统计模块（非侵入式 iptables 计数 + ss 活跃连接统计） ----------
setup_traffic_rules() {
	if ! cmd_exists iptables || [[ ! -f "$SB_CONFIG" ]]; then
		return 0
	fi
	read_current_values
	local ipt
	for ipt in iptables ip6tables; do
		cmd_exists "$ipt" || continue
		"$ipt" -N SBS_IN 2>/dev/null || "$ipt" -F SBS_IN 2>/dev/null || continue
		"$ipt" -N SBS_OUT 2>/dev/null || "$ipt" -F SBS_OUT 2>/dev/null || continue

		"$ipt" -C INPUT -j SBS_IN 2>/dev/null || "$ipt" -I INPUT 1 -j SBS_IN 2>/dev/null || true
		"$ipt" -C OUTPUT -j SBS_OUT 2>/dev/null || "$ipt" -I OUTPUT 1 -j SBS_OUT 2>/dev/null || true

		if cfg_vless_enabled; then
			"$ipt" -A SBS_IN -p tcp --dport "$CUR_VLESS_PORT" 2>/dev/null || true
			"$ipt" -A SBS_OUT -p tcp --sport "$CUR_VLESS_PORT" 2>/dev/null || true
		fi
		if cfg_hy2_enabled; then
			"$ipt" -A SBS_IN -p udp --dport "$CUR_HY2_PORT" 2>/dev/null || true
			"$ipt" -A SBS_OUT -p udp --sport "$CUR_HY2_PORT" 2>/dev/null || true
		fi
	done
}

remove_traffic_rules() {
	local ipt
	for ipt in iptables ip6tables; do
		if cmd_exists "$ipt"; then
			"$ipt" -D INPUT -j SBS_IN 2>/dev/null || true
			"$ipt" -D OUTPUT -j SBS_OUT 2>/dev/null || true
			"$ipt" -F SBS_IN 2>/dev/null || true
			"$ipt" -X SBS_IN 2>/dev/null || true
			"$ipt" -F SBS_OUT 2>/dev/null || true
			"$ipt" -X SBS_OUT 2>/dev/null || true
		fi
	done
}

reset_traffic_counters() {
	local ipt
	for ipt in iptables ip6tables; do
		if cmd_exists "$ipt"; then
			"$ipt" -Z SBS_IN 2>/dev/null || true
			"$ipt" -Z SBS_OUT 2>/dev/null || true
		fi
	done
}

get_port_bytes() {
	local proto="$1" port="$2" dir="$3" total=0 val=0 ipt chain match_flag
	if [[ "$dir" == "in" ]]; then
		chain="SBS_IN"
		match_flag="dpt:${port}"
	else
		chain="SBS_OUT"
		match_flag="spt:${port}"
	fi
	for ipt in iptables ip6tables; do
		cmd_exists "$ipt" || continue
		val="$("$ipt" -L "$chain" -n -v -x 2>/dev/null | awk -v p="$proto" -v m="$match_flag" '$0 ~ p && $0 ~ m {sum += $2} END {print sum+0}')"
		total=$((total + ${val:-0}))
	done
	echo "$total"
}

get_proto_conns() {
	local proto="$1" port="$2" cnt=0
	if [[ "$proto" == "tcp" ]]; then
		cnt="$(ss -tn state established 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {c++} END {print c+0}')"
	else
		cnt="$(ss -un 2>/dev/null | awk -v p=":${port}$" '$4 ~ p && $5 !~ /:\*$/ {c++} END {print c+0}')"
	fi
	echo "${cnt:-0}"
}

get_netdev_bytes() {
	awk 'NR>2 && $1 !~ /lo:|docker|veth|br-|tun|wg/ {rx+=$2; tx+=$10} END {printf "%.0f %.0f\n", rx+0, tx+0}' /proc/net/dev 2>/dev/null || echo "0 0"
}

human_bytes() {
	local b="${1:-0}"
	awk -v b="$b" 'BEGIN {
		if (b < 1024) printf "%d B", b;
		else if (b < 1048576) printf "%.2f KB", b/1024;
		else if (b < 1073741824) printf "%.2f MB", b/1048576;
		else if (b < 1099511627776) printf "%.2f GB", b/1073741824;
		else printf "%.2f TB", b/1099511627776;
	}'
}

traffic_monitor_menu() {
	if [[ ! -f "$SB_CONFIG" ]]; then
		red "尚未找到配置文件，请先选择 1 一键安装"
		press_any_key
		return 1
	fi
	read_current_values
	if cmd_exists iptables && ! iptables -L SBS_IN -n >/dev/null 2>&1; then
		setup_traffic_rules >/dev/null 2>&1 || true
	fi

	local v_in1 v_out1 h_in1 h_out1 n_rx1 n_tx1
	local v_in2 v_out2 h_in2 h_out2 n_rx2 n_tx2
	local v_drx v_dtx h_drx h_dtx n_drx n_dtx
	local vc hc key=""

	v_in1="$(get_port_bytes tcp "$CUR_VLESS_PORT" in)"
	v_out1="$(get_port_bytes tcp "$CUR_VLESS_PORT" out)"
	h_in1="$(get_port_bytes udp "$CUR_HY2_PORT" in)"
	h_out1="$(get_port_bytes udp "$CUR_HY2_PORT" out)"
	read -r n_rx1 n_tx1 <<<"$(get_netdev_bytes)"

	while true; do
		if read -rsn1 -t 1 key 2>/dev/null; then
			case "$key" in
			q | Q | 0) break ;;
			r | R)
				reset_traffic_counters
				v_in1=0; v_out1=0; h_in1=0; h_out1=0
				;;
			esac
		fi

		v_in2="$(get_port_bytes tcp "$CUR_VLESS_PORT" in)"
		v_out2="$(get_port_bytes tcp "$CUR_VLESS_PORT" out)"
		h_in2="$(get_port_bytes udp "$CUR_HY2_PORT" in)"
		h_out2="$(get_port_bytes udp "$CUR_HY2_PORT" out)"
		read -r n_rx2 n_tx2 <<<"$(get_netdev_bytes)"

		vc=0; hc=0
		cfg_vless_enabled && vc="$(get_proto_conns tcp "$CUR_VLESS_PORT")"
		cfg_hy2_enabled && hc="$(get_proto_conns udp "$CUR_HY2_PORT")"

		v_drx=$(( v_in2 >= v_in1 ? v_in2 - v_in1 : 0 ))
		v_dtx=$(( v_out2 >= v_out1 ? v_out2 - v_out1 : 0 ))
		h_drx=$(( h_in2 >= h_in1 ? h_in2 - h_in1 : 0 ))
		h_dtx=$(( h_out2 >= h_out1 ? h_out2 - h_out1 : 0 ))
		n_drx=$(( n_rx2 >= n_rx1 ? n_rx2 - n_rx1 : 0 ))
		n_dtx=$(( n_tx2 >= n_tx1 ? n_tx2 - n_tx1 : 0 ))

		v_in1="$v_in2"; v_out1="$v_out2"
		h_in1="$h_in2"; h_out1="$h_out2"
		n_rx1="$n_rx2"; n_tx1="$n_tx2"

		clear 2>/dev/null || true
		echo "========================================================================"
		green "          sbs - Sing-box 各协议实时流量与连接监控面板 (每秒刷新)"
		echo "========================================================================"
		printf "%-24s | %-14s | %-14s | %-10s\n" "协议 / 监听端口" "实时入站(上行)" "实时出站(下行)" "活跃连接"
		echo "------------------------------------------------------------------------"
		if cfg_vless_enabled; then
			printf "%-24s | %-14s | %-14s | %-10s\n" \
				"VLESS-Reality (TCP:$CUR_VLESS_PORT)" \
				"$(human_bytes "$v_drx")/s" \
				"$(human_bytes "$v_dtx")/s" \
				"${vc} 连接"
		else
			printf "%-24s | %-14s | %-14s | %-10s\n" "VLESS-Reality (已停用)" "-" "-" "-"
		fi

		if cfg_hy2_enabled; then
			printf "%-24s | %-14s | %-14s | %-10s\n" \
				"Hysteria2     (UDP:$CUR_HY2_PORT)" \
				"$(human_bytes "$h_drx")/s" \
				"$(human_bytes "$h_dtx")/s" \
				"${hc} 会话"
		else
			printf "%-24s | %-14s | %-14s | %-10s\n" "Hysteria2     (已停用)" "-" "-" "-"
		fi
		echo "------------------------------------------------------------------------"
		printf "%-24s | %-14s | %-14s | %-10s\n" \
			"VPS 主网卡总计" \
			"$(human_bytes "$n_drx")/s" \
			"$(human_bytes "$n_dtx")/s" \
			"$((vc + hc)) 总活跃"
		echo "========================================================================"
		echo "【各协议累计出入总流量统计】"
		echo "  • VLESS-Reality 累计：入站(上行) $(human_bytes "$v_in2") | 出站(下行) $(human_bytes "$v_out2") | 合计 $(human_bytes $((v_in2 + v_out2)))"
		echo "  • Hysteria2     累计：入站(上行) $(human_bytes "$h_in2") | 出站(下行) $(human_bytes "$h_out2") | 合计 $(human_bytes $((h_in2 + h_out2)))"
		echo "  • VPS 网卡总计  累计：总接收(RX) $(human_bytes "$n_rx2") | 总发送(TX) $(human_bytes "$n_tx2")"
		echo "========================================================================"
		yellow "操作提示：按 [q] 或 [0] 返回主菜单  |  按 [r] 清零各协议累计流量计数"
	done
	return 0
}

# ---------- sing-box 安装 ----------
singbox_installed() { cmd_exists sing-box; }

singbox_version() {
	if cmd_exists sing-box; then
		sing-box version 2>/dev/null | awk '/sing-box version/{print $3}' | head -n 1
	fi
}

install_singbox() {
	if singbox_installed; then
		yellow "检测到 sing-box 已安装，当前版本：$(singbox_version)"
		readp "是否重新安装 / 升级到最新正式版？（y 确认，其他跳过）：" _a
		if [[ "${_a:-n}" != "y" && "${_a:-n}" != "Y" ]]; then
			return 0
		fi
	fi
	echo "=== 安装 sing-box（官方脚本） ==="
	curl -fsSL https://sing-box.app/install.sh | sh || {
		red "sing-box 官方安装脚本执行失败，请检查网络"
		return 1
	}
	if ! singbox_installed; then
		red "安装后仍未找到 sing-box 可执行文件"
		return 1
	fi
	green "sing-box 已就绪，当前版本：$(singbox_version)"
	return 0
}

# ---------- 状态面板 ----------
show_status() {
	echo "=============================================="
	echo " sbs - sing-box 管理脚本 v$SCRIPT_VERSION（快捷命令: sbs）"
	echo "=============================================="
	local os_pretty kernel arch virt bbr ip ip6 sb_stat
	os_pretty="$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "未知")"
	kernel="$(uname -r)"
	arch="$(uname -m)"
	virt="$(systemd-detect-virt 2>/dev/null || echo "未知")"
	bbr="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")"
	ip="$(get_ip)"
	ip6="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /:/) print $i}' | head -n 1)"
	echo "系统：$os_pretty | 内核：$kernel | 架构：$arch | 虚拟化：$virt | 拥塞算法：$bbr"
	echo "IPv4 地址：${ip:-未知} | IPv6 地址：${ip6:-无}"

	if ! singbox_installed; then
		sb_stat="未安装"
	elif systemctl is-active --quiet "$SB_SERVICE" 2>/dev/null; then
		sb_stat="运行中"
	elif [[ -f "$SB_CONFIG" ]]; then
		sb_stat="已安装，未运行"
	else
		sb_stat="已安装，未配置"
	fi
	echo "Sing-box 状态：$sb_stat | 内核版本：$(singbox_version 2>/dev/null || echo "未安装")"
	echo ""
	echo "节点启用状态："
	if [[ -f "$SB_CONFIG" ]]; then
		if cfg_vless_enabled; then
			local v_tot=0
			if cmd_exists iptables && iptables -L SBS_IN -n >/dev/null 2>&1; then
				v_tot=$(( $(get_port_bytes tcp "$(cfg_vless_port)" in) + $(get_port_bytes tcp "$(cfg_vless_port)" out) ))
			fi
			echo " [VLESS-Reality] 已启用 | TCP 端口：$(cfg_vless_port) | SNI：$(cfg_reality_sni) | 累计流量：$(human_bytes "$v_tot")"
		else
			echo " [VLESS-Reality] 已停用"
		fi
		if cfg_hy2_enabled; then
			local h_tot=0
			if cmd_exists iptables && iptables -L SBS_IN -n >/dev/null 2>&1; then
				h_tot=$(( $(get_port_bytes udp "$(cfg_hy2_port)" in) + $(get_port_bytes udp "$(cfg_hy2_port)" out) ))
			fi
			if is_real_cert; then
				echo " [Hysteria-2]    已启用 | UDP 端口：$(cfg_hy2_port) | 模式：域名真实证书 ($(cfg_hy2_domain)) | 累计流量：$(human_bytes "$h_tot")"
			else
				echo " [Hysteria-2]    已启用 | UDP 端口：$(cfg_hy2_port) | 模式：免域名自签证书 (SNI: $(cfg_hy2_domain)) | 累计流量：$(human_bytes "$h_tot")"
			fi
		else
			echo " [Hysteria-2]    已停用"
		fi
	else
		echo " 尚未生成配置（请选择 1 一键安装）"
	fi
	echo "=============================================="
}

# ---------- 节点链接、二维码与客户端配置片段（Clash Verge / Sing-box） ----------
build_node_uris() {
	read_current_values
	local ip uri_ip
	ip="$(get_ip)"
	uri_ip="$(format_host_for_uri "$ip")"
	VLESS_URI=""
	HY2_URI=""

	if cfg_vless_enabled; then
		local vport sni
		vport="$(cfg_vless_port)"
		sni="$(cfg_reality_sni)"
		if [[ -n "$CUR_PUB" ]]; then
			VLESS_URI="vless://${CUR_UUID}@${uri_ip}:${vport}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${CUR_PUB}&sid=${CUR_SHORT}&type=tcp#sbs-VLESS"
		else
			VLESS_URI=""
		fi
	fi

	if cfg_hy2_enabled; then
		local domain hport
		domain="$(cfg_hy2_domain)"
		hport="$(cfg_hy2_port)"
		if is_real_cert; then
			HY2_URI="hysteria2://${CUR_HY2_PASS}@${domain}:${hport}?obfs=salamander&obfs-password=${CUR_OBFS}&sni=${domain}&alpn=h3&insecure=0#sbs-HY2"
		else
			pin_sha256="$(openssl x509 -in "$SB_DIR/fullchain.pem" -noout -fingerprint -sha256 2>/dev/null | awk -F= '{print tolower($2)}' | tr -d ':')"
			HY2_URI="hysteria2://${CUR_HY2_PASS}@${uri_ip}:${hport}?obfs=salamander&obfs-password=${CUR_OBFS}&sni=${domain}&alpn=h3&insecure=0&allowInsecure=0&pinSHA256=${pin_sha256}#sbs-HY2"
		fi
	fi
}

show_nodes() {
	if [[ ! -f "$SB_CONFIG" ]]; then
		red "尚未找到配置文件，请先选择 1 一键安装"
		return 1
	fi
	build_node_uris
	local ip
	ip="$(get_ip)"
	echo ""
	green "================ 节点分享链接 (URI) ================"
	echo "=== 1. VLESS-Reality ==="
	if cfg_vless_enabled; then
		echo "服务器：$ip | 端口：$CUR_VLESS_PORT (TCP) | UUID：$CUR_UUID"
		echo "SNI   ：$CUR_SNI | PublicKey：${CUR_PUB:-未记录} | short_id：$CUR_SHORT"
		echo ""
		[[ -n "$VLESS_URI" ]] && blue "$VLESS_URI"
		if [[ -z "$CUR_PUB" ]]; then
			yellow "提示：未在 $KEYS_FILE 中读取到 PublicKey，请进入菜单 3 -> 5 重新生成 VLESS 密钥对。"
		fi
	else
		yellow "当前未启用 VLESS-Reality"
	fi

	echo ""
	echo "=== 2. Hysteria2 ==="
	if cfg_hy2_enabled; then
		local hy2_host="$CUR_HY2_DOMAIN" mode_desc="ACME 域名真实证书"
		if ! is_real_cert; then
			hy2_host="$ip"
			mode_desc="免域名自签证书 (证书指纹校验 pinSHA256)"
		fi
		echo "模式  ：$mode_desc"
		echo "服务器：$hy2_host | 端口：$CUR_HY2_PORT (UDP) | SNI：$CUR_HY2_DOMAIN | 带宽：${CUR_UP}/${CUR_DOWN} Mbps"
		echo "密码  ：$CUR_HY2_PASS | 混淆 (salamander)：$CUR_OBFS"
		echo ""
		blue "$HY2_URI"
		if ! is_real_cert; then
			yellow "提示：上方链接为 Xray 内核客户端 (v2rayN / NekoBox) 专用 (insecure=0 + pinSHA256)；官方 Hysteria2 客户端请把 insecure 改为 1 再导入，或在客户端配置里设 insecure: true + pinSHA256。"
		fi
	else
		yellow "当前未启用 Hysteria2"
	fi
	echo "===================================================="
	echo "密钥记录文件：$KEYS_FILE"
	return 0
}

show_qrcodes() {
	if [[ ! -f "$SB_CONFIG" ]]; then
		red "尚未找到配置文件，请先选择 1 一键安装"
		return 1
	fi
	if ! ensure_qrencode; then
		return 1
	fi
	build_node_uris
	echo ""
	if [[ -n "$VLESS_URI" ]]; then
		green "=== VLESS-Reality 节点二维码（支持 v2rayNG / Shadowrocket / sing-box / NekoBox 扫码） ==="
		qrencode -t ansiutf8 "$VLESS_URI"
		echo ""
	fi
	if [[ -n "$HY2_URI" ]]; then
		green "=== Hysteria2 节点二维码（支持 v2rayNG / Shadowrocket / sing-box / NekoBox 扫码） ==="
		qrencode -t ansiutf8 "$HY2_URI"
		echo ""
	fi
	return 0
}

show_clash_snippet() {
	if [[ ! -f "$SB_CONFIG" ]]; then
		red "尚未找到配置文件，请先选择 1 一键安装"
		return 1
	fi
	read_current_values
	local ip hy2_server skip_cert="false"
	ip="$(get_ip)"
	hy2_server="$CUR_HY2_DOMAIN"
	if ! is_real_cert; then
		hy2_server="$ip"
		skip_cert="true"
	fi

	{
		echo "# Clash Verge (Mihomo) 节点配置片段 - 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
		echo "proxies:"
		if cfg_vless_enabled; then
			cat <<EOF
  - name: "sbs-VLESS-Reality"
    type: vless
    server: ${ip}
    port: ${CUR_VLESS_PORT}
    uuid: "${CUR_UUID}"
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${CUR_SNI}
    reality-opts:
      public-key: "${CUR_PUB}"
      short-id: "${CUR_SHORT}"
    client-fingerprint: chrome
EOF
		fi
		if cfg_hy2_enabled; then
			cat <<EOF
  - name: "sbs-Hysteria2"
    type: hysteria2
    server: ${hy2_server}
    port: ${CUR_HY2_PORT}
    password: "${CUR_HY2_PASS}"
    up: "${CUR_UP} Mbps"
    down: "${CUR_DOWN} Mbps"
    obfs: salamander
    obfs-password: "${CUR_OBFS}"
    sni: ${CUR_HY2_DOMAIN}
    skip-cert-verify: ${skip_cert}
    alpn:
      - h3
EOF
		fi
		echo ""
		echo "# 策略组引用示例（可按需合入你的主配置）："
		echo "proxy-groups:"
		echo "  - name: \"🚀 节点选择\""
		echo "    type: select"
		echo "    proxies:"
		cfg_vless_enabled && echo "      - \"sbs-VLESS-Reality\""
		cfg_hy2_enabled && echo "      - \"sbs-Hysteria2\""
		echo "      - DIRECT"
	} >"$CLASH_FILE"
	chmod 600 "$CLASH_FILE" || true

	echo ""
	green "================ Clash Verge (Mihomo) 配置片段 ================"
	cat "$CLASH_FILE"
	echo "==============================================================="
	yellow "该配置片段已同步保存至：$CLASH_FILE"
	return 0
}

show_sb_client_snippet() {
	if [[ ! -f "$SB_CONFIG" ]]; then
		red "尚未找到配置文件，请先选择 1 一键安装"
		return 1
	fi
	read_current_values
	local ip hy2_server insecure_bool="false"
	ip="$(get_ip)"
	hy2_server="$CUR_HY2_DOMAIN"
	if ! is_real_cert; then
		hy2_server="$ip"
		insecure_bool="true"
	fi

	local vless_on=0 hy2_on=0
	cfg_vless_enabled && vless_on=1
	cfg_hy2_enabled && hy2_on=1

	jq -n \
		--argjson vless_on "$vless_on" \
		--arg ip "$ip" \
		--argjson vport "$CUR_VLESS_PORT" \
		--arg uuid "$CUR_UUID" \
		--arg sni "$CUR_SNI" \
		--arg pub "$CUR_PUB" \
		--arg short_id "$CUR_SHORT" \
		--argjson hy2_on "$hy2_on" \
		--arg hy2_server "$hy2_server" \
		--argjson hport "$CUR_HY2_PORT" \
		--arg hy2_pass "$CUR_HY2_PASS" \
		--arg obfs_pass "$CUR_OBFS" \
		--arg hy2_domain "$CUR_HY2_DOMAIN" \
		--argjson up_mbps "$CUR_UP" \
		--argjson down_mbps "$CUR_DOWN" \
		--argjson insecure "$insecure_bool" \
		'{
  outbounds: (
    []
    + (if $vless_on == 1 then [{
        type: "vless",
        tag: "sbs-VLESS-Reality",
        server: $ip,
        server_port: $vport,
        uuid: $uuid,
        flow: "xtls-rprx-vision",
        network: "tcp",
        tls: {
          enabled: true,
          server_name: $sni,
          utls: {
            enabled: true,
            fingerprint: "chrome"
          },
          reality: {
            enabled: true,
            public_key: $pub,
            short_id: $short_id
          }
        }
      }] else [] end)
    + (if $hy2_on == 1 then [{
        type: "hysteria2",
        tag: "sbs-Hysteria2",
        server: $hy2_server,
        server_port: $hport,
        up_mbps: $up_mbps,
        down_mbps: $down_mbps,
        obfs: {
          type: "salamander",
          password: $obfs_pass
        },
        password: $hy2_pass,
        tls: {
          enabled: true,
          server_name: $hy2_domain,
          insecure: $insecure,
          alpn: ["h3"]
        }
      }] else [] end)
  )
}' >"$SB_CLIENT_FILE"
	chmod 600 "$SB_CLIENT_FILE" || true

	echo ""
	green "================ Sing-box 客户端 outbounds 配置片段 ================"
	cat "$SB_CLIENT_FILE"
	echo "===================================================================="
	yellow "该配置片段已同步保存至：$SB_CLIENT_FILE"
	return 0
}

nodes_menu() {
	if [[ ! -f "$SB_CONFIG" ]]; then
		red "尚未找到配置文件，请先选择 1 一键安装"
		press_any_key
		return 1
	fi
	show_clash_snippet >/dev/null 2>&1 || true
	show_sb_client_snippet >/dev/null 2>&1 || true
	show_nodes

	while true; do
		echo ""
		echo "=== 节点查看与客户端配置导出 ==="
		echo "1）刷新并显示节点 URI 分享链接"
		echo "2）在终端显示节点二维码（qrencode 扫码导入）"
		echo "3）生成并查看 Clash Verge (Mihomo) 节点配置片段 (YAML)"
		echo "4）生成并查看 Sing-box 客户端 outbounds 配置片段 (JSON)"
		echo "5）一屏展示全部（URI + 二维码 + Clash + Sing-box）"
		echo "0）返回主菜单"
		readp "请选择 [0-5]：" _nm
		case "${_nm:-}" in
		1) show_nodes ;;
		2) show_qrcodes ;;
		3) show_clash_snippet ;;
		4) show_sb_client_snippet ;;
		5)
			show_nodes
			show_qrcodes
			show_clash_snippet
			show_sb_client_snippet
			;;
		0 | "") return 0 ;;
		*) red "输入有误，请选择 0-5" ;;
		esac
	done
}

# ---------- 一键安装（支持无域名与有域名双路径） ----------
one_click_install() {
	need_root
	check_os
	echo "=== 一键安装 Sing-box（VLESS-Reality + Hysteria2）==="
	echo "提示：有无域名均可安装！默认支持一路回车极速部署（HY2 默认采用免域名自签模式）。"
	echo ""

	if config_exists; then
		yellow "检测到已有配置文件 $SB_CONFIG"
		readp "是否覆盖现有配置并重新生成密钥？（y 覆盖安装，其他取消）：" _ow
		if [[ "${_ow:-n}" != "y" && "${_ow:-n}" != "Y" ]]; then
			yellow "已取消安装，现有配置保持不变"
			return 0
		fi
	fi

	local vless_port hy2_port hy2_domain="www.bing.com" reality_sni up_mbps down_mbps
	while true; do
		ask_port "VLESS 监听端口 (TCP)" "443" vless_port
		if check_port_free_or_warn "$vless_port" tcp; then
			break
		fi
		red "TCP 端口 $vless_port 已被其他服务占用，请更换端口"
	done

	while true; do
		ask_port "Hysteria2 监听端口 (UDP)" "8443" hy2_port
		if ! check_port_free_or_warn "$hy2_port" udp; then
			red "UDP 端口 $hy2_port 已被其他服务占用，请更换端口"
			continue
		fi
		if [[ "$hy2_port" == "$vless_port" ]]; then
			yellow "提示：HY2 (UDP) 与 VLESS (TCP) 使用了相同端口号 $vless_port（协议不同可共存，但分开更易排查）。"
			readp "确认共用端口号 $hy2_port 吗？（y 确认，其他重填）：" _same
			if [[ "${_same:-n}" == "y" || "${_same:-n}" == "Y" ]]; then break; fi
		else
			break
		fi
	done

	ask_hostname "VLESS Reality 伪装域名 (SNI)" "www.icloud.com" reality_sni
	ask_number "Hysteria2 客户端上行带宽 (Mbps)" "100" up_mbps
	ask_number "Hysteria2 客户端下行带宽 (Mbps)" "100" down_mbps

	install_deps || return 1
	install_singbox || return 1

	# 选择 Hysteria2 免域名自签模式 或 自有域名 ACME 真实证书模式
	if ! setup_hy2_cert_interactive hy2_domain; then
		yellow "证书配置已取消，安装中止"
		return 1
	fi

	echo "=== 生成随机安全密钥 ==="
	local uuid keypair priv pub short_id hy2_pass obfs_pass
	uuid="$(sing-box generate uuid)" || { red "生成 UUID 失败"; return 1; }
	keypair="$(sing-box generate reality-keypair)" || { red "生成 Reality 密钥对失败"; return 1; }
	priv="$(echo "$keypair" | awk '/PrivateKey:/{print $2}')"
	pub="$(echo "$keypair" | awk '/PublicKey:/{print $2}')"
	short_id="$(sing-box generate rand --hex 8)" || { red "生成 short_id 失败"; return 1; }
	hy2_pass="$(sing-box generate rand --hex 16)" || { red "生成 HY2 密码失败"; return 1; }
	obfs_pass="$(sing-box generate rand --hex 16)" || { red "生成 HY2 混淆密码失败"; return 1; }

	if [[ -z "$uuid" || -z "$priv" || -z "$pub" || -z "$short_id" || -z "$hy2_pass" || -z "$obfs_pass" ]]; then
		red "密钥生成不完整，已终止安装"
		return 1
	fi

	if ! write_config 1 "$vless_port" "$uuid" "$priv" "$short_id" "$reality_sni" \
		1 "$hy2_port" "$hy2_pass" "$obfs_pass" "$hy2_domain" "$up_mbps" "$down_mbps"; then
		red "写入配置失败，已停止安装"
		return 1
	fi

	save_keys_file "$pub"
	show_clash_snippet >/dev/null 2>&1 || true
	show_sb_client_snippet >/dev/null 2>&1 || true

	systemctl enable --now "$SB_SERVICE" >/dev/null 2>&1 || true
	systemctl restart "$SB_SERVICE" || {
		red "启动 sing-box 失败，请通过菜单 8 查看日志"
		return 1
	}
	if ! systemctl is-active --quiet "$SB_SERVICE"; then
		red "sing-box 启动后未处于运行状态，请检查：journalctl -u sing-box -n 50 --no-pager"
		return 1
	fi

	install_sbs_command 0
	show_nodes
	green "一键部署全部完成！可在菜单 5 查看终端二维码、Clash Verge 或 Sing-box 客户端配置片段，在菜单 11 查看各协议实时流量。"
	return 0
}

# ---------- 彻底卸载 Sing-box 与代理业务（支持选择保留或清除 ACME 证书，并闭环退出逻辑） ----------
uninstall_singbox() {
	echo "=== 卸载 Sing-box 与清理代理业务 ==="
	echo "说明：本操作将停止并彻底清除 sing-box 服务、程序、流量统计规则及代理节点配置（/etc/sing-box）。"
	local _u=""
	readp "确定要卸载 Sing-box 代理业务吗？（输入 y 确认，其他取消）：" _u
	if [[ "${_u:-n}" != "y" && "${_u:-n}" != "Y" ]]; then
		yellow "已取消卸载"
		return 0
	fi

	# 1. 询问是否保留或清除 ACME 证书与 acme.sh
	echo ""
	echo "请选择对本机已申请的 ACME 域名证书 (~/.acme.sh) 的处理方式："
	echo "  1）保留 ACME 域名证书与自动续期（默认推荐，方便下次重装时直接导入复用）"
	echo "  2）彻底清除所有 ACME 域名证书、续期定时任务并卸载 acme.sh"
	local _acme_opt=""
	readp "请选择 [1-2]（直接回车默认 1 保留证书）：" _acme_opt
	_acme_opt="${_acme_opt:-1}"

	# 2. 询问是否清除 /root/ 下的业务密钥、导出文件与历史配置备份
	echo ""
	local _clean_root=""
	readp "是否一并清除 /root/ 下的节点密钥记录 ($KEYS_FILE)、导出配置与历史备份？（回车默认 y 清除，输入 n 保留）：" _clean_root
	_clean_root="${_clean_root:-y}"

	# 3. 询问是否移除 sbs 快捷启动命令并直接退出
	echo ""
	local _rmsbs=""
	readp "卸载完成后是否一并移除 sbs 快捷启动命令并退出脚本？（回车默认 y 移除并退出，输入 n 保留 sbs 命令）：" _rmsbs
	_rmsbs="${_rmsbs:-y}"

	echo ""
	echo "正在停止并禁用 sing-box 服务..."
	systemctl stop "$SB_SERVICE" >/dev/null 2>&1 || true
	systemctl disable "$SB_SERVICE" >/dev/null 2>&1 || true

	echo "正在清理 iptables / ip6tables 流量统计规则..."
	remove_traffic_rules

	echo "正在移除 sing-box 软件包、二进制文件与 /etc/sing-box 配置目录..."
	if cmd_exists apt-get; then
		apt-get purge -y sing-box >/dev/null 2>&1 || true
		apt-get autoremove -y >/dev/null 2>&1 || true
	fi
	rm -rf "$SB_DIR" /var/lib/sing-box || true
	rm -f /usr/bin/sing-box /usr/local/bin/sing-box || true
	rm -f /lib/systemd/system/sing-box.service /usr/lib/systemd/system/sing-box.service || true
	systemctl daemon-reload >/dev/null 2>&1 || true

	if [[ "$_clean_root" == "y" || "$_clean_root" == "Y" ]]; then
		rm -f "$KEYS_FILE" "$CLASH_FILE" "$SB_CLIENT_FILE" /root/sing-box-config-*.json /root/sing-box-bin-backup-* 2>/dev/null || true
		green "已清除 /root/ 下的代理密钥记录、客户端导出片段及配置备份。"
	else
		yellow "已保留 /root/ 下的历史密钥与配置备份文件。"
	fi

	if [[ "$_acme_opt" == "2" ]]; then
		echo "正在卸载 acme.sh 并彻底清除所有已申请的域名证书..."
		if acme_installed; then
			"$ACME_SH" --uninstall >/dev/null 2>&1 || true
		fi
		rm -rf "$ACME_HOME" 2>/dev/null || true
		if cmd_exists crontab; then
			(crontab -l 2>/dev/null | grep -v -i 'acme.sh' || true) | crontab - 2>/dev/null || true
		fi
		green "已彻底清除 ACME 域名证书、续期定时任务与 $ACME_HOME 目录。"
	else
		green "已保留本机 ACME 证书目录 ($ACME_HOME)，下次安装可直接导入使用。"
	fi

	if [[ "$_rmsbs" == "y" || "$_rmsbs" == "Y" ]]; then
		rm -f "$SBS_BIN" 2>/dev/null || true
		echo ""
		green "=============================================================="
		green " Sing-box 代理业务与 sbs 快捷命令已全部卸载清除完毕，脚本已退出！"
		green "=============================================================="
		exit 0
	else
		echo ""
		green "Sing-box 代理业务已卸载清除（保留了 sbs 快捷启动命令）。"
		return 0
	fi
}

# ---------- 变更配置与协议辅助函数 ----------
current_on_off() {
	if [[ "$1" == "vless" ]]; then
		if cfg_vless_enabled; then echo 1; else echo 0; fi
	else
		if cfg_hy2_enabled; then echo 1; else echo 0; fi
	fi
}

rewrite_with_current() {
	local vless_on="$1" hy2_on="$2" vless_port="$3" hy2_port="$4" hy2_domain="$5" sni="$6" up="$7" down="$8"
	read_current_values
	if [[ "$vless_on" == "1" ]] && [[ -z "$CUR_UUID" || -z "$CUR_PRIV" || -z "$CUR_SHORT" ]]; then
		red "未读取到完整的 VLESS 密钥记录，请先在菜单 3 -> 5 或 4 -> 3 重新生成 VLESS"
		return 1
	fi
	if [[ "$hy2_on" == "1" ]] && [[ -z "$CUR_HY2_PASS" || -z "$CUR_OBFS" ]]; then
		red "未读取到完整的 HY2 密码记录，请先在菜单 3 -> 6 或 4 -> 4 重新生成 HY2"
		return 1
	fi
	if ! write_config "$vless_on" "$vless_port" "${CUR_UUID:-}" "${CUR_PRIV:-}" "${CUR_SHORT:-}" "$sni" \
		"$hy2_on" "$hy2_port" "${CUR_HY2_PASS:-}" "${CUR_OBFS:-}" "$hy2_domain" "$up" "$down"; then
		return 1
	fi
	CUR_VLESS_PORT="$vless_port"
	CUR_SNI="$sni"
	CUR_HY2_PORT="$hy2_port"
	CUR_HY2_DOMAIN="$hy2_domain"
	CUR_UP="$up"
	CUR_DOWN="$down"
	save_keys_file "$CUR_PUB"
	show_clash_snippet >/dev/null 2>&1 || true
	show_sb_client_snippet >/dev/null 2>&1 || true

	systemctl restart "$SB_SERVICE" || {
		red "重启 sing-box 失败，请查看日志"
		return 1
	}
	green "配置已更新并成功重启服务"
	return 0
}

# ---------- 变更配置（二级菜单） ----------
change_config_menu() {
	while true; do
		read_current_values
		local hy2_mode_str="免域名自签"
		if is_real_cert; then
			hy2_mode_str="ACME真实证书"
		fi
		echo ""
		echo "=== 变更配置 ==="
		echo "当前 VLESS：端口 $CUR_VLESS_PORT | SNI $CUR_SNI | $(if cfg_vless_enabled; then echo "已启用"; else echo "已停用"; fi)"
		echo "当前 HY2  ：端口 $CUR_HY2_PORT | 模式 $hy2_mode_str ($CUR_HY2_DOMAIN) | 带宽 ${CUR_UP}/${CUR_DOWN} Mbps | $(if cfg_hy2_enabled; then echo "已启用"; else echo "已停用"; fi)"
		echo "----------------------------------------------"
		echo "1）修改 VLESS 端口"
		echo "2）修改 HY2 端口"
		echo "3）切换 HY2 证书模式 / 修改 HY2 域名或自签 SNI"
		echo "4）修改 Reality 伪装域名 (SNI)"
		echo "5）重新生成 VLESS UUID 与 Reality 密钥对"
		echo "6）重新生成 HY2 密码与混淆密码"
		echo "7）修改 HY2 上下行带宽限制"
		echo "0）返回主菜单"
		readp "请选择 [0-7]：" _m
		case "${_m:-}" in
		1)
			local p
			ask_port "新的 VLESS 端口 (TCP)" "$CUR_VLESS_PORT" p
			if ! check_port_free_or_warn "$p" tcp; then
				red "该端口已被其他程序占用，已取消"
				press_any_key
				continue
			fi
			rewrite_with_current "$(current_on_off vless)" "$(current_on_off hy2)" "$p" "$CUR_HY2_PORT" "$CUR_HY2_DOMAIN" "$CUR_SNI" "$CUR_UP" "$CUR_DOWN" || true
			;;
		2)
			local p2
			ask_port "新的 HY2 端口 (UDP)" "$CUR_HY2_PORT" p2
			if ! check_port_free_or_warn "$p2" udp; then
				red "该端口已被其他程序占用，已取消"
				press_any_key
				continue
			fi
			rewrite_with_current "$(current_on_off vless)" "$(current_on_off hy2)" "$CUR_VLESS_PORT" "$p2" "$CUR_HY2_DOMAIN" "$CUR_SNI" "$CUR_UP" "$CUR_DOWN" || true
			;;
		3)
			local d="$CUR_HY2_DOMAIN"
			if setup_hy2_cert_interactive d; then
				rewrite_with_current "$(current_on_off vless)" "$(current_on_off hy2)" "$CUR_VLESS_PORT" "$CUR_HY2_PORT" "$d" "$CUR_SNI" "$CUR_UP" "$CUR_DOWN" || true
			else
				yellow "未更改 HY2 证书与域名配置"
			fi
			;;
		4)
			local s
			ask_hostname "新的 Reality SNI" "$CUR_SNI" s
			rewrite_with_current "$(current_on_off vless)" "$(current_on_off hy2)" "$CUR_VLESS_PORT" "$CUR_HY2_PORT" "$CUR_HY2_DOMAIN" "$s" "$CUR_UP" "$CUR_DOWN" || true
			;;
		5)
			echo "重新生成后，旧的 VLESS 节点链接将立即失效（如 VLESS 处于停用状态将一并启用）。"
			readp "确定重新生成吗？（y 确定）：" _r
			if [[ "${_r:-n}" != "y" && "${_r:-n}" != "Y" ]]; then
				yellow "已取消"
				continue
			fi
			local uuid2 kp2 priv2 pub2 short2
			uuid2="$(sing-box generate uuid)" || { red "生成失败"; continue; }
			kp2="$(sing-box generate reality-keypair)" || { red "生成失败"; continue; }
			priv2="$(echo "$kp2" | awk '/PrivateKey:/{print $2}')"
			pub2="$(echo "$kp2" | awk '/PublicKey:/{print $2}')"
			short2="$(sing-box generate rand --hex 8)" || { red "生成失败"; continue; }

			if ! write_config 1 "$CUR_VLESS_PORT" "$uuid2" "$priv2" "$short2" "$CUR_SNI" \
				"$(current_on_off hy2)" "$CUR_HY2_PORT" "${CUR_HY2_PASS:-}" "${CUR_OBFS:-}" "$CUR_HY2_DOMAIN" "$CUR_UP" "$CUR_DOWN"; then
				continue
			fi
			save_keys_file "$pub2"
			show_clash_snippet >/dev/null 2>&1 || true
			show_sb_client_snippet >/dev/null 2>&1 || true
			systemctl restart "$SB_SERVICE" || true
			green "VLESS 密钥对已更新！"
			show_nodes || true
			;;
		6)
			echo "重新生成后，旧的 HY2 节点链接将立即失效（如 HY2 处于停用状态将一并启用）。"
			readp "确定重新生成吗？（y 确定）：" _r2
			if [[ "${_r2:-n}" != "y" && "${_r2:-n}" != "Y" ]]; then
				yellow "已取消"
				continue
			fi
			local hp2 ob2
			hp2="$(sing-box generate rand --hex 16)" || { red "生成失败"; continue; }
			ob2="$(sing-box generate rand --hex 16)" || { red "生成失败"; continue; }

			if ! write_config "$(current_on_off vless)" "$CUR_VLESS_PORT" "${CUR_UUID:-}" "${CUR_PRIV:-}" "${CUR_SHORT:-}" "$CUR_SNI" \
				1 "$CUR_HY2_PORT" "$hp2" "$ob2" "$CUR_HY2_DOMAIN" "$CUR_UP" "$CUR_DOWN"; then
				continue
			fi
			save_keys_file "$CUR_PUB"
			show_clash_snippet >/dev/null 2>&1 || true
			show_sb_client_snippet >/dev/null 2>&1 || true
			systemctl restart "$SB_SERVICE" || true
			green "HY2 密码已更新！"
			show_nodes || true
			;;
		7)
			local up2 down2
			ask_number "新的 HY2 上行带宽 (Mbps)" "$CUR_UP" up2
			ask_number "新的 HY2 下行带宽 (Mbps)" "$CUR_DOWN" down2
			rewrite_with_current "$(current_on_off vless)" "$(current_on_off hy2)" "$CUR_VLESS_PORT" "$CUR_HY2_PORT" "$CUR_HY2_DOMAIN" "$CUR_SNI" "$up2" "$down2" || true
			;;
		0 | "") return 0 ;;
		*) red "输入有误，请选择 0-7" ;;
		esac
		press_any_key
	done
}

# ---------- 管理协议（二级菜单） ----------
manage_protocols_menu() {
	while true; do
		read_current_values
		echo ""
		echo "=== 管理协议（单独启停与重置） ==="
		echo "VLESS-Reality：$(if cfg_vless_enabled; then echo "已启用（TCP 端口 $CUR_VLESS_PORT）"; else echo "已停用（保留原参数于密钥记录）"; fi)"
		echo "Hysteria2    ：$(if cfg_hy2_enabled; then echo "已启用（UDP 端口 $CUR_HY2_PORT）"; else echo "已停用（保留原参数于密钥记录）"; fi)"
		echo "----------------------------------------------"
		echo "1）切换 VLESS 状态（启用 <-> 停用，保留原密钥与端口）"
		echo "2）切换 HY2 状态  （启用 <-> 停用，保留原密码与端口）"
		echo "3）全新重置并启用 VLESS（重设端口/SNI 并生成新密钥）"
		echo "4）全新重置并启用 HY2  （重设端口/证书模式 并生成新密码）"
		echo "0）返回主菜单"
		readp "请选择 [0-4]：" _m
		case "${_m:-}" in
		1)
			if cfg_vless_enabled; then
				rewrite_with_current 0 "$(current_on_off hy2)" "$CUR_VLESS_PORT" "$CUR_HY2_PORT" "$CUR_HY2_DOMAIN" "$CUR_SNI" "$CUR_UP" "$CUR_DOWN" || true
			else
				rewrite_with_current 1 "$(current_on_off hy2)" "$CUR_VLESS_PORT" "$CUR_HY2_PORT" "$CUR_HY2_DOMAIN" "$CUR_SNI" "$CUR_UP" "$CUR_DOWN" || true
			fi
			;;
		2)
			if cfg_hy2_enabled; then
				rewrite_with_current "$(current_on_off vless)" 0 "$CUR_VLESS_PORT" "$CUR_HY2_PORT" "$CUR_HY2_DOMAIN" "$CUR_SNI" "$CUR_UP" "$CUR_DOWN" || true
			else
				rewrite_with_current "$(current_on_off vless)" 1 "$CUR_VLESS_PORT" "$CUR_HY2_PORT" "$CUR_HY2_DOMAIN" "$CUR_SNI" "$CUR_UP" "$CUR_DOWN" || true
			fi
			;;
		3)
			local p s uuid3 kp3 priv3 pub3 short3
			ask_port "VLESS 端口 (TCP)" "$CUR_VLESS_PORT" p
			if ! check_port_free_or_warn "$p" tcp; then
				red "TCP 端口 $p 已被其他服务占用，已取消"
				press_any_key
				continue
			fi
			ask_hostname "Reality SNI" "$CUR_SNI" s
			uuid3="$(sing-box generate uuid)" || { red "生成失败"; continue; }
			kp3="$(sing-box generate reality-keypair)" || { red "生成失败"; continue; }
			priv3="$(echo "$kp3" | awk '/PrivateKey:/{print $2}')"
			pub3="$(echo "$kp3" | awk '/PublicKey:/{print $2}')"
			short3="$(sing-box generate rand --hex 8)" || { red "生成失败"; continue; }

			if ! write_config 1 "$p" "$uuid3" "$priv3" "$short3" "$s" \
				"$(current_on_off hy2)" "$CUR_HY2_PORT" "${CUR_HY2_PASS:-}" "${CUR_OBFS:-}" "$CUR_HY2_DOMAIN" "$CUR_UP" "$CUR_DOWN"; then
				continue
			fi
			save_keys_file "$pub3"
			show_clash_snippet >/dev/null 2>&1 || true
			show_sb_client_snippet >/dev/null 2>&1 || true
			systemctl restart "$SB_SERVICE" || true
			green "VLESS 已全新重置并启用"
			show_nodes || true
			;;
		4)
			local p2 d="$CUR_HY2_DOMAIN" hp3 ob3
			ask_port "HY2 端口 (UDP)" "$CUR_HY2_PORT" p2
			if ! check_port_free_or_warn "$p2" udp; then
				red "UDP 端口 $p2 已被其他服务占用，已取消"
				press_any_key
				continue
			fi
			if ! setup_hy2_cert_interactive d; then
				yellow "已取消重置 HY2"
				press_any_key
				continue
			fi
			hp3="$(sing-box generate rand --hex 16)" || { red "生成失败"; continue; }
			ob3="$(sing-box generate rand --hex 16)" || { red "生成失败"; continue; }

			if ! write_config "$(current_on_off vless)" "$CUR_VLESS_PORT" "${CUR_UUID:-}" "${CUR_PRIV:-}" "${CUR_SHORT:-}" "$CUR_SNI" \
				1 "$p2" "$hp3" "$ob3" "$d" "$CUR_UP" "$CUR_DOWN"; then
				continue
			fi
			save_keys_file "$CUR_PUB"
			show_clash_snippet >/dev/null 2>&1 || true
			show_sb_client_snippet >/dev/null 2>&1 || true
			systemctl restart "$SB_SERVICE" || true
			green "HY2 已全新重置并启用"
			show_nodes || true
			;;
		0 | "") return 0 ;;
		*) red "输入有误，请选择 0-4" ;;
		esac
		press_any_key
	done
}

# ---------- 启动 / 重启 / 停止 ----------
service_menu() {
	echo ""
	echo "1）启动 Sing-box"
	echo "2）重启 Sing-box"
	echo "3）停止 Sing-box"
	echo "0）返回主菜单"
	readp "请选择 [0-3]：" _m
	case "${_m:-}" in
	1)
		setup_traffic_rules >/dev/null 2>&1 || true
		systemctl start "$SB_SERVICE" && green "已启动" || red "启动失败，请查看日志"
		;;
	2)
		setup_traffic_rules >/dev/null 2>&1 || true
		systemctl restart "$SB_SERVICE" && green "已重启" || red "重启失败，请查看日志"
		;;
	3) systemctl stop "$SB_SERVICE" && green "已停止" || red "停止失败" ;;
	0 | "") return 0 ;;
	*) red "输入错误" ;;
	esac
	systemctl status "$SB_SERVICE" --no-pager || true
}

# ---------- 更新 / 切换内核 ----------
update_core() {
	echo "=== 更新 / 切换 Sing-box 内核 ==="
	echo "当前版本：$(singbox_version 2>/dev/null || echo "未安装")"
	local latest=""
	if cmd_exists jq; then
		latest="$(curl -fsSL -m 8 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//' || true)"
	fi
	if [[ -z "$latest" ]]; then
		latest="$(curl -fsSL -m 8 -I https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | awk -F'/tag/v' '/^location:/I{print $2}' | tr -d '\r\n ' || true)"
	fi
	if [[ -n "$latest" ]]; then
		echo "GitHub 最新正式版：$latest"
	else
		yellow "获取 GitHub 最新版本号超时，仍可继续安装或手动指定版本"
	fi
	echo "1）更新到最新正式版（官方脚本）"
	echo "2）指定版本号安装（例如 1.12.0）"
	echo "0）返回主菜单"
	readp "请选择 [0-2]：" _m
	case "${_m:-}" in
	1)
		curl -fsSL https://sing-box.app/install.sh | sh || {
			red "官方脚本更新失败"
			return 1
		}
		fix_sb_perms
		if [[ -f "$SB_CONFIG" ]] && ! sing-box check -c "$SB_CONFIG"; then
			red "新版本配置校验失败，未重启服务"
			return 1
		fi
		systemctl restart "$SB_SERVICE" 2>/dev/null || true
		green "已更新至 $(singbox_version)"
		;;
	2)
		local ver arch
		readp "请输入目标版本号（如 1.12.0，不带 v）：" ver
		if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
			red "版本号格式不正确"
			return 1
		fi
		arch="$(get_arch)"
		local name="sing-box-$ver-linux-$arch"
		local url="https://github.com/SagerNet/sing-box/releases/download/v$ver/$name.tar.gz"
		local tmpdir="/tmp/sb-update-$$"
		mkdir -p "$tmpdir"
		echo "正在下载 $url ..."
		if ! curl -fsSL -o "$tmpdir/sb.tar.gz" "$url"; then
			red "下载失败，请检查版本号是否存在或网络连接"
			rm -rf "$tmpdir"
			return 1
		fi
		if ! tar tzf "$tmpdir/sb.tar.gz" >/dev/null 2>&1; then
			red "下载的文件不是有效的 tar.gz 压缩包，已中止"
			rm -rf "$tmpdir"
			return 1
		fi
		tar xzf "$tmpdir/sb.tar.gz" -C "$tmpdir" || {
			red "解压失败"
			rm -rf "$tmpdir"
			return 1
		}
		if [[ ! -x "$tmpdir/$name/sing-box" ]]; then
			red "解压后未找到 sing-box 二进制程序"
			rm -rf "$tmpdir"
			return 1
		fi
		local bin_target="/usr/bin/sing-box"
		[[ -x /usr/local/bin/sing-box && ! -x /usr/bin/sing-box ]] && bin_target="/usr/local/bin/sing-box"
		local bin_bak="/root/sing-box-bin-backup-$(date +%Y%m%d-%H%M%S)"
		if [[ -f "$bin_target" ]]; then
			cp -f "$bin_target" "$bin_bak" 2>/dev/null || true
		fi
		if ! install -m 755 "$tmpdir/$name/sing-box" "$bin_target"; then
			red "替换二进制文件失败"
			rm -rf "$tmpdir"
			return 1
		fi
		rm -rf "$tmpdir"
		fix_sb_perms
		if [[ -f "$SB_CONFIG" ]] && ! sing-box check -c "$SB_CONFIG"; then
			red "新内核校验当前配置未通过，正在自动回滚旧版内核..."
			[[ -f "$bin_bak" ]] && install -m 755 "$bin_bak" "$bin_target"
			return 1
		fi
		systemctl restart "$SB_SERVICE" || true
		green "已成功切换内核版本至 $(singbox_version)"
		;;
	0 | "") return 0 ;;
	*) red "输入错误" ;;
	esac
	return 0
}

# ---------- 日志查看 ----------
view_logs() {
	echo ""
	echo "=== 查看 Sing-box 日志 ==="
	echo "1）实时滚动日志（按 Ctrl+C 退出）"
	echo "2）查看最近 100 行日志"
	echo "3）查看最近 1 小时日志"
	echo "4）仅看 Hysteria2 相关日志（最近 1 小时）"
	echo "5）仅看 VLESS 相关日志（最近 1 小时）"
	echo "6）仅看今日错误日志 (error)"
	echo "0）返回主菜单"
	readp "请选择 [0-6]：" _m
	case "${_m:-}" in
	1) journalctl -u "$SB_SERVICE" -f --no-pager ;;
	2) journalctl -u "$SB_SERVICE" -n 100 --no-pager ;;
	3) journalctl -u "$SB_SERVICE" --since "-1h" --no-pager ;;
	4) journalctl -u "$SB_SERVICE" --since "-1h" --no-pager | grep -iE 'hysteria|hy2' || echo "最近 1 小时无 HY2 相关日志" ;;
	5) journalctl -u "$SB_SERVICE" --since "-1h" --no-pager | grep -i vless || echo "最近 1 小时无 VLESS 相关日志" ;;
	6) journalctl -u "$SB_SERVICE" -p err --since today --no-pager ;;
	0 | "") return 0 ;;
	*) red "输入错误" ;;
	esac
}

# ---------- 开启 BBR ----------
enable_bbr() {
	echo "=== 一键开启 BBR + FQ ==="
	echo "当前 TCP 拥塞控制算法：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")"
	echo "当前队列调度算法 (qdisc)：$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")"
	if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
		green "系统当前已启用 BBR"
	fi
	readp "是否写入/刷新 BBR+FQ 配置？（y 确认，其他取消）：" _b
	if [[ "${_b:-n}" != "y" && "${_b:-n}" != "Y" ]]; then
		yellow "已取消"
		return 0
	fi
	if ! lsmod 2>/dev/null | grep -q tcp_bbr; then
		modprobe tcp_bbr 2>/dev/null || true
	fi
	if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
		red "当前系统内核不支持 BBR（可能是受限的容器虚拟化环境）"
		return 1
	fi
	cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
	echo "tcp_bbr" >/etc/modules-load.d/bbr.conf
	sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-bbr.conf || {
		red "sysctl 参数加载失败"
		return 1
	}
	green "BBR + FQ 已生效（当前算法：$(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)）"
	return 0
}

# ---------- 证书与 ACME 完整管理（二级菜单，含申请、切换自签、查看与导入本机证书、续期、删除证书） ----------
acme_menu() {
	while true; do
		read_current_values
		local cert_status="未生成证书"
		if [[ -f "$SB_DIR/fullchain.pem" ]]; then
			if is_real_cert; then
				cert_status="CA 真实证书（域名: $CUR_HY2_DOMAIN）"
			else
				cert_status="免域名自签证书（伪装 SNI: $CUR_HY2_DOMAIN）"
			fi
		fi
		echo ""
		echo "=== 管理证书（ACME 真实证书 & 免域名自签证书） ==="
		echo "当前 HY2 证书状态：$cert_status"
		echo "----------------------------------------------"
		echo "1）申请 / 切换为域名 ACME 真实证书（输入新域名或重装当前域名证书）"
		echo "2）切换为免域名自签证书模式（无需域名，直接用 IP 连接）"
		echo "3）查看当前证书详情与 acme.sh 证书列表（支持直接导入使用本机已有证书）"
		echo "4）强制续期当前域名的 ACME 证书"
		echo "5）删除已申请的 ACME 域名证书（清理旧域名证书记录与文件）"
		echo "0）返回主菜单"
		readp "请选择 [0-5]：" _m
		case "${_m:-}" in
		1)
			local d2=""
			if ask_user_domain "请输入要申请/安装的域名" "$CUR_HY2_DOMAIN" d2; then
				if issue_cert "$d2"; then
					if [[ -f "$SB_CONFIG" ]]; then
						rewrite_with_current "$(current_on_off vless)" "$(current_on_off hy2)" "$CUR_VLESS_PORT" "$CUR_HY2_PORT" "$d2" "$CUR_SNI" "$CUR_UP" "$CUR_DOWN" || true
					else
						systemctl restart "$SB_SERVICE" 2>/dev/null || true
					fi
					green "已成功切换为域名 $d2 的 ACME 真实证书！"
				fi
			fi
			;;
		2)
			local sni_self="www.bing.com"
			ask_hostname "请输入自签证书伪装域名 (SNI)" "www.bing.com" sni_self
			if make_self_signed "$sni_self"; then
				if [[ -f "$SB_CONFIG" ]]; then
					rewrite_with_current "$(current_on_off vless)" "$(current_on_off hy2)" "$CUR_VLESS_PORT" "$CUR_HY2_PORT" "$sni_self" "$CUR_SNI" "$CUR_UP" "$CUR_DOWN" || true
				fi
				green "已切换为免域名自签证书模式（SNI: $sni_self）！"
			fi
			;;
		3)
			show_cert
			;;
		4)
			if ! acme_installed; then
				red "尚未安装 acme.sh，当前可能处于免域名自签模式"
				press_any_key
				continue
			fi
			if ! is_real_cert; then
				yellow "当前正在使用的是免域名自签证书（有效期 10 年），无需通过 acme.sh 续期。"
				press_any_key
				continue
			fi
			if ss -tlnp 2>/dev/null | grep -qE ':80[[:space:]]'; then
				red "80 端口被占用，standalone 续期需要释放 80 端口"
				ss -tlnp 2>/dev/null | grep -E ':80[[:space:]]' || true
				press_any_key
				continue
			fi
			"$ACME_SH" --renew -d "$CUR_HY2_DOMAIN" --ecc --force || "$ACME_SH" --renew -d "$CUR_HY2_DOMAIN" --force || {
				red "强制续期失败"
				press_any_key
				continue
			}
			install_cert_to_singbox "$CUR_HY2_DOMAIN" || continue
			systemctl restart "$SB_SERVICE" 2>/dev/null || true
			green "证书强制续期完成并已重启 sing-box"
			;;
		5)
			delete_acme_cert
			;;
		0 | "") return 0 ;;
		*) red "输入错误，请选择 0-5" ;;
		esac
		press_any_key
	done
}

# ---------- 更新本脚本（支持远程 URL 直链或本地新文件一键更新） ----------
update_script() {
	echo "=== 更新 sbs 脚本 ==="
	echo "当前脚本版本：$SCRIPT_VERSION"
	echo "1）通过远程脚本直链 URL 下载更新"
	echo "2）通过本地已上传的新脚本文件更新（如 /root/sbs.sh）"
	echo "0）取消返回"
	local up_mode=""
	readp "请选择更新方式 [0-2]（回车默认 1）：" up_mode
	case "${up_mode:-1}" in
	1)
		local _url=""
		if [[ -n "$DEFAULT_SCRIPT_URL" ]]; then
			readp "请输入脚本直链 URL（直接回车使用预设地址 $DEFAULT_SCRIPT_URL）：" _url
			_url="${_url:-$DEFAULT_SCRIPT_URL}"
		else
			readp "请输入新版本脚本的直链 URL（直接回车取消）：" _url
		fi
		if [[ -z "${_url:-}" ]]; then
			yellow "已取消"
			return 0
		fi
		local tmp="/tmp/sbs-new-$$.sh"
		if ! curl -fsSL -o "$tmp" "$_url"; then
			red "下载失败，请检查 URL 是否可访问"
			rm -f "$tmp"
			return 1
		fi
		sed -i 's/\r$//' "$tmp" 2>/dev/null || true
		if ! bash -n "$tmp"; then
			red "下载的文件未通过 bash 语法校验，已放弃替换"
			rm -f "$tmp"
			return 1
		fi
		install -m 755 "$tmp" "$SBS_BIN" || {
			red "更新 $SBS_BIN 失败"
			rm -f "$tmp"
			return 1
		}
		[[ -f /root/sbs.sh && "/root/sbs.sh" != "$SBS_BIN" ]] && install -m 755 "$tmp" /root/sbs.sh 2>/dev/null || true
		rm -f "$tmp"
		green "脚本已更新成功，正在重新加载新版本 sbs..."
		exec "$SBS_BIN"
		;;
	2)
		local local_path=""
		readp "请输入本地新脚本文件路径（回车默认 /root/sbs.sh）：" local_path
		local_path="${local_path:-/root/sbs.sh}"
		if [[ ! -f "$local_path" ]]; then
			red "找不到文件：$local_path"
			return 1
		fi
		sed -i 's/\r$//' "$local_path" 2>/dev/null || true
		if ! bash -n "$local_path"; then
			red "该文件未通过 bash 语法校验，已放弃替换"
			return 1
		fi
		install -m 755 "$local_path" "$SBS_BIN" || {
			red "更新 $SBS_BIN 失败"
			return 1
		}
		green "已从 $local_path 同步更新至 $SBS_BIN，正在重新加载新版本 sbs..."
		exec "$SBS_BIN"
		;;
	*)
		yellow "已取消"
		return 0
		;;
	esac
}

# ---------- 主菜单 ----------
main_menu() {
	need_root
	check_os
	fix_terminal_backspace
	install_sbs_command 1
	while true; do
		clear 2>/dev/null || true
		show_status
		echo ""
		echo " 1）一键安装 Sing-box（VLESS-Reality + Hysteria2，支持免域名/有域名）"
		echo " 2）卸载 Sing-box（彻底清除代理业务，可选保留或清除 ACME 证书）"
		echo " 3）变更配置（端口 / 证书模式与域名 / SNI / 密钥 / 带宽）"
		echo " 4）管理协议（单独启停 / 重置单个协议）"
		echo " 5）查看节点（URI 链接 / 二维码 / Clash Verge / Sing-box）"
		echo " 6）启动 / 重启 / 停止 Sing-box"
		echo " 7）更新 / 切换 Sing-box 内核版本"
		echo " 8）查看 Sing-box 运行日志"
		echo " 9）一键开启 BBR+FQ 加速"
		echo "10）管理证书（ACME 真实证书申请、查看与导入本机证书、续期、删除 / 切换自签）"
		echo "11）查看实时流量监控（按协议实时显示出入速率、连接数与累计流量）"
		echo "12）更新本脚本 (sbs)"
		echo " 0）退出"
		echo ""
		readp "请输入数字 [0-12]：" choice
		case "${choice:-}" in
		1)
			one_click_install
			press_any_key
			;;
		2)
			uninstall_singbox
			press_any_key
			;;
		3)
			if [[ ! -f "$SB_CONFIG" ]]; then
				red "尚未安装配置，请先选择 1 一键安装"
				press_any_key
				continue
			fi
			change_config_menu
			;;
		4)
			if [[ ! -f "$SB_CONFIG" ]]; then
				red "尚未安装配置，请先选择 1 一键安装"
				press_any_key
				continue
			fi
			manage_protocols_menu
			;;
		5)
			nodes_menu
			;;
		6)
			service_menu
			press_any_key
			;;
		7)
			update_core
			press_any_key
			;;
		8)
			view_logs
			press_any_key
			;;
		9)
			enable_bbr
			press_any_key
			;;
		10)
			acme_menu
			;;
		11)
			traffic_monitor_menu
			;;
		12)
			update_script
			press_any_key
			;;
		0)
			if [[ -x "$SBS_BIN" ]]; then
				green "已退出（随时输入 sbs 可再次进入菜单）"
			else
				green "已退出"
			fi
			exit 0
			;;
		*)
			red "输入有误，请输入 0-12 之间的数字"
			sleep 1
			;;
		esac
	done
}

# ---------- 命令行参数入口 ----------
fix_terminal_backspace
case "${1:-}" in
--install-command)
	need_root
	install_sbs_command 0
	;;
--version | -v)
	echo "sbs version $SCRIPT_VERSION"
	;;
--nodes | -n)
	need_root
	show_nodes
	;;
--qr | -q)
	need_root
	show_qrcodes
	;;
--clash | -c)
	need_root
	show_clash_snippet
	;;
--sb-client | -s)
	need_root
	show_sb_client_snippet
	;;
--traffic | -t)
	need_root
	traffic_monitor_menu
	;;
--help | -h)
	echo "用法："
	echo "  bash sbs.sh             # 首次运行并自动注册 sbs 命令"
	echo "  sbs                     # 直接进入交互式管理菜单"
	echo "  sbs --nodes             # 直接打印当前节点 URI 分享链接"
	echo "  sbs --qr                # 直接在终端输出节点二维码"
	echo "  sbs --clash             # 输出并保存 Clash Verge (Mihomo) YAML 配置片段"
	echo "  sbs --sb-client         # 输出并保存 Sing-box 客户端 outbounds JSON 配置片段"
	echo "  sbs --traffic           # 直接进入各协议实时流量监控面板"
	echo "  sbs --install-command   # 仅注册 /usr/local/bin/sbs 快捷命令"
	echo "  sbs --version           # 查看脚本版本"
	;;
*)
	main_menu
	;;
esac