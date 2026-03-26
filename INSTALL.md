# 安裝與部署指南

完整的伺服器安全加固工具部署指南。

---

## 📖 目錄

1. [前置條件](#前置條件)
2. [快速安裝](#快速安裝)
3. [詳細設定](#詳細設定)
4. [後續驗證](#後續驗證)
5. [常見問題](#常見問題)

---

## 前置條件

### 系統要求

```bash
✓ 作業系統: Ubuntu 24.04 LTS (推薦)
  ✓ 也支援其他 Debian 系統 (Ubuntu 22.04, 20.04, Debian 12 等)
✓ 根權限: root 或 sudo 無密碼設定
✓ 網路連線: 公網連線（下載 Tailscale）
✓ 磁碟空間: ≥ 200MB 可用空間
```

### 帳戶權限

```bash
# 檢查是否可不輸密碼執行 sudo
sudo -n true && echo "✅ 無密碼 sudo 已設定" || echo "❌ 需要 sudo 密碼"

# 若需設定無密碼 sudo
sudo EDITOR=nano visudo
# 添加此行 (OtisFR 替換實際用戶名)
# OtisFR ALL=(ALL) NOPASSWD:ALL
```

### 網路連接性檢查

```bash
# 測試公網連線
ping -c 3 8.8.8.8

# 測試 GitHub 連線
curl -I https://github.com

# 測試 Tailscale 服務可達性
curl -I https://login.tailscale.com
```

---

## 快速安裝

### 方法 1: 直接執行（推薦新用戶）

```bash
# 最簡單的方式 - 直接從 GitHub 拉取執行
curl -fsSL https://raw.githubusercontent.com/OtisFR/server-security/main/secure-deploy.sh | sudo bash

# 完成後會出現互動式菜單，選擇所需模式
```

### 方法 2: 下載後執行（推薦企業）

```bash
# 1. 下載腳本
curl -fsSL -o secure-deploy.sh https://raw.githubusercontent.com/OtisFR/server-security/main/secure-deploy.sh

# 2. 驗證檔案（可選但推薦）
curl -fsSL -o secure-deploy.sh.sha256 https://raw.githubusercontent.com/OtisFR/server-security/main/secure-deploy.sh.sha256
sha256sum -c secure-deploy.sh.sha256

# 3. 執行
sudo bash secure-deploy.sh
```

### 方法 3: 克隆整個倉庫（開發者推薦）

```bash
# 1. 克隆倉庫
git clone https://github.com/OtisFR/server-security.git
cd server-security

# 2. 檢查可用版本
cat VERSION

# 3. 執行
sudo bash secure-deploy.sh
```

---

## 詳細設定

### 步驟 1: 選擇部署模式

執行脚本後，會看到以下菜單：

```
╔═══════════════════════════════════════════════════════╗
║   伺服器安全加固工具 (Tailscale + UFW + Fail2Ban)   ║
╚═══════════════════════════════════════════════════════╝

請選擇安裝模式：

  【標準模式】(允許公網 SSH)
  1️⃣  基本 Tailscale 版 (無防火牆)
  2️⃣  安全強化版 (啟用 UFW)
  3️⃣  Exit Node 版 (啟用 UFW + 轉發)

  【零信任模式】(禁止公網 SSH)
  4️⃣  零信任安全版 (內網 SSH 限制)
  5️⃣  零信任 Exit Node 版 (內網 SSH + 轉發)

  q   退出

💬 [輸入] 請選擇選項 [1/2/3/4/5/q]: 
```

**選擇建議：**
- **新上線伺服器**: 選 2️⃣ (最均衡)
- **高安全需求**: 選 4️⃣ (極致隔離)
- **需要路由轉發**: 選 3️⃣ 或 5️⃣

### 步驟 2: IPv6 禁用

```
💬 [輸入] 是否徹底禁用 IPv6 以減少潛在攻擊面？ (y/n):
```

**推薦選擇:** `y` (針對純 IPv4 環境)

- ✅ **選 y**: 系統與防火牆雙層禁用 IPv6
- ❌ **選 n**: 保持 IPv6 啟用（不常用）

### 步驟 3: Fail2Ban 白名單設定

腳本會自動檢測當前 SSH 連線 IP：

```
📍 [偵測] 偵測到您的 SSH 連線 IP: 203.0.113.100
💬 [輸入] 是否將此 IP 加入白名單？ (y/n):
```

**推薦選擇:** `y` (保護自己免被封鎖)

然後會提示額外 IP：

```
💬 [輸入] 請輸入其他要加入白名單的 IP/CIDR (用逗號隔開):
```

**範例輸入：**
```
203.0.113.50/32, 203.0.113.0/24, 2001:db8::1/128
```

### 步驟 4: Tailscale 認證

腳本會出現：

```
════════════════════════════════════════════════════════
 🔐 [安全] 請完成 Tailscale 認證
════════════════════════════════════════════════════════

⏳ [等待] 正在啟動 Tailscale 登入流程...
📱 [操作] 請複製下方網址到瀏覽器中完成認證：

https://login.tailscale.com/a/XXXXXXXXXXXXX
```

**操作步驟：**
1. 複製上述 URL 到瀏覽器
2. 使用 Google/GitHub/Microsoft 帳號登入
3. 確認裝置添加
4. 等待腳本完成（通常 10-30 秒）

### 步驟 5: 部署完成

待腳本完成，會顯示摘要：

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 ✨ 部署與加固完成！
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 [摘要] 部署狀態
   - 安裝模式: 安全強化版
   
⚙️ [狀態] 服務運行狀態
   - Tailscale: ✅ [運行中] (IP: 100.100.100.50)
   - Fail2Ban:  ✅ [運行中]
   - UFW 防火牆: active
```

---

## 後續驗證

### 建立完成後立即檢查

```bash
# 1. 檢查 Tailscale 連線
tailscale status
# 應看到類似：
# 100.100.100.50    your-server              your-account@...   linux

# 2. 查看 Tailscale IP
tailscale ip -4
# 應出現類似: 100.100.100.50

# 3. 檢查 Fail2Ban 狀態
sudo fail2ban-client status sshd
# 應看到:
# Status for the jail sshd:
# |- Filter set to sshd
# |- Currently failed: 0
# |- Currently banned: 0
# `- Total banned: 0

# 4. 檢查 UFW 防火牆
sudo ufw status verbose
# 應看到:
# Status: active
```

### 長期監控

```bash
# 每日查看 Fail2Ban 日誌
sudo tail -20 /var/log/fail2ban/fail2ban.log

# 監控被封鎖 IP (實時)
watch -n 5 'sudo fail2ban-client status sshd'

# 檢查部署日誌
sudo tail -f /var/log/server-secure-deployment.log
```

---

## 常見問題

### Q1: 執行後無法 SSH 連線

**原因**: 可能是 UFW 規則配置問題

**解決方案**:
```bash
# 從本機控制台或 Tailscale 連線：

# 臨時禁用 UFW
sudo ufw disable

# 查看規則並刪除問題規則
sudo ufw status numbered
sudo ufw delete <NUMBER>

# 重新啟用
sudo ufw enable
```

### Q2: Tailscale 無法連線

**原因**: 可能是服務未啟動或網路問題

**解決方案**:
```bash
# 檢查服務狀態
sudo systemctl status tailscaled

# 查看日誌
sudo journalctl -u tailscaled -n 50

# 重啟服務
sudo systemctl restart tailscaled

# 重新認證
sudo tailscale logout
sudo tailscale up
```

### Q3: 被 Fail2Ban 誤封

**原因**: 登入失敗超過限制

**解決方案**:
```bash
# 查看被封 IP
sudo fail2ban-client status sshd

# 解除封鎖
sudo fail2ban-client set sshd unbanip 203.0.113.100

# 永久白名單
sudo nano /etc/fail2ban/jail.local
# 編輯 ignoreip 行，加上你的 IP
sudo systemctl restart fail2ban
```

### Q4: 升級到新版本

**解決方案**:
```bash
# 自動升級
curl -fsSL https://raw.githubusercontent.com/OtisFR/server-security/main/upgrade.sh | sudo bash
```

### Q5: 回復到舊版本

**解決方案**:
```bash
# 列出備份
ls -la /opt/server-security/backups/

# 恢復特定備份
sudo cp /opt/server-security/backups/backup_20260325_150000/secure-deploy.sh.bak /opt/server-security/secure-deploy.sh
```

---

## 👨‍💻 開發者指南

### 本地測試

```bash
# 語法驗證
bash -n secure-deploy.sh
bash -n setup_ssh_jail.sh
bash -n tailscale-installer.sh

# ShellCheck 靜態分析
shellcheck -x secure-deploy.sh
```

### 提交變更

```bash
# 1. 修改腳本
# 2. 執行本地測試
# 3. 更新 VERSION 檔案
# 4. 更新 CHANGELOG.md
# 5. 提交

git add .
git commit -m "fix: 修復 IPv6 禁用邏輯"
git push origin main
```

### 計算檔案哈希（安全驗證）

```bash
# 生成 SHA256 哈希
sha256sum secure-deploy.sh > secure-deploy.sh.sha256

# 驗證
sha256sum -c secure-deploy.sh.sha256
```

---

## 📞 支援與回報

- 🐛 **遇到 Bug**: 開設 [GitHub Issue](https://github.com/OtisFR/server-security/issues)
- 💡 **功能建議**: 提交 [GitHub Discussion](https://github.com/OtisFR/server-security/discussions)
- 🔧 **貢獻代碼**: 發送 [Pull Request](https://github.com/OtisFR/server-security/pulls)

---

**最後更新**: 2026-03-26
