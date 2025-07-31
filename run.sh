#!/bin/bash

# Colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
purple='\033[0;35m'
cyan='\033[0;36m'
rest='\033[0m'

# Configuration
ERROR_COUNT_THRESHOLD=5  # Number of errors before reconnecting
TIME_WINDOW=60          # Time window in seconds to count errors
CHECK_INTERVAL=10       # How often to check for errors (seconds)
LOG_FILE="/tmp/warp_monitor.log"
ERROR_LOG="/tmp/warp_errors.log"

# Global variables
warp_pid=""
current_endpoint=""
error_count=0
last_error_time=0

# Function to display header
show_header() {
    clear
    echo -e "${cyan}=====================================${rest}"
    echo -e "${purple}    WARP Auto Connect & Monitor${rest}"
    echo -e "${cyan}=====================================${rest}"
    echo ""
}

# Function to log messages
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE"
    echo -e "${cyan}[$timestamp]${rest} $message"
}

# Function to get IP from first repository
get_ip_from_repo1() {
    echo -e "${yellow}Getting IP from Ptechgithub repository...${rest}"
    echo ""
    
    # Download and run the script, capture output
    temp_output=$(mktemp)
    
    # Run the script with option 1 and capture the best IP
    echo "1" | timeout 120 bash <(curl -fsSL https://raw.githubusercontent.com/Ptechgithub/warp/main/endip/install.sh) 2>/dev/null | tee "$temp_output"
    
    # Extract IP from the output (looking for IPv4:Port pattern)
    best_ip=$(grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+" "$temp_output" | head -n 1)
    
    rm -f "$temp_output"
    
    if [ -n "$best_ip" ]; then
        echo -e "${green}✓ Found IP: $best_ip${rest}"
        return 0
    else
        echo -e "${red}✗ Failed to get IP from first repository${rest}"
        return 1
    fi
}

# Function to get IP from second repository
get_ip_from_repo2() {
    echo -e "${yellow}Getting IP from TheyCallMeSecond repository...${rest}"
    echo ""
    
    # Download and run the script, capture output
    temp_output=$(mktemp)
    
    # Run the script with option 1 and capture the best IP
    echo "1" | timeout 120 bash <(curl -fsSL https://raw.githubusercontent.com/TheyCallMeSecond/WARP-Endpoint-IP/main/ip.sh) 2>/dev/null | tee "$temp_output"
    
    # Extract IP from the output (looking for IPv4:Port pattern)
    best_ip=$(grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+" "$temp_output" | head -n 1)
    
    rm -f "$temp_output"
    
    if [ -n "$best_ip" ]; then
        echo -e "${green}✓ Found IP: $best_ip${rest}"
        return 0
    else
        echo -e "${red}✗ Failed to get IP from second repository${rest}"
        return 1
    fi
}

# Function to get new endpoint
get_new_endpoint() {
    log_message "Getting new endpoint..."
    
    # Try first repository
    if get_ip_from_repo1; then
        current_endpoint="$best_ip"
        return 0
    fi
    
    # If first fails, try second
    log_message "First repository failed, trying second..."
    if get_ip_from_repo2; then
        current_endpoint="$best_ip"
        return 0
    fi
    
    log_message "Both repositories failed!"
    return 1
}

# Function to kill existing WARP processes
kill_warp() {
    log_message "Stopping existing WARP processes..."
    
    # Kill by PID if we have it
    if [ -n "$warp_pid" ] && kill -0 "$warp_pid" 2>/dev/null; then
        kill "$warp_pid" 2>/dev/null
        sleep 2
        if kill -0 "$warp_pid" 2>/dev/null; then
            kill -9 "$warp_pid" 2>/dev/null
        fi
    fi
    
    # Kill any remaining warp processes
    pkill -f "warp.*gool" 2>/dev/null
    sleep 2
    pkill -9 -f "warp.*gool" 2>/dev/null
    
    warp_pid=""
}

# Function to start WARP connection
start_warp() {
    local endpoint_ip="$1"
    
    log_message "Starting WARP with endpoint: $endpoint_ip"
    
    # Check if warp command exists
    if ! command -v warp &> /dev/null; then
        log_message "ERROR: 'warp' command not found!"
        exit 1
    fi
    
    # Start WARP in background and capture PID
    warp -4 -b 0.0.0.0:12334 --gool -e "$endpoint_ip" > /dev/null 2>&1 &
    warp_pid=$!
    
    # Wait a bit to see if it starts successfully
    sleep 5
    
    if kill -0 "$warp_pid" 2>/dev/null; then
        log_message "WARP started successfully (PID: $warp_pid)"
        return 0
    else
        log_message "WARP failed to start"
        warp_pid=""
        return 1
    fi
}

# Function to check for connection timeout errors
check_for_errors() {
    local current_time=$(date +%s)
    local error_pattern="connect tcp 169\.254\.169\.254:80: connection timed out"
    
    # Get recent errors from system logs (journalctl if available, otherwise dmesg)
    local recent_errors=0
    
    if command -v journalctl &> /dev/null; then
        recent_errors=$(journalctl --since="$TIME_WINDOW seconds ago" 2>/dev/null | grep -c "$error_pattern" || echo 0)
    fi
    
    # Also check if WARP process is still running
    if [ -n "$warp_pid" ] && ! kill -0 "$warp_pid" 2>/dev/null; then
        log_message "WARP process died unexpectedly"
        recent_errors=$((recent_errors + ERROR_COUNT_THRESHOLD))
    fi
    
    # Check for network connectivity issues
    if ! ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
        log_message "Network connectivity issue detected"
        recent_errors=$((recent_errors + 2))
    fi
    
    if [ "$recent_errors" -ge "$ERROR_COUNT_THRESHOLD" ]; then
        log_message "High error count detected ($recent_errors errors). Reconnecting..."
        return 1
    fi
    
    return 0
}

# Function to reconnect WARP
reconnect_warp() {
    log_message "Reconnecting WARP..."
    
    # Kill existing connection
    kill_warp
    
    # Get new endpoint
    if get_new_endpoint; then
        # Start new connection
        if start_warp "$current_endpoint"; then
            log_message "Successfully reconnected to WARP"
            error_count=0
            return 0
        else
            log_message "Failed to start new WARP connection"
            return 1
        fi
    else
        log_message "Failed to get new endpoint"
        return 1
    fi
}

# Function to monitor WARP connection
monitor_warp() {
    log_message "Starting WARP monitoring..."
    log_message "Monitoring configuration:"
    log_message "- Error threshold: $ERROR_COUNT_THRESHOLD errors"
    log_message "- Time window: $TIME_WINDOW seconds"
    log_message "- Check interval: $CHECK_INTERVAL seconds"
    
    while true; do
        if ! check_for_errors; then
            # Errors detected, try to reconnect
            if ! reconnect_warp; then
                log_message "Reconnection failed, waiting before retry..."
                sleep 30
            fi
        fi
        
        # Display status
        if [ -n "$warp_pid" ] && kill -0 "$warp_pid" 2>/dev/null; then
            echo -ne "\r${green}WARP Status: CONNECTED${rest} (PID: $warp_pid, Endpoint: $current_endpoint) - $(date '+%H:%M:%S')"
        else
            echo -ne "\r${red}WARP Status: DISCONNECTED${rest} - $(date '+%H:%M:%S')"
            # Try to reconnect if process died
            reconnect_warp
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

# Function to show menu
show_menu() {
    echo -e "${purple}Choose repository to get initial IP:${rest}"
    echo ""
    echo -e "${cyan}[1]${rest} Ptechgithub repository"
    echo -e "${cyan}[2]${rest} TheyCallMeSecond repository"
    echo -e "${cyan}[3]${rest} Try both (fallback to second if first fails)"
    echo -e "${cyan}[0]${rest} Exit"
    echo ""
    echo -en "${yellow}Enter your choice: ${rest}"
}

# Cleanup function
cleanup() {
    echo ""
    log_message "Shutting down..."
    kill_warp
    rm -f /tmp/warp_temp_* 2>/dev/null
    echo -e "${cyan}Goodbye!${rest}"
    exit 0
}

# Set trap for cleanup
trap cleanup SIGINT SIGTERM

# Main function
main() {
    show_header
    
    # Initialize log file
    echo "WARP Auto Connect & Monitor Log" > "$LOG_FILE"
    echo "Started at: $(date)" >> "$LOG_FILE"
    echo "================================" >> "$LOG_FILE"
    
    while true; do
        show_menu
        read -r choice
        
        case "$choice" in
            1)
                echo ""
                if get_ip_from_repo1; then
                    current_endpoint="$best_ip"
                    break
                else
                    echo ""
                    echo -e "${red}Failed to get IP. Press Enter to continue...${rest}"
                    read
                    show_header
                fi
                ;;
            2)
                echo ""
                if get_ip_from_repo2; then
                    current_endpoint="$best_ip"
                    break
                else
                    echo ""
                    echo -e "${red}Failed to get IP. Press Enter to continue...${rest}"
                    read
                    show_header
                fi
                ;;
            3)
                echo ""
                echo -e "${yellow}Trying first repository...${rest}"
                if get_ip_from_repo1; then
                    current_endpoint="$best_ip"
                    break
                else
                    echo ""
                    echo -e "${yellow}First repository failed, trying second...${rest}"
                    if get_ip_from_repo2; then
                        current_endpoint="$best_ip"
                        break
                    else
                        echo ""
                        echo -e "${red}Both repositories failed. Press Enter to continue...${rest}"
                        read
                        show_header
                    fi
                fi
                ;;
            0)
                echo ""
                echo -e "${cyan}Goodbye!${rest}"
                exit 0
                ;;
            *)
                echo ""
                echo -e "${red}Invalid choice! Press Enter to continue...${rest}"
                read
                show_header
                ;;
        esac
    done
    
    # Start initial connection
    echo ""
    echo -e "${purple}=====================================${rest}"
    echo -e "${green}Starting WARP Auto Connect & Monitor${rest}"
    echo -e "${purple}=====================================${rest}"
    echo ""
    
    if start_warp "$current_endpoint"; then
        echo ""
        echo -e "${green}WARP connected successfully!${rest}"
        echo -e "${yellow}Monitoring started... Press Ctrl+C to stop${rest}"
        echo -e "${blue}Log file: $LOG_FILE${rest}"
        echo ""
        
        # Start monitoring
        monitor_warp
    else
        echo -e "${red}Failed to start WARP connection${rest}"
        exit 1
    fi
}

# Check if running as root (optional warning)
if [ "$EUID" -eq 0 ]; then
    echo -e "${yellow}Warning: Running as root. This may not be necessary.${rest}"
    echo ""
fi

# Run main function
main