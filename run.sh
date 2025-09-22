#!/bin/bash

# === GitHub to GitLab Sync Tool (Streamlined) ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
ERROR_LOG="$SCRIPT_DIR/sync_errors.log"
SUCCESS_LOG="$SCRIPT_DIR/sync_success.log"
LOCAL_BACKUP_DIR="$SCRIPT_DIR/repos"
LAST_SYNC_FILE="$SCRIPT_DIR/.last_sync"
CRON_LOG="$SCRIPT_DIR/cron_sync.log"

# Display usage information
show_usage() {
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  full-sync    # Sync all GitHub repos to both GitLab and local backup"
    echo "  gitlab-sync  # Sync all GitHub repos to GitLab only"
    echo "  local-sync   # Sync all GitHub repos to local backup only"
    echo "  auto-setup   # Configure automatic syncing (WSL boot or cron)"
    echo "  status       # Show quick status of sync setup"
    echo "  help         # Display this help message"
    echo ""
    echo "Interactive mode:"
    echo "  Run without arguments to use the interactive menu"
    echo ""
    echo "Auto-sync:"
    echo "  • WSL users: Syncs on WSL startup (if >12 hours since last sync)"
    echo "  • Linux users: Syncs via cron at scheduled times"
    echo ""
    echo "Examples:"
    echo "  $0 full-sync     # Perform full sync to GitLab and local"
    echo "  $0 auto-setup    # Set up automatic syncing"
    echo "  $0 status        # Check sync status"
    echo "  $0               # Launch interactive menu"
}

# Check and install dependencies
check_dependencies() {
    local missing_deps=()
    
    # Check for jq
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    # Check for git
    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi
    
    # Check for curl
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "📦 Installing missing dependencies: ${missing_deps[*]}"
        
        # Detect package manager and install
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y "${missing_deps[@]}"
        elif command -v yum &> /dev/null; then
            sudo yum install -y "${missing_deps[@]}"
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y "${missing_deps[@]}"
        elif command -v pacman &> /dev/null; then
            sudo pacman -Sy --noconfirm "${missing_deps[@]}"
        elif command -v brew &> /dev/null; then
            brew install "${missing_deps[@]}"
        elif command -v apk &> /dev/null; then
            sudo apk add --no-cache "${missing_deps[@]}"
        else
            echo "❌ Unable to install dependencies automatically."
            echo "Please install manually: ${missing_deps[*]}"
            exit 1
        fi
        
        echo "✅ Dependencies installed successfully"
    fi
}

# Check dependencies before proceeding
check_dependencies

# Update last sync timestamp
update_last_sync() {
    echo "$(date +%s)" > "$LAST_SYNC_FILE"
}

# Get human-readable time since last sync
get_time_since_sync() {
    if [ ! -f "$LAST_SYNC_FILE" ]; then
        echo "Never synced"
        return
    fi
    
    LAST_SYNC=$(cat "$LAST_SYNC_FILE")
    CURRENT=$(date +%s)
    DIFF=$((CURRENT - LAST_SYNC))
    
    if [ $DIFF -lt 60 ]; then
        echo "$DIFF seconds ago"
    elif [ $DIFF -lt 3600 ]; then
        echo "$((DIFF / 60)) minutes ago"
    elif [ $DIFF -lt 86400 ]; then
        echo "$((DIFF / 3600)) hours ago"
    else
        echo "$((DIFF / 86400)) days ago"
    fi
}

# Get last sync date/time
get_last_sync_date() {
    if [ ! -f "$LAST_SYNC_FILE" ]; then
        echo "Never"
        return
    fi
    
    LAST_SYNC=$(cat "$LAST_SYNC_FILE")
    date -d "@$LAST_SYNC" "+%Y-%m-%d %H:%M:%S"
}

# Check config file
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    exit 1
fi

# Read credentials
GITHUB_USERNAME=$(jq -r '.github.username' "$CONFIG_FILE")
GITHUB_TOKEN=$(jq -r '.github.token' "$CONFIG_FILE")
GITLAB_USERNAME=$(jq -r '.gitlab.username' "$CONFIG_FILE")
GITLAB_TOKEN=$(jq -r '.gitlab.token' "$CONFIG_FILE")
GITLAB_API=$(jq -r '.gitlab_api' "$CONFIG_FILE")
WORKDIR=$(jq -r '.workdir' "$CONFIG_FILE")

