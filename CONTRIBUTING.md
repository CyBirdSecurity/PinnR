# Contributing to PinnR

Thank you for your interest in contributing to PinnR! This document provides guidelines and instructions for contributing.

---

## Getting Started

### Prerequisites

- Bash 4+
- `jq` (JSON processor)
- `gh` CLI or `GITHUB_TOKEN` for testing
- Git

### Clone and Setup

```bash
git clone https://github.com/CyBirdSecurity/pinnr.git
cd pinnr
chmod +x pinnr.sh
```

---

## Development Workflow

### Running Tests Locally

PinnR includes test fixtures that cover various action scenarios:

```bash
# Run dry-run against test fixtures
./pinnr.sh -t test/fixtures

# Run scan mode against test fixtures
./pinnr.sh -S test/fixtures

# Expected output should show:
# - Unpinned actions (warnings)
# - Already-pinned actions (checks)
# - Local actions (skipped)
# - Actions needing upgrades
```

### Testing Your Changes

1. Make your changes to `pinnr.sh`
2. Test against the fixtures:
   ```bash
   ./pinnr.sh -t test/fixtures
   ./pinnr.sh -S test/fixtures
   ```
3. Test against a real repository (your own or a fork):
   ```bash
   ./pinnr.sh -t /path/to/test/repo
   ```
4. Verify all edge cases work correctly

### Code Style

- **Bash Best Practices**:
  - Use `set -euo pipefail` at the top of scripts
  - Quote all variable expansions: `"$var"` not `$var`
  - Use `[[ ]]` for conditionals, not `[ ]`
  - Prefer `$()` over backticks for command substitution

- **Function Naming**:
  - Use `snake_case` for function names
  - Use descriptive names: `resolve_ref_to_sha` not `get_sha`

- **Comments**:
  - Add comments for non-obvious logic
  - Use section headers with `# === SECTION NAME ===`
  - Document complex API interactions

- **Error Handling**:
  - Always check return codes for external commands
  - Use descriptive error messages with `[ERROR]` prefix
  - Provide actionable guidance when possible

- **POSIX Compatibility**:
  - Prefer POSIX-compliant constructs where possible
  - Document any bash-specific features used (arrays, etc.)

---

## Pull Request Process

### Before Submitting

1. **Test thoroughly**:
   - Run against test fixtures
   - Test all flag combinations
   - Verify error handling

2. **Update documentation**:
   - Add examples for new flags/features
   - Update README.md if user-facing behavior changes
   - Update CHANGELOG.md

3. **Check code style**:
   - Follow the style guidelines above
   - Add comments for complex logic
   - Keep functions focused and small

### Submitting a PR

1. Fork the repository
2. Create a feature branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. Make your changes
4. Commit with clear messages:
   ```bash
   git commit -m "feat: add support for custom API endpoints"
   ```
5. Push to your fork:
   ```bash
   git push origin feature/your-feature-name
   ```
6. Open a pull request against `main`

### PR Guidelines

- **Title**: Use conventional commit format:
  - `feat:` for new features
  - `fix:` for bug fixes
  - `docs:` for documentation changes
  - `refactor:` for code refactoring
  - `test:` for test additions/changes

- **Description**: Include:
  - What changed and why
  - How to test the changes
  - Any breaking changes
  - Related issues (use `Fixes #123` to auto-close)

- **Size**: Keep PRs focused and reasonably sized
  - Large PRs are harder to review
  - Consider breaking up into smaller logical changes

---

## Reporting Bugs

### Before Reporting

1. Check existing issues to avoid duplicates
2. Test with the latest version of PinnR
3. Verify your environment meets prerequisites

### Bug Report Template

When opening an issue, please include:

```markdown
**Environment**:
- PinnR version: (git commit hash or release tag)
- Bash version: `bash --version`
- OS: (macOS, Linux distro, etc.)
- jq version: `jq --version`
- Authentication method: (gh CLI / GITHUB_TOKEN)

**Command**:
The exact command you ran:
```bash
./pinnr.sh -flags ...
```

**Expected behavior**:
What you expected to happen.

**Actual behavior**:
What actually happened.

**Workflow file** (if relevant):
```yaml
# Paste the relevant workflow file or snippet
```

**Error output**:
```
Paste any error messages here
```

**Additional context**:
Any other information that might be relevant.
```

---

## Feature Requests

We welcome feature requests! Please open an issue with:

- **Use case**: Describe the problem you're trying to solve
- **Proposed solution**: How you envision the feature working
- **Alternatives**: Other approaches you've considered
- **Examples**: Concrete examples of how it would be used

---

## Development Guidelines

### Adding New Flags

1. Add flag parsing in the `main()` function
2. Update the `print_usage()` function
3. Add validation and compatibility checks
4. Update README.md with examples
5. Add tests (fixtures or manual test cases)

### Modifying API Interactions

1. Keep `gh_api_get()`, `gh_api_post()`, `gh_api_put()` generic
2. Handle both `gh` CLI and `curl` paths
3. Add proper error handling for rate limits and auth failures
4. Test with both authentication methods

### Working with GitHub API

- Consult the [GitHub REST API documentation](https://docs.github.com/en/rest)
- Use `jq` for all JSON parsing
- Handle pagination if dealing with large result sets
- Respect rate limits and provide clear error messages

---

## Testing Philosophy

- **Fixtures**: Use test fixtures for common scenarios
- **Real repositories**: Test against real repos (your own forks)
- **Error cases**: Explicitly test error handling
- **Edge cases**: Test unusual but valid inputs

---

## Community Guidelines

- Be respectful and constructive
- Welcome newcomers and help them get started
- Focus on the technical merits of ideas
- Assume good intentions

---

## Questions?

If you have questions about contributing:

1. Check existing issues and discussions
2. Open a new issue with the `question` label
3. Be specific about what you're trying to achieve

---

Thank you for contributing to PinnR! 🔐
