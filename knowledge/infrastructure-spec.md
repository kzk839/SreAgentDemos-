# Azure SRE Agent Demo - インフラ仕様書

## 概要

Hub-Spoke ネットワーク構成上に構築された Azure 環境。Container Apps (Spoke1) 上の Node.js アプリが Azure SQL Database に接続し、VM (Hub/Spoke2) から Azure Firewall 経由でアクセスする構成。

---

## ネットワークトポロジ

```
  GitHub Repo ──► GitHub Actions ──► ACR ──► Container Apps (Spoke1)

┌───────────────────┐
│    Hub VNet          │
│   10.1.0.0/16       │
│                     │
│  ┌─────────────┐  │
│  │   VM-Hub     │  │
│  └─────────────┘  │
│  ┌─────────────┐  │
│  │  Azure FW   │  │
│  └──────┬──────┘  │
└─────────┼─────────┘
           │
┌───────────┴───────────┐
 VNet Peering            VNet Peering
      │                       │
┌────────────┴──────────┐   ┌───────┴─────────┐
│  Spoke1 VNet (PaaS)   │   │  Spoke2 VNet    │
│  10.2.0.0/16          │   │  10.3.0.0/16    │
│                       │   │                 │
│  ┌─────────────────┐  │   │  ┌───────────┐  │
│  │ Container Apps  │  │   │  │ VM-Spoke2 │  │
│  │ Environment     │  │   │  └───────────┘  │
│  └─────────────────┘  │   └─────────────────┘
│  ┌─────────────────┐  │
│  │ ACR Private EP  │  │
│  └─────────────────┘  │
│  ┌─────────────────┐  │
│  │ SQL Private EP  │  │
│  └─────────────────┘  │
│  ┌─────────────────┐  │
│  │ Private DNS     │  │
│  └─────────────────┘  │
└───────────────────────┘
```

**通信フロー:** Hub-Spoke 間の全通信は Azure Firewall を経由（UDR で強制）

---

## IP アドレス設計

| VNet | アドレス空間 | AzureFirewallSubnet | sn-default | sn-container-apps | sn-private-endpoints |
|------|-------------|---------------------|------------|-------------------|---------------------|
| Hub | 10.1.0.0/16 | 10.1.1.0/26 | 10.1.2.0/24 | — | — |
| Spoke1 | 10.2.0.0/16 | — | — | 10.2.0.0/23 | 10.2.2.0/24 |
| Spoke2 | 10.3.0.0/16 | — | 10.3.1.0/24 | — | — |

> **Note:** Container Apps Environment には最低 /23 のサブネットが必要

---

## リソース一覧

### ネットワーク

| リソース | 名前 | 説明 |
|---------|------|------|
| VNet × 3 | `{prefix}-vnet-hub`, `spoke1`, `spoke2` | 上記 IP 設計に基づく |
| NSG (VM 用) | `{prefix}-nsg-default` | VM サブネット共通。RDP (10.0.0.0/8 → 3389) と ICMP を許可 |
| NSG (PE 用) | `{prefix}-nsg-private-endpoints` | Spoke1 sn-private-endpoints 用。HTTPS (443) と SQL (1433) のみ内部から許可、他全拒否 |
| Azure Firewall | `{prefix}-afw` | Hub VNet に配置。Basic SKU |
| Firewall Policy | `{prefix}-afw-policy` | 内部通信全許可 + HTTP/HTTPS/DNS のアウトバウンド許可 |
| Route Table (Spoke1) | `{prefix}-rt-spoke1` | Hub, Spoke2 → FW へ転送（0.0.0.0/0 なし: Container Apps の Azure サービス通信を維持） |
| Route Table (Spoke2) | `{prefix}-rt-spoke2` | 0.0.0.0/0, Hub, Spoke1 → FW へ転送 |
| Route Table (Hub Default) | `{prefix}-rt-hub-default` | Spoke1, Spoke2 → FW へ転送（Hub VM→Spoke 通信を FW 経由に強制） |
| VNet Peering × 4 | `peer-to-spoke1/2`, `peer-to-hub` | Hub-Spoke ピアリング |
| Azure Bastion × 2 | `{prefix}-bastion-hub`, `bastion-spoke2` | Developer SKU（無料）。同一 VNet 内の VM のみ接続可能 |
| Private DNS Zone | `privatelink.azurecr.io` | ACR Private Endpoint 用。Hub VNet にリンク |
| Private DNS Zone | `privatelink.database.windows.net` | Azure SQL Private Endpoint 用。Hub VNet にリンク |

### アプリケーション (Spoke1)

| リソース | 名前 | 説明 |
|---------|------|------|
| Container Apps Environment | `{prefix}-cae` | Spoke1 VNet 内 (sn-container-apps) にデプロイ |
| Container App | `{prefix}-app` | サンプル REST API アプリ。Azure SQL に接続 |
| Azure Container Registry | `{prefix}acr` | コンテナイメージ格納。Private Endpoint 経由で VNet 内アクセス。パブリックアクセスは有効（`az acr build` 用） |
| ACR Private Endpoint | `{prefix}-pe-acr` | Spoke1 sn-private-endpoints 内 |
| User Assigned Managed Identity | `{prefix}-id-app` | Container App → ACR Pull + SQL 接続に使用 |

### データベース (Spoke1)

| リソース | 名前 | 説明 |
|---------|------|------|
| Azure SQL Server | `{prefix}-sql` | 論理サーバー。パブリックアクセス無効 |
| Azure SQL Database | `{prefix}-sqldb` | Basic/S0 tier（デモ用）。サンプルデータ |
| SQL Private Endpoint | `{prefix}-pe-sql` | Spoke1 sn-private-endpoints 内 |
| SQL Diagnostic Settings | `{prefix}-sqldb-diag` | Log Analytics に送信。SQLInsights, QueryStore (Runtime/Wait), Errors, Timeouts, Blocks, Deadlocks |