# Detect if running in WSL
is_wsl() {
    if grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

show_menu() {
    clear
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                  GitHub to GitLab Sync Tool                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Show status bar
    echo "┌─ Status ─────────────────────────────────────────────────────┐"
    
    # Last sync info
    LAST_SYNC_TEXT="$(get_time_since_sync) ($(get_last_sync_date))"
    printf "│ 🕐 Last Sync: %-46s │\n" "$LAST_SYNC_TEXT"
    
    # Repository counts
    if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_USERNAME" ]; then
        # Test GitHub API connection
        API_TEST=$(curl -s -u "$GITHUB_USERNAME:$GITHUB_TOKEN" "https://api.github.com/user")
        if echo "$API_TEST" | jq -e '.login' &>/dev/null; then
            # Count all repositories (public + private) by fetching them with pagination
            GH_TOTAL=0
            PAGE=1
            while :; do
                REPOS=$(curl -s -u "$GITHUB_USERNAME:$GITHUB_TOKEN" \
                    "https://api.github.com/user/repos?per_page=100&page=$PAGE&visibility=all&affiliation=owner,collaborator")
                
                # Check if response is empty or error
                if [ -z "$REPOS" ] || [ "$REPOS" = "[]" ]; then
                    break
                fi
                
                # Count repos in this page
                COUNT=$(echo "$REPOS" | jq 'length' 2>/dev/null || echo "0")
                GH_TOTAL=$((GH_TOTAL + COUNT))
                
                # Break if we got less than 100 (last page)
                if [ "$COUNT" -lt 100 ]; then
                    break
                fi
                
                ((PAGE++))
            done
            printf "│ 🐙 GitHub: %-49s │\n" "$GH_TOTAL repositories"
        else
            printf "│ 🐙 GitHub: %-49s │\n" "Authentication failed"
        fi
    else
        printf "│ 🐙 GitHub: %-49s │\n" "Not configured"
    fi
    
    if [ -d "$LOCAL_BACKUP_DIR" ]; then
        LOCAL_COUNT=$(find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type d | wc -l)
        printf "│ 💾 Local: %-50s │\n" "$((LOCAL_COUNT - 1)) repositories"
    else
        printf "│ 💾 Local: %-50s │\n" "0 repositories"
    fi
    
    # Auto-sync status with environment info
    if grep -q "boot_sync.sh" ~/.bashrc 2>/dev/null; then
        printf "│ ⏰ Auto-sync: %-46s │\n" "Enabled (WSL boot sync)"
    elif crontab -l 2>/dev/null | grep -q "$SCRIPT_DIR/cron_sync.sh"; then
        printf "│ ⏰ Auto-sync: %-46s │\n" "Enabled (cron schedule)"
    else
        printf "│ ⏰ Auto-sync: %-46s │\n" "Not configured"
    fi
    
    # Environment detection
    if is_wsl; then
        printf "│ 🖥️  Environment: %-44s │\n" "WSL (Windows Subsystem for Linux)"
    else
        printf "│ 🖥️  Environment: %-44s │\n" "Native Linux"
    fi
    
    echo "└──────────────────────────────────────────────────────────────┘"
    echo ""
    
    echo "┌─ Menu Options ───────────────────────────────────────────────┐"
    echo "│ 1) Full Sync (GitHub → GitLab + Local)                       │"
    echo "│ 2) GitLab Only Sync (GitHub → GitLab)                        │"
    echo "│ 3) Local Only Sync (GitHub → Local)                          │"
    echo "│ 4) Setup Auto-Sync (WSL boot or cron)                        │"
    echo "│ 5) View Status & Logs                                        │"
    echo "│ 0) Exit                                                      │"
    echo "└──────────────────────────────────────────────────────────────┘"
    echo ""
    echo -n "Select [0-5]: "
}

setup_auto_sync() {
    echo ""
    echo "🤖 Automatic Sync Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Check existing auto-sync configurations
    local has_cron=false
    local has_wsl_boot=false
    
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_DIR/cron_sync.sh"; then
        has_cron=true
    fi
    
    if grep -q "boot_sync.sh" ~/.bashrc 2>/dev/null; then
        has_wsl_boot=true
    fi
    
    # Show current status
    if [ "$has_cron" = true ] || [ "$has_wsl_boot" = true ]; then
        echo "⚠️  Auto-sync is already configured:"
        echo ""
        if [ "$has_cron" = true ]; then
            echo "  • Cron jobs:"
            crontab -l 2>/dev/null | grep "$SCRIPT_DIR/cron_sync.sh" | head -2
        fi
        if [ "$has_wsl_boot" = true ]; then
            echo "  • WSL boot sync: Enabled in ~/.bashrc"
        fi
        echo ""
        echo -n "Do you want to remove existing auto-sync configuration(s)? [Y/n]: "
        read remove_confirm
        
        # Default to "Y" if Enter is pressed
        if [ -z "$remove_confirm" ]; then
            remove_confirm="Y"
        fi
        
        if [ "$remove_confirm" != "n" ] && [ "$remove_confirm" != "N" ]; then
            # Remove cron entries
            if [ "$has_cron" = true ]; then
                crontab -l 2>/dev/null | grep -v "$SCRIPT_DIR/cron_sync.sh" | crontab -
                echo "✅ Cron entries removed"
            fi
            # Remove WSL boot sync
            if [ "$has_wsl_boot" = true ]; then
                sed -i '/# GitHub to GitLab Auto-sync on WSL startup/,/^fi$/d' ~/.bashrc
                echo "✅ WSL boot sync removed"
            fi
            echo ""
        else
            echo "Keeping existing configuration."
            echo ""
            echo "Press any key to continue..."
            read -n 1
            return
        fi
    fi
    
    # Detect environment and offer appropriate option
    if is_wsl; then
        echo "🐧 WSL environment detected!"
        echo ""
        echo "Choose auto-sync method:"
        echo "  1) WSL Boot Sync (recommended for WSL)"
        echo "  2) Cron Sync (traditional Linux method)"
        echo "  3) Cancel"
        echo ""
        echo -n "Select [1-3]: "
        read sync_method
        
        case "$sync_method" in
            1) setup_wsl_boot_sync ;;
            2) setup_cron_sync ;;
            *) echo "Setup cancelled."; sleep 1; return ;;
        esac
    else
        echo "🐧 Linux environment detected!"
        echo ""
        echo "This will set up automatic syncing using cron with the following schedule:"
        echo "  • Every day at 9:00 AM"
        echo "  • Every day at 6:00 PM"
        echo "  • On system startup (if last sync was >12 hours ago)"
        echo ""
        echo -n "Do you want to proceed? [Y/n]: "
        read confirm
        
        # Default to "Y" if Enter is pressed
        if [ -z "$confirm" ]; then
            confirm="Y"
        fi
        
        if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
            echo "Setup cancelled."
            sleep 1
            return
        fi
        setup_cron_sync
    fi
}

