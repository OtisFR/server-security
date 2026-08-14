#!/bin/bash

set -euo pipefail

# ============================================================================
# SSH 金鑰強化腳本 v2.0 —— 停用密碼登入（含防鎖死檢查）
#
# 與 v1 的關鍵差異：
#   1. 使用 /etc/ssh/sshd_config.d/00-hardening.conf drop-in 檔
#      （sshd 是「第一個值優先」，00- 排序在 50-cloud-init.conf 之前，
#        確保雲端映像預設的 PasswordAuthentication yes 不會蓋過我們的設定）
#   2. 金鑰檢查看的是「實際登入者」(SUDO_USER) 的 authorized_keys，
#      並依 sshd 實際生效的 AuthorizedKeysFile 路徑與權限規則檢查
#   3. 重啟後用 sshd -T 驗證「有效值」，並偵測 Match 區塊覆蓋
#   4. 任一步失敗（含未預期錯誤）自動還原備份
#
# 系統需求：OpenSSH 8.7+（Ubuntu 22.04+/Debian 12+）
# ============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "❌ [錯誤] 請使用 sudo 執行此腳本"
    exit 1
fi

if [ ! -t 0 ]; then
    echo "❌ [錯誤] 此腳本需要互動式終端機，請下載後執行，勿以 curl | bash 方式使用"
    exit 1
fi

SSHD_BIN=$(command -v sshd || echo /usr/sbin/sshd)
if [ ! -x "$SSHD_BIN" ]; then
    echo "❌ [錯誤] 找不到 sshd，請確認已安裝 openssh-server"
    exit 1
fi

# OpenSSH 版本檢查：Include 需 8.2+，KbdInteractiveAuthentication 需 8.7+
SSH_VER=$(ssh -V 2>&1 | sed -nE 's/^OpenSSH_([0-9]+)\.([0-9]+).*/\1\2/p' | head -1)
if [ -n "$SSH_VER" ] && [ "$SSH_VER" -lt 87 ] 2>/dev/null; then
    echo "❌ [錯誤] 偵測到 OpenSSH 版本過舊（需 8.7+，即 Ubuntu 22.04+/Debian 12+）"
    echo "   舊版請手動編輯 /etc/ssh/sshd_config 並使用 ChallengeResponseAuthentication"
    exit 1
fi

MAIN_CONF="/etc/ssh/sshd_config"
DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN_FILE="$DROPIN_DIR/00-hardening.conf"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "--- SSH 金鑰強化腳本 v2.0 ---"
echo ""

# ============================================================================
# [1/5] 防鎖死檢查：實際登入者必須有 sshd 真的會採用的公鑰
# ============================================================================
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

if [ "$TARGET_USER" = "root" ]; then
    echo "⚠️ [注意] 無法判斷原始登入帳號（SUDO_USER 未設定），將檢查 root 的金鑰。"
    echo "         若你平常是用其他帳號登入，請確認該帳號的金鑰已部署。"
fi

echo "[1/5] 檢查使用者「$TARGET_USER」的 SSH 公鑰..."

# 只認「無選項前綴」的正常公鑰行；cloud-init 在 /root 放的
# 「command="echo Please login as ..."」拒絕行不算數
has_usable_key() {
    [ -f "$1" ] && grep -Eq '^[[:space:]]*(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256))' "$1"
}

# 檢查 StrictModes 會拒用金鑰檔的常見權限問題（group/world writable）
perm_problems() {
    local path="$1" out=""
    local check
    for check in "$TARGET_HOME" "$TARGET_HOME/.ssh" "$path"; do
        [ -e "$check" ] || continue
        local mode
        mode=$(stat -c '%a' "$check" 2>/dev/null || stat -f '%Lp' "$check" 2>/dev/null || echo "")
        if [ -n "$mode" ] && [ $(( 0$mode & 022 )) -ne 0 ]; then
            out+="$check (權限 $mode 可被群組/其他人寫入) "
        fi
    done
    echo "$out"
}

# 依 sshd 實際生效的 AuthorizedKeysFile 找出所有金鑰路徑（展開 %h/%u/相對路徑）
KEY_OK=0
KEY_WARNINGS=""
AKF_LIST=$("$SSHD_BIN" -T 2>/dev/null | awk '$1=="authorizedkeysfile"{$1="";print}' || true)
[ -n "${AKF_LIST// /}" ] || AKF_LIST=".ssh/authorized_keys"

