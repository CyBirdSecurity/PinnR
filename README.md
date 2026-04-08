# PinnR

**Pin your GitHub Actions to commit SHAs — automatically.**

License: MIT
Bash

---

## Why PinnR?

Using floating tags or branch references in GitHub Actions workflows creates a **supply chain security risk**. Tags like `v3` or `main` can be moved to point to different commits, potentially introducing malicious code into your CI/CD pipeline.

### Before (Insecure)

```yaml
- uses: actions/checkout@v4
- uses: actions/setup-node@main
```

### After (Secure)

```yaml
- uses: actions/checkout@a81bbbf8298c0fa03ea29cdc473d45769f953675 # v4.1.0
- uses: actions/setup-node@1e60f620b9541d16bece96c5465dc8ee9832be0b # v4.1.2
```

PinnR automatically resolves tags and branches to their exact commit SHAs and adds inline comments to preserve human-readable version information.

---

## How It Works

1. **Scans** your `.github/workflows/` directory for action references
2. **Resolves** tags and branches to their specific commit SHAs via GitHub API
3. **Pins** actions by replacing references with SHAs (pinning to current version by default)
4. **Preserves** version information in inline comments (`# v4.1.0`)
5. **Optionally upgrades** to latest versions when using `-U` flag
6. **Optionally** creates a pull request for remote repositories

---

## Prerequisites

- **Bash 4+**
- **jq** (JSON processor)
- **Authentication** (choose one):
  - **GitHub CLI** (`gh`) — recommended
  - **Personal Access Token** via `GITHUB_TOKEN` environment variable
- **curl** (usually pre-installed)

### Installation

```bash
# Install jq (if not already installed)
brew install jq              # macOS
sudo apt-get install jq      # Ubuntu/Debian

# Install GitHub CLI (recommended)
brew install gh              # macOS
# See https://github.com/cli/cli#installation for other platforms

# Authenticate
gh auth login
```

---

## Installation

```bash
# Clone the repository
git clone https://github.com/CyBirdSecurity/pinnr.git
cd pinnr

# Make executable
chmod +x pinnr.sh

# Optionally, add to PATH
ln -s "$(pwd)/pinnr.sh" /usr/local/bin/pinnr
```

---

## Usage

```bash
pinnr [FLAGS] [PATH]
```

### Flags


| Flag          | Description                                                                                      |
| ------------- | ------------------------------------------------------------------------------------------------ |
| `-t`          | **Dry-run mode**: Show proposed changes as a diff without modifying files                        |
| `-U`          | **Upgrade mode**: Upgrade all actions to their latest versions (default: pin to current version) |
| `-S`          | **Scan mode**: Report status of all actions. Exit 1 if any are unpinned or outdated              |
| `-P`          | **Allow pre-releases**: Include pre-release tags (alpha, beta, rc). Default: stable only         |
| `-R <repo>`   | **Remote mode**: Process `owner/repo` and create a PR (never commits to default branch)          |
| `-b <branch>` | Specify custom branch name for `-R` (default: `pinnR/GHA-Update-YYYY-MM-DD`)                     |
| `-A <org>`    | **Audit organization**: Scan all repos in organization for unpinned actions, generate CSV report |
| `-O`          | **Unpinned-only mode**: CSV includes only unpinned actions (must be used with `-A`)              |
| `-h`          | Show help message                                                                                |


### Flag Combinations

All of the following are valid:

- `-t` (dry-run) works with any combination
- `-S` (scan) works with any combination
- `-P` (allow pre-releases) works with any combination
- `-R -U` (remote upgrade)
- `-R -b custom-branch` (custom branch name)
- `-t -U` (dry-run upgrade)
- `-S -U` (scan with upgrade check)
- `-U -P` (upgrade including pre-release versions)

---

## Examples

### Pin actions to their current version

By default, PinnR pins actions to the commit SHA of their current tag/ref without upgrading:

```bash
cd /path/to/your/repo
pinnr
```

If your workflow has `actions/checkout@v4`, it will pin to whatever commit `v4` currently points to, not upgrade to `v5`.

### Dry-run to see what would change

```bash
pinnr -t
```

Output:

```diff
--- .github/workflows/ci.yml
+++ .github/workflows/ci.yml
@@ -10,7 +10,7 @@
     runs-on: ubuntu-latest
     steps:
       - name: Checkout
-        uses: actions/checkout@v4
+        uses: actions/checkout@a81bbbf8298c0fa03ea29cdc473d45769f953675 # v4
```

