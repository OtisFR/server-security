#!/bin/bash

set -euo pipefail  # 嚴格模式：任何錯誤都會停止執行

# 確保以 root 權限執行
if [ "$EUID" -ne 0 ]; then
  echo "❌ [錯誤] 請使用 sudo 執行此腳本"
  exit 1
fi

echo "🔐 開始安裝與設定 Fail2Ban + UFW (Ubuntu 24.04 安全加固版)..."
echo ""

# 部署日誌檔案
DEPLOY_LOG="/var/log/fail2ban-deployment.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 部署開始" >> "$DEPLOY_LOG"

# ============================================================================
# 0. 服務依賴檢查
# ============================================================================
echo "[0/7] 檢查服務依賴..."

if ! systemctl is-enabled ssh &> /dev/null; then
    echo "⚠️ [警告] SSH 服務未啟用。正在啟用..."
    systemctl enable ssh
fi

if ! systemctl is-active --quiet ssh; then
    echo "⚠️ [警告] SSH 服務未運行。正在啟動..."
    systemctl start ssh || { echo "❌ [錯誤] SSH 服務啟動失敗"; exit 1; }
fi

echo "✅ [成功] SSH 服務已驗證"
echo ""

# ============================================================================
# 1. IP 格式驗證函數
# ============================================================================
validate_ip() {
    local ip=$1
    local ipv4_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$"
    local ipv6_regex="^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?$"

    if [[ $ip =~ $ipv4_regex ]] || [[ $ip =~ $ipv6_regex ]]; then
        # 驗證 IPv4 段
        if [[ $ip =~ $ipv4_regex ]]; then
            local base_ip=$(echo "$ip" | cut -d/ -f1)
            IFS='.' read -ra octets <<< "$base_ip"
            for octet in "${octets[@]}"; do
                if ((octet > 255)); then
                    return 1
                fi
            done
        fi
        return 0
    fi
    return 1
}

# ============================================================================
# 2. 檢查系統依賴 (含自動安裝與防斷線)
# ============================================================================
echo "[1/7] 檢查系統環境..."

# 檢查並自動安裝 UFW
if ! command -v ufw &> /dev/null; then
  echo "⚠️ [警告] UFW 未安裝。正在為您自動安裝..."
  apt update &> /dev/null || true
  apt install -y ufw &> /dev/null || { echo "❌ [錯誤] UFW 安裝失敗"; exit 1; }
  echo "✅ [成功] UFW 已成功安裝"
fi

if ! ufw status | grep -q "Status: active"; then
  echo "⚠️ [警告] UFW 未啟用。正在配置並啟動 UFW..."
  # 【保命機制】先放行 SSH，避免啟用 UFW 瞬間把自己踢下線
  ufw allow ssh > /dev/null
  # 加上 --force 跳過互動式確認，避免腳本卡死
  ufw --force enable || { echo "❌ [錯誤] UFW 啟用失敗"; exit 1; }
fi

echo "✅ [成功] UFW 已驗證並啟用"
echo ""

# ============================================================================
# 3. 詢問並設定 IPv6 狀態
# ============================================================================
echo "[2/7] 網路協定安全設定..."

read -p "💬 [輸入] 是否禁用 IPv6 以減少潛在攻擊面？ (y/n): " disable_ipv6_choice
if [[ "$disable_ipv6_choice" == "y" || "$disable_ipv6_choice" == "Y" ]]; then
    echo "⚙️ 正在寫入 IPv6 禁用規則..."
    cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
# 系統安全加固：禁用 IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    # 套用設定
    if sysctl -p /etc/sysctl.d/99-disable-ipv6.conf &> /dev/null; then
        # 驗證是否成功
        if [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "1" ]]; then
            echo "✅ IPv6 已成功禁用"
        else
            echo "⚠️ IPv6 禁用可能未完全生效（在某些容器環境中可能無法禁用），請稍後檢查"
        fi
    else
        echo "⚠️ IPv6 禁用規則寫入失敗，已跳過此步驟"
    fi
