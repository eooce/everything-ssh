#!/bin/bash
set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
log_url()   { echo -e "${BLUE}[URL]${NC} $1"; }

export ARGO_PORT=${ARGO_PORT:-'8080'} 
export ARGO_DOMAIN=${ARGO_DOMAIN:-''}
export ARGO_AUTH=${ARGO_AUTH:-''}
export USERNAME=${USERNAME:-'admin'}  # 默认用户名
export PASSWORD=${PASSWORD:-''}       # 密码

LOG_MODE="file"

# 系统检测 
detect_arch() {
    case $(uname -m) in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv8l) echo "armv7" ;;
        *) log_error "不支持的架构: $(uname -m)" ;;
    esac
}
detect_os() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        linux|darwin) echo "$os" ;;
        *) log_error "不支持的操作系统: $(uname -s)" ;;
    esac
}

# 下载工具
download_file() {
    local url="$1" output="$2"
    [[ -f "$output" ]] && { log_info "$output 已存在，跳过下载"; return; }
    log_info "下载: $url"
    curl -sLo "$output" "$url" || log_error "下载失败: $url"
    chmod +x "$output"
}
download_gotty() {
    [[ -f ./gotty ]] && { log_info "gotty 已存在，跳过下载"; return; }
    local arch="$1" os="$2" version="v1.8.0"
    local filename="gotty_${version}_${os}_${arch}.tar.gz"
    local url="https://github.com/sorenisanerd/gotty/releases/download/${version}/${filename}"
    local tmp=$(mktemp -d)
    download_file "$url" "${tmp}/${filename}"
    tar -xzf "${tmp}/${filename}" -C "$tmp"
    cp "$(find "$tmp" -name gotty -type f)" ./gotty
    chmod +x ./gotty
    rm -rf "$tmp"
    log_info "gotty 下载完成"
}
download_cloudflared() {
    [[ -f ./cloudflared ]] && { log_info "cloudflared 已存在，跳过下载"; return; }
    local arch="$1" os="$2"
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${os}-${arch}"
    [[ "$os" == "linux" && "$arch" == "armv7" ]] && url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
    download_file "$url" "./cloudflared"
    log_info "cloudflared 下载完成"
}

