# Legacy 腳本（已封存）

此目錄保存 v1.x 的舊版腳本，**已由 v2.0 的 `secure-deploy.sh` 取代，不建議繼續使用**：

| 舊腳本 | v2.0 對應功能 |
|--------|---------------|
| `tailscale-installer.sh` | `secure-deploy.sh` 配置 2/3（Tailscale + 零信任） |
| `setup_ssh_jail.sh` | `secure-deploy.sh` 配置 1（UFW + Fail2Ban） |

## 為什麼被取代？

v1.x 版本存在數個已確認的安全問題（詳見 CHANGELOG 2.0.0），最重要的包括：

- **鎖死風險**：零信任模式先封鎖公網 SSH 才進行 Tailscale 登入，且登入失敗被 `|| true` 吞掉——Tailscale 沒連上時管理員會被永久鎖在門外
- **IPv6 繞過**：核心層停用 IPv6 失敗時仍關閉 UFW 的 IPv6 過濾，導致 IPv6 流量完全不設防
- **CGNAT 過度放行**：`100.64.0.0/10` 網段規則在部分 ISP/雲環境會誤放行外部主機

這些問題在 v2.0 均已修正。保留舊檔僅供參考與比對。
