#!/bin/bash

# Script metadata
readonly SCRIPT_VERSION="1.0.3"
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Configuration
readonly DEFAULT_PLEX_URL="http://localhost:32400"
readonly DEFAULT_OUTPUT_DIR="exports"
readonly LOG_DIR="logs"
readonly CONFIG_DIR="config"
readonly LOCK_FILE="/tmp/media-library-exporter.lock"
readonly LOG_FILE="${LOG_DIR}/media-library-exporter-${TIMESTAMP}.log"
readonly ERROR_LOG="${LOG_DIR}/media-library-exporter-${TIMESTAMP}-error.log"
readonly PAGE_SIZE=50

# Exit codes
readonly E_SUCCESS=0
readonly E_GENERAL_ERROR=1
readonly E_INVALID_ARGS=2
readonly E_MISSING_DEPS=3
readonly E_LOCK_EXISTS=4
readonly E_NETWORK_ERROR=5
readonly E_PERMISSION_ERROR=6

# Global variables
PLEX_URL="$DEFAULT_PLEX_URL"
PLEX_TOKEN=""
DEBUG=false
QUIET=false
FORCE=false

# Colors for output
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m' # No Color
else
    readonly RED=""
    readonly GREEN=""
    readonly YELLOW=""
    readonly BLUE=""
    readonly NC=""
fi

setup_logging() {
    # Save original stdout and stderr
    exec 3>&1 4>&2
    
    # If logging is disabled, only redirect log messages
    if [[ "$ENABLE_LOGGING" != "true" ]]; then
        # Define log functions to do nothing
        log() { :; }
        log_info() { :; }
        log_warn() { :; }
        log_error() { :; }
        log_debug() { :; }
        return
    fi

    mkdir -p "$LOG_DIR" "$CONFIG_DIR"
    if [[ ! -w "$LOG_DIR" ]]; then
        echo "Error: Cannot write to log directory $LOG_DIR" >&2
        exit $E_PERMISSION_ERROR
    fi
    
    # Set up logging to files
    if ! $QUIET; then
        # Create named pipes for logging
        LOG_PIPE=$(mktemp -u)
        mkfifo "$LOG_PIPE"
        ERROR_PIPE=$(mktemp -u)
        mkfifo "$ERROR_PIPE"
        
        # Start tee processes in background
        tee -a "$LOG_FILE" < "$LOG_PIPE" &
        TEE_PID=$!
        tee -a "$ERROR_LOG" >&2 < "$ERROR_PIPE" &
        TEE_ERROR_PID=$!
        
        # Open file descriptors
        exec 5> "$LOG_PIPE"
        exec 6> "$ERROR_PIPE"
        
        # Clean up function
        cleanup_logging() {
            exec 5>&-
            exec 6>&-
            kill $TEE_PID $TEE_ERROR_PID 2>/dev/null
            rm -f "$LOG_PIPE" "$ERROR_PIPE"
        }
        trap cleanup_logging EXIT
    else
        exec 5>>"$LOG_FILE"
        exec 6>>"$ERROR_LOG"
    fi
}

log() {
    local level=$1
    shift
    local message=$*
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ "$ENABLE_LOGGING" == "true" ]]; then
        case "$level" in
            "INFO")  echo -e "${GREEN}[$timestamp] [$level]${NC} $message" >&5 ;;
            "WARN")  echo -e "${YELLOW}[$timestamp] [$level]${NC} $message" >&6 ;;
            "ERROR") echo -e "${RED}[$timestamp] [$level]${NC} $message" >&6 ;;
            "DEBUG") 
                if $DEBUG; then
                    echo -e "${BLUE}[$timestamp] [$level]${NC} $message" >&5
                fi
                ;;
            *)      echo -e "[$timestamp] [$level] $message" >&5 ;;
        esac
    fi
}

log_info() {
    log "INFO" "$*"
}