# 构建 cloudflared 隧道参数
build_tunnel_args() {
    local gotty_port="$1"

    if [[ -n "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
        # ---------- 固定隧道模式 ----------
        if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
            # JSON 配置文件格式
            local config_file="$(pwd)/tunnel.yml"
            printf '%s\n' "$ARGO_AUTH" > "$config_file"
            chmod 600 "$config_file"
            log_info "识别为 JSON 配置固定隧道模式，已生成 $config_file" >&2
            echo "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --config $config_file run"
        else
            if [[ "$ARGO_AUTH" =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
                log_info "识别为固定隧道 Token 模式" >&2
            else
                log_warn "ARGO_AUTH 格式无法识别，将尝试作为 Token 使用" >&2
            fi
            echo "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}"
        fi
    else
        # ---------- 临时隧道模式 ----------
        echo "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --url http://localhost:$gotty_port"
    fi
}

# 创建自守护 Wrapper（仅 nohup 模式使用）：任一进程退出后自动重启
create_supervised_wrapper() {
    local gotty_port="$1" cmd="$2"
    local dir="$(pwd)"
    local tunnel_args=$(build_tunnel_args "$gotty_port")
    local wrapper="$dir/.gotty-wrapper.sh"

    # 构建带认证的 gotty 命令
    local gotty_cmd="$dir/gotty -w -p $gotty_port $cmd"
    if [[ -n "$USERNAME" && -n "$PASSWORD" ]]; then
        gotty_cmd="$dir/gotty -w -c \"$USERNAME:$PASSWORD\" -p $gotty_port $cmd"
    fi

    cat > "$wrapper" <<EOF
#!/bin/bash
cd "$dir"

start_gotty() {
    $gotty_cmd &
    GOTTY_PID=\$!
}

start_cloudflared() {
    "$dir/cloudflared" $tunnel_args &
    CF_PID=\$!
}

start_gotty
start_cloudflared

while true; do
    if ! kill -0 \$GOTTY_PID 2>/dev/null; then
        echo "\$(date '+%F %T') gotty 已退出，5秒后重启..."
        sleep 5
        start_gotty
    fi
    if ! kill -0 \$CF_PID 2>/dev/null; then
        echo "\$(date '+%F %T') cloudflared 已退出，5秒后重启..."
        sleep 5
        start_cloudflared
    fi
    sleep 5
done
EOF
    chmod +x "$wrapper"
    echo "$wrapper"
}

# 服务管理器检测
has_systemd_system() { [[ -d /run/systemd/system ]] && [[ $(id -u) -eq 0 ]]; }
has_systemd_user() { [[ -d /run/systemd/system ]] && [[ -n "$XDG_RUNTIME_DIR" ]]; }
has_supervisor() { command -v supervisorctl &>/dev/null && supervisorctl status &>/dev/null; }

# 启动方式实现
start_with_systemd() {
    local gotty_port="$1" cmd="$2"
    local dir="$(pwd)"
    local tunnel_args=$(build_tunnel_args "$gotty_port")
    local unit_dir systemctl_cmd wanted_by

    # 构建带认证的 gotty 命令（作为完整字符串）
    local gotty_cmd="$dir/gotty -w -p $gotty_port $cmd"
    if [[ -n "$USERNAME" && -n "$PASSWORD" ]]; then
        gotty_cmd="$dir/gotty -w -c \"$USERNAME:$PASSWORD\" -p $gotty_port $cmd"
    fi

    if [[ $(id -u) -eq 0 ]]; then
        unit_dir="/etc/systemd/system"
        systemctl_cmd="systemctl"
        wanted_by="multi-user.target"
    else
        unit_dir="$HOME/.config/systemd/user"
        systemctl_cmd="systemctl --user"
        wanted_by="default.target"
        mkdir -p "$unit_dir"
    fi

    # 日志重定向到文件（append: 需要 systemd >= 240；低版本 stdout 只进 journal，需用 journalctl 查看）
    local log_directives=""
    local systemd_ver=$(systemctl --version 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)
    if [[ -n "$systemd_ver" && "$systemd_ver" -ge 240 ]]; then
        log_directives="StandardOutput=append:/tmp/gotty-tunnel.log
StandardError=append:/tmp/gotty-tunnel.log"
        LOG_MODE="file"
    elif [[ $(id -u) -eq 0 ]]; then
        LOG_MODE="journal"
    else
        LOG_MODE="journal-user"
    fi

    # gotty 服务
    cat > "$unit_dir/gotty.service" <<EOF
[Unit]
Description=Gotty Web Terminal
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/bin/bash -c "$gotty_cmd"
WorkingDirectory=$dir
Restart=always
RestartSec=5
$log_directives

[Install]
WantedBy=$wanted_by
EOF

    # cloudflared 隧道服务（独立守护，依赖 gotty）
    cat > "$unit_dir/gotty-cloudflared.service" <<EOF
[Unit]
Description=Cloudflared Tunnel for Gotty
After=network.target gotty.service
Requires=gotty.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$dir/cloudflared $tunnel_args
WorkingDirectory=$dir
Restart=always
RestartSec=5
$log_directives

[Install]
WantedBy=$wanted_by
EOF

    $systemctl_cmd daemon-reload
    $systemctl_cmd enable gotty gotty-cloudflared 2>/dev/null
    $systemctl_cmd restart gotty gotty-cloudflared
    log_info "✅ systemd 已启动 gotty + cloudflared 双服务（独立守护，崩溃自动重启）"
}

start_with_supervisor() {
    local gotty_port="$1" cmd="$2"
    local dir="$(pwd)"
    local tunnel_args=$(build_tunnel_args "$gotty_port")
    local conf_file="/etc/supervisor/conf.d/gotty-tunnel.conf"
    local need_manual_include=0

    # 构建带认证的 gotty 命令（command 行用 /bin/bash -c）
    local gotty_cmd="$dir/gotty -w -p $gotty_port $cmd"
    if [[ -n "$USERNAME" && -n "$PASSWORD" ]]; then
        gotty_cmd="$dir/gotty -w -c \"$USERNAME:$PASSWORD\" -p $gotty_port $cmd"
    fi

    if [[ ! -w "/etc/supervisor/conf.d" ]]; then
        conf_file="$HOME/.supervisor/gotty-tunnel.conf"
        mkdir -p "$(dirname "$conf_file")"
        need_manual_include=1
    fi

    cat > "$conf_file" <<EOF
[program:gotty]
command=/bin/bash -c "$gotty_cmd"
directory=$dir
autostart=true
autorestart=true
stdout_logfile=/tmp/gotty-tunnel.log
stderr_logfile=/tmp/gotty-tunnel.log

[program:gotty-cloudflared]
command=$dir/cloudflared $tunnel_args
directory=$dir
autostart=true
autorestart=true
stdout_logfile=/tmp/gotty-tunnel.log
stderr_logfile=/tmp/gotty-tunnel.log
EOF

    if [[ $need_manual_include -eq 1 ]]; then
        log_warn "配置已写入 $conf_file，但 supervisor 默认不会读取此路径"
        log_warn "请在 supervisord.conf 的 [include] 部分添加: files = $HOME/.supervisor/*.conf"
    fi

    supervisorctl reread 2>&1 || log_warn "supervisorctl reread 失败"
    supervisorctl update 2>&1
    supervisorctl start gotty gotty-cloudflared 2>/dev/null || true
    log_info "✅ supervisor 已启动 gotty + cloudflared 双进程（独立守护，崩溃自动重启）"
}

start_with_nohup() {
    local gotty_port="$1" cmd="$2"
    local wrapper=$(create_supervised_wrapper "$gotty_port" "$cmd")
    local logfile="/tmp/gotty-tunnel.log"
    nohup "$wrapper" > "$logfile" 2>&1 &
    local pid=$!
    log_info "nohup 已启动 PID: $pid（内置自守护循环，崩溃自动重启；但不会开机自启）"
}

# 从日志源等待匹配内容（后台管道 + 临时文件，避免匹配成功后仍阻塞整个超时周期）
wait_log_match() {
    local mode="$1" pattern="$2" secs="$3" out_file="$4"
    case "$mode" in
        journal)
            timeout "$secs" journalctl -u gotty-cloudflared -f --since "1 minute ago" --output=cat 2>/dev/null \
                | grep -m1 -oE "$pattern" > "$out_file" &
            ;;
        journal-user)
            timeout "$secs" journalctl --user -u gotty-cloudflared -f --since "1 minute ago" --output=cat 2>/dev/null \
                | grep -m1 -oE "$pattern" > "$out_file" &
            ;;
        *)
            timeout "$secs" tail -F /tmp/gotty-tunnel.log 2>/dev/null \
                | grep -m1 -oE "$pattern" > "$out_file" &
            ;;
    esac
    local grep_pid=$!
    wait $grep_pid 2>/dev/null || true
}

# 等待并打印临时隧道公网地址
wait_temp_tunnel_url() {
    local mode="$1"
    local tmp_out=$(mktemp)
    log_info "⏳ 等待临时隧道分配公网地址（最长60秒）..."
    wait_log_match "$mode" "https://[a-zA-Z0-9-]+\.trycloudflare\.com" 60 "$tmp_out"
    local url=$(head -1 "$tmp_out" 2>/dev/null)
    rm -f "$tmp_out"
    # 兜底：tail 附加前 URL 可能已打印，全量日志再扫一次
    if [[ -z "$url" ]]; then
        case "$mode" in
            journal)      url=$(journalctl -u gotty-cloudflared --no-pager --output=cat 2>/dev/null | grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" | tail -1) ;;
            journal-user) url=$(journalctl --user -u gotty-cloudflared --no-pager --output=cat 2>/dev/null | grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" | tail -1) ;;
            *)            url=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" /tmp/gotty-tunnel.log 2>/dev/null | tail -1) ;;
        esac
    fi
    if [[ -n "$url" ]]; then
        log_url "🌐 临时隧道地址(SSH公网地址): $url"
    else
        log_warn "未获取到临时隧道地址，请检查 cloudflared 日志: tail -F /tmp/gotty-tunnel.log"
    fi
}

