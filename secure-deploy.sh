#!/bin/bash

set -euo pipefail  # 嚴格模式：任何錯誤都會停止執行

# ============================================================================
# 伺服器安全加固整合工具 (Tailscale + UFW + Fail2Ban)
# 功能：支援 5 種 Tailscale 部署模式、SSH 零信任隔離、Fail2Ban 防暴力破解
# ============================================================================

# 確保以 root 權限執行
if [ "$EUID" -ne 0 ]; then 
  echo "❌ [錯誤] 請使用 sudo 執行此腳本"
  exit 1
fi

# 系統相容性檢查
if ! command -v apt-get &> /dev/null; then
    echo "❌ [錯誤] 此腳本僅支援使用 apt 套件管理員的系統 (Debian/Ubuntu)"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# 部署日誌檔案
DEPLOY_LOG="/var/log/server-secure-deployment.log"
touch "$DEPLOY_LOG" || { echo "❌ [錯誤] 無法建立日誌檔案"; exit 1; }
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 整合部署開始" >> "$DEPLOY_LOG"

# ============================================================================
# 1. IP 格式驗證函數
# ============================================================================
validate_ip() {
    local ip=$1
    local ipv4_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$"
    local ipv6_regex="^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?$"
    
    if [[ $ip =~ $ipv4_regex ]] || [[ $ip =~ $ipv6_regex ]]; then
        if [[ $ip =~ $ipv4_regex ]]; then
            local base_ip=$(echo "$ip" | cut -d/ -f1)
            IFS='.' read -ra octets <<< "$base_ip"
            for octet in "${octets[@]}"; do
                if ((octet > 255)); then return 1; fi
            done
        fi
        return 0
    fi
    return 1
}

# ============================================================================
# 2. 徹底封殺 IPv6 (系統與防火牆層級)
# ============================================================================
disable_ipv6_completely() {
    echo ""
    read -p "💬 [輸入] 是否徹底禁用 IPv6 以減少潛在攻擊面？ (y/n): " disable_ipv6_choice
    if [[ "$disable_ipv6_choice" =~ ^[Yy]$ ]]; then
        echo "⚙️ [執行] 執行 IPv6 封禁作業..."
        
        # 1. 系統核心層級禁用
        cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        if sysctl -p /etc/sysctl.d/99-disable-ipv6.conf &> /dev/null; then
            # 驗證是否成功
            if [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "1" ]]; then
                echo "✅ [成功] 系統核心 (Kernel) 已徹底禁用 IPv6"
            else
                echo "⚠️ [警告] IPv6 禁用可能未完全生效（在某些容器環境中可能無法禁用）"
            fi
        else
            echo "⚠️ [警告] IPv6 禁用規則寫入失敗，已跳過此步驟"
        fi

        # 2. UFW 層級禁用
        if [[ -f /etc/default/ufw ]]; then
            sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw
            echo "✅ [成功] UFW 防火牆已配置為僅支援 IPv4"
        fi
    else
        echo "⏭️ [跳過] 保持 IPv6 啟用狀態"
    fi
}

# ============================================================================
# 3. 互動菜單 (Tailscale 模式選擇)
# ============================================================================
show_menu() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║       伺服器安全加固工具 (Tailscale + UFW + Fail2Ban)         ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "請選擇安裝模式："
    echo ""
    echo "  【標準模式】(允許所有來源的公網 IPv4 連線存取 SSH + Fail2Ban 保護)"
    echo "  1️⃣  基本 Tailscale 版 (僅安裝，不設定防火牆，安裝 Fail2Ban)"
    echo "  2️⃣  安全強化版 (啟用 UFW 防火牆，保護基本通訊埠 + Fail2Ban)"
    echo "  3️⃣  Exit Node 版 (啟用 UFW 防火牆 + 出口節點路由優化 + Fail2Ban)"
    echo ""
    echo "  【🛡️ 零信任隔離模式】(極致安全：禁止公網 SSH，僅限 Tailscale 連入)"
    echo "  4️⃣  零信任安全版 (UFW 封鎖公網 SSH，僅限內網連線 + 內網 Fail2Ban)"
    echo "  5️⃣  零信任 Exit Node 版 (僅限內網 SSH + 出口節點路由優化 + 內網 Fail2Ban)"
    echo ""
    echo "  q   退出"
    echo ""
    read -p "💬 [輸入] 請選擇選項 [1/2/3/4/5/q]: " CHOICE
}

# ============================================================================
# 4. 依賴安裝與基礎檢查
# ============================================================================
install_base_dependencies() {
    echo "⚙️ [執行] 檢查並安裝基礎依賴 (UFW, SSH)..."
    apt-get update &> /dev/null || true
    
    if ! command -v ufw &> /dev/null; then
        apt-get install -y ufw &> /dev/null || { echo "❌ [錯誤] UFW 安裝失敗，請檢查網路狀態"; exit 1; }
    fi

    if ! systemctl is-active --quiet ssh; then
        systemctl enable ssh > /dev/null 2>&1 || true
        systemctl start ssh > /dev/null 2>&1 || true
    fi
}