setup_wsl_boot_sync() {
    echo ""
    echo "Setting up WSL boot sync..."
    echo ""
    echo "This will sync your repositories when WSL starts:"
    echo "  • Runs automatically on every WSL startup"
    echo "  • Syncs all repositories to GitLab and local"
    echo "  • Runs in background (won't delay shell startup)"
    echo ""
    
    # Create boot_sync.sh if it doesn't exist
    if [ ! -f "$SCRIPT_DIR/boot_sync.sh" ]; then
        cat > "$SCRIPT_DIR/boot_sync.sh" << 'EOF'
#!/bin/bash
# Boot-time sync script for WSL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAST_SYNC_FILE="$SCRIPT_DIR/.last_sync"
LOG_FILE="$SCRIPT_DIR/boot_sync.log"
LOCK_FILE="$SCRIPT_DIR/.boot_sync.lock"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Check if another instance is running
if [ -f "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE")
    if ps -p "$PID" > /dev/null 2>&1; then
        log_message "Another sync instance is already running (PID: $PID)"
        exit 0
    else
        log_message "Removing stale lock file"
        rm -f "$LOCK_FILE"
    fi
fi

# Create lock file
echo $$ > "$LOCK_FILE"

# Cleanup function
cleanup() {
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

log_message "=== WSL Boot Sync Started ==="

# Log last sync time for reference (but don't skip)
if [ -f "$LAST_SYNC_FILE" ]; then
    LAST_SYNC=$(cat "$LAST_SYNC_FILE")
    CURRENT=$(date +%s)
    DIFF=$((CURRENT - LAST_SYNC))
    HOURS_SINCE=$((DIFF / 3600))
    MINUTES_SINCE=$(( (DIFF % 3600) / 60 ))
    log_message "Last sync was $HOURS_SINCE hours and $MINUTES_SINCE minutes ago"
else
    log_message "No previous sync found - performing first sync"
fi

# Wait for network to be ready
log_message "Waiting for network..."
for i in {1..30}; do
    if ping -c 1 github.com > /dev/null 2>&1; then
        log_message "Network is ready"
        break
    fi
    sleep 2
done

# Run the sync
log_message "Starting sync..."
cd "$SCRIPT_DIR"
./run.sh full-sync >> "$LOG_FILE" 2>&1

if [ $? -eq 0 ]; then
    log_message "Sync completed successfully"
else
    log_message "Sync failed with error code $?"
fi

log_message "=== WSL Boot Sync Finished ==="
echo "" >> "$LOG_FILE"
EOF
        chmod +x "$SCRIPT_DIR/boot_sync.sh"
    fi
    
    # Add to .bashrc
    if ! grep -q "boot_sync.sh" ~/.bashrc 2>/dev/null; then
        echo '
# GitHub to GitLab Auto-sync on WSL startup
if [ -f '"$SCRIPT_DIR"'/boot_sync.sh ]; then
    # Run in background to not delay shell startup
    nohup '"$SCRIPT_DIR"'/boot_sync.sh > /dev/null 2>&1 &
fi' >> ~/.bashrc
    fi
    
    echo "✅ WSL boot sync installed successfully!"
    echo ""
    echo "📁 Logs will be saved to:"
    echo "  $SCRIPT_DIR/boot_sync.log"
    echo ""
    echo "💡 Tips:"
    echo "  • View logs: tail -f $SCRIPT_DIR/boot_sync.log"
    echo "  • The sync will run next time you start WSL"
    echo "  • To test now: source ~/.bashrc"
    echo ""
    echo "Press any key to continue..."
    read -n 1
}

setup_cron_sync() {
    echo ""
    echo "Setting up cron sync..."
    echo ""
    
    # Check if cron service is running
    if ! pgrep -x "cron" > /dev/null && ! pgrep -x "crond" > /dev/null; then
        echo "⚠️  Warning: Cron service doesn't appear to be running."
        echo "You may need to start it with: sudo service cron start"
        echo ""
    fi
    
    # Create a wrapper script for cron
    CRON_WRAPPER="$SCRIPT_DIR/cron_sync.sh"
    cat > "$CRON_WRAPPER" << 'EOF'
#!/bin/bash
# Cron wrapper for GitHub to GitLab sync

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/cron_sync.log"
LAST_SYNC_FILE="$SCRIPT_DIR/.last_sync"

# Add timestamp to log
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"
echo "🕐 Auto-sync started: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"

# For startup sync, check if last sync was more than 12 hours ago
if [ "$1" = "startup" ]; then
    echo "🚀 System/WSL startup detected" >> "$LOG_FILE"
    
    # Check if last sync file exists
    if [ -f "$LAST_SYNC_FILE" ]; then
        LAST_SYNC=$(cat "$LAST_SYNC_FILE")
        CURRENT=$(date +%s)
        DIFF=$((CURRENT - LAST_SYNC))
        HOURS_SINCE=$((DIFF / 3600))
        
        # If last sync was less than 12 hours ago, skip
        if [ $DIFF -lt 43200 ]; then  # 43200 seconds = 12 hours
            echo "⏭️  Skipping sync - last sync was $HOURS_SINCE hours ago (less than 12 hours)" >> "$LOG_FILE"
            echo "   Last sync: $(date -d "@$LAST_SYNC" '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
            echo "" >> "$LOG_FILE"
            exit 0
        else
            echo "✅ Proceeding with sync - last sync was $HOURS_SINCE hours ago (more than 12 hours)" >> "$LOG_FILE"
        fi
    else
        echo "✅ No previous sync found - proceeding with first sync" >> "$LOG_FILE"
    fi
    
    echo "⏳ Waiting 30 seconds for network initialization..." >> "$LOG_FILE"
    sleep 30
fi

# Run the sync
cd "$SCRIPT_DIR"
./run.sh full-sync >> "$LOG_FILE" 2>&1

# Check exit status
if [ $? -eq 0 ]; then
    echo "✅ Auto-sync completed successfully at $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
else
    echo "❌ Auto-sync failed at $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
fi

echo "" >> "$LOG_FILE"
EOF
    
    chmod +x "$CRON_WRAPPER"
    
    # Set up cron jobs
    echo ""
    echo "Setting up cron jobs..."
    
    # Get existing crontab (if any)
    EXISTING_CRON=$(crontab -l 2>/dev/null || echo "")
    
    # Add new cron jobs
    {
        echo "$EXISTING_CRON"
        echo ""
        echo "# GitHub to GitLab Sync - Automatic sync jobs"
        echo "0 9 * * * $CRON_WRAPPER"
        echo "0 18 * * * $CRON_WRAPPER"
        echo "@reboot $CRON_WRAPPER startup"
    } | crontab -
    
    if [ $? -eq 0 ]; then
        echo "✅ Cron jobs installed successfully!"
        echo ""
        echo "📋 Installed schedule:"
        echo "  • Daily at 9:00 AM"
        echo "  • Daily at 6:00 PM"
        echo "  • On system/WSL startup (if >12 hours since last sync)"
        echo ""
        echo "📁 Logs will be saved to:"
        echo "  $CRON_LOG"
        echo ""
        echo "💡 Tips:"
        echo "  • View logs: tail -f $CRON_LOG"
        echo "  • Check cron jobs: crontab -l"
        echo "  • Remove auto-sync: Run this option again"
        echo ""
        
        # Initialize log file
        echo "🎉 Auto-sync setup completed on $(date '+%Y-%m-%d %H:%M:%S')" > "$CRON_LOG"
        echo "" >> "$CRON_LOG"
    else
        echo "❌ Failed to install cron jobs"
    fi
    
    echo ""
    echo "Press any key to continue..."
    read -n 1
}

quick_status() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                      📊 System Status                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Environment
    echo "🖥️  Environment:"
    if is_wsl; then
        echo "   • Type: WSL (Windows Subsystem for Linux)"
    else
        echo "   • Type: Native Linux"
    fi
    echo ""
    
    # Last sync
    echo "🕐 Last Sync:"
    echo "   • Time: $(get_time_since_sync)"
    echo "   • Date: $(get_last_sync_date)"
    echo ""
    
    # Connections
    echo "🔗 Connections:"
    if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_USERNAME" ]; then
        if curl -s -u "$GITHUB_USERNAME:$GITHUB_TOKEN" "https://api.github.com/user" | jq -e '.login' &>/dev/null; then
            echo "   • GitHub: ✅ Connected"
        else
            echo "   • GitHub: ❌ Authentication failed"
        fi
    else
        echo "   • GitHub: ❌ Not configured"
    fi
    
    if curl -s -f -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API/user" > /dev/null 2>&1; then
        echo "   • GitLab: ✅ Connected"
    else
        echo "   • GitLab: ❌ Not connected"
    fi
    echo ""
    
    # Repositories
    echo "📦 Repositories:"
    if [ -d "$LOCAL_BACKUP_DIR" ]; then
        LOCAL_COUNT=$(find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type d | wc -l)
        echo "   • Local backups: $((LOCAL_COUNT - 1))"
    else
        echo "   • Local backups: 0"
    fi
    echo ""
    
    # Auto-sync status
    echo "⏰ Auto-sync:"
    if grep -q "boot_sync.sh" ~/.bashrc 2>/dev/null; then
        echo "   • Status: Enabled (WSL boot sync)"
        echo "   • Trigger: On every WSL startup"
        if [ -f "$SCRIPT_DIR/boot_sync.log" ]; then
            LAST_BOOT_LOG=$(tail -1 "$SCRIPT_DIR/boot_sync.log" 2>/dev/null | grep -oE '\[.*\]' | head -1)
            if [ -n "$LAST_BOOT_LOG" ]; then
                echo "   • Last attempt: $LAST_BOOT_LOG"
            fi
        fi
    elif crontab -l 2>/dev/null | grep -q "$SCRIPT_DIR/cron_sync.sh"; then
        echo "   • Status: Enabled (cron schedule)"
        echo "   • Schedule: Daily at 9:00 AM and 6:00 PM"
        if [ -f "$SCRIPT_DIR/cron_sync.log" ]; then
            LAST_CRON_LOG=$(tail -1 "$SCRIPT_DIR/cron_sync.log" 2>/dev/null | grep -oE 'at [0-9]{4}-[0-9]{2}-[0-9]{2}.*' | head -1)
            if [ -n "$LAST_CRON_LOG" ]; then
                echo "   • Last run: $LAST_CRON_LOG"
            fi
        fi
    else
        echo "   • Status: Not configured"
        echo "   • Run option 4 to set up automatic syncing"
    fi
    
    # Log files
    echo ""
    echo "📄 Log Files:"
    if [ -f "$SCRIPT_DIR/boot_sync.log" ]; then
        echo "   • WSL boot log: $SCRIPT_DIR/boot_sync.log"
    fi
    if [ -f "$SCRIPT_DIR/cron_sync.log" ]; then
        echo "   • Cron sync log: $SCRIPT_DIR/cron_sync.log"
    fi
    if [ -f "$ERROR_LOG" ]; then
        echo "   • Error log: $ERROR_LOG"
    fi
    if [ -f "$SUCCESS_LOG" ]; then
        echo "   • Success log: $SUCCESS_LOG"
    fi
    
    echo ""
    echo "Press any key to continue..."
    read -n 1
}