log_warn() {
    log "WARN" "$*"
}

log_error() {
    log "ERROR" "$*"
}

log_debug() {
    if $DEBUG; then
        log "DEBUG" "$*"
    fi
}

tear_down_logging() {
    if [[ "$ENABLE_LOGGING" == "true" ]]; then
        exec 5>&- 2>/dev/null || true
        exec 6>&- 2>/dev/null || true
    fi
    exec 1>&3
    exec 2>&4
}

show_help() {
    cat <<EOF
Usage: $SCRIPT_NAME [options]

Media Library Exporter (for Plex) v${SCRIPT_VERSION}

Options:
  -t TOKEN    Plex authentication token (required)
  -u URL      Plex server URL (default: ${DEFAULT_PLEX_URL})
  -l          List all libraries
  -n NAME     Export specific library by name
  -o FILE     Output file
  -d DIR      Output directory (default: ${DEFAULT_OUTPUT_DIR})
  -f          Force overwrite of existing files
  -q          Quiet mode (no stdout output)
  -v          Debug mode (verbose output)
  -h          Show this help message
  --version   Show version information

Examples:
  ./$SCRIPT_NAME -t YOUR_TOKEN -l
  ./$SCRIPT_NAME -t YOUR_TOKEN -n "Movies" -o movies.csv
  ./$SCRIPT_NAME -t YOUR_TOKEN -u http://plex.local:32400

For more information, please visit:
https://github.com/jeremehancock/media-library-exporter
EOF
    exit $E_SUCCESS
}

show_version() {
    echo "Media Library Exporter (for Plex) v${SCRIPT_VERSION}"
    exit $E_SUCCESS
}

