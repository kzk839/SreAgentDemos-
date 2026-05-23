# Azure SRE Agent Demo - インフラ仕様書

## 概要

Hub-Spoke ネットワーク構成上に構築された Azure 環境。Container Apps (Spoke1) 上の Node.js アプリが Azure SQL Database に接続し、VM (OnPrem/Hub/Spoke2) から Azure Firewall・VPN 経由でアクセスする構成。

---

## ネットワークトポロジ

```
  GitHub Repo ──► GitHub Actions ──► ACR ──► Container Apps (Spoke1)

┌─────────────────┐         VPN GW          ┌───────────────────┐
│  OnPrem VNet    │◄──────(VNet-to-VNet)────►│    Hub VNet       │
│  10.0.0.0/16    │                          │   10.1.0.0/16     │
│                 │                          │                   │
│  ┌───────────┐  │                          │  ┌─────────────┐  │
│  │ VM-OnPrem │  │                          │  │   VM-Hub    │  │
│  └───────────┘  │                          │  └─────────────┘  │
└─────────────────┘                          │  ┌─────────────┐  │
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

**通信フロー:** Spoke 間、OnPrem-Spoke 間の全通信は Azure Firewall を経由（UDR で強制）

---

## IP アドレス設計

| VNet | アドレス空間 | GatewaySubnet | AzureFirewallSubnet | sn-default | sn-container-apps | sn-private-endpoints |
|------|-------------|---------------|---------------------|--------------------|-----------|--------------------|---------------------|
| OnPrem | 10.0.0.0/16 | 10.0.0.0/27 | — | 10.0.1.0/24 | — | — |
| Hub | 10.1.0.0/16 | 10.1.0.0/27 | 10.1.1.0/26 | — | 10.1.2.0/24 | — | — |
| Spoke1 | 10.2.0.0/16 | — | — | — | 10.2.0.0/23 | 10.2.2.0/24 |
| Spoke2 | 10.3.0.0/16 | — | — | 10.3.1.0/24 | — | — |

> **Note:** Container Apps Environment には最低 /23 のサブネットが必要

---

## リソース一覧

### ネットワーク

| リソース | 名前 | 説明 |
|---------|------|------|
| VNet × 4 | `{prefix}-vnet-onprem`, `hub`, `spoke1`, `spoke2` | 上記 IP 設計に基づく |
| NSG (VM 用) | `{prefix}-nsg-default` | VM サブネット共通。RDP (10.0.0.0/8 → 3389) と ICMP を許可 |
| NSG (PE 用) | `{prefix}-nsg-private-endpoints` | Spoke1 sn-private-endpoints 用。HTTPS (443) と SQL (1433) のみ内部から許可、他全拒否 |
| Azure Firewall | `{prefix}-afw` | Hub VNet に配置。Standard SKU |
| Firewall Policy | `{prefix}-afw-policy` | 内部通信全許可 + HTTP/HTTPS/DNS のアウトバウンド許可 |
| Route Table (Spoke1) | `{prefix}-rt-spoke1` | OnPrem, Hub, Spoke2 → FW へ転送（0.0.0.0/0 なし: Container Apps の Azure サービス通信を維持） |
| Route Table (Spoke2) | `{prefix}-rt-spoke2` | 0.0.0.0/0, OnPrem, Hub, Spoke1 → FW へ転送 |
| Route Table (Hub GW) | `{prefix}-rt-hub-gw` | Spoke1, Spoke2 → FW へ転送（OnPrem→Spoke 通信を FW 経由に強制） |
| Route Table (Hub Default) | `{prefix}-rt-hub-default` | Spoke1, Spoke2 → FW へ転送（Hub VM→Spoke 通信を FW 経由に強制）。BGP 伝播有効（VPN GW の OnPrem ルートを受信） |
| VPN Gateway × 2 | `{prefix}-vpngw-onprem`, `vpngw-hub` | VpnGw1AZ SKU, RouteBased, BGP 無効 |
| VPN Connection × 2 | `{prefix}-conn-onprem-to-hub`, `conn-hub-to-onprem` | VNet-to-VNet 接続（双方向） |
| VNet Peering × 4 | `peer-to-spoke1/2`, `peer-to-hub` | Hub 側: allowGatewayTransit=true, Spoke 側: useRemoteGateways=true |
| Azure Bastion × 3 | `{prefix}-bastion-onprem`, `bastion-hub`, `bastion-spoke2` | Developer SKU（無料）。各 VNet に 1 つずつ配置。同一 VNet 内の VM のみ接続可能 |
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
| VM | `{prefix}-vm-onprem` | Windows Server 2022, Standard_B2s_v2 | OnPrem sn-default |
| VM | `{prefix}-vm-hub` | Windows Server 2022, Standard_B2s_v2 | Hub sn-default |
| VM | `{prefix}-vm-spoke2` | Windows Server 2022, Standard_B2s_v2 | Spoke2 sn-default |
| NIC × 3 | `{prefix}-vm-*-nic` | プライベート IP 動的割当 | 各 VNet |

### 監視

| リソース | 名前 | 説明 |
|---------|------|------|
| Log Analytics Workspace | `{prefix}-law` | PerGB2018 SKU, 保持期間 30 日 |
| Application Insights | `{prefix}-appi` | Container App のアプリ監視。Log Analytics に接続 |
| Data Collection Rule | `{prefix}-dcr-windows` | パフォーマンスカウンター + Windows イベントログ |
| Azure Monitor Agent | 各 VM に拡張機能として導入 | 自動アップグレード有効 |
| DCR Association × 3 | 各 VM にスコープ | DCR を各 VM に関連付け |
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

### CI/CD

| リソース | 場所 | 説明 |
|---------|------|------|
| GitHub Repository | GitHub | サンプルアプリコード + Dockerfile + GitHub Actions ワークフロー |
| GitHub Actions Workflow | `.github/workflows/deploy.yml` | ビルド → ACR プッシュ → Container Apps デプロイ（push to main + workflow_dispatch） |
| Entra ID App Registration | Entra ID | `sre-demo-github-actions`。RG 削除後も永続（再利用される） |
| Federated Credential | Entra ID | GitHub Actions → Azure 認証（OIDC）。**main ブランチのみ許可**（パブリックリポジトリ保護） |
| GitHub Secrets | GitHub | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`（`deploy.ps1` が自動設定） |
| GitHub Variables | GitHub | `RESOURCE_GROUP`, `ACR_NAME`, `CONTAINER_APP_NAME`（`deploy.ps1` が自動設定） |

