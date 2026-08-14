#!/bin/bash

set -euo pipefail

# ============================================================================
# 校驗和更新工具 v2.0（macOS / Linux 通用）
#
# 功能：
#   1. 計算所有發佈腳本的 SHA256
#   2. 更新 checksums.sha256
#   3. 以 <!-- CHECKSUMS START/END --> 標記安全地更新 README.md 的校驗表
#      （v1 的標記字串遺失導致 awk 空樣式會毀掉整份 README，v2 已修復並加上
#        替換後的完整性檢查）
#
# 用法：
#   bash update-checksums.sh            # 更新檔案，之後詢問是否 git commit/push
#   bash update-checksums.sh --no-git   # 只更新檔案，跳過 git 操作
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
README_FILE="$SCRIPT_DIR/README.md"
SHA256_FILE="$SCRIPT_DIR/checksums.sha256"

MARKER_START='<!-- CHECKSUMS START -->'
MARKER_END='<!-- CHECKSUMS END -->'

# 發佈的腳本清單（新增腳本時記得同步更新）
FILES=("secure-deploy.sh" "secure_ssh.sh" "upgrade.sh" "zabbix-agent2-install.sh" "update-checksums.sh")

NO_GIT=0
if [ "${1:-}" = "--no-git" ]; then
    NO_GIT=1
fi

# sha256 指令（macOS: shasum；Linux: sha256sum）
sha256_of() {
    if command -v sha256sum &> /dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

for file in "${FILES[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$file" ]; then
        echo "❌ [錯誤] 找不到檔案: $file"
        exit 1
    fi
done
if [ ! -f "$README_FILE" ]; then
    echo "❌ [錯誤] 找不到 README.md"
    exit 1
fi

# ============================================================================
# 1. 計算校驗和
# ============================================================================
echo "📝 計算 SHA256 校驗和..."
echo ""

declare -a NAMES=()
declare -a HASHES=()
for file in "${FILES[@]}"; do
    checksum=$(cd "$SCRIPT_DIR" && sha256_of "$file")
    NAMES+=("$file")
    HASHES+=("$checksum")
    echo "✅ $file"
    echo "   $checksum"
done

# ============================================================================
# 2. 寫入 checksums.sha256（sha256sum -c 可直接使用的格式）
# ============================================================================
: > "$SHA256_FILE"
for i in "${!NAMES[@]}"; do
    echo "${HASHES[$i]}  ${NAMES[$i]}" >> "$SHA256_FILE"
done
echo ""
echo "✅ 已更新: $SHA256_FILE"

# ============================================================================
# 3. 更新 README.md 標記區塊
# ============================================================================
if ! grep -qF "$MARKER_START" "$README_FILE" || ! grep -qF "$MARKER_END" "$README_FILE"; then
    echo "❌ [錯誤] README.md 缺少 $MARKER_START / $MARKER_END 標記，不做任何修改"
    exit 1
fi

# 標記必須各恰好一個，且 START 在 END 之前（順序顛倒會讓替換靜默吃掉後續內容）
start_count=$(grep -cF "$MARKER_START" "$README_FILE")
end_count=$(grep -cF "$MARKER_END" "$README_FILE")
start_line=$(grep -nF "$MARKER_START" "$README_FILE" | head -1 | cut -d: -f1)
end_line=$(grep -nF "$MARKER_END" "$README_FILE" | head -1 | cut -d: -f1)
if [ "$start_count" -ne 1 ] || [ "$end_count" -ne 1 ] || [ "$start_line" -ge "$end_line" ]; then
    echo "❌ [錯誤] 標記數量或順序異常 (START×$start_count@L$start_line, END×$end_count@L$end_line)，不做任何修改"
    exit 1
fi

# 產生新的標記區塊內容（含標記本身）
BLOCK_FILE=$(mktemp)
# shellcheck disable=SC2064  # 蓄意在此展開路徑：mktemp 路徑此後不變
trap "rm -f '$BLOCK_FILE'" EXIT
{
    echo "$MARKER_START"
    echo "| 文件 | SHA256 |"
    echo "|------|--------|"
    for i in "${!NAMES[@]}"; do
        echo "| **${NAMES[$i]}** | \`${HASHES[$i]}\` |"
    done
    echo "$MARKER_END"
} > "$BLOCK_FILE"

# 以明確的標記樣式替換區塊（標記外的內容一律原樣保留）
TMP_README=$(mktemp)
awk -v start="$MARKER_START" -v end="$MARKER_END" -v blockfile="$BLOCK_FILE" '
    index($0, start) {
        while ((getline line < blockfile) > 0) print line
        close(blockfile)
        skip = 1
        next
    }
    index($0, end) { skip = 0; next }
    !skip { print }
' "$README_FILE" > "$TMP_README"

# 完整性檢查：替換後必須仍各有一個標記，且非標記內容行數不變
count_start=$(grep -cF "$MARKER_START" "$TMP_README")
count_end=$(grep -cF "$MARKER_END" "$TMP_README")
if [ "$count_start" -ne 1 ] || [ "$count_end" -ne 1 ]; then
    echo "❌ [錯誤] 替換後標記數量異常 (START=$count_start, END=$count_end)，已放棄修改"
    rm -f "$TMP_README"
    exit 1
fi
outside_before=$(awk -v s="$MARKER_START" -v e="$MARKER_END" 'index($0,s){skip=1;next} index($0,e){skip=0;next} !skip{n++} END{print n+0}' "$README_FILE")
outside_after=$(awk -v s="$MARKER_START" -v e="$MARKER_END" 'index($0,s){skip=1;next} index($0,e){skip=0;next} !skip{n++} END{print n+0}' "$TMP_README")
if [ "$outside_before" -ne "$outside_after" ]; then
    echo "❌ [錯誤] 標記區塊外的內容行數改變 ($outside_before → $outside_after)，已放棄修改"
    rm -f "$TMP_README"
    exit 1
fi

# 以 cat 覆寫內容保留原檔 inode 與權限（mv 會帶入 mktemp 的 0600 權限）
cat "$TMP_README" > "$README_FILE"
rm -f "$TMP_README"
echo "✅ 已更新: README.md 校驗和區塊"

# ============================================================================
# 4. Git 操作（可選）
# ============================================================================
if [ "$NO_GIT" -eq 1 ] || [ ! -t 0 ]; then
    echo ""
    echo "✨ 完成（未執行 git 操作）"
    exit 0
fi

if ! git -C "$SCRIPT_DIR" rev-parse --git-dir &> /dev/null; then
    echo "⚠️ [提示] 不在 Git 倉庫中，略過 git 操作"
    exit 0
fi

echo ""
git -C "$SCRIPT_DIR" status --short
echo ""
read -r -p "💬 [輸入] 是否 commit 並 push？ (y/n): " git_proceed
if [[ ! "$git_proceed" =~ ^[Yy]$ ]]; then
    echo "⏭️ 已跳過 git 操作"
    exit 0
fi

read -r -p "💬 [輸入] 提交訊息 (預設: 'chore: update checksums'): " commit_msg
commit_msg="${commit_msg:-chore: update checksums}"
git -C "$SCRIPT_DIR" add -A
git -C "$SCRIPT_DIR" commit -m "$commit_msg" || echo "ℹ️ 無新變更可提交"
git -C "$SCRIPT_DIR" push origin "$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD)"
echo ""
echo "✨ 完成！"
