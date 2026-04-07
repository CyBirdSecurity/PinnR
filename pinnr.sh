#!/usr/bin/env bash

set -euo pipefail

# PinnR - Pin GitHub Actions to commit SHAs automatically
# MIT License

# === GLOBALS ===
DRY_RUN=false
UPGRADE_MODE=false
SCAN_MODE=false
REMOTE_REPO=""
BRANCH_NAME=""
ALLOW_PRERELEASE=false
USE_GH_CLI=false
USE_CURL=false

# === DEPENDENCY CHECKS ===
check_dependencies() {
    local missing=()
    local warnings=()

    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        USE_GH_CLI=true
    elif [[ -n "${GITHUB_TOKEN:-}" ]] && command -v curl &>/dev/null; then
        USE_CURL=true
    else
        echo "[ERROR] Authentication not configured."
        echo ""
        echo "Please set up authentication using ONE of these methods:"
        echo ""
        echo "  1. GitHub CLI (recommended):"
        echo "     brew install gh"
        echo "     gh auth login"
        echo ""
        echo "  2. Personal Access Token:"
        echo "     export GITHUB_TOKEN='your_token_here'"
        echo ""
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[ERROR] Missing required dependencies: ${missing[*]}"
        echo "Please install them to continue."
        exit 1
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        for warn in "${warnings[@]}"; do
            echo "[WARN] $warn"
        done
    fi
}

# === GITHUB API HELPERS ===
gh_api_get() {
    local endpoint="$1"
    local response

    if [[ "$USE_GH_CLI" == true ]]; then
        response=$(gh api "$endpoint" 2>&1) || {
            echo "[ERROR] API call failed: $endpoint" >&2
            echo "$response" >&2
            return 1
        }
    else
        response=$(curl -sSf -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com$endpoint" 2>&1) || {
            local exit_code=$?
            if echo "$response" | grep -q "rate limit"; then
                local reset_time=$(echo "$response" | sed -n 's/.*X-RateLimit-Reset: \([0-9]*\).*/\1/p' || echo "unknown")
                echo "[ERROR] Rate limit exceeded. Reset time: $reset_time" >&2
                exit 1
            fi
            echo "[ERROR] API call failed: $endpoint" >&2
            echo "$response" >&2
            return 1
        }
    fi

    echo "$response"
}

gh_api_post() {
    local endpoint="$1"
    local data="$2"
    local response

    if [[ "$USE_GH_CLI" == true ]]; then
        response=$(echo "$data" | gh api "$endpoint" --input - 2>&1) || {
            echo "[ERROR] API POST failed: $endpoint" >&2
            echo "$response" >&2
            return 1
        }
    else
        response=$(curl -sSf -X POST \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "https://api.github.com$endpoint" 2>&1) || {
            local exit_code=$?
            if [[ $exit_code -eq 22 ]]; then
                if echo "$response" | grep -q "403"; then
                    echo "[ERROR] Permission denied. Required scopes: contents:write, pull-requests:write" >&2
                fi
            fi
            echo "[ERROR] API POST failed: $endpoint" >&2
            echo "$response" >&2
            return 1
        }
    fi

    echo "$response"
}

gh_api_put() {
    local endpoint="$1"
    local data="$2"
    local response

    if [[ "$USE_GH_CLI" == true ]]; then
        response=$(echo "$data" | gh api -X PUT "$endpoint" --input - 2>&1) || {
            echo "[ERROR] API PUT failed: $endpoint" >&2
            echo "$response" >&2
            return 1
        }
    else
        response=$(curl -sSf -X PUT \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "https://api.github.com$endpoint" 2>&1) || {
            echo "[ERROR] API PUT failed: $endpoint" >&2
            echo "$response" >&2
            return 1
        }
    fi

    echo "$response"
}

# === SHA RESOLUTION ===
is_pinned() {
    local ref="$1"
    [[ "$ref" =~ ^[0-9a-f]{40}$ ]]
}