perform_sync() {
    local sync_mode=$1
    local title
    local auto_confirm=${2:-false}
    
    case $sync_mode in
        both) title="Full Sync (GitHub → GitLab + Local)" ;;
        gitlab) title="GitLab Only Sync (GitHub → GitLab)" ;;
        local) title="Local Only Sync (GitHub → Local)" ;;
    esac
    
    echo ""
    echo "================================================"
    echo "     $title       "
    echo "================================================"
    echo ""
    
    # Skip confirmation in CLI mode if running from command line
    if [ "$auto_confirm" != "true" ]; then
        echo "This will sync all your GitHub repositories."
        echo -n "Continue? [Y/n]: "
        read confirm
        
        # Default to "Y" if Enter is pressed
        if [ -z "$confirm" ]; then
            confirm="Y"
        fi
        
        if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
            echo "Sync cancelled."
            sleep 1
            return
        fi
    fi
    
    # Initialize
    mkdir -p "$WORKDIR" "$LOCAL_BACKUP_DIR"
    cd "$WORKDIR" || exit 1
    echo "=== Sync Started ($sync_mode): $(date) ===" >> "$ERROR_LOG"
    echo "=== Sync Started ($sync_mode): $(date) ===" >> "$SUCCESS_LOG"
    
    echo ""
    echo "Fetching GitHub repositories..."
    
    # Get repositories from GitHub API
    PAGE=1
    TOTAL_PROCESSED=0
    TOTAL_SUCCESS=0
    
    while :; do
        # First, check if credentials are valid and get the raw response
        RESPONSE=$(curl -s -u "$GITHUB_USERNAME:$GITHUB_TOKEN" \
            "https://api.github.com/user/repos?per_page=100&page=$PAGE&visibility=all&affiliation=owner,collaborator")
        
        # Check if response is an error
        if echo "$RESPONSE" | jq -e '.message' &>/dev/null; then
            ERROR_MSG=$(echo "$RESPONSE" | jq -r '.message')
            echo "❌ GitHub API Error: $ERROR_MSG"
            echo "Please check your GitHub credentials in config.json"
            echo ""
            echo "Press any key to continue..."
            read -n 1
            return
        fi
        
        # Check if response is empty or end of pagination
        if [ -z "$RESPONSE" ] || [ "$RESPONSE" = "[]" ]; then
            break
        fi
        
        # Extract repository URLs
        REPOS=$(echo "$RESPONSE" | jq -r '.[]?.clone_url' 2>/dev/null)
        
        [ -z "$REPOS" ] && break
        
        for URL in $REPOS; do
            REPO_NAME=$(basename "$URL" .git)
            TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))
            
            echo ""
            echo "[$TOTAL_PROCESSED] Processing: $REPO_NAME"
            
            # Check if repo is empty
            GITHUB_REFS=$(git ls-remote --heads --tags "$URL" 2>/dev/null | wc -l)
            if [ "$GITHUB_REFS" -eq 0 ]; then
                echo "  ⚠️  Skipping empty repository"
                continue
            fi
            
            # Create GitLab repo if needed
            if [ "$sync_mode" = "both" ] || [ "$sync_mode" = "gitlab" ]; then
                echo "  🔨 Creating GitLab repository..."
                CREATE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$GITLAB_API/projects" \
                    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                    --data-urlencode "name=$REPO_NAME" \
                    --data-urlencode "visibility=private")
                
                HTTP_CODE=$(echo "$CREATE_RESPONSE" | tail -n1)
                if [ "$HTTP_CODE" = "201" ]; then
                    echo "  ✅ GitLab repo created"
                elif [ "$HTTP_CODE" = "400" ]; then
                    echo "  ✅ GitLab repo exists"
                else
                    echo "  ❌ GitLab creation failed (HTTP: $HTTP_CODE)"
                    continue
                fi
                
                # Mirror to GitLab
                echo "  🔄 Mirroring to GitLab..."
                rm -rf "$REPO_NAME.git"
                if git clone --mirror "$URL" "$REPO_NAME.git" &>/dev/null; then
                    cd "$REPO_NAME.git"
                    GITLAB_URL="https://oauth2:$GITLAB_TOKEN@gitlab.com/$GITLAB_USERNAME/$REPO_NAME.git"
                    git remote add gitlab "$GITLAB_URL"
                    
                    if git push --mirror gitlab &>/dev/null; then
                        echo "  ✅ GitLab sync successful"
                    else
                        echo "  ❌ GitLab push failed"
                    fi
                    cd ..
                else
                    echo "  ❌ Failed to clone for GitLab"
                fi
            fi
            
            # Local backup
            if [ "$sync_mode" = "both" ] || [ "$sync_mode" = "local" ]; then
                echo "  💾 Creating local backup..."
                rm -rf "$LOCAL_BACKUP_DIR/$REPO_NAME"
                if git clone "$URL" "$LOCAL_BACKUP_DIR/$REPO_NAME" &>/dev/null; then
                    echo "  ✅ Local backup successful"
                    TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
                else
                    echo "  ❌ Local backup failed"
                fi
            else
                TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
            fi
        done
        
        ((PAGE++))
    done
    
    echo ""
    echo "================================================"
    echo "              Sync Complete              "
    echo "================================================"
    echo "📊 Processed: $TOTAL_PROCESSED repositories"
    echo "✅ Successful: $TOTAL_SUCCESS repositories"
    
    # Update last sync timestamp if any repos were successfully synced
    if [ $TOTAL_SUCCESS -gt 0 ]; then
        update_last_sync
        echo "🕐 Last sync updated: $(get_last_sync_date)"
    fi
    
    echo ""
    echo "Press any key to continue..."
    read -n 1
}

