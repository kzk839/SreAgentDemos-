$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\deploy-validation.ps1')

$cases = @(
    @{ Value = '1.1.1.1'; Expected = $true }
    @{ Value = '198.51.1.1'; Expected = $true }
    @{ Value = '10.0.0.1'; Expected = $false }
    @{ Value = '100.64.0.1'; Expected = $false }
    @{ Value = '192.0.2.1'; Expected = $false }
    @{ Value = '192.88.99.1'; Expected = $false }
    @{ Value = '198.51.100.1'; Expected = $false }
    @{ Value = '203.0.113.1'; Expected = $false }
    @{ Value = '1.1.1.1/32'; Expected = $false }
    @{ Value = '2001:4860:4860::8888'; Expected = $false }
    @{ Value = ''; Expected = $false }
)

foreach ($case in $cases) {
    $actual = Test-PublicIPv4Address $case.Value
    if ($actual -ne $case.Expected) {
        throw "Unexpected validation result for '$($case.Value)': expected $($case.Expected), got $actual."
    }
}

Write-Host 'Deploy validation tests passed.'
