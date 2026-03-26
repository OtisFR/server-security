# 更新日誌 (Changelog)

所有重要的版本變化都記錄在此文件中。

格式基於 [Keep a Changelog](https://keepachangelog.com/)，
並遵循 [語義化版本](https://semver.org/) 慣例。

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

### v1.1.0 (計劃中)
- [ ] Docker 容器支持
- [ ] Systemd service 自動安裝
- [ ] Prometheus 監控整合
- [ ] 自動備份機制

### v1.2.0 (計劃中)
- [ ] Web UI 管理介面
- [ ] 多伺服器集群管理
- [ ] 安全審計報告生成

### v2.0.0 (長期計劃)
- [ ] Kubernetes 整合
- [ ] Ansible Playbook 支持
- [ ] 完整的 CI/CD 工作流

---

## 版本對比

| 版本 | 發佈日期 | Tailscale | UFW | Fail2Ban | 生產就緒 |
|------|---------|-----------|-----|----------|---------|
| 1.0.0 | 2026-03-26 | ✅ (5 模式) | ✅ (2 層防禦) | ✅ (白名單) | ✅ 是 |

---

## 更新方式

### 手動檢查更新
```bash
curl -s https://raw.githubusercontent.com/OtisFR/server-security/main/VERSION
```

### 自動升級
```bash
curl -fsSL https://raw.githubusercontent.com/OtisFR/server-security/main/upgrade.sh | sudo bash
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

**最後更新**: 2026-03-26