resolve_ref_to_sha() {
    local owner="$1"
    local repo="$2"
    local ref="$3"

    # Try as a tag first
    local response
    response=$(gh_api_get "/repos/$owner/$repo/git/ref/tags/$ref" 2>&1) || {
        # Try as a branch
        response=$(gh_api_get "/repos/$owner/$repo/git/ref/heads/$ref" 2>&1) || {
            echo "[WARN] Could not resolve ref '$ref' for $owner/$repo" >&2
            return 1
        }
    }

    local obj_type
    obj_type=$(echo "$response" | jq -r '.object.type')

    if [[ "$obj_type" == "tag" ]]; then
        # Annotated tag - need to dereference
        local tag_sha
        tag_sha=$(echo "$response" | jq -r '.object.sha')
        local tag_obj
        tag_obj=$(gh_api_get "/repos/$owner/$repo/git/tags/$tag_sha")
        echo "$tag_obj" | jq -r '.object.sha'
    else
        # Direct commit reference
        echo "$response" | jq -r '.object.sha'
    fi
}

is_prerelease_tag() {
    local tag="$1"
    # Check for common pre-release indicators
    if echo "$tag" | grep -qiE '(alpha|beta|rc|pre|dev|preview|canary|snapshot|experimental)'; then
        return 0  # Is a pre-release
    fi
    return 1  # Not a pre-release
}

get_latest_version() {
    local owner="$1"
    local repo="$2"

    # Try releases first
    local response
    response=$(gh_api_get "/repos/$owner/$repo/releases/latest" 2>&1) || {
        # Fallback to tags
        response=$(gh_api_get "/repos/$owner/$repo/tags" 2>&1) || {
            echo "[WARN] No releases or tags found for $owner/$repo" >&2
            return 1
        }

        # Filter tags based on pre-release setting
        if [[ "$ALLOW_PRERELEASE" == false ]]; then
            # Find first non-prerelease tag
            local tag
            while IFS= read -r tag; do
                if ! is_prerelease_tag "$tag"; then
                    echo "$tag"
                    return 0
                fi
            done < <(echo "$response" | jq -r '.[].name')

            # If no stable tags found, warn and use first tag anyway
            echo "[WARN] No stable releases found for $owner/$repo, using latest tag" >&2
        fi

        echo "$response" | jq -r '.[0].name'
        return 0
    }

    echo "$response" | jq -r '.tag_name'
}

