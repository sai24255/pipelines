#Requires -Version 7.0
<#
.SYNOPSIS
    Completes an Azure VM OS Disk recovery operation after repair activities.

.DESCRIPTION
    This script completes the recovery process for an Azure VM OS Disk. It performs the following:
    - Loads and validates recovery metadata
    - Stops the repair VM and detaches the recovery disk
    - Creates snapshots of the repaired disk
    - Swaps the recovered OS disk with the original disk
    - Validates the source VM boot and functionality
    - Performs automatic rollback if validation fails
    - Cleans up repair VM resources

.PARAMETER SubscriptionId
    The Azure Subscription ID containing the recovery resources.

.PARAMETER ResourceGroupName
    The name of the resource group containing the source VM.

.PARAMETER VmName
    The name of the source VM being recovered.

.PARAMETER MetadataPath
    Optional path to the recovery metadata JSON file. If not provided, searches current directory.

.PARAMETER CorrelationId
    Optional correlation ID for tracking related operations. Uses ID from metadata if available.

.PARAMETER RetryCount
    Maximum number of retry attempts for operations. Default is 3.

.PARAMETER RetryDelaySeconds
    Delay in seconds between retry attempts. Default is 10.

.PARAMETER ValidationTimeoutSeconds
    Maximum time to wait for VM validation operations. Default is 600.

.PARAMETER SkipRollback
    If specified, skips automatic rollback on validation failure.

.EXAMPLE
    PS> .\complete-recovery.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" `
        -ResourceGroupName "rg-prod" -VmName "vm-prod-01" `
        -MetadataPath "./recovery-metadata-abc123.json"

.OUTPUTS
    System.String. Recovery completion status and summary.

.NOTES
    Author: Cloud Architecture Team
    Version: 1.0.0
    PowerShell: 7.0+
    Requires: Az.Compute, Az.Network, Az.Storage modules

.LINK
    https://docs.microsoft.com/en-us/azure/virtual-machines/repair-windows-vm-offline
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = "Azure Subscription ID")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', `
        ErrorMessage = 'SubscriptionId must be a valid GUID format')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true, HelpMessage = "Resource Group Name")]
    [ValidatePattern('^[a-zA-Z0-9._-]{1,90}$', `
        ErrorMessage = 'ResourceGroupName must be 1-90 characters')]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true, HelpMessage = "Source VM Name")]
    [ValidatePattern('^[a-zA-Z0-9._-]{1,80}$', `
        ErrorMessage = 'VmName must be 1-80 characters')]
    [string]$VmName,

    [Parameter(Mandatory = $false, HelpMessage = "Path to recovery metadata JSON file")]
    [string]$MetadataPath = $null,

    [Parameter(Mandatory = $false, HelpMessage = "Correlation ID for request tracking")]
    [string]$CorrelationId = [System.Guid]::NewGuid().ToString(),

    [Parameter(Mandatory = $false, HelpMessage = "Maximum retry attempts")]
    [ValidateRange(1, 10)]
    [int]$RetryCount = 3,

    [Parameter(Mandatory = $false, HelpMessage = "Delay between retries in seconds")]
    [ValidateRange(1, 60)]
    [int]$RetryDelaySeconds = 10,

    [Parameter(Mandatory = $false, HelpMessage = "VM validation timeout in seconds")]
    [ValidateRange(30, 1800)]
    [int]$ValidationTimeoutSeconds = 600,

    [Parameter(Mandatory = $false, HelpMessage = "Skip automatic rollback on validation failure")]
    [switch]$SkipRollback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# SCRIPT CONFIGURATION
# ============================================================================

$script:ExecutionStartTime = Get-Date -AsUTC
$script:ScriptVersion = '1.0.0'
$script:CorrelationId = $CorrelationId
$script:LogEntries = @()
$script:RecoveryMetadata = $null
$script:RollbackStateStack = @()
$script:ValidationState = @{
    PowerStateValid      = $false
    ProvisioningValid    = $false
    GuestAgentValid      = $false
    BootDiagnosticsValid = $false
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

<#
.SYNOPSIS
    Writes structured JSON log entries.
#>
function Write-LogEntry {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Information', 'Warning', 'Error', 'Debug', 'Verbose')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [object]$Data = $null,

        [Parameter(Mandatory = $false)]
        [string]$FunctionName = (Get-PSCallStack)[1].FunctionName
    )

    $logEntry = @{
        Timestamp       = (Get-Date -AsUTC -Format 'o')
        Level           = $Level
        CorrelationId   = $script:CorrelationId
        FunctionName    = $FunctionName
        Message         = $Message
        ScriptVersion   = $script:ScriptVersion
    }

    if ($Data) {
        $logEntry['Data'] = $Data
    }

    $logEntry | Add-Member -MemberType NoteProperty -Name 'ElapsedSeconds' -Value $((Get-Date -AsUTC) - $script:ExecutionStartTime).TotalSeconds

    $script:LogEntries += $logEntry

    $jsonLog = $logEntry | ConvertTo-Json -Compress

    switch ($Level) {
        'Error' { Write-Error $jsonLog }
        'Warning' { Write-Warning $jsonLog }
        'Debug' { Write-Debug $jsonLog }
        'Verbose' { Write-Verbose $jsonLog }
        'Information' { Write-Host $jsonLog }
    }
}

<#
.SYNOPSIS
    Executes a command with retry logic.
