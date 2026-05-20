<#
.SYNOPSIS
  SRE Agent Demo 環境を一括デプロイ（インフラ + アプリ + DB 初期化）

.DESCRIPTION
  1. リソースグループ作成
  2. Bicep でインフラデプロイ
  3. ACR にコンテナイメージをビルド & プッシュ
  4. Container App のイメージを更新
  ※ DB テーブルはアプリ起動時に自動作成されます

.PARAMETER ResourceGroup
  リソースグループ名（デフォルト: rg-sre-demo）

.PARAMETER Location
  リージョン（デフォルト: japaneast）

.PARAMETER EnableChaos
  カオスエンドポイントを有効化（デフォルト: false）

.EXAMPLE
  ./scripts/deploy.ps1
  ./scripts/deploy.ps1 -EnableChaos
  ./scripts/deploy.ps1 -ResourceGroup "rg-my-demo" -Location "eastus"
#>

param(
    [string]$ResourceGroup = "rg-sre-demo",
    [string]$Location = "japaneast",
    [hashtable]$Tags = @{},
    [switch]$EnableChaos
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " SRE Agent Demo - Deploy" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# --- 環境変数チェック ---
$requiredEnvVars = @("SRE_ADMIN_PASSWORD", "SRE_SQL_PASSWORD", "SRE_NOTIFICATION_EMAIL", "SRE_VPN_SHARED_KEY")
foreach ($var in $requiredEnvVars) {
    if (-not [Environment]::GetEnvironmentVariable($var)) {
        Write-Error "環境変数 '$var' が設定されていません。"
        exit 1
    }
}

# --- 1. リソースグループ作成 ---
Write-Host "`n[1/5] リソースグループ作成: $ResourceGroup ($Location)" -ForegroundColor Yellow
$rgArgs = @("group", "create", "--name", $ResourceGroup, "--location", $Location, "-o", "none")
if ($Tags.Count -gt 0) {
    $tagStrings = $Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    $rgArgs += @("--tags") + $tagStrings
    Write-Host "  タグ: $($tagStrings -join ', ')" -ForegroundColor DarkGray
}
az @rgArgs

# --- 2. Bicep デプロイ ---
Write-Host "`n[2/5] インフラデプロイ（約 50〜60 分かかります）..." -ForegroundColor Yellow
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
Write-Host "`n[3/5] コンテナイメージのビルド & ACR プッシュ..." -ForegroundColor Yellow
az acr build --registry $acrName --image sre-demo-app:latest ./app/

if ($LASTEXITCODE -ne 0) {
    Write-Error "ACR ビルドに失敗しました。"
    exit 1
}

# --- 4. Container App のイメージ更新 ---
Write-Host "`n[4/5] Container App のイメージを更新..." -ForegroundColor Yellow
$updateArgs = @(
    "containerapp", "update",
    "--name", $appName,
    "--resource-group", $ResourceGroup,
    "--image", "$acrLoginServer/sre-demo-app:latest"
)

if ($EnableChaos) {
    $updateArgs += @("--set-env-vars", "ENABLE_CHAOS=true")
    Write-Host "  ⚠ カオスエンドポイント有効" -ForegroundColor Red
}

az @updateArgs -o none

if ($LASTEXITCODE -ne 0) {
    Write-Error "Container App の更新に失敗しました。"
    exit 1
}

# --- 5. 完了 ---
Write-Host "`n[5/5] デプロイ完了!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " アクセス情報" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Container App:  https://$($deployResult.containerAppFqdn.value)" -ForegroundColor White
Write-Host "  ACR:            $acrLoginServer" -ForegroundColor White
Write-Host "  SQL Server:     $($deployResult.sqlServerFqdn.value)" -ForegroundColor White
Write-Host "  Log Analytics:  $($deployResult.logAnalyticsWorkspaceName.value)" -ForegroundColor White
Write-Host "  VM OnPrem:      $($deployResult.vmOnpremPrivateIp.value)" -ForegroundColor White
Write-Host "  VM Hub:         $($deployResult.vmHubPrivateIp.value)" -ForegroundColor White
Write-Host "  VM Spoke2:      $($deployResult.vmSpoke2PrivateIp.value)" -ForegroundColor White
Write-Host ""
Write-Host "  削除: ./scripts/destroy.ps1 -ResourceGroup $ResourceGroup" -ForegroundColor DarkGray
