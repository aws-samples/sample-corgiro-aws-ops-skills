#!/usr/bin/env bash
# Leak scan — mode-builder validation gate 5. Any hit is a hard fail.
# Scans for internal tool tokens, internal hostnames, and possible real
# 12-digit AWS account IDs (placeholders 111111111111 / 123456789012 /
# repeated-digit IDs are allowed).
#
# Usage: leak-scan.sh <file-or-dir> [...]
# Exit 0 = clean. Exit 1 = findings printed above. Exit 2 = usage error.
set -u
[ $# -ge 1 ] || { echo "usage: leak-scan.sh <file-or-dir> [...]"; exit 2; }

fail=0

# Internal tokens / hostnames (case-insensitive; word-bounded where the token
# is a plain word so e.g. "Upfront" does not match "pfr").
TOKENS='k2_|dante_|cmc_|caseapi_|harbinger_|sift_|\bpfr\b|use_subagent|~/shared/tam-work|ReadInternalWebsites|mwinit|isengard|\bmidway\b|\bCAZ\b|bubblewand|\.amazon\.com|\.a2z\.com|\.corp\.amazon\.com'
hits=$(grep -rniE "$TOKENS" "$@" 2>/dev/null)
if [ -n "$hits" ]; then printf '%s\n' "$hits"; fail=1; fi

# Internal tool names (case-sensitive proper nouns).
NAMES='\bUNO\b|\bAIM\b|\bK2\b|\bDante\b|\bCMC\b'
name_hits=$(grep -rnE "$NAMES" "$@" 2>/dev/null)
if [ -n "$name_hits" ]; then printf '%s\n' "$name_hits"; fail=1; fi

# Possible real AWS account IDs: any 12-digit run that is not a documented
# placeholder (all-same-digit, or the AWS doc example 123456789012).
id_hits=$(grep -rnoE '[0-9]{12}' "$@" 2>/dev/null | grep -vE ':(([0-9])\2{11}|123456789012)$')
if [ -n "$id_hits" ]; then
  echo "Possible real account IDs (only repeated-digit or 123456789012 placeholders are allowed):"
  printf '%s\n' "$id_hits"
  fail=1
fi

if [ $fail -eq 0 ]; then echo "Leak scan clean."; else echo "LEAK SCAN FAILED — remove the findings above."; fi
exit $fail