---

## ルーティング詳細

### Spoke1 ルートテーブル (`rt-spoke1`, BGP 伝播無効)

> **Note:** 0.0.0.0/0 ルートは設定しない。Container Apps が ACR や Azure サービスに到達するために必要。

| ルート名 | 宛先 | 次ホップ |
|----------|------|--------|
| to-onprem | 10.0.0.0/16 | Azure FW |
| to-hub | 10.1.0.0/16 | Azure FW |
| to-spoke2 | 10.3.0.0/16 | Azure FW |

### Spoke2 ルートテーブル (`rt-spoke2`, BGP 伝播無効)

| ルート名 | 宛先 | 次ホップ |
|----------|------|---------|
| to-internet | 0.0.0.0/0 | Azure FW |
| to-onprem | 10.0.0.0/16 | Azure FW |
| to-hub | 10.1.0.0/16 | Azure FW |
| to-spoke1 | 10.2.0.0/16 | Azure FW |

### Hub GatewaySubnet ルートテーブル (`rt-hub-gw`, BGP 伝播有効)

| ルート名 | 宛先 | 次ホップ |
|----------|------|---------|
| to-spoke1 | 10.2.0.0/16 | Azure FW |
| to-spoke2 | 10.3.0.0/16 | Azure FW |
### Hub sn-default ルートテーブル (`rt-hub-default`, BGP 伝播有効)

> **Note:** BGP 伝播を有効にし、VPN GW から受信する OnPrem ルート (10.0.0.0/16) を Hub VM に伝播させる。
> 無効にすると Hub VM → OnPrem VM の通信が断になる。

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

## ファイル構成

