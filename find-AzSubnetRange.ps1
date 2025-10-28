#!/usr/bin/env pwsh

[CmdletBinding(DefaultParameterSetName = 'Main')]
param(
    [Parameter(ParameterSetName = 'Main', Mandatory = $true)]
    [Alias('v')]
    [ValidateNotNullOrEmpty()]
    [string]$VNetName,

    [Parameter(ParameterSetName = 'Main', Mandatory = $true)]
    [Alias('l')]
    [ValidateRange(0, 32)]
    [int]$Length,

    [Parameter(ParameterSetName = 'Main')]
    [Alias('a')]
    [ValidateRange(1, 2147483647)]
    [int]$Amount = 1,

    [Parameter(ParameterSetName = 'Main')]
    [Alias('g')]
    [string]$ResourceGroup,

    [Parameter(ParameterSetName = 'Help', Mandatory = $true)]
    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-Usage {
    @"
Usage: find-AzSubnetRange.ps1 -VNetName <name> -Length <prefix> [-Amount <count>] [-ResourceGroup <rg>]

Examples:
  ./find-AzSubnetRange.ps1 -v my-vnet -l 24
  ./find-AzSubnetRange.ps1 -VNetName my-vnet -Length 26 -ResourceGroup my-rg -Amount 3
"@.TrimEnd()
}

function Write-Err {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Write-Status {
    param([string]$Message)
    Write-Err $Message
}

function ConvertTo-UInt32 {
    param([string]$IpAddress)
    $address = [System.Net.IPAddress]::Parse($IpAddress)
    if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Only IPv4 addresses are supported."
    }
    $bytes = $address.GetAddressBytes()
    [Array]::Reverse($bytes)
    return [System.BitConverter]::ToUInt32($bytes, 0)
}

function ConvertFrom-UInt32 {
    param([uint64]$Value)
    $bytes = [System.BitConverter]::GetBytes([uint32]$Value)
    [Array]::Reverse($bytes)
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-NetworkMask {
    param([int]$Prefix)
    if ($Prefix -lt 0 -or $Prefix -gt 32) {
        throw "Invalid prefix length '$Prefix'."
    }
    if ($Prefix -eq 0) {
        return [uint64]0
    }
    $allOnes = [uint64]0x00000000FFFFFFFF
    return ($allOnes -shl (32 - $Prefix)) -band 0x00000000FFFFFFFF
}

function Get-BlockSize {
    param([int]$Prefix)
    if ($Prefix -lt 0 -or $Prefix -gt 32) {
        throw "Invalid prefix length '$Prefix'."
    }
    return [uint64]1 -shl (32 - $Prefix)
}

function New-Network {
    param([string]$Cidr)
    $parts = $Cidr -split '/'
    if ($parts.Count -ne 2) {
        throw "Invalid CIDR notation '$Cidr'."
    }
    $prefix = [int]$parts[1]
    if ($prefix -lt 0 -or $prefix -gt 32) {
        throw "Invalid prefix length '$prefix' in '$Cidr'."
    }
    $ipInt = [uint64](ConvertTo-UInt32($parts[0]))
    $mask = Get-NetworkMask $prefix
    $networkInt = $ipInt -band $mask
    $blockSize = Get-BlockSize $prefix
    $endInt = $networkInt + $blockSize - 1
    [pscustomobject]@{
        Cidr = "{0}/{1}" -f (ConvertFrom-UInt32 $networkInt), $prefix
        Prefix = $prefix
        Start = $networkInt
        End = $endInt
        BlockSize = $blockSize
    }
}

function Test-IPv4Cidr {
    param([string]$Cidr)
    if ([string]::IsNullOrWhiteSpace($Cidr)) {
        return $false
    }
    $parts = $Cidr -split '/'
    if ($parts.Count -ne 2) {
        return $false
    }
    $prefixValue = 0
    if (-not [int]::TryParse($parts[1], [ref]$prefixValue)) {
        return $false
    }
    if ($prefixValue -lt 0 -or $prefixValue -gt 32) {
        return $false
    }
    try {
        $address = [System.Net.IPAddress]::Parse($parts[0])
        return $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
    } catch {
        return $false
    }
}

function Get-SubnetNetworks {
    param([object[]]$Subnets)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($entry in ($Subnets | Where-Object { $_ })) {
        $prefixes = @()
        $single = $entry.PSObject.Properties['addressPrefix']
        if ($single -and $single.Value) {
            $prefixes += $single.Value
        }
        $multi = $entry.PSObject.Properties['addressPrefixes']
        if ($multi -and $multi.Value) {
            $prefixes += $multi.Value
        }
        foreach ($cidr in $prefixes) {
            if (-not (Test-IPv4Cidr $cidr)) {
                continue
            }
            try {
                $list.Add((New-Network $cidr))
            } catch {
                continue
            }
        }
    }
    return $list.ToArray()
}

function Get-VNetAddressSpaces {
    param($VNet)
    if (-not $VNet.addressSpace) {
        return @()
    }
    $addressSpace = $VNet.addressSpace
    $prefixesProperty = $addressSpace.PSObject.Properties['addressPrefixes']
    if (-not $prefixesProperty) {
        $available = ($addressSpace.PSObject.Properties | Select-Object -ExpandProperty Name) -join ', '
        throw "The VNet address space is missing the 'addressPrefixes' property. Available properties: $available"
    }
    $prefixes = $prefixesProperty.Value
    if (-not $prefixes) {
        return @()
    }
    $spaces = New-Object System.Collections.Generic.List[object]
    foreach ($cidr in $prefixes) {
        if (-not (Test-IPv4Cidr $cidr)) {
            continue
        }
        try {
            $spaces.Add((New-Network $cidr))
        } catch {
            continue
        }
    }
    return $spaces.ToArray()
}

function Find-AvailableSubnets {
    param(
        [object[]]$AddressSpaces,
        [object[]]$UsedSubnets,
        [int]$DesiredPrefix,
        [int]$DesiredCount
    )

    $eligibleSpaces = $AddressSpaces | Where-Object { $DesiredPrefix -gt $_.Prefix } | Sort-Object Start
    if (-not $eligibleSpaces) {
        $prefixList = ($AddressSpaces | Select-Object -ExpandProperty Prefix -Unique | Sort-Object | ForEach-Object { "/$_" }) -join ", "
        throw "Requested prefix length /$DesiredPrefix must be greater than the VNet address space prefix length(s): $prefixList"
    }

    $usedList = @($UsedSubnets | Sort-Object Start)
    $results = New-Object System.Collections.Generic.List[object]
    $step = Get-BlockSize $DesiredPrefix

    foreach ($space in $eligibleSpaces) {
        $candidate = [uint64]$space.Start
        while ($candidate -le $space.End) {
            $candidateEnd = $candidate + $step - 1
            if ($candidateEnd -gt $space.End) {
                break
            }

            $overlaps = $false
            foreach ($usedNet in $usedList) {
                if (($candidate -le $usedNet.End) -and ($candidateEnd -ge $usedNet.Start)) {
                    $overlaps = $true
                    break
                }
            }

            if ($overlaps) {
                $candidate += $step
                continue
            }

            $results.Add([pscustomobject]@{
                Start = $candidate
                End = $candidateEnd
            })
            $usedList += [pscustomobject]@{
                Start = $candidate
                End = $candidateEnd
            }

            if ($results.Count -ge $DesiredCount) {
                return $results.ToArray()
            }

            $candidate += $step
        }
    }

    return $results.ToArray()
}

if ($Help) {
    Show-Usage
    exit 0
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Err "Error: 'az' is required but was not found in PATH."
    exit 1
}

Write-Status "Checking Azure CLI access..."

function Invoke-AzCommand {
    param(
        [string[]]$Arguments,
        [string]$FailureMessage
    )

    $result = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $output = if ($result -is [System.Array]) {
        [string]::Join([Environment]::NewLine, $result)
    } else {
        [string]$result
    }
    if ($exitCode -ne 0) {
        Write-Err $FailureMessage
        if (-not [string]::IsNullOrWhiteSpace($output)) {
            Write-Err $output
        }
        exit 1
    }
    return $output
}

$vnetJson = if ($ResourceGroup) {
    Invoke-AzCommand -Arguments @(
        "network", "vnet", "show",
        "--name", $VNetName,
        "--resource-group", $ResourceGroup,
        "--output", "json",
        "--only-show-errors"
    ) -FailureMessage "Failed to read virtual network '$VNetName' in resource group '$ResourceGroup'."
} else {
    Invoke-AzCommand -Arguments @(
        "network", "vnet", "list",
        "--query", "[?name=='$VNetName']",
        "--output", "json",
        "--only-show-errors"
    ) -FailureMessage "Failed to list virtual networks. Ensure you have permission to read VNet properties."
}

if ([string]::IsNullOrWhiteSpace($vnetJson)) {
    Write-Err "Azure CLI returned no data."
    exit 1
}

try {
    $data = $vnetJson | ConvertFrom-Json
} catch {
    Write-Err "Failed to parse Azure CLI response: $($_.Exception.Message)"
    exit 1
}

$matches = if ($ResourceGroup) { @($data) } else { @($data) }
if ($matches.Count -eq 0) {
    if ($ResourceGroup) {
        Write-Err "Virtual network '$VNetName' not found in resource group '$ResourceGroup'."
    } else {
        Write-Err "Virtual network '$VNetName' not found in the current subscription."
    }
    exit 1
}

if ($matches.Count -gt 1) {
    Write-Err "Multiple virtual networks share that name. Specify the resource group."
    foreach ($item in $matches) {
        $rg = if ($item.resourceGroup) { $item.resourceGroup } else { "<unknown-rg>" }
        $name = if ($item.name) { $item.name } else { "<unknown-name>" }
        Write-Err "  - $rg/$name"
    }
    exit 1
}

$vnet = $matches[0]
$addressSpaces = Get-VNetAddressSpaces -VNet $vnet
if (-not $addressSpaces -or $addressSpaces.Count -eq 0) {
    Write-Err "The virtual network has no IPv4 address space."
    exit 1
}

$usedSubnets = @()
if ($vnet.subnets) {
    $usedSubnets = Get-SubnetNetworks -Subnets $vnet.subnets
}

Write-Status "Determining next available /$Length subnet in '$VNetName'..."

try {
    $candidates = Find-AvailableSubnets -AddressSpaces $addressSpaces -UsedSubnets $usedSubnets -DesiredPrefix $Length -DesiredCount $Amount
} catch {
    Write-Err $($_.Exception.Message)
    exit 1
}

if ($candidates.Count -lt $Amount) {
    if ($Amount -eq 1) {
        Write-Err "No available /$Length subnet was found in '$VNetName'."
    } else {
        Write-Err "Only $($candidates.Count) /$Length subnet(s) available in '$VNetName', fewer than requested ($Amount)."
    }
    exit 1
}

# DEBUG
$resultStrings = @(
    $candidates | ForEach-Object {
        "{0}/{1}" -f (ConvertFrom-UInt32 $_.Start), $Length
    }
)

if ($Amount -eq 1) {
    Write-Output "Next available subnet: $($resultStrings[0])"
} else {
    Write-Output "Next available subnets:"
    $resultStrings | ForEach-Object { Write-Output $_ }
}
