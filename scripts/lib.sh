# shellcheck shell=bash
# Shared helpers for spork scripts. Source, don't execute.

SPORK_ACTION_REPO=${SPORK_ACTION_REPO:-Shardbyte/spork}
SPORK_BOT_NAME='github-actions[bot]'
SPORK_BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'

GIT_AUTH=()

spork_log() { printf 'spork: %s\n' "$*" >&2; }

spork_warn() {
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    printf '::warning::spork: %s\n' "$*" >&2
  else
    printf 'spork: warning: %s\n' "$*" >&2
  fi
}

spork_die() {
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    printf '::error::spork: %s\n' "$*" >&2
  else
    printf 'spork: error: %s\n' "$*" >&2
  fi
  exit 1
}

# spork_output NAME VALUE — step output (when in Actions) + log line.
spork_output() {
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
  spork_log "$1=$2"
}

spork_summary() {
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  fi
}

# owner/repo -> https://github.com/owner/repo.git ; URLs and paths pass through.
spork_normalize_url() {
  local u=$1
  if [[ $u =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && ! -e $u ]]; then
    u="${GITHUB_SERVER_URL:-https://github.com}/${u%.git}.git"
  fi
  printf '%s\n' "$u"
}

# spork_set_auth TOKEN — authenticate `ogit` (origin git) and gh with TOKEN.
spork_set_auth() {
  local token=$1 b64
  [[ -n $token ]] || return 0
  b64=$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    printf '::add-mask::%s\n' "$b64"
  fi
  GIT_AUTH=(-c "http.extraheader=AUTHORIZATION: basic $b64")
  export GH_TOKEN=$token
}

# git with origin credentials. Plain `git` is used for upstream so the token
# is never sent to the upstream host.
ogit() { git "${GIT_AUTH[@]}" "$@"; }

# spork_default_branch GITCMD URL
spork_default_branch() {
  "$1" ls-remote --symref "$2" HEAD |
    awk '$1 == "ref:" { sub("^refs/heads/", "", $2); print $2; exit }'
}

# spork_remote_sha GITCMD URL REF — empty when the ref doesn't exist.
spork_remote_sha() {
  "$1" ls-remote "$2" "$3" | awk -v r="$3" '$2 == r { print $1; exit }'
}

# Use the configured git identity, or fall back to the Actions bot.
spork_ensure_identity() {
  if ! git config user.email >/dev/null 2>&1; then
    export GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-$SPORK_BOT_NAME}
    export GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-$SPORK_BOT_EMAIL}
    export GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-$SPORK_BOT_NAME}
    export GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-$SPORK_BOT_EMAIL}
  fi
}

spork_have_gh() { command -v gh >/dev/null 2>&1; }

