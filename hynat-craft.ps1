<#
.SYNOPSIS
    Craft Hyper-V NAT networks declaratively from JSON configuration

.DESCRIPTION
    hynat-craft enables idempotent creation and management of Hyper-V NAT networks
    using simple JSON configuration files. It handles virtual switches, NAT rules,
    and port forwarding with a clean-slate approach for consistency.

.PARAMETER ConfigFile
    Path to JSON configuration file

.PARAMETER Action
    Override the action specified in JSON (apply/remove)

.EXAMPLE
    .\hynat-craft.ps1 -ConfigFile networks\dev.json
    Creates or updates netork defined in dev.json

.EXAMPLE
    .\hynat-craft.ps1 -ConfigFile networks\dev.json -Action remove
    Remove network regardless of JSON action field

.NOTES
    Author: @zinrai
    Repository: https://github.com/zinrai/hynat-craft
    License: MIT
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,
    
    [Parameter()]
    [ValidateSet('apply', 'remove')]
    [string]$Action
)

# Script requires administrator privileges
#Requires -RunAsAdministrator
#Requires -Version 5.1

# Global variables for consistent naming
$script:NetworkName = ""
$script:SwitchName = ""
$script:NatName = ""
$script:AdapterName = ""

# Initialize naming convention based on network name
function Initialize-ResourceNames {
    param([string]$Name)
    
    $script:NetworkName = $Name
    $script:SwitchName = "${Name}Switch"
    $script:NatName = "${Name}NAT"
    $script:AdapterName = "vEthernet ($script:SwitchName)"
    
    Write-Host "Resource names:" -ForegroundColor Gray
    Write-Host "  Switch:  $script:SwitchName" -ForegroundColor Gray
    Write-Host "  NAT:     $script:NatName" -ForegroundColor Gray
    Write-Host "  Adapter: $script:AdapterName" -ForegroundColor Gray
    Write-Host ""
}

# Write formatted message to console
function Write-Message {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Phase')]
        [string]$Level = 'Info'
    )
    
    $prefix = switch ($Level) {
        'Success' { '[SUCCESS]' }
        'Warning' { '[WARN]' }
        'Error' { '[ERROR]' }
        'Phase' { '' }
        default { '[INFO]' }
    }
    
    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        'Phase' { 'Cyan' }
        default { 'White' }
    }
    
    if ($prefix) {
        Write-Host "$prefix $Message" -ForegroundColor $color
    } else {
        Write-Host $Message -ForegroundColor $color
    }
}

# Execute command with display
function Invoke-CommandWithDisplay {
    param(
        [string]$Description,
        [string]$Command,
        [scriptblock]$ScriptBlock
    )
    
    Write-Host "  $Description" -ForegroundColor White
    Write-Host "  > $Command" -ForegroundColor DarkGray
    
    try {
        $result = & $ScriptBlock
        Write-Host "    Success" -ForegroundColor Green
        return $result
    } catch {
        Write-Host "    Failed: $_" -ForegroundColor Red
        throw
    }
}

# Validate JSON configuration
function Test-Configuration {
    param($Config)
    
    Write-Host "Validating configuration structure..." -ForegroundColor Gray
    
    # Check required fields
    if (-not $Config.network) {
        throw "Missing required field: network"
    }
    
    if (-not $Config.network.name) {
        throw "Missing required field: network.name"
    }
    
    if (-not $Config.network.subnet) {
        throw "Missing required field: network.subnet"
    }
    
    # Validate subnet format
    if ($Config.network.subnet -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') {
        throw "Invalid subnet format. Expected CIDR notation (e.g., 192.168.100.0/24)"
    }
    
    # Validate action if present
    if ($Config.action -and $Config.action -notin @('apply', 'remove')) {
        throw "Invalid action. Must be 'apply' or 'remove'"
    }
    
    # Validate port forwarding entries
    if ($Config.portForwarding) {
        Write-Host "Validating port forwarding rules..." -ForegroundColor Gray
        foreach ($pf in $Config.portForwarding) {
            if (-not $pf.name) {
                throw "Port forwarding entry missing name"
            }
            if ($pf.protocol -notin @('TCP', 'UDP')) {
                throw "Invalid protocol for port forwarding '$($pf.name)'. Must be TCP or UDP"
            }
            if ($pf.externalPort -lt 1 -or $pf.externalPort -gt 65535) {
                throw "Invalid external port for '$($pf.name)'. Must be between 1 and 65535"
            }
            if ($pf.internalPort -lt 1 -or $pf.internalPort -gt 65535) {
                throw "Invalid internal port for '$($pf.name)'. Must be between 1 and 65535"
            }
            Write-Host "  - $($pf.name): Valid" -ForegroundColor Gray
        }
    }
    
    Write-Host "Configuration validation completed" -ForegroundColor Gray
    return $true
}

