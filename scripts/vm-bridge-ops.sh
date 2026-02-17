#!/bin/bash
#
# Script to automatically create a Linux bridge on the interface that has the default route
# This script will:
# 1. Identify the interface with the default route
# 2. Create a bridge and attach that interface to it
# 3. Configure the bridge to use DHCP
#
# Usage: sudo ./create-bridge.sh [OPTION]
#        --force     Skip all confirmation prompts
#        --cleanup   Remove the bridge configuration
#
# Environment variables:
#        BRIDGE_NAME The name of the bridge to create (default: br0)

#############################
# Utility Functions
#############################

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Function to detect the default interface
detect_default_interface() {
  local DEFAULT_INTERFACE=$(ip route | grep default | head -n1 | awk '{print $5}')
  echo "$DEFAULT_INTERFACE"
}

# Function to safely get IP information for an interface
get_ip_info() {
  local INTERFACE="$1"
  if [ -n "$INTERFACE" ]; then
    ip -o -4 addr show dev "$INTERFACE" 2>/dev/null | awk '{print $4}' || echo "None"
  else
    echo "None"
  fi
}

# Function to get gateway information
get_gateway_info() {
  ip route | grep default | head -n1 | awk '{print $3}' || echo "None"
}

# Function to detect network manager type
detect_network_manager() {
  if command_exists nmcli && systemctl is-active --quiet NetworkManager; then
    echo "networkmanager"
  elif [ -d /etc/netplan ]; then
    echo "netplan"
  else
    echo "unsupported"
  fi
}

# Function to handle user confirmation
confirm_action() {
  local MESSAGE="$1"
  local INSTRUCTIONS="$2"

  if [ "$FORCE_MODE" = false ]; then
    echo "WARNING: $MESSAGE"
    echo "If you're connected via SSH on this interface, you might lose connectivity."
    echo "Make sure you have an alternative way to access the system if needed."
    read -p "Continue? (y/n): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Operation paused before activation."
      echo "$INSTRUCTIONS"
      return 1
    fi
  fi
  return 0
}

#############################
# Bridge Check Functions
#############################

# Function to check if bridge already exists and is properly configured
check_bridge_exists() {
  local BRIDGE_NAME="$1"
  local DEFAULT_INTERFACE="$2"

  # Check if the bridge already exists
  if ip link show dev $BRIDGE_NAME >/dev/null 2>&1; then
    echo "Bridge $BRIDGE_NAME already exists."

    # First, check if the bridge has an IP address (is functioning)
    if ip -4 addr show dev $BRIDGE_NAME | grep -q 'inet '; then
      echo "Bridge $BRIDGE_NAME is up and has an IP address."

      # Check if it's a bridge to our default interface
      # There are two ways to consider a bridge properly configured:
      # 1. The default route is through the bridge (bridge became the default interface)
      # 2. The specific physical interface we want is enslaved to the bridge

      if ip route | grep default | grep -q $BRIDGE_NAME; then
        echo "Bridge $BRIDGE_NAME is already the default interface. No action needed."
        echo "You can use bridge=$BRIDGE_NAME in your VM configuration."
        return 0  # Bridge exists and is properly configured
      fi

      # Check if our desired interface is enslaved to the bridge
      if bridge link show | grep -q "$DEFAULT_INTERFACE.*master $BRIDGE_NAME"; then
        echo "Bridge $BRIDGE_NAME is already configured with $DEFAULT_INTERFACE. No action needed."
        echo "You can use bridge=$BRIDGE_NAME in your VM configuration."
        return 0  # Bridge exists and is properly configured
      fi

      # If we get here, the bridge exists but isn't configured with our interface
      echo "Bridge exists but is not configured with $DEFAULT_INTERFACE."
      echo "Consider running with --cleanup first to remove the existing bridge."
      return 2  # Bridge exists but is not properly configured
    else
      echo "Bridge $BRIDGE_NAME exists but doesn't have an IP address."
      echo "Consider running with --cleanup first to remove the existing bridge."
      return 2  # Bridge exists but is not properly configured
    fi
  fi

  return 1  # Bridge does not exist
}

#############################
# NetworkManager Functions
#############################

# Function to extract physical interface from slave connection name
extract_interface_from_slave() {
  local SLAVE_CONNECTION="$1"
  local BRIDGE_NAME="$2"

  if [ -n "$SLAVE_CONNECTION" ]; then
    # Extract the interface name from the connection name (format: bridge-slave-INTERFACE-BRIDGE_NAME)
    local PHYSICAL_INTERFACE=$(echo "$SLAVE_CONNECTION" | sed -E "s/bridge-slave-(.*)-$BRIDGE_NAME/\\1/")
    echo "$PHYSICAL_INTERFACE"
  fi
}

