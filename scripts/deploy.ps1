<#
.SYNOPSIS
  SRE Agent Demo 環境を一括デプロイ（インフラ + アプリ + SRE Agent）

.DESCRIPTION
  1. リソースグループ作成（インフラ用 + SRE Agent 用）
  2. Bicep でインフラデプロイ
  3. ACR にコンテナイメージをビルド & プッシュ
  4. Container App のイメージを更新
  5. SRE Agent デプロイ + RBAC 付与
  6. GitHub Actions OIDC 設定（オプション）
  ※ DB テーブルはアプリ起動時に自動作成されます

.PARAMETER ResourceGroup
  インフラ用リソースグループ名（デフォルト: rg-sre-demo）

.PARAMETER Location
  インフラのリージョン（デフォルト: japaneast）

.PARAMETER SreAgentResourceGroup
  SRE Agent 用リソースグループ名（デフォルト: rg-sre-agent）

.PARAMETER SreAgentLocation
  SRE Agent のリージョン（eastus2, swedencentral, australiaeast）

.PARAMETER GitHubRepo
  GitHub リポジトリ（owner/repo 形式）。省略時は git remote から自動検出

.PARAMETER EnableOidc
  GitHub Actions OIDC 設定を有効化（デフォルト: 無効）

.EXAMPLE
  ./scripts/deploy.ps1
  ./scripts/deploy.ps1 -ResourceGroup "rg-my-demo" -Location "eastus"
  ./scripts/deploy.ps1 -EnableOidc
#>

param(
    [string]$ResourceGroup = "rg-sre-demo",
    [string]$Location = "japaneast",
    [string]$SreAgentResourceGroup = "rg-sre-agent",
    [string]$SreAgentLocation = "eastus2",
    [hashtable]$Tags = @{},
    [string]$GitHubRepo = "",
    [switch]$EnableOidc
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " SRE Agent Demo - Deploy" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# --- 環境変数チェック ---
$requiredEnvVars = @("SRE_ADMIN_PASSWORD", "SRE_SQL_PASSWORD", "SRE_NOTIFICATION_EMAIL")
foreach ($var in $requiredEnvVars) {
    if (-not [Environment]::GetEnvironmentVariable($var)) {
        Write-Error "環境変数 '$var' が設定されていません。"
        exit 1
    }
}

# --- 1. リソースグループ作成 ---
Write-Host "`n[1/7] リソースグループ作成: $ResourceGroup ($Location)" -ForegroundColor Yellow
$rgArgs = @("group", "create", "--name", $ResourceGroup, "--location", $Location, "-o", "none")
if ($Tags.Count -gt 0) {
    $tagStrings = $Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    $rgArgs += @("--tags") + $tagStrings
    Write-Host "  タグ: $($tagStrings -join ', ')" -ForegroundColor DarkGray
}
az @rgArgs

# --- 2. Bicep デプロイ ---
Write-Host "`n[2/7] インフラデプロイ（約 20〜30 分かかります）..." -ForegroundColor Yellow
$deployResult = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file infra/main.bicep `
    --parameters infra/main.bicepparam `
    --query "properties.outputs" `
    -o json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    Write-Error "Bicep デプロイに失敗しました。"
    exit 1
}

$acrLoginServer = $deployResult.acrLoginServer.value
$acrName = $acrLoginServer -replace '\.azurecr\.io$', ''
$appName = "sre-demo-app"

Write-Host "  ACR: $acrLoginServer" -ForegroundColor Green
Write-Host "  SQL: $($deployResult.sqlServerFqdn.value)" -ForegroundColor Green
Write-Host "  Container App: $($deployResult.containerAppFqdn.value)" -ForegroundColor Green

# --- 3. ACR にイメージビルド ---
Write-Host "`n[3/7] コンテナイメージのビルド & ACR プッシュ..." -ForegroundColor Yellow
az acr build --registry $acrName --image sre-demo-app:latest ./app/

if ($LASTEXITCODE -ne 0) {
    Write-Error "ACR ビルドに失敗しました。"
    exit 1
}

# --- 4. Container App のイメージ更新 ---
Write-Host "`n[4/7] Container App のイメージを更新..." -ForegroundColor Yellow
$updateArgs = @(
    "containerapp", "update",
    "--name", $appName,
    "--resource-group", $ResourceGroup,
    "--image", "$acrLoginServer/sre-demo-app:latest"
)

az @updateArgs -o none

if ($LASTEXITCODE -ne 0) {
    Write-Error "Container App の更新に失敗しました。"
    exit 1
}

# --- 5. SRE Agent デプロイ ---
Write-Host "`n[5/7] SRE Agent デプロイ..." -ForegroundColor Yellow

# SRE Agent 用 RG 作成
$sreRgArgs = @("group", "create", "--name", $SreAgentResourceGroup, "--location", $SreAgentLocation, "-o", "none")
if ($Tags.Count -gt 0) {
    $tagStrings = $Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    $sreRgArgs += @("--tags") + $tagStrings
}
az @sreRgArgs
Write-Host "  RG: $SreAgentResourceGroup ($SreAgentLocation)" -ForegroundColor DarkGray

# Azure CLI 拡張機能
az extension add --name application-insights --only-show-errors 2>$null

# インフラ RG から情報取得
$subscriptionId = (az account show --query id -o tsv)
$infraRgId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup"
$appiJson = az monitor app-insights component show -g $ResourceGroup --query "[0]" -o json | ConvertFrom-Json
if (-not $appiJson) { Write-Error "Application Insights が見つかりません"; exit 1 }

# 環境変数セット
$env:SRE_INFRA_RG_ID = $infraRgId
$env:SRE_APPI_APP_ID = $appiJson.appId
$env:SRE_APPI_CONNECTION_STRING = $appiJson.connectionString

# Bicep デプロイ
$agentResult = az deployment group create `
    --resource-group $SreAgentResourceGroup `
    --template-file infra/sre-agent.bicep `
    --parameters infra/sre-agent.bicepparam `
    --query "properties.outputs" `
    -o json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    Write-Error "SRE Agent デプロイに失敗しました。"
    exit 1
}

$agentName = $agentResult.agentName.value
$miPrincipalId = $agentResult.managedIdentityPrincipalId.value
$portalUrl = $agentResult.portalUrl.value
Write-Host "  Agent: $agentName" -ForegroundColor Green
Write-Host "  Portal: $portalUrl" -ForegroundColor Green

# RBAC 付与
$roles = @(
    @{ Name = "Contributor"; Id = "b24988ac-6180-42a0-ab88-20f7382dd24c" }
    @{ Name = "Monitoring Reader"; Id = "43d0d8ad-25c7-4714-9337-8ba259a9fe05" }
    @{ Name = "Log Analytics Reader"; Id = "73c42c96-874c-492b-b04d-ab87d138a893" }
)
foreach ($role in $roles) {
    az role assignment create `
        --assignee-object-id $miPrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role $role.Id `
        --scope $infraRgId `
        -o none 2>$null
    Write-Host "  $($role.Name) をインフラ RG に付与" -ForegroundColor DarkGray
}