```
SreAgentDemos/
├── .gitignore                          # Git 除外設定（.env, 証明書, node_modules 等）
├── docs/
│   └── infrastructure-spec.md          # 本ドキュメント
├── scripts/
│   ├── deploy.ps1                      # 一括デプロイスクリプト（インフラ + アプリ）
│   └── destroy.ps1                     # 一括削除スクリプト（RG ごと削除）
├── infra/
│   ├── main.bicep                      # メインオーケストレーション
│   ├── main.bicepparam                 # パラメータファイル
│   └── modules/
│       ├── vnet.bicep                  # VNet モジュール（サブネット構成可変）
│       ├── vm.bicep                    # VM モジュール（AMA + DCR 関連付け込み）
│       ├── azureFirewall.bicep         # Azure Firewall + Policy + ルール
│       ├── vpnGateway.bicep            # VPN Gateway
│       ├── containerApps.bicep         # Container Apps Environment + App
│       ├── containerRegistry.bicep     # ACR + Private Endpoint
│       ├── sqlDatabase.bicep           # Azure SQL Server + DB + Private Endpoint
│       ├── privateDnsZone.bicep        # Private DNS Zone + VNet Link
│       ├── actionGroup.bicep           # アクショングループ（メール通知）
│       └── alertRules.bicep            # アラートルール（VM/SQL/App/Container Apps）
├── app/
│   ├── Dockerfile                      # コンテナビルド定義（node:22-alpine）
│   ├── .dockerignore                   # Docker ビルド除外設定
│   ├── package.json                    # Node.js 依存 (express, mssql, applicationinsights)
│   └── src/
│       └── server.js                   # REST API（バグシナリオ埋め込み済み）
└── .github/
    └── workflows/
        └── deploy.yml                  # GitHub Actions CI/CD ワークフロー（OIDC 認証）
```

---

## パラメータ

| パラメータ | 型 | デフォルト | 説明 |
|-----------|-----|----------|------|
| `location` | string | リソースグループのリージョン | 全リソースのデプロイ先リージョン |
| `prefix` | string | `sre-demo` | リソース名のプレフィックス |
| `adminUsername` | string | 環境変数 `SRE_ADMIN_USERNAME`（フォールバック: `azureadmin`） | VM 管理者ユーザー名 |
| `adminPassword` | secureString | 環境変数 `SRE_ADMIN_PASSWORD` | VM 管理者パスワード |
| `vmSize` | string | `Standard_B2s_v2` | 全 VM のサイズ |
| `sqlAdminUsername` | string | `sqladmin` | Azure SQL 管理者ユーザー名 |
| `sqlAdminPassword` | secureString | 環境変数 `SRE_SQL_PASSWORD` | Azure SQL 管理者パスワード |
| `notificationEmail` | string | 環境変数 `SRE_NOTIFICATION_EMAIL` | アラート通知先メールアドレス |
| `vpnSharedKey` | secureString | 環境変数 `SRE_VPN_SHARED_KEY` | VPN Gateway 共有キー |

---

## デプロイ手順

### 一括デプロイ（推奨）

`scripts/deploy.ps1` で RG 作成 → Bicep デプロイ → ACR ビルド → Container App 更新 → OIDC 設定を一括実行します。

```powershell
# 1. 環境変数を設定
$env:SRE_ADMIN_USERNAME = '<VM管理者ユーザー名>'  # 省略時は azureadmin
$env:SRE_ADMIN_PASSWORD = '<VMパスワード>'
$env:SRE_SQL_PASSWORD = '<SQLパスワード>'
$env:SRE_NOTIFICATION_EMAIL = '<通知先メールアドレス>'
$env:SRE_VPN_SHARED_KEY = '<VPN共有キー>'

# 2. デプロイ実行（OIDC 設定込み）
./scripts/deploy.ps1

# リソースグループ名・リージョンを変更する場合
./scripts/deploy.ps1 -ResourceGroup "rg-my-demo" -Location "eastus"

# リソースグループにタグを付与する場合（ポリシー制約等がある環境向け）
./scripts/deploy.ps1 -Tags @{ "Environment"="Demo"; "Project"="SreAgent" }

# OIDC 設定をスキップする場合
./scripts/deploy.ps1 -SkipOidc
```