# Function to find a suitable connection for an interface
find_original_connection() {
  local INTERFACE="$1"

  if [ -n "$INTERFACE" ]; then
    # Look for a regular ethernet connection for this interface
    # Filter out bridge, slave, virbr, docker and other virtual connection types
    local ORIGINAL_CONN=$(nmcli -g NAME,DEVICE con show |
                 grep "$INTERFACE" |
                 grep -v "bridge\|slave\|virbr\|docker\|veth\|tun\|tap" |
                 head -n1 |
                 cut -d: -f1)
    echo "$ORIGINAL_CONN"
  fi
}

# Function to restore connectivity to a physical interface
restore_interface_connectivity() {
  local INTERFACE="$1"

  if [ -n "$INTERFACE" ]; then
    local ORIGINAL_CONN=$(find_original_connection "$INTERFACE")

    if [ -n "$ORIGINAL_CONN" ]; then
      echo "Activating original connection: $ORIGINAL_CONN"
      nmcli con up "$ORIGINAL_CONN" || true
      # Give it time to establish
      sleep 3
      return 0
    else
      echo "No suitable original connection found for $INTERFACE"
      echo "Creating a temporary DHCP connection to maintain connectivity"
      nmcli con add type ethernet con-name "temp-$INTERFACE" ifname "$INTERFACE" ipv4.method auto
      nmcli con up "temp-$INTERFACE" || true
      # Give it time to establish
      sleep 3
      return 0
    fi
  fi
  return 1
}

# Function to clean up NetworkManager configuration
cleanup_networkmanager() {
  echo "Cleaning up NetworkManager bridge configuration..."

  # Find bridge-slave connections for our specific bridge
  SLAVE_CONNECTIONS=$(nmcli -g NAME con show | grep "bridge-slave-.*-$BRIDGE_NAME" || true)

  # First, extract the physical interface name from the slave connection name
  if [ -n "$SLAVE_CONNECTIONS" ]; then
    # Take the first slave connection if there are multiple
    FIRST_SLAVE=$(echo "$SLAVE_CONNECTIONS" | head -n1)
    # Extract the interface name
    DEFAULT_INTERFACE=$(extract_interface_from_slave "$FIRST_SLAVE" "$BRIDGE_NAME")

    if [ -n "$DEFAULT_INTERFACE" ]; then
      echo "Extracted physical interface from slave connection: $DEFAULT_INTERFACE"
    fi
  fi

  # If we couldn't extract from connection name, try other methods
  if [ -z "$DEFAULT_INTERFACE" ]; then
    # Try to detect which interface is enslaved to the bridge
    DEFAULT_INTERFACE=$(bridge link show | grep $BRIDGE_NAME | awk '{print $2}' | head -n1)
    if [ -z "$DEFAULT_INTERFACE" ]; then
      echo "Warning: Could not identify the physical interface, proceeding anyway."
    else
      echo "Detected physical interface: $DEFAULT_INTERFACE"
    fi
  fi

  # Try to find and activate the original connection for default interface BEFORE removing the bridge
  restore_interface_connectivity "$DEFAULT_INTERFACE"

  # Now down and delete all slave connections
  for CONN in $SLAVE_CONNECTIONS; do
    echo "Removing slave connection: $CONN"
    nmcli con down "$CONN" 2>/dev/null || true
    nmcli con delete "$CONN" 2>/dev/null || true
  done

  # Down and delete the bridge connection
  echo "Removing bridge connection: bridge-$BRIDGE_NAME"
  nmcli con down "bridge-$BRIDGE_NAME" 2>/dev/null || true
  nmcli con delete "bridge-$BRIDGE_NAME" 2>/dev/null || true

  echo "NetworkManager cleanup complete."
}

adapt_bridge_mtu() {
  echo "Checking connection MTU ..."
  nmcon=$(nmcli -t -f NAME c s | grep -- "-${BRIDGE_NAME}$" || true)
  for con in $nmcon; do
    cur_mtu=$(nmcli -g 802-3-ethernet.mtu connection show "$con")
    if [ "$cur_mtu" -gt "$NODES_MTU" ]; then
       echo "Current MTU $cur_mtu is greater than desired $NODES_MTU, not changing."
       return
    fi
    if [ "$cur_mtu" != "$NODES_MTU" ]; then
       echo "Modifying connection '$con' mtu to $NODES_MTU from current $cur_mtu"
       nmcli con modify "$con" mtu "$NODES_MTU" || true
       nmcli con up "$con" || true 
    else
       echo "No need to modify connection '$con' MTU (already $NODES_MTU)"
    fi
  done
}

