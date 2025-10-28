#!/usr/bin/env bash

set -euo pipefail

IFS=$'\n\t'

usage() {
  cat <<'EOF' >&2
Usage: findAzSubnetRange.sh --vnet-name <name> --length <prefix> [--amount <count>] [--resource-group <rg>]

Examples:
  findAzSubnetRange.sh -v my-vnet -l 24
  findAzSubnetRange.sh --vnet-name my-vnet --length 26 --resource-group my-rg --amount 3
EOF
  exit 1
}

fatal() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  local cmd=$1
  command -v "$cmd" >/dev/null 2>&1 || fatal "'$cmd' is required but was not found in PATH."
}

require_command az
require_command python3

VNET_NAME=
PREFIX_LENGTH=
AMOUNT=1
RESOURCE_GROUP=

while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--vnet-name)
      [[ $# -ge 2 ]] || fatal "Missing value for $1."
      VNET_NAME=$2
      shift 2
      ;;
    -l|--length)
      [[ $# -ge 2 ]] || fatal "Missing value for $1."
      PREFIX_LENGTH=$2
      shift 2
      ;;
    -a|--amount)
      [[ $# -ge 2 ]] || fatal "Missing value for $1."
      AMOUNT=$2
      shift 2
      ;;
    -g|--resource-group)
      [[ $# -ge 2 ]] || fatal "Missing value for $1."
      RESOURCE_GROUP=$2
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      fatal "Unknown option: $1"
      ;;
    *)
      fatal "Unexpected argument: $1"
      ;;
  esac
done

if [[ -z $VNET_NAME ]]; then
  fatal "VNet name is required. Use --vnet-name or -v."
fi

if [[ -z $PREFIX_LENGTH ]]; then
  fatal "Subnet prefix length is required. Use --length or -l."
fi

if [[ -n $RESOURCE_GROUP && $RESOURCE_GROUP =~ ^- ]]; then
  fatal "Invalid resource group value."
fi

if ! [[ $PREFIX_LENGTH =~ ^[0-9]+$ ]]; then
  fatal "Subnet prefix length must be an integer (e.g. 24, 25, 26)."
fi

if (( PREFIX_LENGTH < 0 || PREFIX_LENGTH > 32 )); then
  fatal "Subnet prefix length must be between 0 and 32."
fi

if ! [[ $AMOUNT =~ ^[0-9]+$ ]]; then
  fatal "Amount must be a positive integer."
fi

if (( AMOUNT <= 0 )); then
  fatal "Amount must be a positive integer."
fi

readonly VNET_NAME
readonly PREFIX_LENGTH
readonly AMOUNT
readonly RESOURCE_GROUP

readonly TMP_ERR=$(mktemp)
trap 'rm -f "$TMP_ERR"' EXIT

echo "Checking Azure CLI access..." >&2

if [[ -n $RESOURCE_GROUP ]]; then
  if ! VNET_JSON=$(az network vnet show \
      --name "$VNET_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --output json \
      --only-show-errors 2>"$TMP_ERR"); then
    echo "Failed to read virtual network '$VNET_NAME' in resource group '$RESOURCE_GROUP'." >&2
    cat "$TMP_ERR" >&2
    exit 1
  fi
else
  if ! VNET_JSON=$(az network vnet list \
      --query "[?name=='$VNET_NAME']" \
      --output json \
      --only-show-errors 2>"$TMP_ERR"); then
    echo "Failed to list virtual networks. Ensure you have permission to read VNet properties." >&2
    cat "$TMP_ERR" >&2
    exit 1
  fi
fi

echo "Determining next available /$PREFIX_LENGTH subnet in '$VNET_NAME'..." >&2

NEXT_SUBNET=$(VNET_JSON_CONTENT="$VNET_JSON" python3 - "$PREFIX_LENGTH" "$VNET_NAME" "$RESOURCE_GROUP" "$AMOUNT" <<'PY'
import json
import ipaddress
import sys
import os


def gather_subnets(entries):
    used = []
    for entry in entries or []:
        prefixes = []
        prefix = entry.get("addressPrefix")
        if prefix:
            prefixes.append(prefix)
        for extra in entry.get("addressPrefixes") or []:
            if extra:
                prefixes.append(extra)
        for cidr in prefixes:
            try:
                network = ipaddress.ip_network(cidr, strict=False)
            except ValueError:
                continue
            if network.version == 4:
                used.append(network)
    return used


def normalize_matches(raw):
    if isinstance(raw, list):
        return [item for item in raw if item]
    if raw:
        return [raw]
    return []


def find_next_subnets(vnet, desired_prefix, desired_count):
    address_space = vnet.get("addressSpace") or {}
    prefixes = address_space.get("addressPrefixes") or []
    ipv4_spaces = []
    for prefix in prefixes:
        try:
            network = ipaddress.ip_network(prefix, strict=False)
        except ValueError:
            continue
        if network.version == 4:
            ipv4_spaces.append(network)
    if not ipv4_spaces:
        raise ValueError("The virtual network has no IPv4 address space.")

    eligible_spaces = [space for space in ipv4_spaces if desired_prefix > space.prefixlen]
    if not eligible_spaces:
        raise ValueError(
            f"Requested prefix length /{desired_prefix} must be greater than the VNet address space prefix length(s): "
            + ", ".join(f"/{space.prefixlen}" for space in ipv4_spaces)
        )

    ipv4_spaces = eligible_spaces
    ipv4_spaces.sort(key=lambda n: int(n.network_address))
    used = [net for net in gather_subnets(vnet.get("subnets")) if net.version == 4]

    def overlaps(candidate):
        for net in used:
            if candidate.overlaps(net):
                return True
        return False

    found = []
    for space in ipv4_spaces:
        if desired_prefix < space.prefixlen:
            continue
        if desired_prefix == space.prefixlen:
            candidates = [space]
        else:
            try:
                candidates = list(space.subnets(new_prefix=desired_prefix))
            except ValueError:
                continue
        for candidate in candidates:
            if overlaps(candidate):
                continue
            found.append(candidate)
            used.append(candidate)
            if len(found) == desired_count:
                return found
    return found


def main():
    if len(sys.argv) < 4:
        sys.stderr.write("Missing arguments.\n")
        return 1

    desired_prefix = int(sys.argv[1])
    vnet_name = sys.argv[2]
    resource_group = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
    desired_count = int(sys.argv[4]) if len(sys.argv) > 4 else 1

    raw = os.environ.get("VNET_JSON_CONTENT", "").strip()
    if not raw:
        sys.stderr.write("Azure CLI returned no data.\n")
        return 1

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"Failed to parse Azure CLI response: {exc}\n")
        return 1

    matches = normalize_matches(data)
    if not matches:
        if resource_group:
            sys.stderr.write(f"Virtual network '{vnet_name}' not found in resource group '{resource_group}'.\n")
        else:
            sys.stderr.write(f"Virtual network '{vnet_name}' not found in the current subscription.\n")
        return 1

    if len(matches) > 1:
        sys.stderr.write("Multiple virtual networks share that name. Specify the resource group.\n")
        for item in matches:
            rg = item.get("resourceGroup", "<unknown-rg>")
            name = item.get("name", "<unknown-name>")
            sys.stderr.write(f"  - {rg}/{name}\n")
        return 1

    try:
        candidates = find_next_subnets(matches[0], desired_prefix, desired_count)
    except ValueError as exc:
        sys.stderr.write(f"{exc}\n")
        return 1

    if len(candidates) < desired_count:
        if desired_count == 1:
            sys.stderr.write(f"No available /{desired_prefix} subnet was found in '{vnet_name}'.\n")
        else:
            sys.stderr.write(
                f"Only {len(candidates)} /{desired_prefix} subnet(s) available in '{vnet_name}', fewer than requested ({desired_count}).\n"
            )
        return 1

    sys.stdout.write("\n".join(str(candidate) for candidate in candidates))
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
)
PY_STATUS=$?

if (( PY_STATUS != 0 )); then
  exit "$PY_STATUS"
fi

if (( AMOUNT == 1 )); then
  echo "Next available subnet: $NEXT_SUBNET"
else
  echo "Next available subnets:"
  printf '%s\n' "$NEXT_SUBNET"
fi
