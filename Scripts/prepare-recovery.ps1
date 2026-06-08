#Requires -Version 7.0
<#
.SYNOPSIS
    Prepares an Azure VM OS Disk for recovery by creating a snapshot and recovery environment.

.DESCRIPTION
    This script automates the preparation of an Azure VM for OS Disk recovery. It performs the following:
    - Validates the source VM
    - Detects the OS type (Windows/Linux)
    - Stops and deallocates the VM
    - Creates a snapshot of the OS Disk
    - Creates a recovery managed disk from the snapshot
    - Provisions a repair VM with the recovery disk attached
    - Generates recovery metadata for rollback support

.PARAMETER SubscriptionId
    The Azure Subscription ID containing the source VM.

.PARAMETER ResourceGroupName
    The name of the resource group containing the source VM.

.PARAMETER VmName
    The name of the source VM requiring recovery.

.PARAMETER Location
    The Azure region where the recovery resources will be created.

.PARAMETER RepairVmAdminUsername
    The administrator username for the repair VM.

.PARAMETER RepairVmAdminPassword
    The administrator password for the repair VM (as SecureString or plain text).

.PARAMETER CorrelationId
    Optional correlation ID for tracking related operations. If not provided, a new GUID is generated.

.PARAMETER RetryCount
    Maximum number of retry attempts for operations. Default is 3.

.PARAMETER RetryDelaySeconds
    Delay in seconds between retry attempts. Default is 10.

