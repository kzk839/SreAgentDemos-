<#
.SYNOPSIS
  Control/Demo インフラと空の参加者用 SRE Agent RG をデプロイ

.PARAMETER ControlEntraClientId
  Control App の Entra クライアント ID。既定値は SRE_CONTROL_ENTRA_CLIENT_ID
.PARAMETER EnableOidc
  Demo ACR/App 用 GitHub Actions OIDC 設定を有効化
#>
param(
    [string]$ResourceGroup = "rg-sre-demo",
    [string]$Location = "japaneast",
    [string]$SreAgentResourceGroup = "rg-sre-agent",
    [string]$SreAgentLocation = "eastus2",
    [string]$ControlPrefix = "srectrl",
    [string]$ControlEntraClientId = [Environment]::GetEnvironmentVariable("SRE_CONTROL_ENTRA_CLIENT_ID"),
    [hashtable]$Tags = @{},
    [string]$GitHubRepo = "",
    [switch]$EnableOidc
)

$ErrorActionPreference = "Stop"

function Invoke-AzCommand {
    param([string[]]$Arguments, [string]$FailureMessage)
    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
    return $output
}

function Invoke-GhCommand {
    param([string[]]$Arguments, [string]$FailureMessage)
    & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " SRE Agent Demo - Deploy" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

foreach ($variableName in @("SRE_ADMIN_PASSWORD", "SRE_SQL_PASSWORD", "SRE_NOTIFICATION_EMAIL")) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($variableName))) {
        throw "環境変数 '$variableName' が設定されていません。"
    }
}
if ([string]::IsNullOrWhiteSpace($ControlEntraClientId)) {
    throw "環境変数 SRE_CONTROL_ENTRA_CLIENT_ID または -ControlEntraClientId を指定してください。"
}
if ($ControlPrefix -notmatch '^[a-z0-9]{2,10}$') {
    throw "-ControlPrefix は小文字英数字 2～10 文字で指定してください。"
}
if ($ResourceGroup -eq $SreAgentResourceGroup) {
    throw "-ResourceGroup と -SreAgentResourceGroup には異なる名前を指定してください。"
}

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

$account = Invoke-AzCommand @("account", "show", "-o", "json") `
    "Azure アカウント情報を取得できませんでした。az login を確認してください。" | ConvertFrom-Json
$subscriptionId = $account.id
$tenantId = $account.tenantId
$entraIssuer = "https://login.microsoftonline.com/$tenantId/v2.0"

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

# --- 3. Control インフラを先にデプロイ ---
$faultEnvironmentId = "$($ResourceGroup.ToLowerInvariant())/$ControlPrefix"
Write-Host "`n[3/8] Control インフラをインフラ RG にデプロイ..." -ForegroundColor Yellow
$controlResult = Invoke-AzCommand @(
    "deployment", "group", "create", "--name", "control-infrastructure",
    "--resource-group", $ResourceGroup, "--template-file", "infra/control-main.bicep",
    "--parameters", "location=$Location", "prefix=$ControlPrefix", "targetPort=8080",
    "entraClientId=$ControlEntraClientId", "entraIssuer=$entraIssuer",
    "faultEnvironmentId=$faultEnvironmentId", "--query", "properties.outputs", "-o", "json"
) "Control インフラの Bicep デプロイに失敗しました。" | ConvertFrom-Json

$faultStorageAccountName = ($controlResult.storageAccountId.value -split '/')[-1]
$controlAcrLoginServer = $controlResult.registryLoginServer.value
$controlAcrName = $controlAcrLoginServer -replace '\.azurecr\.io$', ''
$controlAppFqdn = $controlResult.containerAppFqdn.value
$controlAppName = "$ControlPrefix-app"
if ([string]::IsNullOrWhiteSpace($faultStorageAccountName) -or
    [string]::IsNullOrWhiteSpace($controlAcrLoginServer) -or
    [string]::IsNullOrWhiteSpace($controlAppFqdn)) {
    throw "Control インフラの必須出力を取得できませんでした。"
}
Write-Host "  Control Storage: $faultStorageAccountName" -ForegroundColor Green
Write-Host "  Control ACR: $controlAcrLoginServer" -ForegroundColor Green
Write-Host "  Control App: $controlAppFqdn" -ForegroundColor Green