### Upgrade all actions to latest versions

Use the `-U` flag to upgrade unpinned actions to the latest available version and update already-pinned actions:

```bash
pinnr -U
```

This will change `actions/checkout@v4` to the latest version (e.g., `v5`) if available.

### Include pre-release versions

By default, PinnR excludes pre-release tags (alpha, beta, rc, etc.) and only uses stable releases. Use `-P` to include pre-releases:

```bash
# Without -P: uses stable v1 tag
pinnr -t

# With -P: allows v2-beta tag
pinnr -t -P
```

This is useful when you specifically want to test bleeding-edge versions or when a project only publishes pre-release tags.

### Scan and report status

```bash
pinnr -S
```

Output:

```
📄 .github/workflows/ci.yml
  ✅ actions/checkout@a81bbbf... # v4.1.0 (up to date)
  ⚠️  actions/setup-node@main (unpinned — latest: v4.1.2 → sha: 1e60f62...)
  🔄 actions/cache@abc0000... # v3.0.0 (newer available: v3.3.2 → sha: fed9876...)
  ⏩  ./.github/actions/local-action (local — skipped)

Summary: 4 actions found | 1 up to date | 1 unpinned | 1 outdated | 1 skipped
```

Exit code: `1` (because unpinned/outdated actions were found)

### Process a remote repository

```bash
pinnr -R owner/repo
```

This will:

1. Fetch the repository's workflows
2. Pin all actions
3. Create a feature branch (`pinnR/GHA-Update-YYYY-MM-DD`)
4. Commit changes
5. Open a pull request
6. Print the PR URL

### Use a custom branch name for remote mode

```bash
pinnr -R owner/repo -b security/pin-actions-2024-03
```

---

## Organization-Wide Audits

Scan all repositories in a GitHub organization to identify unpinned GitHub Actions across your entire organization. This is essential for security teams performing supply chain risk assessments.

### Security Audit (Unpinned Only)

Generate a CSV report containing only unpinned actions for security review:

```bash
pinnr -A myorg -O
```

This mode filters out already-pinned actions, showing only the actions that need attention.

### Comprehensive Audit (All Actions)

Generate a complete inventory of all GitHub Actions used across the organization:

```bash
pinnr -A myorg
```

This includes both pinned and unpinned actions for full visibility.

### Output

The audit displays a real-time progress indicator and summary statistics in the terminal:

```
[INFO] Starting audit of organization: acme-corp
[INFO] Fetching repositories... (excluding archived)
[INFO] Found 47 repositories to scan

[████████████████████] 100% (47/47) acme-corp/api-service

=== PinnR Audit Summary ===

Organization: acme-corp
Date: 2026-04-07 15:32:11

Repositories:
  Total scanned:              47
  With workflows:             34
  Without workflows:          13
  With unpinned actions:      12

Actions:
  Total found:                234
  Pinned to SHA:              189 (80%)
  Unpinned (tags/branches):   45 (19%)
  Local (skipped):            8

Report saved to: pinnr-audit-acme-corp-2026-04-07.csv

[SUCCESS] Audit complete
```

### CSV Format

The CSV report is automatically saved with the filename pattern: `pinnr-audit-{org}-{date}.csv`

**Columns:**
- `Repository` - Full repository name (owner/repo)
- `Workflow File` - Path to the workflow file
- `Action` - The action being used (e.g., actions/checkout)
- `Current Ref` - The current reference (tag, branch, or SHA)
- `Is Pinned` - "yes" if pinned to SHA, "no" otherwise

**Example CSV:**

```csv
Repository,Workflow File,Action,Current Ref,Is Pinned
"acme-corp/api",".github/workflows/ci.yml","actions/checkout","v4","no"
"acme-corp/web",".github/workflows/ci.yml","actions/setup-node","a81bbf8298c0...","yes"
"acme-corp/backend",".github/workflows/test.yml","actions/cache","v3.2.0","no"
```

### Use Cases

**Security Compliance:**
```bash
# Generate unpinned actions report for security review
pinnr -A myorg -O

# Share CSV with security team for risk assessment
```

**Inventory Management:**
```bash
# Generate complete action inventory
pinnr -A myorg

# Use CSV to track action versions across organization
```

**Notes:**
- Archived repositories are automatically excluded
- Repositories without workflows are silently skipped
- Local actions (starting with `./`) are counted but not included in the report
- The `-O` flag cannot be used without `-A`
- Audit mode is read-only and never modifies repositories

---

## Authentication

### Option 1: GitHub CLI (Recommended)

