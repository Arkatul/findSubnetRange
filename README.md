# findSubnetRange

Command-line helpers for finding the next available IPv4 subnet range inside an Azure virtual network.  
The original implementation is Bash; a PowerShell script is also provided for teams standardising on PowerShell.

## Prerequisites
- Azure CLI (`az`) installed and authenticated (`az login`)
- Access permissions to read the target subscription / resource group
- Bash script: requires `python3` for subnet calculations
- PowerShell script: requires PowerShell 7+ (`pwsh`)

## Bash Usage
1. Clone the repository and change into the repo directory.
2. Ensure you are logged into Azure (`az login`) and targeting the right subscription (`az account set --subscription <name-or-id>`).
3. Run the Bash script:

   ```bash
   ./findAzSubnetRange.sh -v <vnet-name> -l <prefix-length> [-g <rg-name>] [-a <count>]
   ```

   - `-v` / `--vnet-name`: Target virtual network name (required).
   - `-l` / `--length`: CIDR prefix length you want, e.g., `24` for `/24` (required).
   - `-g` / `--resource-group`: Resource group containing the VNet (optional).
   - `-a` / `--amount`: Number of subnet ranges to return (defaults to 1).

4. Review the output. A single result prints as `Next available subnet: 10.1.2.0/24`; multiple results are listed one per line.

## PowerShell Usage
The PowerShell version exposes the same parameters for teams that prefer to stay within PowerShell.

```pwsh
./find-AzSubnetRange.ps1 -VNetName <vnet-name> -Length <prefix-length> [-ResourceGroup <rg-name>] [-Amount <count>]
```

Parameter names align with the Bash flags (`-VNetName`/`-Length`/`-ResourceGroup`/`-Amount`). Output formatting matches the Bash script.

## Help
- Bash: `./findAzSubnetRange.sh -h`
- PowerShell: `./find-AzSubnetRange.ps1 -Help`