# spork_disable_foreign_workflows REPO SELF_PATH
# Disables every active workflow except SELF_PATH and cancels their pending
# runs. Sets SPORK_FOREIGN_SEEN to the number of foreign workflows found.
SPORK_FOREIGN_SEEN=0
spork_disable_foreign_workflows() {
  local repo=$1 self=$2 self_id="" list runs id path state wf_id
  SPORK_FOREIGN_SEEN=0

  if ! list=$(gh api --paginate "repos/$repo/actions/workflows" \
    --jq '.workflows[] | [.id, .path, .state] | @tsv'); then
    spork_warn "could not list workflows of $repo (token needs Actions: read/write)"
    return 0
  fi

  while IFS=$'\t' read -r id path state; do
    [[ -n $id ]] || continue
    if [[ $path == "$self" ]]; then
      self_id=$id
      continue
    fi
    # Skip GitHub-managed "dynamic" workflows (Dependabot, Pages, ...).
    [[ $path == .github/workflows/* ]] || continue
    SPORK_FOREIGN_SEEN=$((SPORK_FOREIGN_SEEN + 1))
    [[ $state == active ]] || continue
    if gh api -X PUT "repos/$repo/actions/workflows/$id/disable" >/dev/null; then
      spork_log "disabled upstream workflow $path"
    else
      spork_warn "could not disable workflow $path"
    fi
  done <<<"$list"

  if ! runs=$(gh api "repos/$repo/actions/runs?per_page=100" \
    --jq '.workflow_runs[] | select(.status != "completed") | [.id, .workflow_id, .path] | @tsv'); then
    spork_warn "could not list workflow runs of $repo"
    return 0
  fi
  while IFS=$'\t' read -r id wf_id path; do
    [[ -n $id ]] || continue
    [[ $id == "${GITHUB_RUN_ID:-}" ]] && continue
    [[ -n $self_id && $wf_id == "$self_id" ]] && continue
    [[ ${path%%@*} == "$self" ]] && continue
    if gh api -X POST "repos/$repo/actions/runs/$id/cancel" >/dev/null 2>&1; then
      spork_log "cancelled upstream workflow run $id (${path%%@*})"
    fi
  done <<<"$runs"
}

# --- GitHub App authentication ----------------------------------------------

spork_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# spork_app_token APP_ID PRIVATE_KEY TARGET
# TARGET is owner/repo (token scoped to that repository) or an organization
# name (token for the org installation, covering repositories created later).
# Mints the installation token into SPORK_APP_TOKEN (a variable, not
# stdout, so the ::add-mask:: command reaches the runner before any use).
# APP_ID may be the numeric App ID or the App's client ID. Returns non-zero
# with a message on failure.
SPORK_APP_TOKEN=""
spork_app_token() {
  local app_id=$1 key=$2 repo=$3 now iss header payload sig jwt keyfile inst
  SPORK_APP_TOKEN=""
  command -v openssl >/dev/null || { spork_warn "openssl is required for GitHub App authentication"; return 1; }
  # Secrets pasted with literal "\n" instead of newlines.
  if [[ $key != *$'\n'* && $key == *'\n'* ]]; then key=${key//\\n/$'\n'}; fi

  now=$(date +%s)
  if [[ $app_id =~ ^[0-9]+$ ]]; then iss=$app_id; else iss="\"$app_id\""; fi
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | spork_b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":%s}' $((now - 60)) $((now + 540)) "$iss" | spork_b64url)
  keyfile=$(mktemp)
  chmod 600 "$keyfile"
  printf '%s\n' "$key" >"$keyfile"
  if ! sig=$(printf '%s.%s' "$header" "$payload" |
    openssl dgst -sha256 -sign "$keyfile" -binary 2>/dev/null | spork_b64url) || [[ -z $sig ]]; then
    rm -f "$keyfile"
    spork_warn "could not sign with the App private key (expected a PEM RSA key)"
    return 1
  fi
  rm -f "$keyfile"
  jwt="$header.$payload.$sig"
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then printf '::add-mask::%s\n' "$jwt"; fi

  local inst_path="repos/$repo" scope=(-f "repositories[]=${repo#*/}")
  if [[ $repo != */* ]]; then
    inst_path="orgs/$repo"
    scope=()
  fi
  if ! inst=$(GH_TOKEN=$jwt gh api -H "Authorization: Bearer $jwt" "$inst_path/installation" --jq .id); then
    spork_warn "GitHub App $app_id is not installed on $repo (or the key/ID is wrong)"
    return 1
  fi
  if ! SPORK_APP_TOKEN=$(GH_TOKEN=$jwt gh api -X POST -H "Authorization: Bearer $jwt" \
    "app/installations/$inst/access_tokens" "${scope[@]}" --jq .token) ||
    [[ -z $SPORK_APP_TOKEN ]]; then
    SPORK_APP_TOKEN=""
    spork_warn "could not create an installation token for $repo"
    return 1
  fi
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then printf '::add-mask::%s\n' "$SPORK_APP_TOKEN"; fi
}