```bash
gh auth login
```

Follow the prompts to authenticate. PinnR will automatically use your `gh` credentials.

### Option 2: Personal Access Token

Create a token at [github.com/settings/tokens](https://github.com/settings/tokens) with the appropriate scopes (see table below), then:

```bash
export GITHUB_TOKEN='your_token_here'
```

#### Required Token Scopes


| Operation                  | Required Scope                                         |
| -------------------------- | ------------------------------------------------------ |
| Read public repositories   | None (no token needed)                                 |
| Read private repositories  | `repo` or `contents: read`                             |
| Pin/upgrade with `-R`      | `repo` or (`contents: write` + `pull-requests: write`) |
| Audit organization (`-A`)  | `repo` or `read:org` (for private repos in org)        |


**Note**: Fine-grained tokens should have `contents: write` and `pull_requests: write` permissions for remote mode operations. For auditing private repositories in organizations, include `read:org` scope.

---

## Remote Repositories & the PR Workflow

### Safety First

PinnR **never commits directly to the default branch** when using `-R`. Instead, it:

1. Creates a feature branch (default: `pinnR/GHA-Update-YYYY-MM-DD`)
2. Commits changes to that branch
3. Opens a pull request for review

### Custom Branch Names

```bash
pinnr -R owner/repo -b my-custom-branch
```

If the branch already exists, PinnR will exit with an error and suggest using `-b` to specify a different name.

### Branch Cleanup

If you close the PR without merging, **you are responsible for deleting the feature branch**. GitHub will typically offer a "Delete branch" button on closed PRs.

---

## Using `-S` in CI

You can enforce that all actions remain pinned by adding PinnR to your CI workflow:

```yaml
name: Verify Pinned Actions

on:
  pull_request:
  schedule:
    - cron: '0 0 * * 1'  # Weekly check

jobs:
  verify-pinned:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@a81bbbf8298c0fa03ea29cdc473d45769f953675 # v4.1.0

      - name: Install jq
        run: sudo apt-get update && sudo apt-get install -y jq

      - name: Verify actions are pinned
        run: |
          curl -sSL https://raw.githubusercontent.com/your-org/pinnr/main/pinnr.sh | bash -s -- -S
```

The job will **fail** (exit 1) if any actions are unpinned or outdated.

---

## FAQ / Troubleshooting

### Rate Limiting

GitHub API has rate limits:

- **Unauthenticated**: 60 requests/hour
- **Authenticated**: 5,000 requests/hour

If you hit the limit, PinnR will display the reset time and exit. Authenticate with `gh auth login` or set `GITHUB_TOKEN` for higher limits.

### Local Actions

PinnR automatically skips local actions (e.g., `uses: ./.github/actions/something`). They cannot be pinned because they're local files, not remote repositories.

### Pre-Release Tags

By default, PinnR excludes pre-release versions to ensure stability. It filters out tags containing:

- `alpha`, `beta`, `rc` (release candidate)
- `pre`, `dev`, `preview`
- `canary`, `snapshot`, `experimental`

**Example**: If a repo has tags `v2-beta` (May 2024) and `v1` (Jan 2025), PinnR will choose `v1` because it's the latest **stable** release.

Use the `-P` flag to include pre-release tags when you need bleeding-edge versions or when a project only publishes pre-releases.

### Undoing Changes

If you've run PinnR locally and want to undo:

```bash
git checkout .github/workflows/
```

Or revert the commit:

```bash
git revert HEAD
```

### Private Repository 403 Errors

Ensure your token has the correct scopes:

```bash
# For GitHub CLI
gh auth refresh -s repo

# For personal access token
# Regenerate token with 'repo' scope at https://github.com/settings/tokens
```

### Actions with No Releases or Tags

If an action has no releases or tags, PinnR will print a warning and skip it. This is rare but can happen with experimental or archived repositories.

### Default Behavior vs Upgrade Mode

**Default (no `-U` flag)**:
- Unpinned actions are pinned to their current tag/ref (e.g., `v4` → SHA of `v4`)
- Already pinned actions are left unchanged

**With `-U` flag**:
- Unpinned actions are upgraded to the latest version
- Already pinned actions are upgraded to the latest version

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on how to contribute to PinnR.

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Security

PinnR improves your supply chain security by preventing tag/branch hijacking. However, always review the PRs it creates before merging, especially when upgrading to newer versions.

For security issues with PinnR itself, please open an issue on GitHub.

---

**Made with 🔐 for safer CI/CD pipelines**