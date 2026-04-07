# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-04-07

### Added

- Initial release of PinnR
- **Core functionality**:
  - Automatic detection of GitHub Actions in workflow files
  - Resolution of floating tags and branches to commit SHAs
  - Inline version comments for traceability (e.g., `# v4.1.0`)
  - Support for both annotated and lightweight Git tags
  - Automatic skipping of local actions (`./.github/actions/...`)

- **Flags and modes**:
  - `-t` (Dry-run mode): Preview changes without modifying files
  - `-U` (Upgrade mode): Update all actions to their latest versions
  - `-S` (Scan mode): Report status with formatted output and exit codes
  - `-R <repo>` (Remote mode): Process remote repositories via PR workflow
  - `-b <branch>` (Custom branch): Specify custom feature branch names
  - `-h` (Help): Display usage information

- **Authentication support**:
  - GitHub CLI (`gh`) integration (recommended)
  - Personal Access Token via `GITHUB_TOKEN` environment variable
  - Automatic fallback between authentication methods

- **Remote repository workflow**:
  - Safe PR-based workflow (never commits to default branch)
  - Automatic feature branch creation
  - Comprehensive PR body with change summary
  - Branch conflict detection and helpful error messages

- **Scan mode features**:
  - Color-coded status indicators (emojis)
  - Detailed action-by-action reporting
  - Summary statistics (total, up to date, unpinned, outdated, skipped)
  - Exit code 0 for clean repos, 1 for issues found

- **Error handling**:
  - GitHub API rate limit detection with reset time display
  - 404 handling for missing refs/repos
  - Permission error detection with required scope guidance
  - Network failure handling
  - Branch conflict detection

- **Output prefixes**:
  - `[PIN]` - Newly pinned actions
  - `[SKIP]` - Already up to date
  - `[UPDATE]` - SHA updated to newer version
  - `[SCAN]` - Scan mode information
  - `[WARN]` - Non-fatal warnings
  - `[ERROR]` - Fatal errors

### Technical Details

- **Dependencies**: Requires `bash` 4+, `jq`, `curl`, and `gh` CLI or `GITHUB_TOKEN`
- **Implementation**: Single-file Bash script with no external dependencies
- **Atomic writes**: Uses temp files + `mv` for safe file updates
- **API efficiency**: Minimal API calls with intelligent caching
- **POSIX-compatible**: Uses POSIX shell constructs where possible

### Documentation

- Comprehensive README.md with examples and troubleshooting
- CONTRIBUTING.md with development guidelines
- Test fixtures covering common scenarios
- GitHub Actions workflow for self-verification

[Unreleased]: https://github.com/CyBirdSecurity/pinnr/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/CyBirdSecurity/pinnr/releases/tag/v1.0.0
