#!/bin/bash

set -euo pipefail  # 嚴格模式

# ============================================================================
# Tailscale 部署工具 - 零信任安全加固版 (純 IPv4 環境)
# 功能：支援 5 種部署模式，支援 SSH 內網隔離，徹底封鎖 IPv6
# ============================================================================

# 權限檢查
if [[ $EUID -ne 0 ]]; then
   echo "❌ [錯誤] 請使用 sudo 執行此腳本"
   exit 1
fi

# 系統相容性検查
if ! command -v apt-get &> /dev/null; then
    echo "❌ [錯誤] 此腳本僅支援使用 apt 套件管理员的系統 (Debian/Ubuntu)"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ============================================================================
# 部署日誌與狀態追蹤
# ============================================================================
DEPLOY_LOG="/var/log/tailscale-deployment.log"

if [[ -w /var/log ]]; then
    DEPLOY_LOG="/var/log/tailscale-deployment.log"
elif [[ -w "$HOME" ]]; then
    DEPLOY_LOG="$HOME/.tailscale-deployment.log"
    echo "⚠️ [警告] /var/log 不可寶，改用: $DEPLOY_LOG"
else
    echo "❌ [錯誤] 無法寫入日誌檔案"
    exit 1
fi

touch "$DEPLOY_LOG" || { echo "❌ [錯誤] 無法建立日誌檔案"; exit 1; }
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 部署開始" >> "$DEPLOY_LOG"

# ============================================================================
# 徹底封殺 IPv6 (系統與防火牆層級)
# ============================================================================
disable_ipv6_completely() {
    echo "[$(date '+%H:%M:%S')] 執行 IPv6 封禁作業..."
    
    # 1. 系統核心層級禁用 IPv6
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf &> /dev/null || true
    echo "✅ [成功] 系統核心 (Kernel) 已徹底禁用 IPv6"

    # 2. 確保 UFW 安裝
    if ! command -v ufw &> /dev/null; then
        apt-get update &> /dev/null || true
        apt-get install -y ufw &> /dev/null || true
    fi

    # 3. UFW 層級禁用 IPv6
    if [[ -f /etc/default/ufw ]]; then
        sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw
        echo "✅ [成功] UFW 防火牆已配置為僅支援 IPv4"
    fi
}

# ============================================================================
# 互動菜單
# ============================================================================
show_menu() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║       Tailscale 部署工具 (Ubuntu/Debian 純 IPv4 零信任版)     ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "請選擇安裝模式："
    echo ""
    echo "  【標準模式】(允許所有來源的公網 IPv4 連線存取 SSH)"
    echo "  1️⃣  基本 Tailscale 版 (僅安裝，不設定防火牆)"
    echo "  2️⃣  安全強化版 (啟用 UFW 防火牆，保護基本通訊埠)"
    echo "  3️⃣  Exit Node 版 (啟用 UFW 防火牆 + 出口節點路由優化)"
    echo ""
    echo "  【🛡️ 零信任隔離模式】(極致安全：禁止公網 SSH，僅限 Tailscale IP 連入)"
    echo "  4️⃣  零信任安全版 (UFW 封鎖公網 SSH，僅限內網連線)"
    echo "  5️⃣  零信任 Exit Node 版 (僅限內網 SSH + 出口節點路由優化)"
    echo ""
    echo "  q   退出"
    echo ""
    read -p "✅ [成功] 請輸入選項 [1/2/3/4/5/q]: " CHOICE
}

# ============================================================================
# UFW 防火牆配置（允許公網 SSH）
# ============================================================================
setup_ufw_safe() {
    echo "[$(date '+%H:%M:%S')] 配置 UFW 防火牆（開放公網 SSH）..."
    
    ufw default deny incoming > /dev/null 2>&1 || true
    ufw default allow outgoing > /dev/null 2>&1 || true
    
    ufw allow 22/tcp > /dev/null 2>&1 || true
    echo "✅ [成功] SSH (port 22) 已開放 (所有 IPv4 來源)"
    
    ufw allow 41641/udp > /dev/null 2>&1 || true
    echo "✅ [成功] Tailscale P2P (port 41641 UDP) 已開放"
    
    ufw --force enable > /dev/null 2>&1 || { echo "❌ [錯誤] UFW 啟用失敗"; exit 1; }
    echo "✅ [成功] UFW 已啟用"
}