else
    echo "⏭️ 保持 IPv6 啟用狀態 (跳過)"
fi
echo ""

# ============================================================================
# 4. 偵測白名單 IP
# ============================================================================
echo "[3/7] 配置白名單..."

WHITELIST_ARRAY=("127.0.0.1/8" "::1")

# 嘗試偵測 SSH 連線 IP
if [ -n "${SSH_CLIENT:-}" ]; then
    CURRENT_SSH_IP=$(echo "${SSH_CLIENT:-}" | awk '{print $1}')
    if [ -n "$CURRENT_SSH_IP" ]; then
        echo "📍 偵測到您的 SSH 連線 IP: $CURRENT_SSH_IP"
        read -p "💬 [輸入] 是否將此 IP 加入白名單？ (y/n): " confirm_self
        if [[ "$confirm_self" == "y" || "$confirm_self" == "Y" ]]; then
            WHITELIST_ARRAY+=("$CURRENT_SSH_IP")
            echo "✅ 已添加: $CURRENT_SSH_IP"
        fi
    fi
else
    echo "⚠️ [警告] 無法偵測當前 SSH 連線 (可能在本地或非標準終端執行)"
fi

# 讀取額外白名單
read -p "💬 [輸入] 請輸入其他要加入白名單的 IP/CIDR (多個請用逗號隔開，無則按 Enter): " extra_ips_input

if [ -n "$extra_ips_input" ]; then
    # 分割並驗證每個 IP
    IFS=',' read -ra extra_ips_array <<< "$extra_ips_input"
    for ip in "${extra_ips_array[@]}"; do
        ip=$(echo "$ip" | xargs)  # 移除前後空白
        if [ -n "$ip" ]; then
            if validate_ip "$ip"; then
                WHITELIST_ARRAY+=("$ip")
                echo "✅ 已添加: $ip"
            else
                echo "❌ [錯誤] 無效的 IP 格式: $ip (已跳過)"
            fi
        fi
    done
fi

# 轉換為 Fail2Ban 官方推薦格式 (空格分隔)
WHITELIST=$(IFS=' ' ; echo "${WHITELIST_ARRAY[*]}")
echo "✅ [成功] 最終白名單: $WHITELIST"
echo ""

# ============================================================================
# 5. 安裝 Fail2Ban
# ============================================================================
echo "[4/7] 安裝 Fail2Ban..."
if ! apt update &> /dev/null; then
    echo "❌ [錯誤] apt update 失敗"
    exit 1
fi

if ! apt install -y fail2ban &> /dev/null; then
    echo "❌ [錯誤] Fail2Ban 安裝失敗"
    exit 1
fi

echo "✅ [成功] Fail2Ban 已安裝"

# 備份既存配置
if [ -f /etc/fail2ban/jail.local ]; then
    BACKUP_FILE="/etc/fail2ban/jail.local.bak.$(date +%Y%m%d_%H%M%S)"
    if cp /etc/fail2ban/jail.local "$BACKUP_FILE"; then
        echo "✅ [成功] 已備份既存配置至: $BACKUP_FILE"
    else
        echo "❌ [錯誤] 備份失敗"
        exit 1
    fi
fi
echo ""

# ============================================================================
# 6. 建立最佳化的 jail.local 配置
# ============================================================================
echo "[5/7] 建立 Fail2Ban 配置..."

# 注意：此處使用 EOF (無單引號) 讓 Bash 可以直接展開 $WHITELIST 變數
cat > /etc/fail2ban/jail.local <<EOF
# Fail2Ban 配置檔 - Ubuntu 24.04 最佳實務
# ============================================================================

[DEFAULT]
# 基本設定
banaction = ufw
banaction_allports = ufw
backend = systemd
ignoreip = $WHITELIST

