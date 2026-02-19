#!/usr/bin/env bash
set -euo pipefail

#############################################
# DEFAULT CONFIGURATION
#############################################

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
RESUME_MODE=false
UPDATE_MODE=false
FETCH_MODE=false
DRY_RUN=false
JSON_OUTPUT=false

INCLUDE_PRIVATE=true
INCLUDE_PUBLIC=true
EXCLUDE_ARCHIVED=true
EXCLUDE_FORKS=true
NAME_PATTERN=""

MAX_JOBS=6

LAYOUT="nested"        # nested | flat-prefix | flat
ROOT_DIR=""

LOG_DIR="./logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/github_sync_$(date +%F_%H-%M-%S).log"
ERROR_LOG="$LOG_DIR/errors.log"

API="https://api.github.com"

#############################################
# COLORS
#############################################
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
RESET="\033[0m"

#############################################
# METRICS
#############################################
CLONED=0
UPDATED=0
FETCHED=0
SKIPPED=0
FAILED=0
TOTAL_REPOS=0
PROCESSED_REPOS=0
START_TIME=$(date +%s)

declare -A REPO_ACTIONS   # key: org/repo, value: action

#############################################
# HELP
#############################################
show_help() {
    cat <<EOF
Usage: github-sync.sh [options]

Options:
  --token TOKEN       GitHub token (or set GITHUB_TOKEN env var)
  --orgs LIST         Comma-separated org list (e.g. "microsoft,github,my-org")
  --layout LAYOUT     Directory layout: nested (default), flat-prefix, flat
  --root-dir DIR      Root directory for all synced repos
  --resume            Skip repos that already exist
  --update            Pull updates for existing repos
  --fetch             Fetch/prune existing repos
  --dry-run           Show actions without executing
  --parallel N        Number of parallel jobs
  --filter REGEX      Only process repos matching regex
  --json              Output JSON summary
  --help              Show this help

Examples:
  ./github-sync.sh --token abc123 --orgs microsoft,github --resume --update
  ./github-sync.sh --fetch --parallel 10 --layout flat-prefix
  ./github-sync.sh --json --root-dir github-sync
EOF
    exit 0
}

#############################################
# ARGUMENT PARSING
#############################################
if [[ $# -eq 0 ]]; then
    show_help
fi

ORGS_RAW=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token) GITHUB_TOKEN="$2"; shift ;;
        --orgs) ORGS_RAW="$2"; shift ;;
        --layout) LAYOUT="$2"; shift ;;
        --root-dir) ROOT_DIR="$2"; shift ;;
        --resume) RESUME_MODE=true ;;
        --update) UPDATE_MODE=true ;;
        --fetch) FETCH_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        --parallel) MAX_JOBS="$2"; shift ;;
        --filter) NAME_PATTERN="$2"; shift ;;
        --json) JSON_OUTPUT=true ;;
        --help) show_help ;;
        *) echo -e "${RED}Unknown option:${RESET} $1"; exit 1 ;;
    esac
    shift
done

if [[ -z "$GITHUB_TOKEN" ]]; then
    echo -e "${RED}Error:${RESET} Missing GitHub token. Use --token or set GITHUB_TOKEN."
    exit 1
fi

if [[ -n "$ROOT_DIR" ]]; then
    mkdir -p "$ROOT_DIR"
    cd "$ROOT_DIR"
fi

#############################################
# LOGGING
#############################################
log() {
    echo -e "${CYAN}[$(date +%F_%T)]${RESET} $1" | tee -a "$LOG_FILE"
}

err() {
    echo -e "${RED}[$(date +%F_%T)] ERROR:${RESET} $1" | tee -a "$ERROR_LOG"
    ((FAILED++))
}

#############################################
# PAGINATION
#############################################
fetch_all_pages() {
    local url="$1"
    local page=1

    while true; do
        local response
        response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
            "$url?page=$page&per_page=100")

        local count
        count=$(echo "$response" | jq 'length')

        if [[ "$count" -eq 0 ]]; then
            break
        fi

        echo "$response"
        ((page++))
    done
}

