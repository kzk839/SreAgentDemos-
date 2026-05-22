<#
.SYNOPSIS
  SRE Agent を単体でデプロイ（インフラ環境が既にある前提）

.DESCRIPTION
  1. SRE Agent 用の RG を作成
  2. 既存インフラ RG からリソース情報を取得
  3. インフラ RG に SRE Agent MI の RBAC を付与
  4. SRE Agent を Bicep でデプロイ
  5. Knowledge Base にドキュメントをアップロード

.PARAMETER InfraResourceGroup
  既存のインフラ RG 名

.PARAMETER AgentResourceGroup
  SRE Agent 用の RG 名

.PARAMETER Location
  SRE Agent のリージョン（eastus2, swedencentral, australiaeast）

.EXAMPLE
  ./scripts/deploy-sre-agent.ps1 -InfraResourceGroup "rg-sre-demo6"
  ./scripts/deploy-sre-agent.ps1 -InfraResourceGroup "rg-sre-demo6" -Location "swedencentral"
#>

param(
    [Parameter(Mandatory)]
    [string]$InfraResourceGroup,
    [string]$AgentResourceGroup = "rg-sre-agent",
    [string]$Location = "eastus2",
    [hashtable]$Tags = @{}
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " SRE Agent - Deploy" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# --- 0. 前提チェック: Azure CLI 拡張機能 ---
Write-Host "`n[0/5] Azure CLI 拡張機能を確認..." -ForegroundColor Yellow
az extension add --name application-insights --only-show-errors 2>$null
Write-Host "  application-insights 拡張機能: OK" -ForegroundColor DarkGray

# --- 1. RG 作成 ---
Write-Host "`n[1/5] SRE Agent 用 RG 作成: $AgentResourceGroup ($Location)" -ForegroundColor Yellow
$rgArgs = @("group", "create", "--name", $AgentResourceGroup, "--location", $Location, "-o", "none")
if ($Tags.Count -gt 0) {
    $tagStrings = $Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    $rgArgs += @("--tags") + $tagStrings
}
az @rgArgs

# --- 2. インフラ RG からリソース情報を取得 ---
Write-Host "`n[2/6] インフラ RG ($InfraResourceGroup) からリソース情報を取得..." -ForegroundColor Yellow

$subscriptionId = (az account show --query id -o tsv)
$infraRgId = "/subscriptions/$subscriptionId/resourceGroups/$InfraResourceGroup"
Write-Host "  Infra RG: $infraRgId" -ForegroundColor DarkGray

# Application Insights
$appiJson = az monitor app-insights component show -g $InfraResourceGroup --query "[0]" -o json | ConvertFrom-Json
if (-not $appiJson) { Write-Error "Application Insights が見つかりません"; exit 1 }
$appiAppId = $appiJson.appId
$appiConnStr = $appiJson.connectionString
Write-Host "  App Insights: $($appiJson.id)" -ForegroundColor DarkGray

# --- 3. 環境変数にセット ---
$env:SRE_INFRA_RG_ID = $infraRgId
$env:SRE_APPI_APP_ID = $appiAppId
$env:SRE_APPI_CONNECTION_STRING = $appiConnStr

# --- 4. Bicep デプロイ ---
Write-Host "`n[3/6] SRE Agent デプロイ..." -ForegroundColor Yellow
$deployResult = az deployment group create `
    --resource-group $AgentResourceGroup `
    --template-file infra/sre-agent.bicep `
    --parameters infra/sre-agent.bicepparam `
    --query "properties.outputs" `
    -o json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    Write-Error "SRE Agent デプロイに失敗しました。"
    exit 1
}

$agentName = $deployResult.agentName.value
$agentEndpoint = $deployResult.agentEndpoint.value
$miPrincipalId = $deployResult.managedIdentityPrincipalId.value
$agentResourceId = $deployResult.agentResourceId.value
$portalUrl = $deployResult.portalUrl.value

Write-Host "  Agent: $agentName" -ForegroundColor Green
Write-Host "  Endpoint: $agentEndpoint" -ForegroundColor Green

# --- 5. インフラ RG に SRE Agent MI の RBAC 付与 ---
Write-Host "`n[4/6] インフラ RG に SRE Agent の RBAC を付与..." -ForegroundColor Yellow
$roles = @(
    @{ Name = "Reader"; Id = "acdd72a7-3385-48ef-bd42-f606fba81ae7" }
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
    Write-Host "  $($role.Name) を付与" -ForegroundColor DarkGray
}

# --- 6. デプロイユーザーに SRE Agent Administrator を付与 ---
Write-Host "`n[5/6] デプロイユーザーに SRE Agent Administrator を付与..." -ForegroundColor Yellow
$currentUserId = az ad signed-in-user show --query id -o tsv
if ($currentUserId) {
    az role assignment create `
        --assignee-object-id $currentUserId `
        --assignee-principal-type User `
        --role "SRE Agent Administrator" `
        --scope $agentResourceId `
        -o none 2>$null
    Write-Host "  SRE Agent Administrator を付与 ($currentUserId)" -ForegroundColor DarkGray
} else {
    Write-Host "  サインインユーザーを取得できませんでした。ポータルの IAM から手動で付与してください。" -ForegroundColor DarkGray
}

# --- 7. Knowledge Base アップロード ---
Write-Host "`n[6/6] Knowledge Base にドキュメントをアップロード..." -ForegroundColor Yellow

# アップロード対象ファイル（アーキテクチャ情報・診断手順）
$kbFiles = @(
    "docs/infrastructure-spec.md"
    "infra/prompts/network-expert.md"
    "infra/prompts/app-expert.md"
    "infra/prompts/db-expert.md"
)

$token = az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv 2>$null
if ($token) {
    $headers = @{ "Authorization" = "Bearer $token" }
    $uploadCount = 0

    foreach ($filePath in $kbFiles) {
        if (Test-Path $filePath) {
            $fileName = Split-Path $filePath -Leaf
            try {
                $form = @{ files = Get-Item -Path $filePath }
                Invoke-RestMethod `
                    -Uri "$agentEndpoint/api/v1/agentmemory/upload" `
                    -Method POST `
                    -Headers $headers `
                    -Form $form
                Write-Host "  $fileName をアップロード" -ForegroundColor Green
                $uploadCount++
            } catch {
                Write-Host "  $fileName のアップロードに失敗: $($_.Exception.Message)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  $filePath が見つかりません（スキップ）" -ForegroundColor DarkGray
        }
    }

    if ($uploadCount -eq 0) {
        Write-Host "  Knowledge Base アップロードに失敗しました。ポータルから手動でアップロードしてください。" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  データプレーントークンを取得できませんでした。ポータルから手動でアップロードしてください。" -ForegroundColor DarkGray
}

# --- 完了 ---
Write-Host "`n========================================" -ForegroundColor Green
Write-Host " SRE Agent デプロイ完了!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Portal:   $portalUrl" -ForegroundColor White
Write-Host "  Endpoint: $agentEndpoint" -ForegroundColor White
Write-Host "  監視対象: $InfraResourceGroup" -ForegroundColor White
Write-Host ""
Write-Host "  次のステップ:" -ForegroundColor Yellow
Write-Host "    1. ポータルで Custom Prompts にインシデント対応ワークフローを設定" -ForegroundColor White
Write-Host "       (infra/prompts/common.md の内容を貼り付け)" -ForegroundColor DarkGray
Write-Host "    2. ポータルでスケジュールタスクにヘルスチェックを設定" -ForegroundColor White
Write-Host "       (infra/prompts/health-check.md の内容を貼り付け)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  削除: ./scripts/destroy-sre-agent.ps1 -ResourceGroup $AgentResourceGroup" -ForegroundColor DarkGray