# --- 4. Control 出力を接続して Demo インフラをデプロイ ---
$env:SRE_CONTROL_RESOURCE_GROUP = $ResourceGroup
$env:SRE_FAULT_STORAGE_ACCOUNT = $faultStorageAccountName
$env:SRE_FAULT_ENVIRONMENT_ID = $faultEnvironmentId
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
if ([string]::IsNullOrWhiteSpace($demoAcrLoginServer) -or [string]::IsNullOrWhiteSpace($demoAppFqdn)) {
    throw "Demo インフラの必須出力を取得できませんでした。"
}

# --- 5. 各 ACR で各アプリをビルド ---
$imageTag = (& git rev-parse --short HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($imageTag)) {
    throw "Git コミットハッシュを取得できませんでした。Git リポジトリの状態を確認してください。"
}
Write-Host "`n[5/8] Control/Demo イメージを別々の ACR でビルド: $imageTag" -ForegroundColor Yellow
Invoke-AzCommand @("acr", "build", "--registry", $controlAcrName, "--image", "sre-control-app:$imageTag", "./control-app") `
    "Control App の ACR ビルドに失敗しました。" | Out-Null
Invoke-AzCommand @("acr", "build", "--registry", $demoAcrName, "--image", "sre-demo-app:$imageTag", "./app") `
    "Demo App の ACR ビルドに失敗しました。" | Out-Null

# --- 6. 両 Container App を更新 ---
Write-Host "`n[6/8] Control/Demo Container App のイメージを更新..." -ForegroundColor Yellow
Invoke-AzCommand @(
    "containerapp", "update", "--name", $controlAppName, "--resource-group", $ResourceGroup,
    "--image", "$controlAcrLoginServer/sre-control-app:$imageTag", "-o", "none"
) "Control Container App の更新に失敗しました。" | Out-Null
Invoke-AzCommand @(
    "containerapp", "update", "--name", $demoAppName, "--resource-group", $ResourceGroup,
    "--image", "$demoAcrLoginServer/sre-demo-app:$imageTag", "-o", "none"
) "Demo Container App の更新に失敗しました。" | Out-Null

