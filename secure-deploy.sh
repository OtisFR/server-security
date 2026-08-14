#!/bin/bash

set -euo pipefail  # 嚴格模式：任何錯誤都會停止執行

# ============================================================================
# 伺服器安全加固工具 v2.0 (UFW + Fail2Ban + Tailscale)
#
# 設計原則：
#   1. 絕不鎖死自己 —— 零信任配置一律「先驗證 Tailscale 連線成功，才封鎖公網」
#   2. 失敗就回滾 —— 關鍵步驟不吞錯誤，防火牆變更失敗會自動還原
#   3. 驗證有效值 —— 不只看指令有沒有執行，還確認系統實際狀態
#
# 配置說明：
#   1) 基礎防護    UFW 防火牆 + Fail2Ban（公網 SSH 保持開放）
#   2) 標準加固    基礎防護 + Tailscale VPN（公網 SSH 保持開放）
#   3) 零信任隔離  標準加固 + SSH 僅限 Tailscale 內網連入
#   附加選項：Exit Node（配置 2/3）、停用 IPv6（含安全檢查）
# ============================================================================

SCRIPT_VERSION="2.0.0"

# ============================================================================
# 前置檢查
# ============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "❌ [錯誤] 請使用 sudo 執行此腳本"
    exit 1
fi

if ! command -v apt-get &> /dev/null; then
    echo "❌ [錯誤] 此腳本僅支援使用 apt 套件管理員的系統 (Debian/Ubuntu)"
    exit 1
fi

# 此腳本需要互動輸入；經由 curl | bash 執行時 read 會誤讀腳本內容，直接拒絕
if [ ! -t 0 ]; then
    echo "❌ [錯誤] 此腳本需要互動式終端機，請勿以 curl | bash 方式執行。"
    echo "   正確方式：先下載並驗證，再執行："
    echo "   curl -fsSL -O https://raw.githubusercontent.com/OtisFR/server-security/main/secure-deploy.sh"
    echo "   sudo bash secure-deploy.sh"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ============================================================================
# 日誌系統
# ============================================================================
DEPLOY_LOG="/var/log/server-security-deploy.log"
touch "$DEPLOY_LOG" || { echo "❌ [錯誤] 無法建立日誌檔案"; exit 1; }

log() {
    local msg="$1"
    echo "$msg"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$DEPLOY_LOG"
}

# 執行指令並記錄結果；失敗時回傳非零值（由呼叫端決定是否致命）
run_logged() {
    local desc="$1"; shift
    if "$@" >> "$DEPLOY_LOG" 2>&1; then
        return 0
    else
        log "⚠️ [警告] ${desc} 失敗（詳見 $DEPLOY_LOG）"
        return 1
    fi
}

log "⚙️ [執行] server-security v${SCRIPT_VERSION} 部署開始"

# ============================================================================
# 共用工具函數
# ============================================================================

# IP / CIDR 驗證（優先 python3 精確解析；fallback regex 含正確的前綴範圍檢查）
validate_ip() {
    local ip=$1

    if command -v python3 &> /dev/null; then
        if python3 -c "import ipaddress, sys; ipaddress.ip_network(sys.argv[1], strict=False)" "$ip" 2>/dev/null; then
            return 0
        fi
        return 1
    fi

    local ipv4_regex='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(/([0-9]|[12][0-9]|3[0-2]))?$'
    local ipv6_regex='^([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{0,4}(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$'
    [[ $ip =~ $ipv4_regex ]] || [[ $ip =~ $ipv6_regex ]]
}