#>
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $true)]
        [string]$OperationName,

        [Parameter(Mandatory = $false)]
        [int]$Retries = $script:RetryCount,

        [Parameter(Mandatory = $false)]
        [int]$DelaySeconds = $script:RetryDelaySeconds
    )

    $attempt = 0

    while ($attempt -lt $Retries) {
        try {
            Write-LogEntry -Level 'Debug' -Message "Executing operation: $OperationName (Attempt $(($attempt + 1))/$Retries)"
            $result = & $ScriptBlock
            Write-LogEntry -Level 'Verbose' -Message "Operation succeeded: $OperationName"
            return $result
        }
        catch {
            $attempt++
            if ($attempt -ge $Retries) {
                Write-LogEntry -Level 'Error' -Message "Operation failed after $Retries attempts: $OperationName" -Data @{
                    Error = $_.Exception.Message
                }
                throw
            }

            Write-LogEntry -Level 'Warning' -Message "Operation failed, retrying in $DelaySeconds seconds: $OperationName" -Data @{
                Attempt = $attempt
                Error   = $_.Exception.Message
            }

            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

<#
.SYNOPSIS
    Waits for an Azure resource operation to complete.
#>
function Wait-ResourceOperation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OperationName,

        [Parameter(Mandatory = $true)]
        [scriptblock]$StatusCheck,

        [Parameter(Mandatory = $false)]
        [int]$MaxWaitSeconds = 600,

        [Parameter(Mandatory = $false)]
        [int]$CheckIntervalSeconds = 10
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($stopwatch.Elapsed.TotalSeconds -lt $MaxWaitSeconds) {
        $status = & $StatusCheck

        if ($status -eq $true) {
            Write-LogEntry -Level 'Verbose' -Message "Operation completed: $OperationName (Duration: $([Math]::Round($stopwatch.Elapsed.TotalSeconds))s)"
            return $true
        }

        Write-LogEntry -Level 'Debug' -Message "Waiting for operation: $OperationName (Elapsed: $([Math]::Round($stopwatch.Elapsed.TotalSeconds))s)"
        Start-Sleep -Seconds $CheckIntervalSeconds
    }

    Write-LogEntry -Level 'Error' -Message "Operation timeout: $OperationName (Timeout: $MaxWaitSeconds seconds)"
    return $false
}

<#
.SYNOPSIS
    Pushes rollback state for recovery tracking.
#>
function Push-RollbackState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDescription,

        [Parameter(Mandatory = $false)]
        [object]$StateData = $null
    )

    $rollbackEntry = @{
        Timestamp      = (Get-Date -AsUTC)
        Description    = $StateDescription
        CorrelationId  = $script:CorrelationId
        Data           = $StateData
    }

    $script:RollbackStateStack += $rollbackEntry

    Write-LogEntry -Level 'Debug' -Message "Rollback state pushed: $StateDescription" -Data @{
        StackDepth = $script:RollbackStateStack.Count
    }
}

# ============================================================================
# METADATA FUNCTIONS
# ============================================================================

<#
.SYNOPSIS
    Locates and loads recovery metadata from disk.
#>
function Find-RecoveryMetadata {
    Write-LogEntry -Level 'Information' -Message "Locating recovery metadata"

    $metadataFile = $null

    if ($MetadataPath -and (Test-Path $MetadataPath)) {
        $metadataFile = $MetadataPath
        Write-LogEntry -Level 'Information' -Message "Using provided metadata path: $MetadataPath"
    }
    else {
        # Search for metadata file in current directory
        $searchPattern = "recovery-metadata-*.json"
        $metadataFiles = Get-ChildItem -Filter $searchPattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending

        if ($metadataFiles) {
            $metadataFile = $metadataFiles[0].FullName
            Write-LogEntry -Level 'Information' -Message "Found metadata file: $metadataFile"
        }
        else {
            Write-LogEntry -Level 'Error' -Message "Recovery metadata file not found"
            throw "Recovery metadata file not found. Please provide -MetadataPath parameter"
        }
    }

    return $metadataFile
}

<#
.SYNOPSIS
    Loads and validates recovery metadata.
#>
function Load-RecoveryMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MetadataFilePath
    )

    Write-LogEntry -Level 'Information' -Message "Loading recovery metadata from: $MetadataFilePath"

    $metadata = Invoke-WithRetry -ScriptBlock {
        $content = Get-Content -Path $MetadataFilePath -Raw -ErrorAction Stop
        $json = $content | ConvertFrom-Json -ErrorAction Stop
        return $json
    } -OperationName "Load metadata file"

    Write-LogEntry -Level 'Information' -Message "Recovery metadata loaded successfully" -Data @{
        SessionId       = $metadata.RecoverySessionId
        SourceVmName    = $metadata.SourceVm.Name
        SourceVmOsType  = $metadata.SourceVm.OsType
    }

    return $metadata
}

<#
.SYNOPSIS
    Validates the integrity of recovery metadata.
#>
function Test-RecoveryMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata
    )

    Write-LogEntry -Level 'Information' -Message "Validating recovery metadata integrity"

    # Check required fields
    $requiredFields = @(
        'RecoverySessionId',
        'SourceVm',
        'SourceOsDisk',
        'OsDiskSnapshot',
        'RecoveryDisk',
        'RepairVm'
    )

    foreach ($field in $requiredFields) {
        if (-not $Metadata.$field) {
            Write-LogEntry -Level 'Error' -Message "Missing required metadata field: $field"
            throw "Metadata validation failed: Missing field $field"
        }
    }

    # Validate metadata hash if present
    if ($Metadata.MetadataHash) {
        # Create a copy without the hash for verification
        $metadataForHash = $Metadata | ConvertTo-Json -Depth 10
        $metadataForHash = $metadataForHash -replace '"MetadataHash":\s*"[^"]*"', ''
        
        $calculatedHash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($metadataForHash))) -Algorithm SHA256).Hash
        
        if ($calculatedHash -ne $Metadata.MetadataHash) {
            Write-LogEntry -Level 'Warning' -Message "Metadata hash mismatch (file may have been modified)"
        }
    }

    Write-LogEntry -Level 'Information' -Message "Metadata validation successful"
    return $true
}