# Process CLI arguments
if [ $# -gt 0 ]; then
    case "$1" in
        full-sync|--full-sync)
            # Sync to both GitLab and local backup
            perform_sync "both" "true"
            exit 0
            ;;
        gitlab-sync|--gitlab-sync)
            # Sync to GitLab only
            perform_sync "gitlab" "true"
            exit 0
            ;;
        local-sync|--local-sync)
            # Sync to local backup only
            perform_sync "local" "true"
            exit 0
            ;;
        status|--status)
            # Show quick status
            quick_status
            exit 0
            ;;
        auto-setup|--auto-setup)
            # Setup automatic sync with cron
            setup_auto_sync
            exit 0
            ;;
        help|--help|-h)
            # Display help message
            show_usage
            exit 0
            ;;
        *)
            echo "❌ Unknown command: $1"
            echo ""
            show_usage
            exit 1
            ;;
    esac
fi

# Main menu loop (interactive mode)
while true; do
    show_menu
    read choice
    
    case $choice in
        1) perform_sync "both" ;;      # Full sync: mirrors all repos to GitLab and creates local backups
        2) perform_sync "gitlab" ;;    # GitLab sync: mirrors all repos to GitLab only
        3) perform_sync "local" ;;     # Local sync: creates local backups only
        4) setup_auto_sync ;;           # Setup automatic sync: configure auto-syncing (WSL or cron)
        5) quick_status ;;              # View status: show detailed system and sync status
        0) echo ""; echo "👋 Goodbye!"; exit 0 ;;  # Exit the application
        *) echo "❌ Invalid option"; sleep 1 ;;    # Handle invalid input
    esac
done