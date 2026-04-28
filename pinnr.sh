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
AUDIT_MODE=false
UNPINNED_ONLY_MODE=false

# Audit statistics (using individual variables for bash 3.x compatibility)
AUDIT_TOTAL_REPOS=0
AUDIT_REPOS_SCANNED=0
AUDIT_REPOS_WITH_WORKFLOWS=0
AUDIT_REPOS_WITHOUT_WORKFLOWS=0
AUDIT_REPOS_WITH_UNPINNED=0
AUDIT_TOTAL_ACTIONS=0
AUDIT_TOTAL_PINNED=0
AUDIT_TOTAL_UNPINNED=0
AUDIT_TOTAL_LOCAL=0

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

gh_api_delete() {
    local endpoint="$1"
    local response

    if [[ "$USE_GH_CLI" == true ]]; then
        response=$(gh api -X DELETE "$endpoint" 2>&1) || {
            echo "[ERROR] API DELETE failed: $endpoint" >&2
            echo "$response" >&2
            return 1
        }
    else
        response=$(curl -sSf -X DELETE \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com$endpoint" 2>&1) || {
            echo "[ERROR] API DELETE failed: $endpoint" >&2
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
        tag_obj=$(gh_api_get "/repos/$owner/$repo/git/tags/$tag_sha") || {
            echo "[WARN] Could not dereference annotated tag for $owner/$repo" >&2
            return 1
        }
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

# === ORGANIZATION AUDIT FUNCTIONS ===

# Paginate GitHub API calls to handle >100 items
paginate_api_call() {
    local endpoint="$1"
    local page=1
    local all_results="[]"

    while true; do
        local response
        response=$(gh_api_get "${endpoint}?page=${page}&per_page=100" 2>&1) || {
            echo "[ERROR] Failed to fetch page $page from $endpoint" >&2
            return 1
        }

        local count
        count=$(echo "$response" | jq 'length')

        if [[ $count -eq 0 ]]; then
            break
        fi

        all_results=$(echo "$all_results" "$response" | jq -s 'add')
        ((page++))
    done

    echo "$all_results"
}

# Fetch all non-archived repos from organization
fetch_org_repos() {
    local org="$1"

    echo "[INFO] Fetching repositories from organization: $org" >&2

    local repos
    repos=$(paginate_api_call "/orgs/$org/repos" 2>&1) || {
        echo "[ERROR] Failed to fetch repositories for organization: $org" >&2
        echo "[ERROR] Please verify the organization name and your access permissions" >&2
        return 1
    }

    # Filter out archived repos
    local active_repos
    active_repos=$(echo "$repos" | jq -c '[.[] | select(.archived == false)]')

    echo "$active_repos"
}

# Initialize CSV file with headers
init_csv_file() {
    local csv_file="$1"

    echo "Repository,Workflow File,Action,Current Ref,Is Pinned" > "$csv_file"
}

# Append a row to the CSV file
append_csv_row() {
    local csv_file="$1"
    local repo="$2"
    local workflow="$3"
    local action="$4"
    local ref="$5"
    local is_pinned="$6"  # "yes" or "no"

    # Escape double quotes for CSV
    repo="${repo//\"/\"\"}"
    workflow="${workflow//\"/\"\"}"
    action="${action//\"/\"\"}"
    ref="${ref//\"/\"\"}"

    # Truncate SHAs for readability (but keep original for CSV data)
    local display_ref="$ref"
    if [[ ${#ref} -eq 40 ]] && is_pinned "$ref"; then
        display_ref="${ref:0:12}..."
    fi

    echo "\"$repo\",\"$workflow\",\"$action\",\"$display_ref\",\"$is_pinned\"" >> "$csv_file"
}

# Extract actions from a workflow file and write to CSV
extract_actions_from_workflow() {
    local csv_file="$1"
    local repo_name="$2"
    local workflow_name="$3"
    local workflow_content="$4"

    # Create temp file for workflow content
    local temp_workflow
    temp_workflow=$(mktemp)
    echo "$workflow_content" > "$temp_workflow"

    while IFS= read -r line; do
        if echo "$line" | grep -qE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+'; then
            local uses_part
            uses_part=$(echo "$line" | sed 's/^[[:space:]]*\(-[[:space:]]*\)\{0,1\}uses:[[:space:]]*//; s/[[:space:]]*$//')

            # Skip local actions
            if echo "$uses_part" | grep -qE '^\.\/'; then
                ((AUDIT_TOTAL_LOCAL++)) || true
                continue
            fi

            # Parse owner/repo@ref
            local action_with_ref
            action_with_ref=$(echo "$uses_part" | awk '{print $1}')

            if [[ ! "$action_with_ref" =~ @ ]]; then
                continue
            fi

            local action_path="${action_with_ref%@*}"
            local current_ref="${action_with_ref#*@}"

            # Validate action format (owner/repo)
            if [[ ! "$action_path" == */* ]]; then
                continue
            fi

            ((AUDIT_TOTAL_ACTIONS++)) || true

            # Check if pinned
            local pinned_status="no"
            if is_pinned "$current_ref"; then
                pinned_status="yes"
                ((AUDIT_TOTAL_PINNED++)) || true
            else
                ((AUDIT_TOTAL_UNPINNED++)) || true
            fi

            # Conditionally write to CSV based on mode
            if [[ "$UNPINNED_ONLY_MODE" == true ]] && [[ "$pinned_status" == "yes" ]]; then
                continue  # Skip pinned actions in unpinned-only mode
            fi

            append_csv_row "$csv_file" "$repo_name" "$workflow_name" "$action_path" "$current_ref" "$pinned_status"
        fi
    done < "$temp_workflow"

    rm -f "$temp_workflow"
}

# Audit a single repository
audit_single_repo() {
    local csv_file="$1"
    local repo_name="$2"

    [[ "${PINNR_DEBUG:-}" == "1" ]] && echo "[DEBUG] Processing repo: $repo_name" >&2

    # Fetch workflow files
    local workflows_content
    workflows_content=$(gh_api_get "/repos/$repo_name/contents/.github/workflows" 2>&1) || {
        local api_error=$?
        [[ "${PINNR_DEBUG:-}" == "1" ]] && echo "[DEBUG] API call failed for $repo_name with exit code $api_error" >&2

        # 404 means no workflows directory - skip silently
        if echo "$workflows_content" | grep -qi "404\|not found"; then
            ((AUDIT_REPOS_WITHOUT_WORKFLOWS++)) || true
            return 0
        fi

        # Other errors - skip silently
        ((AUDIT_REPOS_WITHOUT_WORKFLOWS++)) || true
        return 0
    }

    [[ "${PINNR_DEBUG:-}" == "1" ]] && echo "[DEBUG] Successfully fetched workflows for $repo_name" >&2

    # Check if directory is empty or if response is not valid JSON
    local file_count
    file_count=$(echo "$workflows_content" | jq 'length' 2>/dev/null) || {
        [[ "${PINNR_DEBUG:-}" == "1" ]] && echo "[DEBUG] Invalid JSON response for $repo_name" >&2
        ((AUDIT_REPOS_WITHOUT_WORKFLOWS++)) || true
        return 0
    }

    if [[ $file_count -eq 0 ]]; then
        ((AUDIT_REPOS_WITHOUT_WORKFLOWS++)) || true
        return 0
    fi

    ((AUDIT_REPOS_WITH_WORKFLOWS++)) || true

    local has_unpinned=false

    # Process each workflow file
    while IFS= read -r file_obj; do
        local file_name
        file_name=$(echo "$file_obj" | jq -r '.name')

        # Only process YAML files
        if [[ ! "$file_name" =~ \.ya?ml$ ]]; then
            continue
        fi

        local download_url
        download_url=$(echo "$file_obj" | jq -r '.download_url')

        # Download workflow content (uses download URL, no auth required, doesn't count against rate limit)
        local content
        content=$(curl -sS --max-time 10 "$download_url" 2>&1) || {
            echo "[WARN] Failed to download workflow $file_name from $repo_name" >&2
            continue
        }

        # Track unpinned actions count before processing
        local unpinned_before=$AUDIT_TOTAL_UNPINNED

        # Extract and record actions
        extract_actions_from_workflow "$csv_file" "$repo_name" ".github/workflows/$file_name" "$content"

        # Check if unpinned actions were found
        if [[ $AUDIT_TOTAL_UNPINNED -gt $unpinned_before ]]; then
            has_unpinned=true
        fi
    done < <(echo "$workflows_content" | jq -c '.[]')

    if [[ "$has_unpinned" == true ]]; then
        ((AUDIT_REPOS_WITH_UNPINNED++)) || true
    fi

    # Process composite action files
    local actions_dirs_content
    actions_dirs_content=$(gh_api_get "/repos/$repo_name/contents/.github/actions" 2>&1) || {
        # No actions directory, skip silently
        return 0
    }

    # Process each action directory
    while IFS= read -r dir_obj; do
        local dir_name
        dir_name=$(echo "$dir_obj" | jq -r '.name')
        local dir_type
        dir_type=$(echo "$dir_obj" | jq -r '.type')

        # Skip if not a directory
        if [[ "$dir_type" != "dir" ]]; then
            continue
        fi

        # Get contents of action directory
        local action_dir_content
        action_dir_content=$(gh_api_get "/repos/$repo_name/contents/.github/actions/$dir_name" 2>&1) || {
            continue
        }

        # Look for action.yml or action.yaml
        while IFS= read -r action_file_obj; do
            local action_file_name
            action_file_name=$(echo "$action_file_obj" | jq -r '.name')

            # Only process action.yml or action.yaml
            if [[ "$action_file_name" != "action.yml" ]] && [[ "$action_file_name" != "action.yaml" ]]; then
                continue
            fi

            local download_url
            download_url=$(echo "$action_file_obj" | jq -r '.download_url')

            # Download action content (uses download URL, no auth required, doesn't count against rate limit)
            local content
            content=$(curl -sS --max-time 10 "$download_url" 2>&1) || {
                echo "[WARN] Failed to download action $action_file_name from $repo_name/.github/actions/$dir_name" >&2
                continue
            }

            # Track unpinned actions count before processing
            local unpinned_before=$AUDIT_TOTAL_UNPINNED

            # Extract and record actions
            extract_actions_from_workflow "$csv_file" "$repo_name" ".github/actions/$dir_name/$action_file_name" "$content"

            # Check if unpinned actions were found
            if [[ $AUDIT_TOTAL_UNPINNED -gt $unpinned_before ]]; then
                has_unpinned=true
            fi
        done < <(echo "$action_dir_content" | jq -c '.[]')
    done < <(echo "$actions_dirs_content" | jq -c '.[]')
}

# Show progress indicator
show_progress() {
    local current="$1"
    local total="$2"
    local repo_name="$3"

    local percent=$((current * 100 / total))

    # Check if stderr is a terminal (interactive)
    if [[ -t 2 ]]; then
        # Interactive terminal - use progress bar with carriage return
        local filled=$((percent / 5))

        # Build progress bar
        local bar=""
        for ((i=1; i<=filled; i++)); do
            bar+="█"
        done
        for ((i=filled+1; i<=20; i++)); do
            bar+="░"
        done

        # Truncate repo name if too long
        if [[ ${#repo_name} -gt 40 ]]; then
            repo_name="${repo_name:0:37}..."
        fi

        printf "\r[%s] %3d%% (%d/%d) %s" "$bar" "$percent" "$current" "$total" "$repo_name" >&2

        # Print newline when complete
        [[ $current -eq $total ]] && echo "" >&2
    else
        # Non-interactive (redirected/piped) - show periodic updates
        # Show at: start, every 50 repos, and end
        if [[ $current -eq 1 ]] || [[ $current -eq $total ]] || [[ $((current % 50)) -eq 0 ]]; then
            echo "[INFO] Progress: $percent% ($current/$total repos scanned)" >&2
        fi
    fi
}

# Print audit summary to terminal
print_audit_summary() {
    local org="$1"
    local csv_file="$2"

    echo "" >&2
    echo "=== PinnR Audit Summary ===" >&2
    echo "" >&2
    echo "Organization: $org" >&2
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')" >&2
    echo "" >&2
    echo "Repositories:" >&2
    echo "  Total scanned:              $AUDIT_REPOS_SCANNED" >&2
    echo "  With workflows:             $AUDIT_REPOS_WITH_WORKFLOWS" >&2
    echo "  Without workflows:          $AUDIT_REPOS_WITHOUT_WORKFLOWS" >&2
    echo "  With unpinned actions:      $AUDIT_REPOS_WITH_UNPINNED" >&2
    echo "" >&2
    echo "Actions:" >&2
    echo "  Total found:                $AUDIT_TOTAL_ACTIONS" >&2

    if [[ $AUDIT_TOTAL_ACTIONS -gt 0 ]]; then
        local pinned_percent=$((AUDIT_TOTAL_PINNED * 100 / AUDIT_TOTAL_ACTIONS))
        local unpinned_percent=$((AUDIT_TOTAL_UNPINNED * 100 / AUDIT_TOTAL_ACTIONS))
        echo "  Pinned to SHA:              $AUDIT_TOTAL_PINNED (${pinned_percent}%)" >&2
        echo "  Unpinned (tags/branches):   $AUDIT_TOTAL_UNPINNED (${unpinned_percent}%)" >&2
    fi

    echo "  Local (skipped):            $AUDIT_TOTAL_LOCAL" >&2
    echo "" >&2
    echo "Report saved to: $csv_file" >&2
    echo "" >&2
    echo "[SUCCESS] Audit complete" >&2
}

# Main audit orchestrator
audit_organization() {
    local org="$1"

    echo "[INFO] Starting audit of organization: $org" >&2
    echo "[INFO] Fetching repositories... (excluding archived)" >&2

    # Fetch all repos
    local repos
    repos=$(fetch_org_repos "$org") || {
        exit 1
    }

    # Count repos
    local repo_count
    repo_count=$(echo "$repos" | jq 'length')

    if [[ $repo_count -eq 0 ]]; then
        echo "[WARN] No repositories found in organization: $org" >&2
        echo "[WARN] This could mean the organization is empty or you don't have access" >&2
        exit 0
    fi

    echo "[INFO] Found $repo_count repositories to scan" >&2
    echo "" >&2

    # Generate CSV filename
    local csv_filename="pinnr-audit-${org}-$(date '+%Y-%m-%d').csv"

    # Initialize CSV file
    init_csv_file "$csv_filename"

    # Process each repository
    local current=0
    local repos_array
    repos_array=$(echo "$repos" | jq -r '.[].full_name')

    while IFS= read -r repo_full_name; do
        [[ -z "$repo_full_name" ]] && continue

        ((current++)) || true
        ((AUDIT_REPOS_SCANNED++)) || true

        show_progress "$current" "$repo_count" "$repo_full_name" || true

        audit_single_repo "$csv_filename" "$repo_full_name" || true
    done <<< "$repos_array"

    # Print summary
    print_audit_summary "$org" "$csv_filename"
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
        if echo "$line" | grep -qE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+'; then
            local indent
            indent=$(echo "$line" | sed 's/^\([[:space:]]*\)\(-[[:space:]]*\)\{0,1\}uses:.*/\1\2/')

            local uses_part
            uses_part=$(echo "$line" | sed 's/^[[:space:]]*\(-[[:space:]]*\)\{0,1\}uses:[[:space:]]*//; s/[[:space:]]*$//')

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

            # If already pinned and not upgrading, skip or scan
            if [[ "$is_currently_pinned" == true ]] && [[ "$UPGRADE_MODE" == false ]]; then
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
            elif [[ "$UPGRADE_MODE" == true ]]; then
                # Upgrade mode - always get latest version
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
                    # Already on latest SHA
                    if [[ "$SCAN_MODE" == true ]]; then
                        echo "  ✅ $action_path@${current_ref:0:7}... # $existing_comment (up to date)"
                        ((up_to_date++))
                    else
                        echo "[SKIP] $action_path already on latest SHA ($latest_sha)"
                    fi
                    echo "$line" >> "$temp_file"
                else
                    # Upgrade to latest
                    if [[ "$SCAN_MODE" == true ]]; then
                        echo "  🔄 $action_path@${current_ref:0:7}... # $existing_comment (upgrading to: $latest_tag → sha: ${latest_sha:0:7}...)"
                        ((outdated++))
                    else
                        echo "[UPDATE] $action_path@$current_ref → $latest_sha # $latest_tag"
                    fi
                    local new_line="${indent}uses: $action_path@$latest_sha # $latest_tag"
                    echo "$new_line" >> "$temp_file"
                    changed=true
                fi
            else
                # Default mode - pin to current ref's SHA
                local target_sha
                target_sha=$(resolve_ref_to_sha "$owner" "$repo" "$current_ref") || {
                    echo "$line" >> "$temp_file"
                    continue
                }

                if [[ "$SCAN_MODE" == true ]]; then
                    echo "  ⚠️  $action_path@$current_ref (unpinned — will pin to: $current_ref → sha: ${target_sha:0:7}...)"
                    ((unpinned++))
                else
                    echo "[PIN] $action_path@$current_ref → $target_sha # $current_ref"
                fi
                local new_line="${indent}uses: $action_path@$target_sha # $current_ref"
                echo "$new_line" >> "$temp_file"
                changed=true
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
    workflows_content=$(gh_api_get "/repos/$repo/contents/.github/workflows" 2>&1) || {
        if ! echo "$workflows_content" | grep -qi "404\|not found"; then
            echo "[ERROR] Could not fetch workflow files"
            exit 1
        fi
        workflows_content="[]"
    }

    # Get action files
    local actions_dirs_content
    actions_dirs_content=$(gh_api_get "/repos/$repo/contents/.github/actions" 2>&1) || {
        actions_dirs_content="[]"
    }

    # Process each workflow file
    local pr_table_file
    pr_table_file=$(mktemp)
    echo "| File | Action | Change |" > "$pr_table_file"
    echo "|------|--------|--------|" >> "$pr_table_file"

    local changes_made=false
    local files_changed=0

    # Process workflow files
    while IFS= read -r file_obj; do
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
        content=$(curl -sS "$download_url")

        # Save to temp file
        local temp_file
        temp_file=$(mktemp)
        echo "$content" > "$temp_file"

        # Process file to pin actions
        local processed_file
        processed_file=$(mktemp)
        local file_changed=false

        while IFS= read -r line; do
            if echo "$line" | grep -qE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+'; then
                local indent
                indent=$(echo "$line" | sed 's/^\([[:space:]]*\)\(-[[:space:]]*\)\{0,1\}uses:.*/\1\2/')

                local uses_part
                uses_part=$(echo "$line" | sed 's/^[[:space:]]*\(-[[:space:]]*\)\{0,1\}uses:[[:space:]]*//; s/[[:space:]]*$//')

                # Skip local actions
                if echo "$uses_part" | grep -qE '^\.\/'; then
                    echo "$line" >> "$processed_file"
                    continue
                fi

                # Parse owner/repo@ref
                local action_with_ref
                action_with_ref=$(echo "$uses_part" | awk '{print $1}')

                if [[ ! "$action_with_ref" =~ @ ]]; then
                    echo "$line" >> "$processed_file"
                    continue
                fi

                local action_path="${action_with_ref%@*}"
                local current_ref="${action_with_ref#*@}"

                # Extract owner and repo
                local owner
                local repo_name
                if [[ "$action_path" == */* ]]; then
                    owner=$(echo "$action_path" | cut -d'/' -f1)
                    repo_name=$(echo "$action_path" | cut -d'/' -f2)
                else
                    echo "$line" >> "$processed_file"
                    continue
                fi

                # Check if already pinned
                if is_pinned "$current_ref"; then
                    if [[ "$UPGRADE_MODE" == false ]]; then
                        echo "$line" >> "$processed_file"
                        continue
                    fi
                fi

                # Determine target version and SHA
                local target_tag
                local target_sha

                if [[ "$UPGRADE_MODE" == true ]]; then
                    # Upgrade mode - get latest version
                    target_tag=$(get_latest_version "$owner" "$repo_name" 2>/dev/null) || {
                        echo "$line" >> "$processed_file"
                        continue
                    }

                    target_sha=$(resolve_ref_to_sha "$owner" "$repo_name" "$target_tag" 2>/dev/null) || {
                        echo "$line" >> "$processed_file"
                        continue
                    }
                else
                    # Default mode - pin to current ref
                    target_tag="$current_ref"
                    target_sha=$(resolve_ref_to_sha "$owner" "$repo_name" "$current_ref" 2>/dev/null) || {
                        echo "$line" >> "$processed_file"
                        continue
                    }
                fi

                # Only change if different
                if [[ "$current_ref" != "$target_sha" ]]; then
                    local new_line="${indent}uses: $action_path@$target_sha # $target_tag"
                    echo "$new_line" >> "$processed_file"
                    echo "| \`$file_name\` | \`$action_path\` | \`$current_ref\` → \`$target_sha\` (\`$target_tag\`) |" >> "$pr_table_file"
                    file_changed=true
                    echo "  [PIN] $action_path@$current_ref → $target_sha # $target_tag"
                else
                    echo "$line" >> "$processed_file"
                fi
            else
                echo "$line" >> "$processed_file"
            fi
        done < "$temp_file"

        # If file changed, commit it to the remote branch
        if [[ "$file_changed" == true ]]; then
            echo "[INFO] Committing changes to $file_path"

            # Base64 encode the new content (remove line breaks for GitHub API)
            local new_content
            if command -v base64 &>/dev/null; then
                # macOS base64 adds line breaks, remove them
                new_content=$(base64 < "$processed_file" | tr -d '\n')
            else
                echo "[ERROR] base64 command not found"
                exit 1
            fi

            # Update file on remote branch
            local update_data
            update_data=$(jq -n \
                --arg message "Pin actions in $file_name" \
                --arg content "$new_content" \
                --arg sha "$file_sha" \
                --arg branch "$BRANCH_NAME" \
                '{message: $message, content: $content, sha: $sha, branch: $branch}')

            gh_api_put "/repos/$repo/contents/$file_path" "$update_data" > /dev/null || {
                echo "[ERROR] Failed to update $file_path"
                rm "$temp_file" "$processed_file" "$pr_table_file"
                exit 1
            }

            changes_made=true
            ((files_changed++))
        fi

        rm "$temp_file" "$processed_file"
    done < <(echo "$workflows_content" | jq -c '.[]')

    # Process composite action files
    while IFS= read -r dir_obj; do
        local dir_name
        dir_name=$(echo "$dir_obj" | jq -r '.name')
        local dir_type
        dir_type=$(echo "$dir_obj" | jq -r '.type')

        # Skip if not a directory
        if [[ "$dir_type" != "dir" ]]; then
            continue
        fi

        # Get contents of action directory
        local action_dir_content
        action_dir_content=$(gh_api_get "/repos/$repo/contents/.github/actions/$dir_name" 2>&1) || {
            continue
        }

        # Look for action.yml or action.yaml
        while IFS= read -r action_file_obj; do
            local action_file_name
            action_file_name=$(echo "$action_file_obj" | jq -r '.name')

            # Only process action.yml or action.yaml
            if [[ "$action_file_name" != "action.yml" ]] && [[ "$action_file_name" != "action.yaml" ]]; then
                continue
            fi

            local file_path=".github/actions/$dir_name/$action_file_name"
            local download_url
            download_url=$(echo "$action_file_obj" | jq -r '.download_url')
            local file_sha
            file_sha=$(echo "$action_file_obj" | jq -r '.sha')

            echo "[INFO] Processing $file_path"

            # Download file content
            local content
            content=$(curl -sS "$download_url")

            # Save to temp file
            local temp_file
            temp_file=$(mktemp)
            echo "$content" > "$temp_file"

            # Process file to pin actions
            local processed_file
            processed_file=$(mktemp)
            local file_changed=false

            while IFS= read -r line; do
                if echo "$line" | grep -qE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+'; then
                    local indent
                    indent=$(echo "$line" | sed 's/^\([[:space:]]*\)\(-[[:space:]]*\)\{0,1\}uses:.*/\1\2/')

                    local uses_part
                    uses_part=$(echo "$line" | sed 's/^[[:space:]]*\(-[[:space:]]*\)\{0,1\}uses:[[:space:]]*//; s/[[:space:]]*$//')

                    # Skip local actions
                    if echo "$uses_part" | grep -qE '^\.\/'; then
                        echo "$line" >> "$processed_file"
                        continue
                    fi

                    # Parse owner/repo@ref
                    local action_with_ref
                    action_with_ref=$(echo "$uses_part" | awk '{print $1}')

                    if [[ ! "$action_with_ref" =~ @ ]]; then
                        echo "$line" >> "$processed_file"
                        continue
                    fi

                    local action_path="${action_with_ref%@*}"
                    local current_ref="${action_with_ref#*@}"

                    # Extract owner and repo
                    local owner
                    local repo_name
                    if [[ "$action_path" == */* ]]; then
                        owner=$(echo "$action_path" | cut -d'/' -f1)
                        repo_name=$(echo "$action_path" | cut -d'/' -f2)
                    else
                        echo "$line" >> "$processed_file"
                        continue
                    fi

                    # Check if already pinned
                    if is_pinned "$current_ref"; then
                        if [[ "$UPGRADE_MODE" == false ]]; then
                            echo "$line" >> "$processed_file"
                            continue
                        fi
                    fi

                    # Determine target version and SHA
                    local target_tag
                    local target_sha

                    if [[ "$UPGRADE_MODE" == true ]]; then
                        # Upgrade mode - get latest version
                        target_tag=$(get_latest_version "$owner" "$repo_name" 2>/dev/null) || {
                            echo "$line" >> "$processed_file"
                            continue
                        }

                        target_sha=$(resolve_ref_to_sha "$owner" "$repo_name" "$target_tag" 2>/dev/null) || {
                            echo "$line" >> "$processed_file"
                            continue
                        }
                    else
                        # Default mode - pin to current ref
                        target_tag="$current_ref"
                        target_sha=$(resolve_ref_to_sha "$owner" "$repo_name" "$current_ref" 2>/dev/null) || {
                            echo "$line" >> "$processed_file"
                            continue
                        }
                    fi

                    # Only change if different
                    if [[ "$current_ref" != "$target_sha" ]]; then
                        local new_line="${indent}uses: $action_path@$target_sha # $target_tag"
                        echo "$new_line" >> "$processed_file"
                        echo "| \`$file_path\` | \`$action_path\` | \`$current_ref\` → \`$target_sha\` (\`$target_tag\`) |" >> "$pr_table_file"
                        file_changed=true
                        echo "  [PIN] $action_path@$current_ref → $target_sha # $target_tag"
                    else
                        echo "$line" >> "$processed_file"
                    fi
                else
                    echo "$line" >> "$processed_file"
                fi
            done < "$temp_file"

            # If file changed, commit it to the remote branch
            if [[ "$file_changed" == true ]]; then
                echo "[INFO] Committing changes to $file_path"

                # Base64 encode the new content (remove line breaks for GitHub API)
                local new_content
                if command -v base64 &>/dev/null; then
                    # macOS base64 adds line breaks, remove them
                    new_content=$(base64 < "$processed_file" | tr -d '\n')
                else
                    echo "[ERROR] base64 command not found"
                    exit 1
                fi

                # Update file on remote branch
                local update_data
                update_data=$(jq -n \
                    --arg message "Pin actions in $action_file_name" \
                    --arg content "$new_content" \
                    --arg sha "$file_sha" \
                    --arg branch "$BRANCH_NAME" \
                    '{message: $message, content: $content, sha: $sha, branch: $branch}')

                gh_api_put "/repos/$repo/contents/$file_path" "$update_data" > /dev/null || {
                    echo "[ERROR] Failed to update $file_path"
                    rm "$temp_file" "$processed_file" "$pr_table_file"
                    exit 1
                }

                changes_made=true
                ((files_changed++))
            fi

            rm "$temp_file" "$processed_file"
        done < <(echo "$action_dir_content" | jq -c '.[]')
    done < <(echo "$actions_dirs_content" | jq -c '.[]')

    if [[ "$changes_made" == false ]]; then
        echo "[INFO] No changes needed - all actions are already pinned"
        # Delete the branch we created
        gh_api_delete "/repos/$repo/git/refs/heads/$BRANCH_NAME" 2>/dev/null || true
        rm "$pr_table_file"
        exit 0
    fi

    echo "[INFO] $files_changed file(s) updated"

    echo "[INFO] All files processed. Creating PR..."

    # Read the changes table
    local pr_table
    pr_table=$(cat "$pr_table_file")

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

    # Clean up temp file
    rm "$pr_table_file"

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
    -A <org>        Audit organization: scan all repos for unpinned actions, generate CSV
    -O              Unpinned-only mode: CSV includes only unpinned actions (use with -A)
    -h              Show this help message

EXAMPLES:
    pinnr.sh                          # Pin unpinned actions in current directory
    pinnr.sh -t                       # Dry-run to see what would change
    pinnr.sh -U                       # Upgrade all actions to latest versions
    pinnr.sh -S                       # Scan and report status
    pinnr.sh -R owner/repo            # Process remote repo and create PR
    pinnr.sh -R owner/repo -b custom  # Use custom branch name
    pinnr.sh -A myorg                 # Audit all repos in organization (full report)
    pinnr.sh -A myorg -O              # Audit organization (unpinned actions only)

SCOPE:
    PinnR processes both .github/workflows and .github/actions directories.
    It pins external actions in workflow files and composite action files.

AUTHENTICATION:
    Use 'gh auth login' (recommended) or set GITHUB_TOKEN environment variable.

EOF
}

main() {
    # Parse flags
    local target_path="."
    local audit_org=""
    local unpinned_only=false

    while getopts "tUSPR:b:A:Oh" opt; do
        case $opt in
            t) DRY_RUN=true ;;
            U) UPGRADE_MODE=true ;;
            S) SCAN_MODE=true ;;
            P) ALLOW_PRERELEASE=true ;;
            R) REMOTE_REPO="$OPTARG" ;;
            b) BRANCH_NAME="$OPTARG" ;;
            A) audit_org="$OPTARG" ;;
            O) unpinned_only=true ;;
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

    # Audit mode
    if [[ -n "$audit_org" ]]; then
        # Validate incompatible flags
        if [[ -n "$REMOTE_REPO" ]]; then
            echo "[ERROR] -A and -R cannot be used together"
            exit 1
        fi

        if [[ "$UPGRADE_MODE" == true ]]; then
            echo "[ERROR] -A and -U cannot be used together (audit is read-only)"
            exit 1
        fi

        # Set global mode flags
        AUDIT_MODE=true
        UNPINNED_ONLY_MODE=$unpinned_only

        # Run audit
        audit_organization "$audit_org"
        exit $?
    fi

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
    local has_workflows=false
    local has_actions=false

    # Process workflows
    if [[ -d "$target_path/.github/workflows" ]]; then
        has_workflows=true
        for workflow in "$target_path/.github/workflows"/*.yml "$target_path/.github/workflows"/*.yaml; do
            if [[ -f "$workflow" ]]; then
                process_workflow_file "$workflow" || exit_code=1
            fi
        done
    fi

    # Process composite actions
    if [[ -d "$target_path/.github/actions" ]]; then
        has_actions=true
        for action_dir in "$target_path/.github/actions"/*; do
            if [[ -d "$action_dir" ]]; then
                for action_file in "$action_dir/action.yml" "$action_dir/action.yaml"; do
                    if [[ -f "$action_file" ]]; then
                        process_workflow_file "$action_file" || exit_code=1
                    fi
                done
            fi
        done
    fi

    if [[ "$has_workflows" == false ]] && [[ "$has_actions" == false ]]; then
        echo "[ERROR] No .github/workflows or .github/actions directory found at $target_path"
        exit 1
    fi

    exit $exit_code
}

main "$@"
