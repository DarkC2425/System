#!/bin/bash

#==============================================================================
# Linux System Monitor Script
#
# Monitors CPU, Memory, Disk I/O, Network I/O, Processes, and GPU (NVIDIA).
# Provides real-time text-based graphs and statistics.
#==============================================================================

# === Configuration Constants ===
readonly HEIGHT=20            # Graph height in lines
readonly WIDTH=120            # Graph width in characters
readonly DELAY=1              # Update delay in seconds
readonly WARNING_THRESHOLD=85 # Usage percentage threshold for audio warning
readonly MAX_PROCESSES=35     # Max processes to show in process view

# === ANSI Color Codes (Foreground) ===
readonly COLOR_RESET='\e[0m'
readonly COLOR_GREEN='\e[32m'
readonly COLOR_YELLOW='\e[33m'
readonly COLOR_BLUE='\e[34m'
readonly COLOR_MAGENTA='\e[35m'
readonly COLOR_CYAN='\e[36m'
readonly COLOR_WHITE='\e[37m'
readonly COLOR_BRIGHT_BLACK='\e[90m' # Grey
readonly COLOR_BRIGHT_RED='\e[91m'
readonly COLOR_BRIGHT_GREEN='\e[92m'
readonly COLOR_BRIGHT_YELLOW='\e[93m'
readonly COLOR_BRIGHT_BLUE='\e[94m'
readonly COLOR_BRIGHT_MAGENTA='\e[95m'
readonly COLOR_BRIGHT_CYAN='\e[96m'
readonly COLOR_BRIGHT_WHITE='\e[97m'

# === Helper Functions ===

# --- Terminal Control ---
hide_cursor() { tput civis; }
show_cursor() { tput cnorm; }
clear_screen() { tput clear; }
save_cursor() { tput sc; }
restore_cursor() { tput rc; }
move_cursor() { tput cup "$1" "$2"; } # Usage: move_cursor row col

# --- Graph Drawing ---

# Draw a single percentage-based graph
# Usage: draw_graph_percent graph_data_array_name color_code
draw_graph_percent() {
    local -n graph_data_ref=$1 # Use nameref to pass array by name
    local color_escape=$2
    local graph_output=()
    local scale=$((100 / HEIGHT))
    local row_value

    (( scale == 0 )) && scale=1 # Avoid division by zero if HEIGHT > 100

    # Build graph lines from top (100%) down
    for ((row_value = 100; row_value > 0; row_value -= scale)); do
        local line=""
        for ((i = 0; i < WIDTH; i++)); do
            # Default to 0 if index doesn't exist yet
            local current_val=${graph_data_ref[i]:-0}
            if (( current_val > row_value )); then
                line+="${color_escape}█${COLOR_RESET}"
            else
                line+=" "
            fi
        done
        # Ensure row_value doesn't go below 0 for display
        local display_row=$(( row_value > 0 ? row_value : 0 ))
        graph_output+=("$(printf "%3d | %b" "$display_row" "$line")")
    done

    # Add bottom border and timestamp
    graph_output+=("    +$(printf -- '-%.0s' $(seq 0 $WIDTH))")
    graph_output+=("    $(printf "%*s" $((WIDTH / 2 + 10)) "$(date '+%Y-%m-%d %H:%M:%S')")")

    # Print the generated graph output
    printf '%s\n' "${graph_output[@]}"
}

# Draw two overlapping graphs with dynamic scaling
# Usage: draw_graph_overlap graph1_arr_name graph2_arr_name title1 title2 color1 color2 overlap_color
draw_graph_overlap() {
    local -n graph1_ref=$1
    local -n graph2_ref=$2
    local title_1=$3
    local title_2=$4
    local color_1=$5
    local color_2=$6
    local color_3=$7 # Overlap color
    local graph_output=()
    local max_value=0
    local i row

    # Find the peak value across both datasets for scaling
    for ((i = 0; i < WIDTH; i++)); do
        (( ${graph1_ref[i]:-0} > max_value )) && max_value=${graph1_ref[i]:-0}
        (( ${graph2_ref[i]:-0} > max_value )) && max_value=${graph2_ref[i]:-0}
    done

    # Determine MAX_SPEED (Y-axis max) rounded up to nearest sensible unit (e.g., 100, 500, 1000)
    # Simple rounding up to the nearest 100, minimum 20
    local max_speed=$(( (max_value + 99) / 100 * 100 ))
    (( max_speed < 20 )) && max_speed=20

    # Calculate scale factor (value units per graph row)
    local scale=$((max_speed / HEIGHT))
    (( scale == 0 )) && scale=1 # Avoid division by zero

    # Legend
    graph_output+=("      Legend: ${color_1}█${COLOR_RESET}=${title_1}, ${color_2}█${COLOR_RESET}=${title_2}, ${color_3}█${COLOR_RESET}=Overlap")

    # Calculate heights for each point based on the scale
    local -a graph1_heights
    local -a graph2_heights
    for ((i = 0; i < WIDTH; i++)); do
        graph1_heights[i]=$(( (${graph1_ref[i]:-0} + scale / 2) / scale )) # Round to nearest row
        graph2_heights[i]=$(( (${graph2_ref[i]:-0} + scale / 2) / scale )) # Round to nearest row
    done

    # Build graph lines from top (HEIGHT) down
    for ((row = HEIGHT; row > 0; row--)); do
        local line=""
        for ((i = 0; i < WIDTH; i++)); do
            if (( graph1_heights[i] > row && graph2_heights[i] > row )); then
                line+="${color_3}█${COLOR_RESET}" # Overlap
            elif (( graph1_heights[i] > row )); then
                line+="${color_1}█${COLOR_RESET}" # Graph 1
            elif (( graph2_heights[i] > row )); then
                line+="${color_2}█${COLOR_RESET}" # Graph 2
            else
                line+=" " # Empty
            fi
        done
         # Y-axis label (value at this row height)
        graph_output+=("$(printf "%5d | %b" $((row * scale)) "$line")")
    done

    # Add bottom border and timestamp
    graph_output+=("      +$(printf -- '-%.0s' $(seq 0 $WIDTH))")
    graph_output+=("      $(printf "%*s" $((WIDTH / 2 + 10)) "$(date '+%Y-%m-%d %H:%M:%S')")")

    # Print the generated graph output
    printf '%b\n' "${graph_output[@]}"
}

