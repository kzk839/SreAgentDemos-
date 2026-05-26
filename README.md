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
│   ├── deploy.ps1                      # 一括デプロイ（インフラ + アプリ + SRE Agent）
│   └── destroy.ps1                     # 一括削除（RG ごと削除）
├── infra/
│   ├── main.bicep                      # メインオーケストレーション
│   ├── main.bicepparam                 # パラメータファイル
│   ├── sre-agent.bicep                 # SRE Agent 定義
│   ├── sre-agent.bicepparam            # SRE Agent パラメータ
│   ├── prompts/                        # SRE Agent instruction / タスク
│   │   ├── common.md                   # インシデント対応ワークフロー（instruction）
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
│       └── server.js                   # REST API + バックグラウンドワーカー（バグシナリオ埋め込み済み）
```

---

## アプリケーション仕様

### REST API

| エンドポイント | 説明 |
|----------------|------|
| `GET /health` | ヘルスチェック |
| `GET /ready` | DB 接続確認付きレディネスチェック |
| `GET /api/items` | Items テーブルから最新 50 件を取得 |
| `POST /api/items` | 新規アイテム作成（`{"name": "..."}` 必須） |
| `DELETE /api/items/:id` | アイテム削除 |

### バックグラウンドワーカー

アプリ起動後、業務アプリケーションの動作をシミュレートするバックグラウンドワーカーが自動的に動作します。

| 操作 | 間隔 | 内容 |
|------|------|------|
| READ | 10〜30秒（ランダム） | Items テーブルからランダムに 5 件取得 |
| WRITE | 15〜45秒（ランダム） | ランダムな 1 件の Status を `Active` ↔ `Processed` で切り替え |

App Insights の `dependencies` テーブルに SQL テレメトリが継続的に蓄積されるため、DB 障害時にエラーが自動的に記録されます。

### バグシナリオ

`server.js` には以下のバグシナリオがコメントアウト状態で埋め込まれています。

| シナリオ | 効果 | アラート |
|----------|------|----------|
| BUG SCENARIO A | `GET /api/items` で `TypeError` 例外が発生 | `app-exceptions`, `app-failed-requests` |
| BUG SCENARIO B | `GET /api/items` で N+1 クエリによるレスポンス遅延 | `app-slow-response` |

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

### 一括デプロイ

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

# SRE Agent のリージョンを変更する場合
./scripts/deploy.ps1 -SreAgentLocation "swedencentral"
```

**所要時間:** 約 20〜30 分

### デプロイ後のセットアップ（ポータル: sre.azure.com）

`deploy.ps1` 完了後、以下をポータルで設定してください。

#### 1. コネクタ設定

Agent は `az monitor log-analytics query` 等で直接クエリできるため、コネクタなしでも動作します。
設定すると調査が速くなります。

| コネクタ | 用途 |
|---------|------|
| Log Analytics | `sre-demo-law` への永続的コンテキスト |
| Application Insights | `sre-demo-appi` への永続的コンテキスト |

#### 2. ナレッジベース

`knowledge/` ディレクトリのファイルを Knowledge Source にアップロード（ポータル UI から）。

| ファイル | 用途 |
|---------|------|
| `knowledge/infrastructure-spec.md` | インフラ構成仕様 |
| `knowledge/app-expert.md` | アプリケーション専門知識 |
| `knowledge/db-expert.md` | DB 専門知識 |
| `knowledge/network-expert.md` | NW 専門知識 |

#### 3. インシデント応答プラン

ポータルでインシデント応答プランを作成します。

1. 重大度: **すべての重大度**
2. 「Customize the incident response plan (optional)」にチェック
3. 指示の追加: 運用モードに応じて以下のいずれかの内容を貼り付け

| モード | ファイル | 説明 |
|--------|---------|------|
| 自立モード | `infra/prompts/incident-auto.md` | Agent が調査から対処まで自律的に実行する |
| レビューモード | `infra/prompts/incident-review.md` | Agent は調査のみ行い、推奨アクションを提示する。変更操作は人間が実行 |

4. Choose agent autonomy level: 自立モードなら **自律**、レビューモードなら **レビュー**

#### 4. スケジュールタスク

以下のファイルの内容をスケジュールタスクの指示として登録します。

| ファイル | タスク名 | スケジュール |
|---------|---------|------------|
| `infra/prompts/health-check.md` | Daily Health Check | 毎日 9:00 AM |
| `infra/prompts/cost-analysis.md` | Monthly Cost Analysis | 毎月 1 日 9:00 AM |

### 一括削除

```powershell
./scripts/destroy.ps1                             # インフラ RG のみ削除（確認プロンプトあり）
./scripts/destroy.ps1 -IncludeSreAgent             # SRE Agent RG も含めて削除
./scripts/destroy.ps1 -NoConfirm                   # 確認なしで即削除
./scripts/destroy.ps1 -ResourceGroup "rg-my-demo"  # RG 名を指定
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