check_dependencies() {
    local missing_deps=()
    
    for cmd in curl sed grep date readlink; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if ((${#missing_deps[@]} > 0)); then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please install these dependencies and try again."
        exit $E_MISSING_DEPS
    fi
}

# Lock management
create_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            # Direct output to stderr, bypassing logging system
            echo -e "${RED}Error: Another instance is running with PID $pid${NC}" >&2
            exit $E_LOCK_EXISTS
        else
            echo -e "${YELLOW}Warning: Stale lock file found. Removing...${NC}" >&2
            remove_lock
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap remove_lock EXIT
}

remove_lock() {
    rm -f "$LOCK_FILE"
}

# HTML entity decoder
decode_html() {
    local text="$1"
	local entities=(
		's/&amp;/\&/g'
		's/&#39;/'"'"'/g'
		's/&quot;/"/g'
		's/&lt;/</g'
		's/&gt;/>/g'
		's/&#8216;/'"'"'/g'
		's/&#8217;/'"'"'/g'
		's/&#8220;/"/g'
		's/&#8221;/"/g'
		's/&#8230;/.../g'
		's/&ndash;/-/g'
		's/&mdash;/--/g'
		's/&nbsp;/ /g'
		's/&rsquo;/'"'"'/g'
		's/&lsquo;/'"'"'/g'
		's/&rdquo;/"/g'
		's/&ldquo;/"/g'
		's/&#8211;/-/g'
		's/&#8212;/--/g'
		's/&#x27;/'"'"'/g'
		's/&#179;/³/g'
		's/&#189;/½/g'
	)
    
    for entity in "${entities[@]}"; do
        text=$(echo "$text" | sed "$entity")
    done
    echo "$text"
}

make_api_request() {
    local endpoint=$1
    local retry_count=3
    local retry_delay=5
    local response=""
    local full_response=""
    local attempt=1
    local start=0
    local total_size=0
    local page_count=0
    local header=""
    local footer=""
    
    # Check if endpoint already has query parameters
    local separator
    if [[ "$endpoint" == *"?"* ]]; then
        separator="&"
    else
        separator="?"
    fi
    
    # First, get the total size
    local size_check
    size_check=$(curl -s -f -H "X-Plex-Token: $PLEX_TOKEN" \
        -H "Accept: application/xml" \
        -H "X-Plex-Client-Identifier: media-library-exporter-${SCRIPT_VERSION}" \
        -H "X-Plex-Product: Media Library Exporter (for Plex)" \
        -H "X-Plex-Version: ${SCRIPT_VERSION}" \
        "${PLEX_URL}${endpoint}${separator}X-Plex-Container-Start=0&X-Plex-Container-Size=0")
    
    if [[ $? -eq 0 ]]; then
        total_size=$(echo "$size_check" | grep -o 'totalSize="[^"]*"' | head -n1 | cut -d'"' -f2)
        total_size=${total_size:-0}
        
        # Calculate number of pages
        page_count=$(( (total_size + PAGE_SIZE - 1) / PAGE_SIZE ))
        
        log_debug "Total items: $total_size, Page size: $PAGE_SIZE, Total pages: $page_count"
    else
        log_error "Failed to get total size for endpoint: $endpoint"
        return $E_NETWORK_ERROR
    fi
    
    # Initialize full response with XML header
    full_response="<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<MediaContainer>"
    
    # Fetch data page by page
    while ((start < total_size)); do
        attempt=1
        while ((attempt <= retry_count)); do
            local current_page=$(( start / PAGE_SIZE + 1 ))
            if ! $QUIET; then
                printf "\r${BLUE}Fetching page ${GREEN}%d${BLUE}/${GREEN}%d${NC} (${YELLOW}50${BLUE} items per page)" "$current_page" "$page_count"
            fi
            
            response=$(curl -s -f -H "X-Plex-Token: $PLEX_TOKEN" \
                -H "Accept: application/xml" \
                -H "X-Plex-Client-Identifier: media-library-exporter-${SCRIPT_VERSION}" \
                -H "X-Plex-Product: Media Library Exporter (for Plex)" \
                -H "X-Plex-Version: ${SCRIPT_VERSION}" \
                "${PLEX_URL}${endpoint}${separator}X-Plex-Container-Start=$start&X-Plex-Container-Size=$PAGE_SIZE")
            
            if [[ $? -eq 0 ]]; then
                # Extract content between MediaContainer tags
                local content
                content=$(echo "$response" | awk '/<MediaContainer/,/<\/MediaContainer>/' | \
                         grep -v "<MediaContainer" | grep -v "</MediaContainer>")
                
                # Append the content to our full response
                full_response="${full_response}\n${content}"
                break
            fi
            
            log_warn "API request failed for page $current_page (attempt $attempt/$retry_count). Retrying in ${retry_delay}s..."
            sleep "$retry_delay"
            ((attempt++))
        done
        
        if ((attempt > retry_count)); then
            log_error "API request failed after $retry_count attempts for page starting at offset $start"
            return $E_NETWORK_ERROR
        fi
        
        start=$((start + PAGE_SIZE))
        
        # Add a small delay between requests to avoid overwhelming the server
        sleep 0.5
    done
    
    # Close the MediaContainer tag
    full_response="${full_response}\n</MediaContainer>"
    
    if ! $QUIET; then
        echo -e "\n${GREEN}Successfully retrieved all pages${NC}"
    fi
    
    echo -e "$full_response"
    return 0
}

get_libraries() {
    log_info "Retrieving library sections..."
    local response
    response=$(make_api_request "/library/sections")
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to retrieve library sections"
        return $E_NETWORK_ERROR
    fi
    
    echo -e "${BLUE}Available libraries:${NC}"
    echo "$response" | sed "s/<Directory/\n<Directory/g" | grep "<Directory" | \
    while read -r line; do
        local title key type
        title=$(echo "$line" | grep -o 'title="[^"]*"' | cut -d'"' -f2)
        key=$(echo "$line" | grep -o 'key="[^"]*"' | cut -d'"' -f2)
        type=$(echo "$line" | grep -o 'type="[^"]*"' | cut -d'"' -f2)
        
        if [[ -n "$title" && -n "$key" ]]; then
            echo -e "  ${GREEN}$title${NC} (ID: ${BLUE}$key${NC}, Type: ${YELLOW}$type${NC})"
        fi
    done
}

get_library_type() {
    local library_id=$1
    local response
    
    response=$(make_api_request "/library/sections")
    
    if [[ $? -ne 0 ]]; then
        return $E_NETWORK_ERROR
    fi
    
    echo "$response" | sed "s/<Directory/\n<Directory/g" | \
        grep "<Directory" | grep "key=\"$library_id\"" | \
        grep -o 'type="[^"]*"' | cut -d'"' -f2
}

export_library() {
    local library_id=$1
    local output_file=$2
    local library_type
    
    library_type=$(get_library_type "$library_id")
    echo -e "${BLUE}Exporting library ID ${GREEN}$library_id${BLUE} (type: ${YELLOW}$library_type${BLUE}) to ${GREEN}$output_file${NC}"
    
    # Check if output file already exists
    if [[ -f "$output_file" ]]; then
        # Handle both "true" string from config and true boolean
        if [[ "$FORCE" == "true" || "$FORCE" == true ]]; then
            echo -e "${YELLOW}Warning: Overwriting existing file $output_file${NC}" >&2
            rm -f "$output_file"
        else
            echo -e "${RED}Error: Output file $output_file already exists. Use -f to force overwrite.${NC}" >&2
            return $E_GENERAL_ERROR
        fi
    fi
    
    # Create output directory if it doesn't exist
    mkdir -p "$(dirname "$output_file")"
    
    case "$library_type" in
        "movie")
            export_movie_library "$library_id" "$output_file"
            ;;
        "show")
            export_tv_library "$library_id" "$output_file"
            ;;
        "artist")
            export_music_library "$library_id" "$output_file"
            ;;
        *)
            echo -e "${RED}Error: Unknown library type: '$library_type' for library ID: $library_id${NC}" >&2
            return $E_GENERAL_ERROR
            ;;
    esac
    
    if [[ -s "$output_file" ]]; then
        echo -e "${GREEN}Successfully exported to $output_file${NC}"
        if $DEBUG; then
            echo -e "${BLUE}First few lines of export:${NC}"
            head -n 5 "$output_file"
        fi
    else
        echo -e "${YELLOW}Warning: No data was exported to $output_file${NC}"
    fi
}