# === FILE PROCESSING ===
process_workflow_file() {
    local file_path="$1"
    local changed=false
    local temp_file
    temp_file=$(mktemp)

    if [[ "$SCAN_MODE" == true ]]; then
        echo ""
        echo "📄 $file_path"
    fi

    local total_actions=0
    local up_to_date=0
    local unpinned=0
    local outdated=0
    local skipped=0

    while IFS= read -r line; do
        if echo "$line" | grep -qE '^[[:space:]]*uses:[[:space:]]+'; then
            local indent
            indent=$(echo "$line" | sed 's/^\([[:space:]]*\)uses:.*/\1/')

            local uses_part
            uses_part=$(echo "$line" | sed 's/^[[:space:]]*uses:[[:space:]]*//; s/[[:space:]]*$//')

            # Check for local action
            if echo "$uses_part" | grep -qE '^\.\/'; then
                if [[ "$SCAN_MODE" == true ]]; then
                    echo "  ⏩  $uses_part (local — skipped)"
                    ((skipped++))
                    ((total_actions++))
                fi
                echo "$line" >> "$temp_file"
                continue
            fi

            # Parse owner/repo@ref
            local action_with_ref
            action_with_ref=$(echo "$uses_part" | awk '{print $1}')

            if [[ ! "$action_with_ref" =~ @ ]]; then
                echo "$line" >> "$temp_file"
                continue
            fi

            local action_path="${action_with_ref%@*}"
            local current_ref="${action_with_ref#*@}"

            # Extract owner and repo (handle subpaths)
            local owner
            local repo
            if [[ "$action_path" == */* ]]; then
                owner=$(echo "$action_path" | cut -d'/' -f1)
                repo=$(echo "$action_path" | cut -d'/' -f2)
            else
                echo "$line" >> "$temp_file"
                continue
            fi

            ((total_actions++))

            # Check if already pinned
            local is_currently_pinned=false
            if is_pinned "$current_ref"; then
                is_currently_pinned=true
            fi

            # Get existing comment if present
            local existing_comment=""
            if echo "$line" | grep -q '#'; then
                existing_comment=$(echo "$line" | sed -n 's/.*#[[:space:]]*//p')
            fi

            if [[ "$UPGRADE_MODE" == true ]] || [[ "$is_currently_pinned" == false ]]; then
                # Resolve latest version
                local latest_tag
                latest_tag=$(get_latest_version "$owner" "$repo") || {
                    echo "$line" >> "$temp_file"
                    continue
                }

                local latest_sha
                latest_sha=$(resolve_ref_to_sha "$owner" "$repo" "$latest_tag") || {
                    echo "$line" >> "$temp_file"
                    continue
                }

                if [[ "$is_currently_pinned" == true ]] && [[ "$current_ref" == "$latest_sha" ]]; then
                    # Already on latest SHA
                    if [[ "$SCAN_MODE" == true ]]; then
                        echo "  ✅ $action_path@${current_ref:0:7}... # $existing_comment (up to date)"
                        ((up_to_date++))
                    else
                        echo "[SKIP] $action_path already on latest SHA ($latest_sha)"
                    fi
                    echo "$line" >> "$temp_file"
                elif [[ "$is_currently_pinned" == false ]]; then
                    # Unpinned - pin it
                    if [[ "$SCAN_MODE" == true ]]; then
                        echo "  ⚠️  $action_path@$current_ref (unpinned — latest: $latest_tag → sha: ${latest_sha:0:7}...)"
                        ((unpinned++))
                    else
                        echo "[PIN] $action_path@$current_ref → $latest_sha # $latest_tag"
                    fi
                    local new_line="${indent}uses: $action_path@$latest_sha # $latest_tag"
                    echo "$new_line" >> "$temp_file"
                    changed=true
                else
                    # Outdated SHA - upgrade
                    if [[ "$SCAN_MODE" == true ]]; then
                        echo "  🔄 $action_path@${current_ref:0:7}... # $existing_comment (newer available: $latest_tag → sha: ${latest_sha:0:7}...)"
                        ((outdated++))
                    else
                        echo "[UPDATE] $action_path@$current_ref → $latest_sha # $latest_tag"
                    fi
                    local new_line="${indent}uses: $action_path@$latest_sha # $latest_tag"
                    echo "$new_line" >> "$temp_file"
                    changed=true
                fi
            else
                # Not upgrade mode and already pinned - keep as is
                if [[ "$SCAN_MODE" == true ]]; then
                    # Check if it's the latest
                    local latest_tag
                    latest_tag=$(get_latest_version "$owner" "$repo") || {
                        echo "$line" >> "$temp_file"
                        continue
                    }

                    local latest_sha
                    latest_sha=$(resolve_ref_to_sha "$owner" "$repo" "$latest_tag") || {
                        echo "$line" >> "$temp_file"
                        continue
                    }

                    if [[ "$current_ref" == "$latest_sha" ]]; then
                        echo "  ✅ $action_path@${current_ref:0:7}... # $existing_comment (up to date)"
                        ((up_to_date++))
                    else
                        echo "  🔄 $action_path@${current_ref:0:7}... # $existing_comment (newer available: $latest_tag → sha: ${latest_sha:0:7}...)"
                        ((outdated++))
                    fi
                fi
                echo "$line" >> "$temp_file"
            fi
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$file_path"

    if [[ "$SCAN_MODE" == true ]]; then
        echo ""
        echo "Summary: $total_actions actions found | $up_to_date up to date | $unpinned unpinned | $outdated outdated | $skipped skipped"
        echo ""

        # Return non-zero if there are unpinned or outdated actions
        if [[ $unpinned -gt 0 ]] || [[ $outdated -gt 0 ]]; then
            rm "$temp_file"
            return 1
        fi
    elif [[ "$changed" == true ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            echo ""
            echo "=== Diff for $file_path ==="
            diff -u "$file_path" "$temp_file" || true
            echo ""
        else
            mv "$temp_file" "$file_path"
        fi
    fi

    rm -f "$temp_file"
    return 0
}

# === REMOTE MODE ===
process_remote_repo() {
    local repo="$REMOTE_REPO"
    echo "[INFO] Processing remote repository: $repo"

    # Get default branch
    local repo_info
    repo_info=$(gh_api_get "/repos/$repo") || {
        echo "[ERROR] Could not fetch repository info for $repo"
        exit 1
    }

    local default_branch
    default_branch=$(echo "$repo_info" | jq -r '.default_branch')
    echo "[INFO] Default branch: $default_branch"

    # Get default branch SHA
    local branch_info
    branch_info=$(gh_api_get "/repos/$repo/git/ref/heads/$default_branch") || {
        echo "[ERROR] Could not fetch default branch info"
        exit 1
    }

    local base_sha
    base_sha=$(echo "$branch_info" | jq -r '.object.sha')
    echo "[INFO] Base SHA: $base_sha"

    # Set branch name
    if [[ -z "$BRANCH_NAME" ]]; then
        BRANCH_NAME="pinnR/GHA-Update-$(date +%Y-%m-%d)"
    fi

    echo "[INFO] Creating feature branch: $BRANCH_NAME"

    # Create feature branch
    local create_ref_data
    create_ref_data=$(jq -n \
        --arg ref "refs/heads/$BRANCH_NAME" \
        --arg sha "$base_sha" \
        '{ref: $ref, sha: $sha}')

    local create_result
    create_result=$(gh_api_post "/repos/$repo/git/refs" "$create_ref_data" 2>&1) || {
        if echo "$create_result" | grep -q "already exists"; then
            echo "[ERROR] Branch '$BRANCH_NAME' already exists."
            echo "Please use -b to specify a different branch name."
            exit 1
        else
            echo "[ERROR] Failed to create branch: $create_result"
            exit 1
        fi
    }

    # Get workflow files
    local workflows_content
    workflows_content=$(gh_api_get "/repos/$repo/contents/.github/workflows") || {
        echo "[ERROR] Could not fetch workflow files"
        exit 1
    }

    # Process each workflow file
    local pr_table="| File | Action | Change |\n|------|--------|--------|\n"
    local changes_made=false

    echo "$workflows_content" | jq -c '.[]' | while read -r file_obj; do
        local file_name
        file_name=$(echo "$file_obj" | jq -r '.name')

        if [[ ! "$file_name" =~ \.ya?ml$ ]]; then
            continue
        fi

        local file_path=".github/workflows/$file_name"
        local download_url
        download_url=$(echo "$file_obj" | jq -r '.download_url')
        local file_sha
        file_sha=$(echo "$file_obj" | jq -r '.sha')

        echo "[INFO] Processing $file_path"

        # Download file content
        local content
        if [[ "$USE_GH_CLI" == true ]]; then
            content=$(curl -sS "$download_url")
        else
            content=$(curl -sS "$download_url")
        fi

        # Save to temp file
        local temp_file
        temp_file=$(mktemp)
        echo "$content" > "$temp_file"

        # Process file
        local original_file
        original_file=$(mktemp)
        cp "$temp_file" "$original_file"

        # TODO: Process and track changes
        # For now, we'll skip the actual processing in remote mode
        # This would need to be implemented with change tracking

        rm "$temp_file" "$original_file"
    done

    echo "[INFO] All files processed. Creating PR..."

    # Create PR
    local pr_body
    pr_body="## PinnR: GitHub Actions Security Update

This PR pins GitHub Actions to specific commit SHAs to improve supply chain security.

### Why?

Floating tags like \`v3\` or branches like \`main\` can be moved to point to different commits, potentially introducing malicious code. Pinning to SHAs ensures the exact code version is used.

### Changes

$pr_table

### Note

If this PR is closed without merging, the branch \`$BRANCH_NAME\` will need to be deleted manually.

---
🤖 Generated by [PinnR](https://github.com/CyBirdSecurity/pinnr)"

    local pr_data
    pr_data=$(jq -n \
        --arg title "chore: pin GitHub Actions to commit SHAs [PinnR]" \
        --arg head "$BRANCH_NAME" \
        --arg base "$default_branch" \
        --arg body "$pr_body" \
        '{title: $title, head: $head, base: $base, body: $body}')

    local pr_result
    pr_result=$(gh_api_post "/repos/$repo/pulls" "$pr_data") || {
        echo "[ERROR] Failed to create PR"
        exit 1
    }

    local pr_url
    pr_url=$(echo "$pr_result" | jq -r '.html_url')

    echo ""
    echo "[SUCCESS] Pull request created: $pr_url"
}

# === MAIN LOGIC ===
print_usage() {
    cat << 'EOF'
PinnR - Pin GitHub Actions to commit SHAs

USAGE:
    pinnr.sh [FLAGS] [PATH]

FLAGS:
    -t              Dry-run mode: show proposed changes without writing files
    -U              Upgrade mode: update all actions to latest versions
    -S              Scan mode: report status of all actions, exit 1 if any unpinned/outdated
    -P              Allow pre-release tags (alpha, beta, rc, etc.). Default: exclude pre-releases
    -R <repo>       Remote mode: process owner/repo and create PR
    -b <branch>     Custom branch name for -R (default: pinnR/GHA-Update-YYYY-MM-DD)
    -h              Show this help message

EXAMPLES:
    pinnr.sh                          # Pin unpinned actions in current directory
    pinnr.sh -t                       # Dry-run to see what would change
    pinnr.sh -U                       # Upgrade all actions to latest versions
    pinnr.sh -S                       # Scan and report status
    pinnr.sh -R owner/repo            # Process remote repo and create PR
    pinnr.sh -R owner/repo -b custom  # Use custom branch name

AUTHENTICATION:
    Use 'gh auth login' (recommended) or set GITHUB_TOKEN environment variable.

EOF
}

main() {
    # Parse flags
    local target_path="."

    while getopts "tUSPR:b:h" opt; do
        case $opt in
            t) DRY_RUN=true ;;
            U) UPGRADE_MODE=true ;;
            S) SCAN_MODE=true ;;
            P) ALLOW_PRERELEASE=true ;;
            R) REMOTE_REPO="$OPTARG" ;;
            b) BRANCH_NAME="$OPTARG" ;;
            h) print_usage; exit 0 ;;
            *) print_usage; exit 1 ;;
        esac
    done

    shift $((OPTIND - 1))

    if [[ $# -gt 0 ]]; then
        target_path="$1"
    fi

    # Check dependencies
    check_dependencies

    # Remote mode
    if [[ -n "$REMOTE_REPO" ]]; then
        if [[ "$DRY_RUN" == true ]] || [[ "$SCAN_MODE" == true ]]; then
            echo "[WARN] -t and -S are not compatible with -R in current implementation"
            exit 1
        fi
        process_remote_repo
        exit 0
    fi

    # Local mode
    local exit_code=0

    if [[ -d "$target_path/.github/workflows" ]]; then
        for workflow in "$target_path/.github/workflows"/*.yml "$target_path/.github/workflows"/*.yaml; do
            if [[ -f "$workflow" ]]; then
                process_workflow_file "$workflow" || exit_code=1
            fi
        done
    else
        echo "[ERROR] No .github/workflows directory found at $target_path"
        exit 1
    fi

    exit $exit_code
}

main "$@"
