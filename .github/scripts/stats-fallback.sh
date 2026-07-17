#!/usr/bin/env bash
# Rebuild profile/stats.svg when the stats action returns an error card.
#
# GitHub's GraphQL resource limits (Sept 2025, tightened through 2026) reject
# the combined stats query for active accounts, but each sub-query still fits.
# Fetch the numbers with small REST/GraphQL calls and patch them into the last
# good SVG from git. Rank and "Contributed to" are carried over from the
# template (both change slowly and have no cheap API equivalent).
set -euo pipefail

SVG="profile/stats.svg"
USER="${1:?usage: stats-fallback.sh <username>}"
TEMPLATE="$(mktemp)"

if ! grep -q "Something went wrong" "$SVG"; then
  echo "stats card is healthy; no fallback needed"
  exit 0
fi

echo "stats card is an error card; rebuilding from split queries"
git show "HEAD:$SVG" > "$TEMPLATE"
if grep -q "Something went wrong" "$TEMPLATE"; then
  echo "template in HEAD is also an error card; cannot fall back" >&2
  exit 1
fi

api() {
  for _ in 1 2 3; do
    if gh api "$@"; then return 0; fi
    echo "gh api $1 failed; retrying" >&2
    sleep 5
  done
  return 1
}

STARS=$(api --paginate "users/$USER/repos?per_page=100" --jq '.[].stargazers_count' | awk '{s+=$1} END{print s+0}')
COMMITS=$(api graphql -f query="query{user(login:\"$USER\"){contributionsCollection{totalCommitContributions}}}" --jq .data.user.contributionsCollection.totalCommitContributions)
PRS=$(api "search/issues?q=author:$USER+type:pr" --jq .total_count)
ISSUES=$(api "search/issues?q=author:$USER+type:issue" --jq .total_count)

STARS="$STARS" COMMITS="$COMMITS" PRS="$PRS" ISSUES="$ISSUES" \
TEMPLATE="$TEMPLATE" SVG="$SVG" python3 - <<'EOF'
import os, re

def kfmt(n):
    n = int(n)
    return str(n) if abs(n) < 1000 else f"{n / 1000:.1f}k"

svg = open(os.environ["TEMPLATE"]).read()
for tid, env in [("stars", "STARS"), ("commits", "COMMITS"),
                 ("prs", "PRS"), ("issues", "ISSUES")]:
    svg, count = re.subn(
        rf'(<text[^>]*data-testid="{tid}"[^>]*>)[^<]*(</text>)',
        rf"\g<1>{kfmt(os.environ[env])}\g<2>", svg)
    assert count == 1, f"expected exactly one {tid} node, found {count}"
open(os.environ["SVG"], "w").write(svg)
EOF

echo "rebuilt $SVG: stars=$STARS commits=$COMMITS prs=$PRS issues=$ISSUES"