export_movie_library() {
    local library_id=$1
    local output_file=$2
    local total_size=0
    local current_item=0
    
    echo "title,year,duration" > "$output_file"
    echo -e "${BLUE}Exporting movie library...${NC}"
    
    # First, get the total size
    local size_check
    size_check=$(curl -s -f -H "X-Plex-Token: $PLEX_TOKEN" \
        -H "Accept: application/xml" \
        "${PLEX_URL}/library/sections/$library_id/all?X-Plex-Container-Start=0&X-Plex-Container-Size=0")
    
    if [[ $? -eq 0 ]]; then
        total_size=$(echo "$size_check" | grep -o 'totalSize="[^"]*"' | head -n1 | cut -d'"' -f2)
        total_size=${total_size:-0}
    else
        echo -e "${RED}Error: Failed to get library size${NC}" >&2
        return $E_NETWORK_ERROR
    fi
    
    local start=0
    local page_count=$(( (total_size + PAGE_SIZE - 1) / PAGE_SIZE ))
    
    while ((start < total_size)); do
        local current_page=$(( start / PAGE_SIZE + 1 ))
        if ! $QUIET; then
            printf "\r${BLUE}Fetching page ${GREEN}%d${BLUE}/${GREEN}%d${NC} (${YELLOW}50${BLUE} items per page)" "$current_page" "$page_count"
        fi
        
        local response
        response=$(curl -s -f -H "X-Plex-Token: $PLEX_TOKEN" \
            -H "Accept: application/xml" \
            "${PLEX_URL}/library/sections/$library_id/all?X-Plex-Container-Start=$start&X-Plex-Container-Size=$PAGE_SIZE")
        
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}Error: Failed to retrieve page $current_page${NC}" >&2
            return $E_NETWORK_ERROR
        fi
        
        # Process each Video element in this page
        echo "$response" | grep -o '<Video[^>]*>' | while read -r line; do
            ((current_item++))
            
            local title year duration
            
            title=$(echo "$line" | grep -o 'title="[^"]*"' | cut -d'"' -f2)
            year=$(echo "$line" | grep -o 'year="[^"]*"' | cut -d'"' -f2)
            duration=$(echo "$line" | grep -o 'duration="[^"]*"' | cut -d'"' -f2)
            
            # Convert duration from milliseconds to minutes
            if [[ -n "$duration" ]]; then
                duration=$(( duration / 60000 ))
            fi
            
            # Default values for missing fields
            year=${year:-""}
            duration=${duration:-""}
            
            # Decode HTML entities and escape for CSV
            title=$(decode_html "$title")
            title=$(echo "$title" | sed 's/"/""/g')
            
            echo "\"$title\",$year,$duration" >> "$output_file"
        done
        
        start=$((start + PAGE_SIZE))
        sleep 0.5  # Small delay between pages
    done
    
    echo -e "\n${GREEN}Movie export complete${NC}"
    
    # Verify the export
    local exported_count
    exported_count=$(wc -l < "$output_file")
    ((exported_count--))  # Subtract 1 for the header row
    
    if [[ $exported_count -eq 0 ]]; then
        echo -e "${YELLOW}Warning: No movies were exported${NC}" >&2
        return 1
    elif [[ $exported_count -lt $total_size ]]; then
        echo -e "${YELLOW}Warning: Only exported $exported_count out of $total_size movies${NC}" >&2
    else
        echo -e "${GREEN}Successfully exported $exported_count movies${NC}"
    fi
}

