# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains `mfa-share.sh`, a production-ready bash script for AWS IAM role assumption with MFA authentication. It's designed for teams managing multiple AWS accounts with temporary credentials.

**Important:** This script relies on existing AWS credentials in `~/.aws/credentials` and configuration in `~/.aws/config`. It uses base IAM user credentials to assume roles with MFA authentication.

## Key Features

- **MFA Auto-detection**: Automatically detects MFA device ARN from `~/.aws/config` or constructs it from `aws sts get-caller-identity`
- **Profile-Based Authentication**: Uses AWS config profiles to define target roles
- **Interactive Mode**: Arrow-key navigation for profile selection
- **Credential Storage**: Writes temporary credentials to `~/.aws/credentials` as `aws-temp` profile
- **Multiple Authentication Modes**: Profile mode (recommended) or manual mode with account ID and role name

## Architecture

### Configuration System

The script uses AWS config profiles from `~/.aws/config` to determine:
- Target role ARN (account ID + role name)
- AWS region (optional)
- Source profile with base credentials (optional)

**Profile resolution:**
1. Reads `~/.aws/config` for profiles with `role_arn` defined
2. Extracts account ID and role name from the ARN
3. Uses MFA serial from config or constructs from caller identity

### MFA Detection Flow

The script attempts to find the MFA serial number through:
1. `AWS_MFA_SERIAL` environment variable
2. Parsing `mfa_serial` from AWS config file
3. Constructing ARN from `aws sts get-caller-identity` (account + username)

See `detect_mfa_serial()` function at lines 514-555.

### Credential Storage

The script writes temporary credentials to `~/.aws/credentials`:
1. Calls `aws sts assume-role` with MFA token
2. Receives temporary credentials (access key, secret key, session token)
3. Updates/creates `[aws-temp]` profile in `~/.aws/credentials`
4. User sets `AWS_PROFILE=aws-temp` to use the credentials

Implementation: `write_credentials_to_profile()` at lines 692-786.

## Common Commands

### Basic Usage
```bash
# Interactive mode (arrow-key navigation)
./mfa-share.sh

# Profile mode (recommended)
./mfa-share.sh --profile production 123456

# Manual mode with account ID and role
./mfa-share.sh 123456 123456789012 PowerUserAccess

# List available profiles
./mfa-share.sh --list-profiles

# Verbose mode for debugging
./mfa-share.sh -v --profile staging 123456

# Dry-run mode (validate without AWS calls)
./mfa-share.sh -d --profile production 123456

# Custom session duration (12 hours)
./mfa-share.sh --profile production 123456 -t 43200

# Use custom AWS config file
./mfa-share.sh -a ~/custom-config --profile dev 123456
```

### After Running Script
```bash
# Set the profile to use temporary credentials
export AWS_PROFILE=aws-temp

# Verify credentials
aws sts get-caller-identity

# Use AWS CLI with temporary credentials
aws s3 ls
```

### Testing
```bash
# Validate shellcheck compliance
shellcheck mfa-share.sh

# Test MFA detection
./mfa-share.sh -v --profile production 123456 | grep "MFA Serial"

# Test profile listing
./mfa-share.sh --list-profiles

# Test dry-run mode
./mfa-share.sh -d --profile staging 123456
```

## Configuration Files

### Required: Base AWS Credentials
The script requires base IAM user credentials in `~/.aws/credentials`:
```ini
[default]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
```

### Required: AWS Config with Profiles
Ensure `~/.aws/config` includes MFA device and role profiles:
```ini
[profile production]
role_arn = arn:aws:iam::123456789012:role/PowerUserAccess
source_profile = default
region = us-east-1

[profile staging]
role_arn = arn:aws:iam::234567890123:role/DeveloperAccess
source_profile = default
region = us-west-2
```

## Important Constants

- `DEFAULT_REGION`: us-east-1 (line 35)
- `SESSION_DURATION`: 21600 seconds (6 hours, line 36)
- `MIN_SESSION_DURATION`: 900 seconds (15 minutes, line 37)
- `MAX_SESSION_DURATION`: 43200 seconds (12 hours, line 38)
- `OUTPUT_PROFILE_NAME`: "aws-temp" (line 39)
- `MAX_PROFILE_DISPLAY`: 15 (line 40)

## Key Functions

- `show_interactive_prompt()` (lines 109-182): Interactive menu with arrow-key navigation
- `select_profile_interactive()` (lines 185-310): Profile selection with arrow keys
- `list_profiles()` (lines 410-451): Lists all AWS config profiles with role_arn
- `get_profile_info()` (lines 454-507): Extracts account ID and role from profile
- `detect_mfa_serial()` (lines 514-555): Auto-detects MFA device ARN
- `assume_role_with_mfa()` (lines 561-686): Core AWS STS assume-role logic
- `write_credentials_to_profile()` (lines 692-786): Writes credentials to ~/.aws/credentials

## Script Execution Model

The script writes credentials to `~/.aws/credentials` as the `aws-temp` profile.

**Usage after execution:**
```bash
# Run the script
./mfa-share.sh --profile production 123456

# Set the profile in your shell
export AWS_PROFILE=aws-temp

# Use AWS CLI
aws s3 ls
```

Main execution starts at line 993 with `parse_arguments "$@"` followed by `main`.

## Dependencies

Required tools checked in `check_dependencies()` (lines 384-403):
- `aws` (AWS CLI v2+)
- `jq` (JSON processor)

## Error Handling

The script uses strict bash mode (line 26):
```bash
set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'        # Safe word splitting
```

All AWS API errors are caught and logged with context-specific help messages (lines 604-623):
- Invalid credentials → Check `~/.aws/credentials`
- Access denied → Role doesn't exist or no permission
- MFA failures → Check token validity and device configuration

## Prerequisites

**IMPORTANT:** This script requires:
1. **Base AWS credentials** in `~/.aws/credentials` (IAM user access keys)
2. **AWS config file** at `~/.aws/config` with profiles containing `role_arn`
3. **MFA device** configured and associated with your IAM user

Without these, the script will not work.

# Documentation
- Do not create documents to summarize changes
