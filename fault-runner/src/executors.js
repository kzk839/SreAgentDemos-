'use strict';

const { ComputeManagementClient } = require('@azure/arm-compute');
const { NetworkManagementClient } = require('@azure/arm-network');
const sql = require('mssql');

const VM_SCRIPTS = Object.freeze({
  'vm-cpu-high': {
    task: 'SreFaultCpu',
    apply: String.raw`
$existing = Get-ScheduledTask -TaskName 'SreFaultCpu' -ErrorAction SilentlyContinue
if ($existing -and $existing.State -eq 'Running') { return }
$root = 'C:\SreFault'; New-Item -ItemType Directory -Path $root -Force | Out-Null
$path = Join-Path $root 'cpu.ps1'
@'
$workers = 1..([Environment]::ProcessorCount) | ForEach-Object { Start-Job { while ($true) { $value = [Math]::Sqrt((Get-Random)) } } }
Wait-Job $workers
'@ | Set-Content -Path $path -Encoding UTF8
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File $path"
Register-ScheduledTask -TaskName 'SreFaultCpu' -Action $action -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'SreFaultCpu'
`,
  },
  'vm-memory-high': {
    task: 'SreFaultMemory',
    apply: String.raw`
$existing = Get-ScheduledTask -TaskName 'SreFaultMemory' -ErrorAction SilentlyContinue
if ($existing -and $existing.State -eq 'Running') { return }
$root = 'C:\SreFault'; New-Item -ItemType Directory -Path $root -Force | Out-Null
$path = Join-Path $root 'memory.ps1'
@'
$chunks = New-Object System.Collections.Generic.List[byte[]]
while ($true) {
  $os = Get-CimInstance Win32_OperatingSystem
  if (($os.FreePhysicalMemory / $os.TotalVisibleMemorySize) -gt 0.25) {
    $chunk = New-Object byte[] (64MB)
    for ($index = 0; $index -lt $chunk.Length; $index += 4096) { $chunk[$index] = 1 }
    $chunks.Add($chunk)
  }
  Start-Sleep -Seconds 2
}
'@ | Set-Content -Path $path -Encoding UTF8
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File $path"
Register-ScheduledTask -TaskName 'SreFaultMemory' -Action $action -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'SreFaultMemory'
`,
  },
  'vm-disk-pressure': {
    task: 'SreFaultDisk',
    apply: String.raw`
$existing = Get-ScheduledTask -TaskName 'SreFaultDisk' -ErrorAction SilentlyContinue
if ($existing -and $existing.State -eq 'Running') { return }
$volume = Get-Volume -DriveLetter F -ErrorAction Stop
if ($volume.FileSystemLabel -ne 'SREFAULT') { throw 'F: is not the SREFAULT volume.' }
$root = 'F:\SreFault'; New-Item -ItemType Directory -Path $root -Force | Out-Null
$path = Join-Path $root 'disk.ps1'
@'
$file = 'F:\SreFault\disk-pressure.bin'; $chunk = New-Object byte[] (8MB)
$stream = [IO.File]::Open($file, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try {
  while ($true) {
    $volume = Get-Volume -DriveLetter F
    $minimumFree = [Math]::Max(256MB, [int64]($volume.Size * 0.08))
    if ($volume.SizeRemaining -le ($minimumFree + $chunk.Length)) { break }
    $stream.Write($chunk, 0, $chunk.Length); $stream.Flush()
  }
} finally { $stream.Dispose() }
'@ | Set-Content -Path $path -Encoding UTF8
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File $path"
Register-ScheduledTask -TaskName 'SreFaultDisk' -Action $action -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'SreFaultDisk'
`,
  },
});

function stopVmTaskScript(task, faultId) {
  const cleanup = faultId === 'vm-disk-pressure'
    ? "Remove-Item 'F:\\SreFault\\disk-pressure.bin' -Force -ErrorAction SilentlyContinue"
    : '';
  return `Stop-ScheduledTask -TaskName '${task}' -ErrorAction SilentlyContinue\nUnregister-ScheduledTask -TaskName '${task}' -Confirm:$false -ErrorAction SilentlyContinue\n${cleanup}`;
}

function createVmExecutor({ computeClient, resourceGroupName, vmName, faultId }) {
  const definition = VM_SCRIPTS[faultId];
  async function run(script) {
    return computeClient.virtualMachines.beginRunCommandAndWait(resourceGroupName, vmName, { commandId: 'RunPowerShellScript', script: [script] });
  }
  return {
    async apply() {
      await run(definition.apply);
      return { recoveryData: { scheduledTask: definition.task } };
    },
    async revert() {
      await run(stopVmTaskScript(definition.task, faultId));
      return {};
    },
    async verify() {
      const verificationScript = faultId === 'vm-disk-pressure'
        ? "$volume = Get-Volume -DriveLetter F -ErrorAction SilentlyContinue; $minimumFree = if ($volume) { [Math]::Max(256MB, [int64]($volume.Size * 0.08)) } else { 0 }; Write-Output ([bool]($volume -and $volume.FileSystemLabel -eq 'SREFAULT' -and (Test-Path 'F:\\SreFault\\disk-pressure.bin') -and $volume.SizeRemaining -le ($minimumFree + 8MB)))"
        : `$task = Get-ScheduledTask -TaskName '${definition.task}' -ErrorAction SilentlyContinue; Write-Output ([bool]($task -and $task.State -eq 'Running'))`;
      const result = await run(verificationScript);
      return (result.value || []).some(value => /\btrue\b/i.test(value.message || ''));
    },
  };
}