.EXAMPLE
    PS> .\prepare-recovery.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" `
        -ResourceGroupName "rg-prod" -VmName "vm-prod-01" -Location "eastus" `
        -RepairVmAdminUsername "azureuser" -RepairVmAdminPassword "P@ssw0rd123!"

.OUTPUTS
    System.String. Path to the recovery metadata JSON file.

.NOTES
    Author: Cloud Architecture Team
    Version: 1.0.0
    PowerShell: 7.0+
    Requires: Az.Compute, Az.Network modules

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

    [Parameter(Mandatory = $true, HelpMessage = "Azure Region")]
    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [Parameter(Mandatory = $true, HelpMessage = "Repair VM Admin Username")]
    [ValidateLength(1, 20)]
    [string]$RepairVmAdminUsername,

    [Parameter(Mandatory = $true, HelpMessage = "Repair VM Admin Password")]
    [ValidateNotNullOrEmpty()]
    [object]$RepairVmAdminPassword,

    [Parameter(Mandatory = $false, HelpMessage = "Correlation ID for request tracking")]
    [string]$CorrelationId = [System.Guid]::NewGuid().ToString(),

    [Parameter(Mandatory = $false, HelpMessage = "Maximum retry attempts")]
    [ValidateRange(1, 10)]
    [int]$RetryCount = 3,

    [Parameter(Mandatory = $false, HelpMessage = "Delay between retries in seconds")]
    [ValidateRange(1, 60)]
    [int]$RetryDelaySeconds = 10
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
$script:TempResourceNamePrefix = "recovery-$(Get-Date -Format 'yyyyMMddHHmmss')"

# Resource naming conventions
$repairVmName = "repair-vm-$($TempResourceNamePrefix)"
$snapshotName = "snapshot-osdisk-$($TempResourceNamePrefix)"
$recoveryDiskName = "disk-recovery-$($TempResourceNamePrefix)"
$publicIpName = "pip-repair-$($TempResourceNamePrefix)"
$nicName = "nic-repair-$($TempResourceNamePrefix)"

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
    Validates that an Azure resource exists.
#>
function Test-AzureResource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceType,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ValidationScript
    )

    try {
        $result = & $ValidationScript
        if ($result) {
            Write-LogEntry -Level 'Verbose' -Message "Validated $ResourceType exists: $ResourceName"
            return $true
        }
        else {
            Write-LogEntry -Level 'Error' -Message "$ResourceType not found: $ResourceName"
            return $false
        }
    }
    catch {
        Write-LogEntry -Level 'Error' -Message "Error validating $ResourceType : $ResourceName" -Data @{
            Error = $_.Exception.Message
        }
        return $false
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
    Converts SecureString password to plain text for Azure operations.
#>
function ConvertFrom-SecureStringToPlain {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SecurePassword
    )

    if ($SecurePassword -is [System.Security.SecureString]) {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($SecurePassword)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
    }
    else {
        return $SecurePassword.ToString()
    }
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

    Invoke-WithRetry -ScriptBlock {
        $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
        return $context
    } -OperationName "Select subscription"

    Write-LogEntry -Level 'Information' -Message "Successfully selected subscription" -Data @{
        SubscriptionId   = $SubscriptionId
        SubscriptionName = $context.Subscription.Name
        TenantId         = $context.Tenant.Id
    }
}

<#
.SYNOPSIS
    Validates the source VM exists and retrieves its properties.
#>
function Get-SourceVmProperties {
    Write-LogEntry -Level 'Information' -Message "Retrieving source VM properties: $VmName"

    $vm = Invoke-WithRetry -ScriptBlock {
        Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction Stop
    } -OperationName "Get source VM"

    if (-not $vm) {
        Write-LogEntry -Level 'Error' -Message "Source VM not found: $VmName"
        throw "Source VM not found: $VmName"
    }

    Write-LogEntry -Level 'Information' -Message "Source VM retrieved successfully" -Data @{
        VmId                = $vm.Id
        VmName              = $vm.Name
        OsType              = $vm.StorageProfile.OsDisk.OsType
        HyperVGeneration    = $vm.HardwareProfile.VmSize
        Zones               = $vm.Zones
        Tags                = $vm.Tags
    }

    return $vm
}

<#
.SYNOPSIS
    Detects the OS type of the source VM.
#>
function Get-SourceVmOsType {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceVm
    )

    $osType = $SourceVm.StorageProfile.OsDisk.OsType

    if (-not $osType) {
        Write-LogEntry -Level 'Error' -Message "Unable to determine OS type for VM: $VmName"
        throw "OS type not detected for VM: $VmName"
    }

    Write-LogEntry -Level 'Information' -Message "Detected OS type: $osType" -Data @{
        OsType = $osType
    }

    return $osType
}

<#
.SYNOPSIS
    Stops and deallocates the source VM.
#>
function Stop-SourceVm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName
    )

    Write-LogEntry -Level 'Information' -Message "Stopping and deallocating source VM: $VmName"

    Invoke-WithRetry -ScriptBlock {
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Force -NoWait -ErrorAction Stop
    } -OperationName "Stop VM"

    # Wait for VM to be deallocated
    $isDealloc = Wait-ResourceOperation -OperationName "VM deallocation" -StatusCheck {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status
        return $vm.Statuses | Where-Object { $_.Code -match 'PowerState/deallocated' }
    } -MaxWaitSeconds 300

    if (-not $isDealloc) {
        Write-LogEntry -Level 'Warning' -Message "VM deallocation may not be complete, proceeding anyway"
    }

    Write-LogEntry -Level 'Information' -Message "Source VM stopped and deallocated"
}

<#
.SYNOPSIS
    Retrieves the OS disk of the source VM.
#>
function Get-SourceOsDisk {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceVm
    )

    Write-LogEntry -Level 'Information' -Message "Retrieving source OS disk"

    $osDiskId = $SourceVm.StorageProfile.OsDisk.ManagedDisk.Id
    $osDiskName = $SourceVm.StorageProfile.OsDisk.Name

    if (-not $osDiskId) {
        Write-LogEntry -Level 'Error' -Message "OS disk not found on VM: $VmName"
        throw "OS disk ID not found for VM: $VmName"
    }

    $osDisk = Invoke-WithRetry -ScriptBlock {
        Get-AzDisk -ResourceId $osDiskId -ErrorAction Stop
    } -OperationName "Get OS disk"

    Write-LogEntry -Level 'Information' -Message "OS disk retrieved successfully" -Data @{
        DiskId         = $osDisk.Id
        DiskName       = $osDisk.Name
        DiskSizeGb     = $osDisk.DiskSizeGB
        SkuName        = $osDisk.Sku.Name
        CreationTime   = $osDisk.TimeCreated
    }

    return @{
        Disk = $osDisk
        Name = $osDiskName
    }
}

<#
.SYNOPSIS
    Creates a snapshot of the source OS disk.
#>
function New-OsDiskSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [object]$OsDisk,

        [Parameter(Mandatory = $true)]
        [string]$SnapshotName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    Write-LogEntry -Level 'Information' -Message "Creating snapshot of OS disk: $SnapshotName"

    $snapshotConfig = New-AzSnapshotConfig -SourceUri $OsDisk.Id -Location $Location -CreateOption Copy
    $snapshotConfig.Tags = @{
        'SourceVm'      = $VmName
        'CorrelationId' = $script:CorrelationId
        'CreatedBy'     = 'prepare-recovery-script'
        'CreatedDate'   = (Get-Date -AsUTC -Format 'o')
    }

    $snapshot = Invoke-WithRetry -ScriptBlock {
        New-AzSnapshot -ResourceGroupName $ResourceGroupName -Snapshot $snapshotConfig -SnapshotName $SnapshotName -ErrorAction Stop
    } -OperationName "Create snapshot"

    Write-LogEntry -Level 'Information' -Message "Snapshot created successfully" -Data @{
        SnapshotId   = $snapshot.Id
        SnapshotName = $snapshot.Name
        SourceDiskId = $OsDisk.Id
    }

    return $snapshot
}

<#
.SYNOPSIS
    Creates a recovery managed disk from the snapshot.
#>
function New-RecoveryManagedDisk {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [Parameter(Mandatory = $true)]
        [string]$DiskName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    Write-LogEntry -Level 'Information' -Message "Creating recovery managed disk from snapshot: $DiskName"

    $diskConfig = New-AzDiskConfig -Location $Location -CreateOption Copy -SourceResourceId $Snapshot.Id -SkuName StandardSSD_LRS
    $diskConfig.Tags = @{
        'SourceSnapshot' = $Snapshot.Name
        'CorrelationId'  = $script:CorrelationId
        'CreatedBy'      = 'prepare-recovery-script'
        'CreatedDate'    = (Get-Date -AsUTC -Format 'o')
    }

    $recoveryDisk = Invoke-WithRetry -ScriptBlock {
        New-AzDisk -ResourceGroupName $ResourceGroupName -Disk $diskConfig -DiskName $DiskName -ErrorAction Stop
    } -OperationName "Create recovery disk"

    Write-LogEntry -Level 'Information' -Message "Recovery disk created successfully" -Data @{
        DiskId       = $recoveryDisk.Id
        DiskName     = $recoveryDisk.Name
        DiskSizeGb   = $recoveryDisk.DiskSizeGB
        SourceDiskId = $Snapshot.Id
    }

    return $recoveryDisk
}

<#
.SYNOPSIS
    Discovers the source subnet for the repair VM.
#>
function Get-SourceSubnet {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceVm
    )

    Write-LogEntry -Level 'Information' -Message "Discovering source subnet from VM network configuration"

    $nic = $SourceVm.NetworkProfile.NetworkInterfaces[0]

    if (-not $nic) {
        Write-LogEntry -Level 'Error' -Message "No network interface found on source VM"
        throw "Network interface not found on VM: $VmName"
    }

    $nicId = $nic.Id
    $nic = Invoke-WithRetry -ScriptBlock {
        Get-AzNetworkInterface -ResourceId $nicId -ErrorAction Stop
    } -OperationName "Get source NIC"

    $subnetId = $nic.IpConfigurations[0].Subnet.Id
    $vnetId = $subnetId.Substring(0, $subnetId.LastIndexOf('/subnets'))

    Write-LogEntry -Level 'Information' -Message "Source subnet discovered" -Data @{
        SubnetId = $subnetId
        VnetId   = $vnetId
        NicId    = $nicId
    }

    return @{
        SubnetId = $subnetId
        VnetId   = $vnetId
    }
}

<#
.SYNOPSIS
    Creates a public IP for the repair VM.
#>
function New-RepairVmPublicIp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PublicIpName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    Write-LogEntry -Level 'Information' -Message "Creating public IP for repair VM: $PublicIpName"

    $publicIpConfig = @{
        Name              = $PublicIpName
        ResourceGroupName = $ResourceGroupName
        Location          = $Location
        AllocationMethod  = 'Static'
        Sku               = 'Standard'
        Tag               = @{
            'CorrelationId' = $script:CorrelationId
            'CreatedBy'     = 'prepare-recovery-script'
            'CreatedDate'   = (Get-Date -AsUTC -Format 'o')
        }
    }

    $publicIp = Invoke-WithRetry -ScriptBlock {
        New-AzPublicIpAddress @publicIpConfig -ErrorAction Stop
    } -OperationName "Create public IP"

    Write-LogEntry -Level 'Information' -Message "Public IP created successfully" -Data @{
        PublicIpId = $publicIp.Id
        IpAddress  = $publicIp.IpAddress
    }

    return $publicIp
}

<#
.SYNOPSIS
    Creates a network security group for the repair VM.
#>
function New-RepairVmNetworkSecurityGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    Write-LogEntry -Level 'Information' -Message "Creating network security group for repair VM"

    $nsgName = "nsg-repair-$($TempResourceNamePrefix)"

    $nsgConfig = @{
        Name              = $nsgName
        ResourceGroupName = $ResourceGroupName
        Location          = $Location
        Tag               = @{
            'CorrelationId' = $script:CorrelationId
            'CreatedBy'     = 'prepare-recovery-script'
            'CreatedDate'   = (Get-Date -AsUTC -Format 'o')
        }
    }

    $nsg = Invoke-WithRetry -ScriptBlock {
        New-AzNetworkSecurityGroup @nsgConfig -ErrorAction Stop
    } -OperationName "Create NSG"

    # Add SSH/RDP inbound rule
    $nsg | Add-AzNetworkSecurityRuleConfig -Name "AllowRemoteAccess" -Priority 100 -Direction Inbound `
        -Access Allow -Protocol Tcp -SourcePortRange "*" -DestinationPortRange "22,3389" `
        -SourceAddressPrefix "*" -DestinationAddressPrefix "*" | Set-AzNetworkSecurityGroup

    Write-LogEntry -Level 'Information' -Message "Network security group created successfully" -Data @{
        NsgId = $nsg.Id
    }

    return $nsg
}

<#
.SYNOPSIS
    Creates a network interface for the repair VM.
#>
function New-RepairVmNetworkInterface {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NicName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location,

        [Parameter(Mandatory = $true)]
        [string]$SubnetId,

        [Parameter(Mandatory = $true)]
        [object]$PublicIp,

        [Parameter(Mandatory = $true)]
        [object]$Nsg
    )

    Write-LogEntry -Level 'Information' -Message "Creating network interface for repair VM: $NicName"

    $nicConfig = @{
        Name              = $NicName
        ResourceGroupName = $ResourceGroupName
        Location          = $Location
        SubnetId          = $SubnetId
        PublicIpAddressId = $PublicIp.Id
        NetworkSecurityGroupId = $Nsg.Id
        Tag               = @{
            'CorrelationId' = $script:CorrelationId
            'CreatedBy'     = 'prepare-recovery-script'
            'CreatedDate'   = (Get-Date -AsUTC -Format 'o')
        }
    }

    $nic = Invoke-WithRetry -ScriptBlock {
        New-AzNetworkInterface @nicConfig -ErrorAction Stop
    } -OperationName "Create NIC"

    Write-LogEntry -Level 'Information' -Message "Network interface created successfully" -Data @{
        NicId = $nic.Id
    }

    return $nic
}

<#
.SYNOPSIS
    Creates the repair VM.
#>
function New-RepairVm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepairVmName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location,

        [Parameter(Mandatory = $true)]
        [object]$Nic,

        [Parameter(Mandatory = $true)]
        [string]$AdminUsername,

        [Parameter(Mandatory = $true)]
        [string]$AdminPassword,

        [Parameter(Mandatory = $true)]
        [string]$OsType
    )

    Write-LogEntry -Level 'Information' -Message "Creating repair VM: $RepairVmName (OS: $OsType)"

    # Select appropriate image based on OS type
    if ($OsType -eq 'Linux') {
        $imagePublisher = 'Canonical'
        $imageOffer = '0001-com-ubuntu-server-jammy'
        $imageSku = '22_04-lts-gen2'
    }
    else {
        $imagePublisher = 'MicrosoftWindowsServer'
        $imageOffer = 'WindowsServer'
        $imageSku = '2022-datacenter'
    }

    Write-LogEntry -Level 'Debug' -Message "Using image" -Data @{
        Publisher = $imagePublisher
        Offer     = $imageOffer
        Sku       = $imageSku
    }

    $vmConfig = New-AzVMConfig -VMName $RepairVmName -VMSize 'Standard_D2s_v3'

    # Set OS profile
    if ($OsType -eq 'Linux') {
        $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $RepairVmName `
            -Credential (New-Object System.Management.Automation.PSCredential($AdminUsername, (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))) `
            -DisablePasswordAuthentication:$false
    }
    else {
        $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $RepairVmName `
            -Credential (New-Object System.Management.Automation.PSCredential($AdminUsername, (ConvertTo-SecureString $AdminPassword -AsPlainText -Force)))
    }

    # Add NIC
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $Nic.Id

    # Set source image
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName $imagePublisher `
        -Offer $imageOffer -Skus $imageSku -Version 'latest'

    # Create VM
    $vm = Invoke-WithRetry -ScriptBlock {
        New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig -ErrorAction Stop
    } -OperationName "Create repair VM"

    Write-LogEntry -Level 'Information' -Message "Repair VM created successfully" -Data @{
        VmId         = $vm.Id
        VmName       = $vm.Name
        ComputerName = $vm.OSProfile.ComputerName
        ImageDetails = @{
            Publisher = $imagePublisher
            Offer     = $imageOffer
            Sku       = $imageSku
        }
    }

    return $vm
}

<#
.SYNOPSIS
    Attaches the recovery disk to the repair VM.
#>
function Attach-RecoveryDiskToRepairVm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$RepairVmName,

        [Parameter(Mandatory = $true)]
        [object]$RecoveryDisk
    )

    Write-LogEntry -Level 'Information' -Message "Attaching recovery disk to repair VM: $RepairVmName"

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $RepairVmName

    $vm = Add-AzVMDataDisk -VM $vm -Name $RecoveryDisk.Name -ManagedDiskId $RecoveryDisk.Id `
        -Caching ReadWrite -Lun 1 -CreateOption Attach

    $vm = Invoke-WithRetry -ScriptBlock {
        Update-AzVM -VM $vm -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    } -OperationName "Attach recovery disk"

    Write-LogEntry -Level 'Information' -Message "Recovery disk attached successfully" -Data @{
        DiskId   = $RecoveryDisk.Id
        DiskName = $RecoveryDisk.Name
        Lun      = 1
    }

    return $vm
}

