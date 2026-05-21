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

# --- 1. RG 作成 ---
Write-Host "`n[1/5] SRE Agent 用 RG 作成: $AgentResourceGroup ($Location)" -ForegroundColor Yellow
$rgArgs = @("group", "create", "--name", $AgentResourceGroup, "--location", $Location, "-o", "none")
if ($Tags.Count -gt 0) {
    $tagStrings = $Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    $rgArgs += @("--tags") + $tagStrings
}
az @rgArgs

# --- 2. インフラ RG からリソース情報を取得 ---
Write-Host "`n[2/5] インフラ RG ($InfraResourceGroup) からリソース情報を取得..." -ForegroundColor Yellow

$subscriptionId = (az account show --query id -o tsv)
$infraRgId = "/subscriptions/$subscriptionId/resourceGroups/$InfraResourceGroup"

# Log Analytics Workspace
$lawId = az monitor log-analytics workspace list -g $InfraResourceGroup --query "[0].id" -o tsv
if (-not $lawId) { Write-Error "Log Analytics Workspace が見つかりません"; exit 1 }
Write-Host "  LAW: $lawId" -ForegroundColor DarkGray

# Application Insights
$appiJson = az monitor app-insights component show -g $InfraResourceGroup --query "[0]" -o json | ConvertFrom-Json
if (-not $appiJson) { Write-Error "Application Insights が見つかりません"; exit 1 }
$appiId = $appiJson.id
$appiAppId = $appiJson.appId
$appiConnStr = $appiJson.connectionString
Write-Host "  App Insights: $appiId" -ForegroundColor DarkGray

# --- 3. 環境変数にセット ---
$env:SRE_INFRA_RG_ID = $infraRgId
$env:SRE_LAW_ID = $lawId
$env:SRE_APPI_ID = $appiId
$env:SRE_APPI_APP_ID = $appiAppId
$env:SRE_APPI_CONNECTION_STRING = $appiConnStr

# --- 4. Bicep デプロイ ---
Write-Host "`n[3/5] SRE Agent デプロイ..." -ForegroundColor Yellow
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
$portalUrl = $deployResult.portalUrl.value

Write-Host "  Agent: $agentName" -ForegroundColor Green
Write-Host "  Endpoint: $agentEndpoint" -ForegroundColor Green

# --- 5. インフラ RG に RBAC 付与 ---
Write-Host "`n[4/5] インフラ RG に SRE Agent の RBAC を付与..." -ForegroundColor Yellow
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

# --- 6. Knowledge Base アップロード ---
Write-Host "`n[5/5] Knowledge Base にドキュメントをアップロード..." -ForegroundColor Yellow
$token = az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv 2>$null
if ($token) {
    $specFile = "docs/infrastructure-spec.md"
    if (Test-Path $specFile) {
        $boundary = [System.Guid]::NewGuid().ToString()
        $fileName = "infrastructure-spec.md"
        $fileBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $specFile))
        $fileBase64 = [Convert]::ToBase64String($fileBytes)

        # multipart/form-data upload
        $headers = @{
            "Authorization" = "Bearer $token"
        }
        $form = @{
            file = Get-Item -Path $specFile
        }

        try {
            Invoke-RestMethod `
                -Uri "$agentEndpoint/api/v1/agentmemory/upload" `
                -Method POST `
                -Headers $headers `
                -Form $form `
                -ContentType "multipart/form-data"
            Write-Host "  $fileName をアップロード" -ForegroundColor Green
        } catch {
            Write-Host "  Knowledge Base アップロードをスキップ: $($_.Exception.Message)" -ForegroundColor DarkGray
            Write-Host "  ポータルから手動でアップロードしてください: $portalUrl" -ForegroundColor DarkGray
        }
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
Write-Host "  削除: ./scripts/destroy-sre-agent.ps1 -ResourceGroup $AgentResourceGroup" -ForegroundColor DarkGray
