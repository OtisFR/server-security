# 安裝與部署指南

伺服器安全加固工具 v2.0 的完整部署指南。

---

## 前置條件

```
✓ 作業系統: Ubuntu 24.04 LTS（推薦），其他 Debian 系（22.04 / Debian 12）大致相容
✓ 權限:    可執行 sudo 的帳號（互動輸入密碼即可，無需 NOPASSWD）
✓ 網路:    公網連線（下載套件與 Tailscale）
✓ 終端機:  互動式 TTY（腳本不支援 curl | bash 管線執行）
```

### 網路連通性檢查

```bash
ping -c 3 8.8.8.8
curl -I https://github.com
curl -I https://login.tailscale.com
```

---

## 安裝方式

### 方法 1：下載 + 驗證 + 執行（推薦）

```bash
# 1. 下載腳本與校驗檔（secure_ssh.sh 供步驟 5 的 SSH 金鑰強化使用）
curl -fsSL -O https://raw.githubusercontent.com/OtisFR/server-security/main/secure-deploy.sh
curl -fsSL -O https://raw.githubusercontent.com/OtisFR/server-security/main/secure_ssh.sh
curl -fsSL -O https://raw.githubusercontent.com/OtisFR/server-security/main/checksums.sha256

# 2. 驗證完整性（必須看到每個檔案 OK）
sha256sum --ignore-missing -c checksums.sha256

# 3. 執行
sudo bash secure-deploy.sh
```

### 方法 2：克隆倉庫（開發者）

```bash
git clone https://github.com/OtisFR/server-security.git
cd server-security
sha256sum -c checksums.sha256   # 驗證
sudo bash secure-deploy.sh
```

---

## 部署流程說明

### 步驟 1：選擇配置

```
  1️⃣  基礎防護   UFW + Fail2Ban（公網 SSH 保持開放）
  2️⃣  標準加固   基礎防護 + Tailscale VPN（公網 SSH 保持開放）
  3️⃣  零信任隔離 標準加固 + SSH 僅限 Tailscale 內網連入
```

**選擇建議：**

- 沒有 VPN 需求 → `1`
- 新伺服器、想先熟悉 Tailscale → `2`（之後可重跑選 `3` 收緊）
- 生產環境、要求最高安全性 → `3`

### 步驟 2：附加選項（依配置詢問）

- **停用 IPv6**：純 IPv4 環境建議 `y`。腳本會先檢查你目前的連線是否走 IPv6（是的話會警告），且只有在核心層確認停用成功後才會關閉 UFW 的 IPv6 過濾
- **Exit Node**（配置 2/3）：需要出口節點路由時選 `y`，完成後記得到 [Tailscale 管理頁](https://login.tailscale.com/admin/machines) 啟用

### 步驟 3：Tailscale 認證（配置 2/3）

畫面出現認證網址後，複製到瀏覽器完成登入。**零信任配置會等 Tailscale 驗證成功後才封鎖公網 SSH**，認證失敗時防火牆不會有任何變更。

### 步驟 4：Fail2Ban 白名單

腳本會偵測你目前的連線 IP 並詢問是否加入白名單（建議 `y`），也可輸入其他 IP/CIDR（逗號分隔，格式會逐一驗證）。

### 步驟 5：SSH 金鑰強化（建議）

部署完成後：

```bash
# 先確認一般使用者的 ~/.ssh/authorized_keys 已放好公鑰
sudo bash secure_ssh.sh
```

---

## 後續驗證

```bash
tailscale status                      # Tailscale 連線
sudo fail2ban-client status sshd      # Fail2Ban 狀態
sudo ufw status verbose               # 防火牆規則
sudo sshd -T | grep -iE 'passwordauthentication|port'   # SSH 有效設定
sudo tail -f /var/log/server-security-deploy.log        # 部署日誌
```

---

## 常見問題

### Q1: 零信任配置後無法 SSH 連線

透過主機商 Console 登入後：

```bash
sudo ufw disable
sudo ufw status numbered   # 檢查規則
sudo ufw enable
```

### Q2: 被 Fail2Ban 誤封

```bash
sudo fail2ban-client set sshd unbanip <你的IP>
# 永久白名單：編輯 /etc/fail2ban/jail.local 的 ignoreip，然後
sudo systemctl restart fail2ban
```

### Q3: SSH 加固後想還原密碼登入

```bash
sudo rm /etc/ssh/sshd_config.d/00-hardening.conf
sudo systemctl restart ssh
```

### Q4: 升級到新版本

```bash
curl -fsSL -O https://raw.githubusercontent.com/OtisFR/server-security/main/upgrade.sh
curl -fsSL -O https://raw.githubusercontent.com/OtisFR/server-security/main/checksums.sha256
sha256sum --ignore-missing -c checksums.sha256
sudo bash upgrade.sh
```

### Q5: 回復到舊版本

```bash
ls -la /opt/server-security/backups/
sudo cp /opt/server-security/backups/backup_<時間戳>/secure-deploy.sh.bak /opt/server-security/secure-deploy.sh
```

---

## 👨‍💻 開發者指南

### 本地測試

```bash
# 語法驗證 + 靜態分析（CI 也會強制執行）
for f in *.sh; do bash -n "$f"; done
shellcheck --severity=warning secure-deploy.sh secure_ssh.sh upgrade.sh zabbix-agent2-install.sh update-checksums.sh
```

### 提交變更

```bash
# 1. 修改腳本並通過本地測試
# 2. 更新 VERSION 與 CHANGELOG.md
# 3. 重新產生校驗和（會同步 checksums.sha256 與 README 校驗表）
bash update-checksums.sh --no-git
# 4. 提交（CI 會驗證校驗和一致性）
git add -A && git commit -m "feat: ..." && git push
```

---

## 📞 支援與回報

- 🐛 Bug：[GitHub Issues](https://github.com/OtisFR/server-security/issues)
- 🔐 安全性弱點：見 [SECURITY.md](SECURITY.md)
- 🔧 貢獻：[Pull Requests](https://github.com/OtisFR/server-security/pulls)