# ============================================================================
# 5. UFW 防火牆配置
# ============================================================================
setup_ufw_safe() {
    echo "⚙️ [執行] 配置 UFW 防火牆（開放公網 SSH）..."
    
    # 【重要】先設置默認規則（避免規則衝突）
    ufw default deny incoming > /dev/null 2>&1 || true
    ufw default allow outgoing > /dev/null 2>&1 || true
    
    # 再設置允許規則
    ufw allow 22/tcp > /dev/null 2>&1 || true
    echo "✅ [成功] SSH (port 22) 已開放 (所有來源)"
    
    ufw allow 41641/udp > /dev/null 2>&1 || true
    echo "✅ [成功] Tailscale P2P (port 41641 UDP) 已開放"
    
    ufw --force enable > /dev/null 2>&1 || { echo "❌ [錯誤] UFW 啟用失敗"; exit 1; }
    echo "✅ [成功] UFW 已啟用"
}

setup_ufw_strict() {
    echo ""
    echo "================================================================"
    echo " ⚠️ [警告] 零信任模式將會【封鎖】所有來自外網的 SSH 連線請求！"
    echo "    若您目前使用公網 IP 連線，稍後腳本結束或 Tailscale 未成功"
    echo "    啟動，您將無法連回此機器（必須透過 Tailscale IP 才能登入）。"
    echo "================================================================"
    read -p "💬 [輸入] 確認了解風險並繼續？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "⏭️ [跳過] 已取消配置"
        return 1
    fi

    echo "⚙️ [執行] 配置 UFW 防火牆（零信任嚴格模式）..."
    ufw default deny incoming > /dev/null 2>&1 || true
    ufw default allow outgoing > /dev/null 2>&1 || true
    
    # 清除現有開放的公網 SSH 規則
    ufw delete allow 22/tcp >/dev/null 2>&1 || true
    ufw delete allow ssh >/dev/null 2>&1 || true

    # 【重要】保命機制：嘗試從多個途徑抓取當前 IP，避免被 sudo 洗掉變數
    local CURRENT_SSH_IP=""
    if [ -n "${SSH_CLIENT:-}" ]; then
        CURRENT_SSH_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    else
        CURRENT_SSH_IP=$(who am i 2>/dev/null | awk '{print $NF}' | tr -d '()')
    fi

    if [ -n "$CURRENT_SSH_IP" ] && validate_ip "$CURRENT_SSH_IP"; then
        ufw allow from "$CURRENT_SSH_IP" to any port 22 proto tcp > /dev/null 2>&1 || true
        echo "✅ [成功] 已暫時放行當前連線 IP: $CURRENT_SSH_IP"
        echo "ℹ️ [提示] Tailscale 登入成功後，建議執行以下指令移除臨時規則："
        echo "         sudo ufw delete allow from $CURRENT_SSH_IP to any port 22 proto tcp"
    fi

    ufw allow in on tailscale0 to any port 22 > /dev/null 2>&1 || true
    ufw allow from 100.64.0.0/10 to any port 22 proto tcp > /dev/null 2>&1 || true
    echo "✅ [成功] SSH (port 22) 已限制為【僅限 Tailscale 網段】連入"
    
    ufw allow 41641/udp > /dev/null 2>&1 || true
    ufw --force enable > /dev/null 2>&1 || { echo "❌ [錯誤] UFW 啟用失敗"; exit 1; }
    echo "✅ [成功] UFW 已啟用 (零信任模式生效)"
}

# ============================================================================
# 6. Tailscale 安裝與配置
# ============================================================================
install_tailscale_basic() {
    echo ""
    echo "⚙️ [執行] 開始安裝 Tailscale..."
    if command -v tailscale &> /dev/null; then
        TAILSCALE_VER=$(tailscale version 2>/dev/null | head -1 || echo "未知版本")
        echo "✅ [成功] Tailscale 已安裝 (版本: $TAILSCALE_VER)"
        systemctl enable tailscaled > /dev/null 2>&1 || true
        systemctl start tailscaled > /dev/null 2>&1 || true
        return
    fi
    apt-get install -y curl &> /dev/null || true
    TEMP_INSTALL=$(mktemp) || { echo "❌ [錯誤] 無法建立臨時檔案"; exit 1; }
    trap "rm -f '$TEMP_INSTALL'" EXIT
    if ! curl -fsSL -o "$TEMP_INSTALL" --max-time 60 https://tailscale.com/install.sh; then
        echo "❌ [錯誤] Tailscale 下載失敗，請檢查網路連線"; exit 1;
    fi
    sh "$TEMP_INSTALL" &> /dev/null || { echo "❌ [錯誤] Tailscale 安裝失敗"; exit 1; }
    echo "✅ [成功] Tailscale 已安裝"
    systemctl enable tailscaled > /dev/null 2>&1 || true
    systemctl start tailscaled > /dev/null 2>&1 || true
    sleep 1
}