# 偵測 sshd 實際監聽的埠號（可能不只 22）；偵測失敗時退回 22
# SSH_PORTS_DETECTED=0 表示是猜測值——零信任配置會要求使用者確認，
# 否則封錯埠會把 Tailscale 通道一併封死
SSH_PORTS=""
SSH_PORTS_DETECTED=0
detect_ssh_ports() {
    local sshd_bin ports=""
    sshd_bin=$(command -v sshd || echo /usr/sbin/sshd)
    if [ -x "$sshd_bin" ]; then
        ports=$("$sshd_bin" -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ') || ports=""
    fi
    ports="${ports%% }"
    if [ -z "$ports" ]; then
        ports="22"
        SSH_PORTS_DETECTED=0
        log "⚠️ [警告] 無法偵測 sshd 監聽埠，假設為 22"
    else
        SSH_PORTS_DETECTED=1
    fi
    SSH_PORTS="$ports"
    log "📍 [偵測] SSH 服務監聽埠: $SSH_PORTS"
}

# 取得目前 SSH 連線的來源 IP（僅接受通過驗證的格式）
# 注意：sudo 預設 env_reset 會清除 SSH_CLIENT/SSH_CONNECTION，
# 因此必須保留 utmp (who am i) fallback，否則在 sudo 下永遠偵測不到
current_client_ip() {
    local ip=""
    if [ -n "${SSH_CLIENT:-}" ]; then
        ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
    elif [ -n "${SSH_CONNECTION:-}" ]; then
        ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    else
        ip=$(who am i 2>/dev/null | awk '{print $NF}' | tr -d '()' || true)
    fi
    if [ -n "$ip" ] && validate_ip "$ip"; then
        echo "$ip"
    fi
}

# 統一的 y/n 確認
confirm() {
    local prompt="$1" ans=""
    read -r -p "💬 [輸入] ${prompt} (y/n): " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ============================================================================
# 選單
# ============================================================================
CHOICE=""
show_menu() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║        伺服器安全加固工具 v${SCRIPT_VERSION} (UFW + Fail2Ban + Tailscale)  ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "請選擇部署配置："
    echo ""
    echo "  1️⃣  基礎防護   UFW 防火牆 + Fail2Ban 防暴力破解"
    echo "                （公網 SSH 保持開放，適合：無 VPN 需求的一般伺服器）"
    echo ""
    echo "  2️⃣  標準加固   基礎防護 + Tailscale VPN"
    echo "                （公網 SSH 保持開放，適合：想先熟悉 Tailscale 再收緊）"
    echo ""
    echo "  3️⃣  零信任隔離 標準加固 + SSH 僅限 Tailscale 內網連入"
    echo "                （先驗證 VPN 連線成功才封鎖公網，適合：生產環境）"
    echo ""
    echo "  q   離開"
    echo ""
    read -r -p "💬 [輸入] 請選擇 [1/2/3/q]: " CHOICE
}

# ============================================================================
# 步驟 1：基礎依賴
# ============================================================================
install_base_dependencies() {
    log "⚙️ [執行] 檢查並安裝基礎依賴 (UFW / curl)..."
    run_logged "apt-get update" apt-get update || true

    if ! command -v ufw &> /dev/null; then
        run_logged "安裝 UFW" apt-get install -y ufw || { log "❌ [錯誤] UFW 安裝失敗，請檢查網路狀態"; exit 1; }
    fi
    if ! command -v curl &> /dev/null; then
        run_logged "安裝 curl" apt-get install -y curl || { log "❌ [錯誤] curl 安裝失敗"; exit 1; }
    fi

    if ! systemctl is-active --quiet ssh && ! systemctl is-active --quiet sshd; then
        systemctl enable ssh > /dev/null 2>&1 || true
        systemctl start ssh > /dev/null 2>&1 || true
    fi
}

# ============================================================================
# 步驟 2：停用 IPv6（附加選項，含安全檢查）
#
# 安全設計：
#   - 若目前 SSH 連線走 IPv6，額外警告（停用會立刻斷線）
#   - 只有在「核心層停用確認生效」後才關閉 UFW 的 IPv6 過濾
#     （否則會出現：主機仍有 IPv6、防火牆卻不過濾 IPv6 的漏洞）
# ============================================================================
IPV6_DISABLED=0
maybe_disable_ipv6() {
    echo ""
    if ! confirm "是否停用 IPv6 以減少攻擊面？（純 IPv4 環境才建議）"; then
        log "⏭️ [跳過] 保持 IPv6 啟用；UFW 將同時過濾 IPv4/IPv6"
        return 0
    fi

    # 偵測目前連線是否經由 IPv6
    local client_ip
    client_ip=$(current_client_ip || true)
    if [[ "$client_ip" == *:* ]]; then
        echo ""
        echo "🚨 [高風險] 偵測到您目前的 SSH 連線來自 IPv6 位址 ($client_ip)！"
        echo "   停用 IPv6 會【立刻中斷】此連線，若無 IPv4 通道將無法連回。"
        if ! confirm "確定仍要停用 IPv6？"; then
            log "⏭️ [跳過] 已取消停用 IPv6"
            return 0
        fi
    elif [ -z "$client_ip" ]; then
        echo ""
        echo "⚠️ [警告] 無法偵測目前連線的來源 IP。"
        echo "   若你目前是透過 IPv6 連線，停用 IPv6 會【立刻中斷】連線。"
        if ! confirm "確認目前連線不是走 IPv6，繼續停用？"; then
            log "⏭️ [跳過] 已取消停用 IPv6"
            return 0
        fi
    fi

    log "⚙️ [執行] 停用 IPv6（核心層級）..."
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >> "$DEPLOY_LOG" 2>&1 || true

    # 驗證核心層是否真的生效（容器環境常失敗）
    if [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "1" ]]; then
        IPV6_DISABLED=1
        log "✅ [成功] 系統核心已停用 IPv6"
        # 核心層確認停用後，才讓 UFW 只管 IPv4
        if [ -f /etc/default/ufw ]; then
            sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw
            log "✅ [成功] UFW 已設定為僅管理 IPv4"
        fi
    else
        # 核心停用失敗：絕不關閉 UFW 的 IPv6 過濾，否則 IPv6 流量完全不設防
        rm -f /etc/sysctl.d/99-disable-ipv6.conf
        log "⚠️ [警告] 核心層停用 IPv6 未生效（常見於容器環境）"
        log "         已還原設定並保留 UFW 的 IPv6 過濾，確保 IPv6 流量仍受防火牆管制"
    fi
}

