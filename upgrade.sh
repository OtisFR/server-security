#!/bin/bash

set -euo pipefail

# ============================================================================
# 自動升級腳本 v2.0 —— 伺服器安全加固工具
#
# 與 v1 的關鍵差異：
#   1. 下載後【強制驗證 SHA256】（比對 checksums.sha256），驗證失敗即中止
#   2. 備份目錄正確建立，回滾點真實存在
#   3. 版本比較嚴格（相等不再誤判為新版）；遠端版本抓取失敗直接報錯
#   4. 非互動環境（cron / 管線）必須帶 --yes 參數，避免 read 誤讀輸入
# ============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "❌ [錯誤] 請使用 sudo 執行此腳本"
    exit 1
fi

REPO_URL="https://raw.githubusercontent.com/OtisFR/server-security/main"
SCRIPT_DIR="/opt/server-security"
# 與 checksums.sha256 涵蓋的發佈清單一致（含 upgrade.sh 本身，才能自我更新）
SCRIPTS=("secure-deploy.sh" "secure_ssh.sh" "upgrade.sh" "zabbix-agent2-install.sh" "update-checksums.sh")
BACKUP_DIR="$SCRIPT_DIR/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

AUTO_YES=0
if [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
    AUTO_YES=1
fi

# 非互動環境保護：stdin 不是終端機時，必須明確帶 --yes
if [ ! -t 0 ] && [ "$AUTO_YES" -ne 1 ]; then
    echo "❌ [錯誤] 偵測到非互動式環境。"
    echo "   如需自動化升級，請明確加上 --yes 參數："
    echo "   sudo bash upgrade.sh --yes"
    exit 1
fi

# sha256 指令（Linux: sha256sum；macOS: shasum -a 256）
sha256_of() {
    if command -v sha256sum &> /dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

echo "================================================================"
echo " 🔄 伺服器安全加固工具 - 自動升級"
echo "================================================================"
echo ""

# ============================================================================
# 1. 版本檢查
# ============================================================================
if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    LOCAL_VERSION=$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")
else
    LOCAL_VERSION="0.0.0"
fi
[ -n "$LOCAL_VERSION" ] || LOCAL_VERSION="0.0.0"
echo "📍 [偵測] 本地版本: $LOCAL_VERSION"

echo "⏳ [等待] 正在檢查最新版本..."
if ! REMOTE_VERSION=$(curl -fsSL --max-time 30 "$REPO_URL/VERSION"); then
    echo "❌ [錯誤] 無法從 GitHub 取得版本資訊，請檢查網路連線"
    exit 1
fi
REMOTE_VERSION=$(echo "$REMOTE_VERSION" | tr -d '[:space:]')
if [[ -z "$REMOTE_VERSION" ]] || ! [[ "$REMOTE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ [錯誤] 遠端版本格式異常: '$REMOTE_VERSION'"
    exit 1
fi
echo "☁️ [遠端] GitHub 版本: $REMOTE_VERSION"
echo ""

# 嚴格「大於」比較：v1 > v2 才回傳 0
version_gt() {
    local v1=$1 v2=$2
    [ "$v1" != "$v2" ] && [ "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | tail -n1)" = "$v1" ]
}

if ! version_gt "$REMOTE_VERSION" "$LOCAL_VERSION"; then
    echo "⏭️ [跳過] 本地已是最新版本 ($LOCAL_VERSION)，無需升級"
    exit 0
fi
echo "✅ [發現] 新版本！$LOCAL_VERSION → $REMOTE_VERSION"
echo ""

if [ "$AUTO_YES" -ne 1 ]; then
    read -r -p "💬 [輸入] 確認升級？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "⏭️ [跳過] 已取消升級"
        exit 0
    fi
fi

# ============================================================================
# 2. 下載新版本（含 checksums.sha256）
# ============================================================================
echo ""
echo "⏳ [等待] 正在下載新版本..."
TEMP_DIR=$(mktemp -d) || { echo "❌ [錯誤] 無法建立臨時目錄"; exit 1; }
# shellcheck disable=SC2064  # 蓄意在此展開路徑：mktemp 路徑此後不變
trap "rm -rf '$TEMP_DIR'" EXIT

for script in "${SCRIPTS[@]}"; do
    echo "   📥 下載中: $script"
    if ! curl -fsSL --max-time 60 -o "$TEMP_DIR/$script" "$REPO_URL/$script"; then
        echo "❌ [錯誤] 下載 $script 失敗，升級中止"
        exit 1
    fi
done

if ! curl -fsSL --max-time 30 -o "$TEMP_DIR/checksums.sha256" "$REPO_URL/checksums.sha256"; then
    echo "❌ [錯誤] 下載 checksums.sha256 失敗，無法驗證完整性，升級中止"
    exit 1
fi
if ! curl -fsSL --max-time 30 -o "$TEMP_DIR/VERSION" "$REPO_URL/VERSION"; then
    echo "❌ [錯誤] 下載 VERSION 失敗，升級中止"
    exit 1
fi
echo "✅ [成功] 所有檔案下載完成"

# ============================================================================
# 3. SHA256 完整性驗證（強制，任一不符即中止）
# ============================================================================
echo ""
echo "⚙️ [執行] 驗證 SHA256 校驗和..."
for script in "${SCRIPTS[@]}"; do
    expected=$(awk -v f="$script" '$2==f{print $1}' "$TEMP_DIR/checksums.sha256")
    if [ -z "$expected" ]; then
        echo "❌ [錯誤] checksums.sha256 中找不到 $script 的校驗和，升級中止"
        exit 1
    fi
    actual=$(sha256_of "$TEMP_DIR/$script")
    if [ "$actual" != "$expected" ]; then
        echo "❌ [錯誤] $script 校驗和不符！"
        echo "   預期: $expected"
        echo "   實際: $actual"
        echo "   檔案可能在傳輸中損毀或被竄改，升級已中止。"
        exit 1
    fi
    echo "✅ [通過] $script"
done

# ============================================================================
# 4. 語法驗證
# ============================================================================
echo ""
echo "⚙️ [執行] 驗證腳本語法..."
for script in "${SCRIPTS[@]}"; do
    if ! bash -n "$TEMP_DIR/$script"; then
        echo "❌ [錯誤] $script 語法驗證失敗！升級已中止"
        exit 1
    fi
done
echo "✅ [成功] 語法檢查通過"

# ============================================================================
# 5. 備份現有版本
# ============================================================================
BACKUP_PATH="$BACKUP_DIR/backup_$TIMESTAMP"
mkdir -p "$BACKUP_PATH"
BACKED_UP=0
for script in "${SCRIPTS[@]}"; do
    if [[ -f "$SCRIPT_DIR/$script" ]]; then
        cp "$SCRIPT_DIR/$script" "$BACKUP_PATH/${script}.bak"
        BACKED_UP=$((BACKED_UP + 1))
    fi
done
if [ "$BACKED_UP" -gt 0 ]; then
    echo ""
    echo "✅ [成功] 已備份 $BACKED_UP 個檔案至: $BACKUP_PATH"
fi

# ============================================================================
# 6. 安裝新版本
# ============================================================================
echo ""
echo "⚙️ [執行] 安裝新版本..."
mkdir -p "$SCRIPT_DIR"
for script in "${SCRIPTS[@]}"; do
    # 先寫入同目錄暫存檔再 mv：mv 以換 inode 方式取代，
    # 即使 upgrade.sh 正在自我更新，執行中的舊檔仍完整（cp 就地覆寫則不安全）
    cp "$TEMP_DIR/$script" "$SCRIPT_DIR/.$script.new"
    chmod +x "$SCRIPT_DIR/.$script.new"
    mv -f "$SCRIPT_DIR/.$script.new" "$SCRIPT_DIR/$script"
    echo "✅ [成功] 已安裝: $script"
done
cp "$TEMP_DIR/VERSION" "$SCRIPT_DIR/VERSION"
cp "$TEMP_DIR/checksums.sha256" "$SCRIPT_DIR/checksums.sha256"

# ============================================================================
# 7. 完成
# ============================================================================
LOG_FILE="/var/log/server-security-upgrade.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 升級完成: $LOCAL_VERSION → $REMOTE_VERSION" >> "$LOG_FILE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ 升級完成！$LOCAL_VERSION → $REMOTE_VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "   安裝位置: $SCRIPT_DIR"
echo "   備份位置: $BACKUP_PATH"
echo "   升級日誌: $LOG_FILE"
echo ""
echo "ℹ️ [提示] 執行部署: sudo bash $SCRIPT_DIR/secure-deploy.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