AKC=$("$SSHD_BIN" -T 2>/dev/null | awk '$1=="authorizedkeyscommand"{print $2; exit}' || true)
if [ -n "$AKC" ] && [ "$AKC" != "none" ]; then
    KEY_WARNINGS+="sshd 設定了 AuthorizedKeysCommand ($AKC)，金鑰可能由外部程式提供，本檢查無法涵蓋。 "
fi

for akf in $AKF_LIST; do
    akf="${akf//%u/$TARGET_USER}"
    akf="${akf//%h/$TARGET_HOME}"
    case "$akf" in
        /*) : ;;
        *)  akf="$TARGET_HOME/$akf" ;;
    esac
    if has_usable_key "$akf"; then
        KEY_OK=1
        echo "✅ 找到可用的公鑰: $akf"
        perms=$(perm_problems "$akf")
        if [ -n "$perms" ]; then
            KEY_WARNINGS+="StrictModes 可能因權限拒用金鑰：$perms"
        fi
    fi
done

if [ "$KEY_OK" -ne 1 ] || [ -n "$KEY_WARNINGS" ]; then
    echo ""
    if [ "$KEY_OK" -ne 1 ]; then
        echo "⚠️ 警告：找不到可用的 SSH 公鑰（檢查路徑: $AKF_LIST）"
        echo "   （帶有 command=/restrict 等選項限制的金鑰不計入）"
        echo "   停用密碼登入後，「$TARGET_USER」將無法再以密碼登入。"
    fi
    if [ -n "$KEY_WARNINGS" ]; then
        echo "⚠️ 注意：$KEY_WARNINGS"
    fi
    echo ""
    echo "   最保險的做法：先在另一個視窗執行"
    echo "   ssh -o PasswordAuthentication=no $TARGET_USER@<此主機> 確認金鑰登入成功。"
    read -r -p "確定要繼續嗎？ (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消"; exit 1; }
fi

# ============================================================================
# [2/5] 備份（此後任何未預期錯誤都會自動還原）
# ============================================================================
echo "[2/5] 備份現有設定..."
BACKUP_MAIN="${MAIN_CONF}.bak.${TIMESTAMP}"
cp "$MAIN_CONF" "$BACKUP_MAIN" || { echo "❌ 備份失敗！"; exit 1; }
echo "✅ 已備份: $BACKUP_MAIN"

BACKUP_DROPIN=""
DROPIN_EXISTED=0
if [ -f "$DROPIN_FILE" ]; then
    DROPIN_EXISTED=1
    BACKUP_DROPIN="${DROPIN_FILE}.bak.${TIMESTAMP}"
    cp "$DROPIN_FILE" "$BACKUP_DROPIN"
    echo "✅ 已備份: $BACKUP_DROPIN"
fi

restore_backup() {
    echo "🔄 正在還原備份..."
    local ok=1
    cp "$BACKUP_MAIN" "$MAIN_CONF" || ok=0
    if [ "$DROPIN_EXISTED" -eq 1 ] && [ -n "$BACKUP_DROPIN" ]; then
        cp "$BACKUP_DROPIN" "$DROPIN_FILE" || ok=0
    else
        rm -f "$DROPIN_FILE" || ok=0
    fi
    if [ "$ok" -ne 1 ]; then
        echo "🚨 [嚴重] 自動還原失敗！請立刻手動執行："
        echo "   sudo cp $BACKUP_MAIN $MAIN_CONF && sudo rm -f $DROPIN_FILE"
        return 1
    fi
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    if systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; then
        echo "✅ 已還原原始設定，SSH 服務運行中"
    else
        echo "🚨 [嚴重] 還原後 SSH 服務未運行！請立即檢查: systemctl status ssh"
    fi
}

# 未預期錯誤的兜底：從此刻起任何失敗都會先還原再退出
on_unexpected_error() {
    echo ""
    echo "❌ 發生未預期的錯誤（行 $1）"
    restore_backup || true
    exit 1
}
trap 'on_unexpected_error $LINENO' ERR

# ============================================================================
# [3/5] 寫入 drop-in 設定
# ============================================================================
echo "[3/5] 寫入強化設定 ($DROPIN_FILE)..."

mkdir -p "$DROPIN_DIR"

# 確保主設定檔會讀取 drop-in 目錄（Ubuntu 20.04+/Debian 12 預設就有）。
# 注意：若原本沒有 Include，插入後會「一併啟用」目錄內既存的其他 *.conf，
# 必須先讓使用者知情
if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN_CONF"; then
    existing_dropins=$(find "$DROPIN_DIR" -maxdepth 1 -name '*.conf' ! -name "$(basename "$DROPIN_FILE")" 2>/dev/null || true)
    if [ -n "$existing_dropins" ]; then
        echo ""
        echo "⚠️ 警告：主設定檔目前沒有 Include，但 $DROPIN_DIR 內已存在其他設定檔："
        echo "$existing_dropins" | sed 's/^/   /'
        echo "   加入 Include 後這些檔案會【同時生效】且優先於主設定檔。"
        read -r -p "已確認上述檔案內容無誤，繼續？ (y/N): " inc_confirm
        if [[ ! "$inc_confirm" =~ ^[Yy]$ ]]; then
            trap - ERR
            restore_backup || true
            echo "已取消"
            exit 1
        fi
    fi
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$MAIN_CONF"
    echo "✅ 已在主設定檔第 1 行加入 Include 指令"
fi

cat > "$DROPIN_FILE" <<EOF
# 由 server-security secure_ssh.sh 產生（$TIMESTAMP）
# 檔名 00- 開頭：sshd 採「第一個值優先」，此檔優先於 50-cloud-init.conf 等預設
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
echo "✅ 設定已寫入"

# ============================================================================
# [4/5] 語法檢查 + 重啟
# ============================================================================
echo "[4/5] 檢查設定檔語法..."
if ! "$SSHD_BIN" -t; then
    echo "❌ 設定檔語法錯誤！"
    trap - ERR
    restore_backup || true
    exit 1
fi

echo "✅ 語法正確，重啟 SSH 服務..."
if ! systemctl restart ssh 2>/dev/null && ! systemctl restart sshd 2>/dev/null; then
    echo "❌ SSH 服務重啟失敗！"
    trap - ERR
    restore_backup || true
    exit 1
fi

# ============================================================================
# [5/5] 驗證「有效值」—— 這一步才是真正的成功判定
# ============================================================================
echo "[5/5] 驗證 sshd 實際生效的設定..."

verify_effective() {
    local key="$1" expected="$2" actual
    actual=$("$SSHD_BIN" -T 2>/dev/null | awk -v k="$key" 'tolower($1)==k{print tolower($2); exit}')
    if [ "$actual" = "$expected" ]; then
        echo "   ✅ $key = $actual"
        return 0
    else
        echo "   ❌ $key = ${actual:-（讀取失敗）}（預期: $expected）"
        return 1
    fi
}

VERIFY_OK=1
verify_effective "passwordauthentication" "no" || VERIFY_OK=0
verify_effective "kbdinteractiveauthentication" "no" || VERIFY_OK=0
verify_effective "pubkeyauthentication" "yes" || VERIFY_OK=0

if [ "$VERIFY_OK" -ne 1 ]; then
    echo ""
    echo "❌ 有效設定驗證失敗！常見原因："
    echo "   1. 主設定檔的 Include 位置在認證指令之後（第一個值優先，前面的贏）"
    echo "   2. 其他 drop-in 檔以更前的字典序覆蓋"
    echo "   相關設定位置如下："
    grep -n -iE '^[[:space:]]*(Include|PasswordAuthentication|Match)' "$MAIN_CONF" "$DROPIN_DIR"/*.conf 2>/dev/null | sed 's/^/   /' || true
    trap - ERR
    restore_backup || true
    exit 1
fi

# Match 區塊偵測：sshd -T（未帶 -C）只反映全域值；Match 區塊內若另設
# PasswordAuthentication yes，對符合條件的連線仍然有效，必須明確告知
MATCH_OVERRIDES=$(awk '
    FNR==1 { inmatch=0 }
    tolower($1)=="match" { inmatch=1 }
    inmatch && tolower($1) ~ /^(passwordauthentication|kbdinteractiveauthentication)$/ { print FILENAME ": " $0 }
' "$MAIN_CONF" "$DROPIN_DIR"/*.conf 2>/dev/null || true)

trap - ERR

echo ""
if [ -n "$MATCH_OVERRIDES" ]; then
    echo "--- ✨ 強化完成（全域密碼登入已停用，但有例外） ---"
    echo "⚠️ 偵測到 Match 區塊內的認證設定，符合條件的連線【不受】本次全域強化影響："
    echo "$MATCH_OVERRIDES" | sed 's/^/   /'
    echo "   請自行確認這些例外是否符合預期。"
else
    echo "--- ✨ 強化完成！密碼登入已確認停用 ---"
fi
echo "⚠️  重要：請開啟『另一個』新視窗測試 SSH 金鑰登入。"
echo "⚠️  在確認新視窗能登入之前，請勿關閉此視窗！"
echo "ℹ️  如需還原: sudo cp $BACKUP_MAIN $MAIN_CONF && sudo rm -f $DROPIN_FILE && sudo systemctl restart ssh"
