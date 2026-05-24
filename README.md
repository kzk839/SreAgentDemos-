# Azure SRE Agent Demo

Azure SRE Agent のデモ環境。Hub-Spoke ネットワーク上に Container Apps + Azure SQL + VM を配置し、SRE Agent による障害検知・調査・対処を実演します。

## ファイル構成

```
SreAgentDemos/
├── .gitignore                          # Git 除外設定（.env, 証明書, node_modules 等）
├── README.md                           # 本ドキュメント
├── knowledge/                          # SRE Agent ナレッジベース（KB）
│   ├── infrastructure-spec.md          # インフラ構成仕様
│   ├── app-expert.md                   # アプリ専門知識
│   ├── db-expert.md                    # DB 専門知識
│   └── network-expert.md              # NW 専門知識
├── docs/
│   └── internal/                       # 内部メモ（gitignored）
├── scripts/
│   ├── deploy.ps1                      # 一括デプロイスクリプト（インフラ + アプリ）
│   ├── destroy.ps1                     # 一括削除スクリプト（RG ごと削除）
│   ├── deploy-sre-agent.ps1            # SRE Agent デプロイスクリプト
│   └── destroy-sre-agent.ps1           # SRE Agent 削除スクリプト
├── infra/
│   ├── main.bicep                      # メインオーケストレーション
│   ├── main.bicepparam                 # パラメータファイル
│   ├── sre-agent.bicep                 # SRE Agent 定義
│   ├── sre-agent.bicepparam            # SRE Agent パラメータ
│   ├── prompts/                        # SRE Agent プロンプト（KB / instruction）
│   │   ├── common.md                   # インシデント対応ワークフロー（instruction）
│   │   ├── app-expert.md               # アプリ専門知識（KB）
│   │   ├── db-expert.md                # DB 専門知識（KB）
│   │   ├── network-expert.md           # NW 専門知識（KB）
│   │   └── health-check.md             # ヘルスチェック（スケジュールタスク用）
│   └── modules/
│       ├── vnet.bicep                  # VNet モジュール
│       ├── vm.bicep                    # VM モジュール（AMA + DCR 込み）
│       ├── azureFirewall.bicep         # Azure Firewall + Policy + ルール
│       ├── containerApps.bicep         # Container Apps Environment + App
│       ├── containerRegistry.bicep     # ACR + Private Endpoint
│       ├── sqlDatabase.bicep           # Azure SQL Server + DB + Private Endpoint
│       ├── privateDnsZone.bicep        # Private DNS Zone + VNet Link
│       ├── actionGroup.bicep           # アクショングループ
│       └── alertRules.bicep            # アラートルール
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

---

## デプロイ手順

### 一括デプロイ（推奨）

```powershell
# 1. 環境変数を設定
$env:SRE_ADMIN_USERNAME = '<VM管理者ユーザー名>'  # 省略時は azureadmin
$env:SRE_ADMIN_PASSWORD = '<VMパスワード>'
$env:SRE_SQL_PASSWORD = '<SQLパスワード>'
$env:SRE_NOTIFICATION_EMAIL = '<通知先メールアドレス>'

# 2. デプロイ実行
./scripts/deploy.ps1

# リソースグループ名・リージョンを変更する場合
./scripts/deploy.ps1 -ResourceGroup "rg-my-demo" -Location "eastus"

# リソースグループにタグを付与する場合（ポリシー制約等がある環境向け）
./scripts/deploy.ps1 -Tags @{ "Environment"="Demo"; "Project"="SreAgent" }

# GitHub Actions OIDC 設定も行う場合（gh CLI が必要）
./scripts/deploy.ps1 -EnableOidc

# SRE Agent のリージョンを変更する場合
./scripts/deploy.ps1 -SreAgentLocation "swedencentral"
```

**所要時間:** 約 20〜30 分

### 一括削除

```powershell
./scripts/destroy.ps1                           # 確認プロンプトあり
./scripts/destroy.ps1 -NoConfirm                 # 確認なしで即削除
./scripts/destroy.ps1 -ResourceGroup "rg-my-demo" # RG 名を指定
```

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

---

## 運用想定

環境を常時残す想定ではなく、必要な時に `deploy.ps1` でデプロイし、使い終わったら `destroy.ps1` で RG ごと削除する使い捨て運用です。

| 項目 | RG 削除で消える？ | 再デプロイ時 |
|------|:-:|---|
| Azure リソース（VM, ACR, SQL 等） | ✅ | `deploy.ps1` が再作成 |
| Entra ID アプリ登録 + Federated Credential | ❌ | 既存を自動再利用 |
| GitHub Secrets / Variables | ❌ | `deploy.ps1` が自動更新 |

`deploy.ps1` は全ステップが冪等に設計されているため、初回でも再デプロイでも同じコマンドで実行できます。

---

## デプロイ順序（依存関係）

```
Log Analytics ──► DCR
              ──► App Insights

NSG ──► VNet Hub ──► Azure FW ──► Route Tables ──┬──► VNet Spoke1 ──┬──► Container Apps Env
                                                  │                  ├──► ACR + Private EP
                                                  │                  ├──► SQL + Private EP
                                                  │                  └──► Private DNS Zones
                                                  └──► VNet Spoke2 ──► VM-Spoke2

                                                  └──► Peerings (Hub-Spoke1, Hub-Spoke2)

VM-Hub は Hub VNet のサブネット作成後にデプロイ
Container App は Container Apps Env + ACR + SQL の準備完了後にデプロイ
```

---

## Spoke 間テストシナリオ

| # | テスト内容 | 方法 | 障害注入例 |
|---|----------|------|----------|
| 1 | Spoke2 VM → Container App API | `Invoke-RestMethod` で API エンドポイントに HTTP リクエスト | FW ルール変更、UDR 変更、Container App 停止 |
| 2 | Spoke2 VM → SQL Private EP | `sqlcmd` で直接 SQL 接続 | Private EP の DNS 破壊、SQL 一時停止 |
| 3 | Spoke2 VM → ACR | `az acr login` + `docker pull` でイメージ取得 | ACR FW ルール変更、Private EP 削除 |
| 4 | DNS 解決テスト | `Resolve-DnsName` で Private DNS Zone の名前解決確認 | DNS Zone リンク削除、レコード削除 |

---

## CI/CD

| リソース | 場所 | 説明 |
|---------|------|------|
| GitHub Actions Workflow | `.github/workflows/deploy.yml` | ビルド → ACR プッシュ → Container Apps デプロイ（push to main + workflow_dispatch） |
| Entra ID App Registration | Entra ID | `sre-demo-github-actions`。RG 削除後も永続（再利用される） |
| Federated Credential | Entra ID | GitHub Actions → Azure 認証（OIDC）。**main ブランチのみ許可** |
| GitHub Secrets | GitHub | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` |
| GitHub Variables | GitHub | `RESOURCE_GROUP`, `ACR_NAME`, `CONTAINER_APP_NAME` |
