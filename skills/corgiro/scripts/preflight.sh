#!/usr/bin/env bash
# Corgiro pre-flight security checks — run at the start of every mode execution,
# before reading any credentials or config. Full rationale lives in
# references/credential-resolution.md ("Pre-flight Security Checks").
#
#   1   — file permissions on ~/.corgiro/
#   2.0 — resolve session variables from config.json (absent-implies-default rules)
#   2a  — identity-center: session age from the SSO token cache
#   2b  — saml-external: session age from the profile's expiry key (best-effort)
#   2c  — authoritative validity probe (sts get-caller-identity)
#
# Exit 0 = all clear. Exit 1 = stop the run; a remediation line was printed.
set -u

CFG=~/.corgiro/config.json

# --- 1. File permission verification -----------------------------------------
CORGIRO_DIR_PERM=$(stat -f "%Lp" ~/.corgiro 2>/dev/null || stat -c "%a" ~/.corgiro 2>/dev/null)
if [ "${CORGIRO_DIR_PERM:-}" != "700" ]; then
  echo "WARNING: ~/.corgiro/ permissions are ${CORGIRO_DIR_PERM:-unset} (expected 700). Fixing..."
  chmod 700 ~/.corgiro ~/.corgiro/state 2>/dev/null
  chmod 600 ~/.corgiro/config.json ~/.corgiro/state/*.json 2>/dev/null
fi

[ -f "$CFG" ] || { echo "No $CFG. Run: /corgiro setup-corgiro"; exit 1; }

# --- 2.0 Resolve session variables (all paths) --------------------------------
read_cfg() {  # read_cfg <python-expr over `c`> — never raises on null/missing blocks
  python3 -c "import json,os
c = json.load(open(os.path.expanduser('$CFG')))
print($1)" 2>/dev/null
}

ACCESS_MODE=$(read_cfg "c.get('accessMode','')")
AUTH_METHOD=$(read_cfg "c.get('authMethod') or 'identity-center'")            # absent => identity-center
AUTH_PROFILE=$(read_cfg "(c.get('auth') or {}).get('profile') or 'corgiro'")  # absent => corgiro
SESSION_NAME=$(read_cfg "(c.get('ssoSession') or {}).get('sessionName','')")

# Remediation command printed on any failure below. Never executed by Corgiro.
if [ "$AUTH_METHOD" = "saml-external" ]; then
  LOGIN_COMMAND=$(read_cfg "(c.get('auth') or {}).get('loginCommand') or ''")
  [ -n "$LOGIN_COMMAND" ] || LOGIN_COMMAND="your IdP helper's login command (auth.loginCommand is unset in $CFG)"
else
  LOGIN_COMMAND="aws sso login --sso-session $SESSION_NAME"
fi

# Which profile 2c probes. identity-center-direct has NO base profile — it
# reaches each account through its own <profilePrefix><accountId> profile, and
# `auth` is null there — so probe the first roster entry instead.
# AUTH_PROFILE and PROBE_PROFILE are NOT interchangeable: probing AUTH_PROFILE
# on identity-center-direct tests a profile that was never written.
if [ "$ACCESS_MODE" = "identity-center-direct" ]; then
  PROBE_PROFILE=$(python3 -c "import json,os
r = json.load(open(os.path.expanduser('~/.corgiro/state/roster.json')))
print(next((e['profile'] for e in r.values() if e.get('profile')), ''))" 2>/dev/null)
else
  PROBE_PROFILE=$AUTH_PROFILE
fi

# --- 2a / 2b. Session age (T2, best-effort) ------------------------------------
if [ "$AUTH_METHOD" = "saml-external" ]; then
  # 2b — expiry key names vary by helper; aws_expiration is verified for
  # aws-azure-login. No expiry found => do NOT fail; 2c decides.
  EXPIRES_AT=$(aws configure get aws_expiration --profile "$AUTH_PROFILE" 2>/dev/null)
  if [ -z "$EXPIRES_AT" ]; then
    echo "NOTE: no known expiry key on profile '$AUTH_PROFILE'. Age enforcement unavailable; relying on the validity probe only."
  fi
else
  # 2a — AWS CLI v2 keys the sso-session token cache on sha1(sessionName), so
  # derive the filename. NEVER select the cache file by modification time: a
  # laptop holds tokens for unrelated sessions, and the newest file can report
  # a healthy session when Corgiro's own token has expired — a silent false
  # pass on a security control. Fallback matches on startUrl, not mtime.
  SESSION_HASH=$(printf %s "$SESSION_NAME" | { shasum -a 1 2>/dev/null || sha1sum; } | cut -d' ' -f1)
  CACHE_FILE=~/.aws/sso/cache/$SESSION_HASH.json

  if [ ! -f "$CACHE_FILE" ]; then
    START_URL=$(read_cfg "(c.get('ssoSession') or {}).get('startUrl','')")
    CACHE_FILE=$(grep -l "\"startUrl\": *\"$START_URL\"" ~/.aws/sso/cache/*.json 2>/dev/null | head -1)
  fi

  if [ -n "${CACHE_FILE:-}" ] && [ -f "$CACHE_FILE" ]; then
    EXPIRES_AT=$(python3 -c "import json,sys; print(json.load(open('$CACHE_FILE')).get('expiresAt',''))" 2>/dev/null)
    if [ -n "$EXPIRES_AT" ]; then
      EXPIRES_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$EXPIRES_AT" "+%s" 2>/dev/null || date -d "$EXPIRES_AT" "+%s" 2>/dev/null)
      NOW_EPOCH=$(date "+%s")
      if [ -n "${EXPIRES_EPOCH:-}" ] && [ $(( EXPIRES_EPOCH - NOW_EPOCH )) -le 0 ]; then
        echo "SSO session expired. Run: $LOGIN_COMMAND"
        exit 1
      fi
    fi
  fi
fi

# --- 2c. Authoritative validity probe ------------------------------------------
# Expiry timestamps only say when a session WOULD lapse; they miss sessions
# revoked or disabled at the IdP. Probe before doing any work.
if [ -z "$PROBE_PROFILE" ]; then
  echo "No probeable profile in ~/.corgiro/. Re-run: /corgiro setup-corgiro"
  exit 1
fi

aws sts get-caller-identity --profile "$PROBE_PROFILE" >/dev/null 2>&1 || {
  echo "Operator session invalid or expired. Run: $LOGIN_COMMAND"
  exit 1
}

echo "Pre-flight OK (accessMode=$ACCESS_MODE, authMethod=$AUTH_METHOD, probed profile=$PROBE_PROFILE)"
