#!/bin/bash

################################################################################
# AWS MFA Role Assumption Script
#
# A production-ready script for assuming AWS roles with MFA authentication.
# Supports AWS config profiles, auto-detection of MFA devices, and automatic
# credential management.
#
# Requirements:
#   - AWS CLI v2+
#   - jq (JSON processor)
#   - Properly configured ~/.aws/config with MFA device
#
# Usage (Profile Mode - Recommended):
#   ./mfa-share.sh --profile <PROFILE_NAME> <MFA_TOKEN>
#
# Usage (Manual Mode):
#   ./mfa-share.sh <MFA_TOKEN> <ACCOUNT_ID> <ROLE_NAME>
#
# Credentials are stored in ~/.aws/credentials as 'aws-temp' profile
#
# Version: 3.0
################################################################################

set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'        # Safe word splitting

################################################################################
# CONFIGURATION
################################################################################

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_REGION="us-east-1"
readonly SESSION_DURATION=21600  # 6 hours
readonly MIN_SESSION_DURATION=900  # 15 minutes
readonly MAX_SESSION_DURATION=43200  # 12 hours
readonly OUTPUT_PROFILE_NAME="aws-temp"
readonly MAX_PROFILE_DISPLAY=15

# Default paths (can be overridden with options)
AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-${HOME}/.aws/config}"

################################################################################
# COLOR CODES FOR OUTPUT
################################################################################

