#!/usr/bin/env bash
# Generate a realistic sample git repo for poking at GitChop.
#
# The repo is a small CLI project called `tabby` (a CSV/Markdown/JSON
# table formatter). It has three authors, two merged feature branches,
# a merged hotfix branch, and a "local WIP" tail of 12 commits that
# is what GitChop loads by default — full of deliberate rebase
# candidates: typos to fixup, related work to squash, a WIP to drop,
# a CI fix that landed in the wrong order, etc.
#
# Re-runnable: deletes the destination first so each run starts clean.
#
# Usage:
#   bash init.sh                              # repo at ~/Desktop/GitChop\ Sample
#   bash init.sh /path/to/somewhere/else      # custom location

set -euo pipefail

DEST="${1:-$HOME/Desktop/GitChop Sample}"
echo "==> Creating sample repo at: $DEST"

if [[ -e "$DEST" ]]; then
    echo "==> Removing existing $DEST"
    rm -rf "$DEST"
fi
mkdir -p "$DEST"
cd "$DEST"

git init -q -b main
git config commit.gpgsign false
git config init.defaultBranch main

# ── helpers ───────────────────────────────────────────────────────────

# Switch the active author identity. We bake author + committer to the
# same person per commit, since that's what real-world history looks
# like (committer == author in the common case).
set_author() {
    export GIT_AUTHOR_NAME="$1"  GIT_AUTHOR_EMAIL="$2"
    export GIT_COMMITTER_NAME="$1" GIT_COMMITTER_EMAIL="$2"
}

# Commit currently-staged changes at a fixed timestamp. Pinning dates
# keeps the demo deterministic — re-running produces the same SHAs as
# long as content matches.
commit_at() {
    local date="$1" subject="$2" body="${3:-}"
    if [[ -n "$body" ]]; then
        GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
            git commit -q -m "$subject" -m "$body"
    else
        GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
            git commit -q -m "$subject"
    fi
}

# Merge a branch back with --no-ff so the merge commit is preserved
# (matches how teams that protect main usually configure it).
merge_at() {
    local date="$1" branch="$2" subject="$3"
    GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
        git merge --no-ff --no-edit -q -m "$subject" "$branch"
}

# ── authors ───────────────────────────────────────────────────────────
ALEX="Alex Chen|alex@tabby.dev"
SAM="Sam Patel|sam@tabby.dev"
JORDAN="Jordan Lee|jordan@tabby.dev"

as() {
    local who="$1"
    set_author "${who%%|*}" "${who##*|}"
}

# ─────────────────────────────────────────────────────────────────────
# PHASE 1: project foundation (already pushed; not what GitChop shows
# by default, but visible if you bump the depth)
# ─────────────────────────────────────────────────────────────────────

# c01 — Alex, Apr 1: scaffold
as "$ALEX"
mkdir -p lib tests/fixtures
cat > README.md <<'EOF'
# tabby

Convert tabular data between CSV, Markdown, and JSON. One command,
no dependencies beyond `awk` and `jq`.

```
tabby input.csv --to markdown
```
EOF
cat > .gitignore <<'EOF'
.DS_Store
*.tmp
/build/
EOF
git add README.md .gitignore
commit_at "2026-04-01T10:00:00" "Initial commit: README and .gitignore"

# c02 — Alex, Apr 2: CSV reader + main driver
cat > tabby <<'EOF'
#!/usr/bin/env bash
# tabby — convert tabular data between formats
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT="${1:-/dev/stdin}"
TO="markdown"
while [[ $# -gt 1 ]]; do
    case "$2" in
        --to) TO="$3"; shift 2 ;;
        *) echo "unknown arg: $2" >&2; exit 1 ;;
    esac
done

. "$SCRIPT_DIR/lib/csv.sh"
read_csv "$INPUT"
EOF
chmod +x tabby
cat > lib/csv.sh <<'EOF'
# Read a CSV file into the global TABLE_ROWS array.
# Each entry is a tab-separated row; quotes are stripped.
read_csv() {
    local file="$1"
    TABLE_ROWS=()
    while IFS= read -r line; do
        # naive split on commas; doesn't handle quoted commas yet
        TABLE_ROWS+=("$(echo "$line" | tr ',' '\t')")
    done < "$file"
}
EOF
git add tabby lib/csv.sh
commit_at "2026-04-02T11:30:00" "Add tabby driver and naive CSV reader"

