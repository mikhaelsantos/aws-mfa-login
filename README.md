# AWS MFA Role Assumption Script

A bash script for assuming AWS IAM roles with MFA authentication. Designed for teams managing multiple AWS accounts with temporary credentials.

## Features

✨ **Smart MFA Detection** - Automatically detects your MFA device from AWS config
🎯 **Profile-Based Authentication** - Use AWS config profiles for easy role assumption
📝 **Credential Management** - Stores temporary credentials in `~/.aws/credentials` as `aws-temp` profile
🎨 **Rich CLI Experience** - Colored output, interactive menus, verbose mode, helpful error messages
🔒 **Security First** - Validates inputs, proper error handling, credential isolation
🚀 **Production Ready** - Strict mode, shellcheck compliant, comprehensive error handling
⚡ **Interactive Mode** - Arrow-key navigation for profile selection

## Requirements

- **AWS CLI** v2+ ([installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html))
- **jq** JSON processor: `brew install jq` (macOS) or `apt-get install jq` (Linux)
- **AWS credentials configured** in `~/.aws/credentials` (base IAM user credentials)
- **AWS config file** at `~/.aws/config` with profiles and MFA serial
- **MFA device** configured (physical or virtual authenticator)

**Important:** This script relies on properly configured `~/.aws/credentials` and `~/.aws/config` files. It assumes you have base IAM user credentials already set up and uses them to assume roles with MFA.

## Installation

```bash
# Download the script
curl -O https://raw.githubusercontent.com/your-org/scripts/main/mfa-share.sh

# Make it executable
chmod +x mfa-share.sh

# Optional: Move to your PATH
sudo mv mfa-share.sh /usr/local/bin/aws-mfa
```

## Quick Start

```bash
# Interactive mode - no arguments needed
./mfa-share.sh

# Use a specific AWS config profile
./mfa-share.sh --profile production 123456

# Manual mode with account ID and role
./mfa-share.sh 123456 123456789012 PowerUserAccess

# List available profiles
./mfa-share.sh --list-profiles

# Verbose mode for debugging
./mfa-share.sh -v --profile staging 123456
```

## Usage

### Profile Mode (Recommended)
```
./mfa-share.sh --profile <PROFILE_NAME> <MFA_TOKEN> [OPTIONS]
```

### Manual Mode
```
./mfa-share.sh <MFA_TOKEN> <ACCOUNT_ID> <ROLE_NAME> [OPTIONS]
```

### Interactive Mode
```
./mfa-share.sh
```
No arguments needed - navigate with arrow keys and select your profile.

### Arguments

**Profile Mode:**
| Argument | Description | Required |
|----------|-------------|----------|
| `--profile NAME` | AWS config profile name | Yes |
| `MFA_TOKEN` | 6-digit code from your authenticator app | Yes |

**Manual Mode:**
| Argument | Description | Required |
|----------|-------------|----------|
| `MFA_TOKEN` | 6-digit code from your authenticator app | Yes |
| `ACCOUNT_ID` | 12-digit AWS account ID | Yes |
| `ROLE_NAME` | IAM role to assume | Yes |

### Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-v, --verbose` | Enable verbose debug output |
| `-p, --list-profiles` | List all available AWS config profiles |
| `-d, --dry-run` | Validate configuration without assuming role |
| `-t, --duration SECONDS` | Session duration (default: 21600, max: 43200) |
| `-a, --aws-config FILE` | Use custom AWS config file |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `AWS_MFA_SERIAL` | Override auto-detected MFA serial number |
| `AWS_REGION` | Set AWS region (default: us-east-1) |

## Configuration

### Prerequisites: Base AWS Credentials

**This script requires existing AWS credentials to work.** Before using this script, ensure you have:

1. **Base IAM user credentials** in `~/.aws/credentials`:
   ```ini
   [default]
   aws_access_key_id = AKIA...
   aws_secret_access_key = ...
   ```

2. **AWS config file** at `~/.aws/config` with profiles and MFA device

### AWS Config Setup

The script reads from `~/.aws/config` to find profiles with `role_arn` defined. Ensure your config includes:

1. **MFA device configuration** (for auto-detection)
2. **Profile definitions** with role_arn

Example `~/.aws/config`:

```ini
[profile production]
role_arn = arn:aws:iam::123456789012:role/PowerUserAccess
source_profile = default
region = us-east-1

[profile staging]
role_arn = arn:aws:iam::234567890123:role/DeveloperAccess
source_profile = default
region = us-west-2

[profile readonly]
role_arn = arn:aws:iam::345678901234:role/ReadOnlyAccess
source_profile = default
region = eu-west-1
```

Or set it as an environment variable:

```bash
export AWS_MFA_SERIAL="arn:aws:iam::999999999999:mfa/your.email@company.com"
```

## Examples

### Basic Workflow

```bash
# 1. Check available profiles from AWS config
./mfa-share.sh --list-profiles

# 2. Get MFA code from authenticator app (e.g., 123456)

# 3. Assume role using profile
./mfa-share.sh --profile production 123456

# 4. Set the profile and verify credentials
export AWS_PROFILE=aws-temp
aws sts get-caller-identity
```

### Interactive Mode (Easiest)

```bash
# Run without arguments for interactive menu
./mfa-share.sh

# Use arrow keys to select profile
# Enter your 6-digit MFA code when prompted
# Credentials automatically written to aws-temp profile
```

### Advanced Usage

```bash
# Verbose mode for debugging
./mfa-share.sh -v --profile staging 123456

# Manual mode with specific account ID and role
./mfa-share.sh 123456 123456789012 SecurityAudit

# Custom session duration (12 hours)
./mfa-share.sh --profile production 123456 -t 43200

# Dry-run to validate without making AWS calls
./mfa-share.sh -d --profile staging 123456

# Use custom AWS config file
./mfa-share.sh -a ~/custom-config --profile dev 123456
```

### Integration with Shell Aliases

Add to your `~/.bashrc` or `~/.zshrc`:

```bash
# Quick MFA alias
alias mfa='~/scripts/mfa-share.sh'

# Usage
mfa --profile production 123456

# Then set profile
export AWS_PROFILE=aws-temp
```

## How Credentials Are Stored

The script writes temporary AWS credentials to `~/.aws/credentials` under the profile name `aws-temp`.

**What happens:**
1. Script calls AWS STS AssumeRole with your MFA token
2. Receives temporary credentials (valid for 6 hours by default)
3. Writes credentials to `~/.aws/credentials` as `[aws-temp]` profile
4. You set `AWS_PROFILE=aws-temp` to use them

**Credential format in `~/.aws/credentials`:**
```ini
[aws-temp]
aws_access_key_id = ASIA...
aws_secret_access_key = ...
aws_session_token = ...
```

**Using the credentials:**
```bash
# Set environment variable
export AWS_PROFILE=aws-temp

# Or use --profile flag with AWS CLI
aws s3 ls --profile aws-temp
```

## Troubleshooting

### "Could not auto-detect MFA serial number"

**Solution 1:** Add to `~/.aws/config`:
```ini
mfa_serial = arn:aws:iam::YOUR_ACCOUNT:mfa/your.name@company.com
```

**Solution 2:** Set environment variable:
```bash
export AWS_MFA_SERIAL="arn:aws:iam::YOUR_ACCOUNT:mfa/your.name@company.com"
```

### "Failed to assume role"

Common causes:
- **Invalid MFA token** - Ensure time is synced on your device
- **Token expired** - MFA codes are time-sensitive (30-60 seconds)
- **No permission** - Verify you have `sts:AssumeRole` permission
- **Role doesn't exist** - Check role name and account ID
- **Trust policy issue** - Ensure role trusts your IAM user/role

### "Missing required dependencies"

Install missing tools:
```bash
# macOS
brew install awscli jq

# Ubuntu/Debian
sudo apt-get update
sudo apt-get install awscli jq

# Amazon Linux
sudo yum install aws-cli jq
```

### Credentials not available after running script

The script writes credentials to `~/.aws/credentials`, but you need to set the profile.

**Wrong:**
```bash
./mfa-share.sh --profile production 123456
aws s3 ls  # Won't work - using wrong profile
```

**Correct:**
```bash
./mfa-share.sh --profile production 123456
export AWS_PROFILE=aws-temp
aws s3 ls  # Works - using aws-temp profile
```