export_tv_library() {
    local library_id=$1
    local output_file=$2
    local total_size=0
    local current_item=0
    
    echo "series_title,total_episodes,seasons,year,duration_minutes" > "$output_file"
    echo -e "${BLUE}Exporting TV library...${NC}"
    
    # Get total size
    local size_check
    size_check=$(curl -s -f -H "X-Plex-Token: $PLEX_TOKEN" \
        -H "Accept: application/xml" \
        "${PLEX_URL}/library/sections/$library_id/all?type=2&X-Plex-Container-Start=0&X-Plex-Container-Size=0")
    
    if [[ $? -eq 0 ]]; then
        total_size=$(echo "$size_check" | grep -o 'totalSize="[^"]*"' | head -n1 | cut -d'"' -f2)
        total_size=${total_size:-0}
    else
        echo -e "${RED}Error: Failed to get library size${NC}" >&2
        return $E_NETWORK_ERROR
    fi
    
    local start=0
    local page_count=$(( (total_size + PAGE_SIZE - 1) / PAGE_SIZE ))
    
    while ((start < total_size)); do
        local current_page=$(( start / PAGE_SIZE + 1 ))
        if ! $QUIET; then
            printf "\r${BLUE}Fetching page ${GREEN}%d${BLUE}/${GREEN}%d${NC} (${YELLOW}50${BLUE} items per page)" "$current_page" "$page_count"
        fi
        
        local response
        response=$(curl -s -f -H "X-Plex-Token: $PLEX_TOKEN" \
            -H "Accept: application/xml" \
            "${PLEX_URL}/library/sections/$library_id/all?type=2&X-Plex-Container-Start=$start&X-Plex-Container-Size=$PAGE_SIZE")
        
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}Error: Failed to retrieve page $current_page${NC}" >&2
            return $E_NETWORK_ERROR
        fi
        
        # Process each Directory element in this page
        echo "$response" | grep -o '<Directory[^>]*>' | while read -r line; do
            ((current_item++))
            
            local title episodes seasons year duration
            
            title=$(echo "$line" | grep -o 'title="[^"]*"' | cut -d'"' -f2)
            episodes=$(echo "$line" | grep -o 'leafCount="[^"]*"' | cut -d'"' -f2)
            seasons=$(echo "$line" | grep -o 'childCount="[^"]*"' | cut -d'"' -f2)
            year=$(echo "$line" | grep -o 'year="[^"]*"' | cut -d'"' -f2)
            duration=$(echo "$line" | grep -o 'duration="[^"]*"' | cut -d'"' -f2)
            
            if [[ -n "$duration" ]]; then
                duration=$(( duration / 60000 ))
            fi
            
            # Default values for missing fields
            episodes=${episodes:-"0"}
            seasons=${seasons:-"0"}
            year=${year:-""}
            duration=${duration:-""}
            
            # Decode HTML entities and escape for CSV
            title=$(decode_html "$title")
            title=$(echo "$title" | sed 's/"/""/g')
            
            echo "\"$title\",$episodes,$seasons,$year,$duration" >> "$output_file"
        done
        
        start=$((start + PAGE_SIZE))
        sleep 0.5  # Small delay between pages
    done
    
    echo -e "\n${GREEN}TV export complete${NC}"
    
    # Verify the export
    local exported_count
    exported_count=$(wc -l < "$output_file")
    ((exported_count--))  # Subtract 1 for the header row
    
    if [[ $exported_count -eq 0 ]]; then
        echo -e "${YELLOW}Warning: No TV shows were exported${NC}" >&2
        return 1
    elif [[ $exported_count -lt $total_size ]]; then
        echo -e "${YELLOW}Warning: Only exported $exported_count out of $total_size TV shows${NC}" >&2
    else
        echo -e "${GREEN}Successfully exported $exported_count TV shows${NC}"
    fi
}