# ============================================================================
# AZURE OPERATIONS FUNCTIONS
# ============================================================================

<#
.SYNOPSIS
    Selects the Azure subscription.
#>
function Select-TargetSubscription {
    Write-LogEntry -Level 'Information' -Message "Selecting Azure subscription: $SubscriptionId"

    $context = Invoke-WithRetry -ScriptBlock {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    } -OperationName "Select subscription"

    Write-LogEntry -Level 'Information' -Message "Subscription selected successfully" -Data @{
        SubscriptionId   = $SubscriptionId
        SubscriptionName = $context.Subscription.Name
    }

    return $context
}

<#
.SYNOPSIS
    Retrieves source VM for recovery.
#>
function Get-SourceVmForRecovery {
    Write-LogEntry -Level 'Information' -Message "Retrieving source VM: $VmName"

    $vm = Invoke-WithRetry -ScriptBlock {
        Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction Stop
    } -OperationName "Get source VM"

    if (-not $vm) {
        Write-LogEntry -Level 'Error' -Message "Source VM not found: $VmName"
        throw "Source VM not found: $VmName"
    }

    Write-LogEntry -Level 'Information' -Message "Source VM retrieved" -Data @{
        VmId  = $vm.Id
        State = $vm.ProvisioningState
    }

    return $vm
}

<#
.SYNOPSIS
    Retrieves repair VM.
#>
function Get-RepairVm {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata
    )

    Write-LogEntry -Level 'Information' -Message "Retrieving repair VM: $($Metadata.RepairVm.Name)"

    $vm = Invoke-WithRetry -ScriptBlock {
        Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Metadata.RepairVm.Name -ErrorAction Stop
    } -OperationName "Get repair VM"

    if (-not $vm) {
        Write-LogEntry -Level 'Error' -Message "Repair VM not found: $($Metadata.RepairVm.Name)"
        throw "Repair VM not found"
    }

    Write-LogEntry -Level 'Information' -Message "Repair VM retrieved" -Data @{
        VmId  = $vm.Id
        Name  = $vm.Name
    }

    return $vm
}

<#
.SYNOPSIS
    Stops the repair VM.
#>
function Stop-RepairVm {
    param(
        [Parameter(Mandatory = $true)]
        [object]$RepairVm
    )

    Write-LogEntry -Level 'Information' -Message "Stopping repair VM: $($RepairVm.Name)"

    Invoke-WithRetry -ScriptBlock {
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $RepairVm.Name -Force -NoWait -ErrorAction Stop
    } -OperationName "Stop repair VM"

    # Wait for VM to stop
    $isStopped = Wait-ResourceOperation -OperationName "Repair VM stop" -StatusCheck {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $RepairVm.Name -Status
        return $vm.Statuses | Where-Object { $_.Code -match 'PowerState/stopped' }
    } -MaxWaitSeconds 300

    if (-not $isStopped) {
        Write-LogEntry -Level 'Warning' -Message "Repair VM stop may not be complete, proceeding anyway"
    }

    Write-LogEntry -Level 'Information' -Message "Repair VM stopped"
    Push-RollbackState -StateDescription "Repair VM stopped"
}

<#
.SYNOPSIS
    Detaches recovery disk from repair VM.
#>
function Detach-RecoveryDiskFromRepairVm {
    param(
        [Parameter(Mandatory = $true)]
        [object]$RepairVm,

        [Parameter(Mandatory = $true)]
        [object]$Metadata
    )

    Write-LogEntry -Level 'Information' -Message "Detaching recovery disk from repair VM"

    $vm = Invoke-WithRetry -ScriptBlock {
        Get-AzVM -ResourceGroupName $ResourceGroupName -Name $RepairVm.Name -ErrorAction Stop
    } -OperationName "Get repair VM for detach"

    $recoveryDiskName = $Metadata.RecoveryDisk.Name
    $dataDisks = $vm.StorageProfile.DataDisks | Where-Object { $_.Name -eq $recoveryDiskName }

    if ($dataDisks) {
        $vm = Remove-AzVMDataDisk -VM $vm -DataDiskNames $recoveryDiskName

        $vm = Invoke-WithRetry -ScriptBlock {
            Update-AzVM -VM $vm -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        } -OperationName "Update VM to detach disk"

        Write-LogEntry -Level 'Information' -Message "Recovery disk detached successfully" -Data @{
            DiskName = $recoveryDiskName
        }
    }
    else {
        Write-LogEntry -Level 'Warning' -Message "Recovery disk not found on repair VM, may already be detached"
    }

    Push-RollbackState -StateDescription "Recovery disk detached from repair VM"
}

<#
.SYNOPSIS
    Creates a final snapshot of the recovery disk.