# --- 7. GitHub Actions OIDC（Demo の ACR/App のみ） ---
if (-not $EnableOidc) {
    Write-Host "`n[7/8] GitHub Actions OIDC 設定...スキップ（有効化は -EnableOidc）" -ForegroundColor DarkGray
} else {
    Write-Host "`n[7/8] GitHub Actions OIDC 設定（Demo の ACR/App のみ）..." -ForegroundColor Yellow
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warning "gh CLI が見つからないため OIDC 設定をスキップします。"
    } else {
        if (-not $GitHubRepo) {
            $gitRemoteUrl = git remote get-url origin 2>$null
            if ($LASTEXITCODE -eq 0 -and $gitRemoteUrl -match 'github\.com[:/](.+?)(?:\.git)?$') { $GitHubRepo = $Matches[1] }
        }
        if (-not $GitHubRepo) {
            Write-Warning "GitHub リポジトリを検出できないため OIDC 設定をスキップします。"
        } else {
            $appDisplayName = "sre-demo-github-actions"
            $credentialName = "github-actions-main"
            $existingApp = Invoke-AzCommand @(
                "ad", "app", "list", "--display-name", $appDisplayName, "--query", "[0]", "-o", "json"
            ) "OIDC 用 Entra アプリを確認できませんでした。" | ConvertFrom-Json
            if ($existingApp) {
                $appClientId = $existingApp.appId
                $appObjectId = $existingApp.id
            } else {
                $newApp = Invoke-AzCommand @("ad", "app", "create", "--display-name", $appDisplayName, "-o", "json") `
                    "OIDC 用 Entra アプリの作成に失敗しました。" | ConvertFrom-Json
                $appClientId = $newApp.appId
                $appObjectId = $newApp.id
            }

            $servicePrincipalId = Invoke-AzCommand @(
                "ad", "sp", "list", "--filter", "appId eq '$appClientId'", "--query", "[0].id", "-o", "tsv"
            ) "OIDC 用 Service Principal を確認できませんでした。"
            if ([string]::IsNullOrWhiteSpace($servicePrincipalId)) {
                Invoke-AzCommand @("ad", "sp", "create", "--id", $appClientId, "-o", "none") `
                    "OIDC 用 Service Principal の作成に失敗しました。" | Out-Null
                $servicePrincipalId = Invoke-AzCommand @(
                    "ad", "sp", "list", "--filter", "appId eq '$appClientId'", "--query", "[0].id", "-o", "tsv"
                ) "作成した Service Principal を取得できませんでした。"
            }

            $credential = @{
                name = $credentialName
                issuer = "https://token.actions.githubusercontent.com"
                subject = "repo:${GitHubRepo}:ref:refs/heads/main"
                description = "GitHub Actions - main branch only"
                audiences = @("api://AzureADTokenExchange")
            }
            $existingCredential = Invoke-AzCommand @(
                "ad", "app", "federated-credential", "list", "--id", $appObjectId,
                "--query", "[?name=='$credentialName'] | [0]", "-o", "json"
            ) "Federated Credential を確認できませんでした。" | ConvertFrom-Json
            $credentialMatches = $existingCredential -and
                $existingCredential.issuer -eq $credential.issuer -and
                $existingCredential.subject -eq $credential.subject -and
                @($existingCredential.audiences).Count -eq 1 -and
                @($existingCredential.audiences)[0] -eq $credential.audiences[0]
            if (-not $credentialMatches) {
                if ($existingCredential) {
                    Invoke-AzCommand @(
                        "ad", "app", "federated-credential", "delete", "--id", $appObjectId,
                        "--federated-credential-id", $existingCredential.id
                    ) "既存 Federated Credential の削除に失敗しました。" | Out-Null
                }
                $tempFile = [System.IO.Path]::GetTempFileName()
                try {
                    $credential | ConvertTo-Json -Depth 3 | Set-Content -Path $tempFile -Encoding UTF8
                    Invoke-AzCommand @(
                        "ad", "app", "federated-credential", "create", "--id", $appObjectId,
                        "--parameters", $tempFile, "-o", "none"
                    ) "Federated Credential の作成に失敗しました。" | Out-Null
                } finally {
                    Remove-Item $tempFile -ErrorAction SilentlyContinue
                }
            }

            $demoAcrResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ContainerRegistry/registries/$demoAcrName"
            $demoAppResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$demoAppName"
            $roleAssignments = @(
                @{ Scope = $demoAcrResourceId; Role = "AcrPush" }
                @{ Scope = $demoAppResourceId; Role = "Contributor" }
            )
            foreach ($assignment in $roleAssignments) {
                Invoke-AzCommand @(
                    "role", "assignment", "create", "--assignee-object-id", $servicePrincipalId,
                    "--assignee-principal-type", "ServicePrincipal", "--role", $assignment.Role,
                    "--scope", $assignment.Scope, "-o", "none"
                ) "Demo リソースへの OIDC ロール割り当てに失敗しました。" | Out-Null
            }
            Invoke-GhCommand @("secret", "set", "AZURE_CLIENT_ID", "--body", $appClientId, "--repo", $GitHubRepo) "AZURE_CLIENT_ID の設定に失敗しました。"
            Invoke-GhCommand @("secret", "set", "AZURE_TENANT_ID", "--body", $tenantId, "--repo", $GitHubRepo) "AZURE_TENANT_ID の設定に失敗しました。"
            Invoke-GhCommand @("secret", "set", "AZURE_SUBSCRIPTION_ID", "--body", $subscriptionId, "--repo", $GitHubRepo) "AZURE_SUBSCRIPTION_ID の設定に失敗しました。"
            Invoke-GhCommand @("variable", "set", "RESOURCE_GROUP", "--body", $ResourceGroup, "--repo", $GitHubRepo) "RESOURCE_GROUP の設定に失敗しました。"
            Invoke-GhCommand @("variable", "set", "ACR_NAME", "--body", $demoAcrName, "--repo", $GitHubRepo) "ACR_NAME の設定に失敗しました。"
            Invoke-GhCommand @("variable", "set", "CONTAINER_APP_NAME", "--body", $demoAppName, "--repo", $GitHubRepo) "CONTAINER_APP_NAME の設定に失敗しました。"
            Write-Host "  OIDC 設定完了。対象は Demo ACR/App のみです。" -ForegroundColor Green
        }
    }
}

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
Write-Host "  参加者の次のステップ:" -ForegroundColor Yellow
Write-Host "    1. https://sre.azure.com/ を開く" -ForegroundColor White
Write-Host "    2. Agent RG '$SreAgentResourceGroup' に SRE Agent を作成する" -ForegroundColor White
Write-Host "    3. インフラ RG '$ResourceGroup' と上記監視リソースを対象に設定する" -ForegroundColor White
Write-Host ""
Write-Host "  削除: ./scripts/destroy.ps1 -ResourceGroup $ResourceGroup -SreAgentResourceGroup $SreAgentResourceGroup" -ForegroundColor DarkGray
