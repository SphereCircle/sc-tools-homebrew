#!/usr/bin/env bash
set -euo pipefail

#############################################
# CONFIGURATION
#############################################

GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Modes
RESUME_MODE=false
UPDATE_MODE=false
FETCH_MODE=false
DRY_RUN=false
JSON_OUTPUT=false
VERBOSE=false
DEBUG=false
CHECK_PERMISSIONS=false
DIAGNOSE=false

# Filters
INCLUDE_PRIVATE=true
INCLUDE_PUBLIC=true
EXCLUDE_ARCHIVED=true
EXCLUDE_FORKS=true
NAME_PATTERN=""

# Parallelism
MAX_JOBS=6

# Layout
LAYOUT="nested"        # nested | flat-prefix | flat
ROOT_DIR=""

# Logging
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

declare -A REPO_ACTIONS

#############################################
# LOGGING HELPERS
#############################################
log() {
    echo -e "${CYAN}[$(date +%F_%T)]${RESET} $1" | tee -a "$LOG_FILE"
}

err() {
    echo -e "${RED}[$(date +%F_%T)] ERROR:${RESET} $1" | tee -a "$ERROR_LOG"
    ((FAILED++))
}

vlog() {
    [[ "$VERBOSE" == true ]] && echo -e "${YELLOW}[VERBOSE]${RESET} $1"
}

dlog() {
    [[ "$DEBUG" == true ]] && echo -e "${BLUE}[DEBUG]${RESET} $1"
}

#############################################
# TOKEN DIAGNOSTICS
#############################################
diagnose_token() {
    echo -e "${CYAN}Running GitHub token diagnostics...${RESET}"

    echo -e "\n${BLUE}1. Checking /user...${RESET}"
    user_resp=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$API/user")
    if echo "$user_resp" | jq -e '.login' >/dev/null 2>&1; then
        echo -e "${GREEN}✔ Token can access /user (${RESET}$(echo "$user_resp" | jq -r '.login')${GREEN})${RESET}"
    else
        echo -e "${RED}✘ Token cannot access /user${RESET}"
        echo "$user_resp"
    fi

    echo -e "\n${BLUE}2. Checking /user/orgs...${RESET}"
    orgs_resp=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$API/user/orgs")
    if echo "$orgs_resp" | jq -e '.[0].login' >/dev/null 2>&1; then
        echo -e "${GREEN}✔ Token can list organizations:${RESET}"
        echo "$orgs_resp" | jq -r '.[].login'
    else
        echo -e "${RED}✘ Token cannot list organizations${RESET}"
        echo "$orgs_resp"
    fi

    if [[ -n "${1:-}" ]]; then
        echo -e "\n${BLUE}3. Checking repo access for org: $1...${RESET}"
        repos_resp=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$API/orgs/$1/repos")
        if echo "$repos_resp" | jq -e '.[0].clone_url' >/dev/null 2>&1; then
            echo -e "${GREEN}✔ Token can list repos in $1${RESET}"
            echo "$repos_resp" | jq -r '.[].name'
        else
            echo -e "${RED}✘ Token cannot list repos in $1${RESET}"
            echo "$repos_resp"
        fi
    fi

    echo -e "\n${CYAN}Diagnostics complete.${RESET}"
    exit 0
}

#############################################
# HELP
#############################################
show_help() {
    cat <<EOF
Usage: github-sync [options]

Required:
  --token TOKEN           GitHub token (or set GITHUB_TOKEN env var)

Repository selection:
  --orgs LIST             Comma-separated list of orgs (e.g. "microsoft,github")
                          If omitted, all orgs + your user repos are included.

Modes:
  --resume                Skip repos that already exist locally
  --update                Pull updates for existing repos
  --fetch                 Fetch/prune existing repos
  --dry-run               Show actions without executing

Filtering:
  --filter REGEX          Only include repos whose names match REGEX
  --include-private       Include private repos (default: on)
  --exclude-private       Exclude private repos
  --include-public        Include public repos (default: on)
  --exclude-public        Exclude public repos
  --include-archived      Include archived repos
  --exclude-archived      Exclude archived repos (default: on)
  --include-forks         Include forks
  --exclude-forks         Exclude forks (default: on)

Layout:
  --layout LAYOUT         nested (default), flat-prefix, flat
  --root-dir DIR          Root directory for all synced repos

Parallelism:
  --parallel N            Number of parallel jobs (default: 6)

Output:
  --json                  Output JSON summary
  --verbose               Verbose logging
  --debug                 Debug logging (implies verbose)

Diagnostics:
  --check-permissions     Quick token permission check
  --diagnose              Full token diagnostics

Other:
  --help                  Show this help message
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
        --resume) RESUME_MODE=true ;;
        --update) UPDATE_MODE=true ;;
        --fetch) FETCH_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        --filter) NAME_PATTERN="$2"; shift ;;
        --include-private) INCLUDE_PRIVATE=true ;;
        --exclude-private) INCLUDE_PRIVATE=false ;;
        --include-public) INCLUDE_PUBLIC=true ;;
        --exclude-public) INCLUDE_PUBLIC=false ;;
        --include-archived) EXCLUDE_ARCHIVED=false ;;
        --exclude-archived) EXCLUDE_ARCHIVED=true ;;
        --include-forks) EXCLUDE_FORKS=false ;;
        --exclude-forks) EXCLUDE_FORKS=true ;;
        --layout) LAYOUT="$2"; shift ;;
        --root-dir) ROOT_DIR="$2"; shift ;;
        --parallel) MAX_JOBS="$2"; shift ;;
        --json) JSON_OUTPUT=true ;;
        --verbose) VERBOSE=true ;;
        --debug) DEBUG=true; VERBOSE=true ;;
        --check-permissions) CHECK_PERMISSIONS=true ;;
        --diagnose) DIAGNOSE=true ;;
        --help) show_help ;;
        *)
            echo -e "${RED}Unknown option:${RESET} $1"
            exit 1
            ;;
    esac
    shift