# --- Utility Functions ---

# Beep warning if usage exceeds threshold
# Usage: warning usage_percentage
warning() {
    local usage=$1
    # Check if usage is a number and greater than threshold
    if [[ "$usage" =~ ^[0-9]+$ ]] && (( usage > WARNING_THRESHOLD )); then
        # Run beep in background so it doesn't block main loop
        (
          for ((i = 0; i < 3; i++)); do
              tput bel # Terminal beep
              sleep 0.2
          done
        ) &
    fi
}

# Convert bytes to human-readable format (KB, MB, GB, TB)
# Usage: byte_to_human bytes [per_second_flag]
# Example: byte_to_human 1048576 -> 1.0 MB
# Example: byte_to_human 1048576 true -> 1.0 MB/s
byte_to_human() {
    local value=$1
    local per_second=${2:-false} # Default to false if not provided
    local suffix=""
    local scale_factor=1

    if ! [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "0 B" # Invalid input
        return
    fi

    # Using awk for floating point comparison
    if awk -v val="$value" 'BEGIN{ exit !(val >= 1099511627776) }'; then
        scale_factor=1099511627776; suffix="TB"
    elif awk -v val="$value" 'BEGIN{ exit !(val >= 1073741824) }'; then
        scale_factor=1073741824; suffix="GB"
    elif awk -v val="$value" 'BEGIN{ exit !(val >= 1048576) }'; then
        scale_factor=1048576; suffix="MB"
    elif awk -v val="$value" 'BEGIN{ exit !(val >= 1024) }'; then
        scale_factor=1024; suffix="KB"
    else
        scale_factor=1; suffix="B"
    fi

    # Append /s if requested
    [[ "$per_second" == "true" ]] && suffix+="/s"

    # Perform calculation using bc for floating point precision
    local result=$(echo "scale=1; $value / $scale_factor" | bc -l)
    # Ensure result starts with 0 if integer part is 0 (e.g., 0.5 not .5)
    [[ "$result" == .* ]] && result="0$result"
    printf "%.1f %s" "$result" "$suffix"
}


#==============================================================================
# CPU Monitoring Section
#==============================================================================

# Get static CPU information
get_cpu_info() {
    echo "===== CPU Info ====="
    local cpu_model=$(grep -m1 "^model name" /proc/cpuinfo | cut -d ':' -f2 | sed 's/^[ \t]*//')
    local physical_cores=$(grep "^core id" /proc/cpuinfo | sort -u | wc -l)
    local siblings=$(grep -m1 "^siblings" /proc/cpuinfo | cut -d ':' -f2 | xargs) # Logical cores per physical package
    local sockets=$(grep "^physical id" /proc/cpuinfo | sort -u | wc -l)
    local total_physical_cores=$((physical_cores * sockets))
    local logical_cores=$(nproc)
    local virtualization="Disabled"
    grep -qE '(vmx|svm)' /proc/cpuinfo && virtualization="Enabled"

    echo "CPU Model              : ${cpu_model:-N/A}"
    echo "Physical Cores         : $total_physical_cores ($sockets socket(s) x $physical_cores core(s))"
    echo "Logical Cores (Threads): $logical_cores"
    echo "Virtualization         : $virtualization"

    # Cache Info (simplified, using lscpu is generally more reliable if available)
    if command -v lscpu >/dev/null; then
        local l1d_cache=$(lscpu | awk '/^L1d cache:/ {print $3 $4}')
        local l1i_cache=$(lscpu | awk '/^L1i cache:/ {print $3 $4}')
        local l2_cache=$(lscpu | awk '/^L2 cache:/ {print $3 $4}')
        local l3_cache=$(lscpu | awk '/^L3 cache:/ {print $3 $4}')
        echo "L1d Cache              : ${l1d_cache:-N/A}"
        echo "L1i Cache              : ${l1i_cache:-N/A}"
        echo "L2 Cache               : ${l2_cache:-N/A}"
        echo "L3 Cache               : ${l3_cache:-N/A}"
    else
        echo "Cache Info             : (lscpu not found)"
    fi
    echo # Newline for separation
}

# Get current total and idle CPU ticks from /proc/stat
# Output: total_ticks idle_ticks
_get_cpu_ticks() {
    local cpu_line
    read -r cpu_line < /proc/stat # Read only the first line "cpu ..."
    # user nice system idle iowait irq softirq steal guest guest_nice
    local -a cpu_values=($cpu_line)
    unset cpu_values[0] # Remove the "cpu" label

    local total=0
    local value
    for value in "${cpu_values[@]}"; do
        total=$((total + value))
    done
    local idle=${cpu_values[3]:-0} # Index 3 is idle time

    echo "$total $idle"
}

# Show real-time CPU usage graph and stats
show_cpu_info() {
    local -a graph_data # Array to hold graph points
    local prev_total prev_idle total idle diff_total diff_idle cpu_usage key
    local cur_freq process_count thread_count handle_count

    # Initialize graph data array
    for ((i = 0; i < WIDTH; i++)); do graph_data[i]=0; done

    # Get initial CPU tick values
    read -r prev_total prev_idle < <(_get_cpu_ticks)

    hide_cursor
    clear_screen
    get_cpu_info # Display static info once
    echo "===== CPU Monitoring (Real-time) ====="
    save_cursor # Save position for graph updates

    while true; do
        restore_cursor # Go back to saved position

        # Get current CPU tick values
        read -r total idle < <(_get_cpu_ticks)

        # Calculate difference from previous measurement
        diff_total=$((total - prev_total))
        diff_idle=$((idle - prev_idle))

        # Calculate CPU usage percentage
        cpu_usage=0
        if (( diff_total > 0 )); then
            # Usage = 100 * (Total Time - Idle Time) / Total Time
            cpu_usage=$(( (100 * (diff_total - diff_idle)) / diff_total ))
        fi
        # Clamp usage between 0 and 100
        (( cpu_usage < 0 )) && cpu_usage=0
        (( cpu_usage > 100 )) && cpu_usage=100

        # Update previous values for next iteration
        prev_total=$total
        prev_idle=$idle

        # Update graph data (shift left, add new value)
        graph_data=("${graph_data[@]:1}" "$cpu_usage")

        # Display current usage and draw graph
        printf "CPU Usage: %3d%% \n" "$cpu_usage" # Pad for consistent width
        warning "$cpu_usage"
        draw_graph_percent graph_data "$COLOR_CYAN" # Use the function

        # --- Additional Real-time Info ---
        # Ensure this info is printed *below* the graph area

        # Current CPU Frequency (average or first core)
        cur_freq=$(awk '/^cpu MHz/ {sum+=$4; count++} END {if (count>0) printf "%.0f", sum/count; else print "N/A"}' /proc/cpuinfo)
        echo "Avg Frequency         : ${cur_freq} MHz      " # Padding spaces overwrite previous longer value

        # Process and Thread Counts
        process_count=$(ps -e --no-headers | wc -l)
        thread_count=$(ps -eL --no-headers | wc -l)
        echo "Processes             : $process_count      "
        echo "Threads               : $thread_count      "

        # System-wide open file handles (approximate)
        handle_count=$(cat /proc/sys/fs/file-nr | awk '{print $1}')
        echo "Open File Handles     : $handle_count      "

        # Check for user keypress to exit (non-blocking read)
        read -t "$DELAY" -n 1 key
        if [[ $? -eq 0 ]]; then
            echo -e "\nExiting CPU monitor..."
            break
        fi
        # No sleep needed here if read -t has a timeout >= DELAY
        # If DELAY is very small, add sleep: sleep "$DELAY"
    done

    show_cursor
}


#==============================================================================
# Memory Monitoring Section
#==============================================================================

# Get static memory hardware information (requires root/dmidecode)
get_memory_info() {
    echo "========== Memory Hardware Info =========="
    if [[ "$EUID" -ne 0 ]]; then
      echo " (Run as root/sudo for detailed hardware info)"
    fi

    # Total Memory from /proc/meminfo (most reliable)
    local total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_mem_gib=$(awk "BEGIN {printf \"%.2f\", $total_mem_kb / 1024 / 1024}")
    echo "Total Memory          : $total_mem_gib GiB"

    # Attempt to get details using dmidecode (if root)
    if [[ "$EUID" -eq 0 ]] && command -v dmidecode >/dev/null; then
        local mem_speed=$(dmidecode -t memory | grep -i "Speed:" | grep -iv "Configured" | grep -o '[0-9]\+ MT/s' | sort -n | head -n 1 | awk '{print $1}')
        local slots_used=$(dmidecode -t memory | grep -i "Size:" | grep -iv "No Module" | wc -l)
        local slots_total=$(dmidecode -t memory | grep -i "Locator:" | wc -l) # More reliable count of physical slots
        local form_factor=$(dmidecode -t memory | grep -m1 -i "Form Factor:" | cut -d ':' -f2 | xargs)

        echo "Memory Speed          : ${mem_speed:-N/A} MT/s" # MT/s is more standard now
        echo "Memory Slots Used     : $slots_used of $slots_total"
        echo "Memory Form Factor    : ${form_factor:-N/A}"

        # Hardware Reserved (less common, might not be available)
        local hw_reserved_kb=$(grep -i "HardwareCorrupted:" /proc/meminfo | awk '{print $2}')
         if [[ -n "$hw_reserved_kb" && "$hw_reserved_kb" -gt 0 ]]; then
            local hw_reserved_mib=$(awk "BEGIN {printf \"%.1f\", $hw_reserved_kb / 1024}")
            echo "Hardware Reserved     : $hw_reserved_mib MiB"
        else
            echo "Hardware Reserved     : 0 MiB / N/A"
        fi
    else
         echo "Memory Speed          : (Requires root + dmidecode)"
         echo "Memory Slots          : (Requires root + dmidecode)"
         echo "Memory Form Factor    : (Requires root + dmidecode)"
         echo "Hardware Reserved     : (Requires root + dmidecode)"
    fi
    echo # Newline for separation
}

# Show real-time memory usage graph and stats
show_memory_info() {
    local -a graph_data
    local mem_total_kb mem_available_kb mem_used_kb mem_usage_percent key
    local mem_buffers_kb mem_cached_kb mem_slab_kb swap_total_kb swap_free_kb swap_used_kb
    local committed_as_kb commit_limit_kb paged_pool_kb nonpaged_pool_kb # Approximations

    # Initialize graph data
    for ((i = 0; i < WIDTH; i++)); do graph_data[i]=0; done

    hide_cursor
    clear_screen
    get_memory_info # Display static info once
    echo "===== Memory Usage Monitoring (Real-time) ====="
    save_cursor

    while true; do
        restore_cursor

        # Read /proc/meminfo for current values (KB)
        mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        mem_available_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}') # Use MemAvailable for a better "free" picture
        mem_buffers_kb=$(grep Buffers /proc/meminfo | awk '{print $2}')
        mem_cached_kb=$(grep ^Cached: /proc/meminfo | awk '{print $2}')
        mem_slab_kb=$(grep Slab /proc/meminfo | awk '{print $2}')
        swap_total_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
        swap_free_kb=$(grep SwapFree /proc/meminfo | awk '{print $2}')
        committed_as_kb=$(grep Committed_AS /proc/meminfo | awk '{print $2}')
        commit_limit_kb=$(grep CommitLimit /proc/meminfo | awk '{print $2}')
        paged_pool_kb=$(grep PageTables /proc/meminfo | awk '{print $2}')   # Approximation for Paged Pool
        nonpaged_pool_kb=$(grep Slab /proc/meminfo | awk '{print $2}')     # Approximation for Non-Paged Pool

        # Calculate usage
        mem_used_kb=$((mem_total_kb - mem_available_kb))
        swap_used_kb=$((swap_total_kb - swap_free_kb))

        mem_usage_percent=0
        if (( mem_total_kb > 0 )); then
            mem_usage_percent=$(( (100 * mem_used_kb) / mem_total_kb ))
        fi
         # Clamp usage between 0 and 100
        (( mem_usage_percent < 0 )) && mem_usage_percent=0
        (( mem_usage_percent > 100 )) && mem_usage_percent=100

        # Update graph data
        graph_data=("${graph_data[@]:1}" "$mem_usage_percent")

        # Display graph and current usage %
        printf "Memory Usage: %3d%% \n" "$mem_usage_percent"
        warning "$mem_usage_percent"
        draw_graph_percent graph_data "$COLOR_BRIGHT_GREEN"

        # --- Detailed Memory Info (convert KB to MiB/GiB for display) ---
        local used_display=$(byte_to_human $((mem_used_kb * 1024))) # Convert KB to Bytes for function
        local available_display=$(byte_to_human $((mem_available_kb * 1024)))
        local total_display=$(byte_to_human $((mem_total_kb * 1024)))
        local committed_display=$(byte_to_human $((committed_as_kb * 1024)))
        local commit_limit_display=$(byte_to_human $((commit_limit_kb * 1024)))
        local cached_display=$(byte_to_human $(( (mem_cached_kb + mem_slab_kb) * 1024 ))) # Combine Cached + Slab
        local buffers_display=$(byte_to_human $((mem_buffers_kb * 1024)))
        local swap_used_display=$(byte_to_human $((swap_used_kb * 1024)))
        local swap_total_display=$(byte_to_human $((swap_total_kb * 1024)))
        local paged_display=$(byte_to_human $((paged_pool_kb * 1024)))
        local nonpaged_display=$(byte_to_human $((nonpaged_pool_kb * 1024)))


        # Use printf for aligned output, padding with spaces to overwrite previous lines
        printf " In Use:      %-10s Available: %-10s Total: %-10s\n" "$used_display" "$available_display" "$total_display"
        printf " Committed:   %-10s Limit:     %-10s Cached: %-10s \n" "$committed_display" "$commit_limit_display" "$cached_display"
        printf " Buffers:     %-10s Swap Used: %-10s Total: %-10s\n" "$buffers_display" "$swap_used_display" "$swap_total_display"
        printf " Paged Pool:  %-10s Non-Paged: %-10s \n" "$paged_display" "$nonpaged_display" # Approximations

        # Check for user keypress
        read -t "$DELAY" -n 1 key
        if [[ $? -eq 0 ]]; then
            echo -e "\nExiting Memory monitor..."
            break
        fi
    done

    show_cursor
}

