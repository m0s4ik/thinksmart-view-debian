#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrea Mattera
# Fails if tracked files contain data that belongs to someone's home: private IP addresses (other than the generic
# ranges used as defaults), MAC addresses, .home/.lan host names, tokens and private keys.
# Extra literal patterns (your own host names, SSIDs, serial numbers...), one per line, can come from the file
# .private-patterns (git-ignored, never committed) and from the PRIVATE_PATTERNS environment variable (in CI: a
# repository secret), so the list itself is never published.
# Usage: .github/scripts/check-private.sh   (from the repository root)
set -uo pipefail

found=0
report() {  # report DESCRIPTION REGEX [grep options]
    local what=$1 re=$2 hits
    shift 2
    hits=$(git grep -n -I -E "$@" -e "$re" -- . ':!.github/scripts/check-private.sh' |
        grep -v -E '192\.168\.0\.0/16|10\.0\.0\.0/8|172\.16\.0\.0/12' || true)
    if [ -n "$hits" ]; then
        echo "== $what"
        echo "$hits"
        found=1
    fi
}

report "private IPv4 address" '(^|[^0-9.])(192\.168|10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
report "MAC address" '(^|[^0-9a-f:])([0-9a-f]{2}:){5}[0-9a-f]{2}([^0-9a-f:]|$)' -i
report "home host name" '[a-z0-9-]+\.(home|lan|internal)([^a-z0-9._-]|$)' -i
report "token" '(ghp_|gho_|github_pat_)[A-Za-z0-9_]{20,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'
report "private key" '-----BEGIN [A-Z ]*PRIVATE KEY-----'

patterns=$( { [ -r .private-patterns ] && cat .private-patterns; printf '%s\n' "${PRIVATE_PATTERNS:-}"; } |
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true)
if [ -n "$patterns" ]; then
    hits=$(git grep -n -I -i -F -f <(printf '%s\n' "$patterns") -- . ':!.github/scripts/check-private.sh' || true)
    if [ -n "$hits" ]; then
        # print where, not what: the patterns themselves are private
        echo "== private pattern (from .private-patterns or PRIVATE_PATTERNS)"
        echo "$hits" | cut -d: -f1,2
        found=1
    fi
fi

if [ $found = 0 ]; then echo "no private data found"; fi
exit $found
