#!/bin/bash
# DiskHopper - Fast, Safe Disk Partition Migration Tool for Linux
# Version: 1.0
# Author: Chris Hawthorne, 2025
# License: MIT
# https://github.com/kj7ppk/DiskHopper

RSYNC_OPTS="-aAXH --whole-file --inplace --no-compress --info=stats2"
TEMP_MOUNT_BASE="/mnt/migratetemp"
TEMP_MOUNTS=()

LOG_ENABLED=false
LOG_FILE=""

# === Color Codes ===
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

#############################################
# Clean up temporary mounts and directories #
#############################################
diskhopper_cleanup() {
    echo -e "\n${BLUE}Cleaning up temporary mounts...${NC}"
    echo -e "${YELLOW}Mount points to unmount:${NC} ${TEMP_MOUNTS[*]}"
    
    for mnt in "${TEMP_MOUNTS[@]}"; do
        echo -e "${YELLOW}Unmounting $mnt...${NC}"
        sudo umount "$mnt" 2>/dev/null
        sudo rmdir "$mnt" 2>/dev/null
    done

    if [ -d "$TEMP_MOUNT_BASE" ]; then
        if [ -z "$(ls -A "$TEMP_MOUNT_BASE")" ]; then
            echo -e "${GREEN}✅ Temp mount base $TEMP_MOUNT_BASE is empty. Removing...${NC}"
            sudo rmdir "$TEMP_MOUNT_BASE"
        else
            echo -e "${RED}⚠️ Warning:${NC} $TEMP_MOUNT_BASE is not empty after cleanup."
            echo -e "${YELLOW}Manual cleanup recommended:${NC} sudo rm -rf $TEMP_MOUNT_BASE/*"
        fi
    fi
}

trap diskhopper_cleanup SIGINT

###################
# Logging Handler #
###################
diskhopper_log() {
    if $LOG_ENABLED; then
        echo -e "$@" >> "$LOG_FILE"
    fi
}

##################################
# Get OS disks to exclude them   #
##################################
diskhopper_get_os_disks() {
    ROOT_DEV=$(findmnt -n -o SOURCE /)
    EFI_DEV=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null)
    ROOT_DISK=$(lsblk -no PKNAME "$ROOT_DEV")
    EFI_DISK=$(lsblk -no PKNAME "$EFI_DEV" 2>/dev/null)

    echo "$ROOT_DISK $EFI_DISK" | tr ' ' '\n' | sort -u | grep -v '^$'
}

##################################
# Get SMART health for a disk    #
##################################
diskhopper_get_smart_status() {
    local disk="$1"
    if smartctl -H "$disk" &>/dev/null; then
        health=$(smartctl -H "$disk" | grep "SMART overall-health" | awk '{print $NF}')
        case "$health" in
            PASSED) echo "✅" ;;
            FAILED) echo "❌" ;;
            *) echo "⚠️" ;;
        esac
    else
        echo "⚠️"
    fi
}

