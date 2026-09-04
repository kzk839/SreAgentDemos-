<#
.SYNOPSIS
    Control/Demo インフラと空の SRE Agent RG をデプロイ

.PARAMETER AllowedSourceIp
        Demo App と Control App へのインターネットアクセスを許可する単一のパブリック IPv4 アドレス。
        省略時は両方を内部 ACA とし、Bastion 経由の VM からのみアクセス可能。

.PARAMETER MigrateLegacyControlNetwork
    旧Control VNet構成を削除し、Hub VNet内の専用サブネット構成へ移行する。
#>
param(
    [string]$ResourceGroup = "rg-sre-demo",
    [string]$Location = "japaneast",
    [string]$SreAgentResourceGroup = "rg-sre-agent",
    [string]$SreAgentLocation = "eastus2",
    [string]$ControlPrefix = "srectrl",
    [string]$AllowedSourceIp = "",
    [switch]$MigrateLegacyControlNetwork,
    [hashtable]$Tags = @{}
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'deploy-validation.ps1')

function Invoke-AzCommand {
    param([string[]]$Arguments, [string]$FailureMessage)
    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
    return $output
}

function Assert-EnvironmentMode {
    param([string]$ResourceGroupName, [string]$EnvironmentName, [string]$AllowedIp, [switch]$AllowRecreation)

    $resourceGroupExists = Invoke-AzCommand @("group", "exists", "--name", $ResourceGroupName, "-o", "tsv") `
        "インフラ RG '$ResourceGroupName' の存在確認に失敗しました。"
    if (-not [System.Convert]::ToBoolean($resourceGroupExists)) { return }

    $existingEnvironmentInternal = Invoke-AzCommand @(
        "containerapp", "env", "list", "--resource-group", $ResourceGroupName,
        "--query", "[?name=='$EnvironmentName'].properties.vnetConfiguration.internal | [0]", "-o", "tsv"
    ) "Container Apps Environment '$EnvironmentName' の状態を取得できませんでした。"
    if ([string]::IsNullOrWhiteSpace($existingEnvironmentInternal)) { return }

    $requestedEnvironmentInternal = [string]::IsNullOrWhiteSpace($AllowedIp)
    $currentEnvironmentInternal = [System.Convert]::ToBoolean($existingEnvironmentInternal)
    if ($currentEnvironmentInternal -ne $requestedEnvironmentInternal -and -not $AllowRecreation) {
        throw "既存の Container Apps Environment '$EnvironmentName' は内部/公開モードを変更できません。README の手順で対象の App と Environment を再作成してから再実行してください。"
    }
}

function Invoke-LegacyControlNetworkMigration {
    param(
        [string]$ResourceGroupName,
        [string]$EnvironmentName,
        [string]$ExpectedSubnetId,
        [string]$Prefix,
        [string]$AllowedIp
    )

    $existingEnvironmentSubnetId = Invoke-AzCommand @(
        "containerapp", "env", "list", "--resource-group", $ResourceGroupName,
        "--query", "[?name=='$EnvironmentName'].properties.vnetConfiguration.infrastructureSubnetId | [0]", "-o", "tsv"
    ) "Container Apps Environment '$EnvironmentName' のサブネットを取得できませんでした。"
    $legacyVnetName = "$Prefix-vnet"
    $legacyVnetExists = Invoke-AzCommand @(
        "network", "vnet", "list", "--resource-group", $ResourceGroupName,
        "--query", "[?name=='$legacyVnetName'].name | [0]", "-o", "tsv"
    ) "旧 Control VNet '$legacyVnetName' の存在確認に失敗しました。"

    $existingEnvironmentInternal = Invoke-AzCommand @(
        "containerapp", "env", "list", "--resource-group", $ResourceGroupName,
        "--query", "[?name=='$EnvironmentName'].properties.vnetConfiguration.internal | [0]", "-o", "tsv"
    ) "Container Apps Environment '$EnvironmentName' の状態を取得できませんでした。"
    $environmentNeedsRecreation = -not [string]::IsNullOrWhiteSpace($existingEnvironmentSubnetId) -and
        $existingEnvironmentSubnetId -ne $ExpectedSubnetId
    if (-not [string]::IsNullOrWhiteSpace($existingEnvironmentInternal)) {
        $requestedEnvironmentInternal = [string]::IsNullOrWhiteSpace($AllowedIp)
        $environmentNeedsRecreation = $environmentNeedsRecreation -or
            ([System.Convert]::ToBoolean($existingEnvironmentInternal) -ne $requestedEnvironmentInternal)
    }
    if (-not $environmentNeedsRecreation -and [string]::IsNullOrWhiteSpace($legacyVnetExists)) { return }
    if (-not $MigrateLegacyControlNetwork) {
        throw "旧 Control VNet 構成を検出しました。内容を確認し、-MigrateLegacyControlNetwork を指定して再実行してください。"
    }

    Write-Host "  旧 Control VNet 構成を削除して Hub VNet 構成へ移行..." -ForegroundColor Yellow
    if ($environmentNeedsRecreation) {
        $controlAppName = "$Prefix-app"
        $controlAppExists = Invoke-AzCommand @(
            "containerapp", "list", "--resource-group", $ResourceGroupName,
            "--query", "[?name=='$controlAppName'].name | [0]", "-o", "tsv"
        ) "Control App '$controlAppName' の存在確認に失敗しました。"
        if (-not [string]::IsNullOrWhiteSpace($controlAppExists)) {
            Invoke-AzCommand @("containerapp", "delete", "--name", $controlAppName, "--resource-group", $ResourceGroupName, "--yes") `
                "旧 Control App '$controlAppName' の削除に失敗しました。" | Out-Null
        }
        Invoke-AzCommand @("containerapp", "env", "delete", "--name", $EnvironmentName, "--resource-group", $ResourceGroupName, "--yes") `
            "旧 Container Apps Environment '$EnvironmentName' の削除に失敗しました。" | Out-Null
    }

    $legacyPrivateEndpointName = "$Prefix-table-pe"
    $legacyPrivateEndpointExists = Invoke-AzCommand @(
        "network", "private-endpoint", "list", "--resource-group", $ResourceGroupName,
        "--query", "[?name=='$legacyPrivateEndpointName'].name | [0]", "-o", "tsv"
    ) "旧 Table Private Endpoint '$legacyPrivateEndpointName' の存在確認に失敗しました。"
    if (-not [string]::IsNullOrWhiteSpace($legacyPrivateEndpointExists)) {
        Invoke-AzCommand @("network", "private-endpoint", "delete", "--name", $legacyPrivateEndpointName, "--resource-group", $ResourceGroupName) `
            "旧 Table Private Endpoint '$legacyPrivateEndpointName' の削除に失敗しました。" | Out-Null
    }

    $tablePrivateDnsZoneName = 'privatelink.table.core.windows.net'
    $legacyDnsLinkName = "$Prefix-table-link"
    $legacyDnsLinkExists = Invoke-AzCommand @(
        "network", "private-dns", "link", "vnet", "list", "--resource-group", $ResourceGroupName,
        "--zone-name", $tablePrivateDnsZoneName, "--query", "[?name=='$legacyDnsLinkName'].name | [0]", "-o", "tsv"
    ) "旧 Table Private DNS link '$legacyDnsLinkName' の存在確認に失敗しました。"
    if (-not [string]::IsNullOrWhiteSpace($legacyDnsLinkExists)) {
        Invoke-AzCommand @(
            "network", "private-dns", "link", "vnet", "delete", "--resource-group", $ResourceGroupName,
            "--zone-name", $tablePrivateDnsZoneName, "--name", $legacyDnsLinkName, "--yes"
        ) "旧 Table Private DNS link '$legacyDnsLinkName' の削除に失敗しました。" | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($legacyVnetExists)) {
        Invoke-AzCommand @("network", "vnet", "delete", "--name", $legacyVnetName, "--resource-group", $ResourceGroupName) `
            "旧 Control VNet '$legacyVnetName' の削除に失敗しました。" | Out-Null
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " SRE Agent Demo - Deploy" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

foreach ($variableName in @("SRE_ADMIN_PASSWORD", "SRE_SQL_PASSWORD", "SRE_NOTIFICATION_EMAIL")) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($variableName))) {
        throw "環境変数 '$variableName' が設定されていません。"
    }
}
if ([string]::IsNullOrWhiteSpace($env:SRE_SQL_FAULT_RUNNER_PASSWORD)) {
    $passwordBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($passwordBytes)
    $env:SRE_SQL_FAULT_RUNNER_PASSWORD = [Convert]::ToBase64String($passwordBytes)
}
if ($ControlPrefix -notmatch '^[a-z0-9]{2,10}$') {
    throw "-ControlPrefix は小文字英数字 2～10 文字で指定してください。"
}
if ($ResourceGroup -eq $SreAgentResourceGroup) {
    throw "-ResourceGroup と -SreAgentResourceGroup には異なる名前を指定してください。"
}
$AllowedSourceIp = $AllowedSourceIp.Trim()
if (-not [string]::IsNullOrWhiteSpace($AllowedSourceIp) -and -not (Test-PublicIPv4Address $AllowedSourceIp)) {
    throw "-AllowedSourceIp には CIDR を付けず、単一のパブリック IPv4 アドレスを指定してください。"
}

$demoEnvironmentName = 'sre-demo-cae'
$controlEnvironmentName = "$ControlPrefix-cae"
Assert-EnvironmentMode $ResourceGroup $demoEnvironmentName $AllowedSourceIp
Assert-EnvironmentMode $ResourceGroup $controlEnvironmentName $AllowedSourceIp -AllowRecreation:$MigrateLegacyControlNetwork

# --- 1. リソースグループ作成 ---
Write-Host "`n[1/8] リソースグループを作成..." -ForegroundColor Yellow
$tagArguments = @()
if ($Tags.Count -gt 0) {
    $tagArguments = @("--tags") + @($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
}
Invoke-AzCommand (@("group", "create", "--name", $ResourceGroup, "--location", $Location, "-o", "none") + $tagArguments) `
    "インフラ RG '$ResourceGroup' の作成に失敗しました。" | Out-Null
Invoke-AzCommand (@("group", "create", "--name", $SreAgentResourceGroup, "--location", $SreAgentLocation, "-o", "none") + $tagArguments) `
    "空の Agent RG '$SreAgentResourceGroup' の作成に失敗しました。" | Out-Null
Write-Host "  インフラ RG: $ResourceGroup ($Location)" -ForegroundColor Green
Write-Host "  空の Agent RG: $SreAgentResourceGroup ($SreAgentLocation)" -ForegroundColor Green
Assert-EnvironmentMode $ResourceGroup $demoEnvironmentName $AllowedSourceIp
Assert-EnvironmentMode $ResourceGroup $controlEnvironmentName $AllowedSourceIp -AllowRecreation:$MigrateLegacyControlNetwork

# --- 2. Demo 用 Log Analytics を先行作成 ---
$lawName = "sre-demo-law"
Write-Host "`n[2/8] Log Analytics ワークスペースを先行作成: $lawName" -ForegroundColor Yellow
Invoke-AzCommand @(
    "monitor", "log-analytics", "workspace", "create",
    "--resource-group", $ResourceGroup, "--workspace-name", $lawName,
    "--location", $Location, "--retention-time", "30", "--sku", "PerGB2018", "-o", "none"
) "Log Analytics ワークスペースの作成に失敗しました。" | Out-Null

Write-Host "  DCR テーブル (Microsoft-Perf / Microsoft-Event) の準備を待機中..." -ForegroundColor DarkGray
for ($retry = 1; $retry -le 12; $retry++) {
    $tables = @(Invoke-AzCommand @(
        "monitor", "log-analytics", "workspace", "table", "list",
        "--resource-group", $ResourceGroup, "--workspace-name", $lawName,
        "--query", "[?name=='Perf' || name=='Event'].name", "-o", "tsv"
    ) "Log Analytics のテーブル状態を取得できませんでした。")
    $tableList = @($tables | Where-Object { $_ -match '\S' })
    if ($tableList.Count -ge 2) {
        Write-Host "  テーブル準備完了 ($($tableList -join ', '))" -ForegroundColor Green
        break
    }
    if ($retry -eq 12) {
        Write-Warning "テーブルの準備確認がタイムアウトしました。デプロイを続行します。"
        break
    }
    Write-Host "  待機中... ($retry/12)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
}

# --- 3. Fault 状態 Storage を先にデプロイ ---
$faultEnvironmentId = "$($ResourceGroup.ToLowerInvariant())/$ControlPrefix"
Write-Host "`n[3/8] Fault 状態 Storage をインフラ RG にデプロイ..." -ForegroundColor Yellow
$stateResult = Invoke-AzCommand @(
    "deployment", "group", "create", "--name", "control-state",
    "--resource-group", $ResourceGroup, "--template-file", "infra/modules/faultState.bicep",
    "--parameters", "location=$Location", "namePrefix=$ControlPrefix",
    "--query", "properties.outputs", "-o", "json"
) "Fault 状態 Storage の Bicep デプロイに失敗しました。" | ConvertFrom-Json

$faultStorageAccountName = $stateResult.storageAccountName.value
if ([string]::IsNullOrWhiteSpace($faultStorageAccountName)) {
    throw "Fault 状態 Storage の必須出力を取得できませんでした。"
}
Write-Host "  Control Storage: $faultStorageAccountName" -ForegroundColor Green

# --- 4. Storage を接続して Demo インフラをデプロイ ---
$env:SRE_CONTROL_RESOURCE_GROUP = $ResourceGroup
$env:SRE_FAULT_STORAGE_ACCOUNT = $faultStorageAccountName
$env:SRE_FAULT_ENVIRONMENT_ID = $faultEnvironmentId
$env:SRE_ALLOWED_SOURCE_IP = $AllowedSourceIp
Write-Host "`n[4/8] Demo インフラを同じインフラ RG にデプロイ（約 20～30 分）..." -ForegroundColor Yellow
$demoResult = Invoke-AzCommand @(
    "deployment", "group", "create", "--name", "demo-infrastructure",
    "--resource-group", $ResourceGroup, "--template-file", "infra/main.bicep",
    "--parameters", "infra/main.bicepparam", "--query", "properties.outputs", "-o", "json"
) "Demo インフラの Bicep デプロイに失敗しました。" | ConvertFrom-Json

$demoAcrLoginServer = $demoResult.acrLoginServer.value
$demoAcrName = $demoAcrLoginServer -replace '\.azurecr\.io$', ''
$demoAppFqdn = $demoResult.containerAppFqdn.value
$demoAppName = "sre-demo-app"
$hubVnetId = $demoResult.hubVirtualNetworkId.value
$controlInfrastructureSubnetId = $demoResult.controlInfrastructureSubnetId.value
if ([string]::IsNullOrWhiteSpace($demoAcrLoginServer) -or
    [string]::IsNullOrWhiteSpace($demoAppFqdn) -or
    [string]::IsNullOrWhiteSpace($hubVnetId) -or
    [string]::IsNullOrWhiteSpace($controlInfrastructureSubnetId)) {
    throw "Demo インフラの必須出力を取得できませんでした。"
}
Invoke-LegacyControlNetworkMigration $ResourceGroup $controlEnvironmentName $controlInfrastructureSubnetId $ControlPrefix $AllowedSourceIp

# --- 5. Hub VNet の専用サブネットへ Control インフラをデプロイ ---
Write-Host "`n[5/8] Control インフラをHub VNetにデプロイ..." -ForegroundColor Yellow
$controlResult = Invoke-AzCommand @(
    "deployment", "group", "create", "--name", "control-infrastructure",
    "--resource-group", $ResourceGroup, "--template-file", "infra/control-main.bicep",
    "--parameters", "location=$Location", "prefix=$ControlPrefix", "targetPort=8080",
    "allowedSourceIpAddress=$AllowedSourceIp", "faultEnvironmentId=$faultEnvironmentId",
    "storageAccountName=$faultStorageAccountName", "virtualNetworkId=$hubVnetId",
    "infrastructureSubnetId=$controlInfrastructureSubnetId",
    "--query", "properties.outputs", "-o", "json"
) "Control インフラの Bicep デプロイに失敗しました。" | ConvertFrom-Json

$controlAcrLoginServer = $controlResult.registryLoginServer.value
$controlAcrName = $controlAcrLoginServer -replace '\.azurecr\.io$', ''
$controlAppFqdn = $controlResult.containerAppFqdn.value
$controlAppName = "$ControlPrefix-app"
if ([string]::IsNullOrWhiteSpace($controlAcrLoginServer) -or [string]::IsNullOrWhiteSpace($controlAppFqdn)) {
    throw "Control インフラの必須出力を取得できませんでした。"
}
Write-Host "  Control ACR: $controlAcrLoginServer" -ForegroundColor Green
Write-Host "  Control App: $controlAppFqdn" -ForegroundColor Green

# --- 6. 各 ACR で各アプリをビルド ---
$commitTag = (& git rev-parse --short HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commitTag)) {
    throw "Git コミットハッシュを取得できませんでした。Git リポジトリの状態を確認してください。"
}
$imageTag = "$commitTag-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host "`n[6/8] Control/Demo/Fault Runner イメージをビルド: $imageTag" -ForegroundColor Yellow
Invoke-AzCommand @("acr", "build", "--registry", $controlAcrName, "--image", "sre-control-app:$imageTag", "./control-app") `
    "Control App の ACR ビルドに失敗しました。" | Out-Null
Invoke-AzCommand @("acr", "build", "--registry", $demoAcrName, "--image", "sre-demo-app:$imageTag", "./app") `
    "Demo App の ACR ビルドに失敗しました。" | Out-Null
Invoke-AzCommand @("acr", "build", "--registry", $demoAcrName, "--image", "sre-fault-runner:$imageTag", "./fault-runner") `
    "Fault Runner の ACR ビルドに失敗しました。" | Out-Null

# --- 7. Container App と Job を更新 ---
Write-Host "`n[7/8] Control/Demo/Fault Runner のイメージを更新..." -ForegroundColor Yellow
Invoke-AzCommand @(
    "containerapp", "update", "--name", $controlAppName, "--resource-group", $ResourceGroup,
    "--image", "$controlAcrLoginServer/sre-control-app:$imageTag", "-o", "none"
) "Control Container App の更新に失敗しました。" | Out-Null
Invoke-AzCommand @(
    "containerapp", "update", "--name", $demoAppName, "--resource-group", $ResourceGroup,
    "--image", "$demoAcrLoginServer/sre-demo-app:$imageTag", "-o", "none"
) "Demo Container App の更新に失敗しました。" | Out-Null
Invoke-AzCommand @(
    "containerapp", "update", "--name", "sre-demo-fault-runner", "--resource-group", $ResourceGroup,
    "--image", "$demoAcrLoginServer/sre-fault-runner:$imageTag", "-o", "none"
) "Fault Runner Container App の更新に失敗しました。" | Out-Null
Invoke-AzCommand @(
    "containerapp", "job", "update", "--name", "sre-demo-fault-reconciler", "--resource-group", $ResourceGroup,
    "--image", "$demoAcrLoginServer/sre-fault-runner:$imageTag", "-o", "none"
) "Fault Reconciler Job の更新に失敗しました。" | Out-Null

# --- 8. 完了 ---
$appInsightsName = "sre-demo-appi"
$appInsightsId = Invoke-AzCommand @(
    "resource", "show", "--resource-group", $ResourceGroup,
    "--resource-type", "Microsoft.Insights/components", "--name", $appInsightsName,
    "--query", "id", "-o", "tsv"
) "Application Insights のリソース ID を取得できませんでした。"

Write-Host "`n[8/8] デプロイ完了" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Demo URL:          https://$demoAppFqdn" -ForegroundColor White
Write-Host "  Control URL:       https://$controlAppFqdn" -ForegroundColor White
if ([string]::IsNullOrWhiteSpace($AllowedSourceIp)) {
    Write-Host "  App Access:        Private (Bastion/VM required)" -ForegroundColor White
} else {
    Write-Host "  App Access:        Public, allowed from $AllowedSourceIp/32" -ForegroundColor White
}
Write-Host "  インフラ RG:       $ResourceGroup" -ForegroundColor White
Write-Host "  空の Agent RG:     $SreAgentResourceGroup" -ForegroundColor White
Write-Host "  Log Analytics:     $($demoResult.logAnalyticsWorkspaceName.value)" -ForegroundColor White
Write-Host "  Log Analytics ID:  $($demoResult.logAnalyticsWorkspaceId.value)" -ForegroundColor White
Write-Host "  App Insights:      $appInsightsName" -ForegroundColor White
Write-Host "  App Insights ID:   $appInsightsId" -ForegroundColor White
Write-Host "  Fault Environment: $faultEnvironmentId" -ForegroundColor White
Write-Host ""
Write-Host "  対応 Fault ID:" -ForegroundColor Yellow
Write-Host "    app-exception, app-latency, app-n-plus-one" -ForegroundColor White
Write-Host "    vm-cpu-high, vm-memory-high, vm-disk-pressure" -ForegroundColor White
Write-Host "    sql-high-load, sql-deadlock, network-deny" -ForegroundColor White
Write-Host ""
Write-Host "  次のステップ:" -ForegroundColor Yellow
Write-Host "    1. https://sre.azure.com/ を開く" -ForegroundColor White
Write-Host "    2. Agent RG '$SreAgentResourceGroup' に SRE Agent を作成する" -ForegroundColor White
Write-Host "    3. インフラ RG '$ResourceGroup' と上記監視リソースを対象に設定する" -ForegroundColor White
Write-Host ""
Write-Host "  削除: ./scripts/destroy.ps1 -ResourceGroup $ResourceGroup -SreAgentResourceGroup $SreAgentResourceGroup" -ForegroundColor DarkGray