# ============================================================================
# 步驟 3：Tailscale 安裝與登入（配置 2/3）
# ============================================================================
install_tailscale() {
    echo ""
    log "⚙️ [執行] 安裝 Tailscale..."
    if command -v tailscale &> /dev/null; then
        log "✅ [成功] Tailscale 已安裝 ($(tailscale version 2>/dev/null | head -1 || echo '未知版本'))"
    else
        local tmp_install
        tmp_install=$(mktemp) || { log "❌ [錯誤] 無法建立臨時檔案"; exit 1; }
        # shellcheck disable=SC2064  # 蓄意在此展開路徑：mktemp 路徑此後不變
        trap "rm -f '$tmp_install'" EXIT
        if ! curl -fsSL -o "$tmp_install" --max-time 60 https://tailscale.com/install.sh; then
            log "❌ [錯誤] Tailscale 安裝腳本下載失敗，請檢查網路連線"
            exit 1
        fi
        if [ ! -s "$tmp_install" ]; then
            log "❌ [錯誤] 下載的安裝腳本為空"
            exit 1
        fi
        sh "$tmp_install" >> "$DEPLOY_LOG" 2>&1 || { log "❌ [錯誤] Tailscale 安裝失敗（詳見 $DEPLOY_LOG）"; exit 1; }
        rm -f "$tmp_install"
        trap - EXIT
        log "✅ [成功] Tailscale 已安裝"
    fi
    systemctl enable tailscaled > /dev/null 2>&1 || true
    systemctl start tailscaled > /dev/null 2>&1 || true
}

