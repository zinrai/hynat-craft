# hynat-craft

Craft Hyper-V NAT networks like building blocks - declaratively and idempotently.

## Why hynat-craft?

Setting up NAT networks in VirtualBox: Just a few clicks in the GUI

Setting up NAT networks in Hyper-V: Multiple PowerShell commands, complex parameters, and manual configuration...

**hynat-craft** solves this by letting you define your network in a JSON file and applying it with a single command.

## Features

- **Declarative Configuration**: Define your desired state in JSON
- **Idempotent**: Run multiple times safely - same result every time
- **Clean Slate Approach**: Ensures consistent state by recreating resources
- **Command Transparency**: Shows all PowerShell commands being executed

## Requirements

- Windows 10/11 Pro or Server with Hyper-V enabled
- Administrator privileges

## Usage

### Create or Update Network

Apply configuration (with confirmation prompt)

```powershell
.\hynat-craft.ps1 -ConfigFile networks\dev.json
```

### Remove Network

Edit your JSON file and set action to "remove":

```json
{
  "action": "remove",
  "network": {
    "name": "DevNetwork"
  }
}
```

Then run:
```powershell
.\hynat-craft.ps1 -ConfigFile networks\dev.json
```

### Automatic Confirmation

For scripting or automation, you can pipe the confirmation:

```powershell
echo Y | .\hynat-craft.ps1 -ConfigFile networks\dev.json
```

## JSON Configuration

See `example.json`

### Configuration Fields

| Field           | Required | Description                                | Default             |
|-----------------|----------|--------------------------------------------|---------------------|
| action          | No       | "apply" or "remove"                        | "apply"             |
| network.name    | Yes      | Network identifier                         | -                   |
| network.subnet  | Yes      | CIDR notation (e.g., "192.168.100.0/24")   | -                   |
| network.gateway | No       | Gateway IP address                         | Auto (.1 of subnet) |
| portForwarding  | No       | Array of port forwarding rules             | []                  |
| vms             | No       | Array of VM configurations (for reference) | []                  |

## Example Output

```
hynat-craft - Hyper-V NAT Network Builder
Craft your NAT networks like building blocks!

[Phase 1/4] Validating configuration

Loading configuration file: networks\dev.json
Validating configuration structure...
Configuration validation completed

=========================================
Configuration Summary
=========================================
Network:  DevNetwork
Subnet:   192.168.100.0/24
Action:   apply
Ports:    2 forwarding rules
VMs:      1 VM configurations
=========================================

This will recreate the network (existing resources will be removed).

Continue? (Y/N): Y

[Phase 2/4] Cleaning up existing resources

  Checking for port forwarding rules...
  > Remove-NetNatStaticMapping -StaticMappingID 12345 -Confirm:$false
    Removed: TCP 8080 -> 192.168.100.10:80

  Checking for NAT configuration...
  > Remove-NetNat -Name 'DevNetworkNAT' -Confirm:$false
    NAT removed successfully

[Phase 3/4] Crafting network resources

  Creating virtual switch
  > New-VMSwitch -Name 'DevNetworkSwitch' -SwitchType Internal
    Success

  Configuring gateway IP
  > New-NetIPAddress -InterfaceIndex 12 -IPAddress '192.168.100.1' -PrefixLength 24 -AddressFamily IPv4
    Success

[Phase 4/4] Complete
[SUCCESS] Network 'DevNetwork' is ready!

Execution completed in 5.2 seconds
```

## How It Works

1. **Validation**: Checks admin rights and validates JSON configuration
2. **Confirmation**: Shows configuration summary and asks for confirmation
3. **Cleanup**: Removes existing resources (shows each removal command)
4. **Creation**: Creates resources (shows each creation command)
5. **Display**: Shows VM network configuration for manual setup

The script ensures idempotency by always recreating resources from scratch, eliminating configuration drift and conflicts.

## Limitations

- Designed for development environments (brief network interruption during recreation)
- VMs need manual network configuration (IP, Gateway, DNS)
- Single NAT network per configuration file
- Cannot modify existing resources (always recreates)
- No built-in DNS server (use external DNS servers)

## License

This project is licensed under the MIT License - see the [LICENSE](https://opensource.org/license/mit) file for details.
