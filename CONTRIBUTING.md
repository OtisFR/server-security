# 貢獻指南 (Contributing Guide)

感謝您對本項目的興趣！❤️

這是一個歡迎所有改進建議和 Pull Request 的開源項目。

---

## 📋 目錄

1. [行為準則](#行為準則)
2. [如何貢獻](#如何貢獻)
3. [報告 Bug](#報告-bug)
4. [提出功能建議](#提出功能建議)
5. [提交 Pull Request](#提交-pull-request)
6. [編碼風格](#編碼風格)
7. [提交訊息規範](#提交訊息規範)

---

## 行為準則

### 我們的承諾

我們歡迎：
- ✅ 所有背景和經驗水平的貢獻者
- ✅ 包容、尊重和建設性的討論
- ✅ 誠實和透明的溝通

我們不能容忍：
- ❌ 騷擾或歧視行為
- ❌ 人身攻擊或辱罵
- ❌ 在任何互動中不尊重他人

**違反行為準則的參與者將被移除。**

---

## 如何貢獻

### 🐛 報告 Bug

發現問題？以下是最佳實踐：

#### 1. 搜索現有 Issues
先檢查是否已有人報告相同問題。

#### 2. 提供完整信息
提交 Issue 時請包含：

```markdown
## Bug 描述
清楚簡潔地描述問題。

## 復現步驟
1. 執行命令...
2. 選擇選項...
3. ...

## 預期行為
應該發生什麼

## 實際行為
實際發生了什麼

## 系統環境
- OS: Ubuntu 24.04
- Bash 版本: $(bash --version)
- 部署模式: 安全強化版
- 完整錯誤訊息:
  ```
  [複製完整錯誤輸出]
  ```

## 日誌檔案
```bash
# 部署日誌
sudo tail -50 /var/log/server-secure-deployment.log
```
```

#### 3. 附加診斷信息

```bash
# 系統信息
uname -a
lsb_release -a

# Tailscale 狀態
tailscale status

# Fail2Ban 狀態
sudo fail2ban-client status sshd

# UFW 規則
sudo ufw status numbered
```

---

### 💡 提出功能建議

有新想法？太好了！

#### 1. 檢查現有討論
看看是否有 [Discussion](https://github.com/OtisFR/server-security/discussions)

#### 2. 清楚描述功能

```markdown
## 功能概述
簡明扼要的說明新功能

## 使用場景
什麼情況下需要這個功能？

## 預期行為
如何使用這個功能？

## 替代方案
現有解決方案是什麼？

## 相關配置
```bash
# 可能的配置選項
```
```

#### 3. 討論實現方案
開啟 Discussion 收集反饋意見

---

## 提交 Pull Request

### 0️⃣ 準備工作

```bash
# 1. Fork 這個倉庫
# 2. Clone 你的 fork
git clone https://github.com/OtisFR/server-security.git
cd server-security

# 3. 添加上游遠程
git remote add upstream https://github.com/ORIGINAL_AUTHOR/server-security.git

# 4. 創建功能分支
git checkout -b feature/your-feature-name
# 或
git checkout -b fix/your-bug-fix-name
```

### 1️⃣ 本地開發

```bash
# 編輯文件
nano secure-deploy.sh

# 測試語法
bash -n secure-deploy.sh

# 靜態分析
shellcheck -x secure-deploy.sh

# 實際測試（在測試環境）
sudo bash secure-deploy.sh
```

### 2️⃣ 測試清單

提交前請檢查：

- [ ] ✅ Bash 語法通過 (`bash -n`)
- [ ] ✅ ShellCheck 無關鍵問題
- [ ] ✅ 行尾無空白
- [ ] ✅ 無 Tab 字符（使用空格）
- [ ] ✅ UTF-8 編碼
- [ ] ✅ 邏輯測試通過
- [ ] ✅ 更新 CHANGELOG.md
- [ ] ✅ 更新 VERSION（若有版本變化）
- [ ] ✅ 文檔更新（如適用）

### 3️⃣ 提交更改

```bash
# 同步最新代碼
git fetch upstream
git rebase upstream/main

# 提交
git add .
git commit -m "fix: 修復 IPv6 禁用邏輯 (#123)"

# 推送到你的 fork
git push origin feature/your-feature-name
```

### 4️⃣ 建立 Pull Request

在 GitHub 上：
1. 點擊「New Pull Request」
2. 選擇 `main` 分支
3. 填寫 PR 模板：

```markdown
## 描述
簡要說明此 PR 的目的

## 相關 Issue
fixes #123

## 更改類型
- [ ] 🐛 Bug 修復
- [ ] ✨ 新功能
- [ ] 📖 文檔更新
- [ ] 🔧 配置更改

## 測試
說明如何測試此更改

## 檢查清單
- [x] 我的代碼遵循項目風格
- [x] 新增功能已添加測試
- [x] 文檔已更新
- [x] 沒有新的警告/錯誤
```

### 5️⃣ 審查與合併

- 等待 CI/CD 通過
- 回應審查者的評論
- 進行必要的修改
- 一旦批准，PR 將被合併

---

## 編碼風格

### Bash 編碼規範

#### 1. Shebang 與嚴格模式

```bash
#!/bin/bash

set -euo pipefail  # 必需
```

#### 2. 變數命名

```bash
# 常數: UPPER_CASE
DEPLOY_LOG="/var/log/deployment.log"

# 函數變數: snake_case
local current_ip="192.168.1.1"

# 全局變數: UPPER_CASE_WITH_UNDERSCORE
SCRIPT_DIR="/opt/scripts"
```

#### 3. 函數定義

```bash
# 正確做法
function_name() {
    # 函數體
    echo "Hello from function"
}

# 調用
function_name
```

#### 4. 錯誤處理

```bash
# ❌ 不好 - 沉默失敗
command || true

# ✅ 好 - 明確處理
if ! command; then
    echo "❌ [錯誤] 命令失敗"
    return 1
fi

# ✅ 更好 - 清楚的日誌
command || { 
    echo "❌ [錯誤] 命令失敗"
    exit 1
}
```

#### 5. 字串引用

```bash
# ✅ 優先使用雙引號（允許變數展開）
echo "Hello $name"

# ✅ 複雜表達式使用雙引號
echo "Count: ${#array[@]}"

# ✅ 單引號用於字面意義
echo 'No variable expansion here'
```

#### 6. 條件判斷

```bash
# ✅ 使用 [[ ]] (更安全)
if [[ -f "$file" ]]; then
    echo "File exists"
fi

# ❌ 避免使用 [ ]
# if [ -f "$file" ]; then

# ✅ 正確的邏輯操作符
if [[ $var1 && $var2 ]]; then
    echo "Both true"
fi
```

#### 7. 迴圈

```bash
# ✅ 推薦風格
for item in "${array[@]}"; do
    echo "$item"
done

# ✅ 範圍迴圈
for ((i=0; i<10; i++)); do
    echo "$i"
done

# ❌ 避免
# for item in $list  # 會被分詞
```

#### 8. 註釋

```bash
# ✅ 清楚的功能註釋
# 檢查 SSH 連線是否啟用
if systemctl is-enabled ssh &> /dev/null; then

# ✅ 複雜部分的解釋
# 嘗試從 SSH_CLIENT 或 who 命令偵測 IP
CURRENT_IP="${SSH_CLIENT%% *}" || CURRENT_IP=$(who am i | awk '{print $NF}')

# ❌ 避免明顯的註釋
# count = 1  # 設置計數為 1
```

---

## 提交訊息規範

### 格式

```
<type>(<scope>): <subject>
<空行>
<body>
<空行>
<footer>
```

### 類型 (type)

```
fix:       🐛 Bug 修復
feat:      ✨ 新功能
docs:      📖 文檔
style:     🎨 代碼風格（不改邏輯）
refactor:  🔧 重構
perf:      ⚡ 性能改進
test:      ✅ 測試
chore:     📦 構建/依賴
ci:        🤖 CI/CD 配置
```

### 範例

```
fix(fail2ban): 修復 IPv6 禁用後的白名單驗證問題

之前在禁用 IPv6 後，白名單中的 IPv6 地址會導致
Fail2Ban 啟動失敗。現在先過濾掉禁用 IPv6 時的 
IPv6 條目。

fixes #123

BREAKING CHANGE: IPv6 地址現在在禁用 IPv6 模式下被自動過濾
```

### 建議

```
# ✅ 好的提交訊息
git commit -m "fix: 修復在容器環境中 sysctl 失敗的問題

在某些容器環境中，sysctl 不被允許執行。
添加了檢查機制允許優雅降級。

fixes #42"

# ❌ 不好的提交訊息
git commit -m "fixed stuff"
```

---

## 📊 審查流程

1. **自動檢查** (✅ 必需通過)
   - Bash 語法驗證
   - ShellCheck 靜態分析
   - 文件編碼檢查

2. **人工審查** (⏳ 1-3 天)
   - 代碼質量
   - 邏輯正確性
   - 安全問題
   - 文檔完整性

3. **測試** (✅ 推薦)
   - 在 Ubuntu 24.04 上測試
   - 各部署模式測試
   - 回滾測試（如適用）

4. **合併** (✅ 已批准)
   - 所有檢查通過
   - 至少 1 位維護者同意
   - PR 已更新至最新 main

---

## 🎉 感謝

非常感謝您的貢獻！每一個改進都幫助了整個社區。

---

**最後更新**: 2026-03-26