# 登入並「驗證取得內網 IP」。此函數成功返回 = Tailscale 確定可用。
# 零信任配置依賴這個保證：只有它成功，之後才會封鎖公網 SSH。
tailscale_login_and_verify() {
    echo ""
    echo "================================================================"
    echo " 🔐 請完成 Tailscale 認證"
    echo "================================================================"

    if tailscale ip -4 &> /dev/null; then
        log "✅ [成功] Tailscale 已登入 (IP: $(tailscale ip -4 2>/dev/null | head -1))"
        return 0
    fi

    log "⏳ [等待] 啟動 Tailscale 登入流程，請複製出現的網址到瀏覽器完成認證..."
    echo ""
    # 不吞錯誤：登入失敗必須讓部署停止（公網 SSH 未被封鎖，連線不受影響）
    if ! tailscale up; then
        log "❌ [錯誤] tailscale up 失敗，部署中止（公網 SSH 未被封鎖，連線不受影響）"
        log "         注意：若先前步驟已啟用 UFW，非 SSH 的服務埠此刻已被預設拒絕"
        exit 1
    fi

    # 再三確認真的拿到內網 IP
    local _try
    for _try in 1 2 3 4 5 6; do
        if tailscale ip -4 &> /dev/null; then
            log "✅ [成功] Tailscale 登入完成 (IP: $(tailscale ip -4 2>/dev/null | head -1))"
            tailscale set --auto-update > /dev/null 2>&1 || true
            return 0
        fi
        sleep 5
    done

    log "❌ [錯誤] 無法取得 Tailscale IP，部署中止（公網 SSH 未被封鎖，連線不受影響）"
    exit 1
}

# ============================================================================
# 步驟 4：Exit Node（附加選項）
# ============================================================================
maybe_setup_exit_node() {
    echo ""
    if ! confirm "是否將此機器設定為 Tailscale Exit Node（出口節點）？"; then
        log "⏭️ [跳過] 不設定 Exit Node"
        return 0
    fi

    log "⚙️ [執行] 啟用封包轉發..."
    {
        echo "net.ipv4.ip_forward = 1"
        echo "net.ipv4.conf.all.accept_redirects = 0"
        if [ "$IPV6_DISABLED" -eq 0 ]; then
            echo "net.ipv6.conf.all.forwarding = 1"
        fi
    } > /etc/sysctl.d/99-tailscale.conf
    sysctl -p /etc/sysctl.d/99-tailscale.conf >> "$DEPLOY_LOG" 2>&1 || true

    if tailscale set --advertise-exit-node=true 2>> "$DEPLOY_LOG"; then
        log "✅ [成功] 已宣告為 Exit Node"
        echo "🌍 [提示] 請至 https://login.tailscale.com/admin/machines"
        echo "         找到本機 →『...』選單 → 啟用『Use as exit node』"
    else
        log "⚠️ [警告] Exit Node 宣告失敗，可稍後手動執行: tailscale set --advertise-exit-node=true"
    fi
}

# ============================================================================
# 步驟 5：UFW 防火牆
# ============================================================================

# 開放模式（配置 1/2）：公網 SSH 開放 + 基本規則
setup_ufw_open() {
    local with_tailscale="$1"
    log "⚙️ [執行] 配置 UFW 防火牆（公網 SSH 開放）..."

    ufw default deny incoming >> "$DEPLOY_LOG" 2>&1 || true
    ufw default allow outgoing >> "$DEPLOY_LOG" 2>&1 || true

    # SSH 放行是 default deny 生效後唯一的入口，失敗必須中止（此時尚未 enable，安全）
    local p
    for p in $SSH_PORTS; do
        if run_logged "放行 SSH 埠 $p" ufw allow "$p/tcp"; then
            log "✅ [成功] SSH (port $p) 已開放"
        else
            log "❌ [錯誤] 無法放行 SSH 埠 $p，中止（防火牆尚未啟用，連線不受影響）"
            exit 1
        fi
    done

    if [ "$with_tailscale" = "yes" ]; then
        run_logged "放行 Tailscale P2P" ufw allow 41641/udp || true
        log "✅ [成功] Tailscale P2P (41641/udp) 已開放"
    fi

    if ! ufw --force enable >> "$DEPLOY_LOG" 2>&1; then
        log "❌ [錯誤] UFW 啟用失敗（詳見 $DEPLOY_LOG）"
        exit 1
    fi
    log "✅ [成功] UFW 已啟用"
}