# ============================================================================
# METADATA AND OUTPUT FUNCTIONS
# ============================================================================

<#
.SYNOPSIS
    Generates recovery metadata JSON file.
#>
function New-RecoveryMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceVm,

        [Parameter(Mandatory = $true)]
        [object]$OsDisk,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [Parameter(Mandatory = $true)]
        [object]$RecoveryDisk,

        [Parameter(Mandatory = $true)]
        [object]$RepairVm,

        [Parameter(Mandatory = $true)]
        [object]$PublicIp,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    Write-LogEntry -Level 'Information' -Message "Generating recovery metadata"

    $metadata = @{
        RecoverySessionId = $script:CorrelationId
        ScriptVersion     = $script:ScriptVersion
        ExecutionStartTime = $script:ExecutionStartTime.ToString('o')
        ExecutionEndTime   = (Get-Date -AsUTC).ToString('o')
        SourceVm          = @{
            Id                 = $SourceVm.Id
            Name               = $SourceVm.Name
            ResourceGroupName  = $SourceVm.ResourceGroupName
            Location           = $SourceVm.Location
            OsType             = $SourceVm.StorageProfile.OsDisk.OsType
            HyperVGeneration   = $SourceVm.HardwareProfile.VmSize
            VmSize             = $SourceVm.HardwareProfile.VmSize
            Zones              = $SourceVm.Zones
            Tags               = $SourceVm.Tags
            ProvisioningState  = $SourceVm.ProvisioningState
        }
        SourceOsDisk      = @{
            Id              = $OsDisk.Disk.Id
            Name            = $OsDisk.Name
            SizeGb          = $OsDisk.Disk.DiskSizeGB
            SkuName         = $OsDisk.Disk.Sku.Name
            DiskEncryptionSet = $OsDisk.Disk.Encryption.DiskEncryptionSet.Id
            CreationTime    = $OsDisk.Disk.TimeCreated.ToString('o')
        }
        OsDiskSnapshot    = @{
            Id              = $Snapshot.Id
            Name            = $Snapshot.Name
            SizeGb          = $Snapshot.DiskSizeGB
            CreationTime    = $Snapshot.TimeCreated.ToString('o')
            SourceResourceId = $Snapshot.CreationData.SourceResourceId
        }
        RecoveryDisk      = @{
            Id              = $RecoveryDisk.Id
            Name            = $RecoveryDisk.Name
            SizeGb          = $RecoveryDisk.DiskSizeGB
            SkuName         = $RecoveryDisk.Sku.Name
            CreationTime    = $RecoveryDisk.TimeCreated.ToString('o')
        }
        RepairVm          = @{
            Id              = $RepairVm.Id
            Name            = $RepairVm.Name
            ResourceGroupName = $ResourceGroupName
            Location        = $Location
            VmSize          = $RepairVm.HardwareProfile.VmSize
            OsType          = if ($SourceVm.StorageProfile.OsDisk.OsType -eq 'Linux') { 'Linux' } else { 'Windows' }
            ProvisioningState = $RepairVm.ProvisioningState
            PublicIpAddress = $PublicIp.IpAddress
            Fqdn            = $PublicIp.Fqdns[0] ? $PublicIp.Fqdns[0] : ""
            AdminUsername   = $RepairVmAdminUsername
        }
        ConnectionInfo    = @{
            PublicIpAddress = $PublicIp.IpAddress
            SshPort         = 22
            RdpPort         = 3389
            AdminUsername   = $RepairVmAdminUsername
            Instructions    = if ($SourceVm.StorageProfile.OsDisk.OsType -eq 'Linux') {
                "SSH: ssh -i <private_key> $RepairVmAdminUsername@$($PublicIp.IpAddress)"
            }
            else {
                "RDP: mstsc /v:$($PublicIp.IpAddress)"
            }
        }
        LogEntries        = $script:LogEntries
    }

    # Generate metadata hash
    $metadataJson = $metadata | ConvertTo-Json -Depth 10
    $metadata['MetadataHash'] = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($metadataJson))) -Algorithm SHA256).Hash

    Write-LogEntry -Level 'Information' -Message "Recovery metadata generated successfully"

    return $metadata
}