# c03 — Alex, Apr 3: markdown output
cat > lib/markdown.sh <<'EOF'
# Render TABLE_ROWS as a Markdown table to stdout.
# First row is treated as the header.
write_markdown() {
    local i=0
    for row in "${TABLE_ROWS[@]}"; do
        echo "| $(echo "$row" | sed 's/\t/ | /g') |"
        if [[ $i -eq 0 ]]; then
            local cols=$(echo "$row" | awk -F'\t' '{print NF}')
            local sep="|"
            for ((c=0; c<cols; c++)); do sep+=" --- |"; done
            echo "$sep"
        fi
        i=$((i+1))
    done
}
EOF
# Append markdown wiring to tabby
cat > tabby <<'EOF'
#!/usr/bin/env bash
# tabby — convert tabular data between formats
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT="${1:-/dev/stdin}"
TO="markdown"
while [[ $# -gt 1 ]]; do
    case "$2" in
        --to) TO="$3"; shift 2 ;;
        *) echo "unknown arg: $2" >&2; exit 1 ;;
    esac
done

. "$SCRIPT_DIR/lib/csv.sh"
. "$SCRIPT_DIR/lib/markdown.sh"

read_csv "$INPUT"
case "$TO" in
    markdown) write_markdown ;;
    *) echo "unknown output format: $TO" >&2; exit 1 ;;
esac
EOF
git add lib/markdown.sh tabby
commit_at "2026-04-03T15:45:00" "Add Markdown table output"

# c04 — Sam, Apr 4: tests
as "$SAM"
cat > tests/fixtures/users.csv <<'EOF'
name,email,role
Alex,alex@tabby.dev,maintainer
Sam,sam@tabby.dev,contributor
Jordan,jordan@tabby.dev,docs
EOF
cat > tests/run.sh <<'EOF'
#!/usr/bin/env bash
# Smoke tests for tabby. Exits non-zero on any mismatch.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
expect() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  ✓ $name"
    else
        echo "  ✗ $name"
        diff <(echo "$expected") <(echo "$actual") || true
        fail=1
    fi
}

# CSV → Markdown
got="$(./tabby tests/fixtures/users.csv --to markdown)"
want="| name | email | role |
| --- | --- | --- |
| Alex | alex@tabby.dev | maintainer |
| Sam | sam@tabby.dev | contributor |
| Jordan | jordan@tabby.dev | docs |"
expect "csv → markdown" "$got" "$want"

exit $fail
EOF
chmod +x tests/run.sh
git add tests
commit_at "2026-04-04T09:15:00" "Add test runner with CSV→Markdown smoke test"

# c05 — Alex, Apr 4: license
as "$ALEX"
cat > LICENSE <<'EOF'
MIT License

Copyright (c) 2026 The tabby contributors

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
EOF
git add LICENSE
commit_at "2026-04-04T17:30:00" "Add MIT license"

# ─────────────────────────────────────────────────────────────────────
# PHASE 2: feature branch — JSON input support
# ─────────────────────────────────────────────────────────────────────

git checkout -q -b feature/json-input

# c06 — Sam: JSON parser
as "$SAM"
cat > lib/json.sh <<'EOF'
# Read a JSON array-of-objects into TABLE_ROWS.
# Requires jq. The first object's keys become the header row.
read_json() {
    local file="$1"
    TABLE_ROWS=()
    local headers
    headers=$(jq -r '.[0] | keys_unsorted | @tsv' "$file")
    TABLE_ROWS+=("$headers")
    while IFS= read -r row; do
        TABLE_ROWS+=("$row")
    done < <(jq -r '.[] | [.[]] | @tsv' "$file")
}
EOF
git add lib/json.sh
commit_at "2026-04-05T14:00:00" "Add JSON input parser"

# c07 — Sam: wire JSON into dispatcher
cat > tabby <<'EOF'
#!/usr/bin/env bash
# tabby — convert tabular data between formats
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT="${1:-/dev/stdin}"
FROM=""
TO="markdown"
while [[ $# -gt 1 ]]; do
    case "$2" in
        --to)   TO="$3";   shift 2 ;;
        --from) FROM="$3"; shift 2 ;;
        *) echo "unknown arg: $2" >&2; exit 1 ;;
    esac
