#!/bin/bash

set -euo pipefail

# ============================================================================
# 自動計算腳本校驗和並更新 README.md (macOS 專用穩定版)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
README_FILE="$SCRIPT_DIR/README.md"
GIT_DIR="$(git -C "$SCRIPT_DIR" rev-parse --git-dir 2>/dev/null)" && GIT_DIR="$(dirname "$GIT_DIR")" || GIT_DIR=""

# 要檢查的文件
FILES=("secure-deploy.sh" "setup_ssh_jail.sh" "tailscale-installer.sh")
GITHUB_RAW_BASE="https://raw.githubusercontent.com/OtisFR/server-security/main"

# 檢查所有文件是否存在
for file in "${FILES[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$file" ]; then
        echo "❌ [錯誤] 找不到文件: $file"
        exit 1
    fi
done

echo "📝 計算 SHA256 校驗和..."
echo ""

# 計算校驗和並存儲
CHECKSUMS_LIST=()
for file in "${FILES[@]}"; do
    checksum=$(cd "$SCRIPT_DIR" && shasum -a 256 "$file" | awk '{print $1}')
    CHECKSUMS_LIST+=("$file:$checksum")
    echo "✅ $file"
    echo "   $checksum"
done

# 提取校驗和的輔助函數
get_checksum() {
    local file=$1
    for item in "${CHECKSUMS_LIST[@]}"; do
        if [[ "$item" == "$file:"* ]]; then
            echo "${item#*:}"
            return
        fi
    done
}

echo ""
echo "📄 更新 README.md 和 checksums.sha256..."

# 取得 secure-deploy.sh 的最新 checksum
SECURE_CS=$(get_checksum "secure-deploy.sh")

# 生成要寫入的 Markdown 內容 (包含標籤、One-liner 區塊與表格)
# 注意：使用 HTML 註解作為替換的定位點
NEW_MARKDOWN=$(cat <<EOF
### 🛡️ 安全驗證版本（企業推薦）

\`\`\`bash
# 下載、驗證、執行並自動銷毀 (One-liner 複製貼上即可)
curl -fsSL -o /tmp/secure-deploy.sh $GITHUB_RAW_BASE/secure-deploy.sh && \\
echo "$SECURE_CS  /tmp/secure-deploy.sh" | shasum -a 256 -c && \\
sudo bash /tmp/secure-deploy.sh ; rm -f /tmp/secure-deploy.sh
\`\`\`

#### 📄 完整檔案校驗和清單
| 文件 | SHA256 |
|------|--------|
$(for file in "${FILES[@]}"; do
    cs=$(get_checksum "$file")
    echo "| **$file** | \`${cs}\` |"
done)
EOF
)

# 確保 README.md 存在
if [ ! -f "$README_FILE" ]; then
    echo "❌ [錯誤] 找不到 README.md: $README_FILE"
    exit 1
fi

# 更新 README.md 邏輯：利用 awk 和自訂標籤進行安全替換
if grep -q "" "$README_FILE"; then
    echo "🔄 偵測到現有區塊，正在更新 README.md..."
    # 使用 awk 將 START 和 END 標籤之間的內容替換為最新的 NEW_MARKDOWN
    awk -v new_content="$NEW_MARKDOWN" '
        BEGIN { skip=0 }
        // { print new_content; skip=1; next }
        // { skip=0; next }
        !skip { print }
    ' "$README_FILE" > "$README_FILE.tmp" && mv "$README_FILE.tmp" "$README_FILE"
    echo "✅ [成功] README.md 區塊已同步"
else
    echo "➕ 未發現區塊，正在將校驗和追加至 README.md 末尾..."
    echo -e "\n$NEW_MARKDOWN" >> "$README_FILE"
    echo "✅ [成功] 已追加新區塊 (包含標籤)"
fi

# 生成 .sha256 檔案
SHA256_FILE="$SCRIPT_DIR/checksums.sha256"
: > "$SHA256_FILE"
for item in "${CHECKSUMS_LIST[@]}"; do
    file="${item%%:*}"
    checksum="${item##*:}"
    echo "$checksum  $file" >> "$SHA256_FILE"
done
echo "✅ 已更新驗證檔: $SHA256_FILE"

# ============================================================================
# Git 互動操作
# ============================================================================

if [ -z "$GIT_DIR" ]; then
    echo "⚠️ [警告] 不在 Git 倉庫中，略過 Git 操作"
    exit 0
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔧 Git 操作"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd "$SCRIPT_DIR"
GIT_STATUS=$(git status --porcelain 2>/dev/null || echo "")

if [ -z "$GIT_STATUS" ]; then
    echo "✅ [信息] 工作目錄清潔，無新變更需要 Commit"
    # 如果只是想單純 Push，可以繼續執行
else
    echo "📝 檢測到的本地更改："
    echo "$GIT_STATUS" | sed 's/^/   /'
    echo ""
fi

read -p "💬 [輸入] 是否要進行 Git 操作？ (y/n): " git_proceed
if [[ ! "$git_proceed" =~ ^[Yy]$ ]]; then
    echo "⏭️ [跳過] 已取消 Git 操作"
    exit 0
fi

echo ""
echo "🔀 選擇 Git 操作方式："
echo "  1) 直接推送 (git push)"
echo "  2) 合併分支後推送 (git merge)"
echo "  3) 僅 Commit，不推送"
echo "  4) 🔥 強制覆蓋 GitHub (以本地檔案為準，完全覆蓋遠端)"
echo "  q) 取消"
echo ""
read -p "💬 [輸入] 請選擇 [1/2/3/4/q]: " git_choice

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

case "$git_choice" in
    1)
        git add -A
        read -p "💬 [輸入] 提交訊息 (預設: 'chore: update checksums'): " commit_msg
        commit_msg="${commit_msg:-chore: update checksums}"
        git commit -m "$commit_msg" || echo "ℹ️ 無新變更可提交"
        git push origin "$CURRENT_BRANCH"
        ;;
    2)
        read -p "💬 [輸入] 來源分支 (預設: develop): " source_branch
        source_branch="${source_branch:-develop}"
        git add -A
        read -p "💬 [輸入] 提交訊息: " commit_msg
        commit_msg="${commit_msg:-merge: update checksums from $source_branch}"
        git commit -m "$commit_msg" || echo "ℹ️ 無新變更"
        git merge "$source_branch" --no-edit
        git push origin "$CURRENT_BRANCH"
        ;;
    3)
        git add -A
        read -p "💬 [輸入] 提交訊息: " commit_msg
        commit_msg="${commit_msg:-chore: update checksums}"
        git commit -m "$commit_msg" || echo "ℹ️ 無新變更"
        echo "✅ [成功] Commit 已建立"
        ;;
    4)
        echo ""
        echo "🚨 [警告] 即將進行強制推送 (Force Push)！"
        read -p "⚠️  你確定要完全以本地端覆蓋遠端 GitHub 嗎？ (y/n): " confirm_force
        if [[ "$confirm_force" =~ ^[Yy]$ ]]; then
            git add -A
            read -p "💬 [輸入] 提交訊息: " commit_msg
            commit_msg="${commit_msg:-chore: force sync local state to remote}"
            git commit -m "$commit_msg" || echo "ℹ️ 無新變更"
            echo "🚀 強制推送到分支: $CURRENT_BRANCH ..."
            git push origin "$CURRENT_BRANCH" --force
            echo "✅ [成功] GitHub 已被覆蓋"
        else
            echo "⏭️ 操作取消"
        fi
        ;;
    q)
        exit 0
        ;;
    *)
        echo "❌ 無效選項"
        exit 1
        ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ 任務完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"