# Function to configure using NetworkManager
configure_with_networkmanager() {
  echo "Creating bridge with NetworkManager..."

  # Create the bridge
  nmcli con add type bridge con-name bridge-$BRIDGE_NAME ifname $BRIDGE_NAME
  nmcli con mod bridge-$BRIDGE_NAME bridge.stp no

  # Get the current connection name for the interface
  CONN_NAME=$(nmcli -g NAME,DEVICE connection show --active | grep "$DEFAULT_INTERFACE" | cut -d: -f1)

  if [ -z "$CONN_NAME" ]; then
    echo "Warning: Could not find active connection for $DEFAULT_INTERFACE"
    # Try to get any connection for this device
    CONN_NAME=$(nmcli -g NAME,DEVICE connection show | grep "$DEFAULT_INTERFACE" | head -n1 | cut -d: -f1)

    if [ -z "$CONN_NAME" ]; then
      echo "Error: No connection found for $DEFAULT_INTERFACE"
      exit 1
    fi
  fi

  echo "Found connection: $CONN_NAME for interface $DEFAULT_INTERFACE"

  # Configure bridge for DHCP only
  echo "Configuring bridge to use DHCP"
  nmcli con mod bridge-$BRIDGE_NAME ipv4.method auto

  # Create the slave connection with bridge name in the connection name
  nmcli con add type bridge-slave con-name bridge-slave-"$DEFAULT_INTERFACE-$BRIDGE_NAME" ifname "$DEFAULT_INTERFACE" master $BRIDGE_NAME

  if [ "$NODES_MTU" != "1500" ] ; then
     nmcli con modify bridge-$BRIDGE_NAME mtu $NODES_MTU
     nmcli con modify bridge-slave-"$DEFAULT_INTERFACE-$BRIDGE_NAME" mtu $NODES_MTU
  fi

  echo "NetworkManager configurations created. Ready to activate."

  # Ask for confirmation before modifying network
  INSTRUCTIONS="To activate manually, run:
  sudo nmcli con up bridge-$BRIDGE_NAME
  sudo nmcli con down \"$CONN_NAME\"
  sudo nmcli con up bridge-slave-$DEFAULT_INTERFACE-$BRIDGE_NAME"

  confirm_action "The next step will change your network configuration." "$INSTRUCTIONS" || exit 0

  echo "Activating bridge..."

  # Activate the bridge first
  nmcli con up bridge-$BRIDGE_NAME

  # Wait a bit for the bridge to initialize
  sleep 5

  # Deactivate the original connection
  nmcli con down "$CONN_NAME"

  # Activate the slave connection
  nmcli con up bridge-slave-"$DEFAULT_INTERFACE-$BRIDGE_NAME"

  echo "Bridge activation complete."
}

#############################
# Netplan Functions
#############################

# Function to clean up Netplan configuration
cleanup_netplan() {
  echo "Cleaning up Netplan bridge configuration..."

  # First, restore backups if they exist
  NETPLAN_BACKUPS=$(find /etc/netplan -name "*.yaml.bak")
  for BACKUP in $NETPLAN_BACKUPS; do
    ORIGINAL="${BACKUP%.bak}"
    echo "Restoring $BACKUP to $ORIGINAL"
    cp "$BACKUP" "$ORIGINAL"
  done

  # Then apply the restored configuration first to ensure connectivity
  echo "Applying restored Netplan configuration..."
  netplan apply

  # Give it time to establish
  sleep 3

  # Now, remove our bridge configuration file
  if [ -f "/etc/netplan/99-bridge-$BRIDGE_NAME.yaml" ]; then
    echo "Removing /etc/netplan/99-bridge-$BRIDGE_NAME.yaml"
    rm "/etc/netplan/99-bridge-$BRIDGE_NAME.yaml"
  fi

  # Remove backup files
  for BACKUP in $NETPLAN_BACKUPS; do
    echo "Removing backup: $BACKUP"
    rm "$BACKUP"
  done

  echo "Netplan cleanup complete."
}