# Calculate gateway IP from subnet (use .1 address)
function Get-GatewayIP {
    param([string]$Subnet)
    
    $parts = $Subnet.Split('/')
    $network = $parts[0]
    $networkParts = $network.Split('.')
    $networkParts[3] = '1'
    
    return ($networkParts -join '.')
}

# Remove all network resources
function Remove-NetworkResources {
    param([string]$Name)
    
    Initialize-ResourceNames -Name $Name
    
    Write-Message "Cleaning up existing resources for network: $Name"
    
    # Remove port forwarding rules (least dependencies)
    Write-Host "  Checking for port forwarding rules..." -ForegroundColor White
    try {
        $mappings = Get-NetNatStaticMapping -ErrorAction SilentlyContinue | 
                   Where-Object { $_.ExternalIPAddress -eq '0.0.0.0' }
        
        if ($mappings) {
            foreach ($mapping in $mappings) {
                $cmd = "Remove-NetNatStaticMapping -StaticMappingID $($mapping.StaticMappingID) -Confirm:`$false"
                Write-Host "  > $cmd" -ForegroundColor DarkGray
                Remove-NetNatStaticMapping -StaticMappingID $mapping.StaticMappingID -Confirm:$false
                Write-Host "    Removed: $($mapping.Protocol) $($mapping.ExternalPort) -> $($mapping.InternalIPAddress):$($mapping.InternalPort)" -ForegroundColor Green
            }
        } ese {
            Write-Host "    No port forwarding rules found" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    Warning: $_" -ForegroundColor Yellow
    }
    
    # Remove NAT
    Write-Host "  Checking for NAT configuration..." -ForegroundColor White
    try {
        $nat = Get-NetNat -Name $script:NatName -ErrorAction SilentlyContinue
        if ($nat) {
            $cmd = "Remove-NetNat -Name '$script:NatName' -Confirm:`$false"
            Write-Host "  > $cmd" -ForegroundColor DarkGray
            Remove-NetNat -Name $script:NatName -Confirm:$false
            Write-Host "    NAT removed successfully" -ForegroundColor Green
        } else {
            Write-Host "    No NAT configuration found" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    Warning: $_" -ForegroundColor Yellow
    }
    
    # Remove IP address
    Write-Host "  Checking for IP address configuration..." -ForegroundColor White
    try {
        $adapter = Get-NetAdapter -Name $script:AdapterName -ErrorAction SilentlyContinue
        if ($adapter) {
            $ip = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($ip) {
                $cmd = "Remove-NetIPAddress -InterfaceIndex $($adapter.InterfaceIndex) -AddressFamily IPv4 -Confirm:`$false"
                Write-Host "  > $cmd" -ForegroundColor DarkGray
                Remove-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -Confirm:$false
                Write-Host "    IP address removed successfully" -ForegroundColor Green
            } else {
                Write-Host "    No IP address configuration found" -ForegroundColor Yellow
            }
        } else {
            Write-Host "    No network adapter found" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    Warning: $_" -ForegroundColor Yellow
    }
    
    # Remove virtual switch
    Write-Host "  Checking for virtual switch..." -ForegroundColor White
    try {
        $switch = Get-VMSwitch -Name $script:SwitchName -ErrorAction SilentlyContinue
        if ($switch) {
            $cmd = "Remove-VMSwitch -Name '$script:SwitchName' -Force -Confirm:`$false"
            Write-Host "  > $cmd" -ForegroundColor DarkGray
            Remove-VMSwitch -Name $script:SwitchName -Force -Confirm:$false
            Write-Host "    Virtual switch removed successfully" -ForegroundColor Green
        } else {
            Write-Host "    No virtual switch found" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    Warning: $_" -ForegroundColor Yellow
    }
    
    Write-Message "Cleanup completed" -Level Success
}

# Create network resources
function New-NetworkResources {
    param($Config)
    
    Initialize-ResourceNames -Name $Config.network.name
    
    # Determine gateway IP
    $gatewayIP = if ($Config.network.gateway) { 
        Write-Host "Using specified gateway: $($Config.network.gateway)" -ForegroundColor Gray
        $Config.network.gateway 
    } else { 
        $calculated = Get-GatewayIP -Subnet $Config.network.subnet
        Write-Host "Using auto-calculated gateway: $calculated" -ForegroundColor Gray
        $calculated
    }
    
    Write-Host ""
    Write-Message "Crafting network: $($Config.network.name)"
    
    # Create virtual switch
    Invoke-CommandWithDisplay `
        -Description "Creating virtual switch" `
        -Command "New-VMSwitch -Name '$script:SwitchName' -SwitchType Internal" `
        -ScriptBlock { 
            New-VMSwitch -Name $script:SwitchName -SwitchType Internal -ErrorAction Stop 
        }
    
    # Wait for adapter to be ready
    Write-Host "  Waiting for network adapter to initialize..." -ForegroundColor Gray
    Start-Sleep -Seconds 2
    
    # Configure gateway IP
    $adapter = Get-NetAdapter -Name $script:AdapterName -ErrorAction Stop
    $prefixLength = $Config.network.subnet.Split('/')[1]
    
    Invoke-CommandWithDisplay `
        -Description "Configuring gateway IP" `
        -Command "New-NetIPAddress -InterfaceIndex $($adapter.InterfaceIndex) -IPAddress '$gatewayIP' -PrefixLength $prefixLength -AddressFamily IPv4" `
        -ScriptBlock {
            New-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
                            -IPAddress $gatewayIP `
                            -PrefixLength $prefixLength `
                            -AddressFamily IPv4 `
                            -ErrorAction Stop
        }
    
    # Create NAT
    Invoke-CommandWithDisplay `
        -Description "Creating NAT" `
        -Command "New-NetNat -Name '$script:NatName' -InternalIPInterfaceAddressPrefix '$($Config.network.subnet)'" `
        -ScriptBlock {
            New-NetNat -Name $script:NatName `
                      -InternalIPInterfaceAddressPrefix $Config.network.subnet `
                      -ErrorAction Stop
        }
    
    # Add port forwarding rules
    if ($Config.portForwarding -and $Config.portForwarding.Count -gt 0) {
        Write-Host "  Adding port forwarding rules:" -ForegroundColor White
        foreach ($pf in $Config.portForwarding) {
            $cmd = "Add-NetNatStaticMapping -NatName '$script:NatName' -Protocol $($pf.protocol) -ExternalIPAddress '0.0.0.0' -ExternalPort $($pf.externalPort) -InternalIPAddress '$($pf.internalIP)' -InternalPort $($pf.internalPort)"
            Write-Host "  > $cmd" -ForegroundColor DarkGray
            
            try {
                $null = Add-NetNatStaticMapping -NatName $script:NatName `
                                               -Protocol $pf.protocol `
                                               -ExternalIPAddress "0.0.0.0" `
                                               -ExternalPort $pf.externalPort `
                                               -InternalIPAddress $pf.internalIP `
                                               -InternalPort $pf.internalPort `
                                               -ErrorAction Stop
                
                Write-Host "    Success: $($pf.name) configured" -ForegroundColor Green
            } catch {
                Write-Host "    Failed: $_" -ForegroundColor Red
            }
        }
    }
    
    Write-Message "Network crafted successfully!" -Level Success
    
    # Display VM configuration information
    if ($Config.vms -and $Config.vms.Count -gt 0) {
        Write-Host ""
        Write-Host "=========================================" -ForegroundColor Cyan
        Write-Host "VM Network Configuration" -ForegroundColor Cyan
        Write-Host "=========================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Configure each VM with these settings:" -ForegroundColor Yellow
        Write-Host ""
        
        foreach ($vm in $Config.vms) {
            Write-Host "VM: $($vm.name)" -ForegroundColor Yellow
            Write-Host "  IP Address:     $($vm.ip)"
            Write-Host "  Subnet Mask:    255.255.255.0"
            Write-Host "  Gateway:        $gatewayIP"
            Write-Host "  DNS:            Configure your preferred DNS servers"
            Write-Host "                  (e.g., 8.8.8.8, 1.1.1.1, or your local DNS)"
            if ($vm.memo) {
                Write-Host "  Note:           $($vm.memo)"
            }
            Write-Host ""
        }
        
        Write-Host "=========================================" -ForegroundColor Cyan
    }
}

# Show banner
function Show-Banner {
    Write-Host ""
    Write-Host "hynat-craft - Hyper-V NAT Network Builder" -ForegroundColor Cyan
    Write-Host "Craft your NA networks like building blocks!" -ForegroundColor Gray
    Write-Host ""
}

# Main execution
try {
    $startTime = Get-Date
    
    Show-Banner
    
    # Phase 1: Validation
    Write-Message "[Phase 1/4] Validating configuration" -Level Phase
    Write-Host ""
    
    # Check if configuration file exists
    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file not found: $ConfigFile"
    }
    
    # Load and parse JSON
    Write-Host "Loading configuration file: $ConfigFile" -ForegroundColor Gray
    try {
        $configContent = Get-Content $ConfigFile -Raw
        $config = $configContent | ConvertFrom-Json
    } catch {
        throw "Failed to parse JSON configuration: $_"
    }
    
    # Validate configuration
    Test-Configuration -Config $config
    Write-Host ""
    
    # Determine action (parameter overrides JSON)
    $actionToPerform = if ($Action) { $Action } else { $config.action }
    if (-not $actionToPerform) {
        $actionToPerform = 'apply'
    }
    
    # Show configuration summary and confirm
    Write-Host "=========================================" -ForegroundColor Yellow
    Write-Host "Configuration Summary" -ForegroundColor Yellow
    Write-Host "=========================================" -ForegroundColor Yellow
    Write-Host "Network:  $($config.network.name)" -ForegroundColor Cyan
    Write-Host "Subnet:   $($config.network.subnet)" -ForegroundColor Cyan
    Write-Host "Action:   $actionToPerform" -ForegroundColor Cyan
    if ($config.portForwarding) {
        Write-Host "Ports:    $($config.portForwarding.Count) forwarding rules" -ForegroundColor Cyan
    }
    if ($config.vms) {
        Write-Host "VMs:      $($config.vms.Count) VM configurations" -ForegroundColor Cyan
    }
    Write-Host "=========================================" -ForegroundColor Yellow
    Write-Host ""
    
    if ($actionToPerform -eq 'apply') {
        Write-Host "This will recreate the network (existing resources will be removed)." -ForegroundColor Yellow
    } else {
        Write-Host "This will remove the network and all associated resources." -ForegroundColor Yellow
    }
    
    Write-Host ""
    $confirmation = Read-Host "Continue? (Y/N)"
    if ($confirmation -ne 'Y' -and $confirmation -ne 'y') {
        Write-Message "Operation cancelled by user" -Level Warning
        exit 0
    }
    
    Write-Host ""
    
    if ($actionToPerform -eq 'remove') {
        # Phase 2: Remove only
        Write-Message "[Phase 2/2] Removing network" -Level Phase
        Write-Host ""
        Remove-NetworkResources -Name $config.network.name
        Write-Host ""
        Write-Message "Network '$($config.network.name)' has been removed" -Level Success
    } else {
        # Phase 2: Cleanup
        Write-Message "[Phase 2/4] Cleaning up existing resources" -Level Phase
        Write-Host ""
        Remove-NetworkResources -Name $config.network.name
        
        Write-Host ""
        
        # Phase 3: Creation
        Write-Message "[Phase 3/4] Crafting network resources" -Level Phase
        Write-Host ""
        New-NetworkResources -Config $config
        
        Write-Host ""
        
        # Phase 4: Complete
        Write-Message "[Phase 4/4] Complete" -Level Phase
        Write-Message "Network '$($config.network.name)' is ready!" -Level Success
    }
    
    # Calculate execution time
    $endTime = Get-Date
    $duration = ($endTime - $startTime).TotalSeconds
    Write-Host ""
    Write-Host ("Execution completed in {0:N1} seconds" -f $duration) -ForegroundColor Gray
    
} catch {
    Write-Message "Operation failed: $_" -Level Error
    
    # Show detailed error information
    Write-Host ""
    Write-Host "Error details:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Gray
    Write-Host ""
    Write-Host "Stack trace:" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
    
    # Attempt cleanup on error
    if ($script:NetworkName) {
        Write-Host ""
        Write-Message "Attempting to clean up partial resources..." -Level Warning
        try {
            Remove-NetworkResources -Name $script:NetworkName
        } catch {
            Write-Message "Cleanup failed. Manual intervention may be required." -Level Error
            Write-Host "Please manually check and remove:" -ForegroundColor Yellow
            Write-Host "  - Virtual Switch: $script:SwitchName" -ForegroundColor Gray
            Write-Host "  - NAT: $script:NatName" -ForegroundColor Gray
        }
    }
    
    exit 1
}