done

# Auto-detect input format from extension if not provided.
if [[ -z "$FROM" ]]; then
    case "$INPUT" in
        *.json) FROM="json" ;;
        *)      FROM="csv"  ;;
    esac
fi

. "$SCRIPT_DIR/lib/csv.sh"
. "$SCRIPT_DIR/lib/markdown.sh"
. "$SCRIPT_DIR/lib/json.sh"

case "$FROM" in
    csv)  read_csv  "$INPUT" ;;
    json) read_json "$INPUT" ;;
    *) echo "unknown input format: $FROM" >&2; exit 1 ;;
esac

case "$TO" in
    markdown) write_markdown ;;
    *) echo "unknown output format: $TO" >&2; exit 1 ;;
esac
EOF
git add tabby
commit_at "2026-04-06T10:30:00" "Wire JSON parser into the input dispatcher"

# c08 — Sam: JSON tests
cat > tests/fixtures/users.json <<'EOF'
[
  {"name": "Alex",   "email": "alex@tabby.dev",   "role": "maintainer"},
  {"name": "Sam",    "email": "sam@tabby.dev",    "role": "contributor"},
  {"name": "Jordan", "email": "jordan@tabby.dev", "role": "docs"}
]
EOF
# Append a JSON test case
cat >> tests/run.sh <<'EOF'

# JSON → Markdown
got="$(./tabby tests/fixtures/users.json --to markdown)"
want="| name | email | role |
| --- | --- | --- |
| Alex | alex@tabby.dev | maintainer |
| Sam | sam@tabby.dev | contributor |
| Jordan | jordan@tabby.dev | docs |"
expect "json → markdown" "$got" "$want"

exit $fail
EOF
# remove the stray earlier `exit $fail` (now we have it at the end)
awk '
    /^exit \$fail$/ {
        if (++count == 1) next   # drop the first occurrence
    }
    { print }
' tests/run.sh > tests/run.sh.tmp && mv tests/run.sh.tmp tests/run.sh
chmod +x tests/run.sh
git add tests
commit_at "2026-04-06T16:00:00" "Add JSON→Markdown test"

# Merge json-input back to main
git checkout -q main
as "$ALEX"
merge_at "2026-04-07T09:00:00" "feature/json-input" "Merge feature/json-input: JSON input support"
git branch -q -d feature/json-input

# c09 — Jordan, Apr 7: CHANGELOG
as "$JORDAN"
cat > CHANGELOG.md <<'EOF'
# Changelog

## [Unreleased]

## [0.2.0] — 2026-04-07
### Added
- JSON input format (auto-detected from `.json` extension or `--from json`).
- Initial test runner with CSV and JSON smoke tests.

## [0.1.0] — 2026-04-03
### Added
- Initial CSV reader and Markdown writer.
EOF
git add CHANGELOG.md
commit_at "2026-04-07T15:30:00" "Add CHANGELOG"

# c10 — Alex, Apr 8: bump version
as "$ALEX"
sed -i.bak 's|^# tabby — convert tabular data between formats$|# tabby 0.2.0 — convert tabular data between formats|' tabby
rm -f tabby.bak
git add tabby
commit_at "2026-04-08T11:00:00" "Bump version to 0.2.0"

# ─────────────────────────────────────────────────────────────────────
# PHASE 3: bugfix branch — header alignment with quoted CSV
# ─────────────────────────────────────────────────────────────────────

git checkout -q -b bugfix/header-alignment

