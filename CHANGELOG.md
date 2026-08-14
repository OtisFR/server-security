# 更新日誌 (Changelog)

所有重要的版本變化都記錄在此文件中。

格式基於 [Keep a Changelog](https://keepachangelog.com/)，
並遵循 [語義化版本](https://semver.org/) 慣例。

---

## [2.0.0] - 2026-08-08

### 🎯 模式重新設計（Breaking Change）

原本分散在 `secure-deploy.sh` 與 `tailscale-installer.sh` 的 5 種重疊模式，收斂為 **3 種配置 + 附加選項**：

| 新配置 | 對應舊模式 |
|--------|-----------|
| 1. 基礎防護（UFW + Fail2Ban） | 新增（舊模式 1 的 Fail2Ban 實際無效，已修正） |
| 2. 標準加固（+ Tailscale） | 舊模式 2/3 |
| 3. 零信任隔離（SSH 僅限 Tailscale） | 舊模式 4/5 |

Exit Node 與停用 IPv6 改為附加選項，不再乘出獨立模式。`tailscale-installer.sh` 與 `setup_ssh_jail.sh` 移至 `legacy/`。

### 🔒 安全修復

- **零信任順序修正**：先驗證 Tailscale 登入成功並取得內網 IP，才封鎖公網 SSH；封鎖後再次驗證，失敗自動回滾（舊版先封鎖再登入，登入失敗還被 `|| true` 吞掉，會把管理員鎖在門外）
- **SSH 加固改用 drop-in**：`secure_ssh.sh` 改寫 `/etc/ssh/sshd_config.d/00-hardening.conf` 並以 `sshd -T` 驗證有效值（舊版只改主設定檔，會被雲端映像的 `50-cloud-init.conf` 靜默覆蓋，密碼登入實際上沒關掉）
- **防鎖死檢查修正**：改檢查實際登入者（`SUDO_USER`）的 authorized_keys，並過濾 cloud-init 的拒絕行（舊版在 sudo 下檢查的是 `/root`）
- **IPv6 停用安全化**：核心層停用需驗證生效才會關閉 UFW 的 IPv6 過濾；偵測目前連線是否走 IPv6 並警告（舊版可能造成 IPv6 流量完全不設防）
- **移除 CGNAT 網段規則**：不再放行 `100.64.0.0/10`（非 Tailscale 專屬，部分 ISP/雲環境會誤放行外部主機），僅保留 `tailscale0` 介面限定規則；Fail2Ban 白名單同步移除該網段
- **動態偵測 SSH 埠**：UFW 與 Fail2Ban 規則套用到 `sshd -T` 偵測到的實際埠號，不再假設 22
- **升級完整性**：`upgrade.sh` 強制以 `checksums.sha256` 驗證 SHA256 後才安裝；備份目錄修正（舊版備份路徑不存在導致升級必定中止）；版本比較修正；非互動環境需 `--yes`
- **Fail2Ban banaction 修正**：UFW 未啟用時改用 `iptables-multiport`（舊模式 1 的封鎖是無效空操作）
- **`update-checksums.sh` 修復**：補回遺失的 `<!-- CHECKSUMS -->` 標記樣式並加上替換後完整性檢查（舊版執行會把整份 README 毀掉，也是校驗和長期漂移的根因）
- **`zabbix-agent2-install.sh`**：改用 mktemp 私有目錄 + `wget -O`（防同名檔劫持）、輸入白名單驗證（防 sed 注入）、嚴格模式與結果驗證
- **文件安全**：移除所有 `curl | sudo bash` 與 root cron 自動更新建議，一律改為「下載 → 驗證 → 執行」；移除 `NOPASSWD:ALL` 示範

### ⚙️ CI 強化

- ShellCheck 改為強制通過（移除 `|| true`），涵蓋全部發佈腳本
- 新增校驗和一致性檢查（checksums.sha256 ↔ 實際檔案 ↔ README 校驗表）
- 移除 paths 過濾（所有變更都跑 CI）、`permissions: contents: read`、actions 以 commit SHA 釘選
- 新增 SECURITY.md 必要文件檢查

### 📖 文件

- README / INSTALL 全面改寫（新配置說明、安全安裝流程）
- 新增 SECURITY.md（弱點回報管道與信任邊界說明）

---

## [1.0.0] - 2026-03-26

### 🎉 初始版本發佈

#### ✨ 功能
- ✅ **統合部署工具** (`secure-deploy.sh`)
  - 三合一整合：Tailscale + UFW + Fail2Ban
  - 5 種部署模式（標準 3 + 零信任 2）
  - 完整的 IPv6 禁用機制（雙層：核心 + UFW）

- ✅ **SSH 防禦工具** (`setup_ssh_jail.sh`)
  - 專用 Fail2Ban 配置與白名單管理
  - UFW 防火牆安全啟用
  - 完整的 IP 格式驗證

- ✅ **Tailscale 部署工具** (`tailscale-installer.sh`)
  - 5 種 Tailscale 部署模式
  - 零信任隔離（SSH 限制 + CIDR 白名單）
  - Exit Node 路由優化

#### 🔒 安全特性
- **Fail2Ban 防禦**
  - SSH 暴力破解防護：5 次失敗 5 分鐘 → 封鎖 2 小時
  - 智能白名單：本機 + Tailscale 網段 + 自訂 IP
  - 配置備份機制

- **UFW 防火牆**
  - 安全啟用（先設預設規則後設開放規則）
  - 絕對定位 SSH 溫控開放
  - 零信任模式 SSH CIDR 限制

- **Tailscale 零信任**
  - 公網 SSH 完全封鎖（零信任模式）
  - 100.64.0.0/10 內部網段限制
  - 臨時 IP 放行機制

- **IPv6 徹底禁用**
  - 系統邏輯層禁用（sysctl）
  - UFW 防火牆層禁用
  - 完整性驗證

#### ⚙️ 系統特性
- 嚴格模式 (`set -euo pipefail`) 所有腳本
- 完整的錯誤彙報與恢復機制
- 自動依賴檢測與安裝
- 完整部署日誌與審查軌跡
- 標準化互動提示風格

#### 📚 部署方式
- CLI 菜單選擇
- 自動 IPv6 禁用詢問
- IP 白名單互動配置
- Fail2Ban 動態邏輯設置

#### 🚀 GitHub 部署支援
- 直接拉取執行 (`curl | sudo bash`)
- 版本檢查機制
- 自動升級指令碼
- 備份與恢復機制

#### 📖 文檔
- 完整 README.md 含 5 種模式說明
- 故障排除指南
- 常用管理指令參考
- 安全特性詳細解說

### 🐛 已知限制
- IPv6 禁用在某些容器環境可能不完全生效（vender 級別限制）
- Tailscale 認證需外部網路連線
- 零信任模式需謹慎（可能暫時無法連線）

### 📝 版本資訊
- **發佈日期**: 2026-03-26
- **發佈者**: Server Security Team
- **穩定性**: ⭐⭐⭐⭐⭐ 生產級

---

## [未來計劃]

### v2.1.0 (計劃中)
- [ ] GPG/minisign 簽章驗證（跨通道信任錨，取代同倉庫校驗和的自我背書）
- [ ] 以 GitHub Release tag 固定版本發佈
- [ ] Prometheus 監控整合

---

## 版本對比

| 版本 | 發佈日期 | 部署模式 | 零信任防鎖死 | 升級驗證 | 生產就緒 |
|------|---------|----------|--------------|----------|---------|
| 2.0.0 | 2026-08-08 | 3 配置 + 附加選項 | ✅ 先驗證後封鎖 + 自動回滾 | ✅ 強制 SHA256 | ✅ 是 |
| 1.0.0 | 2026-03-26 | 5 模式 × 2 腳本 | ❌ 先封鎖後登入 | ❌ 僅語法檢查 | ⚠️ 已知風險 |

---

## 更新方式

### 手動檢查更新
```bash
curl -s https://raw.githubusercontent.com/OtisFR/server-security/main/VERSION
```

### 升級（下載 → 驗證 → 執行）
```bash
curl -fsSL -O https://raw.githubusercontent.com/OtisFR/server-security/main/upgrade.sh
curl -fsSL -O https://raw.githubusercontent.com/OtisFR/server-security/main/checksums.sha256
sha256sum --ignore-missing -c checksums.sha256
sudo bash upgrade.sh
```

### 查看完整變更
每個版本發佈都在 GitHub Releases 中提供：
https://github.com/OtisFR/server-security/releases

---

## 貢獻指南

發現 Bug 或有建議？
1. 開設 GitHub Issue
2. 提交 Pull Request（含清晰的變更說明）
3. 遵循既有的程式碼風格

---

**最後更新**: 2026-08-08