#==============================================================================
# Disk I/O Monitoring Section
#==============================================================================

# Show real-time disk I/O graph and stats for a selected device
show_disk_info() {
    local -a available_disks disk_index device
    local -a read_graph write_graph
    local current_read_kbps current_write_kbps read_speed_display write_speed_display
    local key disk_size df_info disk_used disk_used_percent iostat_output

    while true; do # Loop for disk selection menu
        clear_screen
        show_cursor

        # Get list of block devices (potential disks/partitions)
        # Filter common non-physical devices, might need adjustment
        mapfile -t available_disks < <(lsblk -dpno NAME | grep -E '/dev/(sd|nvme|vd|hd)')

        if [[ ${#available_disks[@]} -eq 0 ]]; then
            echo "No suitable disk devices found (/dev/sd*, /dev/nvme*, etc.)."
            read -p "Press Enter to return to main menu."
            return
        fi

        echo "===== Select Disk to Monitor ====="
        for i in "${!available_disks[@]}"; do
            # Try to get model/size for better description
            local model=$(lsblk -do VENDOR,MODEL "${available_disks[$i]}" | tail -n 1 | xargs)
            local size=$(lsblk -do SIZE "${available_disks[$i]}" | tail -n 1 | xargs)
            printf "  [%d] %s (%s %s)\n" "$i" "${available_disks[$i]}" "${model:-Unknown}" "${size:-?}"
        done
        echo "  [q] Return to Main Menu"

        read -p "Enter selection number or q: " disk_index

        if [[ "$disk_index" == "q" || "$disk_index" == "Q" ]]; then
            return # Return to main menu
        fi

        # Validate selection
        if ! [[ "$disk_index" =~ ^[0-9]+$ ]] || (( disk_index < 0 )) || (( disk_index >= ${#available_disks[@]} )); then
            echo "Invalid selection. Press Enter to try again."
            read
            continue # Restart disk selection loop
        fi

        device="${available_disks[$disk_index]}"
        echo "Selected: $device. Starting monitor..."
        sleep 1

        # --- Monitoring Loop for Selected Device ---
        hide_cursor
        clear_screen

        # Display static disk info (Mount point, Size, Used)
        # Note: A device like /dev/sda might not be mounted directly
        # Find the main mount point associated with the device or its partitions
        local mount_point=$(lsblk -no MOUNTPOINT "$device" | grep '^/' | head -n 1)
        local device_or_part=$device # Default to device itself
        if [[ -z "$mount_point" ]]; then
             # If device itself isn't mounted, check partitions
             local parts=$(lsblk -pno NAME "$device" | grep "$device[0-9]")
             for p in $parts; do
                 mount_point=$(lsblk -no MOUNTPOINT "$p" | grep '^/' | head -n 1)
                 if [[ -n "$mount_point" ]]; then
                     device_or_part=$p # Use the mounted partition for df
                     break
                 fi
             done
        fi

        echo "===== Disk Info: $device ====="
        disk_size=$(lsblk -bdo SIZE -n "$device") # Size of the whole device in bytes
        echo "Device Size : $(byte_to_human "$disk_size")"
        if [[ -n "$mount_point" ]]; then
             df_info=$(df -k "$mount_point" | tail -n 1) # Use the found mount point
             local total_kb=$(echo "$df_info" | awk '{print $2}')
             local used_kb=$(echo "$df_info" | awk '{print $3}')
             local avail_kb=$(echo "$df_info" | awk '{print $4}')
             local used_percent=$(echo "$df_info" | awk '{print $5}')
             echo "Mount Point : $mount_point (on $device_or_part)"
             echo "Filesystem  : $(byte_to_human $((total_kb*1024))) total, $(byte_to_human $((used_kb*1024))) used, $(byte_to_human $((avail_kb*1024))) avail ($used_percent)"
        else
             echo "Mount Point : Not directly mounted or no mounted partitions found."
        fi
        echo # Newline

        echo "===== Real-time I/O Monitoring ====="
        save_cursor

        # Initialize graph data
        for ((i = 0; i < WIDTH; i++)); do read_graph[i]=0; write_graph[i]=0; done

        # iostat requires 2 runs to calculate rates
        # Run once to establish baseline (discard output)
        iostat -dk "$device" 1 1 > /dev/null

        while true; do
            restore_cursor

            # Get I/O stats (KB/s) - Run for 1 second, take 2nd report
            # LC_ALL=C ensures decimal point is '.'
            # tail -n 2 | head -n 1 gets the device line, avoiding header/avg
            # Fallback to 0 0 if iostat fails or device disappears
            read -r current_read_kbps current_write_kbps < <(LC_ALL=C iostat -dk "$device" 1 2 | awk -v dev="$(basename "$device")" '$1 == dev {print $3, $4}' | tail -n 1 || echo "0 0")

            # Convert KB/s to Bytes/s for byte_to_human
            local read_bps=$(echo "$current_read_kbps * 1024" | bc)
            local write_bps=$(echo "$current_write_kbps * 1024" | bc)

            # Format for display
            read_speed_display=$(byte_to_human "$read_bps" true)
            write_speed_display=$(byte_to_human "$write_bps" true)

            # Update graph data (using KB/s as the value for scaling)
            # Round KB/s to integer for graph data storage
            local read_val_int=$(printf "%.0f" "$current_read_kbps")
            local write_val_int=$(printf "%.0f" "$current_write_kbps")
            read_graph=("${read_graph[@]:1}" "$read_val_int")
            write_graph=("${write_graph[@]:1}" "$write_val_int")

            # Display speeds and draw graph
            printf "Read: %-15s Write: %-15s\n" "$read_speed_display" "$write_speed_display"
            # Using KB/s as the unit for the graph Y-axis labels
            draw_graph_overlap read_graph write_graph "Read (KB/s)" "Write (KB/s)" "$COLOR_BRIGHT_BLUE" "$COLOR_BRIGHT_YELLOW" "$COLOR_BRIGHT_CYAN"

            # Check for keypress (non-blocking)
            # Use a shorter timeout than DELAY to ensure responsiveness
            read -t 0.1 -n 1 key
            if [[ $? -eq 0 ]]; then
                echo -e "\nReturning to disk selection..."
                sleep 1 # Brief pause before clearing
                break # Exit inner loop, go back to disk selection
            fi

            # The main delay is handled by iostat running for 1 second.
            # If iostat delay changes, adjust timing here.
        done # End monitoring loop for the selected device

    done # End disk selection loop

    show_cursor
}


#==============================================================================
# Process Monitoring Section
#==============================================================================

# Get overall CPU stats (Total/Idle ticks), specifically for process view's %CPU calc
_get_overall_cpu_ticks() {
    local stat_line
    stat_line=$(grep '^cpu ' /proc/stat)
    local -a cpu_vals=($stat_line)
    unset cpu_vals[0]
    local total=0 val idle
    for val in "${cpu_vals[@]}"; do
        ((total += val))
    done
    idle=${cpu_vals[3]:-0} # idle is the 4th value (index 3)
    echo "$total $idle"
}

# Show list of running processes, sorted by CPU usage
show_processes_info() {
    local prev_total prev_idle total idle diff_total diff_idle cpu_usage
    local mem_info mem_used_b mem_total_b mem_percent
    local key current_time prev_time=$SECONDS # Use $SECONDS for interval calculation
    local -A prev_read_bytes prev_write_bytes # Associative arrays for per-PID I/O tracking

    # Initial CPU ticks for overall usage calculation
    read -r prev_total prev_idle < <(_get_overall_cpu_ticks)

    hide_cursor
    clear_screen

    trap 'show_cursor; clear_screen; echo "Exited Process Monitor."; exit 0' INT TERM

    while true; do
        current_time=$SECONDS
        local time_diff=$((current_time - prev_time))
        (( time_diff <= 0 )) && time_diff=1 # Prevent division by zero, ensure minimum 1 sec

        # --- Calculate Overall CPU Usage ---
        read -r total idle < <(_get_overall_cpu_ticks)
        diff_total=$((total - prev_total))
        diff_idle=$((idle - prev_idle))
        cpu_usage=0
        if (( diff_total > 0 )); then
            cpu_usage=$(( (100 * (diff_total - diff_idle)) / diff_total ))
        fi
        (( cpu_usage < 0 )) && cpu_usage=0
        (( cpu_usage > 100 )) && cpu_usage=100
        prev_total=$total
        prev_idle=$idle

        # --- Calculate Overall Memory Usage ---
        mem_info=$(grep -E '^(MemTotal|MemAvailable):' /proc/meminfo)
        mem_total_b=$(echo "$mem_info" | grep MemTotal | awk '{print $2 * 1024}')
        local mem_avail_b=$(echo "$mem_info" | grep MemAvailable | awk '{print $2 * 1024}')
        mem_used_b=$((mem_total_b - mem_avail_b))
        mem_percent=0
        if (( mem_total_b > 0 )); then
            mem_percent=$(echo "scale=1; $mem_used_b * 100 / $mem_total_b" | bc -l)
        fi

        # --- Display Header ---
        move_cursor 0 0 # Go to top-left
        echo "Process Monitor - $(date '+%Y-%m-%d %H:%M:%S') (Update Interval: $time_diff s) - Press any key to exit"
        printf "Overall CPU: %3d%%   Overall Memory: %s%% (%s / %s) \n" \
            "$cpu_usage" \
            "$mem_percent" \
            "$(byte_to_human "$mem_used_b")" \
            "$(byte_to_human "$mem_total_b")"
        echo # Blank line

        # Table Header - Adjust spacing as needed
        printf "%-10s %6s %5s %5s %8s %8s   %12s   %12s %-5s %-8s %-9s %s\n" \
               "USER" "PID" "%CPU" "%MEM" "VIRT" "RES" "READ/s" "WRITE/s" "STAT" "START" "TIME" "COMMAND"
        # Use a separator line that matches the width
        printf -- '-%.0s' $(seq 1 $(tput cols))
        echo

        # --- Get Process Data ---
        # Using ps with custom format. Sorting by CPU. Limiting lines.
        # VIRT = VSZ (Virtual Memory Size in KB)
        # RES = RSS (Resident Set Size in KB)
        local ps_output
        mapfile -t ps_output < <(ps -eo user:10=,pid=,pcpu=,pmem=,vsz=,rss=,stat=,start=,time=,comm= --sort=-pcpu --no-headers | head -n "$MAX_PROCESSES")

        # --- Process Each Line ---
        local line_num=5 # Start printing processes below header + separator
        for line in "${ps_output[@]}"; do
            # Use read to parse columns safely, handling potential spaces in command
            local user pid cpu mem vsz rss stat start timep command
            read -r user pid cpu mem vsz rss stat start timep command <<< "$line"

            # --- Calculate I/O Rate ---
            local rbps_display="0 B/s"
            local wbps_display="0 B/s"
            local current_rb=0
            local current_wb=0

            if [[ -r "/proc/$pid/io" ]]; then
                # Read current byte counts
                local io_data=$(cat "/proc/$pid/io")
                current_rb=$(echo "$io_data" | grep -m1 '^read_bytes:' | awk '{print $2}')
                current_wb=$(echo "$io_data" | grep -m1 '^write_bytes:' | awk '{print $2}')

                # Get previous counts, default to current if first time seen
                local prev_rb=${prev_read_bytes[$pid]:-$current_rb}
                local prev_wb=${prev_write_bytes[$pid]:-$current_wb}

                # Calculate bytes per second if previous data exists
                 if [[ -n "${prev_read_bytes[$pid]}" ]]; then # Check if PID was seen before
                    local diff_rb=$((current_rb - prev_rb))
                    local diff_wb=$((current_wb - prev_wb))
                    (( diff_rb < 0 )) && diff_rb=0 # Handle counter reset/wrap
                    (( diff_wb < 0 )) && diff_wb=0

                    rbps_display=$(byte_to_human $((diff_rb / time_diff)) true)
                    wbps_display=$(byte_to_human $((diff_wb / time_diff)) true)
                 fi
            fi
            # Store current counts for the next iteration
            prev_read_bytes[$pid]=$current_rb
            prev_write_bytes[$pid]=$current_wb

            # Format VIRT/RES memory (comes in KB from ps)
            local vsz_display=$(byte_to_human $((vsz * 1024)))
            local rss_display=$(byte_to_human $((rss * 1024)))

            # Print process row, ensure it fits on one line
            move_cursor $line_num 0
            printf "%-10.10s %6d %5.1f %5.1f %8s %8s   %12s   %12s    %-5s %-8s %-9s %s\n" \
                   "$user" "$pid" "$cpu" "$mem" "$vsz_display" "$rss_display" \
                   "$rbps_display" "$wbps_display" \
                   "$stat" "$start" "$timep" "${command}" | cut -c 1-$(tput cols) # Truncate long lines
            ((line_num++))
        done

        # Clear remaining lines from previous iteration (if process count decreased)
        local current_lines=$(tput lines)
        while (( line_num < current_lines )); do
             move_cursor $line_num 0
             tput el # Clear line
             ((line_num++))
        done

        prev_time=$current_time

        # Check for exit key
        read -t "$DELAY" -n 1 key
        if [[ $? -eq 0 ]]; then
            break
        fi
    done

    # Clean up before returning
    show_cursor
    clear_screen
    trap - INT TERM # Remove trap
}


#==============================================================================
# Network I/O Monitoring Section
#==============================================================================

# Show real-time network I/O graph and stats for a selected interface
show_net_info() {
    local -a available_interfaces interface_index interface
    local -a rx_graph tx_graph
    local prev_rx_bytes prev_tx_bytes current_rx_bytes current_tx_bytes
    local prev_time current_time time_diff
    local rx_bps tx_bps rx_speed_display tx_speed_display
    local key ip4 ip6 mac i

    while true; do # Loop for interface selection
        clear_screen
        show_cursor

        # Get list of non-loopback network interfaces
        mapfile -t available_interfaces < <(ip -o link show | awk -F': ' '!/LOOPBACK/ {print $2}')

        if [[ ${#available_interfaces[@]} -eq 0 ]]; then
            echo "No non-loopback network interfaces found."
            read -p "Press Enter to return to main menu."
            return
        fi

        echo "===== Select Network Interface to Monitor ====="
        for i in "${!available_interfaces[@]}"; do
            local status=$(ip link show "${available_interfaces[$i]}" | awk '/state/ {print $9}')
            local ip_addr=$(ip -4 -o addr show "${available_interfaces[$i]}" | awk '{print $4}' | cut -d/ -f1)
            printf "  [%d] %s (State: %s, IP: %s)\n" "$i" "${available_interfaces[$i]}" "$status" "${ip_addr:-N/A}"
        done
        echo "  [q] Return to Main Menu"

        read -p "Enter selection number or q: " interface_index

        if [[ "$interface_index" == "q" || "$interface_index" == "Q" ]]; then
            return # Return to main menu
        fi

        # Validate selection
        if ! [[ "$interface_index" =~ ^[0-9]+$ ]] || (( interface_index < 0 )) || (( interface_index >= ${#available_interfaces[@]} )); then
            echo "Invalid selection. Press Enter to try again."
            read
            continue # Restart interface selection loop
        fi

        interface="${available_interfaces[$interface_index]}"
        echo "Selected: $interface. Starting monitor..."
        sleep 1

        # --- Monitoring Loop for Selected Interface ---
        hide_cursor
        clear_screen

        # Display static interface info
        echo "===== Network Info: $interface ====="
        ip4=$(ip -4 -o addr show "$interface" | awk '{print $4}' | head -n 1) || ip4="N/A"
        ip6=$(ip -6 -o addr show "eth0" | awk '{print $4}') || ip6="N/A"
        mac=$(cat "/sys/class/net/$interface/address") || mac="N/A"
        local speed=$(cat "/sys/class/net/$interface/speed") || speed="N/A" # Speed in Mbits/s
        local duplex=$(cat "/sys/class/net/$interface/duplex") || duplex="N/A"
        local status=$(cat "/sys/class/net/$interface/operstate") || status="N/A"

        echo "Status        : $status"
        echo "MAC Address   : $mac"
        echo "IPv4 Address  : ${ip4:-N/A}"
        echo "IPv6 Address  : ${ip6:-N/A}"
        echo "Speed         : ${speed} Mbits/s"
        echo "Duplex        : $duplex"
        echo # Newline

        echo "===== Real-time I/O Monitoring ====="
        save_cursor

        # Initialize graph data
        for ((i = 0; i < WIDTH; i++)); do rx_graph[i]=0; tx_graph[i]=0; done

        # Get initial byte counts and time
        local stats
        read -r current_rx_bytes current_tx_bytes < <(awk -v iface="$interface:" '$1 == iface {print $2, $10}' /proc/net/dev || echo "0 0")
        prev_rx_bytes=$current_rx_bytes
        prev_tx_bytes=$current_tx_bytes
        prev_time=$(date +%s.%N) # Use nanoseconds for higher precision

        while true; do
            restore_cursor
            sleep "$DELAY" # Wait for the specified interval

            current_time=$(date +%s.%N)
            read -r current_rx_bytes current_tx_bytes < <(awk -v iface="$interface:" '$1 == iface {print $2, $10}' /proc/net/dev || echo "$prev_rx_bytes $prev_tx_bytes") # Use previous on error

            # Calculate time difference using bc for floating point seconds
            time_diff=$(echo "$current_time - $prev_time" | bc -l)

            # Calculate bytes transferred
            local diff_rx=$((current_rx_bytes - prev_rx_bytes))
            local diff_tx=$((current_tx_bytes - prev_tx_bytes))

            # Handle counter wrap-around or initial state (negative diff)
            (( diff_rx < 0 )) && diff_rx=0
            (( diff_tx < 0 )) && diff_tx=0

            # Calculate speed in Bytes per Second (Bps)
            rx_bps=0
            tx_bps=0
            if (( $(echo "$time_diff > 0" | bc -l) )); then
                rx_bps=$(echo "scale=0; $diff_rx / $time_diff" | bc -l)
                tx_bps=$(echo "scale=0; $diff_tx / $time_diff" | bc -l)
            fi
            # Ensure speeds are integers >= 0
            rx_bps=${rx_bps%.*} # Truncate fractional part
            tx_bps=${tx_bps%.*}
            (( rx_bps < 0 )) && rx_bps=0
            (( tx_bps < 0 )) && tx_bps=0

            # Format for display
            rx_speed_display=$(byte_to_human "$rx_bps" true)
            tx_speed_display=$(byte_to_human "$tx_bps" true)

            # Update graph data (use KB/s for graph scale consistency)
            # Use integer KB/s for the graph array value
            local rx_kbps_int=$(( (rx_bps + 512) / 1024 )) # Round to nearest KB/s
            local tx_kbps_int=$(( (tx_bps + 512) / 1024 ))
            rx_graph=("${rx_graph[@]:1}" "$rx_kbps_int")
            tx_graph=("${tx_graph[@]:1}" "$tx_kbps_int")

            # Display speeds and draw graph
            printf "Recv: %-15s Send: %-15s\n" "$rx_speed_display" "$tx_speed_display"
            # Graph titles indicate units used for Y-axis scaling
            draw_graph_overlap rx_graph tx_graph "Recv (KB/s)" "Send (KB/s)" "$COLOR_BRIGHT_CYAN" "$COLOR_BRIGHT_MAGENTA" "$COLOR_BLUE"

            # Update previous values for next iteration
            prev_rx_bytes=$current_rx_bytes
            prev_tx_bytes=$current_tx_bytes
            prev_time=$current_time

            # Check for keypress (non-blocking)
            read -t 0.1 -n 1 key
            if [[ $? -eq 0 ]]; then
                echo -e "\nReturning to interface selection..."
                sleep 1
                break # Exit inner loop, go back to interface selection
            fi
        done # End monitoring loop

    done # End interface selection loop

    show_cursor
}


#==============================================================================
# GPU Monitoring Section (NVIDIA Only)
#==============================================================================

# Get static GPU information (NVIDIA)
get_gpu_info() {
    echo "===== GPU Info (NVIDIA) ====="
    if ! command -v nvidia-smi >/dev/null; then
        echo "nvidia-smi command not found. Cannot get GPU info."
        return
    fi
    # Get info for GPU 0 by default, can be adapted for multi-GPU later if needed
    local gpu_model=$(nvidia-smi --query-gpu=name --format=csv,noheader -i 0 2>/dev/null)
    local vram_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits -i 0 2>/dev/null)
    local driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader -i 0 2>/dev/null)
    local cuda_version=$(nvidia-smi | grep "CUDA Version" | awk '{printf $9}' 2>&1)

    echo "GPU Model             : ${gpu_model:-N/A}"
    echo "VRAM Total            : ${vram_total:-N/A} MiB"
    echo "Driver Version        : ${driver_version:-N/A}"
    echo "CUDA Version          : ${cuda_version:-N/A}"
    echo
}

# Get current GPU utilization and memory usage (NVIDIA) for a specific GPU index
# Output: gpu_util mem_used_mib mem_total_mib power_draw temp fan_speed perf_state gpu_clock mem_clock
_get_gpu_stats() {
    local gpu_index=${1:-0} # Default to GPU 0
    local stats=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,power.draw,temperature.gpu,fan.speed,pstate,clocks.gr,clocks.mem \
                      --format=csv,noheader,nounits -i "$gpu_index" 2>/dev/null)

    if [[ -z "$stats" ]]; then
        # Return zeros or N/A if command fails
        echo "0 0 0 0 0 0 N/A 0 0"
        return
    fi

    # Parse the CSV output
    local gpu_util=$(echo "$stats" | cut -d',' -f1 | xargs)
    local mem_used=$(echo "$stats" | cut -d',' -f2 | xargs)
    local mem_total=$(echo "$stats" | cut -d',' -f3 | xargs)
    local power=$(echo "$stats" | cut -d',' -f4 | xargs)
    local temp=$(echo "$stats" | cut -d',' -f5 | xargs)
    local fan=$(echo "$stats" | cut -d',' -f6 | xargs | sed 's/\[Not Supported\]/N\/A/')
    local pstate=$(echo "$stats" | cut -d',' -f7 | xargs)
    local gpu_clk=$(echo "$stats" | cut -d',' -f8 | xargs)
    local mem_clk=$(echo "$stats" | cut -d',' -f9 | xargs)

    echo "$gpu_util $mem_used $mem_total $power $temp $fan $pstate $gpu_clk $mem_clk"
}

# Show real-time GPU usage graph and stats (NVIDIA)
show_gpu_info() {
    while true; do
        if ! command -v nvidia-smi >/dev/null; then
            echo "nvidia-smi command not found. Cannot monitor GPU."
            read -p "Press Enter to return to menu."
            return
        fi

        # --- GPU Selection ---
        local -a gpu_list
        mapfile -t gpu_list < <(nvidia-smi --query-gpu=index,name --format=csv,noheader)
        local num_gpus=${#gpu_list[@]}

        if [[ $num_gpus -eq 0 ]]; then
            echo "No NVIDIA GPUs detected by nvidia-smi."
            read -p "Press Enter to return to menu."
            return
        fi

        local gpu_index=0 # Default to first GPU
        if [[ $num_gpus -ge 1 ]]; then
            clear_screen
            show_cursor
            echo "===== Select NVIDIA GPU to Monitor ====="
            for i in "${!gpu_list[@]}"; do
                local index=$(echo "${gpu_list[$i]}" | cut -d',' -f1 | xargs)
                local name=$(echo "${gpu_list[$i]}" | cut -d',' -f2- | xargs)
                printf "  [%d] GPU %d: %s\n" "$i" "$index" "$name"
            done
                echo "  [q] Return to Main Menu"
            local selection
            while true; do
                read -p "Enter selection number or q: " selection
                if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
                    return
                fi
                if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 0 && selection < num_gpus )); then
                    gpu_index=$(echo "${gpu_list[$selection]}" | cut -d',' -f1 | xargs) # Get actual GPU index
                    break
                else
                    echo "Invalid selection."
                fi
            done
        fi
        local gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader -i "$gpu_index")
        echo "Selected: GPU $gpu_index ($gpu_name). Starting monitor..."
        sleep 1

        # --- Monitoring Setup ---
        local -a graph_data
        local gpu_util mem_used mem_total power temp fan pstate gpu_clk mem_clk
        local mem_usage_percent key process_count

        for ((i = 0; i < WIDTH; i++)); do graph_data[i]=0; done

        hide_cursor
        clear_screen
        get_gpu_info # Display static info (uses GPU 0 by default, maybe adapt?)
        echo "===== GPU Monitoring: GPU $gpu_index ($gpu_name) ====="
        save_cursor

        while true; do
            restore_cursor

            # Get current stats for the selected GPU
            read -r gpu_util mem_used mem_total power temp fan pstate gpu_clk mem_clk < <(_get_gpu_stats "$gpu_index")

            # Update graph data (GPU Utilization %)
            graph_data=("${graph_data[@]:1}" "${gpu_util:-0}") # Default to 0 if empty

            # Display graph and current usage %
            printf "GPU Utilization: %3d%% \n" "${gpu_util:-0}"
            warning "${gpu_util:-0}"
            draw_graph_percent graph_data "$COLOR_BRIGHT_MAGENTA"

            # --- Detailed GPU Info ---
            mem_usage_percent=0
            if (( ${mem_total:-0} > 0 )); then
                mem_usage_percent=$(awk "BEGIN {printf \"%.1f\", (${mem_used:-0} / ${mem_total}) * 100}")
            fi

            # Get process count using the GPU
            process_count=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader -i "$gpu_index" | wc -l)

            printf "VRAM Usage        : %s MiB / %s MiB (%s%%)         \n" "${mem_used:-0}" "${mem_total:-0}" "$mem_usage_percent"
            printf "Power Draw        : %s W                            \n" "${power:-N/A}"
            printf "Temperature       : %s °C                           \n" "${temp:-N/A}"
            printf "Fan Speed         : %s %%                            \n" "${fan:-N/A}"
            printf "Performance State : %s                             \n" "${pstate:-N/A}"
            printf "GPU Clock         : %s MHz                          \n" "${gpu_clk:-N/A}"
            printf "Memory Clock      : %s MHz                          \n" "${mem_clk:-N/A}"
            printf "GPU Processes     : %d                              \n" "$process_count"


            # Check for user keypress
            read -t "$DELAY" -n 1 key
            if [[ $? -eq 0 ]]; then
                echo -e "\nExiting GPU monitor..."
                break
            fi
        done
        
    done

    show_cursor
}


#==============================================================================
# Main Menu and Script Execution
#==============================================================================

# Function to display the main menu
show_menu() {
    clear_screen
    show_cursor
    echo "============================="
    echo " Linux System Monitor"
    echo "============================="
    echo " 1. CPU Monitor"
    echo " 2. Memory Monitor"
    echo " 3. Disk I/O Monitor"
    echo " 4. Process Monitor"
    echo " 5. Network I/O Monitor"
    echo " 6. GPU Monitor (NVIDIA)"
    echo "-----------------------------"
    echo " q. Quit"
    echo "============================="
    echo -n "Select an option: "
}

# --- Dependency Checks ---
check_dependencies() {
    local missing=""
    # Core utils
    for cmd in grep awk sed tput bc date sleep cat head tail wc sort cut; do
        command -v $cmd >/dev/null 2>&1 || missing+=" $cmd"
    done
    # Specific info commands
    command -v nproc >/dev/null 2>&1 || missing+=" nproc(coreutils)"
    command -v free >/dev/null 2>&1 || missing+=" free(procps)"
    command -v ps >/dev/null 2>&1 || missing+=" ps(procps)"
    command -v lsblk >/dev/null 2>&1 || missing+=" lsblk(util-linux)"
    command -v iostat >/dev/null 2>&1 || missing+=" iostat(sysstat)"
    command -v ip >/dev/null 2>&1 || missing+=" ip(iproute2)"
    # Optional but helpful
    command -v lscpu >/dev/null 2>&1 || echo "Warning: 'lscpu' not found, CPU cache info may be limited."
    # Root-dependent optional
    if [[ "$EUID" -eq 0 ]]; then
      command -v dmidecode >/dev/null 2>&1 || echo "Warning: 'dmidecode' not found, detailed memory hardware info requires root and dmidecode."
    fi
    # GPU specific
    # nvidia-smi is checked within the GPU function itself

    if [[ -n "$missing" ]]; then
        echo "Error: Required commands missing:$missing"
        echo "Please install the packages providing these commands (e.g., procps, coreutils, sysstat, util-linux, iproute2, bc)."
        exit 1
    fi
}

# --- Main Execution Loop ---
check_dependencies

# Trap Ctrl+C (SIGINT) and termination signals for graceful exit
trap 'clear_screen; show_cursor; echo -e "\nExiting monitor."; exit 0' INT TERM

while true; do
    show_menu
    read -r -n 1 option # Read single character

    case $option in
        1) show_cpu_info ;;
        2) show_memory_info ;;
        3) show_disk_info ;;
        4) show_processes_info ;;
        5) show_net_info ;;
        6) show_gpu_info ;;
        q|Q) break ;; # Quit the loop
        *) echo -e "\nInvalid option '$option'. Press Enter to continue." ; read ;;
    esac

    # Small pause before showing menu again, unless quitting
    if [[ "$option" != "q" && "$option" != "Q" ]]; then
        echo # Newline after function returns
    fi
done

# Final cleanup before exiting normally
clear_screen
show_cursor
echo "Exited Linux System Monitor."
exit 0