# c11
cat > lib/csv.sh <<'EOF'
# Read a CSV file into the global TABLE_ROWS array.
# Each entry is a tab-separated row.
# Surrounding double quotes around individual cells are stripped so
# header alignment matches body cells when the source quotes some
# fields but not others.
read_csv() {
    local file="$1"
    TABLE_ROWS=()
    while IFS= read -r line; do
        # Strip surrounding double quotes on each comma-separated cell.
        local cleaned
        cleaned="$(echo "$line" | sed -E 's/"([^"]*)"/\1/g')"
        TABLE_ROWS+=("$(echo "$cleaned" | tr ',' '\t')")
    done < "$file"
}
EOF
git add lib/csv.sh
commit_at "2026-04-09T10:00:00" "Fix header alignment with quoted CSV cells

Header rows from CSVs that quote *some* cells (often produced by
spreadsheet exports) were rendering with the quotes intact, which
threw off the column count vs. unquoted body rows. Strip surrounding
quotes per cell so the header and body line up.
"

# c12 — test for the fix
cat > tests/fixtures/quoted.csv <<'EOF'
"name",email,"role"
Alex,alex@tabby.dev,"maintainer"
Sam,"sam@tabby.dev",contributor
EOF
# Insert a third test before the final exit
awk '
    /^exit \$fail$/ && !inserted {
        print ""
        print "# Quoted-cell CSV → Markdown (regression test for header alignment)"
        print "got=\"$(./tabby tests/fixtures/quoted.csv --to markdown)\""
        print "want=\"| name | email | role |"
        print "| --- | --- | --- |"
        print "| Alex | alex@tabby.dev | maintainer |"
        print "| Sam | sam@tabby.dev | contributor |\""
        print "expect \"quoted csv → markdown\" \"$got\" \"$want\""
        inserted = 1
    }
    { print }
' tests/run.sh > tests/run.sh.tmp && mv tests/run.sh.tmp tests/run.sh
chmod +x tests/run.sh
git add tests
commit_at "2026-04-09T11:15:00" "Add test for quoted-cell header alignment"

# Merge bugfix back
git checkout -q main
merge_at "2026-04-09T14:00:00" "bugfix/header-alignment" "Merge bugfix/header-alignment"
git branch -q -d bugfix/header-alignment

# ─────────────────────────────────────────────────────────────────────
# PHASE 4: LOCAL WIP — twelve commits the developer is about to clean
# up before pushing. This is what GitChop loads by default (depth=12).
# Lots of deliberate rebase candidates.
# ─────────────────────────────────────────────────────────────────────

# w01 — Apr 15: refactor formatter
as "$ALEX"
cat > lib/markdown.sh <<'EOF'
# Render TABLE_ROWS as a Markdown table to stdout.
# First row is the header.
write_markdown() {
    local i=0
    for row in "${TABLE_ROWS[@]}"; do
        # printf-based to avoid sed's habit of misinterpreting embedded
        # `&` and pipe characters in cell values.
        local cells
        IFS=$'\t' read -ra cells <<<"$row"
        printf '|'
        printf ' %s |' "${cells[@]}"
        printf '\n'
        if [[ $i -eq 0 ]]; then
            printf '|'
            for _ in "${cells[@]}"; do printf ' --- |'; done
            printf '\n'
        fi
        i=$((i+1))
    done
}
EOF
git add lib/markdown.sh
commit_at "2026-04-15T09:30:00" "Refactor markdown writer to use printf instead of a sed pipeline"

# w02 — Apr 15 afternoon: start JSON output
cat > lib/json_out.sh <<'EOF'
# Render TABLE_ROWS as a JSON array of objects.
# First row is treated as the header (used as object keys).
write_json() {
    local headers_row="${TABLE_ROWS[0]}"
    local -a headers
    IFS=$'\t' read -ra headers <<<"$headers_row"

    printf '[\n'
    local i
    for ((i=1; i<${#TABLE_ROWS[@]}; i++)); do
        local -a cells
        IFS=$'\t' read -ra cells <<<"${TABLE_ROWS[i]}"
        printf '  {'
        local j
        for ((j=0; j<${#headers[@]}; j++)); do
            [[ $j -gt 0 ]] && printf ', '
            # naive escape: just wrap in quotes
            printf '"%s": "%s"' "${headers[j]}" "${cells[j]}"
        done
        printf '}'
        if [[ $i -lt $((${#TABLE_ROWS[@]}-1)) ]]; then printf ','; fi
        printf '\n'
    done
    printf ']\n'
}
EOF
# Hook into dispatcher
sed -i.bak 's|. "$SCRIPT_DIR/lib/json.sh"|. "$SCRIPT_DIR/lib/json.sh"\n. "$SCRIPT_DIR/lib/json_out.sh"|' tabby
sed -i.bak 's|markdown) write_markdown ;;|markdown) write_markdown ;;\n    json)     write_json     ;;|' tabby
rm -f tabby.bak
git add tabby lib/json_out.sh
commit_at "2026-04-15T14:30:00" "Start JSON output support"

# w03 — Apr 15 evening: tests for JSON output (paired with w02 — squash candidate)
awk '
    /^exit \$fail$/ && !inserted {
        print ""
        print "# CSV → JSON"
        print "got=\"$(./tabby tests/fixtures/users.csv --to json | tr -d \" \\n\")\""
        print "want=\"[{\\\"name\\\":\\\"Alex\\\",\\\"email\\\":\\\"alex@tabby.dev\\\",\\\"role\\\":\\\"maintainer\\\"},{\\\"name\\\":\\\"Sam\\\",\\\"email\\\":\\\"sam@tabby.dev\\\",\\\"role\\\":\\\"contributor\\\"},{\\\"name\\\":\\\"Jordan\\\",\\\"email\\\":\\\"jordan@tabby.dev\\\",\\\"role\\\":\\\"docs\\\"}]\""
        print "expect \"csv → json\" \"$got\" \"$want\""
        inserted = 1
    }
    { print }
' tests/run.sh > tests/run.sh.tmp && mv tests/run.sh.tmp tests/run.sh
git add tests/run.sh
commit_at "2026-04-15T17:45:00" "Add CSV→JSON output test"

# w04 — Apr 16 morning: bug fix for w02 (fixup candidate)
cat > lib/json_out.sh <<'EOF'
# Render TABLE_ROWS as a JSON array of objects.
# First row is treated as the header (used as object keys).
write_json() {
    local headers_row="${TABLE_ROWS[0]}"
    local -a headers
    IFS=$'\t' read -ra headers <<<"$headers_row"

    printf '[\n'
    local i
    for ((i=1; i<${#TABLE_ROWS[@]}; i++)); do
        local -a cells
        IFS=$'\t' read -ra cells <<<"${TABLE_ROWS[i]}"
        printf '  {'
        local j
        for ((j=0; j<${#headers[@]}; j++)); do
            [[ $j -gt 0 ]] && printf ', '
            local v="${cells[j]}"
            # Escape backslashes, then double quotes. Order matters —
            # if we did quotes first, the backslash escape would
            # double-escape what we just inserted.
            v="${v//\\/\\\\}"
            v="${v//\"/\\\"}"
            printf '"%s": "%s"' "${headers[j]}" "$v"
        done
        printf '}'
        if [[ $i -lt $((${#TABLE_ROWS[@]}-1)) ]]; then printf ','; fi
        printf '\n'
    done
    printf ']\n'
}
EOF
git add lib/json_out.sh
commit_at "2026-04-16T10:15:00" "Fix JSON output: don't double-escape backslashes"

# w05 — Apr 16 afternoon: typo fix in CHANGELOG (Sam — fixup candidate)
as "$SAM"
sed -i.bak 's|Initial test runner with CSV and JSON smoke tests.|Initial test runner with CSV and JSON smoke tests|' CHANGELOG.md
sed -i.bak 's|Initial CSV reader and Markdown writer.|Initial CSV reader and Markdown writer|' CHANGELOG.md
# fix the typo we're actually fixing — invent one in the changelog
sed -i.bak 's|JSON input format|JSON input format support|' CHANGELOG.md
rm -f CHANGELOG.md.bak
git add CHANGELOG.md
commit_at "2026-04-16T16:30:00" "Fix wording in CHANGELOG entry for 0.2.0"

# w06 — Apr 17 late: WIP TOML output (DROP candidate)
as "$ALEX"
cat > lib/toml_out.sh <<'EOF'
# WIP: TOML output. Doesn't actually work yet — leaving it here so I
# don't forget the shape, but this file isn't wired into the dispatcher
# and shouldn't ship.
#
# TODO: figure out how TOML even handles tabular data. Arrays of inline
# tables? Doesn't really fit the format. Maybe scrap this.
write_toml() {
    echo "# TOML output not implemented" >&2
    return 1
}
EOF
git add lib/toml_out.sh
commit_at "2026-04-17T23:15:00" "WIP: starting TOML output (probably won't ship)"

# w07 — Apr 18 morning: README update (Jordan — could squash with w02 cluster)
as "$JORDAN"
cat > README.md <<'EOF'
# tabby

Convert tabular data between CSV, Markdown, and JSON. One command,
no dependencies beyond `awk` and `jq`.

## Usage

```
tabby input.csv --to markdown
tabby input.json --to markdown
tabby input.csv  --to json
```

The input format is auto-detected from the file extension; pass
`--from csv` or `--from json` to override.

## Examples

```
$ tabby tests/fixtures/users.csv --to markdown
| name | email | role |
| --- | --- | --- |
| Alex | alex@tabby.dev | maintainer |
| Sam | sam@tabby.dev | contributor |
| Jordan | jordan@tabby.dev | docs |
```

```
$ tabby tests/fixtures/users.csv --to json
[
  {"name": "Alex", "email": "alex@tabby.dev", "role": "maintainer"},
  ...
]
```
EOF
git add README.md
commit_at "2026-04-18T11:00:00" "Update README with JSON output examples"

# w08 — Apr 19: --pretty flag
as "$ALEX"
cat > tabby <<'EOF'
#!/usr/bin/env bash
# tabby 0.2.0 — convert tabular data between formats
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT="${1:-/dev/stdin}"
FROM=""
TO="markdown"
PRETTY=0
while [[ $# -gt 1 ]]; do
    case "$2" in
        --to)     TO="$3";   shift 2 ;;
        --from)   FROM="$3"; shift 2 ;;
        --pretty) PRETTY=1;  shift ;;
        *) echo "unknown arg: $2" >&2; exit 1 ;;
    esac
done

if [[ -z "$FROM" ]]; then
    case "$INPUT" in
        *.json) FROM="json" ;;
        *)      FROM="csv"  ;;
    esac
fi

. "$SCRIPT_DIR/lib/csv.sh"
. "$SCRIPT_DIR/lib/markdown.sh"
. "$SCRIPT_DIR/lib/json.sh"
. "$SCRIPT_DIR/lib/json_out.sh"

case "$FROM" in
    csv)  read_csv  "$INPUT" ;;
    json) read_json "$INPUT" ;;
    *) echo "unknown input format: $FROM" >&2; exit 1 ;;
esac

case "$TO" in
    markdown) write_markdown ;;
    json)
        if [[ "$PRETTY" == "1" ]]; then
            write_json | jq .
        else
            write_json
        fi
        ;;
    *) echo "unknown output format: $TO" >&2; exit 1 ;;
esac
EOF
git add tabby
commit_at "2026-04-19T15:00:00" "Add --pretty flag for indented JSON output"

# w09 — Apr 20: column-width polish
cat > lib/markdown.sh <<'EOF'
# Render TABLE_ROWS as a Markdown table to stdout.
# First row is the header.
#
# Column widths are sized to the longest cell in each column (padded
# on the right) so the rendered output stays aligned even when cells
# vary in length. Older versions sized to the header only, which made
# anything wider than the header overflow visually.
write_markdown() {
    [[ ${#TABLE_ROWS[@]} -eq 0 ]] && return 0

    # Compute per-column max widths.
    local -a widths
    local row cells col w
    for row in "${TABLE_ROWS[@]}"; do
        IFS=$'\t' read -ra cells <<<"$row"
        for col in "${!cells[@]}"; do
            w=${#cells[col]}
            if [[ -z "${widths[col]:-}" || $w -gt ${widths[col]} ]]; then
                widths[col]=$w
            fi
        done
    done

    local i=0
    for row in "${TABLE_ROWS[@]}"; do
        IFS=$'\t' read -ra cells <<<"$row"
        printf '|'
        for col in "${!cells[@]}"; do
            printf ' %-*s |' "${widths[col]}" "${cells[col]}"
        done
        printf '\n'
        if [[ $i -eq 0 ]]; then
            printf '|'
            for col in "${!widths[@]}"; do
                printf ' %s |' "$(printf '%*s' "${widths[col]}" '' | tr ' ' '-')"
            done
            printf '\n'
        fi
        i=$((i+1))
    done
}
EOF
git add lib/markdown.sh
commit_at "2026-04-20T10:00:00" "Polish: align Markdown columns to longest cell, not first row"

# w10 — Apr 21: CI fix (Sam — REORDER candidate, should be near w02)
as "$SAM"
mkdir -p .github/workflows
cat > .github/workflows/test.yml <<'EOF'
name: tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install jq
        run: sudo apt-get update && sudo apt-get install -y jq
      - name: Run tests
        run: bash tests/run.sh
EOF
git add .github/workflows/test.yml
commit_at "2026-04-21T09:30:00" "Fix CI: install jq before running JSON tests"

# w11 — Apr 22: bump version
as "$ALEX"
sed -i.bak 's|^# tabby 0\.2\.0 — convert tabular data between formats$|# tabby 0.3.0 — convert tabular data between formats|' tabby
rm -f tabby.bak
# CHANGELOG entry
awk '
    /^## \[Unreleased\]$/ {
        print
        print ""
        print "## [0.3.0] — 2026-04-22"
        print "### Added"
        print "- JSON output (`--to json`), with optional `--pretty` for jq-indented output."
        print "### Changed"
        print "- Markdown writer rewritten to use printf and to size columns to the longest cell."
        print "### Fixed"
        print "- Header alignment when the source CSV quotes some cells but not others."
        next
    }
    { print }
' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
git add tabby CHANGELOG.md
commit_at "2026-04-22T11:00:00" "Bump version to 0.3.0"

# w12 — Apr 23: flaky test fix
cat > tests/run.sh <<'EOF'
#!/usr/bin/env bash
# Smoke tests for tabby. Exits non-zero on any mismatch.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
expect() {
    local name="$1" actual="$2" expected="$3"
    # Normalize trailing whitespace on each line — `tput cols` on
    # macOS Terminal at narrow widths can pad cells with stray spaces.
    actual="$(printf '%s\n' "$actual" | sed -e 's/[[:space:]]*$//')"
    expected="$(printf '%s\n' "$expected" | sed -e 's/[[:space:]]*$//')"
    if [[ "$actual" == "$expected" ]]; then
        echo "  ✓ $name"
    else
        echo "  ✗ $name"
        diff <(echo "$expected") <(echo "$actual") || true
        fail=1
    fi
}

# CSV → Markdown
got="$(./tabby tests/fixtures/users.csv --to markdown)"
want="| name   | email            | role        |
| ------ | ---------------- | ----------- |
| Alex   | alex@tabby.dev   | maintainer  |
| Sam    | sam@tabby.dev    | contributor |
| Jordan | jordan@tabby.dev | docs        |"
expect "csv → markdown" "$got" "$want"

# JSON → Markdown
got="$(./tabby tests/fixtures/users.json --to markdown)"
expect "json → markdown" "$got" "$want"

# Quoted-cell CSV → Markdown (regression test for header alignment)
got="$(./tabby tests/fixtures/quoted.csv --to markdown)"
want_q="| name | email          | role        |
| ---- | -------------- | ----------- |
| Alex | alex@tabby.dev | maintainer  |
| Sam  | sam@tabby.dev  | contributor |"
expect "quoted csv → markdown" "$got" "$want_q"

# CSV → JSON
got="$(./tabby tests/fixtures/users.csv --to json | tr -d ' \n')"
want_j='[{"name":"Alex","email":"alex@tabby.dev","role":"maintainer"},{"name":"Sam","email":"sam@tabby.dev","role":"contributor"},{"name":"Jordan","email":"jordan@tabby.dev","role":"docs"}]'
expect "csv → json" "$got" "$want_j"

exit $fail
EOF
chmod +x tests/run.sh
git add tests/run.sh
commit_at "2026-04-23T14:00:00" "Fix flaky terminal-width test on macOS"

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────

unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE

echo
echo "Done. ${DEST}"
echo
echo "──── git log --graph --oneline (most recent first) ────"
git log --graph --oneline --all | head -20
echo
echo "──── what GitChop will show (last 12 non-merge commits, oldest at top) ────"
git log --no-merges -12 --reverse --pretty='format:%h  %an — %s' | head -12
echo
echo
echo "Try it:"
echo "  • Open Repo… in GitChop and pick: $DEST"
echo "  • Practice candidates:"
echo "      drop      'WIP: starting TOML output'"
echo "      fixup     'Fix JSON output: don't double-escape' into 'Start JSON output support'"
echo "      squash    'Add CSV→JSON output test' into 'Start JSON output support'"
echo "      reorder   'Fix CI: install jq…' to land right after 'Start JSON output support'"