# Cost Management Reader (サブスクリプションスコープ)
az role assignment create `
    --assignee-object-id $miPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --role "72fafb9e-0641-4937-9268-a91bfd8191a3" `
    --scope "/subscriptions/$subscriptionId" `
    -o none 2>$null
Write-Host "  Cost Management Reader をサブスクリプションに付与" -ForegroundColor DarkGray

# SRE Agent Administrator
$currentUserId = az ad signed-in-user show --query id -o tsv 2>$null
if ($currentUserId) {
    az role assignment create `
        --assignee-object-id $currentUserId `
        --assignee-principal-type User `
        --role "SRE Agent Administrator" `
        --scope $agentResult.agentResourceId.value `
        -o none 2>$null
    Write-Host "  SRE Agent Administrator を付与" -ForegroundColor DarkGray
}

# --- 6. GitHub Actions OIDC 設定 ---
if (-not $EnableOidc) {
    Write-Host "`n[6/7] GitHub Actions OIDC 設定...スキップ（有効化は -EnableOidc）" -ForegroundColor DarkGray
} else {
    Write-Host "`n[6/7] GitHub Actions OIDC 設定..." -ForegroundColor Yellow

    # gh CLI チェック
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host "  gh CLI が見つかりません。OIDC 設定をスキップします。" -ForegroundColor Red
        Write-Host "  インストール: https://cli.github.com/" -ForegroundColor DarkGray
    } else {
        # GitHub リポジトリ検出
        if (-not $GitHubRepo) {
            $gitRemoteUrl = git remote get-url origin 2>$null
            if ($gitRemoteUrl -match 'github\.com[:/](.+?)(?:\.git)?$') {
                $GitHubRepo = $Matches[1]
            }
        }

        if (-not $GitHubRepo) {
            Write-Host "  GitHub リポジトリを検出できません。-GitHubRepo を指定してください。" -ForegroundColor Red
        } else {
            $subscriptionId = (az account show --query id -o tsv)
            $tenantId = (az account show --query tenantId -o tsv)
            $appDisplayName = "sre-demo-github-actions"
            $credName = "github-actions-main"

            Write-Host "  リポジトリ: $GitHubRepo" -ForegroundColor DarkGray

            # Entra ID アプリ登録（既存があれば再利用）
            $existingApp = az ad app list --display-name $appDisplayName --query "[0]" -o json 2>$null | ConvertFrom-Json
            if ($existingApp) {
                $appClientId = $existingApp.appId
                $appObjectId = $existingApp.id
                Write-Host "  既存のアプリ登録を使用: $appClientId" -ForegroundColor DarkGray
            } else {
                $newApp = az ad app create --display-name $appDisplayName -o json | ConvertFrom-Json
                $appClientId = $newApp.appId
                $appObjectId = $newApp.id
                Write-Host "  アプリ登録を作成: $appClientId" -ForegroundColor Green
            }

            # Service Principal（既存があれば再利用）
            $spId = az ad sp list --filter "appId eq '$appClientId'" --query "[0].id" -o tsv 2>$null
            if (-not $spId) {
                az ad sp create --id $appClientId -o none
                $spId = (az ad sp list --filter "appId eq '$appClientId'" --query "[0].id" -o tsv)
                Write-Host "  Service Principal を作成" -ForegroundColor Green
            }

            # Federated Credential（main ブランチのみ — パブリックリポジトリのセキュリティ対策）
            $existingCredCount = az ad app federated-credential list --id $appObjectId --query "[?name=='$credName'] | length(@)" -o tsv 2>$null
            if ($existingCredCount -eq "0" -or -not $existingCredCount) {
                $fedCredParams = @{
                    name        = $credName
                    issuer      = "https://token.actions.githubusercontent.com"
                    subject     = "repo:${GitHubRepo}:ref:refs/heads/main"
                    description = "GitHub Actions - main branch only"
                    audiences   = @("api://AzureADTokenExchange")
                }
                $tempFile = [System.IO.Path]::GetTempFileName()
                try {
                    $fedCredParams | ConvertTo-Json -Depth 3 | Set-Content -Path $tempFile -Encoding UTF8
                    az ad app federated-credential create --id $appObjectId --parameters $tempFile -o none
                    Write-Host "  Federated Credential を作成（main ブランチのみ）" -ForegroundColor Green
                } finally {
                    Remove-Item $tempFile -ErrorAction SilentlyContinue
                }
            } else {
                Write-Host "  Federated Credential は既存" -ForegroundColor DarkGray
            }

            # RBAC: RG に Contributor ロールを付与
            az role assignment create `
                --assignee-object-id $spId `
                --assignee-principal-type ServicePrincipal `
                --role Contributor `
                --scope "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup" `
                -o none 2>$null
            Write-Host "  Contributor ロールを RG に割当" -ForegroundColor Green

            # GitHub Secrets（OIDC 認証情報 — シークレットとして格納）
            gh secret set AZURE_CLIENT_ID --body $appClientId --repo $GitHubRepo
            gh secret set AZURE_TENANT_ID --body $tenantId --repo $GitHubRepo
            gh secret set AZURE_SUBSCRIPTION_ID --body $subscriptionId --repo $GitHubRepo
            Write-Host "  GitHub Secrets を設定（AZURE_CLIENT_ID / TENANT_ID / SUBSCRIPTION_ID）" -ForegroundColor Green

            # GitHub Variables（リソース名 — 秘匿不要の値）
            gh variable set RESOURCE_GROUP --body $ResourceGroup --repo $GitHubRepo
            gh variable set ACR_NAME --body $acrName --repo $GitHubRepo
            gh variable set CONTAINER_APP_NAME --body $appName --repo $GitHubRepo
            Write-Host "  GitHub Variables を設定（RESOURCE_GROUP / ACR_NAME / CONTAINER_APP_NAME）" -ForegroundColor Green

            Write-Host "  OIDC 設定完了 — app/** への push で自動デプロイが有効です" -ForegroundColor Green
        }
    }
}

# --- 7. 完了 ---
Write-Host "`n[7/7] デプロイ完了!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " アクセス情報" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Container App:  https://$($deployResult.containerAppFqdn.value)" -ForegroundColor White
Write-Host "  ACR:            $acrLoginServer" -ForegroundColor White
Write-Host "  SQL Server:     $($deployResult.sqlServerFqdn.value)" -ForegroundColor White
Write-Host "  Log Analytics:  $($deployResult.logAnalyticsWorkspaceName.value)" -ForegroundColor White
Write-Host "  VM Hub:         $($deployResult.vmHubPrivateIp.value)" -ForegroundColor White
Write-Host "  VM Spoke2:      $($deployResult.vmSpoke2PrivateIp.value)" -ForegroundColor White
Write-Host "  SRE Agent:      $portalUrl" -ForegroundColor White
Write-Host ""
Write-Host "  次のステップ:" -ForegroundColor Yellow
Write-Host "    1. ポータルで Knowledge Source に knowledge/ のファイルをアップロード" -ForegroundColor White
Write-Host "    2. ポータルで instruction に infra/prompts/incident-auto.md の内容を設定" -ForegroundColor White
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " VM 用変数設定（Bastion 接続後にコピペ）" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$vmVarsBlock = @"
`$RG = "$ResourceGroup"
`$SUB = "$((az account show --query id -o tsv))"
`$FQDN = "$($deployResult.containerAppFqdn.value)"
`$SQL_SERVER = "$($deployResult.sqlServerFqdn.value)"
`$ACR_NAME = "$acrName"
`$connStr = "Server=`$SQL_SERVER;Database=sre-demo-sqldb;User Id=sqladmin;Password=<pass>;Encrypt=True;TrustServerCertificate=False;Application Name=sre-demo-vm-hub"
"@
Write-Host $vmVarsBlock -ForegroundColor White
Write-Host ""
Write-Host "  削除: ./scripts/destroy.ps1 -ResourceGroup $ResourceGroup" -ForegroundColor DarkGray