#>
function New-FinalRecoverySnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata
    )

    Write-LogEntry -Level 'Information' -Message "Creating final snapshot of recovery disk"

    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $snapshotName = "snapshot-final-$timestamp"

    $recoveryDisk = Invoke-WithRetry -ScriptBlock {
        Get-AzDisk -ResourceId $Metadata.RecoveryDisk.Id -ErrorAction Stop
    } -OperationName "Get recovery disk"

    $snapshotConfig = New-AzSnapshotConfig -SourceUri $recoveryDisk.Id -Location $Metadata.RepairVm.Location -CreateOption Copy
    $snapshotConfig.Tags = @{
        'SourceDisk'    = $Metadata.RecoveryDisk.Name
        'CorrelationId' = $script:CorrelationId
        'CreatedBy'     = 'complete-recovery-script'
        'CreatedDate'   = (Get-Date -AsUTC -Format 'o')
    }

    $snapshot = Invoke-WithRetry -ScriptBlock {
        New-AzSnapshot -ResourceGroupName $ResourceGroupName -Snapshot $snapshotConfig -SnapshotName $snapshotName -ErrorAction Stop
    } -OperationName "Create final recovery snapshot"

    Write-LogEntry -Level 'Information' -Message "Final snapshot created" -Data @{
        SnapshotId   = $snapshot.Id
        SnapshotName = $snapshot.Name
    }

    Push-RollbackState -StateDescription "Final recovery snapshot created" -StateData @{
        SnapshotId = $snapshot.Id
        SnapshotName = $snapshotName
    }

    return $snapshot
}

<#
.SYNOPSIS
    Creates a recovered OS disk from the recovery disk.