#############################################
# FILTERS
#############################################
repo_passes_filters() {
    local json="$1"

    local is_private is_archived is_fork name
    is_private=$(echo "$json" | jq -r '.private')
    is_archived=$(echo "$json" | jq -r '.archived')
    is_fork=$(echo "$json" | jq -r '.fork')
    name=$(echo "$json" | jq -r '.name')

    if [[ "$is_private" == "true" && "$INCLUDE_PRIVATE" != true ]]; then return 1; fi
    if [[ "$is_private" == "false" && "$INCLUDE_PUBLIC" != true ]]; then return 1; fi
    if [[ "$is_archived" == "true" && "$EXCLUDE_ARCHIVED" == true ]]; then return 1; fi
    if [[ "$is_fork" == "true" && "$EXCLUDE_FORKS" == true ]]; then return 1; fi

    if [[ -n "$NAME_PATTERN" ]]; then
        if ! [[ "$name" =~ $NAME_PATTERN ]]; then return 1; fi
    fi

    return 0
}

#############################################
# PROGRESS BAR
#############################################
progress_bar() {
    local current=$1
    local total=$2
    local width=40

    (( total == 0 )) && total=1

    local percent=$((100 * current / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))

    printf "\r["
    printf "%0.s#" $(seq 1 $filled)
    printf "%0.s-" $(seq 1 $empty)
    printf "] %3d%% (%d/%d)" "$percent" "$current" "$total"
}

#############################################
# JOB CONTROL
#############################################
wait_for_slot() {
    while [[ $(jobs -r | wc -l) -ge $MAX_JOBS ]]; do
        sleep 0.2
    done
}

#############################################
# LAYOUT
#############################################
repo_dest_path() {
    local org="$1"
    local repo="$2"

    case "$LAYOUT" in
        nested)
            echo "$org/$repo"
            ;;
        flat-prefix)
            echo "${org}-${repo}"
            ;;
        flat)
            echo "$repo"
            ;;
        *)
            echo "$org/$repo"
            ;;
    esac
}

#############################################
# ACTIONS
#############################################
clone_repo() {
    local org="$1"
    local repo="$2"
    local url="$3"
    local dest="$4"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${GREEN}[DRY-RUN] Would clone:${RESET} $org/$repo → $dest"
        REPO_ACTIONS["$org/$repo"]="clone"
        return
    fi

    mkdir -p "$(dirname "$dest")"
    git clone --quiet "$url" "$dest" 2>>"$ERROR_LOG"
    if [[ $? -eq 0 ]]; then
        ((CLONED++))
        REPO_ACTIONS["$org/$repo"]="cloned"
    else
        err "Failed to clone $url"
    fi
}

update_repo() {
    local org="$1"
    local repo="$2"
    local dest="$3"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN] Would pull:${RESET} $org/$repo"
        REPO_ACTIONS["$org/$repo"]="update"
        return
    fi

    git -C "$dest" pull --quiet 2>>"$ERROR_LOG"
    if [[ $? -eq 0 ]]; then
        ((UPDATED++))
        REPO_ACTIONS["$org/$repo"]="updated"
    else
        err "Failed to update $dest"
    fi
}

fetch_repo() {
    local org="$1"
    local repo="$2"
    local dest="$3"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BLUE}[DRY-RUN] Would fetch:${RESET} $org/$repo"
        REPO_ACTIONS["$org/$repo"]="fetch"
        return
    fi

    git -C "$dest" fetch --all --prune --quiet 2>>"$ERROR_LOG"
    if [[ $? -eq 0 ]]; then
        ((FETCHED++))
        REPO_ACTIONS["$org/$repo"]="fetched"
    else
        err "Failed to fetch $dest"
    fi
}

#############################################
# ORG SELECTION
#############################################
parse_orgs_from_flag() {
    local raw="$1"
    IFS=',' read -r -a arr <<< "$raw"
    ORGS=()
    for o in "${arr[@]}"; do
        o="${o#"${o%%[![:space:]]*}"}"
        o="${o%"${o##*[![:space:]]}"}"
        [[ -n "$o" ]] && ORGS+=("$o")
    done
}

confirm_all_orgs() {
    local orgs_list=("$@")

    echo "You did not specify --orgs."
    echo "The following organizations will be synced:"
    for o in "${orgs_list[@]}"; do
        echo "  - $o"
    done
    echo
    read -r -p "Do you want to continue? (y/N): " answer

    shopt -s nocasematch
    case "$answer" in
        y|yes|ok|okay|sure|go|continue|"do it"|yep|affirmative|proceed)
            ;;
        *)
            echo "Aborted by user."
            exit 1
            ;;
    esac
    shopt -u nocasematch
}

