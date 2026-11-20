# AWS CLI v2 pipes output through a pager (less) by default, which BLOCKS a
# non-interactive script mid-deployment on an innocuous {"OperationId": "..."}
# and looks for all the world like the script has hung or opened an editor.
export AWS_PAGER=""
# Shared helpers for the Corgiro DevOps Agent scripts. Sourced, not executed.
#
# Lives here because duplicating these bit us twice: a secret leaked from two
# scripts independently, and the read-at-EOF fix had to be applied per copy.

# --------------------------------------------------------------------- output
say()  { printf '%s\n' "$*"; }

# One convention for every boolean input: yes or no, any case, with y/n accepted
# as the short form the [y/N] prompts take. Nothing else - 1/0, true/false and
# on/off are rejected rather than guessed at.
#
# An unrecognised value is an ERROR, never a silent "no". Three different
# conventions used to coexist here: NO_PROMPT matched exactly "1", CONFIRM
# exactly "yes", PIN_AGENT_SPACE anything starting with y. So NO_PROMPT=true was
# silently ignored, and CONFIRM=true would have run a silent DRY RUN that
# reported success and changed nothing, leaving you believing you had deployed.
is_yes() {   # is_yes VARNAME
  local _v
  _v="$(printf %s "${!1:-}" | tr "[:upper:]" "[:lower:]")"
  case "$_v" in
    y|yes)   return 0 ;;
    ""|n|no) return 1 ;;
    *) printf "%s\n" "${1}=${!1} is not valid. Use yes or no (y/n also accepted, any case)." >&2
       exit 1 ;;
  esac
}

# Resolve REGION from the profile when unset. No default: deploying to or
# inspecting the wrong region is the most expensive mistake available here,
# because every script finds its targets by name WITHIN one region - a different
# region does not collide with the existing deployment, it silently addresses a
# second, parallel one. A shown default invites exactly that by being accepted
# unread, so take the profile's own region and stop if it has none.
common_resolve_region() {
  [ -n "${REGION:-}" ] && return 0
  REGION="$(aws configure get region --profile "$TOOLING_PROFILE" 2>/dev/null || echo '')"
  if [ -n "$REGION" ]; then
    say "  region: ${REGION} (from profile '${TOOLING_PROFILE}')"
    return 0
  fi
  say "Cannot determine the region." >&2
  say "  Profile '${TOOLING_PROFILE}' has no region configured, so there is" >&2
  say "  nothing to fall back to. Guessing one would risk addressing a second," >&2
  say "  parallel set of resources instead of the one you mean." >&2
  say "" >&2
  say "  Either set it for this run:  REGION=<region> ..." >&2
  say "  or configure it once:        aws configure set region <region> --profile ${TOOLING_PROFILE}" >&2
  exit 1
}

step() { printf '\n--- %s ---\n' "$*"; }

# Elide long arguments and redact secrets. A GitHub PAT or an external ID is
# shorter than the elision threshold, so they must be matched by name too, or a
# dry run prints them to stdout and shell history.
redact() {
  local a="$1"
  case "$a" in
    *GitHubPat,ParameterValue=*|*ExternalId,ParameterValue=*)
      printf '%s' "${a%%,ParameterValue=*},ParameterValue=<redacted>" ; return ;;
    ghp_*|github_pat_*|ghs_*|ghu_*)
      printf '%s' '<redacted-token>' ; return ;;
  esac
  if [ "${#a}" -gt 110 ]; then printf "'%s...<%s chars>'" "${a:0:90}" "${#a}"
  else printf '%s' "$a"; fi
}

# Execute, or in dry run print what would have been executed.
run() {
  if [ "$DRY" -eq 1 ]; then
    local out="" a
    for a in "$@"; do out+=" $(redact "$a")"; done
    say "  DRY-RUN would run:${out}"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------- input
# Prompt only when stdin is a TTY and the value is unset. The environment always
# wins. NO_PROMPT=y forces the non-interactive path for CI.
# `return 0` is load-bearing. At top level a failing `&&` list is exempt from
# `set -e`, but as a function's LAST command its status becomes the function's
# return value, so a non-TTY stdin made this function return 1 and killed the
# calling script with no output.
common_init_interactive() {
  INTERACTIVE=0
  # is_yes FIRST: [ -t 0 ] would short-circuit and skip its validation.
  if ! is_yes NO_PROMPT && [ -t 0 ]; then INTERACTIVE=1; fi
  return 0
}

# ask VAR "prompt" [default] [secret]
ask() {
  local var="$1" prompt="$2" def="${3:-}" secret="${4:-}" cur val
  cur="${!var:-}"
  [ -n "$cur" ] && return 0
  if [ "$INTERACTIVE" -eq 0 ]; then
    [ -n "$def" ] && eval "$var=\$def"
    return 0
  fi
  # `|| true` matters: read returns non-zero at EOF, and under `set -e` that
  # kills the script with no message when stdin closes mid-prompt.
  if [ -n "$secret" ]; then
    read -rsp "  ${prompt}: " val || true; echo
  elif [ -n "$def" ]; then
    read -rp "  ${prompt} [${def}]: " val || true; val="${val:-$def}"
  else
    read -rp "  ${prompt}: " val || true
  fi
  eval "$var=\$val"
}

need() { [ -n "${!1:-}" ] || { printf '%s\n' "$1 is required. $2" >&2; exit 1; } ; }

# --------------------------------------------------------------------- confirm
# Dry run unless CONFIRM=yes. Call common_init_dry BEFORE the plan banner, and
# common_confirm AFTER it, so the decision is made with the plan on screen.
common_init_dry() {
  DRY=1
  if is_yes CONFIRM; then DRY=0; fi
  CONFIRM_PROMPTED=0
  return 0
}

# The banner prints BEFORE the apply prompt, so when that prompt is still coming
# the mode is genuinely undecided. Saying "DRY RUN" there was wrong: answering y
# applies for real, which reads as though the confirmation were confirming the
# dry run itself.
mode_label() {
  if [ "$DRY" -eq 0 ]; then
    printf 'APPLY'
  elif [ "$INTERACTIVE" -eq 1 ] && [ -z "${CONFIRM:-}" ]; then
    printf 'decided by the prompt below (DRY RUN if you decline)'
  else
    printf 'DRY RUN'
  fi
}

common_confirm() {
  if [ "$DRY" -eq 1 ] && [ "$INTERACTIVE" -eq 1 ] && [ -z "${CONFIRM:-}" ]; then
    local _apply=""
    read -rp "
Apply these changes? [y/N]: " _apply || true     # EOF -> empty -> treated as No
    case "$_apply" in
      [yY]*) DRY=0; CONFIRM_PROMPTED=1; say "  applying." ;;
      *)     say "  dry run - showing what would happen, changing nothing." ;;
    esac
  elif [ "$DRY" -eq 1 ]; then
    say " (dry run; set CONFIRM=yes to apply)"
  fi
  return 0
}

# Message for the closing summary of a run that changed nothing.
common_nochange_note() {
  if [ "${CONFIRM_PROMPTED:-0}" -eq 0 ] && [ "$INTERACTIVE" -eq 1 ]; then
    say " Nothing was changed - you answered no at the apply prompt."
  else
    say " Nothing was changed. Re-run with CONFIRM=yes to apply."
  fi
  return 0
}
