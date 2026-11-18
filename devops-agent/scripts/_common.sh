# Shared helpers for the Corgiro DevOps Agent scripts. Sourced, not executed.
#
# Lives here because duplicating these bit us twice: a secret leaked from two
# scripts independently, and the read-at-EOF fix had to be applied per copy.

# --------------------------------------------------------------------- output
say()  { printf '%s\n' "$*"; }
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
# wins. NO_PROMPT=1 forces the non-interactive path for CI.
# `return 0` is load-bearing. At top level a failing `&&` list is exempt from
# `set -e`, but as a function's LAST command its status becomes the function's
# return value, so a non-TTY stdin made this function return 1 and killed the
# calling script with no output.
common_init_interactive() {
  INTERACTIVE=0
  if [ -t 0 ] && [ "${NO_PROMPT:-0}" != "1" ]; then INTERACTIVE=1; fi
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
  if [ "${CONFIRM:-no}" = "yes" ]; then DRY=0; fi
  CONFIRM_PROMPTED=0
  return 0
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