<#
.SYNOPSIS
    Saves recovery metadata to JSON file.
#>
function Save-RecoveryMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    Write-LogEntry -Level 'Information' -Message "Saving recovery metadata to file: $OutputPath"

    $Metadata | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding UTF8 -Force

    Write-LogEntry -Level 'Information' -Message "Recovery metadata saved successfully" -Data @{
        FilePath = $OutputPath
        FileSize = (Get-Item $OutputPath).Length
    }

    return $OutputPath
}

<#
.SYNOPSIS
    Outputs recovery completion information.
#>
function Output-RecoveryCompletionInfo {
    param(
        [Parameter(Mandatory = $true)]
        [object]$RepairVm,

        [Parameter(Mandatory = $true)]
        [object]$PublicIp,

        [Parameter(Mandatory = $true)]
        [string]$OsType,

        [Parameter(Mandatory = $true)]
        [string]$MetadataFilePath
    )

    $completionInfo = @{
        Status          = 'SUCCESS'
        RepairVmName    = $RepairVm.Name
        RepairVmId      = $RepairVm.Id
        PublicIpAddress = $PublicIp.IpAddress
        AdminUsername   = $RepairVmAdminUsername
        MetadataFile    = $MetadataFilePath
        ConnectionInfo  = if ($OsType -eq 'Linux') {
            "Connect via SSH: ssh -i <private_key> $RepairVmAdminUsername@$($PublicIp.IpAddress)"
        }
        else {
            "Connect via RDP: mstsc /v:$($PublicIp.IpAddress)"
        }
        CorrelationId   = $script:CorrelationId
        Timestamp       = (Get-Date -AsUTC).ToString('o')
    }

    Write-LogEntry -Level 'Information' -Message "Recovery preparation completed successfully" -Data $completionInfo

    Write-Host "═══════════════════════════════════════════════════════════════════"
    Write-Host "RECOVERY PREPARATION COMPLETED" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════════"
    Write-Host ""
    Write-Host "Repair VM Details:" -ForegroundColor Cyan
    Write-Host "  Name:          $($RepairVm.Name)"
    Write-Host "  Public IP:     $($PublicIp.IpAddress)"
    Write-Host "  Admin User:    $RepairVmAdminUsername"
    Write-Host ""
    Write-Host "Connection Information:" -ForegroundColor Cyan
    Write-Host "  $($completionInfo.ConnectionInfo)"
    Write-Host ""
    Write-Host "Metadata File:" -ForegroundColor Cyan
    Write-Host "  Path:          $MetadataFilePath"
    Write-Host ""
    Write-Host "Correlation ID: $($script:CorrelationId)"
    Write-Host "═══════════════════════════════════════════════════════════════════"
    Write-Host ""

    return $completionInfo
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

try {
    Write-LogEntry -Level 'Information' -Message "Starting Azure VM Recovery Preparation" -Data @{
        CorrelationId     = $script:CorrelationId
        SubscriptionId    = $SubscriptionId
        ResourceGroupName = $ResourceGroupName
        VmName            = $VmName
        Location          = $Location
        ScriptVersion     = $script:ScriptVersion
    }

    # 1. Select subscription
    Select-TargetSubscription

    # 2. Validate VM exists and get properties
    $sourceVm = Get-SourceVmProperties
    Write-LogEntry -Level 'Information' -Message "Source VM validated"

    # 3. Detect OS type
    $osType = Get-SourceVmOsType -SourceVm $sourceVm
    Write-LogEntry -Level 'Information' -Message "OS type detected: $osType"

    # 4. Stop and deallocate VM
    Stop-SourceVm -VmName $VmName -ResourceGroupName $ResourceGroupName
    Write-LogEntry -Level 'Information' -Message "Source VM deallocated"

    # 5. Get OS disk
    $osDiskInfo = Get-SourceOsDisk -SourceVm $sourceVm
    Write-LogEntry -Level 'Information' -Message "OS disk retrieved"

    # 6. Get source subnet
    $subnetInfo = Get-SourceSubnet -SourceVm $sourceVm
    Write-LogEntry -Level 'Information' -Message "Source subnet discovered"

    # 7. Create OS disk snapshot
    $snapshot = New-OsDiskSnapshot -OsDisk $osDiskInfo.Disk -SnapshotName $snapshotName `
        -ResourceGroupName $ResourceGroupName -Location $Location
    Write-LogEntry -Level 'Information' -Message "OS disk snapshot created"

    # 8. Create recovery disk from snapshot
    $recoveryDisk = New-RecoveryManagedDisk -Snapshot $snapshot -DiskName $recoveryDiskName `
        -ResourceGroupName $ResourceGroupName -Location $Location
    Write-LogEntry -Level 'Information' -Message "Recovery disk created"

    # 9. Create public IP
    $publicIp = New-RepairVmPublicIp -PublicIpName $publicIpName -ResourceGroupName $ResourceGroupName `
        -Location $Location
    Write-LogEntry -Level 'Information' -Message "Public IP created"

    # 10. Create NSG
    $nsg = New-RepairVmNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Location $Location
    Write-LogEntry -Level 'Information' -Message "NSG created"

    # 11. Create NIC
    $nic = New-RepairVmNetworkInterface -NicName $nicName -ResourceGroupName $ResourceGroupName `
        -Location $Location -SubnetId $subnetInfo.SubnetId -PublicIp $publicIp -Nsg $nsg
    Write-LogEntry -Level 'Information' -Message "NIC created"

    # 12. Create repair VM
    $plainPassword = ConvertFrom-SecureStringToPlain -SecurePassword $RepairVmAdminPassword
    $repairVm = New-RepairVm -RepairVmName $repairVmName -ResourceGroupName $ResourceGroupName `
        -Location $Location -Nic $nic -AdminUsername $RepairVmAdminUsername `
        -AdminPassword $plainPassword -OsType $osType
    Write-LogEntry -Level 'Information' -Message "Repair VM created"

    # 13. Attach recovery disk to repair VM
    $repairVm = Attach-RecoveryDiskToRepairVm -ResourceGroupName $ResourceGroupName `
        -RepairVmName $repairVmName -RecoveryDisk $recoveryDisk
    Write-LogEntry -Level 'Information' -Message "Recovery disk attached"

    # 14. Generate recovery metadata
    $metadata = New-RecoveryMetadata -SourceVm $sourceVm -OsDisk $osDiskInfo -Snapshot $snapshot `
        -RecoveryDisk $recoveryDisk -RepairVm $repairVm -PublicIp $publicIp `
        -ResourceGroupName $ResourceGroupName -Location $Location

    # 15. Save metadata to file
    $metadataFilePath = Join-Path $PSScriptRoot "recovery-metadata-$($script:CorrelationId).json"
    Save-RecoveryMetadata -Metadata $metadata -OutputPath $metadataFilePath

    # 16. Output completion information
    Output-RecoveryCompletionInfo -RepairVm $repairVm -PublicIp $publicIp -OsType $osType `
        -MetadataFilePath $metadataFilePath

    Write-LogEntry -Level 'Information' -Message "Azure VM recovery preparation completed successfully" -Data @{
        Duration          = $([Math]::Round(((Get-Date -AsUTC) - $script:ExecutionStartTime).TotalSeconds))
        MetadataFilePath  = $metadataFilePath
        RepairVmId        = $repairVm.Id
    }

    # Return metadata file path as output
    return $metadataFilePath
}
catch {
    $errorDetails = @{
        ErrorMessage  = $_.Exception.Message
        ErrorType     = $_.Exception.GetType().FullName
        StackTrace    = $_.ScriptStackTrace
        LineNumber    = $_.InvocationInfo.ScriptLineNumber
    }

    Write-LogEntry -Level 'Error' -Message "Azure VM recovery preparation failed" -Data $errorDetails

    Write-Host "ERROR: Azure VM recovery preparation failed" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Correlation ID: $($script:CorrelationId)" -ForegroundColor Red

    exit 1
}
finally {
    $totalDuration = [Math]::Round(((Get-Date -AsUTC) - $script:ExecutionStartTime).TotalSeconds)
    Write-LogEntry -Level 'Information' -Message "Script execution completed" -Data @{
        TotalDuration = "$totalDuration seconds"
        LogEntryCount = $script:LogEntries.Count
    }
}
11. Create NIC
12. Create Repair VM
13. Use Ubuntu 22.04 for Linux source VMs
14. Use Windows Server 2022 for Windows source VMs
15. Attach Recovery Disk as Data Disk
16. Generate recovery-metadata.json
17. Store:

* Source VM details
* Snapshot details
* Recovery disk details
* Repair VM details
* Original OS disk details
* Tags
* Zones
* HyperV Generation
* Disk Encryption Set

18. Generate metadata hash
19. Support rollback preparation
20. Output repair VM connection information

Use Az PowerShell cmdlets only.

Generate full working code.
Do not generate pseudocode.
```powershell<#
.SYNOPSIS 
    Prepares Azure VM OS Disk Recovery by creating a repair VM with the OS disk attached as a data disk.
.DESCRIPTION
    This script performs the following operations:
    1. Selects the Azure Subscription
    2. Validates the existence of the specified VM  
    3. Detects the OS type of the VM
    4. Stops and deallocates the VM
    5. Retrieves the OS disk information
    6. Captures VM metadata
    7. Creates a snapshot of the OS disk
    8. Creates a recovery managed disk from the snapshot
    9. Discovers the source subnet automatically    
    10. Creates a Public IP
    11. Creates a NIC
    12. Creates a Repair VM
    13. Attaches the Recovery Disk as a Data Disk
    14. Generates recovery-metadata.json with all relevant details
    15. Supports rollback preparation
.PARAMETER SubscriptionId
    The Azure Subscription ID where the VM is located.
.PARAMETER ResourceGroupName
    The name of the Resource Group containing the VM.
.PARAMETER VmName
    The name of the VM to prepare for recovery.
.PARAMETER Location
    The Azure region where the resources will be created.
.PARAMETER RepairVmAdminUsername
    The administrator username for the repair VM.
.PARAMETER RepairVmAdminPassword
    The administrator password for the repair VM.
.EXAMPLE
    .\prepare-recovery.ps1 -SubscriptionId "xxxx-xxxx-xxxx-xxxx" -ResourceGroupName "myResourceGroup" -VmName "myVM" -Location "eastus" -RepairVmAdminUsername "adminUser" -RepairVmAdminPassword "P@ssw0rd!"
    This command prepares the specified VM for recovery by creating a repair VM with the OS disk attached as a data disk.
.NOTES
    This script requires Azure PowerShell modules to be installed and configured.