# Enable colors by default (set NO_COLOR=1 to disable)
if [[ -z "${NO_COLOR:-}" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly PURPLE='\033[0;35m'
    readonly MAGENTA='\033[1;35m'
    readonly CYAN='\033[0;36m'
    readonly NC='\033[0m' # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly PURPLE=''
    readonly MAGENTA=''
    readonly CYAN=''
    readonly NC=''
fi

################################################################################
# GLOBAL VARIABLES
################################################################################

VERBOSE=false
DRY_RUN=false
SESSION_DURATION_OVERRIDE=""
USE_PROFILE=""
PROFILE_ACCOUNT_ID=""
PROFILE_ROLE=""
PROFILE_REGION=""

################################################################################
# UTILITY FUNCTIONS
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_verbose() {
    if [[ "${VERBOSE}" == true ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
}

# Interactive prompt for first-time users
show_interactive_prompt() {
    local selected=1
    local options=("List available AWS profiles" "Show help and usage examples" "Exit")

    # Function to display menu
    display_menu() {
        clear
        echo -e "${CYAN}AWS MFA Authentication Helper${NC}"
        echo -e ""
        echo -e "Use ${YELLOW}↑/↓${NC} arrow keys to navigate, ${YELLOW}Enter${NC} to select:"
        echo -e ""

        for i in "${!options[@]}"; do
            local num=$((i + 1))
            if [[ $((i + 1)) -eq $selected ]]; then
                echo -e "  ${MAGENTA}▶${NC} ${GREEN}${num}${NC}) ${options[$i]}"
            else
                echo -e "    ${BLUE}${num}${NC}) ${options[$i]}"
            fi
        done
        echo -e ""
    }

    # Main loop
    while true; do
        display_menu

        # Read single character with arrow key support
        read -rsn1 key

        # Handle arrow keys (they come as three characters: ESC [ A/B)
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in
                '[A') # Up arrow
                    ((selected--))
                    if [[ $selected -lt 1 ]]; then
                        selected=${#options[@]}
                    fi
                    ;;
                '[B') # Down arrow
                    ((selected++))
                    if [[ $selected -gt ${#options[@]} ]]; then
                        selected=1
                    fi
                    ;;
            esac
        elif [[ $key == "" ]]; then
            # Enter key pressed
            break
        elif [[ $key =~ ^[1-3]$ ]]; then
            # Number key pressed
            selected=$key
            break
        fi
    done

    clear

    # Execute selected option
    case "$selected" in
        1)
            select_profile_interactive
            ;;
        2)
            show_help
            ;;
        3)
            echo -e "Goodbye!"
            exit 0
            ;;
    esac
    exit 0
}

# Interactive profile selector with arrow keys
select_profile_interactive() {
    local aws_config="${AWS_CONFIG_FILE}"

    if [[ ! -f "${aws_config}" ]]; then
        log_error "AWS config file not found: ${aws_config}"
        return 1
    fi

    # Build array of profiles
    local profiles=()
    local current_profile=""

    while IFS= read -r line; do
        if [[ "${line}" =~ ^\[profile[[:space:]]+([^]]+)\] ]]; then
            current_profile="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^\[default\] ]]; then
            current_profile="default"
        fi

        if [[ -n "${current_profile}" && "${line}" =~ role_arn[[:space:]]*=[[:space:]]*arn:aws:iam::([0-9]{12}):role/(.+) ]]; then
            profiles+=("${current_profile}")
            current_profile=""
        fi
    done < "${aws_config}"

    if [[ ${#profiles[@]} -eq 0 ]]; then
        log_error "No profiles with role_arn found in ${aws_config}"
        return 1
    fi

    local selected=1

    # Function to display profile menu
    display_profile_menu() {
        clear
        echo -e "${CYAN}Select AWS Profile${NC}"
        echo -e ""
        echo -e "Use ${YELLOW}↑/↓${NC} arrow keys to navigate, ${YELLOW}Enter${NC} to select, ${YELLOW}q${NC} to quit:"
        echo -e ""

        local display_start=0
        local display_end=${#profiles[@]}
        local max_display=${MAX_PROFILE_DISPLAY}

        # Show subset if too many profiles
        if [[ ${#profiles[@]} -gt $max_display ]]; then
            display_start=$((selected - max_display / 2))
            if [[ $display_start -lt 0 ]]; then
                display_start=0
            fi
            display_end=$((display_start + max_display))
            if [[ $display_end -gt ${#profiles[@]} ]]; then
                display_end=${#profiles[@]}
                display_start=$((display_end - max_display))
                if [[ $display_start -lt 0 ]]; then
                    display_start=0
                fi
            fi
        fi

        if [[ $display_start -gt 0 ]]; then
            echo -e "  ${YELLOW}... (${display_start} more above)${NC}"
        fi

        for ((i = display_start; i < display_end; i++)); do
            local num=$((i + 1))
            if [[ $num -eq $selected ]]; then
                echo -e "  ${MAGENTA}▶${NC} ${GREEN}${profiles[$i]}${NC}"
            else
                echo -e "    ${BLUE}${profiles[$i]}${NC}"
            fi
        done

        if [[ $display_end -lt ${#profiles[@]} ]]; then
            local remaining=$((${#profiles[@]} - display_end))
            echo -e "  ${YELLOW}... (${remaining} more below)${NC}"
        fi

        echo -e ""
        echo -e "${YELLOW}Showing ${#profiles[@]} profile(s)${NC}"
    }

    # Main loop
    while true; do
        display_profile_menu

        read -rsn1 key

        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in
                '[A') # Up arrow
                    ((selected--))
                    if [[ $selected -lt 1 ]]; then
                        selected=${#profiles[@]}
                    fi
                    ;;
                '[B') # Down arrow
                    ((selected++))
                    if [[ $selected -gt ${#profiles[@]} ]]; then
                        selected=1
                    fi
                    ;;
            esac
        elif [[ $key == "" ]]; then
            # Enter key pressed
            break
        elif [[ $key == "q" || $key == "Q" ]]; then
            clear
            echo -e "Cancelled."
            exit 0
        fi
    done

    clear

    local profile_name="${profiles[$((selected - 1))]}"
    echo -e "${GREEN}Selected profile:${NC} ${CYAN}${profile_name}${NC}"
    echo -e ""

    read -p "Enter your 6-digit MFA code from authenticator app: " mfa_code

    if [[ -n "${mfa_code}" ]]; then
        exec "${BASH_SOURCE[0]}" --profile "${profile_name}" "${mfa_code}"
    fi
}

show_help() {
    echo -e "${GREEN}AWS MFA Role Assumption Script${NC}"
    echo ""
    echo -e "${BLUE}Usage (Profile Mode):${NC}"
    echo "    ${SCRIPT_NAME} --profile <PROFILE_NAME> <MFA_TOKEN> [OPTIONS]"
    echo ""
    echo -e "${BLUE}Usage (Manual Mode):${NC}"
    echo "    ${SCRIPT_NAME} <MFA_TOKEN> <ACCOUNT_ID> <ROLE_NAME> [OPTIONS]"
    echo ""
    echo -e "${BLUE}Arguments:${NC}"
    echo "    MFA_TOKEN              6-digit code from authenticator app"
    echo "                           (Google Authenticator, Authy, Microsoft Authenticator, etc.)"
    echo "                           Note: Codes expire every 30 seconds"
    echo "    PROFILE_NAME           AWS config profile name (extracts account, role, region)"
    echo "    ACCOUNT_ID             12-digit AWS account ID"
    echo "    ROLE_NAME              IAM role to assume (required)"
    echo ""
    echo -e "${BLUE}Options:${NC}"
    echo "    --profile NAME         Use AWS config profile (recommended)"
    echo "    -h, --help             Show this help message"
    echo "    -v, --verbose          Enable verbose output"
    echo "    -p, --list-profiles    List available AWS config profiles"
    echo "    -d, --dry-run          Validate configuration without assuming role"
    echo "    -t, --duration SECONDS Session duration in seconds (default: ${SESSION_DURATION}, max: ${MAX_SESSION_DURATION})"
    echo "    -a, --aws-config FILE  Use custom AWS config file (default: ~/.aws/config)"
    echo ""
    echo -e "${BLUE}Environment Variables:${NC}"
    echo "    AWS_CONFIG_FILE        Override AWS config file location"
    echo "    AWS_MFA_SERIAL         Override auto-detected MFA serial number"
    echo "    AWS_REGION             Set AWS region (default: ${DEFAULT_REGION})"
    echo ""
    echo -e "${BLUE}Examples (Profile Mode - Recommended):${NC}"
    echo "    # List available profiles"
    echo "    ${SCRIPT_NAME} --list-profiles"
    echo ""
    echo "    # Use profile (extracts account, role, region automatically)"
    echo "    ${SCRIPT_NAME} --profile production 123456"
    echo ""
    echo "    # Profile with custom duration (12 hours)"
    echo "    ${SCRIPT_NAME} --profile staging 123456 -t ${MAX_SESSION_DURATION}"
    echo ""
    echo "    # Source in current shell"
    echo "    source ${SCRIPT_NAME} --profile development 123456"
    echo ""
    echo -e "${BLUE}Examples (Manual Mode):${NC}"
    echo "    # Basic usage with account ID and role"
    echo "    ${SCRIPT_NAME} 123456 123456789012 AdminRole"
    echo ""
    echo "    # Different role"
    echo "    ${SCRIPT_NAME} 123456 123456789012 ReadOnlyAccess"
    echo ""
    echo "    # Verbose mode"
    echo "    ${SCRIPT_NAME} -v 123456 987654321098 DeveloperRole"
    echo ""
    echo -e "${BLUE}Requirements:${NC}"
    echo "    - AWS CLI v2+ installed and configured"
    echo "    - jq (JSON processor)"
    echo "    - MFA device configured in ~/.aws/config"
    echo ""
    echo -e "${BLUE}Profile Configuration:${NC}"
    echo "    Profile mode reads from ~/.aws/config"
    echo "    Each profile should have:"
    echo "      - role_arn (required) - defines account ID and role name"
    echo "      - region (optional) - AWS region to use"
    echo "      - source_profile (optional) - base profile with credentials"
    echo ""
    echo -e "${BLUE}Output:${NC}"
    echo "    Credentials are written to ~/.aws/credentials as profile 'aws-temp'"
    echo "    Use: export AWS_PROFILE=aws-temp"
    echo ""
}

check_dependencies() {
    local missing_deps=()

    if ! command -v aws &> /dev/null; then
        missing_deps+=("aws-cli")
    fi

    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Install with: brew install ${missing_deps[*]}"
        return 1
    fi

    log_verbose "All dependencies satisfied"
    return 0
}

################################################################################
# PROFILE MANAGEMENT FUNCTIONS
################################################################################

# List all AWS config profiles with role_arn
list_profiles() {
    local aws_config="${AWS_CONFIG_FILE}"

    if [[ ! -f "${aws_config}" ]]; then
        log_error "AWS config file not found: ${aws_config}"
        return 1
    fi

    echo -e "${GREEN}Available AWS Config Profiles:${NC}\n"
    echo -e "${BLUE}Profile Name                      Account ID      Role Name${NC}"
    echo "--------------------------------------------------------------------------------"

    local current_profile=""
    local role_arn=""
    local count=0

    while IFS= read -r line; do
        # Match profile lines
        if [[ "${line}" =~ ^\[profile[[:space:]]+([^]]+)\] ]]; then
            current_profile="${BASH_REMATCH[1]}"
            role_arn=""
        elif [[ "${line}" =~ ^\[default\] ]]; then
            current_profile="default"
            role_arn=""
        # Match role_arn lines
        elif [[ -n "${current_profile}" && "${line}" =~ role_arn[[:space:]]*=[[:space:]]*arn:aws:iam::([0-9]{12}):role/(.+) ]]; then
            local account_id="${BASH_REMATCH[1]}"
            local role_name="${BASH_REMATCH[2]}"
            printf "%-35s %-15s %s\n" "${current_profile}" "${account_id}" "${role_name}"
            ((count++))
        fi
    done < "${aws_config}"

    echo ""
    if [[ ${count} -eq 0 ]]; then
        echo -e "${YELLOW}No profiles with role_arn found in ${aws_config}${NC}"
    else
        echo -e "${GREEN}Found ${count} profile(s)${NC}"
    fi
    echo ""
    echo -e "${BLUE}Usage:${NC} ${SCRIPT_NAME} --profile <PROFILE_NAME> <MFA_TOKEN>"
}

# Extract account ID and role from AWS profile
get_profile_info() {
    local profile_name="$1"
    local aws_config="${AWS_CONFIG_FILE}"

    if [[ ! -f "${aws_config}" ]]; then
        log_error "AWS config file not found: ${aws_config}"
        return 1
    fi

    log_verbose "Looking for profile: ${profile_name}"

    local current_profile=""
    local role_arn=""
    local region=""
    local found=false

    while IFS= read -r line; do
        # Match profile lines
        if [[ "${line}" =~ ^\[profile[[:space:]]+([^]]+)\] ]]; then
            current_profile="${BASH_REMATCH[1]}"
            role_arn=""
            region=""
        elif [[ "${line}" =~ ^\[default\] ]]; then
            current_profile="default"
            role_arn=""
            region=""
        fi

        # If we're in the target profile, extract info
        if [[ "${current_profile}" == "${profile_name}" ]]; then
            if [[ "${line}" =~ role_arn[[:space:]]*=[[:space:]]*arn:aws:iam::([0-9]{12}):role/(.+) ]]; then
                PROFILE_ACCOUNT_ID="${BASH_REMATCH[1]}"
                PROFILE_ROLE="${BASH_REMATCH[2]}"
                found=true
                log_verbose "Found account: ${PROFILE_ACCOUNT_ID}, role: ${PROFILE_ROLE}"
            elif [[ "${line}" =~ region[[:space:]]*=[[:space:]]*(.+) ]]; then
                PROFILE_REGION="${BASH_REMATCH[1]}"
                log_verbose "Found region: ${PROFILE_REGION}"
            fi
        fi
    done < "${aws_config}"

    if [[ "${found}" == true ]]; then
        if [[ -z "${PROFILE_ACCOUNT_ID}" || -z "${PROFILE_ROLE}" ]]; then
            log_error "Profile '${profile_name}' missing role_arn"
            return 1
        fi
        return 0
    else
        log_error "Profile '${profile_name}' not found in ${aws_config}"
        log_info "Use --list-profiles to see available profiles"
        return 1
    fi
}

################################################################################
# MFA DETECTION FUNCTIONS
################################################################################

# Auto-detect MFA serial number from AWS config
detect_mfa_serial() {
    local aws_config="${AWS_CONFIG_FILE}"
    local mfa_serial

    # Check if environment variable is set
    if [[ -n "${AWS_MFA_SERIAL:-}" ]]; then
        log_verbose "Using MFA serial from AWS_MFA_SERIAL environment variable"
        echo "${AWS_MFA_SERIAL}"
        return 0
    fi

    # Try to parse from AWS config
    if [[ -f "${aws_config}" ]]; then
        mfa_serial=$(grep -m 1 "mfa_serial" "${aws_config}" | sed 's/.*=\s*//' | xargs || true)

        if [[ -n "${mfa_serial}" ]]; then
            log_verbose "Detected MFA serial from ${aws_config}: ${mfa_serial}"
            echo "${mfa_serial}"
            return 0
        fi
    fi

    # Try to get from AWS CLI
    local caller_identity
    if caller_identity=$(aws sts get-caller-identity 2>/dev/null); then
        local account_id
        local username
        account_id=$(echo "${caller_identity}" | jq -r '.Account')
        username=$(echo "${caller_identity}" | jq -r '.Arn' | awk -F'/' '{print $NF}')

        if [[ -n "${account_id}" && -n "${username}" ]]; then
            mfa_serial="arn:aws:iam::${account_id}:mfa/${username}"
            log_verbose "Constructed MFA serial from caller identity: ${mfa_serial}"
            echo "${mfa_serial}"
            return 0
        fi
    fi

    log_error "Could not auto-detect MFA serial number"
    log_info "Please set AWS_MFA_SERIAL environment variable or configure mfa_serial in ~/.aws/config"
    return 1
}

################################################################################
# AWS ASSUME ROLE FUNCTIONS
################################################################################

assume_role_with_mfa() {
    local mfa_token="$1"
    local account_id="$2"
    local role_name="$3"
    local mfa_serial="$4"

    local role_arn="arn:aws:iam::${account_id}:role/${role_name}"
    local session_name="${USER}_mfa_session_$(date +%s)"

    # Use custom duration if specified, otherwise use default
    local duration="${SESSION_DURATION_OVERRIDE:-${SESSION_DURATION}}"

    log_info "Assuming role: ${role_arn}"
    log_verbose "MFA Serial: ${mfa_serial}"
    log_verbose "Session duration: ${duration} seconds"

    # Dry-run mode: validate configuration without making AWS calls
    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY-RUN] Would assume role with:"
        log_info "  Role ARN: ${role_arn}"
        log_info "  Session Name: ${session_name}"
        log_info "  MFA Serial: ${mfa_serial}"
        log_info "  Duration: ${duration} seconds"
        log_success "[DRY-RUN] Configuration validation passed"
        return 0
    fi

    # Clear any existing AWS environment variables to avoid conflicts
    unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
          AWS_REGION AWS_DEFAULT_REGION AWS_SECURITY_TOKEN 2>/dev/null || true

    local response
    if ! response=$(aws sts assume-role \
        --role-arn "${role_arn}" \
        --role-session-name "${session_name}" \
        --serial-number "${mfa_serial}" \
        --token-code "${mfa_token}" \
        --duration-seconds "${duration}" \
        2>&1); then

        log_error "Could not get AWS credentials"
        echo "" >&2

        if [[ "${response}" == *"InvalidClientTokenId"* ]]; then
            echo -e "${YELLOW}What to check:${NC}" >&2
            echo "  • Your AWS credentials in ~/.aws/credentials might be invalid or expired" >&2
            echo "  • Run 'aws configure' to set up your base AWS credentials" >&2
        elif [[ "${response}" == *"AccessDenied"* ]]; then
            echo -e "${YELLOW}What to check:${NC}" >&2
            echo "  • The role '${role_name}' might not exist in account ${account_id}" >&2
            echo "  • You might not have permission to access this account/role" >&2
            echo "  • Check with your AWS administrator about access permissions" >&2
        elif [[ "${response}" == *"MultiFactorAuthentication"* ]]; then
            echo -e "${YELLOW}What to check:${NC}" >&2
            echo "  • Is your MFA code correct? (6 digits from authenticator app)" >&2
            echo "  • MFA codes expire every 30 seconds - try a fresh code" >&2
            echo "  • Is your MFA device configured correctly in AWS?" >&2
        else
            echo -e "${YELLOW}AWS Error:${NC}" >&2
            echo "${response}" >&2
        fi

        return 1
    fi

    # Extract credentials
    local access_key secret_key session_token expiration
    access_key=$(echo "${response}" | jq -r '.Credentials.AccessKeyId')
    secret_key=$(echo "${response}" | jq -r '.Credentials.SecretAccessKey')
    session_token=$(echo "${response}" | jq -r '.Credentials.SessionToken')
    expiration=$(echo "${response}" | jq -r '.Credentials.Expiration')

    # Validate extraction
    if [[ -z "${access_key}" || "${access_key}" == "null" ]] || \
       [[ -z "${secret_key}" || "${secret_key}" == "null" ]] || \
       [[ -z "${session_token}" || "${session_token}" == "null" ]]; then
        log_error "Failed to extract credentials from AWS response"
        return 1
    fi

    # Store credentials in variables (not exported to environment)
    AWS_ACCESS_KEY_ID="${access_key}"
    AWS_SECRET_ACCESS_KEY="${secret_key}"
    AWS_SESSION_TOKEN="${session_token}"

    log_success "Successfully assumed role: ${role_name}"
    log_info "Credentials expire at: ${expiration}"

    # Calculate time until expiration (cross-platform compatible)
    if command -v date &> /dev/null; then
        local expire_epoch=""
        local expiration_clean

        # Remove timezone suffix and microseconds for consistent parsing
        # AWS returns format: 2025-10-09T12:34:56.000Z or 2025-10-09T12:34:56+00:00
        expiration_clean=$(echo "${expiration}" | sed 's/\.[0-9]*Z$/Z/' | sed 's/+00:00$/Z/')

        if [[ "${OSTYPE}" == "darwin"* ]]; then
            # macOS (BSD date) - try multiple formats
            expire_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "${expiration_clean}" "+%s" 2>/dev/null) || \
            expire_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$(echo "${expiration}" | sed 's/\.[0-9]*[+-].*$//' | sed 's/Z$//')" "+%s" 2>/dev/null) || \
            expire_epoch=""
        else
            # Linux (GNU date) - handles ISO8601 natively
            expire_epoch=$(date -u -d "${expiration}" "+%s" 2>/dev/null) || expire_epoch=""
        fi

        if [[ -n "${expire_epoch}" && "${expire_epoch}" =~ ^[0-9]+$ ]]; then
            local now_epoch
            now_epoch=$(date -u "+%s")
            local seconds_remaining=$((expire_epoch - now_epoch))

            if [[ ${seconds_remaining} -gt 0 ]]; then
                local hours_remaining=$((seconds_remaining / 3600))
                local minutes_remaining=$(((seconds_remaining % 3600) / 60))
                log_info "Time remaining: ${hours_remaining}h ${minutes_remaining}m"
            else
                log_warn "Credentials appear to be already expired"
            fi
        else
            log_verbose "Could not parse expiration time for duration calculation"
        fi
    fi

    return 0
}

################################################################################
# AWS CREDENTIALS FILE MANAGEMENT
################################################################################

write_credentials_to_profile() {
    local profile_name="${OUTPUT_PROFILE_NAME}"
    local credentials_file="${HOME}/.aws/credentials"
    local credentials_dir="${HOME}/.aws"

    # Create .aws directory if it doesn't exist
    if [[ ! -d "${credentials_dir}" ]]; then
        log_verbose "Creating AWS credentials directory: ${credentials_dir}"
        mkdir -p "${credentials_dir}"
        chmod 700 "${credentials_dir}"
    fi

    # Create credentials file if it doesn't exist
    if [[ ! -f "${credentials_file}" ]]; then
        log_verbose "Creating AWS credentials file: ${credentials_file}"
        touch "${credentials_file}"
        chmod 600 "${credentials_file}"
    fi

    log_info "Writing credentials to profile: ${profile_name}"

    # Create temporary file for updated credentials
    local temp_file
    temp_file=$(mktemp)

    # Setup cleanup trap for temp file
    trap 'rm -f "${temp_file}"' EXIT

    # Read existing credentials file and update/add temp-claude profile
    local in_temp_claude_section=false
    local temp_claude_section_found=false

    if [[ -s "${credentials_file}" ]]; then
        while IFS= read -r line || [[ -n "${line}" ]]; do
            # Check if we're entering the temp-claude section
            if [[ "${line}" =~ ^\[${profile_name}\] ]]; then
                in_temp_claude_section=true
                temp_claude_section_found=true
                # Write the section header and new credentials
                cat >> "${temp_file}" <<EOF
[${profile_name}]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
aws_session_token = ${AWS_SESSION_TOKEN}
EOF
                continue
            fi

            # Check if we're entering a different section (end of temp-claude section)
            if [[ "${line}" =~ ^\[.*\] ]]; then
                in_temp_claude_section=false
            fi

            # Skip lines in the temp-claude section (we already wrote the new ones)
            if [[ "${in_temp_claude_section}" == true ]]; then
                continue
            fi

            # Write all other lines as-is
            echo "${line}" >> "${temp_file}"
        done < "${credentials_file}"
    fi

    # If temp-claude section wasn't found, append it
    if [[ "${temp_claude_section_found}" == false ]]; then
        # Add blank line if file is not empty
        if [[ -s "${temp_file}" ]]; then
            echo "" >> "${temp_file}"
        fi
        cat >> "${temp_file}" <<EOF
[${profile_name}]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
aws_session_token = ${AWS_SESSION_TOKEN}
EOF
    fi

    # Move temp file to credentials file with error handling
    if ! mv "${temp_file}" "${credentials_file}"; then
        # Attempt to save as backup if move fails
        local backup_file="${credentials_file}.backup.$(date +%s)"
        if cp "${temp_file}" "${backup_file}" 2>/dev/null; then
            log_error "Failed to update credentials file"
            log_warn "Credentials saved to backup: ${backup_file}"
        else
            log_error "Failed to update credentials file and create backup"
        fi
        return 1
    fi

    chmod 600 "${credentials_file}"

    log_success "Credentials written to profile '${profile_name}' in ${credentials_file}"
    return 0
}


################################################################################
# ARGUMENT PARSING
################################################################################

parse_arguments() {
    # If no arguments provided, show interactive prompt
    if [[ $# -eq 0 ]]; then
        show_interactive_prompt
    fi

    local positional_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -p|--list-profiles)
                list_profiles
                exit 0
                ;;
            --profile)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option --profile requires an argument"
                    exit 1
                fi
                USE_PROFILE="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -a|--aws-config)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option --aws-config requires an argument"
                    exit 1
                fi
                AWS_CONFIG_FILE="$2"
                shift 2
                ;;
            -t|--duration)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option --duration requires an argument"
                    exit 1
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "Invalid duration: '$2'. Must be a positive integer."
                    exit 1
                fi
                if [[ "$2" -lt ${MIN_SESSION_DURATION} || "$2" -gt ${MAX_SESSION_DURATION} ]]; then
                    log_error "Invalid duration: $2 seconds. Must be between ${MIN_SESSION_DURATION} (15 min) and ${MAX_SESSION_DURATION} (12 hours)."
                    exit 1
                fi
                SESSION_DURATION_OVERRIDE="$2"
                shift 2
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                positional_args+=("$1")
                shift
                ;;
        esac
    done

    # Restore positional arguments
    set -- "${positional_args[@]}"

    # When using --profile, only MFA token is required
    if [[ -n "${USE_PROFILE}" ]]; then
        if [[ $# -lt 1 ]]; then
            log_error "Missing required argument: MFA_TOKEN"
            echo ""
            show_help
            exit 1
        fi

        readonly MFA_TOKEN="$1"

        # Validate MFA token format
        if ! [[ "${MFA_TOKEN}" =~ ^[0-9]{6}$ ]]; then
            log_error "Invalid MFA token format. Expected 6 digits, got: '${MFA_TOKEN}'"
            exit 1
        fi

        # Extract profile information
        if ! get_profile_info "${USE_PROFILE}"; then
            exit 1
        fi

        readonly ACCOUNT_INPUT="${PROFILE_ACCOUNT_ID}"
        readonly ROLE_NAME="${PROFILE_ROLE}"

        log_verbose "Using profile: ${USE_PROFILE}"
        log_verbose "MFA Token: ${MFA_TOKEN}"
        log_verbose "Account ID: ${ACCOUNT_INPUT}"
        log_verbose "Role Name: ${ROLE_NAME}"

        # Set region if found in profile
        if [[ -n "${PROFILE_REGION}" ]]; then
            export AWS_REGION="${PROFILE_REGION}"
            log_verbose "Region: ${PROFILE_REGION}"
        fi

    else
        # Manual mode: require MFA token, account, AND role
        if [[ $# -lt 3 ]]; then
            log_error "Missing required arguments"
            log_info "Manual mode requires: <MFA_TOKEN> <ACCOUNT_ID> <ROLE_NAME>"
            log_info "Or use profile mode: --profile <PROFILE_NAME> <MFA_TOKEN>"
            echo ""
            show_help
            exit 1
        fi

        # Set variables
        readonly MFA_TOKEN="$1"
        readonly ACCOUNT_INPUT="$2"
        readonly ROLE_NAME="$3"

        # Validate MFA token format
        if ! [[ "${MFA_TOKEN}" =~ ^[0-9]{6}$ ]]; then
            log_error "Invalid MFA token format. Expected 6 digits, got: '${MFA_TOKEN}'"
            exit 1
        fi

        # Validate account ID format (must be 12-digit number in manual mode)
        if ! [[ "${ACCOUNT_INPUT}" =~ ^[0-9]{12}$ ]]; then
            log_error "Invalid account ID format. Expected 12-digit number, got: '${ACCOUNT_INPUT}'"
            log_info "Use --profile mode for named profiles, or provide a 12-digit account ID"
            exit 1
        fi

        log_verbose "MFA Token: ${MFA_TOKEN}"
        log_verbose "Account ID: ${ACCOUNT_INPUT}"
        log_verbose "Role Name: ${ROLE_NAME}"
    fi
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    log_verbose "Starting AWS MFA role assumption script"

    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi

    # Detect MFA serial
    local mfa_serial
    if ! mfa_serial=$(detect_mfa_serial); then
        exit 1
    fi

    # ACCOUNT_INPUT is already validated as a 12-digit account ID
    local account_id="${ACCOUNT_INPUT}"
    log_verbose "Using account ID: ${account_id}"

    # Assume role with MFA
    if ! assume_role_with_mfa "${MFA_TOKEN}" "${account_id}" "${ROLE_NAME}" "${mfa_serial}"; then
        exit 1
    fi

    # Write credentials to AWS credentials file
    write_credentials_to_profile || log_warn "Failed to write credentials to profile (non-fatal)"

    # Print success message with next steps
    echo ""
    echo -e "${GREEN}✓ Success! AWS credentials configured${NC}"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}What's next?${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} Set the AWS profile:"
    echo -e "     ${YELLOW}export AWS_PROFILE=aws-temp${NC}"
    echo ""
    echo -e "  ${GREEN}2.${NC} Test that it works:"
    echo -e "     ${YELLOW}aws sts get-caller-identity${NC}"
    echo ""
    echo -e "  ${GREEN}3.${NC} Use AWS CLI, boto3, or CDK:"
    echo -e "     ${YELLOW}aws s3 ls${NC}"
    echo -e "     ${YELLOW}python my_script.py${NC}"
    echo -e "     ${YELLOW}cdk deploy${NC}"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}💡 Tip:${NC} Add to your shell profile for automatic activation:"
    echo -e "   echo 'export AWS_PROFILE=aws-temp' >> ~/.bashrc"
    echo ""
}

# Main execution
parse_arguments "$@"
main
