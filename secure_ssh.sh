#!/bin/bash

# 檢查是否為 root 權限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 請使用 sudo 或 root 權限執行此腳本。"
  exit 1
fi

# [新增] 安全檢查：確保家目錄有公鑰，否則會把自己鎖在外面
if [ ! -f "$HOME/.ssh/authorized_keys" ] || [ ! -s "$HOME/.ssh/authorized_keys" ]; then
  echo "⚠️ 警告：在 $HOME/.ssh/authorized_keys 中找不到任何公鑰！"
  read -p "如果你現在執行腳本，密碼停用後你將無法登入。確定要繼續嗎？ (y/N): " confirm
  [[ "$confirm" != "y" ]] && exit 1
fi

echo "--- 開始執行 SSH 安全強化腳本 ---"

CONF_FILE="/etc/ssh/sshd_config"
BACKUP_FILE="${CONF_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

if ! cp "$CONF_FILE" "$BACKUP_FILE"; then
  echo "❌ 備份失敗！"
  exit 1
fi
echo "[1/4] 已備份設定檔至: $BACKUP_FILE"

# 修改後的函式：更精準的匹配
update_config() {
    local key=$1
    local value=$2
    # 使用 grep 尋找「非註解」或「被註解」的精確單字
    if grep -qE "^[#[:space:]]*$key([[:space:]]+|$)" "$CONF_FILE"; then
        # 替換該行，並確保 key 與 value 之間有空格
        sed -i "s/^[#[:space:]]*$key.*/$key $value/" "$CONF_FILE"
    else
        echo "$key $value" >> "$CONF_FILE"
    fi
}

echo "[2/4] 正在修改 SSH 設定參數..."
update_config "PubkeyAuthentication" "yes"
update_config "PasswordAuthentication" "no"
update_config "KbdInteractiveAuthentication" "no"
update_config "ChallengeResponseAuthentication" "no"
update_config "UsePAM" "yes"

echo "[3/4] 正在檢查設定檔語法..."
if sshd -t; then
    echo "✅ 語法檢查正確，正在重啟 SSH 服務..."
    if systemctl restart ssh; then
        echo "--- ✨ 設定完成！ ---"
        echo "⚠️  重要：請開啟『另一個』新視窗測試 SSH 連線。"
        echo "⚠️  在確認新視窗能透過金鑰登入前，請勿關閉此視窗！"
    else
        echo "❌ SSH 服務重啟失敗！正在還原備份..."
        cp "$BACKUP_FILE" "$CONF_FILE"
        systemctl restart ssh
        exit 1
    fi
else
    echo "❌ 設定檔語法錯誤！正在還原備份..."
    cp "$BACKUP_FILE" "$CONF_FILE"
    exit 1
fi