done

#############################################
# TOKEN VALIDATION
#############################################
if [[ -z "$GITHUB_TOKEN" ]]; then
    echo -e "${RED}Error:${RESET} Missing GitHub token. Use --token or set GITHUB_TOKEN."
    exit 1
fi

if [[ "$CHECK_PERMISSIONS" == true ]]; then
    diagnose_token "${ORGS_RAW:-}"
fi

if [[ "$DIAGNOSE" == true ]]; then
    diagnose_token "${ORGS_RAW:-}"
fi

#############################################
# ROOT DIRECTORY HANDLING
#############################################
if [[ -n "$ROOT_DIR" ]]; then
    mkdir -p "$ROOT_DIR"
    cd "$ROOT_DIR"
fi

#############################################
# JOB CONTROL
#############################################
wait_for_slot() {
    while [[ $(jobs -r | wc -l) -ge $MAX_JOBS ]]; do
        sleep 0.2
    done
}

#############################################
# PAGINATION (fetch all pages from GitHub API)
#############################################
fetch_all_pages() {
    local url="$1"
    local page=1

    while true; do
        dlog "Fetching page $page → $url?page=$page&per_page=100"

        local response
        response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
            "$url?page=$page&per_page=100")

        # If GitHub returns a string instead of JSON → token issue
        if ! echo "$response" | jq . >/dev/null 2>&1; then
            err "GitHub returned non‑JSON response for $url"
            echo "$response" >> "$ERROR_LOG"
            break
        fi

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
# REPO FILTERING
#############################################
repo_passes_filters() {
    local json="$1"

    local is_private is_archived is_fork name
    is_private=$(echo "$json" | jq -r '.private')
    is_archived=$(echo "$json" | jq -r '.archived')
    is_fork=$(echo "$json" | jq -r '.fork')
    name=$(echo "$json" | jq -r '.name')

    # Private/public filters
    if [[ "$is_private" == "true" && "$INCLUDE_PRIVATE" != true ]]; then return 1; fi
    if [[ "$is_private" == "false" && "$INCLUDE_PUBLIC" != true ]]; then return 1; fi

    # Archived filter
    if [[ "$is_archived" == "true" && "$EXCLUDE_ARCHIVED" == true ]]; then return 1; fi

    # Fork filter
    if [[ "$is_fork" == "true" && "$EXCLUDE_FORKS" == true ]]; then return 1; fi

    # Name regex filter
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
# ORG LIST PARSING
#############################################
parse_orgs_from_flag() {
    local raw="$1"
    IFS=',' read -r -a arr <<< "$raw"
    ORGS=()
    for o in "${arr[@]}"; do
        o="${o#"${o%%[![:space:]]*}"}"   # trim leading spaces
        o="${o%"${o##*[![:space:]]}"}"   # trim trailing spaces
        [[ -n "$o" ]] && ORGS+=("$o")
    done
}

#############################################
# CONFIRMATION PROMPT (when no --orgs provided)
#############################################
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
# REPO DESTINATION PATH (layout handling)
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
# CLONE REPO
#############################################
clone_repo() {
    local org="$1"
    local repo="$2"
    local url="$3"
    local dest="$4"

    dlog "Cloning $org/$repo from $url → $dest"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${GREEN}[DRY-RUN] Would clone:${RESET} $org/$repo → $dest"
        REPO_ACTIONS["$org/$repo"]="clone"
        return
    fi

    mkdir -p "$(dirname "$dest")"

    if ! git clone "$url" "$dest" 2>>"$ERROR_LOG"; then
        err "Failed to clone $url"
        echo -e "${RED}✘ Clone failed for $org/$repo${RESET}"
        echo -e "${YELLOW}Check logs/errors.log for details.${RESET}"
        REPO_ACTIONS["$org/$repo"]="clone_failed"
        return
    fi

    ((CLONED++))
    REPO_ACTIONS["$org/$repo"]="cloned"
}

#############################################
# UPDATE REPO (git pull)
#############################################
update_repo() {
    local org="$1"
    local repo="$2"
    local dest="$3"

    dlog "Updating $org/$repo at $dest"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN] Would pull:${RESET} $org/$repo"
        REPO_ACTIONS["$org/$repo"]="update"
        return
    fi

    if ! git -C "$dest" pull --ff-only 2>>"$ERROR_LOG"; then
        err "Failed to update $dest"
        echo -e "${RED}✘ Update failed for $org/$repo${RESET}"
        REPO_ACTIONS["$org/$repo"]="update_failed"
        return
    fi

    ((UPDATED++))
    REPO_ACTIONS["$org/$repo"]="updated"
}

#############################################
# FETCH REPO (git fetch --all --prune)
#############################################
fetch_repo() {
    local org="$1"
    local repo="$2"
    local dest="$3"

    dlog "Fetching $org/$repo at $dest"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BLUE}[DRY-RUN] Would fetch:${RESET} $org/$repo"
        REPO_ACTIONS["$org/$repo"]="fetch"
        return
    fi

    if ! git -C "$dest" fetch --all --prune 2>>"$ERROR_LOG"; then
        err "Failed to fetch $dest"
        echo -e "${RED}✘ Fetch failed for $org/$repo${RESET}"
        REPO_ACTIONS["$org/$repo"]="fetch_failed"
        return
    fi

    ((FETCHED++))
    REPO_ACTIONS["$org/$repo"]="fetched"
}