**Or use --profile flag:**
```bash
./mfa-share.sh --profile production 123456
aws s3 ls --profile aws-temp
```

## Security Considerations

✅ **Safe practices in this script:**
- No credentials stored in script or repository
- Auto-detects MFA device from config
- Validates all inputs before AWS API calls
- Unsets existing credentials before assuming role
- Creates backups before modifying files
- Credentials expire after 6 hours (configurable)

⚠️ **User responsibilities:**
- Never commit AWS credentials to version control
- Rotate MFA devices if compromised
- Use least-privilege IAM roles
- Review CloudTrail logs periodically
- Don't share MFA codes

## Customization

### Change Session Duration

**Option 1: Use command-line flag (recommended)**
```bash
./mfa-share.sh --profile production 123456 -t 43200  # 12 hours
./mfa-share.sh --profile production 123456 -t 3600   # 1 hour
```

**Option 2: Edit script constant**
Edit the `SESSION_DURATION` variable at [mfa-share.sh:36](mfa-share.sh#L36):
```bash
readonly SESSION_DURATION=43200  # 12 hours (max)
```

AWS limits: 900 seconds (15 min) to 43200 seconds (12 hours)

### Change Default Region

**Option 1: Set environment variable**
```bash
export AWS_REGION=eu-west-1
./mfa-share.sh --profile production 123456
```

**Option 2: Edit script constant**
Edit the `DEFAULT_REGION` variable at [mfa-share.sh:35](mfa-share.sh#L35):
```bash
readonly DEFAULT_REGION="eu-west-1"
```

**Option 3: Set in AWS config profile**
```ini
[profile production]
role_arn = arn:aws:iam::123456789012:role/PowerUserAccess
region = eu-west-1
```

## Setting Up Your Profiles

The script reads profiles from `~/.aws/config`. Here's how to set up your organization's accounts:

### Example: Multi-Account Setup

```ini
[profile prod-main]
role_arn = arn:aws:iam::123456789012:role/PowerUserAccess
source_profile = default
region = us-east-1

[profile prod-dr]
role_arn = arn:aws:iam::234567890123:role/PowerUserAccess
source_profile = default
region = us-west-2

[profile staging]
role_arn = arn:aws:iam::345678901234:role/DeveloperAccess
source_profile = default
region = us-east-1

[profile dev]
role_arn = arn:aws:iam::456789012345:role/AdminAccess
source_profile = default
region = us-east-1

[profile security-audit]
role_arn = arn:aws:iam::567890123456:role/SecurityAudit
source_profile = default
region = us-east-1
```

### Profile Components

- **`role_arn`** (required): Full ARN of the role to assume
- **`source_profile`** (optional): Base profile with credentials
- **`region`** (optional): AWS region for this profile

## FAQ

**Q: How long do credentials last?**
A: Default is 6 hours. Maximum is 12 hours (AWS limit).

**Q: Can I use this in CI/CD pipelines?**
A: No. Use IAM roles for service accounts instead. MFA requires human interaction.

**Q: Does this work with AWS SSO?**
A: No, this is for IAM users with MFA. For SSO, use `aws sso login`.

**Q: Can I assume roles across different AWS organizations?**
A: Yes, if the target role's trust policy allows your source account.

**Q: What if I have multiple MFA devices?**
A: Set `AWS_MFA_SERIAL` environment variable to specify which device to use.

## Contributing

Contributions welcome! Please:

1. Test changes thoroughly
2. Follow existing code style
3. Update documentation
4. Ensure shellcheck passes: `shellcheck mfa-share.sh`
5. Add examples for new features

## License

MIT License - feel free to use and modify for your organization.

## Support

- **No Support**

## Changelog

### v3.0 (Current)
- Interactive mode with arrow-key navigation
- Profile-based authentication from AWS config
- Auto-detection of MFA serial numbers
- Credential storage in `~/.aws/credentials`
- Dry-run mode for validation
- Configurable session duration
- Verbose mode and enhanced error handling
- Support for Linux and macOS
- Shellcheck compliance
- Comprehensive documentation

### v2.0
- Profile support added
- Enhanced error messages
- Multiple output modes

### v1.0
- Initial release
- Basic MFA role assumption

---

**Author:** Mikhael Santos + Claud Code
**Last Updated:** 2025

