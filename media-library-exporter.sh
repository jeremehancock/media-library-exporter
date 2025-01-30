#!/bin/bash

# Script metadata
readonly SCRIPT_VERSION="1.1.0"
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

check_dependencies() {
    local missing_deps=()
    
    for cmd in curl sed grep date readlink xmllint; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if ((${#missing_deps[@]} > 0)); then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please install these dependencies and try again."
        log_error "Note: xmllint is typically provided by the libxml2-utils package"
        exit $E_MISSING_DEPS
    fi
}

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

parse_xml_attribute() {
    local xml="$1"
    local xpath="$2"
    local attr="$3"
    
    echo "$xml" | xmllint --xpath "string($xpath/@$attr)" - 2>/dev/null
}

parse_xml_count() {
    local xml="$1"
    local xpath="$2"
    
    echo "$xml" | xmllint --xpath "count($xpath)" - 2>/dev/null
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
  --update    Update to the latest version

Examples:
  ./$SCRIPT_NAME -t YOUR_TOKEN -l
  ./$SCRIPT_NAME -t YOUR_TOKEN -n "Movies" -o movies.csv
  ./$SCRIPT_NAME -t YOUR_TOKEN -u http://plex.local:32400

For more information, please visit:
https://github.com/jeremehancock/media-library-exporter
EOF
    exit $E_SUCCESS
}

check_version() {
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}Error: curl is required for version checking${NC}"
        return 1
    fi

    local remote_version
    remote_version=$(curl -s https://raw.githubusercontent.com/jeremehancock/media-library-exporter/refs/heads/main/media-library-exporter.sh | grep "^readonly SCRIPT_VERSION=" | cut -d'"' -f2)
    
    if [[ -z "$remote_version" ]]; then
        echo -e "${RED}Error: Could not fetch remote version${NC}"
        return 1
    fi

    # Compare versions (assuming semantic versioning x.y.z format)
    if [[ "$remote_version" != "$SCRIPT_VERSION" ]]; then
        local current_parts=( ${SCRIPT_VERSION//./ } )
        local remote_parts=( ${remote_version//./ } )
        
        for i in {0..2}; do
            if (( ${remote_parts[$i]:-0} > ${current_parts[$i]:-0} )); then
                echo -e "${RED}Update available: v$SCRIPT_VERSION → v$remote_version${NC}"
                echo -e "${YELLOW}Run with --update to update to the latest version${NC}"
                return 0
            elif (( ${remote_parts[$i]:-0} < ${current_parts[$i]:-0} )); then
                break
            fi
        done
    fi
}

update_script() {
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}Error: curl is required for updating${NC}"
        return 1
    fi

    echo -e "${BLUE}Updating script...${NC}"
    
    # Create backups directory if it doesn't exist
    local backup_dir="${SCRIPT_DIR}/backups"
    mkdir -p "$backup_dir"

    # Create backup of current script with version number
    local backup_file="${backup_dir}/${SCRIPT_NAME}.v${SCRIPT_VERSION}.backup"
    cp "$0" "$backup_file"
    
    # Download new version
    if curl -o "$SCRIPT_NAME" -L https://raw.githubusercontent.com/jeremehancock/media-library-exporter/main/media-library-exporter.sh; then
        chmod +x "$SCRIPT_NAME"
        echo -e "${GREEN}Successfully updated script${NC}"
        echo -e "${BLUE}Previous version backed up to ${GREEN}$backup_file${NC}"
    else
        echo -e "${RED}Update failed${NC}"
        # Restore backup
        mv "$backup_file" "$SCRIPT_NAME"
        return 1
    fi
}

show_version() {
    echo "Media Library Exporter (for Plex) v${SCRIPT_VERSION}"
    check_version
    exit $E_SUCCESS
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

# Lock management
create_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
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

make_api_request() {
    local endpoint=$1
    local progress_to_stderr=${2:-false}
    local retry_count=3
    local retry_delay=5
    local response=""
    local start=0
    local total_size=0
    local page_count=0
    
    # Determine the proper separator for URL parameters
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
        total_size=$(echo "$size_check" | xmllint --xpath "string(//MediaContainer/@totalSize)" - 2>/dev/null)
        total_size=${total_size:-0}
        
        # Calculate number of pages
        page_count=$(( (total_size + PAGE_SIZE - 1) / PAGE_SIZE ))
        
        if $DEBUG; then
            log_debug "Total items: $total_size, Page size: $PAGE_SIZE, Total pages: $page_count"
        fi
    else
        log_error "Failed to get total size for endpoint: $endpoint"
        return $E_NETWORK_ERROR
    fi
    
    # Initialize concatenated response with just the opening tag
    local concatenated_response="<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<MediaContainer>"
    
    # Fetch data page by page
    while ((start < total_size)); do
        local attempt=1
        while ((attempt <= retry_count)); do
            local current_page=$(( start / PAGE_SIZE + 1 ))
            if ! $QUIET; then
                if $progress_to_stderr; then
                    printf "\r${BLUE}Fetching page ${GREEN}%d${BLUE}/${GREEN}%d${NC} (${YELLOW}%d${BLUE} items per page)" "$current_page" "$page_count" "$PAGE_SIZE" >&2
                else
                    printf "\r${BLUE}Fetching page ${GREEN}%d${BLUE}/${GREEN}%d${NC} (${YELLOW}%d${BLUE} items per page)" "$current_page" "$page_count" "$PAGE_SIZE"
                fi
            fi
            
            local page_response
            page_response=$(curl -s -f -H "X-Plex-Token: $PLEX_TOKEN" \
                -H "Accept: application/xml" \
                -H "X-Plex-Client-Identifier: media-library-exporter-${SCRIPT_VERSION}" \
                -H "X-Plex-Product: Media Library Exporter (for Plex)" \
                -H "X-Plex-Version: ${SCRIPT_VERSION}" \
                "${PLEX_URL}${endpoint}${separator}X-Plex-Container-Start=$start&X-Plex-Container-Size=$PAGE_SIZE")
            
            if [[ $? -eq 0 ]]; then
                # Extract just the inner content, excluding MediaContainer tags
                local inner_content
                inner_content=$(echo "$page_response" | 
                    sed -n '/<MediaContainer/,/<\/MediaContainer>/p' |
                    sed '1d;$d')  # Remove first and last lines (MediaContainer tags)
                
                # Append the inner content to our concatenated response
                concatenated_response="${concatenated_response}\n${inner_content}"
                break
            fi
            
            log_warn "API request failed for page $current_page (attempt $attempt/$retry_count). Retrying in ${retry_delay}s..." >&2
            sleep "$retry_delay"
            ((attempt++))
        done
        
        if ((attempt > retry_count)); then
            log_error "API request failed after $retry_count attempts for page starting at offset $start"
            return $E_NETWORK_ERROR
        fi
        
        start=$((start + PAGE_SIZE))
        sleep 0.5  # Small delay between requests
    done
    
    # Close the concatenated response
    concatenated_response="${concatenated_response}\n</MediaContainer>"
    
    if ! $QUIET; then
        if $progress_to_stderr; then
            echo -e "\n${GREEN}Successfully retrieved all pages${NC}" >&2
        else
            echo -e "\n${GREEN}Successfully retrieved all pages${NC}"
        fi
    fi
    
    echo -e "$concatenated_response"
    return 0
}

get_libraries() {
    log_info "Retrieving library sections..."
    local response
    response=$(make_api_request "/library/sections")
    local request_status=$?
    
    if $DEBUG; then
        log_debug "API request status: $request_status"
        log_debug "Raw response length: ${#response}"
        log_debug "Raw response:"
        log_debug "$response"
    fi
    
    if [[ $request_status -ne 0 ]]; then
        log_error "Failed to retrieve library sections"
        return $E_NETWORK_ERROR
    fi
    
    echo -e "${BLUE}Available libraries:${NC}"
    
    # Process the response if it exists
    if [[ -n "$response" ]]; then
        # Clean up the XML response - remove progress messages and fix XML structure
        local cleaned_response
        cleaned_response=$(echo "$response" | 
            sed -e '/Fetching page/d' | # Remove progress messages
            sed -e '/Successfully retrieved/d' | # Remove success messages
            sed -e 's/<?xml[^>]*?>//g' | # Remove all XML declarations
            sed -e 's/<MediaContainer>//' | # Remove outer MediaContainer
            sed -e 's/<\/MediaContainer><\/MediaContainer>/<\/MediaContainer>/' | # Fix nested closing tags
            sed -e '1i<?xml version="1.0" encoding="UTF-8"?>\n<MediaContainer>' # Add single XML declaration
        )
        
        if $DEBUG; then
            log_debug "Cleaned XML response:"
            log_debug "$cleaned_response"
        fi
        
        # Get the count of Directory elements from cleaned response
        local count=0
        count=$(echo "$cleaned_response" | xmllint --xpath "count(//Directory)" - 2>/dev/null || echo 0)
        
        if $DEBUG; then
            log_debug "Found $count libraries"
            log_debug "Attempting to parse each library..."
        fi
        
        if [[ $count -eq 0 ]]; then
            if $DEBUG; then
                log_debug "No libraries found in response."
            fi
            log_error "No libraries found in Plex server response"
            return $E_NETWORK_ERROR
        fi
        
        for ((i=1; i<=count; i++)); do
            local title key type
            title=$(echo "$cleaned_response" | xmllint --xpath "string(//Directory[$i]/@title)" - 2>/dev/null || echo "")
            key=$(echo "$cleaned_response" | xmllint --xpath "string(//Directory[$i]/@key)" - 2>/dev/null || echo "")
            type=$(echo "$cleaned_response" | xmllint --xpath "string(//Directory[$i]/@type)" - 2>/dev/null || echo "")
            
            if $DEBUG; then
                log_debug "Library $i - Title: '$title', Key: '$key', Type: '$type'"
            fi
            
            if [[ -n "$title" && -n "$key" ]]; then
                echo -e "  ${GREEN}$title${NC} (ID: ${BLUE}$key${NC}, Type: ${YELLOW}$type${NC})"
            fi
        done
    else
        log_error "No response received from Plex server"
        return $E_NETWORK_ERROR
    fi
}

get_library_type() {
    local library_id=$1
    local response
    
    if $DEBUG; then
        log_debug "Getting library type for ID: $library_id"
    fi
    
    # Make a direct call to get sections
    response=$(curl -s -H "X-Plex-Token: $PLEX_TOKEN" \
        -H "Accept: application/xml" \
        "${PLEX_URL}/library/sections")
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to get library sections when determining type"
        return $E_NETWORK_ERROR
    fi
    
    if $DEBUG; then
        log_debug "Response received, searching for library type..."
        log_debug "Raw Response (first 500 chars):"
        log_debug "${response:0:500}"
    fi
    
    # First try xmllint to get the library type
    local library_type
    library_type=$(echo "$response" | xmllint --xpath "string(//Directory[@key='$library_id']/@type)" - 2>/dev/null)
    
    if [[ -z "$library_type" ]]; then
        log_error "Could not find type for library ID $library_id"
        if $DEBUG; then
            log_debug "Full response:"
            log_debug "$response"
        fi
        return 1
    fi
    
    if $DEBUG; then
        log_debug "Found library type: $library_type"
    fi
    
    echo "$library_type"
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
    
    echo "title,year,duration" > "$output_file"
    echo -e "${BLUE}Exporting movie library...${NC}"
    
    local response
    response=$(make_api_request "/library/sections/$library_id/all?type=1" true)
    local api_status=$?
    
    if [[ $api_status -ne 0 ]]; then
        log_error "Failed to retrieve movie library"
        return $E_NETWORK_ERROR
    fi

    # Clean up the XML response
    local cleaned_response
    cleaned_response=$(echo "$response" | 
        sed -e '/Fetching page/d' | # Remove progress messages
        sed -e '/Successfully retrieved/d' | # Remove success messages
        sed -e 's/<?xml[^>]*?>//g' | # Remove all XML declarations
        sed -e 's/<MediaContainer>//' | # Remove outer MediaContainer
        sed -e 's/<\/MediaContainer><\/MediaContainer>/<\/MediaContainer>/' | # Fix nested closing tags
        sed -e '1i<?xml version="1.0" encoding="UTF-8"?>\n<MediaContainer>' # Add single XML declaration
    )

    if $DEBUG; then
        log_debug "Cleaned movie library XML:"
        log_debug "$cleaned_response"
    fi

    # Get total number of movies using xmllint
    local total_movies=0
    total_movies=$(echo "$cleaned_response" | xmllint --xpath "count(//Video)" - 2>/dev/null || echo 0)
    local current=0
    
    if $DEBUG; then
        log_debug "Found $total_movies movies in library"
    fi

    # Process each Video element using xmllint
    for ((i=1; i<=total_movies; i++)); do
        ((current++))
        if ! $QUIET; then
            printf "\r${BLUE}Processing movie ${GREEN}%d${BLUE}/${GREEN}%d${NC}" "$current" "$total_movies"
        fi
        
        local title year duration
        title=$(echo "$cleaned_response" | xmllint --xpath "string(//Video[$i]/@title)" - 2>/dev/null || echo "")
        year=$(echo "$cleaned_response" | xmllint --xpath "string(//Video[$i]/@year)" - 2>/dev/null || echo "")
        duration=$(echo "$cleaned_response" | xmllint --xpath "string(//Video[$i]/@duration)" - 2>/dev/null || echo "")
        
        if $DEBUG; then
            log_debug "Movie $i - Title: '$title', Year: '$year', Duration: '$duration'"
        fi
        
        # Convert duration from milliseconds to minutes
        if [[ -n "$duration" ]]; then
            duration=$(( duration / 60000 ))
        fi
        
        # Default values for missing fields
        year=${year:-""}
        duration=${duration:-""}
        
        # Only write if we have a title
        if [[ -n "$title" ]]; then
            title=$(decode_html "$title")
            title=$(echo "$title" | sed 's/"/""/g')
            echo "\"$title\",$year,$duration" >> "$output_file"
            
            if $DEBUG; then
                log_debug "Wrote entry: \"$title\",$year,$duration"
            fi
        fi
    done
    
    if ! $QUIET; then
        echo -e "\n${GREEN}Movie export complete${NC}"
    fi
    
    # Verify the export
    local exported_count
    exported_count=$(wc -l < "$output_file")
    ((exported_count--))  # Subtract 1 for the header row
    
    if [[ $exported_count -eq 0 ]]; then
        echo -e "${YELLOW}Warning: No movies were exported${NC}" >&2
        return 1
    elif [[ $exported_count -lt $total_movies ]]; then
        echo -e "${YELLOW}Warning: Only exported $exported_count out of $total_movies movies${NC}" >&2
    else
        echo -e "${GREEN}Successfully exported $exported_count movies${NC}"
    fi
}

export_tv_library() {
    local library_id=$1
    local output_file=$2
    
    echo "series_title,total_episodes,seasons,year,duration_minutes" > "$output_file"
    echo -e "${BLUE}Exporting TV library...${NC}"
    
    local response
    response=$(make_api_request "/library/sections/$library_id/all?type=2" true)
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to retrieve TV library"
        return $E_NETWORK_ERROR
    fi
    
    # Clean up the XML response
    local cleaned_response
    cleaned_response=$(echo "$response" | 
        sed -e '/Fetching page/d' | # Remove progress messages
        sed -e '/Successfully retrieved/d' | # Remove success messages
        sed -e 's/<?xml[^>]*?>//g' | # Remove all XML declarations
        sed -e 's/<MediaContainer>//' | # Remove outer MediaContainer
        sed -e 's/<\/MediaContainer><\/MediaContainer>/<\/MediaContainer>/' | # Fix nested closing tags
        sed -e '1i<?xml version="1.0" encoding="UTF-8"?>\n<MediaContainer>' # Add single XML declaration
    )

    if $DEBUG; then
        log_debug "Cleaned TV library XML:"
        log_debug "$cleaned_response"
    fi
    
    # Get total number of shows using xmllint
    local total_shows=0
    total_shows=$(echo "$cleaned_response" | xmllint --xpath "count(//Directory)" - 2>/dev/null || echo 0)
    local current=0
    
    if $DEBUG; then
        log_debug "Found $total_shows TV shows in library"
    fi
    
    # Process TV shows using xmllint
    for ((i=1; i<=total_shows; i++)); do
        ((current++))
        if ! $QUIET; then
            printf "\r${BLUE}Processing show ${GREEN}%d${BLUE}/${GREEN}%d${NC}" "$current" "$total_shows"
        fi
        
        local title episodes seasons year duration
        
        title=$(echo "$cleaned_response" | xmllint --xpath "string(//Directory[$i]/@title)" - 2>/dev/null || echo "")
        episodes=$(echo "$cleaned_response" | xmllint --xpath "string(//Directory[$i]/@leafCount)" - 2>/dev/null || echo "0")
        seasons=$(echo "$cleaned_response" | xmllint --xpath "string(//Directory[$i]/@childCount)" - 2>/dev/null || echo "0")
        year=$(echo "$cleaned_response" | xmllint --xpath "string(//Directory[$i]/@year)" - 2>/dev/null || echo "")
        duration=$(echo "$cleaned_response" | xmllint --xpath "string(//Directory[$i]/@duration)" - 2>/dev/null || echo "")
        
        if $DEBUG; then
            log_debug "Show $i - Title: '$title', Episodes: '$episodes', Seasons: '$seasons', Year: '$year', Duration: '$duration'"
        fi
        
        if [[ -n "$duration" ]]; then
            duration=$(( duration / 60000 ))
        fi
        
        # Default values for missing fields
        episodes=${episodes:-"0"}
        seasons=${seasons:-"0"}
        year=${year:-""}
        duration=${duration:-""}
        
        # Decode HTML entities and escape for CSV
        if [[ -n "$title" ]]; then
            title=$(decode_html "$title")
            title=$(echo "$title" | sed 's/"/""/g')
            echo "\"$title\",$episodes,$seasons,$year,$duration" >> "$output_file"
            
            if $DEBUG; then
                log_debug "Wrote entry: \"$title\",$episodes,$seasons,$year,$duration"
            fi
        fi
    done
    
    if ! $QUIET; then
        echo -e "\n${GREEN}TV export complete${NC}"
    fi
    
    # Verify the export
    local exported_count
    exported_count=$(wc -l < "$output_file")
    ((exported_count--))  # Subtract 1 for the header row
    
    if [[ $exported_count -eq 0 ]]; then
        echo -e "${YELLOW}Warning: No TV shows were exported${NC}" >&2
        return 1
    elif [[ $exported_count -lt $total_shows ]]; then
        echo -e "${YELLOW}Warning: Only exported $exported_count out of $total_shows TV shows${NC}" >&2
    else
        echo -e "${GREEN}Successfully exported $exported_count TV shows${NC}"
    fi
}

export_music_library() {
    local library_id=$1
    local output_file=$2
    
    echo "artist,album,track,track_number,disc_number,duration" > "$output_file"
    echo -e "${BLUE}Exporting music library...${NC}"
    
    local response
    response=$(make_api_request "/library/sections/$library_id/all?type=10" true)
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to retrieve music library"
        return $E_NETWORK_ERROR
    fi
    
    # Clean up the XML response
    local cleaned_response
    cleaned_response=$(echo "$response" | 
        sed -e '/Fetching page/d' | # Remove progress messages
        sed -e '/Successfully retrieved/d' | # Remove success messages
        sed -e 's/<?xml[^>]*?>//g' | # Remove all XML declarations
        sed -e 's/<MediaContainer>//' | # Remove outer MediaContainer
        sed -e 's/<\/MediaContainer><\/MediaContainer>/<\/MediaContainer>/' | # Fix nested closing tags
        sed -e '1i<?xml version="1.0" encoding="UTF-8"?>\n<MediaContainer>' # Add single XML declaration
    )

    if $DEBUG; then
        log_debug "Cleaned music library XML:"
        log_debug "$cleaned_response"
    fi
    
    # Get total number of tracks using xmllint
    local total_tracks=0
    total_tracks=$(echo "$cleaned_response" | xmllint --xpath "count(//Track)" - 2>/dev/null || echo 0)
    local current=0
    
    if $DEBUG; then
        log_debug "Found $total_tracks tracks in library"
    fi
    
    # Process tracks using xmllint
    for ((i=1; i<=total_tracks; i++)); do
        ((current++))
        if ! $QUIET; then
            printf "\r${BLUE}Processing track ${GREEN}%d${BLUE}/${GREEN}%d${NC}" "$current" "$total_tracks"
        fi
        
        local artist album track_title track_num disc_num duration
        
        artist=$(echo "$cleaned_response" | xmllint --xpath "string(//Track[$i]/@grandparentTitle)" - 2>/dev/null || echo "")
        album=$(echo "$cleaned_response" | xmllint --xpath "string(//Track[$i]/@parentTitle)" - 2>/dev/null || echo "")
        track_title=$(echo "$cleaned_response" | xmllint --xpath "string(//Track[$i]/@title)" - 2>/dev/null || echo "")
        track_num=$(echo "$cleaned_response" | xmllint --xpath "string(//Track[$i]/@index)" - 2>/dev/null || echo "")
        disc_num=$(echo "$cleaned_response" | xmllint --xpath "string(//Track[$i]/@parentIndex)" - 2>/dev/null || echo "")
        duration=$(echo "$cleaned_response" | xmllint --xpath "string(//Track[$i]/@duration)" - 2>/dev/null || echo "")
        
        if $DEBUG; then
            log_debug "Track $i - Artist: '$artist', Album: '$album', Title: '$track_title', Track: '$track_num', Disc: '$disc_num', Duration: '$duration'"
        fi
        
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
        if [[ -n "$track_title" ]]; then
            artist=$(decode_html "$artist")
            album=$(decode_html "$album")
            track_title=$(decode_html "$track_title")
            artist=$(echo "$artist" | sed 's/"/""/g')
            album=$(echo "$album" | sed 's/"/""/g')
            track_title=$(echo "$track_title" | sed 's/"/""/g')
            
            echo "\"$artist\",\"$album\",\"$track_title\",$track_num,$disc_num,\"$duration\"" >> "$output_file"
            
            if $DEBUG; then
                log_debug "Wrote entry: \"$artist\",\"$album\",\"$track_title\",$track_num,$disc_num,\"$duration\""
            fi
        fi
    done
    
    if ! $QUIET; then
        echo -e "\n${GREEN}Music export complete${NC}"
    fi
    
    # Verify the export
    local exported_count
    exported_count=$(wc -l < "$output_file")
    ((exported_count--))  # Subtract 1 for the header row
    
    if [[ $exported_count -eq 0 ]]; then
        echo -e "${YELLOW}Warning: No tracks were exported${NC}" >&2
        return 1
    elif [[ $exported_count -lt $total_tracks ]]; then
        echo -e "${YELLOW}Warning: Only exported $exported_count out of $total_tracks tracks${NC}" >&2
    else
        echo -e "${GREEN}Successfully exported $exported_count tracks${NC}"
    fi
}

parse_arguments() {
    while getopts ":t:u:ln:o:d:fqvh-:" opt; do
        case $opt in
            -)
                case "${OPTARG}" in
                    version)
                        show_version
                        ;;
                    update)
                        update_script
                        exit $E_SUCCESS
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
		
		# Get the library sections
		local sections_response
		sections_response=$(curl -s -H "X-Plex-Token: $PLEX_TOKEN" \
		    -H "Accept: application/xml" \
		    "${PLEX_URL}/library/sections")
		    
		# First try xmllint to get the library id
		library_id=$(echo "$sections_response" | xmllint --xpath "string(//Directory[@title='$LIBRARY_NAME']/@key)" - 2>/dev/null)
        
        if [[ -z "$library_id" ]]; then
            log_error "Error: Library '$LIBRARY_NAME' not found"
            exit $E_GENERAL_ERROR
        fi
        export_library "$library_id" "$OUTPUT_FILE"
    else
        # Export all libraries
        log_info "Exporting all libraries..."
        mkdir -p exports
        
        local response
        response=$(make_api_request "/library/sections")
        
        if [[ $? -ne 0 ]]; then
            log_error "Failed to retrieve library sections"
            exit $E_NETWORK_ERROR
        fi
        
        # Count total libraries for progress
        local total_libs=0
        total_libs=$(echo "$response" | grep -c '<Directory ' || true)
        local current_lib=0
        
        while IFS= read -r directory; do
            ((current_lib++))
            local title key
            title=$(echo "$directory" | grep -o 'title="[^"]*"' | head -1 | cut -d'"' -f2)
            key=$(echo "$directory" | grep -o 'key="[^"]*"' | head -1 | cut -d'"' -f2)
            
            if [[ -n "$title" && -n "$key" ]]; then
                echo -e "\n${BLUE}Processing library ${GREEN}$current_lib${BLUE}/${GREEN}$total_libs${NC}: ${YELLOW}$title${NC}"
                output_file="exports/${title// /-}.csv"
                export_library "$key" "$output_file"
            fi
        done < <(echo "$response" | grep -o '<Directory[^>]*>' || true)
        
        echo -e "\n${GREEN}All libraries have been exported${NC}"
    fi

}

# Execute main function with all arguments
main "$@"