# ============================================================================
# UFW 防火牆配置（零信任：僅限 Tailscale SSH）
# ============================================================================
setup_ufw_strict() {
    echo ""
    echo "================================================================"
    echo " ⚠️ [警告] 零信任模式將會【封鎖】所有來自外網的 SSH 連線請求！"
    echo "    若您目前使用公網 IP 連線，稍後腳本結束或 Tailscale 未成功"
    echo "    啟動，您將無法連回此機器（必須透過 Tailscale IP 才能登入）。"
    echo "================================================================"
    read -p "✅ [成功] 確認了解風骨並繼續？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "⚡️ [跳過] 已取消配置"
        return 1  # ← 改用 return 1，允許主程式繼續清理
    fi

    echo "[$(date '+%H:%M:%S')] 配置 UFW 防火牆（零信任嚴格模式）..."
    
    # 設置默認規則（優先執行）
    ufw default deny incoming > /dev/null 2>&1 || true
    ufw default allow outgoing > /dev/null 2>&1 || true
    
    # 清除現有開放的公網 SSH 規則
    ufw delete allow 22/tcp >/dev/null 2>&1 || true
    ufw delete allow ssh >/dev/null 2>&1 || true
    ufw delete allow 22 >/dev/null 2>&1 || true

    # 僅允許來自 Tailscale 網卡與內網 IPv4 網段的 SSH 連線
    ufw allow in on tailscale0 to any port 22 > /dev/null 2>&1 || true
    ufw allow from 100.64.0.0/10 to any port 22 proto tcp > /dev/null 2>&1 || true
    echo "✅ [成功] SSH (port 22) 已限制為【僅限 Tailscale 100.64.0.0/10 網段】連入"
    
    # 允許 Tailscale 自身穿透通訊
    ufw allow 41641/udp > /dev/null 2>&1 || true
    echo "✅ [成功] Tailscale P2P (port 41641 UDP) 已開放"
    
    ufw --force enable > /dev/null 2>&1 || { echo "❌ [錯誤] UFW 啟用失敗"; exit 1; }
    echo "✅ [成功] UFW 已啟用 (零信任模式獨效)"
}

# ============================================================================
# Tailscale 基本安裝
# ============================================================================
install_tailscale_basic() {
    echo ""
    echo "[$(date '+%H:%M:%S')] 開始安裝 Tailscale..."
    
    if command -v tailscale &> /dev/null; then
        TAILSCALE_VER=$(tailscale version 2>/dev/null | head -1 || echo "未知版本")
        echo "⚠️ [警告] Tailscale 已安裝 (版本: $TAILSCALE_VER)"
        
        systemctl enable tailscaled > /dev/null 2>&1 || true
        systemctl start tailscaled > /dev/null 2>&1 || true
        
        read -p "✅ [成功] 是否重新安裝/更新？ (y/n): " do_reinstall
        if [[ "$do_reinstall" != "y" && "$do_reinstall" != "Y" ]]; then
            echo "⚡️ [跳過] 跳過 Tailscale 安裝程序"
            return
        fi
    fi
    
    apt-get update &> /dev/null || true
    apt-get install -y curl &> /dev/null || { echo "❌ 依賴安裝失敗"; exit 1; }
    
    echo "[$(date '+%H:%M:%S')] 下載 Tailscale 安裝腳本..."
    TEMP_INSTALL=$(mktemp) || { echo "❌ 無法建立臨時檔案"; exit 1; }
    trap "rm -f '$TEMP_INSTALL'" EXIT
    
    if ! curl -fsSL -o "$TEMP_INSTALL" --max-time 60 https://tailscale.com/install.sh; then
        echo "❌ Tailscale 下載失敗，請檢查網路連線"
        exit 1
    fi
    
    if [[ ! -s "$TEMP_INSTALL" ]]; then
        echo "❌ 下載的檔案為空或不完整"
        exit 1
    fi
    
    if ! sh "$TEMP_INSTALL" &> /dev/null; then
        echo "❌ Tailscale 安裝失敗"
        exit 1
    fi
    echo "✅ Tailscale 已安裝"
    
    systemctl enable tailscaled > /dev/null 2>&1 || true
    systemctl start tailscaled > /dev/null 2>&1 || true
    sleep 1
}

# ============================================================================
# Tailscale Exit Node 配置 (純 IPv4)
# ============================================================================
setup_tailscale_exit_node() {
    echo ""
    echo "[$(date '+%H:%M:%S')] 配置 Tailscale Exit Node 模式 (IPv4 專用)..."
    
    cat > /etc/sysctl.d/99-tailscale.conf <<'EOF'
# Tailscale Exit Node 核心轉發設定 (僅 IPv4)
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
EOF
    
    sysctl -p /etc/sysctl.d/99-tailscale.conf &> /dev/null || true
    echo "✅ [成功] IPv4 轉發已啟用"
    
    if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" == "1" ]]; then
        echo "✅ [成功] IPv4 轉發驗證成功"
    else
        echo "⚠️ [警告] IPv4 轉發可能在某些容器環境受限"
    fi
}