export_music_library() {
    local library_id=$1
    local output_file=$2
    local total_size=0
    local current_item=0
    
    echo "artist,album,track,track_number,disc_number,duration" > "$output_file"
    echo -e "${BLUE}Exporting music library...${NC}"
    
    # Get total size
    local size_check
    size_check=$(curl -s -f -H "X-Plex-Token: $PLEX_TOKEN" \
        -H "Accept: application/xml" \
        "${PLEX_URL}/library/sections/$library_id/all?type=10&X-Plex-Container-Start=0&X-Plex-Container-Size=0")
    
    if [[ $? -eq 0 ]]; then
        total_size=$(echo "$size_check" | grep -o 'totalSize="[^"]*"' | head -n1 | cut -d'"' -f2)
        total_size=${total_size:-0}
    else
        echo -e "${RED}Error: Failed to get library size${NC}" >&2
        return $E_NETWORK_ERROR
    fi
    
    local start=0
    local page_count=$(( (total_size + PAGE_SIZE - 1) / PAGE_SIZE ))
    
    while ((start < total_size)); do
        local current_page=$(( start / PAGE_SIZE + 1 ))
        if ! $QUIET; then
            printf "\r${BLUE}Fetching page ${GREEN}%d${BLUE}/${GREEN}%d${NC} (${YELLOW}50${BLUE} items per page)" "$current_page" "$page_count"
        fi
        
        local response
        response=$(curl -s -f -H "X-Plex-Token: $PLEX_TOKEN" \
            -H "Accept: application/xml" \
            "${PLEX_URL}/library/sections/$library_id/all?type=10&X-Plex-Container-Start=$start&X-Plex-Container-Size=$PAGE_SIZE")
        
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}Error: Failed to retrieve page $current_page${NC}" >&2
            return $E_NETWORK_ERROR
        fi
        
        # Process each Track element in this page
        echo "$response" | grep -o '<Track[^>]*>' | while read -r line; do
            ((current_item++))
            
            local artist album track track_num disc_num duration
            
            artist=$(echo "$line" | grep -o 'grandparentTitle="[^"]*"' | cut -d'"' -f2)
            album=$(echo "$line" | grep -o 'parentTitle="[^"]*"' | cut -d'"' -f2)
            track=$(echo "$line" | grep -o 'title="[^"]*"' | cut -d'"' -f2)
            track_num=$(echo "$line" | grep -o 'index="[^"]*"' | cut -d'"' -f2)
            disc_num=$(echo "$line" | grep -o 'parentIndex="[^"]*"' | cut -d'"' -f2)
            duration=$(echo "$line" | grep -o 'duration="[^"]*"' | cut -d'"' -f2)
            
            if [[ -n "$duration" ]]; then
                minutes=$(( duration / 60000 ))
                seconds=$(( (duration % 60000) / 1000 ))
                duration="${minutes}:$(printf "%02d" $seconds)"
            fi
            
            # Default values for missing fields
            track_num=${track_num:-""}
            disc_num=${disc_num:-""}
            duration=${duration:-""}
            
            # Decode HTML entities and escape for CSV
            artist=$(decode_html "$artist")
            album=$(decode_html "$album")
            track=$(decode_html "$track")
            artist=$(echo "$artist" | sed 's/"/""/g')
            album=$(echo "$album" | sed 's/"/""/g')
            track=$(echo "$track" | sed 's/"/""/g')
            
            echo "\"$artist\",\"$album\",\"$track\",$track_num,$disc_num,\"$duration\"" >> "$output_file"
        done
        
        start=$((start + PAGE_SIZE))
        sleep 0.5  # Small delay between pages
    done
    
    echo -e "\n${GREEN}Music export complete${NC}"
    
    # Verify the export
    local exported_count
    exported_count=$(wc -l < "$output_file")
    ((exported_count--))  # Subtract 1 for the header row
    
    if [[ $exported_count -eq 0 ]]; then
        echo -e "${YELLOW}Warning: No tracks were exported${NC}" >&2
        return 1
    elif [[ $exported_count -lt $total_size ]]; then
        echo -e "${YELLOW}Warning: Only exported $exported_count out of $total_size tracks${NC}" >&2
    else
        echo -e "${GREEN}Successfully exported $exported_count tracks${NC}"
    fi
}