#############################################
# MAIN
#############################################
log "Starting GitHub sync"

ORGS=()

if [[ -n "$ORGS_RAW" ]]; then
    parse_orgs_from_flag "$ORGS_RAW"
else
    # auto-discover orgs + personal account
    mapfile -t api_orgs < <(fetch_all_pages "$API/user/orgs" | jq -r '.[].login')
    user_login=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$API/user" | jq -r '.login')

    ORGS=("${api_orgs[@]}" "$user_login")
    confirm_all_orgs "${ORGS[@]}"
fi

log "Organizations to sync:"
for o in "${ORGS[@]}"; do
    echo "  - $o" | tee -a "$LOG_FILE"
done

# Collect all repos first to know TOTAL_REPOS
repos_json="[]"
for org in "${ORGS[@]}"; do
    org_repos=$(fetch_all_pages "$API/orgs/$org/repos" || echo "[]")
    user_repos=$(fetch_all_pages "$API/users/$org/repos" || echo "[]")

    merged=$(jq -s 'add' <(echo "$org_repos") <(echo "$user_repos"))
    repos_json=$(jq -s 'add' <(echo "$repos_json") <(echo "$merged"))
done

TOTAL_REPOS=$(echo "$repos_json" | jq 'length')

echo
log "Total repos discovered: $TOTAL_REPOS"
echo

echo "$repos_json" | jq -c '.[]' | while read -r repo_json; do
    ((PROCESSED_REPOS++))
    progress_bar "$PROCESSED_REPOS" "$TOTAL_REPOS"

    if ! repo_passes_filters "$repo_json"; then
        continue
    fi

    org_name=$(echo "$repo_json" | jq -r '.owner.login')
    repo_name=$(echo "$repo_json" | jq -r '.name')
    clone_url=$(echo "$repo_json" | jq -r '.clone_url')

    dest=$(repo_dest_path "$org_name" "$repo_name")

    if [[ -d "$dest/.git" ]]; then
        ((SKIPPED++))
        if [[ "$UPDATE_MODE" == true ]]; then
            wait_for_slot
            update_repo "$org_name" "$repo_name" "$dest" &
        elif [[ "$FETCH_MODE" == true ]]; then
            wait_for_slot
            fetch_repo "$org_name" "$repo_name" "$dest" &
        else
            REPO_ACTIONS["$org_name/$repo_name"]="${REPO_ACTIONS["$org_name/$repo_name"]:-skipped}"
        fi
        continue
    fi

    wait_for_slot
    clone_repo "$org_name" "$repo_name" "$clone_url" "$dest" &
done

wait
echo

#############################################
# SUMMARY
#############################################
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo -e "${GREEN}Cloned:   $CLONED${RESET}"
echo -e "${YELLOW}Updated:  $UPDATED${RESET}"
echo -e "${BLUE}Fetched:  $FETCHED${RESET}"
echo -e "${CYAN}Skipped:  $SKIPPED${RESET}"
echo -e "${RED}Failed:   $FAILED${RESET}"
echo -e "${CYAN}Duration: ${DURATION}s${RESET}"

#############################################
# JSON SUMMARY
#############################################
if [[ "$JSON_OUTPUT" == true ]]; then
    repos_array=$(printf '%s\n' "${!REPO_ACTIONS[@]}" | while read -r key; do
        action="${REPO_ACTIONS["$key"]}"
        org="${key%%/*}"
        repo="${key#*/}"
        jq -n --arg org "$org" --arg name "$repo" --arg action "$action" \
            '{org: $org, name: $name, action: $action}'
    done | jq -s '.')

    jq -n \
        --argjson cloned "$CLONED" \
        --argjson updated "$UPDATED" \
        --argjson fetched "$FETCHED" \
        --argjson skipped "$SKIPPED" \
        --argjson failed "$FAILED" \
        --argjson duration "$DURATION" \
        --argjson repos "$repos_array" \
        '{
            stats: {
                cloned: $cloned,
                updated: $updated,
                fetched: $fetched,
                skipped: $skipped,
                failed: $failed,
                duration_seconds: $duration
            },
            repos: $repos
        }'
fi