### コンピューティング (VM)

| リソース | 名前 | 仕様 | VNet |
|---------|------|------|------|
| VM | `{prefix}-vm-hub` | Windows Server 2022, Standard_B2s_v2 | Hub sn-default |
| VM | `{prefix}-vm-spoke2` | Windows Server 2022, Standard_B2s_v2 | Spoke2 sn-default |
| NIC × 2 | `{prefix}-vm-*-nic` | プライベート IP 動的割当 | 各 VNet |

### 監視

| リソース | 名前 | 説明 |
|---------|------|------|
| Log Analytics Workspace | `{prefix}-law` | PerGB2018 SKU, 保持期間 30 日 |
| Application Insights | `{prefix}-appi` | Container App のアプリ監視。Log Analytics に接続 |
| Data Collection Rule | `{prefix}-dcr-windows` | パフォーマンスカウンター + Windows イベントログ |
| Azure Monitor Agent | 各 VM に拡張機能として導入 | 自動アップグレード有効 |
| DCR Association × 2 | 各 VM にスコープ | DCR を各 VM に関連付け |
| Action Group | `{prefix}-ag-sre` | メール通知用アクショングループ |
| Alert Rule (VM CPU) | `{prefix}-alert-vm-cpu-high` | VM CPU > 90% (5分平均) — Sev2 |
| Alert Rule (VM Memory) | `{prefix}-alert-vm-memory-low` | 空きメモリ < 500MB — Sev2 |
| Alert Rule (VM Disk) | `{prefix}-alert-vm-disk-low` | ディスク空き < 10% — Sev1 |
| Alert Rule (SQL DTU) | `{prefix}-alert-sql-dtu-high` | DTU 消費 > 90% — Sev2 |
| Alert Rule (SQL Deadlock) | `{prefix}-alert-sql-deadlock` | デッドロック検出 — Sev2 |
| Alert Rule (SQL Conn) | `{prefix}-alert-sql-conn-failed` | 接続失敗 > 5件/5分 — Sev2 |
| Alert Rule (App Response) | `{prefix}-alert-app-slow-response` | 応答時間 > 5秒 — Sev2 |
| Alert Rule (App Failures) | `{prefix}-alert-app-failed-requests` | 失敗リクエスト > 10件/5分 — Sev1 |
| Alert Rule (App Exceptions) | `{prefix}-alert-app-exceptions` | サーバー例外検出 — Sev2 |
| Alert Rule (CA Restarts) | `{prefix}-alert-ca-restarts` | コンテナ再起動検出 — Sev2 |
| Alert Rule (CA Replicas) | `{prefix}-alert-ca-replicas-down` | レプリカ数 = 0 — **Sev0 (Critical)** |

---

## ルーティング詳細

### Spoke1 ルートテーブル (`rt-spoke1`, BGP 伝播無効)

> **Note:** 0.0.0.0/0 ルートは設定しない。Container Apps が ACR や Azure サービスに到達するために必要。

| ルート名 | 宛先 | 次ホップ |
|----------|------|--------|
| to-hub | 10.1.0.0/16 | Azure FW |
| to-spoke2 | 10.3.0.0/16 | Azure FW |

### Spoke2 ルートテーブル (`rt-spoke2`, BGP 伝播無効)

| ルート名 | 宛先 | 次ホップ |
|----------|------|---------|
| to-internet | 0.0.0.0/0 | Azure FW |
| to-hub | 10.1.0.0/16 | Azure FW |
| to-spoke1 | 10.2.0.0/16 | Azure FW |

### Hub sn-default ルートテーブル (`rt-hub-default`)

| ルート名 | 宛先 | 次ホップ |
|----------|------|--------|
| to-spoke1 | 10.2.0.0/16 | Azure FW |
| to-spoke2 | 10.3.0.0/16 | Azure FW |
---

## Azure Firewall ルール

### ネットワークルール

| コレクション名 | 優先度 | ルール名 | ソース | 宛先 | ポート | プロトコル | アクション |
|---------------|--------|---------|-------|------|--------|----------|----------|
| AllowInternalTraffic | 100 | AllowAllInternal | 全内部 CIDR | 全内部 CIDR | * | Any | Allow |
| AllowInternetOutbound | 200 | AllowHttpHttps | 全内部 CIDR | * | 80, 443 | TCP | Allow |
| AllowInternetOutbound | 200 | AllowDns | 全内部 CIDR | * | 53 | UDP, TCP | Allow |

---

## サンプルアプリ詳細

`app/` ディレクトリに配置。Node.js (Express) + mssql + Application Insights の REST API。

### エンドポイント一覧

| パス | メソッド | 用途 |
|------|---------|------|
| `/health` | GET | ヘルスチェック（常に 200 返却） |
| `/ready` | GET | レディネスチェック（DB 接続確認込み） |
| `/api/items` | GET | Items テーブル全件取得 |
| `/api/items` | POST | Item 追加 (`{ "name": "..." }`) |
| `/api/items/:id` | DELETE | Item 削除 |

### テスト時の注意事項

- **ヘルスプローブの除外:** Container Apps のヘルスプローブ (`/health`, `/ready`) は Application Insights テレメトリから除外されています（`server.js` の TelemetryProcessor）。これによりプローブのリクエストがメトリクス平均を希釈することを防止しています。
- **VNet 内部アクセス:** Container App は `internal: true` のため、VNet 内の VM（Azure Bastion 経由）からリクエストを送信してください。
