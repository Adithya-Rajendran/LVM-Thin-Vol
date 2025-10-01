#!/bin/bash

#=======================================================================
# LVM Snapshot Helper Script
#=======================================================================

#===========================Configuration===============================
SERVERS=(
    "192.168.1.101"
    "192.168.1.102"
    "192.168.1.103"
)
SSH_USER="ubuntu"
SSH_KEY="/home/ubuntu/.ssh/id_rsa"
LOG_FILE="lvm_job_$(date +%Y%m%d).log"
#=======================================================================


BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0%m' # No Color

if [ ! -f "$SSH_KEY" ]; then
    echo -e "${RED}Error: SSH key not found at ${SSH_KEY}${NC}"
    exit 1
fi

if ! command -v parallel &> /dev/null; then
    echo -e "${RED}Error: GNU Parallel is not installed. Please install it to continue.${NC}"
    echo "  sudo apt-get install parallel"
    exit 1
fi

usage() {
    echo "A script to manage LVM snapshots in parallel on multiple servers."
    echo ""
    echo "Usage: $0 {take|revert|remove} [options]"
    echo ""
    echo "Actions:"
    echo "  take <source_volume> <snapshot_name> [size]"
    echo "      Example: $0 take /dev/vg0/root root-snap-$(date +%Y%m%d) 1G"
    echo ""
    echo "  revert <snapshot_volume>"
    echo "      Example: $0 revert /dev/vg0/root-snap-20250930"
    echo ""
    echo "  remove <snapshot_volume>"
    echo "      Example: $0 remove /dev/vg0/root-snap-20250930"
    exit 1
}

ACTION=$1
shift # Shift command-line arguments

case $ACTION in
    take)
        SOURCE_VOL=$1
        SNAP_NAME=$2
        SIZE=$3

        if [ -z "$SOURCE_VOL" ] || [ -z "$SNAP_NAME" ]; then
            echo -e "${RED}Error: Missing arguments for 'take' action.${NC}"; usage
        fi

        CMD="sudo lvcreate -s -n \"$SNAP_NAME\" \"$SOURCE_VOL\""
        [ -n "$SIZE" ] && CMD="sudo lvcreate -s -L \"$SIZE\" -n \"$SNAP_NAME\" \"$SOURCE_VOL\""
        ;;
    revert)
        SNAP_VOL=$1
        if [ -z "$SNAP_VOL" ]; then
            echo -e "${RED}Error: Missing snapshot volume path for 'revert' action.${NC}"; usage
        fi
        CMD="sudo lvconvert --merge \"$SNAP_VOL\" && sudo reboot"
        ;;
    remove)
        SNAP_VOL=$1
        if [ -z "$SNAP_VOL" ]; then
            echo -e "${RED}Error: Missing snapshot volume path for 'remove' action.${NC}"; usage
        fi
        CMD="sudo lvremove -y \"$SNAP_VOL\""
        ;;
    *)
        usage
        ;;
esac

# This function will be executed by `parallel` for each server.
run_on_remote() {
    server="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$SSH_KEY" "${SSH_USER}@${server}" "$CMD"
}

# Export the function and variables so `parallel` subshells can access them
export -f run_on_remote
export SSH_USER SSH_KEY CMD

echo -e "${BLUE}Dispatching action '${ACTION}' to all servers using GNU Parallel...${NC}"
echo -e "A detailed log will be created at: ${BLUE}${LOG_FILE}${NC}"

# Use printf to safely pipe server names to parallel, one per line.
# --tag: Prepends output lines with the server name.
# --joblog: Creates a detailed log of each job's status.
# --bar: Shows a progress bar.
# --nonall: Exits with a non-zero status if any job fails.
parallel --bar --tag --joblog "$LOG_FILE" --nonall run_on_remote {} ::: "${SERVERS[@]}"

PARALLEL_EXIT_CODE=$?

echo "-------------------------------------"
if [ "$PARALLEL_EXIT_CODE" -eq 0 ]; then
    echo -e "${GREEN} Success! All operations completed without errors.${NC}"
else
    echo -e "${RED} Failures detected! Check the output above for details.${NC}"
    echo "The following servers reported an error (Exit Code != 0):"
    
    # The log is tab-separated. Column 7 is Exitval, Column 9 is Command (which includes the server name).
    awk 'NR > 1 && $7 != 0 {print "  - " $NF}' "$LOG_FILE"
    
    echo -e "\nReview the full output and check the log file '${LOG_FILE}' for more information."
    exit 1
fi