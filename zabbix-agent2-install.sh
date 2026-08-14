#!/bin/bash

set -euo pipefail

# ============================================================================
# Zabbix Agent 2 安裝腳本 v2.0 (Ubuntu 24.04 / Zabbix 7.0)
#
# 與 v1 的關鍵差異：
#   1. 下載到 mktemp 私有目錄並以 -O 指定輸出（v1 在共享目錄且不覆寫，
#      可能安裝到被預先放置的同名舊檔）
#   2. 輸入驗證（Server IP / 主機名稱），杜絕 sed 注入
#   3. 嚴格模式 + 結果驗證 + 自動清理下載檔
# ============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "❌ [錯誤] 請使用 sudo 執行此腳本"
    exit 1
fi

if [ ! -t 0 ]; then
    echo "❌ [錯誤] 此腳本需要互動式終端機，請下載後執行"
    exit 1
fi

# Zabbix 官方套件庫釋出檔（更新版本時請同步修改）
ZBX_RELEASE_URL="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_7.0-2+ubuntu24.04_all.deb"

if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${VERSION_ID:-}" != "24.04" ]; then
        echo "⚠️ [警告] 此腳本針對 Ubuntu 24.04 撰寫（偵測到: ${PRETTY_NAME:-未知}）"
        read -r -p "仍要繼續嗎？ (y/N): " os_confirm
        [[ "$os_confirm" =~ ^[Yy]$ ]] || exit 1
    fi
fi

# ============================================================================
# 輸入與驗證
# ============================================================================
validate_ipv4() {
    [[ "$1" =~ ^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$ ]]
}
validate_hostname() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$ ]]
}

read -r -p "👉 請輸入 Zabbix Server IP (例如 192.168.1.254): " ZBX_IP
if ! validate_ipv4 "$ZBX_IP"; then
    echo "❌ [錯誤] 無效的 IPv4 位址: $ZBX_IP"
    exit 1
fi

read -r -p "👉 請輸入本機名稱 (例如 vps-ubuntu): " ZBX_HOST
if ! validate_hostname "$ZBX_HOST"; then
    echo "❌ [錯誤] 無效的主機名稱（僅允許英數、點、底線、連字號）: $ZBX_HOST"
    exit 1
fi

# ============================================================================
# 下載並安裝套件庫釋出檔
# ============================================================================
echo "⏳ 下載 Zabbix 套件庫釋出檔..."
TMP_DIR=$(mktemp -d)
# shellcheck disable=SC2064  # 蓄意在此展開路徑：mktemp 路徑此後不變
trap "rm -rf '$TMP_DIR'" EXIT

DEB_FILE="$TMP_DIR/zabbix-release.deb"
if ! wget -q -O "$DEB_FILE" "$ZBX_RELEASE_URL"; then
    echo "❌ [錯誤] 下載失敗，請檢查網路或確認 URL 是否仍有效："
    echo "   $ZBX_RELEASE_URL"
    exit 1
fi

echo "⏳ 安裝套件庫（安裝後由 APT 簽章機制驗證後續套件）..."
dpkg -i "$DEB_FILE"

echo "⏳ 更新套件清單並安裝 Zabbix Agent 2..."
apt-get update
apt-get install -y zabbix-agent2

# ============================================================================
# 設定
# ============================================================================
echo "⏳ 修改設定檔..."
CONF="/etc/zabbix/zabbix_agent2.conf"
if [ ! -f "$CONF" ]; then
    echo "❌ [錯誤] 找不到設定檔: $CONF"
    exit 1
fi
cp "$CONF" "${CONF}.bak.$(date +%Y%m%d_%H%M%S)"

# 輸入已通過白名單驗證，不含 sed 特殊字元。
# 不依賴原廠預設值比對（重複執行時也要能改），寫入後逐項驗證
sed -i -E "s/^Server=.*/Server=$ZBX_IP/" "$CONF"
sed -i -E "s/^ServerActive=.*/ServerActive=$ZBX_IP/" "$CONF"
sed -i -E "s/^Hostname=.*/Hostname=$ZBX_HOST/" "$CONF"

for expect in "Server=$ZBX_IP" "ServerActive=$ZBX_IP" "Hostname=$ZBX_HOST"; do
    if ! grep -qx "$expect" "$CONF"; then
        echo "❌ [錯誤] 設定寫入驗證失敗（找不到 $expect），請手動檢查 $CONF"
        exit 1
    fi
done
echo "✅ 設定已寫入並驗證: Server/ServerActive=$ZBX_IP, Hostname=$ZBX_HOST"

# 若 UFW 已啟用，只對 Zabbix Server 開放被動檢查埠
if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow from "$ZBX_IP" to any port 10050 proto tcp > /dev/null 2>&1 || true
    echo "✅ UFW: 已放行 $ZBX_IP → 10050/tcp (Zabbix 被動檢查)"
fi

# ============================================================================
# 啟動與驗證
# ============================================================================
# apt 安裝時 postinst 可能已用「預設設定」啟動服務，
# 必須 restart（而非 --now 的 no-op start）才會載入上面寫入的設定
echo "⏳ 啟動 Zabbix Agent 2..."
systemctl enable zabbix-agent2
systemctl restart zabbix-agent2

if systemctl is-active --quiet zabbix-agent2; then
    echo ""
    echo "✅ 安裝與設定完成！"
    echo "📌 Server IP: $ZBX_IP | 主機名稱: $ZBX_HOST"
    echo "📌 設定檔: $CONF（原始檔已備份）"
else
    echo "❌ [錯誤] zabbix-agent2 服務未成功啟動，請檢查:"
    echo "   sudo journalctl -u zabbix-agent2 -n 50"
    exit 1
fi