# Function to configure using Netplan
configure_with_netplan() {
  echo "Creating bridge with Netplan..."

  # Create a backup of existing configuration
  NETPLAN_FILES=$(find /etc/netplan -name "*.yaml")
  for file in $NETPLAN_FILES; do
    cp "$file" "$file.bak"
    echo "Backed up $file to $file.bak"
  done

  # Create new configuration file
  cat > /etc/netplan/99-bridge-$BRIDGE_NAME.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $DEFAULT_INTERFACE:
      dhcp4: no
      mtu: $NODES_MTU
  bridges:
    $BRIDGE_NAME:
      interfaces: [$DEFAULT_INTERFACE]
      dhcp4: yes
      mtu: $NODES_MTU
EOF

  echo "Netplan configuration created."

  # Ask for confirmation before modifying network
  INSTRUCTIONS="To activate manually, run:
  sudo netplan try
  sudo netplan apply"

  confirm_action "The next step will change your network configuration." "$INSTRUCTIONS" || exit 0

  echo "Trying new configuration (will automatically revert if not confirmed within 120 seconds)..."
  netplan try
  echo "Configuration applied successfully."
}

#############################
# Main Functions
#############################

# Function to handle cleanup mode
do_cleanup() {
  echo "Cleanup mode enabled. Bridge configuration will be removed."
  echo "Using bridge name: $BRIDGE_NAME"

  # Detect the interface with the default route (for reference in cleanup)
  DEFAULT_INTERFACE=$(detect_default_interface)

  if [ -z "$DEFAULT_INTERFACE" ]; then
    echo "Warning: Could not identify the default interface, continuing anyway."
  else
    echo "Default route uses interface: $DEFAULT_INTERFACE"
    echo "Current IP configuration: $(get_ip_info "$DEFAULT_INTERFACE"), Gateway: $(get_gateway_info)"
  fi

  # Detect which network manager is in use
  NETWORK_MANAGER=$(detect_network_manager)

  case "$NETWORK_MANAGER" in
    networkmanager)
      echo "NetworkManager detected"
      cleanup_networkmanager
      ;;
    netplan)
      echo "Netplan detected"
      cleanup_netplan
      ;;
    *)
      echo "Error: Unsupported network configuration system"
      echo "This script only supports NetworkManager and Netplan"
      exit 1
      ;;
  esac

  echo "Bridge cleanup complete."
}

# Function to handle create mode
do_create() {
  echo "Using bridge name: $BRIDGE_NAME"

  # Detect the default interface
  DEFAULT_INTERFACE=$(detect_default_interface)

  if [ -z "$DEFAULT_INTERFACE" ]; then
    echo "Error: Could not identify the default interface"
    exit 1
  fi

  echo "Default route uses interface: $DEFAULT_INTERFACE"
  echo "Current IP configuration: $(get_ip_info "$DEFAULT_INTERFACE"), Gateway: $(get_gateway_info)"

  # Check if the bridge already exists
  check_bridge_exists "$BRIDGE_NAME" "$DEFAULT_INTERFACE"
  BRIDGE_CHECK_RESULT=$?

  if [ $BRIDGE_CHECK_RESULT -eq 0 ]; then
    adapt_bridge_mtu
    # Bridge exists and is properly configured
    exit 0
  elif [ $BRIDGE_CHECK_RESULT -eq 2 ]; then
    # Bridge exists but is not properly configured
    exit 1
  fi

  # Detect which network manager is in use
  NETWORK_MANAGER=$(detect_network_manager)

  case "$NETWORK_MANAGER" in
    networkmanager)
      echo "NetworkManager detected"
      configure_with_networkmanager
      ;;
    netplan)
      echo "Netplan detected"
      configure_with_netplan
      ;;
    *)
      echo "Error: Unsupported network configuration system"
      echo "This script only supports NetworkManager and Netplan"
      exit 1
      ;;
  esac

  echo "Bridge setup complete."
  echo "You can now use bridge=$BRIDGE_NAME in your VM configuration."
}

#############################
# Main Script Execution
#############################

# Process command line arguments and environment variables
FORCE_MODE=false
CLEANUP_MODE=false
BRIDGE_NAME=${BRIDGE_NAME:-br0}  # Default to br0 if not set
NODES_MTU=${NODES_MTU:-"1500"}

if [ "$1" = "--force" ]; then
  FORCE_MODE=true
  echo "Force mode enabled. All confirmations will be skipped."
elif [ "$1" = "--cleanup" ]; then
  CLEANUP_MODE=true
fi

# Must run as root
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root"
  exit 1
fi

# Main execution flow starts here
if [ "$CLEANUP_MODE" = true ]; then
  do_cleanup
else
  do_create
fi