#>
function New-RecoveredOsDisk {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata,

        [Parameter(Mandatory = $true)]
        [object]$FinalSnapshot
    )

    Write-LogEntry -Level 'Information' -Message "Creating recovered OS disk from snapshot"

    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $recoveredDiskName = "disk-recovered-$timestamp"

    # Preserve original disk properties
    $originalDiskSku = $Metadata.SourceOsDisk.SkuName
    $location = $Metadata.SourceVm.Location

    $diskConfig = New-AzDiskConfig -Location $location -CreateOption Copy -SourceResourceId $FinalSnapshot.Id `
        -SkuName $originalDiskSku

    $diskConfig.Tags = @{
        'SourceVm'             = $Metadata.SourceVm.Name
        'SourceOsDisk'         = $Metadata.SourceOsDisk.Name
        'CorrelationId'        = $script:CorrelationId
        'CreatedBy'            = 'complete-recovery-script'
        'CreatedDate'          = (Get-Date -AsUTC -Format 'o')
        'RecoverySessionId'    = $Metadata.RecoverySessionId
    }

    # Preserve disk encryption set if present
    if ($Metadata.SourceOsDisk.DiskEncryptionSet) {
        $diskConfig.Encryption = @{
            Type                = 'EncryptionAtRestWithCustomerKey'
            DiskEncryptionSetId = $Metadata.SourceOsDisk.DiskEncryptionSet
        }
    }

    # Set zones if present
    if ($Metadata.SourceVm.Zones) {
        $diskConfig.Zones = $Metadata.SourceVm.Zones
    }

    $recoveredDisk = Invoke-WithRetry -ScriptBlock {
        New-AzDisk -ResourceGroupName $ResourceGroupName -Disk $diskConfig -DiskName $recoveredDiskName -ErrorAction Stop
    } -OperationName "Create recovered OS disk"

    Write-LogEntry -Level 'Information' -Message "Recovered OS disk created" -Data @{
        DiskId       = $recoveredDisk.Id
        DiskName     = $recoveredDisk.Name
        SkuName      = $recoveredDisk.Sku.Name
    }

    Push-RollbackState -StateDescription "Recovered OS disk created" -StateData @{
        DiskId      = $recoveredDisk.Id
        DiskName    = $recoveredDiskName
    }

    return $recoveredDisk
}

<#
.SYNOPSIS
    Creates a rollback snapshot of the original OS disk.
#>
function New-RollbackSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata
    )

    Write-LogEntry -Level 'Information' -Message "Creating rollback snapshot of original OS disk"

    $originalOsDisk = Invoke-WithRetry -ScriptBlock {
        Get-AzDisk -ResourceId $Metadata.SourceOsDisk.Id -ErrorAction Stop
    } -OperationName "Get original OS disk"

    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $rollbackSnapshotName = "snapshot-rollback-$timestamp"

    $snapshotConfig = New-AzSnapshotConfig -SourceUri $originalOsDisk.Id -Location $Metadata.SourceVm.Location -CreateOption Copy
    $snapshotConfig.Tags = @{
        'SourceDisk'    = $Metadata.SourceOsDisk.Name
        'Purpose'       = 'Rollback'
        'CorrelationId' = $script:CorrelationId
        'CreatedBy'     = 'complete-recovery-script'
        'CreatedDate'   = (Get-Date -AsUTC -Format 'o')
    }

    $rollbackSnapshot = Invoke-WithRetry -ScriptBlock {
        New-AzSnapshot -ResourceGroupName $ResourceGroupName -Snapshot $snapshotConfig -SnapshotName $rollbackSnapshotName -ErrorAction Stop
    } -OperationName "Create rollback snapshot"

    Write-LogEntry -Level 'Information' -Message "Rollback snapshot created" -Data @{
        SnapshotId   = $rollbackSnapshot.Id
        SnapshotName = $rollbackSnapshotName
    }

    Push-RollbackState -StateDescription "Rollback snapshot created" -StateData @{
        SnapshotId = $rollbackSnapshot.Id
        SnapshotName = $rollbackSnapshotName
    }

    return $rollbackSnapshot
}

<#
.SYNOPSIS
    Stops the source VM.
#>
function Stop-SourceVmForSwap {
    Write-LogEntry -Level 'Information' -Message "Stopping source VM for disk swap: $VmName"

    Invoke-WithRetry -ScriptBlock {
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Force -NoWait -ErrorAction Stop
    } -OperationName "Stop source VM"

    $isStopped = Wait-ResourceOperation -OperationName "Source VM stop" -StatusCheck {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status
        return $vm.Statuses | Where-Object { $_.Code -match 'PowerState/deallocated' }
    } -MaxWaitSeconds 300

    if (-not $isStopped) {
        Write-LogEntry -Level 'Warning' -Message "Source VM deallocation may not be complete, proceeding anyway"
    }

    Write-LogEntry -Level 'Information' -Message "Source VM stopped"
    Push-RollbackState -StateDescription "Source VM stopped for disk swap"
}

<#
.SYNOPSIS
    Swaps the OS disk on the source VM.
#>
function Invoke-OsDiskSwap {
    param(
        [Parameter(Mandatory = $true)]
        [object]$RecoveredDisk,

        [Parameter(Mandatory = $true)]
        [object]$SourceVm,

        [Parameter(Mandatory = $true)]
        [object]$Metadata
    )

    Write-LogEntry -Level 'Information' -Message "Swapping OS disk on source VM"

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName

    # Store original disk ID for potential rollback
    $originalOsDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id
    
    Push-RollbackState -StateDescription "Original OS disk stored for rollback" -StateData @{
        OriginalDiskId = $originalOsDiskId
    }

    # Swap the OS disk
    $vm.StorageProfile.OsDisk.ManagedDisk.Id = $RecoveredDisk.Id

    $vm = Invoke-WithRetry -ScriptBlock {
        Update-AzVM -VM $vm -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    } -OperationName "Swap OS disk"

    Write-LogEntry -Level 'Information' -Message "OS disk swapped successfully" -Data @{
        OriginalDiskId = $originalOsDiskId
        NewDiskId      = $RecoveredDisk.Id
        VmName         = $VmName
    }

    Push-RollbackState -StateDescription "OS disk swapped" -StateData @{
        OriginalDiskId = $originalOsDiskId
        NewDiskId      = $RecoveredDisk.Id
    }

    return $vm
}

<#
.SYNOPSIS
    Starts the source VM.
#>
function Start-RecoveredSourceVm {
    Write-LogEntry -Level 'Information' -Message "Starting recovered source VM: $VmName"

    Invoke-WithRetry -ScriptBlock {
        Start-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -NoWait -ErrorAction Stop
    } -OperationName "Start source VM"

    Write-LogEntry -Level 'Information' -Message "Source VM start command issued"
    Push-RollbackState -StateDescription "Source VM started"
}

<#
.SYNOPSIS
    Validates VM power state.
#>
function Test-VmPowerState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedState
    )

    Write-LogEntry -Level 'Information' -Message "Validating VM power state: $VmName"

    $isValid = Wait-ResourceOperation -OperationName "VM power state validation" -StatusCheck {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status
        $powerState = $vm.Statuses | Where-Object { $_.Code -match 'PowerState' }
        return $powerState.Code -match $ExpectedState
    } -MaxWaitSeconds $ValidationTimeoutSeconds

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status
    $powerState = ($vm.Statuses | Where-Object { $_.Code -match 'PowerState' }).Code

    Write-LogEntry -Level 'Information' -Message "Power state validation: $powerState" -Data @{
        Valid         = $isValid
        CurrentState  = $powerState
        ExpectedState = $ExpectedState
    }

    $script:ValidationState.PowerStateValid = $isValid
    return $isValid
}

<#
.SYNOPSIS
    Validates VM provisioning state.
#>
function Test-VmProvisioningState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    Write-LogEntry -Level 'Information' -Message "Validating VM provisioning state: $VmName"

    $vm = Invoke-WithRetry -ScriptBlock {
        Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction Stop
    } -OperationName "Get VM for provisioning validation"

    $isValid = $vm.ProvisioningState -eq 'Succeeded'

    Write-LogEntry -Level 'Information' -Message "Provisioning state validation: $($vm.ProvisioningState)" -Data @{
        Valid                = $isValid
        ProvisioningState    = $vm.ProvisioningState
    }

    $script:ValidationState.ProvisioningValid = $isValid
    return $isValid
}

<#
.SYNOPSIS
    Validates VM guest agent status.
#>
function Test-VmGuestAgentStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    Write-LogEntry -Level 'Information' -Message "Validating VM guest agent status: $VmName"

    $vm = Invoke-WithRetry -ScriptBlock {
        Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status -ErrorAction Stop
    } -OperationName "Get VM status for agent validation"

    $guestStatus = $vm.VMStatus.Where{ $_.Code -like 'GuestAgentStatus/*' }

    $isValid = $false
    if ($guestStatus) {
        $isValid = $guestStatus.DisplayStatus -like '*running*' -or $guestStatus.Code -match 'GuestAgentStatus/Succeeded'
    }

    Write-LogEntry -Level 'Information' -Message "Guest agent status validation" -Data @{
        Valid            = $isValid
        GuestAgentStatus = $guestStatus.DisplayStatus
        Code             = $guestStatus.Code
    }

    $script:ValidationState.GuestAgentValid = $isValid
    return $isValid
}

<#
.SYNOPSIS
    Validates boot diagnostics.
#>
function Test-VmBootDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    Write-LogEntry -Level 'Information' -Message "Validating VM boot diagnostics: $VmName"

    $vm = Invoke-WithRetry -ScriptBlock {
        Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction Stop
    } -OperationName "Get VM for boot diagnostics validation"

    $bootDiagEnabled = $vm.DiagnosticsProfile.BootDiagnostics.Enabled

    Write-LogEntry -Level 'Information' -Message "Boot diagnostics validation" -Data @{
        Enabled = $bootDiagEnabled
    }

    $script:ValidationState.BootDiagnosticsValid = $bootDiagEnabled
    return $bootDiagEnabled
}

<#
.SYNOPSIS
    Validates recovered VM functionality.
#>
function Invoke-ComprehensiveVmValidation {
    Write-LogEntry -Level 'Information' -Message "Starting comprehensive VM validation: $VmName"

    # Wait for VM to fully start
    $isPoweredOn = Test-VmPowerState -VmName $VmName -ExpectedState 'running'

    # Validate provisioning
    $provisioningValid = Test-VmProvisioningState -VmName $VmName

    # Validate guest agent
    $guestAgentValid = Test-VmGuestAgentStatus -VmName $VmName

    # Validate boot diagnostics
    $bootDiagValid = Test-VmBootDiagnostics -VmName $VmName

    $allValid = $isPoweredOn -and $provisioningValid

    Write-LogEntry -Level 'Information' -Message "Validation summary" -Data @{
        PowerStateValid      = $isPoweredOn
        ProvisioningValid    = $provisioningValid
        GuestAgentValid      = $guestAgentValid
        BootDiagnosticsValid = $bootDiagValid
        OverallValid         = $allValid
    }

    return $allValid
}

<#
.SYNOPSIS
    Performs automatic rollback on validation failure.
#>
function Invoke-AutomaticRollback {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata,

        [Parameter(Mandatory = $true)]
        [string]$RollbackReason
    )

    Write-LogEntry -Level 'Error' -Message "Initiating automatic rollback: $RollbackReason"

    try {
        # Stop the source VM if running
        Write-LogEntry -Level 'Information' -Message "Stopping source VM for rollback"
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Force -NoWait -ErrorAction SilentlyContinue

        Wait-ResourceOperation -OperationName "Source VM stop for rollback" -StatusCheck {
            $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status -ErrorAction SilentlyContinue
            return $vm.Statuses | Where-Object { $_.Code -match 'PowerState/deallocated' }
        } -MaxWaitSeconds 300 | Out-Null

        # Get the last rollback state (original disk ID)
        $originalDiskState = $script:RollbackStateStack | Where-Object { $_.Description -match 'Original OS disk stored' } | Select-Object -Last 1

        if ($originalDiskState -and $originalDiskState.Data.OriginalDiskId) {
            Write-LogEntry -Level 'Information' -Message "Restoring original OS disk"

            $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName
            $vm.StorageProfile.OsDisk.ManagedDisk.Id = $originalDiskState.Data.OriginalDiskId

            Update-AzVM -VM $vm -ResourceGroupName $ResourceGroupName -ErrorAction Stop

            Write-LogEntry -Level 'Information' -Message "Original OS disk restored"
        }

        # Start the source VM
        Write-LogEntry -Level 'Information' -Message "Starting source VM after rollback"
        Start-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -NoWait -ErrorAction SilentlyContinue

        Write-LogEntry -Level 'Information' -Message "Rollback completed successfully"
        return $true
    }
    catch {
        Write-LogEntry -Level 'Error' -Message "Rollback failed" -Data @{
            Error = $_.Exception.Message
        }
        throw "Automatic rollback failed: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Retrieves resource by ID for deletion.
#>
function Get-AzureResourceById {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceType
    )

    try {
        switch ($ResourceType) {
            'VM' {
                $parts = $ResourceId -split '/'
                $vmName = $parts[-1]
                $rgName = $parts[4]
                return Get-AzVM -ResourceGroupName $rgName -Name $vmName -ErrorAction SilentlyContinue
            }
            'NIC' {
                return Get-AzNetworkInterface -ResourceId $ResourceId -ErrorAction SilentlyContinue
            }
            'PublicIP' {
                return Get-AzPublicIpAddress -ResourceId $ResourceId -ErrorAction SilentlyContinue
            }
            'Disk' {
                return Get-AzDisk -ResourceId $ResourceId -ErrorAction SilentlyContinue
            }
            'NSG' {
                return Get-AzNetworkSecurityGroup -ResourceId $ResourceId -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-LogEntry -Level 'Warning' -Message "Failed to retrieve resource: $ResourceId" -Data @{
            Error = $_.Exception.Message
        }
        return $null
    }
}

<#
.SYNOPSIS
    Deletes the repair VM.
#>
function Remove-RepairVm {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata
    )

    Write-LogEntry -Level 'Information' -Message "Deleting repair VM: $($Metadata.RepairVm.Name)"

    Invoke-WithRetry -ScriptBlock {
        Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $Metadata.RepairVm.Name -Force -ErrorAction Stop
    } -OperationName "Delete repair VM"

    Write-LogEntry -Level 'Information' -Message "Repair VM deleted"
    Push-RollbackState -StateDescription "Repair VM deleted"
}

<#
.SYNOPSIS
    Deletes the network interface.
#>
function Remove-RepairVmNetworkInterface {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata
    )

    Write-LogEntry -Level 'Information' -Message "Deleting network interface"

    # Get NIC from metadata
    if ($Metadata.RepairVm.NetworkProfile -and $Metadata.RepairVm.NetworkProfile.NetworkInterfaces) {
        $nicId = $Metadata.RepairVm.NetworkProfile.NetworkInterfaces[0].Id

        $nic = Get-AzureResourceById -ResourceId $nicId -ResourceType 'NIC'

        if ($nic) {
            Invoke-WithRetry -ScriptBlock {
                Remove-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $nic.Name -Force -ErrorAction Stop
            } -OperationName "Delete NIC"

            Write-LogEntry -Level 'Information' -Message "Network interface deleted"
        }
    }

    Push-RollbackState -StateDescription "Network interface deleted"
}

<#
.SYNOPSIS
    Deletes the public IP.
#>
function Remove-RepairVmPublicIp {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata
    )

    Write-LogEntry -Level 'Information' -Message "Deleting public IP"

    # Search for public IP by name pattern
    $publicIpPattern = "pip-repair-*"
    $publicIps = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue | `
        Where-Object { $_.Name -like $publicIpPattern }

    foreach ($publicIp in $publicIps) {
        Invoke-WithRetry -ScriptBlock {
            Remove-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $publicIp.Name -Force -ErrorAction Stop
        } -OperationName "Delete public IP: $($publicIp.Name)"

        Write-LogEntry -Level 'Information' -Message "Public IP deleted: $($publicIp.Name)"
    }

    Push-RollbackState -StateDescription "Public IP deleted"
}