parse_arguments() {
    
    while getopts ":t:u:ln:o:d:fqvh-:" opt; do
        case $opt in
            f) FORCE=true ;;  # Make sure this line is present
            -)
                case "${OPTARG}" in
                    version)
                        show_version
                        ;;
                    *)
                        log_error "Invalid option: --${OPTARG}"
                        show_help
                        ;;
                esac
                ;;
            t) PLEX_TOKEN="$OPTARG" ;;
            u) PLEX_URL="$OPTARG" ;;
            l) LIST_LIBRARIES=true ;;
            n) LIBRARY_NAME="$OPTARG" ;;
            o) OUTPUT_FILE="$OPTARG" ;;
            d) OUTPUT_DIR="$OPTARG" ;;
            f) FORCE=true ;;
            q) QUIET=true ;;
            v) DEBUG=true ;;
            h) show_help ;;
            \?) log_error "Invalid option: -$OPTARG"; show_help ;;
            :) log_error "Option -$OPTARG requires an argument"; show_help ;;
        esac
    done
}

load_config() {
    local config_file="${CONFIG_DIR}/media-library-exporter.conf"
    
    # Create default config if it doesn't exist
    if [[ ! -f "$config_file" ]]; then
        mkdir -p "$CONFIG_DIR"
        cat > "$config_file" <<EOF
# Media Library Exporter (for Plex) Configuration File
# Location: config/media-library-exporter.conf

###################
# Server Settings #
###################

# Plex server URL (required)
PLEX_URL="http://localhost:32400"

# Your Plex authentication token (required)
# To find your token: https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/
PLEX_TOKEN=""

########################
# Connection Settings  #
########################

# Number of retry attempts for failed API calls
RETRY_COUNT=3

# Delay between retries in seconds
RETRY_DELAY=5

###################
# Export Settings #
###################

# Default output directory for exports
OUTPUT_DIR="exports"

# Date format for timestamps (uses date command format)
DATE_FORMAT="%Y-%m-%d %H:%M:%S"

# Force overwrite existing files (true/false)
FORCE=false

###################
# Debug Settings  #
###################

# Enable debug mode (true/false)
DEBUG=false

# Enable logging (true/false)
ENABLE_LOGGING=false

# Whether to run in quiet mode (true/false)
QUIET=false
EOF
        echo -e "${GREEN}Created default configuration file: $config_file${NC}"
    fi
    
    # Source the config file
    if [[ -r "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
        log_debug "Loaded configuration from $config_file"
    else
        echo -e "${YELLOW}Warning: Cannot read configuration file: $config_file${NC}" >&2
    fi
}

main() {
    load_config
    
    parse_arguments "$@"
    
    check_dependencies
    
    setup_logging
    
    create_lock
    
    # Validate required parameters
    if [[ -z "$PLEX_TOKEN" ]]; then
        log_error "Error: Plex token is required. Use -t option."
        exit $E_INVALID_ARGS
    fi
    
    # Set default output file if not specified
    if [[ -z "$OUTPUT_FILE" ]]; then
        if [[ -n "$LIBRARY_NAME" ]]; then
            # Use library name as the default filename, replacing spaces with underscores
            OUTPUT_FILE="${LIBRARY_NAME// /-}.csv"
        else
            OUTPUT_FILE="library_export.csv"
        fi
    fi
    
    # If output directory is specified, prepend it to output file
    if [[ -n "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR"
        OUTPUT_FILE="${OUTPUT_DIR}/${OUTPUT_FILE}"
    fi
    
    # Main execution logic
    if [[ "$LIST_LIBRARIES" = true ]]; then
        log_info "Listing available libraries..."
        get_libraries
        exit $E_SUCCESS
    fi
    
    # Export specific library if requested
    if [[ -n "$LIBRARY_NAME" ]]; then
        log_info "Exporting library: $LIBRARY_NAME"
        library_id=$(curl -s -H "X-Plex-Token: $PLEX_TOKEN" \
            -H "Accept: application/xml" \
            "$PLEX_URL/library/sections" | \
            sed "s/<Directory/\n<Directory/g" | \
            grep "<Directory" | \
            grep "title=\"$LIBRARY_NAME\"" | \
            grep -o 'key="[^"]*"' | \
            cut -d'"' -f2)
        
        if [[ -z "$library_id" ]]; then
            log_error "Error: Library '$LIBRARY_NAME' not found"
            exit $E_GENERAL_ERROR
        fi
        export_library "$library_id" "$OUTPUT_FILE"
    else
        # Export all libraries
        log_info "Exporting all libraries..."
        mkdir -p exports
        response=$(make_api_request "/library/sections")
        
        if [[ $? -ne 0 ]]; then
            log_error "Failed to retrieve library sections"
            exit $E_NETWORK_ERROR
        fi
        
        echo "$response" | sed "s/<Directory/\n<Directory/g" | grep "<Directory" | \
        while IFS= read -r line; do
            title=$(echo "$line" | grep -o 'title="[^"]*"' | cut -d'"' -f2)
            key=$(echo "$line" | grep -o 'key="[^"]*"' | cut -d'"' -f2)
            if [[ -n "$title" && -n "$key" ]]; then
                output_file="exports/${title// /-}.csv"
                export_library "$key" "$output_file"
            fi
        done
    fi
}

# Execute main function with all arguments
main "$@"