function createSqlExecutors(connectionString, sqlClient = sql) {
  let poolPromise;
  const pool = () => {
    poolPromise ||= sqlClient.connect(connectionString).catch(error => {
      poolPromise = null;
      throw error;
    });
    return poolPromise;
  };
  return {
    'sql-high-load': {
      repeatWhileActive: true,
      async apply() {
        const connection = await pool();
        await connection.request().query("WITH Work AS (SELECT 1 AS Value UNION ALL SELECT Value + 1 FROM Work WHERE Value < 100000) SELECT SUM(CONVERT(bigint, CHECKSUM(NEWID()))) AS WorkUnits FROM Work OPTION (MAXRECURSION 0)");
        return { recoveryData: { workload: 'fixed-recursive-query' } };
      },
      async revert() { return {}; },
    },
    'sql-deadlock': {
      repeatWhileActive: true,
      async apply() {
        const connection = await pool();
        const first = connection.request().batch("SET DEADLOCK_PRIORITY LOW; BEGIN TRAN; UPDATE dbo.SreFaultLocks SET Value += 1 WHERE Id = 1; WAITFOR DELAY '00:00:01'; UPDATE dbo.SreFaultLocks SET Value += 1 WHERE Id = 2; COMMIT;");
        const second = connection.request().batch("BEGIN TRAN; UPDATE dbo.SreFaultLocks SET Value += 1 WHERE Id = 2; WAITFOR DELAY '00:00:01'; UPDATE dbo.SreFaultLocks SET Value += 1 WHERE Id = 1; COMMIT;");
        const results = await Promise.allSettled([first, second]);
        const completed = results.some(result => result.status === 'fulfilled');
        const deadlockObserved = results.some(result => result.status === 'rejected' && (result.reason?.number === 1205 || result.reason?.originalError?.info?.number === 1205));
        if (!completed || !deadlockObserved) throw new Error('Controlled SQL deadlock was not observed');
        return { recoveryData: { workload: 'catalog-deadlock-pair' } };
      },
      async revert() { return {}; },
    },
  };
}

function createNetworkExecutor({ networkClient, resourceGroupName, firewallPolicyName, ruleCollectionGroupName }) {
  const inactive = { priority: 100, ruleCollections: [] };
  const active = {
    priority: 100,
    ruleCollections: [{
      name: 'DenySpoke2ToSpoke1',
      ruleCollectionType: 'FirewallPolicyFilterRuleCollection',
      priority: 100,
      action: { type: 'Deny' },
      rules: [{
        name: 'DenyCataloguedSpokeTraffic',
        ruleType: 'NetworkRule',
        sourceAddresses: ['10.3.0.0/16'],
        destinationAddresses: ['10.2.0.0/16'],
        destinationPorts: ['*'],
        ipProtocols: ['Any'],
      }],
    }],
  };
  return {
    async apply() {
      await networkClient.firewallPolicyRuleCollectionGroups.beginCreateOrUpdateAndWait(resourceGroupName, firewallPolicyName, ruleCollectionGroupName, active);
      return { recoveryData: { ruleCollectionGroupName } };
    },
    async revert() {
      await networkClient.firewallPolicyRuleCollectionGroups.beginCreateOrUpdateAndWait(resourceGroupName, firewallPolicyName, ruleCollectionGroupName, inactive);
      return {};
    },
    async verify() {
      const current = await networkClient.firewallPolicyRuleCollectionGroups.get(resourceGroupName, firewallPolicyName, ruleCollectionGroupName);
      if (current.priority !== active.priority || current.ruleCollections?.length !== 1) return false;
      const collection = current.ruleCollections[0];
      if (collection.name !== 'DenySpoke2ToSpoke1'
        || collection.ruleCollectionType !== 'FirewallPolicyFilterRuleCollection'
        || collection.priority !== 100
        || collection.action?.type !== 'Deny'
        || collection.rules?.length !== 1) return false;
      const rule = collection.rules[0];
      return rule.name === 'DenyCataloguedSpokeTraffic'
        && rule.ruleType === 'NetworkRule'
        && JSON.stringify(rule.sourceAddresses) === JSON.stringify(['10.3.0.0/16'])
        && JSON.stringify(rule.destinationAddresses) === JSON.stringify(['10.2.0.0/16'])
        && JSON.stringify(rule.destinationPorts) === JSON.stringify(['*'])
        && JSON.stringify(rule.ipProtocols) === JSON.stringify(['Any']);
    },
  };
}

function createExecutors(options) {
  const computeClient = options.computeClient || new ComputeManagementClient(options.credential, options.subscriptionId);
  const networkClient = options.networkClient || new NetworkManagementClient(options.credential, options.subscriptionId);
  const vmOptions = { computeClient, resourceGroupName: options.resourceGroupName, vmName: options.vmName };
  return {
    'vm-cpu-high': createVmExecutor({ ...vmOptions, faultId: 'vm-cpu-high' }),
    'vm-memory-high': createVmExecutor({ ...vmOptions, faultId: 'vm-memory-high' }),
    'vm-disk-pressure': createVmExecutor({ ...vmOptions, faultId: 'vm-disk-pressure' }),
    ...createSqlExecutors(options.sqlConnectionString),
    'network-deny': createNetworkExecutor({
      networkClient,
      resourceGroupName: options.resourceGroupName,
      firewallPolicyName: options.firewallPolicyName,
      ruleCollectionGroupName: options.ruleCollectionGroupName,
    }),
  };
}

module.exports = { VM_SCRIPTS, createExecutors, createNetworkExecutor, createSqlExecutors, createVmExecutor };