> **前提:** OIDC 設定には [GitHub CLI (`gh`)](https://cli.github.com/) が必要です。未インストールの場合は OIDC ステップのみスキップされます。

### 一括削除

```powershell
./scripts/destroy.ps1                           # 確認プロンプトあり
./scripts/destroy.ps1 -NoConfirm                 # 確認なしで即削除
./scripts/destroy.ps1 -ResourceGroup "rg-my-demo" # RG 名を指定
```

### SRE Agent デプロイ（インフラとは別に実施）

SRE Agent はインフラとは別の RG にデプロイします。対応リージョンは eastus2, swedencentral, australiaeast のみです。

**前提:**
- インフラ環境が `deploy.ps1` で先にデプロイ済みであること
- Azure CLI 拡張機能 `application-insights` がインストール済みであること（スクリプトが自動インストールしますが、初回は事前に `az extension add --name application-insights` を実行しておくと安全です）

```powershell
# デプロイ
./scripts/deploy-sre-agent.ps1 -InfraResourceGroup "rg-sre-demo6"

# リージョンを変更する場合
./scripts/deploy-sre-agent.ps1 -InfraResourceGroup "rg-sre-demo6" -Location "swedencentral"

# 削除（インフラには影響なし）
./scripts/destroy-sre-agent.ps1                   # 確認プロンプトあり
./scripts/destroy-sre-agent.ps1 -NoConfirm         # 確認なしで即削除
```

デプロイ完了後、SRE Agent ポータル URL が表示されます。

### 手動デプロイ（個別実行）

```powershell
# 1. リソースグループ作成
az group create --name rg-sre-demo --location japaneast

# 2. 環境変数を設定（上記参照）

# 3. インフラデプロイ
az deployment group create `
  --resource-group rg-sre-demo `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam

# 4. サンプルアプリのコンテナイメージをビルド & プッシュ
az acr build --registry <acr-name> --image sre-demo-app:latest ./app/

# 5. Container App のイメージを更新
az containerapp update --name sre-demo-app --resource-group rg-sre-demo `
  --image <acr-name>.azurecr.io/sre-demo-app:latest
```

### 運用想定

環境を常時残す想定ではなく、必要な時に `deploy.ps1` でデプロイし、使い終わったら `destroy.ps1` で RG ごと削除する使い捨て運用です。

| 項目 | RG 削除で消える？ | 再デプロイ時 |
|------|:-:|---|
| Azure リソース（VM, ACR, SQL 等） | ✅ | `deploy.ps1` が再作成 |
| Entra ID アプリ登録 + Federated Credential | ❌ | 既存を自動再利用 |
| GitHub Secrets / Variables | ❌ | `deploy.ps1` が自動更新 |

`deploy.ps1` は全ステップが冪等に設計されているため、初回でも再デプロイでも同じコマンドで実行できます。

**所要時間:** VPN Gateway は直列デプロイ（OnPrem → Hub の順）のため各 15〜25 分、全体で約 50〜60 分

---

## デプロイ順序（依存関係）

```
Log Analytics ──► DCR
              ──► App Insights

NSG ──┬──► VNet OnPrem ──► VPN GW OnPrem ──┐
      │                                     │ (直列: Hub は OnPrem 完了後にデプロイ)
      └──► VNet Hub ──► Azure FW ──► Route Tables ──┬──► VNet Spoke1 ──┬──► Container Apps Env
                                                     │                  ├──► ACR + Private EP
                                                     │                  ├──► SQL + Private EP
                                                     │                  └──► Private DNS Zones
                                                     ├──► VNet Spoke2 ──► VM-Spoke2
                                                     └──► Hub GW Subnet ──► VPN GW Hub ──┬──► VPN Connections
                                                                                          ├──► Peerings
                                                                                          └──► (dependsOn: VPN GW OnPrem)

VM-OnPrem, VM-Hub は各 VNet のサブネット作成後に並列デプロイ
Container App は Container Apps Env + ACR + SQL の準備完了後にデプロイ
```

---

## Spoke 間テストシナリオ

Spoke2 の VM から Spoke1 の PaaS リソースへの通信テスト用に、以下のシナリオを想定：

| # | テスト内容 | 方法 | 障害注入例 |
|---|----------|------|----------|
| 1 | Spoke2 VM → Container App API | `curl` / `Invoke-RestMethod` で API エンドポイントに HTTP リクエスト | FW ルール削除、UDR 変更、Container App 停止 |
| 2 | Spoke2 VM → SQL Private EP | `sqlcmd` / SSMS で直接 SQL 接続 | SQL FW ルール変更、Private EP の DNS 破壊、SQL 一時停止 |
| 3 | Spoke2 VM → ACR | `az acr login` + `docker pull` でイメージ取得 | ACR FW ルール変更、Private EP 削除 |
| 4 | DNS 解決テスト | `nslookup` / `Resolve-DnsName` で Private DNS Zone の名前解決確認 | DNS Zone リンク削除、レコード削除 |

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

---

## 今後の拡張予定

- [x] ~~Azure Bastion の追加（VM アクセス用）~~ → 各 VNet に Developer SKU（無料）で追加済み
- [x] ~~OIDC Federated Credential 設定スクリプト（GitHub Actions 用）~~ → `deploy.ps1` に統合済み
- [ ] SRE エージェント連携設定
- [ ] ダッシュボード（Azure Monitor Workbook）
- [ ] README.md の作成（クイックスタートガイド）
