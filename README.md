# Media Library Exporter (for Plex)

A powerful bash script for Linux that allows you to export your Plex Media Server library information to CSV files. This tool supports exporting movies, TV shows, and music libraries with detailed metadata.

## AI Assistance Disclosure

This tool was developed with assistance from AI language models.

## Features

- Export all Plex libraries or specific ones
- Support for multiple library types:
  - Movies
  - TV
  - Albums
- Robust error handling and retry mechanisms
- Detailed logging system
- Color-coded console output
- Lock file system to prevent multiple instances
- HTML entity decoding for proper character handling

## Prerequisites

The script requires the following dependencies:

### Core Dependencies
- `curl` - For making HTTP requests to Plex API
- `sed` - For text processing
- `grep` - For pattern matching
- `date` - For timestamp handling
- `readlink` - For resolving symbolic links
- `xmllint` - For XML parsing (typically provided by libxml2-utils package)
- `bc` - For mathematical calculations (basic calculator package)
- `tee` - For logging output handling
- `python3` - For CSV processing
- `mktemp` - For temporary file handling
- `numfmt` - For number formatting (typically provided by coreutils package)
- `kill` - For process management
- `tr` - For character translation
- `wc` - For counting lines

### Package Installation

On Debian/Ubuntu systems, you can install missing dependencies using:
```bash
sudo apt-get update
sudo apt-get install curl coreutils bc python3 libxml2-utils
```

On Red Hat/CentOS systems:
```bash
sudo yum install curl coreutils bc python3 libxml2
```

Most Linux distributions will have many of these tools installed by default, but some might need to be installed manually.

## Installation

1. Download the script:
```bash
curl -O https://raw.githubusercontent.com/jeremehancock/media-library-exporter/main/media-library-exporter.sh
```

2. Make it executable:
```bash
chmod +x media-library-exporter.sh
```

## Configuration

The script creates a configuration file at `config/media-library-exporter.conf` on first run. You can customize the following settings:

### Server Settings
```bash
# Plex server URL (required)
PLEX_URL="http://localhost:32400"

# Your Plex authentication token
# If set here, you won't need to pass it via command line
# See instructions above for finding your token
PLEX_TOKEN=""
```

### Connection Settings
```bash
# Number of retry attempts for failed API calls
RETRY_COUNT=3

# Delay between retries in seconds
RETRY_DELAY=5
```

### Export Settings
```bash
# Default output directory for exports
OUTPUT_DIR="exports"

# Date format for timestamps (uses date command format)
DATE_FORMAT="%Y-%m-%d %H:%M:%S"

# Force overwrite existing files (true/false)
FORCE=false
```

### Debug Settings
```bash
# Enable debug mode (true/false)
DEBUG=false

# Enable logging (true/false)
ENABLE_LOGGING=false

# Whether to run in quiet mode (true/false)
QUIET=false
```

The configuration file will be automatically created with default values on first run. You can modify these settings by editing the file directly or override them using command-line options.

## Usage

### Basic Usage

If you haven't set your Plex token in the config file:
```bash
./media-library-exporter.sh -t YOUR_PLEX_TOKEN [options]
```

If you've already set your Plex token in the config file:
```bash
./media-library-exporter.sh [options]
```

### Getting Your Plex Token

You can find your Plex authentication token (X-Plex-Token) using one of these methods:

1. Browser method:
   - Log into Plex Web App
   - Browse to a library item
   - Click the ⋮ (three dots) next to the item
   - Click "Get Info"
   - Click "View XML"
   - Look at the URL in your browser's address bar - the X-Plex-Token will be at the end

2. Plex Desktop App method:
   - Open Plex Desktop App
   - Go to any library item
   - Right-click and choose "Get Info"
   - Click "View XML"
   - Find the X-Plex-Token in the URL

For more detailed instructions, visit the [official Plex support article](https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/)

### Command Line Options

```
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
```

### Examples

List all available libraries:
```bash
./media-library-exporter.sh -t YOUR_TOKEN -l
```

Export a specific library:
```bash
./media-library-exporter.sh -t YOUR_TOKEN -n "Movies" -o movies.csv
```

Export all libraries:
```bash
./media-library-exporter.sh -t YOUR_TOKEN
```

Use a different Plex server:
```bash
./media-library-exporter.sh -t YOUR_TOKEN -u http://plex.local:32400
```

## Logs

Logs are stored in the `logs` directory with the following naming convention:
- `media-library-exporter-YYYYMMDD_HHMMSS.log` for general logs
- `media-library-exporter-YYYYMMDD_HHMMSS-error.log` for error logs

## Error Handling

The script includes comprehensive error handling for common issues:
- Network connectivity problems
- Missing dependencies
- Permission errors
- Invalid arguments
- Concurrent execution attempts

## Disclaimer

All code is provided as-is without any warranty.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