# 零信任模式（配置 3）：只在 tailscale_login_and_verify 成功後呼叫。
# 出錯或最終驗證失敗會自動回滾（重新開放公網 SSH）。
ZEROTRUST_APPLIED=0
rollback_zerotrust() {
    log "🔄 [回滾] 正在還原公網 SSH 規則..."
    local p
    for p in $SSH_PORTS; do
        ufw allow "$p/tcp" > /dev/null 2>&1 || true
    done
    ufw reload > /dev/null 2>&1 || true
    log "✅ [回滾] 公網 SSH 已重新開放，請檢查後再嘗試零信任配置"
}

setup_ufw_zerotrust() {
    echo ""
    echo "================================================================"
    echo " ⚠️ [警告] 零信任配置將【封鎖所有公網 SSH 連線】！"
    echo "    Tailscale 已驗證連線成功，但仍請確認："
    echo "    1. 你可以開啟另一個終端機，用 Tailscale IP 測試連線"
    echo "    2. 主機商的 Console（救援終端）可用，以防萬一"
    echo "================================================================"
    if ! confirm "確認了解風險並繼續？"; then
        log "⏭️ [跳過] 已取消零信任配置（防火牆維持原狀）"
        return 1
    fi

    # 埠號偵測失敗時不可用猜測值封鎖：封錯埠會連 Tailscale 通道一併封死
    if [ "$SSH_PORTS_DETECTED" -ne 1 ]; then
        echo ""
        echo "⚠️ [警告] 先前無法自動偵測 sshd 監聽埠（目前假設: $SSH_PORTS）"
        local port_input=""
        read -r -p "💬 [輸入] 請輸入實際的 SSH 埠號（多個以空格分隔，直接 Enter 使用 $SSH_PORTS）: " port_input
        if [ -n "$port_input" ]; then
            local p_check
            for p_check in $port_input; do
                if ! [[ "$p_check" =~ ^[0-9]+$ ]] || [ "$p_check" -lt 1 ] || [ "$p_check" -gt 65535 ]; then
                    log "❌ [錯誤] 無效的埠號: $p_check，零信任配置中止（防火牆未變更）"
                    return 1
                fi
            done
            SSH_PORTS="$port_input"
            log "📍 [設定] 使用者指定 SSH 埠: $SSH_PORTS"
        fi
    fi

    log "⚙️ [執行] 配置 UFW（零信任模式）..."
    ufw default deny incoming >> "$DEPLOY_LOG" 2>&1 || true
    ufw default allow outgoing >> "$DEPLOY_LOG" 2>&1 || true

    local p
    for p in $SSH_PORTS; do
        # 清除既有的公網放行規則（含 limit 與各種寫法）
        ufw delete allow "$p/tcp" > /dev/null 2>&1 || true
        ufw delete allow "$p" > /dev/null 2>&1 || true
        ufw delete limit "$p/tcp" > /dev/null 2>&1 || true
        ufw delete limit "$p" > /dev/null 2>&1 || true
        # 僅限 Tailscale 介面連入（不使用 100.64.0.0/10 網段規則：
        # 該網段是 CGNAT 共用位址，在部分 ISP/雲端環境會意外放行外部鄰居）
        # 這是封鎖後唯一的 SSH 入口，失敗必須回滾，不可繼續
        if ! ufw allow in on tailscale0 to any port "$p" proto tcp >> "$DEPLOY_LOG" 2>&1; then
            log "❌ [錯誤] 無法建立 tailscale0 放行規則（埠 $p），執行回滾"
            rollback_zerotrust
            exit 1
        fi
    done
    # 應用程式設定檔與服務名稱寫法（如 ufw allow OpenSSH / allow ssh）也要清除
    ufw delete allow ssh > /dev/null 2>&1 || true
    ufw delete limit ssh > /dev/null 2>&1 || true
    ufw delete allow OpenSSH > /dev/null 2>&1 || true
    ufw delete limit OpenSSH > /dev/null 2>&1 || true
    log "✅ [成功] SSH ($SSH_PORTS) 已限制為僅限 tailscale0 介面連入"

    # 暫時放行目前連線來源，避免設定過程中斷線（結尾會提示移除指令）
    TEMP_ALLOW_IP=""
    local client_ip
    client_ip=$(current_client_ip || true)
    if [ -n "$client_ip" ]; then
        for p in $SSH_PORTS; do
            ufw allow from "$client_ip" to any port "$p" proto tcp >> "$DEPLOY_LOG" 2>&1 || true
        done
        TEMP_ALLOW_IP="$client_ip"
        log "✅ [成功] 已暫時放行目前連線 IP: $client_ip"
    else
        log "⚠️ [警告] 無法偵測目前連線來源 IP，不建立臨時放行規則"
        log "         請務必保持此視窗開啟，直到確認 Tailscale SSH 可登入"
    fi

    ufw allow 41641/udp >> "$DEPLOY_LOG" 2>&1 || true

    if ! ufw --force enable >> "$DEPLOY_LOG" 2>&1; then
        log "❌ [錯誤] UFW 啟用失敗，執行回滾"
        rollback_zerotrust
        exit 1
    fi

    # 最終驗證 1：Tailscale 後端必須處於 Running 且持有內網 IP，否則立刻回滾
    if ! tailscale ip -4 &> /dev/null || ! tailscale status --peers=false > /dev/null 2>&1; then
        log "❌ [錯誤] 封鎖後 Tailscale 狀態異常！立即回滾以避免鎖死"
        rollback_zerotrust
        exit 1
    fi

    # 最終驗證 2：檢查是否仍有其他規則對公網放行 SSH（埠號寫法或
    # OpenSSH/SSH 應用程式設定檔寫法，上面未能刪除的都要抓出來）
    local leftover
    leftover=$(ufw status | awk -v ports="$SSH_PORTS" -v tmpip="${TEMP_ALLOW_IP:-__none__}" '
        BEGIN { n = split(ports, plist, " ") }
        !/(ALLOW|LIMIT)/ { next }
        /on tailscale0/ || $0 ~ tmpip || /\(v6\)/ { next }
        /^(OpenSSH|SSH)[[:space:]]/ { print "   " $0; next }
        {
            for (i = 1; i <= n; i++) {
                if ($0 ~ ("(^|[ /:])" plist[i] "(/tcp)?([ ]|$)")) { print "   " $0; break }
            }
        }
    ' || true)
    if [ -n "$leftover" ]; then
        echo ""
        log "🚨 [注意] 偵測到以下規則可能仍對公網放行 SSH，請人工確認並移除："
        echo "$leftover"
        log "         檢視: sudo ufw status numbered ；刪除: sudo ufw delete <編號>"
    fi

    ZEROTRUST_APPLIED=1
    log "✅ [成功] UFW 零信任模式已生效"
}

# ============================================================================
# 步驟 6：Fail2Ban
# ============================================================================
setup_fail2ban() {
    echo ""
    echo "================================================================"
    echo " 🛡️ 配置 Fail2Ban SSH 防禦與白名單"
    echo "================================================================"

    local whitelist=("127.0.0.1/8" "::1")

    # 零信任模式下，能連到 sshd 的 100.64.0.0/10 來源必然已通過 tailscale0
    # （皆為已認證的 tailnet 節點）；不加白名單的話，Fail2Ban 唯一會封的
    # 就是管理者自己的裝置——5 次失敗即自我鎖死唯一通道 2 小時
    if [ "$ZEROTRUST_APPLIED" -eq 1 ]; then
        whitelist+=("100.64.0.0/10")
        log "ℹ️ [提示] 零信任模式：Tailscale 網段 (100.64.0.0/10) 已加入 Fail2Ban 白名單"
    fi

    local client_ip
    client_ip=$(current_client_ip || true)
    if [ -n "$client_ip" ]; then
        log "📍 [偵測] 您的 SSH 連線 IP: $client_ip"
        if confirm "是否將此 IP 加入 Fail2Ban 白名單？"; then
            whitelist+=("$client_ip")
            log "✅ [成功] 已添加: $client_ip"
        fi
    else
        log "⚠️ [警告] 無法偵測目前連線來源 IP，跳過自身 IP 白名單詢問"
        log "         如需白名單請在下一步手動輸入（誤封時可用 fail2ban-client 解除）"
    fi

    local extra_ips_input=""
    read -r -p "💬 [輸入] 其他白名單 IP/CIDR（逗號分隔，無則按 Enter）: " extra_ips_input
    if [ -n "$extra_ips_input" ]; then
        local extra_ips_array ip
        IFS=',' read -ra extra_ips_array <<< "$extra_ips_input"
        for ip in "${extra_ips_array[@]}"; do
            ip=$(echo "$ip" | xargs)
            [ -z "$ip" ] && continue
            if validate_ip "$ip"; then
                whitelist+=("$ip")
                log "✅ [成功] 已添加: $ip"
            else
                log "❌ [錯誤] 無效的 IP/CIDR 格式: $ip（已跳過）"
            fi
        done
    fi

    local whitelist_str
    whitelist_str="${whitelist[*]}"
    log "✅ [成功] Fail2Ban 白名單: $whitelist_str"

    log "⚙️ [執行] 安裝 Fail2Ban..."
    run_logged "安裝 Fail2Ban" apt-get install -y fail2ban || { log "❌ [錯誤] Fail2Ban 安裝失敗"; return 1; }

    if [ -f /etc/fail2ban/jail.local ]; then
        local backup_file
        backup_file="/etc/fail2ban/jail.local.bak.$(date +%Y%m%d_%H%M%S)"
        cp /etc/fail2ban/jail.local "$backup_file" || { log "❌ [錯誤] 既存配置備份失敗"; return 1; }
        log "✅ [成功] 已備份既存配置至: $backup_file"
    fi

    # banaction 依 UFW 實際狀態決定：UFW 未啟用時 ufw 動作是無效的空操作
    local banaction="iptables-multiport"
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        banaction="ufw"
    else
        log "⚠️ [警告] UFW 未啟用，Fail2Ban 改用 iptables-multiport 執行封鎖"
    fi

    local f2b_ports
    f2b_ports=$(echo "$SSH_PORTS" | tr ' ' ',')

    cat > /etc/fail2ban/jail.local <<EOF
# 由 server-security v${SCRIPT_VERSION} 產生
[DEFAULT]
banaction = ${banaction}
banaction_allports = ${banaction}
backend = systemd
ignoreip = ${whitelist_str}

[sshd]
enabled  = true
port     = ${f2b_ports}
filter   = sshd
backend  = systemd
maxretry = 5
findtime = 300
bantime  = 7200
EOF

    if ! fail2ban-client -t &> /dev/null; then
        log "❌ [錯誤] Fail2Ban 配置語法錯誤，請檢查 /etc/fail2ban/jail.local"
        return 1
    fi
    if ! systemctl restart fail2ban >> "$DEPLOY_LOG" 2>&1; then
        log "⚠️ [警告] Fail2Ban 重啟失敗，請手動執行: sudo systemctl restart fail2ban"
        return 1
    fi
    systemctl enable fail2ban > /dev/null 2>&1 || true
    log "✅ [成功] Fail2Ban 已啟動（5 次失敗/5 分鐘 → 封鎖 2 小時，埠: $f2b_ports）"
}

# ============================================================================
# 步驟 7：部署摘要
# ============================================================================
TEMP_ALLOW_IP=""
show_summary() {
    local mode="$1"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " ✨ 部署完成！"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 [摘要] 部署配置: $mode"
    echo ""
    echo "⚙️ [狀態] 服務運行狀態"
    if command -v tailscale &> /dev/null; then
        if systemctl is-active --quiet tailscaled; then
            echo "   - Tailscale: ✅ 運行中 (IP: $(tailscale ip -4 2>/dev/null | head -1 || echo 'N/A'))"
        else
            echo "   - Tailscale: ❌ 未運行"
        fi
    fi
    echo "   - Fail2Ban:  $(systemctl is-active --quiet fail2ban && echo '✅ 運行中' || echo '❌ 未運行')"
    echo "   - UFW:       $(ufw status 2>/dev/null | awk -F': ' '/^Status/{print $2}' || echo '未知')"
    echo "   - SSH 埠:    $SSH_PORTS"

    if [ "$ZEROTRUST_APPLIED" -eq 1 ]; then
        echo ""
        echo "🛡️ 【重要】公網 SSH 已封鎖，之後請一律使用 Tailscale IP 連線："
        echo "   ssh <使用者>@$(tailscale ip -4 2>/dev/null | head -1 || echo '<Tailscale IP>')"
        echo ""
        echo "⚠️ 【立即測試】請開啟『另一個』終端機，確認能以 Tailscale IP 登入。"
        echo "   確認成功前，請勿關閉目前這個視窗！"
        echo "   （測試前請先確認帳號密碼/金鑰無誤，連續登入失敗仍可能觸發 Fail2Ban）"
        if [ -n "$TEMP_ALLOW_IP" ]; then
            echo ""
            echo "🧹 測試成功後，請移除臨時放行規則（每個埠各一條）："
            local p
            for p in $SSH_PORTS; do
                echo "   sudo ufw delete allow from $TEMP_ALLOW_IP to any port $p proto tcp"
            done
        fi
    fi

    echo ""
    echo "🔍 [指令] 常用管理指令"
    echo "   - Fail2Ban 封鎖名單: sudo fail2ban-client status sshd"
    echo "   - 解除封鎖:          sudo fail2ban-client set sshd unbanip <IP>"
    echo "   - UFW 規則:          sudo ufw status numbered"
    echo "   - 部署日誌:          $DEPLOY_LOG"
    echo ""
    echo "🔐 [建議] 下一步可執行 SSH 金鑰強化（停用密碼登入）："
    echo "   sudo bash secure_ssh.sh"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ============================================================================
# 主流程
#
# 關鍵順序（零信任）：
#   依賴 → IPv6 選項 → Tailscale 安裝 → 登入並驗證成功 → Exit Node 選項
#   → 這時才封鎖公網 SSH → Fail2Ban → 摘要
# ============================================================================
main() {
    show_menu

    case "$CHOICE" in
        1)
            install_base_dependencies
            detect_ssh_ports
            maybe_disable_ipv6
            setup_ufw_open "no"
            setup_fail2ban || log "⚠️ [警告] Fail2Ban 配置失敗，已跳過"
            show_summary "基礎防護 (UFW + Fail2Ban)"
            ;;
        2)
            install_base_dependencies
            detect_ssh_ports
            maybe_disable_ipv6
            install_tailscale
            setup_ufw_open "yes"
            tailscale_login_and_verify
            maybe_setup_exit_node
            setup_fail2ban || log "⚠️ [警告] Fail2Ban 配置失敗，已跳過"
            show_summary "標準加固 (基礎防護 + Tailscale)"
            ;;
        3)
            install_base_dependencies
            detect_ssh_ports
            maybe_disable_ipv6
            install_tailscale
            tailscale_login_and_verify   # ← 必須先成功
            maybe_setup_exit_node
            setup_ufw_zerotrust || { log "⏭️ [跳過] 零信任配置未套用"; exit 1; }
            setup_fail2ban || log "⚠️ [警告] Fail2Ban 配置失敗，已跳過"
            show_summary "零信任隔離 (SSH 僅限 Tailscale)"
            ;;
        q|Q)
            log "✋ [中止] 已取消"
            exit 0
            ;;
        *)
            log "❌ [錯誤] 無效選項，退出"
            exit 1
            ;;
    esac
}

main
