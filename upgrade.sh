#!/bin/bash

set -euo pipefail

# ============================================================================
# 自動升級指令碼 - 伺服器安全加固工具
# 功能：從 GitHub 檢查並下載最新版本，安全驗證後升級
# ============================================================================

# 確保以 root 權限執行
if [ "$EUID" -ne 0 ]; then
  echo "❌ [錯誤] 請使用 sudo 執行此指令碼"
  exit 1
fi

# 配置
REPO_URL="https://raw.githubusercontent.com/OtisFR/server-security/main"
SCRIPT_DIR="/opt/server-security"
SCRIPTS=("secure-deploy.sh" "setup_ssh_jail.sh" "tailscale-installer.sh")
BACKUP_DIR="/opt/server-security/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "================================================================"
echo " 🔄 伺服器安全加固工具 - 自動升級"
echo "================================================================"
echo ""

# ============================================================================
# 1. 檢查本地版本
# ============================================================================
if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    LOCAL_VERSION=$(cat "$SCRIPT_DIR/VERSION")
    echo "📍 [偵測] 本地版本: $LOCAL_VERSION"
else
    LOCAL_VERSION="0.0.0"
    echo "⚠️ [警告] 未偵測到本地版本，假設為 0.0.0"
fi

# ============================================================================
# 2. 從 GitHub 獲取最新版本
# ============================================================================
echo "⏳ [等待] 正在檢查最新版本..."
REMOTE_VERSION=$(curl -fsSL "$REPO_URL/VERSION" 2>/dev/null || echo "0.0.0")

if [[ -z "$REMOTE_VERSION" ]]; then
    echo "❌ [錯誤] 無法從 GitHub 獲取版本資訊"
    exit 1
fi

echo "☁️ [遠端] GitHub 版本: $REMOTE_VERSION"
echo ""

# ============================================================================
# 3. 版本比較函數
# ============================================================================
version_gt() {
    local v1=$1 v2=$2
    [[ "$(printf '%s\n' "$v1" "$v2" | sort -V | head -n1)" != "$v1" ]] || [[ "$v1" == "$v2" ]]
}

# ============================================================================
# 4. 判斷是否需要升級
# ============================================================================
if version_gt "$REMOTE_VERSION" "$LOCAL_VERSION"; then
    echo "✅ [成功] 發現新版本！$LOCAL_VERSION → $REMOTE_VERSION"
    echo ""
else
    echo "⏭️ [跳過] 本地已是最新版本，無需升級"
    exit 0
fi

# ============================================================================
# 5. 用戶確認
# ============================================================================
read -p "💬 [輸入] 確認升級？(y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "⏭️ [跳過] 已取消升級"
    exit 0
fi

# ============================================================================
# 6. 建立備份目錄
# ============================================================================
mkdir -p "$BACKUP_DIR"
echo ""
echo "⚙️ [執行] 備份現有版本至: $BACKUP_DIR/backup_$TIMESTAMP"

# ============================================================================
# 7. 備份各腳本
# ============================================================================
for script in "${SCRIPTS[@]}"; do
    SCRIPT_PATH="$SCRIPT_DIR/$script"
    if [[ -f "$SCRIPT_PATH" ]]; then
        cp "$SCRIPT_PATH" "$BACKUP_DIR/backup_$TIMESTAMP/${script}.bak"
        echo "✅ [成功] 已備份: $script"
    fi
done

# ============================================================================
# 8. 下載新版本
# ============================================================================
echo ""
echo "⏳ [等待] 正在下載新版本..."
TEMP_DIR=$(mktemp -d) || { echo "❌ [錯誤] 無法建立臨時目錄"; exit 1; }
trap "rm -rf '$TEMP_DIR'" EXIT

for script in "${SCRIPTS[@]}"; do
    echo "   📥 下載中: $script"
    if ! curl -fsSL -o "$TEMP_DIR/$script" "$REPO_URL/$script"; then
        echo "❌ [錯誤] 下載 $script 失敗"
        exit 1
    fi
done

# 同時下載 VERSION 檔案
curl -fsSL -o "$TEMP_DIR/VERSION" "$REPO_URL/VERSION" || true

echo "✅ [成功] 所有文件下載完成"

# ============================================================================
# 9. 語法驗證
# ============================================================================
echo ""
echo "⚙️ [執行] 驗證新腳本語法..."
for script in "${SCRIPTS[@]}"; do
    if ! bash -n "$TEMP_DIR/$script"; then
        echo "❌ [錯誤] $script 語法驗證失敗！升級已中止"
        echo "ℹ️ [提示] 舊版本已備份至: $BACKUP_DIR/backup_$TIMESTAMP"
        exit 1
    fi
    echo "✅ [成功] $script 通過語法檢查"
done

# ============================================================================
# 10. 安裝新版本
# ============================================================================
echo ""
echo "⚙️ [執行] 安裝新版本..."
for script in "${SCRIPTS[@]}"; do
    cp "$TEMP_DIR/$script" "$SCRIPT_DIR/$script"
    chmod +x "$SCRIPT_DIR/$script"
    echo "✅ [成功] 已安裝: $script"
done

if [[ -f "$TEMP_DIR/VERSION" ]]; then
    cp "$TEMP_DIR/VERSION" "$SCRIPT_DIR/VERSION"
fi

# ============================================================================
# 11. 驗證安裝
# ============================================================================
echo ""
echo "⚙️ [執行] 驗證升級..."
NEW_VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")

if [[ "$NEW_VERSION" == "$REMOTE_VERSION" ]]; then
    echo "✅ [成功] 升級完成！版本: $NEW_VERSION"
else
    echo "⚠️ [警告] 版本驗證不符，但文件已更新"
fi

# ============================================================================
# 12. 升級日誌
# ============================================================================
LOG_FILE="/var/log/server-security-upgrade.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 升級完成: $LOCAL_VERSION → $REMOTE_VERSION" >> "$LOG_FILE"

# ============================================================================
# 13. 完成摘要
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ 升級完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 升級摘要："
echo "   版本: $LOCAL_VERSION → $REMOTE_VERSION"
echo "   位置: $SCRIPT_DIR"
echo "   備份: $BACKUP_DIR/backup_$TIMESTAMP"
echo ""
echo "ℹ️ [提示] 常用指令："
echo "   執行部署: sudo $SCRIPT_DIR/secure-deploy.sh"
echo "   查看日誌: tail -f /var/log/server-security-upgrade.log"
echo ""
echo "🔄 [提示] 下次升級可執行："
echo "   curl -fsSL https://raw.githubusercontent.com/OtisFR/server-security/main/upgrade.sh | sudo bash"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