setup_tailscale_exit_node() {
    echo "⚙️ [執行] 配置 Tailscale Exit Node 模式 (IPv4 專用)..."
    cat > /etc/sysctl.d/99-tailscale.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
EOF
    sysctl -p /etc/sysctl.d/99-tailscale.conf &> /dev/null || true
    echo "✅ [成功] IPv4 轉發已啟用"
}

do_tailscale_login() {
    local mode=$1
    echo ""
    echo "================================================================"
    echo " 🔐 [安全] 請完成 Tailscale 認證"
    echo "================================================================"
    echo ""
    if tailscale ip -4 &> /dev/null; then
        echo "✅ [成功] Tailscale 已登入 (IP: $(tailscale ip -4))"
        if [[ "$mode" == "exit-node" ]]; then
            tailscale up --advertise-exit-node --snat-subnet-routes=false 2>&1 || true
        fi
        return
    fi
    
    echo "⏳ [等待] 正在啟動 Tailscale 登入流程..."
    echo "📱 [操作] 請複製下方網址到瀏覽器中完成認證："
    echo ""
    sleep 2
    if [[ "$mode" == "exit-node" ]]; then
        tailscale up --advertise-exit-node --snat-subnet-routes=false 2>&1 || true
    else
        tailscale up 2>&1 || true
    fi
    echo "✅ [成功] 登入流程完成！"
    tailscale set --auto-update > /dev/null 2>&1 || true
}

# ============================================================================
# 7. Fail2Ban 防禦機制建置
# ============================================================================
setup_fail2ban() {
    echo ""
    echo "================================================================"
    echo " 🛡️ [安全] 配置 Fail2Ban SSH 防禦與白名單"
    echo "================================================================"
    
    WHITELIST_ARRAY=("127.0.0.1/8" "100.64.0.0/10" "::1") # 預設放行本機與 Tailscale 網段
    
    local CURRENT_SSH_IP=""
    if [ -n "${SSH_CLIENT:-}" ]; then
        CURRENT_SSH_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    else
        CURRENT_SSH_IP=$(who am i 2>/dev/null | awk '{print $NF}' | tr -d '()')
    fi

    if [ -n "$CURRENT_SSH_IP" ] && validate_ip "$CURRENT_SSH_IP"; then
        echo "📍 [偵測] 偵測到您的 SSH 連線 IP: $CURRENT_SSH_IP"
        read -p "💬 [輸入] 是否將此 IP 加入白名單？ (y/n): " confirm_self
        if [[ "$confirm_self" =~ ^[Yy]$ ]]; then
            WHITELIST_ARRAY+=("$CURRENT_SSH_IP")
            echo "✅ [成功] 已添加: $CURRENT_SSH_IP"
        fi
    fi

    read -p "💬 [輸入] 請輸入其他要加入白名單的 IP/CIDR (用逗號隔開，無則按 Enter): " extra_ips_input
    if [ -n "$extra_ips_input" ]; then
        IFS=',' read -ra extra_ips_array <<< "$extra_ips_input"
        for ip in "${extra_ips_array[@]}"; do
            ip=$(echo "$ip" | xargs)
            if [ -n "$ip" ]; then
                if validate_ip "$ip"; then
                    WHITELIST_ARRAY+=("$ip")
                    echo "✅ [成功] 已添加: $ip"
                else
                    echo "❌ [錯誤] 無效的 IP 格式: $ip (已跳過)"
                fi
            fi
        done
    fi

    WHITELIST=$(IFS=' ' ; echo "${WHITELIST_ARRAY[*]}")
    echo "✅ [成功] 最終白名單: $WHITELIST"

    echo "⚙️ [執行] 安裝 Fail2Ban..."
    apt-get install -y fail2ban &> /dev/null || { echo "❌ [錯誤] Fail2Ban 安裝失敗"; return 1; }

    # 【重要】備份既存配置
    if [ -f /etc/fail2ban/jail.local ]; then
        BACKUP_FILE="/etc/fail2ban/jail.local.bak.$(date +%Y%m%d_%H%M%S)"
        if cp /etc/fail2ban/jail.local "$BACKUP_FILE"; then
            echo "✅ [成功] 已備份既存配置至: $BACKUP_FILE"
        else
            echo "❌ [錯誤] Fail2Ban 配置備份失敗"
            return 1
        fi
    fi

    # 建立最佳化的 jail.local 配置
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
banaction = ufw
banaction_allports = ufw
backend = systemd
ignoreip = $WHITELIST

[sshd]
enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
maxretry = 5
findtime = 300
bantime  = 7200
EOF

    # 驗證配置語法
    if ! fail2ban-client -t &> /dev/null; then
        echo "❌ [錯誤] Fail2Ban 配置語法錯誤"
        return 1
    fi

    if ! systemctl restart fail2ban > /dev/null 2>&1; then
        echo "⚠️ [警告] Fail2Ban 重啟失敗，請手動執行: sudo systemctl restart fail2ban"
        return 1
    fi

    systemctl enable fail2ban > /dev/null 2>&1 || true
    echo "✅ [成功] Fail2Ban 已配置完成並啟動 (5次失敗封鎖2小時)"
}

