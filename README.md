# 🔐 伺服器安全加固工具

[![Bash](https://img.shields.io/badge/bash-5.1+-green)](https://www.gnu.org/software/bash/)
[![Ubuntu](https://img.shields.io/badge/ubuntu-24.04-orange)](https://ubuntu.com/)
[![License](https://img.shields.io/badge/license-MIT-blue)](#-license)

一套伺服器安全加固工具，整合 **UFW**（防火牆）、**Fail2Ban**（暴力破解防護）、**Tailscale**（零信任 VPN）。

**v2.0 設計原則：**

1. **絕不鎖死自己** —— 零信任配置一律「先驗證 Tailscale 連線成功，才封鎖公網 SSH」；防火牆變更失敗會自動回滾
2. **驗證有效值** —— SSH 加固會用 `sshd -T` 確認實際生效的設定（正確處理 `sshd_config.d/` 覆蓋問題），不是只看指令有沒有跑完
3. **下載必驗證** —— 所有安裝與升級流程都走「下載 → SHA256 驗證 → 執行」，不使用 `curl | bash`

---

## 📚 工具清單

| 腳本 | 用途 |
|------|------|
| **secure-deploy.sh** | 主部署工具：3 種配置（基礎防護／標準加固／零信任隔離）+ 附加選項 |
| **secure_ssh.sh** | SSH 金鑰強化：停用密碼登入（drop-in 方式 + 有效值驗證 + 防鎖死檢查） |
| **upgrade.sh** | 升級工具：下載新版並強制 SHA256 驗證後安裝 |
| **zabbix-agent2-install.sh** | Zabbix Agent 2 安裝（Ubuntu 24.04 / Zabbix 7.0） |
| **update-checksums.sh** | （維護用）重新計算並同步所有校驗和 |

> 舊版的 `tailscale-installer.sh` 與 `setup_ssh_jail.sh` 已由 `secure-deploy.sh` 取代，封存於 [`legacy/`](legacy/)。

---

## 🎯 部署配置（v2.0 新設計）

執行 `secure-deploy.sh` 後選擇一種配置，附加選項會依配置逐一詢問：

| 配置 | UFW | Fail2Ban | Tailscale | 公網 SSH | 適用場景 |
|------|-----|----------|-----------|----------|----------|
| **1. 基礎防護** | ✅ | ✅ | ❌ | ✅ 開放 | 無 VPN 需求的一般伺服器 |
| **2. 標準加固** | ✅ | ✅ | ✅ | ✅ 開放 | 想先熟悉 Tailscale 再收緊 |
| **3. 零信任隔離** | ✅ | ✅ | ✅ | 🔒 封鎖 | 生產環境（最高安全性） |

**附加選項**（依配置詢問）：

- **Exit Node**（配置 2/3）：將此機器設為 Tailscale 出口節點
- **停用 IPv6**：含安全檢查——若目前連線走 IPv6 會先警告；核心層停用失敗時**不會**關閉 UFW 的 IPv6 過濾（避免 IPv6 流量不設防）
- **SSH 金鑰強化**：部署完成後另行執行 `secure_ssh.sh`

**零信任配置的安全順序**：安裝 Tailscale → 登入並**驗證取得內網 IP** → 這時才封鎖公網 SSH → 封鎖後再次驗證 Tailscale 可用，失敗自動回滾。並自動偵測 sshd 實際監聽埠（不假設一定是 22）。

---

## 🚀 快速開始

### 安裝（下載 → 驗證 → 執行）

```bash
# 1. 下載腳本與校驗檔
curl -fsSL -O https://raw.githubusercontent.com/OtisFR/server-security/main/secure-deploy.sh
curl -fsSL -O https://raw.githubusercontent.com/OtisFR/server-security/main/secure_ssh.sh
curl -fsSL -O https://raw.githubusercontent.com/OtisFR/server-security/main/checksums.sha256

# 2. 驗證（必須看到每個檔案: OK）
sha256sum --ignore-missing -c checksums.sha256

# 3. 執行
sudo bash secure-deploy.sh
```

> ⚠️ 腳本需要互動式終端機，**不支援** `curl | sudo bash` 直接執行（會被腳本主動拒絕）。

### 或克隆整個倉庫

```bash
git clone https://github.com/OtisFR/server-security.git
cd server-security
sudo bash secure-deploy.sh
```

### SSH 金鑰強化（建議在部署後執行）

```bash
# 先確認你的一般使用者已放好公鑰（~/.ssh/authorized_keys），再執行：
sudo bash secure_ssh.sh
```

腳本會：檢查**實際登入者**（而非 root）的公鑰 → 寫入 `/etc/ssh/sshd_config.d/00-hardening.conf` → `sshd -t` 語法檢查 → 重啟 → 用 `sshd -T` **驗證實際生效值**，任一步失敗自動還原備份。

---

## ✅ 檔案校驗和 (SHA256)

`checksums.sha256` 為唯一事實來源，下方表格由 `update-checksums.sh` 自動同步，CI 會驗證三者一致：

<!-- CHECKSUMS START -->
| 文件 | SHA256 |
|------|--------|
| **secure-deploy.sh** | `56ae9a7f75b003be3d70edba2c72ddad4d91af6706c908696fd20326ee6fc56f` |
| **secure_ssh.sh** | `c03751fe49dbdaa1b0d817360d0c70fc938122478e44c96c5ae251eac7e3690e` |
| **upgrade.sh** | `afa31a0212643db0ab9af14cbe8197288f8c9737b7e96e2ef7ef98d1c373c935` |
| **zabbix-agent2-install.sh** | `58084bc6a514c31e17f342adef7d72ef003e3bdaf90210960c651ea5b5d8f3e2` |
| **update-checksums.sh** | `b559fdf263d535ffa1507d5b39bd41336001086cff4b547d5d9fe8c7de168a63` |
<!-- CHECKSUMS END -->

```bash
# 一次驗證所有已下載的檔案
sha256sum --ignore-missing -c checksums.sha256
```

---

## 🛠️ 常用管理指令

### Fail2Ban

```bash
sudo fail2ban-client status sshd                 # 查看封鎖名單
sudo fail2ban-client set sshd unbanip <IP>       # 解除封鎖
sudo nano /etc/fail2ban/jail.local               # 編輯白名單 (ignoreip)，改完重啟
sudo systemctl restart fail2ban
```

### UFW

```bash
sudo ufw status numbered      # 查看規則（含編號）
sudo ufw delete <編號>        # 刪除特定規則
```

### Tailscale

```bash
tailscale status              # 連線狀態
tailscale ip -4               # 本機內網 IP
sudo tailscale up             # 重新認證
```

---

## 🔄 升級

```bash
# 下載並驗證 upgrade.sh 後執行（它會再對新版腳本做 SHA256 驗證）
curl -fsSL -O https://raw.githubusercontent.com/OtisFR/server-security/main/upgrade.sh
curl -fsSL -O https://raw.githubusercontent.com/OtisFR/server-security/main/checksums.sha256
sha256sum --ignore-missing -c checksums.sha256
sudo bash upgrade.sh
```

- 升級前自動備份至 `/opt/server-security/backups/backup_<時間戳>/`
- 新版腳本必須通過 `checksums.sha256` 驗證才會安裝
- 自動化環境請使用 `sudo bash upgrade.sh --yes`（不建議設定成無人值守 cron；如需自動化，請先確保你了解「自動套用遠端程式碼」的風險）

---

## ⚠️ 零信任配置注意事項

1. **執行前**：確認可存取 <https://login.tailscale.com>，並確認主機商 Console（救援終端）可用
2. **執行中**：腳本會在封鎖公網 SSH 前先驗證 Tailscale 連線，並暫時放行你目前的來源 IP
3. **執行後**：立刻開「另一個」終端機用 Tailscale IP 測試登入，成功後再移除臨時放行規則（摘要會列出指令），**測試成功前不要關閉原視窗**

### 緊急救援（萬一無法連線）

```bash
# 透過主機商 Console 登入後：
sudo ufw disable              # 暫時關閉防火牆
sudo ufw status numbered      # 檢查規則
sudo ufw enable               # 修正後重新啟用
```

---

## 🐛 故障排除

| 症狀 | 處理方式 |
|------|----------|
| Tailscale 無法認證 | `sudo systemctl status tailscaled`、`sudo journalctl -u tailscaled -n 50` |
| 被 Fail2Ban 誤封 | `sudo fail2ban-client set sshd unbanip <IP>`，並把 IP 加入 `ignoreip` |
| SSH 加固後仍可用密碼登入 | 執行 `sudo sshd -T \| grep -i passwordauthentication` 檢查有效值；確認 `/etc/ssh/sshd_config.d/00-hardening.conf` 存在 |
| 還原 SSH 設定 | `sudo rm /etc/ssh/sshd_config.d/00-hardening.conf && sudo systemctl restart ssh` |
| 還原 IPv6 | `sudo rm /etc/sysctl.d/99-disable-ipv6.conf && sudo sysctl --system`（若曾停用，記得把 `/etc/default/ufw` 的 `IPV6` 改回 `yes`） |

部署完整日誌：`/var/log/server-security-deploy.log`

---

## 📄 License

MIT License —— 詳見 [LICENSE](LICENSE)

---

## 🤝 貢獻與回報

- 🐛 Bug 回報：[GitHub Issues](https://github.com/OtisFR/server-security/issues)
- 🔐 安全性弱點：請參閱 [SECURITY.md](SECURITY.md)（請勿以公開 Issue 揭露）
- 🔧 貢獻流程：[CONTRIBUTING.md](CONTRIBUTING.md)
