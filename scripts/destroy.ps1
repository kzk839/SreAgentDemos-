<#
.SYNOPSIS
  SRE Agent Demo のリソースグループを一括削除

.DESCRIPTION
  Control と Demo を含むインフラ RG を削除します。継続課金を防ぐため、
  既定では参加者用 SRE Agent RG も削除します。

.PARAMETER KeepSreAgent
  SRE Agent リソースグループを削除せず保持する
#>
param(
    [string]$ResourceGroup = "rg-sre-demo",
    [string]$SreAgentResourceGroup = "rg-sre-agent",
    [switch]$KeepSreAgent,
    [switch]$NoConfirm
)

$ErrorActionPreference = "Stop"

function Remove-ResourceGroup {
    param([string]$Name)
    $exists = & az group exists --name $Name
    if ($LASTEXITCODE -ne 0) { throw "リソースグループ '$Name' の存在確認に失敗しました。" }
    if ($exists -ne "true") {
        Write-Host "リソースグループ '$Name' は存在しないためスキップします。" -ForegroundColor DarkGray
        return
    }
    Write-Host "リソースグループ '$Name' を削除中（バックグラウンド）..." -ForegroundColor Yellow
    & az group delete --name $Name --yes --no-wait
    if ($LASTEXITCODE -ne 0) { throw "リソースグループ '$Name' の削除開始に失敗しました。" }
}

Write-Host "========================================" -ForegroundColor Red
Write-Host " SRE Agent Demo - Destroy" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host "削除対象:" -ForegroundColor Yellow
Write-Host "  インフラ RG (Control + Demo): $ResourceGroup" -ForegroundColor White
if ($KeepSreAgent) {
    Write-Host "  Agent RG: ${SreAgentResourceGroup}（保持）" -ForegroundColor DarkGray
} else {
    Write-Host "  Agent RG: ${SreAgentResourceGroup}（削除）" -ForegroundColor White
}

if (-not $NoConfirm) {
    $confirm = Read-Host "上記のリソースグループを削除します。続行しますか？ (y/N)"
    if ($confirm -ne 'y') {
        Write-Host "中止しました。" -ForegroundColor Gray
        exit 0
    }
}

Remove-ResourceGroup -Name $ResourceGroup
if (-not $KeepSreAgent -and $SreAgentResourceGroup -ne $ResourceGroup) {
    Remove-ResourceGroup -Name $SreAgentResourceGroup
}

Write-Host "削除がバックグラウンドで開始されました。完了まで数分かかります。" -ForegroundColor Green
Write-Host "状態確認: az group exists --name $ResourceGroup" -ForegroundColor DarkGray
if (-not $KeepSreAgent -and $SreAgentResourceGroup -ne $ResourceGroup) {
    Write-Host "状態確認: az group exists --name $SreAgentResourceGroup" -ForegroundColor DarkGray
}
