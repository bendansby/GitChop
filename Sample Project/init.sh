#!/usr/bin/env bash
# Generate a fresh sample git repo for poking at GitChop.
#
# Creates an 8-commit history with deliberate rebase candidates:
#   - a "Fix typo" commit you'd want to fixup into the README commit
#   - a "WIP" commit you'd want to drop
#   - a couple of small, related polishing commits to squash together
#
# Usage:
#   bash init.sh                              # repo at ~/Desktop/GitChop\ Sample
#   bash init.sh /path/to/somewhere/else      # repo at <path>
#
# Re-runnable: deletes and recreates the destination so you always get a
# clean state to practice on.

set -euo pipefail

DEST="${1:-$HOME/Desktop/GitChop Sample}"
echo "==> Creating sample repo at: $DEST"

if [[ -e "$DEST" ]]; then
    echo "==> Removing existing $DEST"
    rm -rf "$DEST"
fi
mkdir -p "$DEST"
cd "$DEST"

# Pin commit timestamps so the demo is deterministic. (Author + committer
# date are both set per commit so re-running produces an identical SHA
# graph as long as content matches.)
git init -q -b main
git config user.name  "GitChop Demo"
git config user.email "demo@gitchop.local"
git config commit.gpgsign false

commit() {
    local subject="$1" body="${2:-}" date="$3"
    GIT_AUTHOR_DATE="$date"  GIT_COMMITTER_DATE="$date" \
        git commit -q -m "$subject" ${body:+-m "$body"}
}

# 1. Initial: README
cat > README.md <<'EOF'
# Greet

A toy CLI that prints a friendly greting.

## Usage

    greet [name]

If no name is given, greets the world.
EOF
git add README.md
commit "Initial commit: README" "" "2026-04-20T09:00:00"

# 2. Add the actual hello script
cat > hello.txt <<'EOF'
#!/usr/bin/env bash
NAME="${1:-world}"
echo "hello, $NAME"
EOF
git add hello.txt
commit "Add greet script" "Reads optional name argument; defaults to 'world'." "2026-04-20T10:30:00"

# 3. Add config
cat > config.txt <<'EOF'
# greet config
default_name=world
shout=false
EOF
git add config.txt
commit "Add config file" "" "2026-04-20T13:15:00"

# 4. Add a tests file (placeholder)
cat > tests.txt <<'EOF'
# Tests for greet
- greet with no args prints "hello, world"
- greet "alice" prints "hello, alice"
EOF
git add tests.txt
commit "Add tests outline" "" "2026-04-21T09:45:00"

# 5. Fix typo in README — classic FIXUP candidate (would amend commit 1).
sed -i '' 's/greting/greeting/' README.md
git add README.md
commit "Fix typo: greting -> greeting" "" "2026-04-21T11:00:00"

# 6. Polishing the hello script — small change.
cat > hello.txt <<'EOF'
#!/usr/bin/env bash
NAME="${1:-world}"
echo "Hello, $NAME!"
EOF
git add hello.txt
commit "Capitalize greeting and add exclamation" "" "2026-04-22T09:00:00"

# 7. WIP — DROP candidate.
cat > experiment.txt <<'EOF'
TODO: try a fancier prompt format here.
This is just a scratchpad, not for shipping.
EOF
git add experiment.txt
commit "WIP: experimenting with prompt format" "" "2026-04-22T15:30:00"

# 8. Honest polish on hello — could SQUASH with #6.
cat > hello.txt <<'EOF'
#!/usr/bin/env bash
NAME="${1:-world}"
if [[ "${SHOUT:-false}" == "true" ]]; then
  NAME="$(echo "$NAME" | tr '[:lower:]' '[:upper:]')"
fi
echo "Hello, $NAME!"
EOF
git add hello.txt
commit "Honor SHOUT env var to uppercase the name" "" "2026-04-23T10:15:00"

echo
echo "Done. ${DEST}"
echo "8 commits on main. Try GitChop > Open Repo… and point it here."
echo
git log --oneline