# 固定隧道：确认 cloudflared 已连接边缘节点
check_fixed_tunnel() {
    local mode="$1"
    local tmp_out=$(mktemp)
    log_info "等待固定隧道建立连接（最长60秒）..."
    wait_log_match "$mode" "Registered tunnel connection" 60 "$tmp_out"
    # 兜底：tail 附加前连接日志可能已打印，全量日志再扫一次
    if [[ ! -s "$tmp_out" ]]; then
        case "$mode" in
            journal)      journalctl -u gotty-cloudflared --no-pager --output=cat 2>/dev/null | grep -m1 -q "Registered tunnel connection" && echo ok > "$tmp_out" ;;
            journal-user) journalctl --user -u gotty-cloudflared --no-pager --output=cat 2>/dev/null | grep -m1 -q "Registered tunnel connection" && echo ok > "$tmp_out" ;;
            *)            grep -m1 -q "Registered tunnel connection" /tmp/gotty-tunnel.log 2>/dev/null && echo ok > "$tmp_out" ;;
        esac || true
    fi
    if [[ -s "$tmp_out" ]]; then
        log_info "✅ 隧道连接已建立"
    else
        log_warn "未确认隧道连接，最近的 cloudflared 日志："
        tail -5 /tmp/gotty-tunnel.log 2>/dev/null
        log_warn "完整日志: tail -F /tmp/gotty-tunnel.log"
    fi
    rm -f "$tmp_out"
}

