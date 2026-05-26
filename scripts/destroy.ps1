<#
.SYNOPSIS
  SRE Agent Demo 環境を一括削除

.PARAMETER ResourceGroup
  削除するリソースグループ名（デフォルト: rg-sre-demo）

.PARAMETER IncludeSreAgent
  SRE Agent のリソースグループも削除する

.PARAMETER SreAgentResourceGroup
  SRE Agent のリソースグループ名（デフォルト: rg-sre-agent）

.PARAMETER NoConfirm
  確認プロンプトをスキップ

.EXAMPLE
  ./scripts/destroy.ps1
  ./scripts/destroy.ps1 -IncludeSreAgent
  ./scripts/destroy.ps1 -NoConfirm
#>

param(
    [string]$ResourceGroup = "rg-sre-demo",
    [switch]$IncludeSreAgent,
    [string]$SreAgentResourceGroup = "rg-sre-agent",
    [switch]$NoConfirm
)

Write-Host "========================================" -ForegroundColor Red
Write-Host " SRE Agent Demo - Destroy" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""
Write-Host "リソースグループ '$ResourceGroup' 内の全リソースを削除します。" -ForegroundColor Yellow
if ($IncludeSreAgent) {
    Write-Host "SRE Agent リソースグループ '$SreAgentResourceGroup' も削除します。" -ForegroundColor Yellow
}

if (-not $NoConfirm) {
    $confirm = Read-Host "続行しますか？ (y/N)"
    if ($confirm -ne 'y') {
        Write-Host "中止しました。" -ForegroundColor Gray
        exit 0
    }
}

Write-Host "`nリソースグループ '$ResourceGroup' を削除中（バックグラウンド）..." -ForegroundColor Yellow
az group delete --name $ResourceGroup --yes --no-wait

if ($IncludeSreAgent) {
    Write-Host "SRE Agent リソースグループ '$SreAgentResourceGroup' を削除中（バックグラウンド）..." -ForegroundColor Yellow
    az group delete --name $SreAgentResourceGroup --yes --no-wait
}

Write-Host "削除がバックグラウンドで開始されました。完了まで数分かかります。" -ForegroundColor Green
Write-Host "状態確認: az group show --name $ResourceGroup --query properties.provisioningState -o tsv" -ForegroundColor DarkGray