#############################################
# MAIN SYNC PROCESS
#############################################
log "Starting GitHub sync"

ORGS=()

#############################################
# DETERMINE ORGANIZATIONS
#############################################
if [[ -n "$ORGS_RAW" ]]; then
    # User explicitly provided orgs
    parse_orgs_from_flag "$ORGS_RAW"
else
    # Auto-discover orgs + user repos
    dlog "Fetching organizations via /user/orgs"
    mapfile -t api_orgs < <(fetch_all_pages "$API/user/orgs" | jq -r '.[].login')

    dlog "Fetching user login via /user"
    user_login=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$API/user" | jq -r '.login')

    ORGS=("${api_orgs[@]}" "$user_login")

    confirm_all_orgs "${ORGS[@]}"
fi

#############################################
# DISPLAY ORGANIZATIONS
#############################################
log "Organizations to sync:"
for o in "${ORGS[@]}"; do
    echo "  - $o" | tee -a "$LOG_FILE"
done
echo

#############################################
# FETCH ALL REPOS FROM ALL ORGS
#############################################
repos_json="[]"

for org in "${ORGS[@]}"; do
    dlog "Fetching repos for org: $org"

    # Org repos
    org_repos=$(fetch_all_pages "$API/orgs/$org/repos" || echo "[]")

    # User repos (if org == username)
    user_repos=$(fetch_all_pages "$API/users/$org/repos" || echo "[]")

    # Merge
    merged=$(jq -s 'add' <(echo "$org_repos") <(echo "$user_repos"))
    repos_json=$(jq -s 'add' <(echo "$repos_json") <(echo "$merged"))
done

#############################################
# COUNT TOTAL REPOS
#############################################
TOTAL_REPOS=$(echo "$repos_json" | jq 'length')
log "Total repos discovered: $TOTAL_REPOS"
echo

#############################################
# PROCESS EACH REPO
#############################################
echo "$repos_json" | jq -c '.[]' | while read -r repo_json; do
    ((PROCESSED_REPOS++))
    progress_bar "$PROCESSED_REPOS" "$TOTAL_REPOS"

    # Apply filters
    if ! repo_passes_filters "$repo_json"; then
        continue
    fi

    org_name=$(echo "$repo_json" | jq -r '.owner.login')
    repo_name=$(echo "$repo_json" | jq -r '.name')
    clone_url=$(echo "$repo_json" | jq -r '.clone_url')

    dest=$(repo_dest_path "$org_name" "$repo_name")

    #############################################
    # REPO EXISTS LOCALLY
    #############################################
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

    #############################################
    # REPO DOES NOT EXIST → CLONE
    #############################################
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
# JSON SUMMARY OUTPUT
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
            repositories: $repos
        }'
fi

echo -e "${GREEN}GitHub sync complete.${RESET}"
exit 0