diskhopper_truncate_text() {
    local text="$1"
    local length="$2"
    if [ ${#text} -gt $length ]; then
        echo "${text:0:$(($length - 3))}..."
    else
        printf "%-${length}s" "$text"
    fi
}

#################################################
# List available partitions excluding OS disks  #
#################################################
diskhopper_list_partitions() {
    OS_DISKS=($(diskhopper_get_os_disks))
    PARTITION_LIST=()

    echo -e "${BLUE}SMART Health Legend:${NC} ✅ Healthy   ⚠️ Unknown   ❌ Failed"
    echo -e "${BLUE}========== Available Partitions (Excluding OS Disk) ==========${NC}"
    printf "${BLUE}%-4s| %-15s| %-6s| %-17s| %-22s| %-15s| %-22s${NC}\n" \
        "#" "Partition" "Size" "Model" "Mount Point" "Usage" "Host Disk (Type)"
    printf "${BLUE}%s\n${NC}" "----|-----------------|--------|-------------------|------------------------|----------------|------------------------"

    local count=1
    while read -r line; do
        eval "$line"
        PARTITION="/dev/$NAME"
        PARENT="/dev/$PKNAME"

        if printf '%s\n' "${OS_DISKS[@]}" | grep -q -w "$PKNAME"; then continue; fi
        if [ -z "$PKNAME" ]; then continue; fi

        TRANSPORT=$(lsblk -dn -o TRAN "$PARENT")
        [ -z "$TRANSPORT" ] && TRANSPORT="unknown"
        SMART_ICON=$(diskhopper_get_smart_status "$PARENT")

        MOUNT_POINT=$(lsblk -nr -o MOUNTPOINT "$PARTITION" | grep '/' || echo "UNMOUNTED")
        SHORT_MOUNT="$MOUNT_POINT"
        if [[ "$MOUNT_POINT" =~ ^/srv/dev-disk-by-uuid- ]]; then
            UUID=$(echo "$MOUNT_POINT" | sed 's|/srv/dev-disk-by-uuid-||')
            SHORT_MOUNT="/srv/uuid-${UUID:0:8}...${UUID: -8}"
        elif [[ ${#MOUNT_POINT} -gt 22 ]]; then
            SHORT_MOUNT="${MOUNT_POINT:0:19}..."
        fi

        PARTITION_SIZE=$(lsblk -n -o SIZE "$PARTITION")

        if [[ "$MOUNT_POINT" != "UNMOUNTED" ]]; then
            USAGE_INFO=$(df -h --output=used,size,pcent "$MOUNT_POINT" | tail -1 | awk '{print $1" / "$2" ("$3")"}')
            MOUNT_COLOR=$GREEN
        else
            USAGE_INFO="N/A"
            MOUNT_COLOR=$YELLOW
        fi

        MODEL=$(udevadm info --query=all --name="$PARENT" | grep "ID_MODEL=" | cut -d= -f2)
        [[ -z "$MODEL" ]] && MODEL="Unknown"

        printf "%-4s| %-15s| %-6s| %-17s| ${MOUNT_COLOR}%-22s${NC}| %-15s| %-22s\n" \
            "$count" "$(diskhopper_truncate_text "$PARTITION" 15)" "$(diskhopper_truncate_text "$PARTITION_SIZE" 6)" \
            "$(diskhopper_truncate_text "$MODEL" 17)" "$(diskhopper_truncate_text "$SHORT_MOUNT" 22)" \
            "$(diskhopper_truncate_text "$USAGE_INFO" 15)" "$(diskhopper_truncate_text "$PARENT (${TRANSPORT^^}) $SMART_ICON" 22)"

        PARTITION_LIST+=("$PARTITION")
        ((count++))
    done < <(lsblk -P -o NAME,SIZE,MODEL,PKNAME | grep -v "loop")

    export PARTITION_LIST
}

diskhopper_select_partitions() {
    local prompt=$1
    local result_var=$2
    read -p "Select $prompt partition numbers (space-separated): " -a selection
    eval "$result_var=(${selection[@]})"
}

##############################################################
# Ensure the partition is mounted and return the mount point #
##############################################################
diskhopper_ensure_mounted() {
    local partition=$1
    local index=$2
    local temp_mount="$TEMP_MOUNT_BASE/partition$index"

    sudo mkdir -p "$temp_mount"
    sudo mount "$partition" "$temp_mount" || {
        echo -e "${RED}❌ Failed to mount $partition. Exiting.${NC}"
        exit 1
    }

    echo "$temp_mount"
}

############################################
# Main migration function using rsync      #
############################################
diskhopper_migrate_data() {
    local total_bytes_moved=0

    for src in "${SOURCE_MOUNTS[@]}"; do
        echo -e "\n📂 ${BLUE}Processing source:${NC} $src"
        diskhopper_log "Processing source: $src"

        mapfile -t items < <(find "$src" -mindepth 1 -maxdepth 1)

        if [ ${#items[@]} -eq 0 ]; then
            echo -e "${YELLOW}⚠️  No files to transfer in $src${NC}"
            diskhopper_log "No files to transfer in $src"
            continue
        fi

        for item in "${items[@]}"; do
            dst="${DEST_MOUNTS[$((RANDOM % ${#DEST_MOUNTS[@]}))]}"
            echo -e "➡️  ${BLUE}Copying${NC} $(basename "$item") ${BLUE}to${NC} $dst"
            diskhopper_log "Copying $(basename "$item") to $dst"

            RSYNC_OUTPUT=$(rsync $RSYNC_OPTS "$item" "$dst"/)
            result=$?

            echo "$RSYNC_OUTPUT"

            transferred_bytes=$(echo "$RSYNC_OUTPUT" | grep "Total transferred file size:" | awk '{print $5}')

            if [[ "$transferred_bytes" =~ ^[0-9]+$ ]]; then
                total_bytes_moved=$((total_bytes_moved + transferred_bytes))
            fi

            if [ $result -eq 0 ]; then
                echo -e "${GREEN}✅ rsync OK, removing source:${NC} $(basename "$item")"
                diskhopper_log "✅ rsync OK, removing source: $(basename "$item")"
                rm -rf "$item"
            else
                echo -e "${RED}❌ rsync failed:${NC} $item"
                diskhopper_log "❌ rsync failed: $item"
                echo -e "${YELLOW}Cleaning up failed destination...${NC}"
                rm -rf "$dst/$(basename "$item")"
                diskhopper_log "Cleaned up destination: $dst/$(basename "$item")"
            fi
        done
    done

    total_gb_moved=$(awk "BEGIN {printf \"%.2f\", $total_bytes_moved / (1024*1024*1024)}")
    echo -e "\n${BLUE}Total Data Transferred:${NC} ${GREEN}${total_gb_moved} GB${NC}"
    diskhopper_log "Total Data Transferred: ${total_gb_moved} GB"
}

##########################################
# Main Program Start - DiskHopper 🐇💽    #
##########################################
clear
echo -e "${BLUE}=== DiskHopper - Partition Data Migration Tool ===${NC}"

LOG_DIR="$(pwd)"
LOG_FILE="$LOG_DIR/migration-log-$(date +%F_%H-%M-%S).txt"

echo
echo -e "${BLUE}Enable logging to file? (y/n):${NC}"
echo -e "Logs will be saved to: ${YELLOW}${LOG_FILE}${NC}"
read -p "> " LOG_CHOICE

if [[ "$LOG_CHOICE" == "y" ]]; then
    LOG_ENABLED=true
    echo "Logging to $LOG_FILE"
    echo "DiskHopper Migration Log - $(date)" > "$LOG_FILE"
fi

diskhopper_list_partitions
diskhopper_select_partitions "SOURCE" SOURCE_SELECTION
diskhopper_select_partitions "DESTINATION" DEST_SELECTION

SOURCE_MOUNTS=()
for num in "${SOURCE_SELECTION[@]}"; do
    index=$((num-1))
    partition="${PARTITION_LIST[$index]}"
    mount_point=$(diskhopper_ensure_mounted "$partition" "$index")

    echo -e "${GREEN}Mounted: $partition -> $mount_point${NC}"

    SOURCE_MOUNTS+=("$mount_point")
    TEMP_MOUNTS+=("$mount_point")
    echo -e "${YELLOW}TEMP_MOUNTS now:${NC} ${TEMP_MOUNTS[*]}"
done

DEST_MOUNTS=()
for num in "${DEST_SELECTION[@]}"; do
    index=$((num-1))
    partition="${PARTITION_LIST[$index]}"
    mount_point=$(diskhopper_ensure_mounted "$partition" "$index")

    echo -e "${GREEN}Mounted: $partition -> $mount_point${NC}"

    DEST_MOUNTS+=("$mount_point")
    TEMP_MOUNTS+=("$mount_point")
    echo -e "${YELLOW}TEMP_MOUNTS now:${NC} ${TEMP_MOUNTS[*]}"
done

echo -e "${BLUE}✅ Sources:${NC} ${SOURCE_MOUNTS[*]}"
echo -e "${BLUE}✅ Destinations:${NC} ${DEST_MOUNTS[*]}"
echo -e "${BLUE}✅ Temp mounts to cleanup:${NC} ${TEMP_MOUNTS[*]}"

read -p "Ready to start migration? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    echo -e "${RED}Exiting.${NC}"
    diskhopper_cleanup
    exit 0
fi

diskhopper_migrate_data

echo -e "\n${GREEN}✅ Migration complete!${NC}"
diskhopper_log "✅ Migration complete!"

diskhopper_cleanup
