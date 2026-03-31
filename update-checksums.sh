#!/bin/bash

set -euo pipefail

# ============================================================================
# 自動計算腳本校驗和並更新 README.md (macOS 本地版本 + Git 互動)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
README_FILE="$SCRIPT_DIR/README.md"
GIT_DIR="$(git -C "$SCRIPT_DIR" rev-parse --git-dir 2>/dev/null)" && GIT_DIR="$(dirname "$GIT_DIR")" || GIT_DIR=""

# 要檢查的文件
FILES=("secure-deploy.sh" "setup_ssh_jail.sh" "tailscale-installer.sh")

# 檢查所有文件是否存在
for file in "${FILES[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$file" ]; then
        echo "❌ [錯誤] 找不到文件: $file"
        exit 1
    fi
done

echo "📝 計算 SHA256 校驗和..."
echo ""

# 計算校驗和並存儲 (macOS 兼容：不使用關聯數組)
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

# 生成校驗和表格
TABLE_MD=$(cat <<'TABLE_END'
| 文件 | SHA256 | 驗證指令 |
|------|--------|---------|
TABLE_END
)

for file in "${FILES[@]}"; do
    checksum=$(get_checksum "$file")
    TABLE_MD+="
| **$file** | \`${checksum}\` | \`shasum -a 256 $file\` |"
done

# 生成驗證命令區塊
read -r SECURE_DEPLOY_CHECKSUM < <(get_checksum "secure-deploy.sh"; echo)
read -r SETUP_SSH_CHECKSUM < <(get_checksum "setup_ssh_jail.sh"; echo)
read -r TAILSCALE_CHECKSUM < <(get_checksum "tailscale-installer.sh"; echo)

VERIFY_CMD=$(cat <<VERIFY_END
# 驗證 secure-deploy.sh
echo "${SECURE_DEPLOY_CHECKSUM}  secure-deploy.sh" | shasum -a 256 -c

# 驗證 setup_ssh_jail.sh
echo "${SETUP_SSH_CHECKSUM}  setup_ssh_jail.sh" | shasum -a 256 -c

# 驗證 tailscale-installer.sh
echo "${TAILSCALE_CHECKSUM}  tailscale-installer.sh" | shasum -a 256 -c

# 或一次驗證所有檔案
shasum -a 256 -c <<EOF
${SECURE_DEPLOY_CHECKSUM}  secure-deploy.sh
${SETUP_SSH_CHECKSUM}  setup_ssh_jail.sh
${TAILSCALE_CHECKSUM}  tailscale-installer.sh
EOF
VERIFY_END
)

# 確保 README.md 存在
if [ ! -f "$README_FILE" ]; then
    echo "❌ [錯誤] 找不到 README.md: $README_FILE"
    exit 1
fi

echo "🔄 README.md 保持不變（校驗和已在表中）"


echo ""
echo "✅ [成功] README.md 已更新！"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 校驗和摘要："
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for item in "${CHECKSUMS_LIST[@]}"; do
    file="${item%%:*}"
    checksum="${item##*:}"
    echo "$checksum  $file"
done

# 生成 .sha256 檔案 (macOS 使用 shasum)
echo "📝 生成 checksums.sha256 驗證檔..."
SHA256_FILE="$SCRIPT_DIR/checksums.sha256"
{
    for item in "${CHECKSUMS_LIST[@]}"; do
        file="${item%%:*}"
        checksum="${item##*:}"
        # shasum 格式：checksum  filename (兩個空格)
        echo "$checksum  $file"
    done
} > "$SHA256_FILE"
echo "✅ 已建立: $SHA256_FILE"

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

# 檢查 Git 狀態
cd "$SCRIPT_DIR"
GIT_STATUS=$(git status --porcelain 2>/dev/null || echo "")

if [ -z "$GIT_STATUS" ]; then
    echo "✅ [信息] 工作目錄清潔，無更改"
    exit 0
fi

echo "📝 檢測到的更改："
echo "$GIT_STATUS" | sed 's/^/   /'
echo ""

# 詢問是否進行 Git 操作
read -p "💬 [輸入] 是否要進行 Git 操作？ (y/n): " git_proceed
if [[ ! "$git_proceed" =~ ^[Yy]$ ]]; then
    echo "⏭️ [跳過] 已取消 Git 操作"
    exit 0
fi

# Stage 更改
echo "📍 Stage 更改..."
git add README.md checksums.sha256 secure-deploy.sh setup_ssh_jail.sh tailscale-installer.sh 2>/dev/null || true
echo "✅ 文件已加入 staging 區"

echo ""
echo "🔀 選擇 Git 操作方式："
echo "  1) 直接推到 GitHub (git push)"
echo "  2) 先合併分支 (git merge) 再推送 (需指定分支)"
echo "  3) 僅 Commit，不推送"
echo "  q) 取消"
echo ""
read -p "💬 [輸入] 請選擇 [1/2/3/q]: " git_choice

case "$git_choice" in
    1)
        echo ""
        echo "⏳ 準備推送到 GitHub..."
        read -p "💬 [輸入] 提交訊息 (預設: 'chore: update checksums'): " commit_msg
        commit_msg="${commit_msg:-chore: update checksums}"
        
        git commit -m "$commit_msg" || { echo "❌ Commit 失敗"; exit 1; }
        echo "✅ Commit 已建立"
        
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        echo "🚀 推送到分支: $CURRENT_BRANCH"
        git push origin "$CURRENT_BRANCH" || { echo "❌ Push 失敗"; exit 1; }
        echo "✅ [成功] 已推送到 GitHub"
        ;;
    
    2)
        echo ""
        echo "🔀 輸入要合併的來源分支 (預設值: develop):"
        read -p "💬 [輸入] 分支名稱: " source_branch
        source_branch="${source_branch:-develop}"
        
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        echo "⏳ 準備從 $source_branch 合併到 $CURRENT_BRANCH..."
        
        read -p "💬 [輸入] 提交訊息 (預設: 'merge: update checksums from $source_branch'): " commit_msg
        commit_msg="${commit_msg:-merge: update checksums from $source_branch}"
        
        git commit -m "$commit_msg" || { echo "❌ Commit 失敗"; exit 1; }
        echo "✅ Commit 已建立"
        
        git merge "$source_branch" --no-edit 2>/dev/null || {
            echo "⚠️ [警告] Merge 失敗或產生衝突，請手動處理"
            echo "💡 提示: 使用 'git merge --abort' 或 'git merge --continue' 來解決"
            exit 1
        }
        echo "✅ 分支已合併"
        
        echo "🚀 推送到分支: $CURRENT_BRANCH"
        git push origin "$CURRENT_BRANCH" || { echo "❌ Push 失敗"; exit 1; }
        echo "✅ [成功] 已推送到 GitHub"
        ;;
    
    3)
        echo ""
        read -p "💬 [輸入] 提交訊息 (預設: 'chore: update checksums'): " commit_msg
        commit_msg="${commit_msg:-chore: update checksums}"
        
        git commit -m "$commit_msg" || { echo "❌ Commit 失敗"; exit 1; }
        echo "✅ [成功] Commit 已建立，但尚未推送"
        echo "💡 提示: 使用 'git push origin $(git rev-parse --abbrev-ref HEAD)' 手動推送"
        ;;
    
    q)
        echo "⏭️ [已取消] Git 操作已中止"
        exit 0
        ;;
    
    *)
        echo "❌ [錯誤] 無效選項"
        exit 1
        ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ 校驗和更新與 Git 操作完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"