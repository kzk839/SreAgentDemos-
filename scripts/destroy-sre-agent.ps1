<#
.SYNOPSIS
  SRE Agent 環境を削除（インフラは残す）

.PARAMETER ResourceGroup
  SRE Agent の RG 名

.PARAMETER NoConfirm
  確認プロンプトをスキップ

.EXAMPLE
  ./scripts/destroy-sre-agent.ps1
  ./scripts/destroy-sre-agent.ps1 -NoConfirm
  ./scripts/destroy-sre-agent.ps1 -ResourceGroup "rg-sre-agent-test"
#>

param(
    [string]$ResourceGroup = "rg-sre-agent",
    [switch]$NoConfirm
)

Write-Host "========================================" -ForegroundColor Red
Write-Host " SRE Agent - Destroy" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""
Write-Host "リソースグループ '$ResourceGroup' を削除します。" -ForegroundColor Yellow
Write-Host "※ インフラ RG (rg-sre-demo*) には影響しません。" -ForegroundColor DarkGray

if (-not $NoConfirm) {
    $confirm = Read-Host "続行しますか？ (y/N)"
    if ($confirm -ne 'y') {
        Write-Host "中止しました。" -ForegroundColor Gray
        exit 0
    }
}

Write-Host "`nリソースグループを削除中（バックグラウンド）..." -ForegroundColor Yellow
az group delete --name $ResourceGroup --yes --no-wait

Write-Host "削除がバックグラウンドで開始されました。完了まで数分かかります。" -ForegroundColor Green
Write-Host "状態確認: az group show --name $ResourceGroup --query properties.provisioningState -o tsv" -ForegroundColor DarkGray
