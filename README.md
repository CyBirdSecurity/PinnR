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
2. **Resolves** floating tags and branches to their specific commit SHAs via GitHub API
3. **Pins** actions by replacing references with SHAs
4. **Preserves** version information in inline comments (`# v4.1.0`)
5. **Optionally** creates a pull request for remote repositories

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


| Flag          | Description                                                                             |
| ------------- | --------------------------------------------------------------------------------------- |
| `-t`          | **Dry-run mode**: Show proposed changes as a diff without modifying files               |
| `-U`          | **Upgrade mode**: Update all actions to their latest versions (even if already pinned)  |
| `-S`          | **Scan mode**: Report status of all actions. Exit 1 if any are unpinned or outdated     |
| `-R <repo>`   | **Remote mode**: Process `owner/repo` and create a PR (never commits to default branch) |
| `-b <branch>` | Specify custom branch name for `-R` (default: `pinnR/GHA-Update-YYYY-MM-DD`)            |
| `-h`          | Show help message                                                                       |


### Flag Combinations

All of the following are valid:

- `-t` (dry-run) works with any combination
- `-S` (scan) works with any combination
- `-R -U` (remote upgrade)
- `-R -b custom-branch` (custom branch name)
- `-t -U` (dry-run upgrade)
- `-S -U` (scan with upgrade check)

---

## Examples

### Pin unpinned actions locally

```bash
cd /path/to/your/repo
pinnr
```

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
+        uses: actions/checkout@a81bbbf8298c0fa03ea29cdc473d45769f953675 # v4.1.0
```

### Upgrade all actions to latest versions

```bash
pinnr -U
```

### Scan and report status

```bash
pinnr -S
```

Output:

```
:page_facing_up: .github/workflows/ci.yml
  :white_check_mark: actions/checkout@a81bbbf... # v4.1.0 (up to date)
  :warning:  actions/setup-node@main (unpinned — latest: v4.1.2 → sha: 1e60f62...)
  :arrows_counterclockwise: actions/cache@abc0000... # v3.0.0 (newer available: v3.3.2 → sha: fed9876...)
  :black_right_pointing_double_triangle_with_vertical_bar:  ./.github/actions/local-action (local — skipped)

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


| Operation                 | Required Scope                                         |
| ------------------------- | ------------------------------------------------------ |
| Read public repositories  | None (no token needed)                                 |
| Read private repositories | `repo` or `contents: read`                             |
| Pin/upgrade with `-R`     | `repo` or (`contents: write` + `pull-requests: write`) |


**Note**: Fine-grained tokens should have `contents: write` and `pull_requests: write` permissions.

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

### Already Pinned Actions

By default, PinnR skips actions that are already pinned to a SHA. To update them to the latest version, use `-U`.

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