# 主流程
main() {
    # 检查是否设置了密码
    if [[ -z "$PASSWORD" ]]; then
        # 自动生成 6 位随机字母数字密码
        PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 6)
        echo -e "\033[0;33m[WARN] 未设置 PASSWORD，自动生成: $PASSWORD\033[0m"
    fi
    
    # 校验环境变量一致性
    if [[ -n "$ARGO_AUTH" && -z "$ARGO_DOMAIN" ]]; then
        log_error "ARGO_AUTH 已设置但 ARGO_DOMAIN 未设置，请同时设置两者或都留空。"
    fi
    if [[ -z "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
        log_error "ARGO_DOMAIN 已设置但 ARGO_AUTH 未设置，请同时设置两者或都留空。"
    fi

    # 决定 gotty 端口（命令行参数优先，其次 ARGO_PORT，默认 8080）
    local gotty_port="${1:-$ARGO_PORT}"
    if [[ -n "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
        log_info "固定隧道模式，gotty 监听端口: $gotty_port"
    else
        log_info "临时隧道模式，gotty 监听端口: $gotty_port"
    fi

    local cmd="${2:-/bin/bash}"

    local arch=$(detect_arch) os=$(detect_os)
    log_info "系统: $os / $arch"
    download_gotty "$arch" "$os"
    download_cloudflared "$arch" "$os"

    # 打印认证信息（如果启用）
    if [[ -n "$USERNAME" && -n "$PASSWORD" ]]; then
        log_info "🔐 HTTP Basic 认证已启用，用户名: $USERNAME ，密码: $PASSWORD"
    else
        log_info "⚠️  未设置认证（USERNAME 或 PASSWORD 为空），任何人可访问"
    fi

    if has_systemd_system || has_systemd_user; then
        start_with_systemd "$gotty_port" "$cmd"
    elif has_supervisor; then
        start_with_supervisor "$gotty_port" "$cmd"
    else
        start_with_nohup "$gotty_port" "$cmd"
    fi

    echo ""
    log_info "✅ 服务已在后台运行"
    if has_systemd_system; then
        log_info "🔧 管理命令: systemctl {start|stop|status|restart} gotty gotty-cloudflared"
    elif has_systemd_user; then
        log_info "🔧 管理命令: systemctl --user {start|stop|status|restart} gotty gotty-cloudflared"
    elif has_supervisor; then
        log_info "🔧 管理命令: supervisorctl {start|stop|status|restart} gotty gotty-cloudflared"
    else
        log_info "🔧 停止: pkill -f gotty-wrapper; pkill -f 'cloudflared tunnel'"
    fi
    case "$LOG_MODE" in
        journal)      log_info "📁 实时日志: journalctl -u gotty-cloudflared -f" ;;
        journal-user) log_info "📁 实时日志: journalctl --user -u gotty-cloudflared -f" ;;
        *)            log_info "📁 实时日志: tail -F /tmp/gotty-tunnel.log" ;;
    esac

    # 打印隧道访问地址
    echo ""
    if [[ -n "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
        log_url "🌐 公网SSH地址(固定隧道): https://$ARGO_DOMAIN"
        check_fixed_tunnel "$LOG_MODE"
    else
        wait_temp_tunnel_url "$LOG_MODE"
        
    fi
    
    # 打印认证信息
    if [[ -n "$USERNAME" && -n "$PASSWORD" ]]; then
        log_info "🔐 网页验证  用户名: $USERNAME  密码: $PASSWORD"
    fi
}

# 卸载模式
uninstall() {
    log_info "开始卸载 gotty-tunnel 服务..."
    local services="gotty gotty-cloudflared gotty-tunnel"

    # 停止并删除 systemd 服务（系统级 + 用户级，含旧版 gotty-tunnel）
    for svc in $services; do
        if systemctl is-active "$svc" &>/dev/null; then
            systemctl stop "$svc" 2>/dev/null
            systemctl disable "$svc" 2>/dev/null
            rm -f "/etc/systemd/system/${svc}.service"  
            log_info "已停止并禁用 systemd 系统级服务: $svc"
        fi
        if systemctl --user is-active "$svc" &>/dev/null; then
            systemctl --user stop "$svc" 2>/dev/null
            systemctl --user disable "$svc" 2>/dev/null
            rm -f "$HOME/.config/systemd/user/${svc}.service"
            log_info "已停止并禁用 systemd user 服务: $svc"
        fi
        for unit_file in "/etc/systemd/system/${svc}.service" "$HOME/.config/systemd/user/${svc}.service"; do
            if [[ -f "$unit_file" ]]; then
                rm -f "$unit_file"
                log_info "已删除 $unit_file"
            fi
        done
    done
    systemctl daemon-reload 2>/dev/null
    systemctl --user daemon-reload 2>/dev/null

    # 停止 supervisor 服务
    if command -v supervisorctl &>/dev/null; then
        supervisorctl stop gotty gotty-cloudflared gotty-tunnel 2>/dev/null && log_info "已停止 supervisor 服务"
        for conf in "/etc/supervisor/conf.d/gotty-tunnel.conf" "$HOME/.supervisor/gotty-tunnel.conf"; do
            [[ -f "$conf" ]] && rm -f "$conf" && log_info "已删除 $conf"
        done
        supervisorctl reread 2>/dev/null
        supervisorctl update 2>/dev/null
    fi

    # 先删除本地可执行文件和 wrapper 脚本
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for f in "$script_dir/gotty" "$script_dir/cloudflared" "$script_dir/tunnel.yml" "$script_dir/.gotty-wrapper.sh"; do
        if [[ -f "$f" ]]; then
            rm -f "$f" && log_info "已删除 $f"
        fi
    done

    # 然后强制终止所有残留进程
    pkill -9 -f "gotty-wrapper" 2>/dev/null && log_info "已强制终止 wrapper 进程"
    pkill -9 -f "gotty -w -p" 2>/dev/null && log_info "已强制终止 gotty 进程"
    pkill -9 -f "cloudflared tunnel" 2>/dev/null && log_info "已强制终止 cloudflared 进程"

    # 清理日志
    rm -f /tmp/gotty-tunnel.log /tmp/gotty-tunnel.err 2>/dev/null
    log_info "✅ 卸载完成"
    exit 0
}

# 参数解析：-u 卸载模式
if [[ "$1" == "-u" || "$1" == "--uninstall" ]]; then
    uninstall
fi

# 帮助
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat <<EOF
用法: $0 [选项] [端口] [命令]

选项：
  -u, --uninstall  卸载模式：停止服务、删除配置和本地文件
  -h, --help       显示帮助信息

环境变量（可选，必须成对出现）：
  ARGO_DOMAIN  固定隧道域名
  ARGO_AUTH  固定隧道认证信息（支持两种格式）：
              1. 纯 Token（长度120~250，字符 A-Z a-z 0-9 =）
              2. JSON 配置文件内容（包含 "TunnelSecret" 字段）

  USERNAME  (可选，默认 admin)
  PASSWORD  (可选，若未设置自动生成6位随机字母数字)

说明：
  - 若同时设置 ARGO_DOMAIN 和 ARGO_AUTH → 固定隧道模式
  - 若两者都未设置 → 临时隧道模式（trycloudflare.com）

示例：
  # 临时隧道
  ./$0

  # 临时隧道指定端口和命令
  ./$0 3000 htop

  # 固定隧道（纯 Token）
  export ARGO_PORT=8080
  export ARGO_AUTH=eyJh...（你的长 token）
  ./$0

  # 固定隧道（JSON 配置）
  export ARGO_PORT=8080
  export ARGO_AUTH='{"TunnelSecret":"...","AccountTag":"...","TunnelID":"..."}'
  ./$0

  # 指定用户名密码
  export USERNAME=myuser
  export PASSWORD=mypass
  ./$0

  # 卸载
  ./$0 -u

注意：固定隧道请在cloudflare 里设置端口为8080。
EOF
    exit 0
fi

main "$@"
