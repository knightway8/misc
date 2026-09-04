#!/usr/bin/env bash
#
# download_aileda_repos.sh
# Downloads all public repositories from https://github.com/aileda
# as separate ZIP files (one per repo).
#
# Requirements:
#   - curl
#   - jq  OR  python3 (for JSON parsing)
#
# Usage:
#   chmod +x download_aileda_repos.sh
#   ./download_aileda_repos.sh
#
# Optional: set GITHUB_TOKEN environment variable for higher rate limits
#   export GITHUB_TOKEN=ghp_your_token_here
#   ./download_aileda_repos.sh
#

set -euo pipefail

USER="aileda"
OUTPUT_DIR="${USER}_repos_zips"
PER_PAGE=100

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Downloading all public repos from github.com/${USER} ===${NC}"
echo

# Create output directory
mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

# Auth header if token is provided
AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: token ${GITHUB_TOKEN}")
  echo -e "${YELLOW}Using GITHUB_TOKEN for higher rate limits${NC}"
fi

# Function to parse JSON with jq or python3
parse_repos() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r '.[] | "\(.name)\t\(.default_branch)"'
  elif command -v python3 >/dev/null 2>&1; then
    echo "$json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, dict) and 'message' in data:
        print('ERROR: ' + data['message'], file=sys.stderr)
        sys.exit(1)
    for r in data:
        print(r['name'] + chr(9) + r['default_branch'])
except Exception as e:
    print('Parse error: ' + str(e), file=sys.stderr)
    sys.exit(1)
"
  else
    echo -e "${RED}Error: Neither 'jq' nor 'python3' found. Please install one of them.${NC}" >&2
    exit 1
  fi
}

page=1
total_downloaded=0
total_failed=0

while true; do
  echo -e "${YELLOW}Fetching page ${page}...${NC}"
  
  response=$(curl -s -w "\n%{http_code}" \
    "${AUTH_HEADER[@]}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/users/${USER}/repos?per_page=${PER_PAGE}&page=${page}")

  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "403" ]]; then
    echo -e "${RED}API rate limit exceeded (HTTP 403).${NC}"
    echo "Tip: Create a personal access token at https://github.com/settings/tokens"
    echo "     and run:  export GITHUB_TOKEN=your_token_here"
    echo "     then re-run this script."
    exit 1
  fi

  if [[ "$http_code" != "200" ]]; then
    echo -e "${RED}Failed to fetch repos (HTTP ${http_code})${NC}"
    echo "$body" | head -c 300
    exit 1
  fi

  # Check if empty array
  if echo "$body" | grep -q '^\s*\[\s*\]\s*$'; then
    break
  fi

  # Parse and download
  while IFS=$'\t' read -r name branch; do
    if [[ -z "$name" ]]; then
      continue
    fi

    zip_name="${name}.zip"
    download_url="https://github.com/${USER}/${name}/archive/refs/heads/${branch}.zip"

    if [[ -f "$zip_name" ]]; then
      echo -e "  ${YELLOW}Skipping${NC} $name (already exists)"
      continue
    fi

    echo -n "  Downloading ${name} (${branch}) ... "

    if curl -sL -f -o "$zip_name" "$download_url"; then
      size=$(du -h "$zip_name" | cut -f1)
      echo -e "${GREEN}OK${NC} (${size})"
      ((total_downloaded++)) || true
    else
      echo -e "${RED}FAILED${NC}"
      rm -f "$zip_name"
      ((total_failed++)) || true
    fi
  done < <(parse_repos "$body")

  # If we got fewer than per_page, we're done
  if command -v jq >/dev/null 2>&1; then
    count=$(echo "$body" | jq 'length')
  else
    count=$(echo "$body" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')
  fi
  if [[ "$count" -lt "$PER_PAGE" ]]; then
    break
  fi

  ((page++))
done

echo
echo -e "${GREEN}=== Done ===${NC}"
echo "Downloaded : $total_downloaded"
echo "Failed     : $total_failed"
echo "Location   : $(pwd)"
echo
echo "Each ZIP contains a folder named: <repo>-<branch>/"