<#
.SYNOPSIS
    Deletes the recovery managed disk.
#>
function Remove-RecoveryManagedDisk {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata
    )

    Write-LogEntry -Level 'Information' -Message "Deleting recovery managed disk: $($Metadata.RecoveryDisk.Name)"

    Invoke-WithRetry -ScriptBlock {
        Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $Metadata.RecoveryDisk.Name -Force -ErrorAction Stop
    } -OperationName "Delete recovery disk"

    Write-LogEntry -Level 'Information' -Message "Recovery managed disk deleted"
    Push-RollbackState -StateDescription "Recovery disk deleted"
}

<#
.SYNOPSIS
    Deletes the snapshot.
#>
function Remove-Snapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SnapshotName
    )

    Write-LogEntry -Level 'Information' -Message "Deleting snapshot: $SnapshotName"

    Invoke-WithRetry -ScriptBlock {
        Remove-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $SnapshotName -Force -ErrorAction Stop
    } -OperationName "Delete snapshot: $SnapshotName"

    Write-LogEntry -Level 'Information' -Message "Snapshot deleted: $SnapshotName"
}

<#
.SYNOPSIS
    Deletes the NSG.
#>
function Remove-RepairVmNetworkSecurityGroup {
    Write-LogEntry -Level 'Information' -Message "Deleting network security group"

    # Search for NSG by name pattern
    $nsgPattern = "nsg-repair-*"
    $nsgs = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue | `
        Where-Object { $_.Name -like $nsgPattern }

    foreach ($nsg in $nsgs) {
        Invoke-WithRetry -ScriptBlock {
            Remove-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $nsg.Name -Force -ErrorAction Stop
        } -OperationName "Delete NSG: $($nsg.Name)"

        Write-LogEntry -Level 'Information' -Message "NSG deleted: $($nsg.Name)"
    }

    Push-RollbackState -StateDescription "NSG deleted"
}

# ============================================================================
# CLEANUP AND OUTPUT FUNCTIONS
# ============================================================================

<#
.SYNOPSIS
    Updates recovery completion state.
#>
function Update-RecoveryCompletionState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [object]$Details = $null
    )

    Write-LogEntry -Level 'Information' -Message "Updating recovery completion state: $Status" -Data $Details

    $completionState = @{
        RecoverySessionId      = $Metadata.RecoverySessionId
        CorrelationId          = $script:CorrelationId
        Status                 = $Status
        SourceVmName           = $VmName
        CompletionTime         = (Get-Date -AsUTC).ToString('o')
        ValidationState        = $script:ValidationState
        LogEntryCount          = $script:LogEntries.Count
        RollbackStateCount     = $script:RollbackStateStack.Count
    }

    if ($Details) {
        $completionState['Details'] = $Details
    }

    return $completionState
}

<#
.SYNOPSIS
    Outputs recovery completion summary.
#>
function Output-RecoveryCompletionSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [object]$Details = $null
    )

    $duration = [Math]::Round(((Get-Date -AsUTC) - $script:ExecutionStartTime).TotalSeconds)

    Write-Host "═══════════════════════════════════════════════════════════════════"
    Write-Host "RECOVERY COMPLETION SUMMARY" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════════"
    Write-Host ""
    Write-Host "Status:                 $Status" -ForegroundColor $(if ($Status -eq 'SUCCESS') { 'Green' } else { 'Red' })
    Write-Host "Source VM:              $VmName"
    Write-Host "Correlation ID:         $($script:CorrelationId)"
    Write-Host "Recovery Session ID:    $($Metadata.RecoverySessionId)"
    Write-Host "Duration:               $duration seconds"
    Write-Host ""
    Write-Host "Validation Results:" -ForegroundColor Cyan
    Write-Host "  Power State:          $($script:ValidationState.PowerStateValid)"
    Write-Host "  Provisioning State:   $($script:ValidationState.ProvisioningValid)"
    Write-Host "  Guest Agent:          $($script:ValidationState.GuestAgentValid)"
    Write-Host "  Boot Diagnostics:     $($script:ValidationState.BootDiagnosticsValid)"
    Write-Host ""
    
    if ($Details) {
        Write-Host "Details:" -ForegroundColor Cyan
        $Details | ConvertTo-Json | Write-Host
        Write-Host ""
    }

    Write-Host "Logging:" -ForegroundColor Cyan
    Write-Host "  Total Log Entries:    $($script:LogEntries.Count)"
    Write-Host "  Rollback States:      $($script:RollbackStateStack.Count)"
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════"
    Write-Host ""

    Write-LogEntry -Level 'Information' -Message "Recovery completion summary output" -Data @{
        Status   = $Status
        Duration = "$duration seconds"
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

try {
    Write-LogEntry -Level 'Information' -Message "Starting Azure VM Recovery Completion" -Data @{
        CorrelationId     = $script:CorrelationId
        SubscriptionId    = $SubscriptionId
        ResourceGroupName = $ResourceGroupName
        VmName            = $VmName
        ScriptVersion     = $script:ScriptVersion
    }

    # 1. Select subscription
    Select-TargetSubscription

    # 2. Find and load metadata
    $metadataFile = Find-RecoveryMetadata
    $script:RecoveryMetadata = Load-RecoveryMetadata -MetadataFilePath $metadataFile

    # Update correlation ID if available in metadata
    if ($script:RecoveryMetadata.RecoverySessionId) {
        $script:CorrelationId = $script:RecoveryMetadata.RecoverySessionId
    }

    # 3. Validate metadata
    Test-RecoveryMetadata -Metadata $script:RecoveryMetadata

    # 4. Get repair VM
    $repairVm = Get-RepairVm -Metadata $script:RecoveryMetadata

    # 5. Stop repair VM
    Stop-RepairVm -RepairVm $repairVm

    # 6. Detach recovery disk
    Detach-RecoveryDiskFromRepairVm -RepairVm $repairVm -Metadata $script:RecoveryMetadata

    # 7. Create final snapshot
    $finalSnapshot = New-FinalRecoverySnapshot -Metadata $script:RecoveryMetadata

    # 8. Create recovered OS disk
    $recoveredDisk = New-RecoveredOsDisk -Metadata $script:RecoveryMetadata -FinalSnapshot $finalSnapshot

    # 9. Create rollback snapshot
    $rollbackSnapshot = New-RollbackSnapshot -Metadata $script:RecoveryMetadata

    # 10. Stop source VM
    Stop-SourceVmForSwap

    # 11. Swap OS disk
    $sourceVm = Get-SourceVmForRecovery
    Invoke-OsDiskSwap -RecoveredDisk $recoveredDisk -SourceVm $sourceVm -Metadata $script:RecoveryMetadata

    # 12. Start source VM
    Start-RecoveredSourceVm

    # 13. Perform comprehensive validation
    $validationPassed = Invoke-ComprehensiveVmValidation

    # 14. Handle validation results
    if (-not $validationPassed) {
        if (-not $SkipRollback) {
            Write-LogEntry -Level 'Error' -Message "Validation failed, initiating automatic rollback"
            Invoke-AutomaticRollback -Metadata $script:RecoveryMetadata -RollbackReason "Validation failed"
            
            $completionState = Update-RecoveryCompletionState -Metadata $script:RecoveryMetadata -Status "ROLLED_BACK" -Details @{
                Reason = "Validation failed - automatic rollback performed"
            }
            
            Output-RecoveryCompletionSummary -Metadata $script:RecoveryMetadata -Status "ROLLED_BACK" -Details $completionState

            Write-LogEntry -Level 'Error' -Message "Recovery rolled back due to validation failure"
            exit 1
        }
        else {
            Write-LogEntry -Level 'Warning' -Message "Validation failed but rollback skipped per user request"
        }
    }

    # 15. Delete repair VM
    Remove-RepairVm -Metadata $script:RecoveryMetadata

    # 16. Delete NIC
    Remove-RepairVmNetworkInterface -Metadata $script:RecoveryMetadata

    # 17. Delete NSG
    Remove-RepairVmNetworkSecurityGroup

    # 18. Delete Public IP
    Remove-RepairVmPublicIp -Metadata $script:RecoveryMetadata

    # 19. Delete recovery disk
    Remove-RecoveryManagedDisk -Metadata $script:RecoveryMetadata

    # 20. Delete OS disk snapshot
    Remove-Snapshot -SnapshotName $script:RecoveryMetadata.OsDiskSnapshot.Name

    # 21. Update completion state
    $completionState = Update-RecoveryCompletionState -Metadata $script:RecoveryMetadata -Status "SUCCESS" -Details @{
        RecoveredDiskId   = $recoveredDisk.Id
        RecoveredDiskName = $recoveredDisk.Name
        ValidationPassed  = $validationPassed
    }

    # 22. Output summary
    Output-RecoveryCompletionSummary -Metadata $script:RecoveryMetadata -Status "SUCCESS" -Details $completionState

    Write-LogEntry -Level 'Information' -Message "Azure VM recovery completion successful" -Data @{
        Duration          = $([Math]::Round(((Get-Date -AsUTC) - $script:ExecutionStartTime).TotalSeconds))
        SourceVmName      = $VmName
        ValidationPassed  = $validationPassed
    }

    return "Recovery completed successfully"
}
catch {
    $errorDetails = @{
        ErrorMessage  = $_.Exception.Message
        ErrorType     = $_.Exception.GetType().FullName
        StackTrace    = $_.ScriptStackTrace
        LineNumber    = $_.InvocationInfo.ScriptLineNumber
    }

    Write-LogEntry -Level 'Error' -Message "Azure VM recovery completion failed" -Data $errorDetails

    Write-Host "ERROR: Azure VM recovery completion failed" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Correlation ID: $($script:CorrelationId)" -ForegroundColor Red

    # Attempt to output partial completion state if metadata is available
    if ($script:RecoveryMetadata) {
        $failureState = Update-RecoveryCompletionState -Metadata $script:RecoveryMetadata -Status "FAILED" -Details @{
            Error = $_.Exception.Message
        }
        Output-RecoveryCompletionSummary -Metadata $script:RecoveryMetadata -Status "FAILED" -Details $failureState
    }

    exit 1
}
finally {
    $totalDuration = [Math]::Round(((Get-Date -AsUTC) - $script:ExecutionStartTime).TotalSeconds)
    Write-LogEntry -Level 'Information' -Message "Script execution completed" -Data @{
        TotalDuration = "$totalDuration seconds"
        LogEntryCount = $script:LogEntries.Count
    }
}