# ============================================================================
# 8. 最終配置與摘要
# ============================================================================
show_summary() {
    local mode=$1
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " ✨ 部署與加固完成！"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 [摘要] 部署狀態"
    echo "   - 安裝模式: $mode"
    echo ""
    echo "⚙️ [狀態] 服務運行狀態"
    if systemctl is-active --quiet tailscaled; then
        echo "   - Tailscale: ✅ [運行中] (IP: $(tailscale ip -4 2>/dev/null || echo "N/A"))"
    else
        echo "   - Tailscale: ❌ [未運行]"
    fi
    echo "   - Fail2Ban:  $(systemctl is-active fail2ban 2>/dev/null >/dev/null && echo '✅ [運行中]' || echo '❌ [未安裝/未運行]')"
    echo "   - UFW 防火牆:  $(ufw status | grep Status | awk '{print $2}')"
    echo "   - SSH 服務:  $(systemctl is-active ssh >/dev/null && echo '✅ [運行中]' || echo '❌ [未運行]')"
    
    echo ""
    case "$mode" in
        "零信任安全版" | "零信任 Exit Node 版")
            echo "🛡️ [安全] 【重要提示】: 公網 SSH 已被封鎖！"
            echo "   未來請務必使用 Tailscale 內網 IP ($(tailscale ip -4 2>/dev/null)) 連線此伺服器。"
            ;;
    esac
    
    if [[ "$mode" == *"Exit Node"* ]]; then
        echo ""
        echo "🌍 [網路] Exit Node 後續步驟（重要）："
        echo "   1. 造訪 https://login.tailscale.com/admin/machines"
        echo "   2. 找到本機，點擊 '...' 選單"
        echo "   3. 啟用『Use as exit node』選項"
    fi
    
    echo ""
    echo "🔍 [指令] 常用防護管理指令"
    echo "   - 查看 Fail2Ban 封鎖名單: sudo fail2ban-client status sshd"
    echo "   - 解除特定 IP 封鎖: sudo fail2ban-client set sshd unbanip <IP>"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ============================================================================
# 主程式
# ============================================================================
main() {
    show_menu
    
    case "${CHOICE:-}" in
        1|2|3|4|5)
            disable_ipv6_completely
            install_base_dependencies
            ;;
        q|Q) echo "✋ [中止] 已取消安裝"; exit 0 ;;
        *) echo "❌ [錯誤] 無效選項，退出"; exit 1 ;;
    esac
    
    case "${CHOICE:-}" in
        1)
            install_tailscale_basic
            do_tailscale_login "basic"
            setup_fail2ban || { echo "⚠️ [警告] Fail2Ban 配置失敗，已跳過"; }
            show_summary "基本 Tailscale (含 Fail2Ban)"
            ;;
        2)
            install_tailscale_basic
            setup_ufw_safe
            do_tailscale_login "basic"
            setup_fail2ban || { echo "⚠️ [警告] Fail2Ban 配置失敗，已跳過"; }
            show_summary "安全強化版"
            ;;
        3)
            install_tailscale_basic
            setup_ufw_safe
            setup_tailscale_exit_node
            do_tailscale_login "exit-node"
            setup_fail2ban || { echo "⚠️ [警告] Fail2Ban 配置失敗，已跳過"; }
            show_summary "Exit Node 版"
            ;;
        4)
            install_tailscale_basic
            setup_ufw_strict || { echo "❌ [錯誤] UFW 配置已取消"; exit 1; }
            do_tailscale_login "basic"
            setup_fail2ban || { echo "⚠️ [警告] Fail2Ban 配置失敗，已跳過"; }
            show_summary "零信任安全版"
            ;;
        5)
            install_tailscale_basic
            setup_ufw_strict || { echo "❌ [錯誤] UFW 配置已取消"; exit 1; }
            setup_tailscale_exit_node
            do_tailscale_login "exit-node"
            setup_fail2ban || { echo "⚠️ [警告] Fail2Ban 配置失敗，已跳過"; }
            show_summary "零信任 Exit Node 版"
            ;;
    esac
}

main