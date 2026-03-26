# 🔐 服務器安全加固整合工具

[![Bash](https://img.shields.io/badge/bash-5.1+-green)](https://www.gnu.org/software/bash/)
[![Ubuntu](https://img.shields.io/badge/ubuntu-24.04-orange)](https://ubuntu.com/)
[![License](https://img.shields.io/badge/license-MIT-blue)](#license)

一套完整的伺服器安全加固工具，整合 **Tailscale** (零信任 VPN)、**UFW** (防火牆)、**Fail2Ban** (暴力破解防護) 於一體。支援 5 種部署模式，從基本安裝到企業級零信任隔離。

---

## 📚 工具清單

| 工具 | 用途 | 功能 |
|------|------|------|
| **secure-deploy.sh** | 統合部署 | 三合一完整解決方案（推薦首選） |
| **setup_ssh_jail.sh** | SSH 防禦 | 專用 Fail2Ban + UFW 配置 |
| **tailscale-installer.sh** | VPN 部署 | 5 種 Tailscale 部署模式 |

---

## 🚀 快速開始

### 最簡單的方式（推薦）

```bash
# 直接從 GitHub 拉取並執行（自動應用最新版本）
curl -fsSL https://raw.githubusercontent.com/OtisFR/server-security/main/secure-deploy.sh | sudo bash
```

### 安全驗證版本（企業推薦）

```bash
# 下載並驗證後執行
curl -fsSL -o secure-deploy.sh https://raw.githubusercontent.com/OtisFR/server-security/main/secure-deploy.sh
sha256sum -c secure-deploy.sh.sha256 && sudo bash secure-deploy.sh
```

---

## 🎯 5 種部署模式

### 標準模式（允許公網 SSH）

| 模式 | 防火牆 | Fail2Ban | Exit Node | 使用場景 |
|------|--------|----------|-----------|---------|
| **1. 基本版** | ❌ | ✅ | ❌ | 簡單測試、開發環境 |
| **2. 安全強化版** | ✅ | ✅ | ❌ | 生產環境（標準） |
| **3. Exit Node 版** | ✅ | ✅ | ✅ | 需要路由轉發的伺服器 |

### 零信任模式（僅 Tailscale SSH）

| 模式 | 公網 SSH | 內網 Fail2Ban | Exit Node | 安全等級 |
|------|---------|---------------|-----------|---------|
| **4. 零信任安全版** | 🔒 封鎖 | ✅ | ❌ | ⭐⭐⭐⭐⭐ 極高 |
| **5. 零信任 Exit Node** | 🔒 封鎖 | ✅ | ✅ | ⭐⭐⭐⭐⭐ 極高 |

---

## 📋 詳細安裝步驟

### 先決條件

```bash
# 確保系統要求
- OS: Ubuntu 24.04 LTS（或相容的 Debian 系統）
- 權限: root 或 sudo 不需密碼
- 網路: 公網連線（下載 Tailscale）
```

### 執行安裝

```bash
# 標準部署流程
1. SSH 登入伺服器
   ssh user@your-server.com

2. 執行部署腳本
   curl -fsSL https://raw.githubusercontent.com/OtisFR/server-security/main/secure-deploy.sh | sudo bash

3. 選擇部署模式（1-5 或 q）
   - 根據需求選擇對應模式

4. 按提示完成設定
   - IPv6 禁用？(推薦 y)
   - 白名單 IP 設定
   - Tailscale 認證（掃描 QR Code 或點擊連結）
```

### 後續驗證

```bash
# 檢查服務狀態
sudo systemctl status tailscaled
sudo systemctl status fail2ban
sudo ufw status

# 查看 Fail2Ban 封鎖列表
sudo fail2ban-client status sshd

# 查看部署日誌
sudo tail -f /var/log/server-secure-deployment.log
```

---

## 🔒 安全功能詳解

### Fail2Ban 防禦策略
```
📊 防禦規則：5 次失敗在 5 分鐘內 → 自動封鎖 2 小時

💡 設計原理：
  - 標準掃描工具通常嘗試 3-5 次就會放棄
  - 2 小時足以阻擋自動化掃描波次
  - 誤傷風險低：正常用戶不會短時間內失敗 5 次
```

### Tailscale 零信任隔離
```
🛡️ 零信任模式安全特性：
  ✅ 公網 SSH 完全封鎖
  ✅ 只允許 Tailscale 網段 (100.64.0.0/10) 連入
  ✅ 出站連線不受限（內網訪問正常）
  ✅ 可配置 Exit Node 用於路由轉發
```

### IPv6 徹底禁用
```
🔐 雙層禁用策略：
  1️⃣ 核心層級：/etc/sysctl.d/99-disable-ipv6.conf
  2️⃣ 防火牆層級：UFW 設定 IPV6=no
  3️⃣ 驗證檢查：確保 /proc/sys/net/ipv6/conf/all/disable_ipv6 = 1
```

---

## 🛠️ 常用管理指令

### Fail2Ban 管理

```bash
# 查看所有被封鎖的 IP
sudo fail2ban-client status sshd

# 解除特定 IP 的臨時封鎖
sudo fail2ban-client set sshd unbanip 192.168.1.100

# 永久加入白名單
sudo nano /etc/fail2ban/jail.local
# 編輯 [DEFAULT] 區塊的 ignoreip，加上新 IP
sudo systemctl restart fail2ban
```

### UFW 防火牆管理

```bash
# 查看所有規則（含編號）
sudo ufw status numbered

# 刪除特定規則
sudo ufw delete 1

# 臨時允許特定 IP 的 SSH
sudo ufw allow from 203.0.113.100 to any port 22

# 啟用/禁用防火牆
sudo ufw enable
sudo ufw disable
```

### Tailscale 管理

```bash
# 查看 Tailscale 狀態
tailscale status

# 查看本機 IP
tailscale ip -4
tailscale ip -6

# 重新認證
sudo tailscale logout && sudo tailscale up

# 設定 Exit Node（在 https://login.tailscale.com/admin/machines）
```

---

## 📝 配置文件位置

| 文件 | 路徑 | 用途 |
|------|------|------|
| Fail2Ban 配置 | `/etc/fail2ban/jail.local` | SSH 防禦規則 + 白名單 |
| UFW 設定 | `/etc/default/ufw` | IPv6 禁用配置 |
| IPv6 禁用 | `/etc/sysctl.d/99-disable-ipv6.conf` | 核心層級 IPv6 禁用 |
| Tailscale 設定 | `/etc/tailscale/` | VPN 配置文件 |
| 部署日誌 | `/var/log/server-secure-deployment.log` | 完整部署記錄 |

---

## 🔄 自動更新

### 檢查更新

```bash
# 手動檢查（建議定期執行）
curl -s https://raw.githubusercontent.com/OtisFR/server-security/main/VERSION

# 如發現新版本，執行升級腳本
curl -fsSL https://raw.githubusercontent.com/OtisFR/server-security/main/upgrade.sh | sudo bash
```

### 自動更新（Cron 任務）

```bash
# 編輯 crontab（每週一 02:00 檢查更新）
sudo crontab -e

# 添加以下行
0 2 * * 1 curl -fsSL https://raw.githubusercontent.com/OtisFR/server-security/main/upgrade.sh | bash
```

---

## ⚠️ 重要注意事項

### 零信任模式風險

```
🚨 【極其重要】使用零信任模式時：

1. 確保已配置 Tailscale 認證
   - 執行前務必已能訪問 https://login.tailscale.com

2. Tailscale 啟動可能需要 30-60 秒
   - 若連線中斷，需透過 Tailscale IP 才能重新連入

3. 臨時 IP 白名單
   - 腳本會自動暫時放行當前 IP（建議腳本完成後手動移除）
   - 指令：sudo ufw delete allow from <IP> to any port 22 proto tcp
```

### 備份與恢復

```bash
# Fail2Ban 配置備份（自動生成）
ls -la /etc/fail2ban/jail.local.bak.*

# 恢復備份
sudo cp /etc/fail2ban/jail.local.bak.20260326_120000 /etc/fail2ban/jail.local
sudo systemctl restart fail2ban
```

---

## 🐛 故障排除

### 問題 1: Tailscale 無法認證

```bash
# 檢查服務狀態
sudo systemctl status tailscaled

# 查看日誌
sudo journalctl -u tailscaled -n 50

# 重新啟動服務
sudo systemctl restart tailscaled
```

### 問題 2: UFW 執行後無法 SSH

```bash
# 緊急恢復（若無法連線）
# 在本機或透過 Tailscale 連線

# 暫時禁用 UFW
sudo ufw disable

# 查看並刪除有問題的規則
sudo ufw status numbered
sudo ufw delete <NUMBER>

# 重新啟用
sudo ufw enable
```

### 問題 3: Fail2Ban 沒有工作

```bash
# 檢查語法
sudo fail2ban-client -t

# 查看日誌
sudo tail -f /var/log/fail2ban/fail2ban.log

# 重啟服務
sudo systemctl restart fail2ban
```

---

## 📊 部署結果範例

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 ✨ 部署與加固完成！
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 [摘要] 部署狀態
   - 安裝模式: 零信任安全版

⚙️ [狀態] 服務運行狀態
   - Tailscale: ✅ [運行中] (IP: 100.100.100.50)
   - Fail2Ban:  ✅ [運行中]
   - UFW 防火牆: active
   - SSH 服務:  ✅ [運行中]

🛡️ [安全] 【重要提示】: 公網 SSH 已被封鎖！
   未來請務必使用 Tailscale 內網 IP (100.100.100.50) 連線此伺服器。

🔍 [指令] 常用防護管理指令
   - 查看 Fail2Ban 封鎖名單: sudo fail2ban-client status sshd
   - 解除特定 IP 封鎖: sudo fail2ban-client set sshd unbanip <IP>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 📄 License

MIT License - 詳見 [LICENSE](LICENSE) 文件

---

## 🤝 貢獻

歡迎提交 Issue 與 Pull Request！

---

## 👨‍💻 作者

Created with ❤️ for server security

---

## 📞 支援

遇到問題？查看 [Troubleshooting](#-故障排除) 或提交 Issue