# ============================================================================
# SSH 防禦規則 - 單一智能規則
# ============================================================================
# 策略：5 分鐘內失敗 5 次 → 自動封鎖 2 小時
#
# 邏輯說明：
# - 標準掃描工具通常嘗試 3-5 次就會放棄
# - 2 小時足以阻擋自動化掃描
# - 防止誤傷：調整 maxretry 或手動解除封鎖
#
[sshd]
enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
maxretry = 5
findtime = 300
bantime  = 7200
EOF

echo "✅ [成功] 配置檔已建立"
echo ""

# ============================================================================
# 7. 重啟及驗證服務
# ============================================================================
echo "[6/7] 重啟並驗證服務..."

# 檢查配置語法
if ! fail2ban-client -t &> /dev/null; then
    echo "❌ [錯誤] Fail2Ban 配置語法錯誤"
    echo "請檢查: /etc/fail2ban/jail.local"
    exit 1
fi

# 重啟服務
if ! systemctl restart fail2ban; then
    echo "❌ [錯誤] Fail2Ban 服務重啟失敗"
    exit 1
fi

# 驗證服務狀態
if ! systemctl is-active --quiet fail2ban; then
    echo "❌ [錯誤] Fail2Ban 服務未成功啟動"
    exit 1
fi

echo "✅ [成功] Fail2Ban 服務已啟動"

# 啟用 Fail2Ban 開機自啟
echo "[7/7] 配置開機自啟..."
if ! systemctl enable fail2ban &> /dev/null; then
    echo "❌ [錯誤] 開機自啟配置失敗"
    exit 1
fi

echo "✅ [成功] Fail2Ban 已設為開機自啟"
echo ""

# 記錄部署完成
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 部署完成 (白名單: $WHITELIST)" >> "$DEPLOY_LOG"

# ============================================================================
# 8. 輸出配置摘要與管理指令
# ============================================================================
# 檢查 IPv6 目前核心狀態以供摘要顯示
IPV6_STATUS="啟用"
if [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "1" ]]; then
    IPV6_STATUS="禁用"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ 安全強化完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 強化配置摘要："
echo "   🛡️  防止暴力破解："
echo "       - 5 分鐘內失敗 5 次 → 自動封鎖 2 小時"
echo ""
echo "   🔒 白名單 IP:"
echo "       - $WHITELIST"
echo ""
echo "   ⚙️  服務狀態："
echo "       - SSH 服務: $(systemctl is-active ssh)"
echo "       - Fail2Ban 服務: $(systemctl is-active fail2ban)"
echo "       - UFW 狀態: $(ufw status | grep Status)"
echo "       - IPv6 狀態: $IPV6_STATUS"
echo "       - 開機自啟: $(systemctl is-enabled fail2ban)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 常用管理指令："
echo ""
echo "   查看所有被封鎖的 IP:"
echo "     sudo fail2ban-client status sshd"
echo ""
echo "   手動解除特定 IP 的封鎖:"
echo "     sudo fail2ban-client set sshd unbanip <IP>"
echo ""
echo "   臨時加入白名單 (立即生效，但重啟服務後失效):"
echo "     sudo fail2ban-client set sshd addignoreip <IP>"
echo ""
echo "   永久加入白名單:"
echo "     1. 編輯設定檔: sudo nano /etc/fail2ban/jail.local"
echo "     2. 在 [DEFAULT] 區塊的 ignoreip 後面加上 IP (用空格隔開)"
echo "     3. 重啟服務: sudo systemctl restart fail2ban"
echo ""
echo ""
echo "   檢查 UFW 規則 (由 Fail2Ban 建立):"
echo "     sudo ufw status numbered"
echo ""
echo "   查看部署日誌:"
echo "     sudo tail -f '$DEPLOY_LOG'"
echo ""
echo "   還原 IPv6 設定 (若有禁用):"
echo "     sudo rm /etc/sysctl.d/99-disable-ipv6.conf && sudo sysctl --system"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ [成功] 配置完成！系統已安全加固、設為開機自啟、並已記錄部署日誌。"