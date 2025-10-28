# findSubnetRange

PowerShell utility for finding the next available IPv4 subnet range inside an Azure virtual network.

## Prerequisites
- Azure CLI (`az`) installed and authenticated (`az login`)
- PowerShell 7+ (`pwsh`) available on your PATH
- Access permissions to read the target subscription / resource group

## How To Use
1. Clone the repository and change into the repo directory.
2. Ensure you are logged into Azure (`az login`) and have the correct subscription selected (`az account set --subscription <name-or-id>`).
3. Run the script with the required parameters:

   ```pwsh
   ./find-AzSubnetRange.ps1 -VNetName <vnet-name> -Length <prefix-length> [-ResourceGroup <rg-name>] [-Amount <count>]
   ```

   - `-VNetName` (`-v`): Name of the target virtual network (required).
   - `-Length` (`-l`): CIDR prefix length for the subnet you want, e.g., `24` for `/24` (required).
   - `-ResourceGroup` (`-g`): Resource group containing the VNet. Provide this when multiple VNets share the same name (optional).
   - `-Amount` (`-a`): Number of subnet ranges to return (defaults to 1).

4. Review the output. A single result prints as `Next available subnet: 10.1.2.0/24`; multiple results are listed one per line.

## Help
Run `./find-AzSubnetRange.ps1 -Help` (or `-h`) to print usage details.