# ============================================================================
# Tailscale 登入與認證
# ============================================================================
do_tailscale_login() {
    local mode=$1  # "basic" 或 "exit-node"
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║           【重要】請完成 Tailscale 認證                       ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    
    if tailscale ip -4 &> /dev/null; then
        local current_ip=$(tailscale ip -4)
        echo "✅ [成功] Tailscale 已登入 (IP: $current_ip)"
        
        if [[ "$mode" == "exit-node" ]]; then
            echo ""
            read -p "✅ [成功] 是否確認啟用/覆寫 Exit Node 設定？此操作會重新設定網路 (y/n): " confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                echo "⚡️ [跳過] 跳過 Exit Node 設定"
                return
            fi
        else
            echo "⚡️ [跳過] 跳過重複登入"
            return
        fi
    fi
    
    echo "⏳ 正在啟動 Tailscale 登入流程..."
    echo "📱 一個登入網址即將出現，請複製到瀏覽器中完成認證"
    echo ""
    
    sleep 2
    
    if [[ "$mode" == "exit-node" ]]; then
        echo "⚡️ [反赫] 此模式將設定本機為 Exit Node..."
        tailscale up --advertise-exit-node --snat-subnet-routes=false 2>&1 || true
    else
        tailscale up 2>&1 || true
    fi
    
    echo ""
    echo "✅ [成功] 登入流程完成！"
    sleep 1
}

# ============================================================================
# 最終配置
# ============================================================================
finalize_setup() {
    local mode=$1
    
    echo ""
    echo "[$(date '+%H:%M:%S')] 執行最終配置..."
    
    tailscale set --auto-update > /dev/null 2>&1 || true
    echo "✅ [成功] 自動更新已啟用"
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 部署完成 (模式: $mode)" >> "$DEPLOY_LOG"
}

# ============================================================================
# 統計輸出
# ============================================================================
show_summary() {
    local mode=$1
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                  🎉 部署完成！                                ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "📋 部署摘要："
    echo "   安裝模式: $mode"
    echo ""
    
    echo "⚙️  服務狀態："
    if systemctl is-active --quiet tailscaled; then
        echo "   • Tailscale: ✅ [成功] 運行中 (IP: $(tailscale ip -4 2>/dev/null || echo "N/A"))"
    else
        echo "   • Tailscale: ❌ [錯誤] 未運行"
    fi
    
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        echo "   • UFW 防火牆: ✅ [成功] 啟用 (IPv6 已停用)"
    else
        echo "   • UFW 防火牆: ⚡️ [跳過] 未啟用"
    fi
    
    echo ""
    case "$mode" in
        "零信任安全版" | "零信任 Exit Node 版")
            echo "⚩️ [這严] 》重要提示】: 公網 SSH 已被封鎖!"
            echo "   未來請使用 Tailscale 內網 IP ($(tailscale ip -4 2>/dev/null)) 來連線此伺服器。"
            ;;
    esac
    
    if [[ "$mode" == *"Exit Node"* ]]; then
        echo ""
        echo "⚡️ [反赫] Exit Node 後續步驟（重要）:"
        echo "   1. 造訪 https://login.tailscale.com/admin/machines"
        echo "   2. 找到本機，點擊 '...' 選單"
        echo "   3. 啟用『Use as exit node』選項"
    fi
    
    echo ""
    echo "📝 部署日誌已保存: $DEPLOY_LOG"
    echo ""
}

# ============================================================================
# 主程式
# ============================================================================
main() {
    show_menu
    
    # 執行選項前，先徹底禁用 IPv6
    case "${CHOICE:-}" in
        1|2|3|4|5)
            disable_ipv6_completely
            ;;
    esac
    
    case "${CHOICE:-}" in
        1)
            install_tailscale_basic
            do_tailscale_login "basic"
            finalize_setup "基本 Tailscale"
            show_summary "基本 Tailscale"
            ;;
        2)
            install_tailscale_basic
            setup_ufw_safe
            do_tailscale_login "basic"
            finalize_setup "安全強化版"
            show_summary "安全強化版"
            ;;
        3)
            install_tailscale_basic
            setup_ufw_safe
            setup_tailscale_exit_node
            do_tailscale_login "exit-node"
            finalize_setup "Exit Node 版"
            show_summary "Exit Node 版"
            ;;
        4)
            install_tailscale_basic
            setup_ufw_strict || { echo "❌ UFW 配置已取消"; exit 1; }
            do_tailscale_login "basic"
            finalize_setup "零信任安全版"
            show_summary "零信任安全版"
            ;;
        5)
            install_tailscale_basic
            setup_ufw_strict || { echo "❌ UFW 配置已取消"; exit 1; }
            setup_tailscale_exit_node
            do_tailscale_login "exit-node"
            finalize_setup "零信任 Exit Node 版"
            show_summary "零信任 Exit Node 版"
            ;;
        q|Q)
            echo "✋ 已取消安裝"
            exit 0
            ;;
        *)
            echo "❌ [錯誤] 無效選項，退出"
            exit 1
            ;;
    esac
}

# 執行主程式
main