#!/usr/bin/env bash
# spork sync — mirror an upstream branch into a branch of this repository,
# then optionally propose (PR) or apply (fast-forward / merge) the update to
# the base branch. Configured through SPORK_* environment variables; see
# action.yml for their meaning.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$here/lib.sh"

UPSTREAM_URL=${SPORK_UPSTREAM_URL:-}
UPSTREAM_BRANCH=${SPORK_UPSTREAM_BRANCH:-}
TARGET=${SPORK_TARGET_BRANCH:-upstream}
BASE=${SPORK_BASE_BRANCH:-}
ON_UPDATE=${SPORK_ON_UPDATE:-pr}
SYNC_TAGS=${SPORK_SYNC_TAGS:-false}
DISABLE_WF=${SPORK_DISABLE_UPSTREAM_WORKFLOWS:-true}
REPO=${SPORK_REPO:-${GITHUB_REPOSITORY:-}}
ORIGIN_URL=${SPORK_ORIGIN_URL:-}
SELF_WF=${SPORK_SELF_WORKFLOW:-}

[[ -n $UPSTREAM_URL ]] || spork_die "upstream-url is required"
UPSTREAM_URL=$(spork_normalize_url "$UPSTREAM_URL")
case $ON_UPDATE in
  none | pr | fast-forward | merge) ;;
  *) spork_die "on-update must be one of: none, pr, fast-forward, merge (got '$ON_UPDATE')" ;;
esac
if [[ -z $ORIGIN_URL ]]; then
  [[ -n $REPO ]] || spork_die "cannot determine this repository (GITHUB_REPOSITORY unset)"
  ORIGIN_URL="${GITHUB_SERVER_URL:-https://github.com}/$REPO.git"
fi
if [[ -z $SELF_WF && -n ${GITHUB_WORKFLOW_REF:-} ]]; then
  SELF_WF=${GITHUB_WORKFLOW_REF#"$REPO"/}
  SELF_WF=${SELF_WF%%@*}
fi
SELF_WF=${SELF_WF:-.github/workflows/spork-sync.yml}

spork_set_auth "${SPORK_TOKEN:-}"

gh_ok=false
if [[ -n $REPO ]] && spork_have_gh; then gh_ok=true; fi

# ---------------------------------------------------------------------------
# Resolve branches and current state.

if [[ -z $UPSTREAM_BRANCH ]]; then
  UPSTREAM_BRANCH=$(spork_default_branch git "$UPSTREAM_URL")
  [[ -n $UPSTREAM_BRANCH ]] || spork_die "could not determine default branch of $UPSTREAM_URL"
fi
if [[ $ON_UPDATE != none && -z $BASE ]]; then
  BASE=$(spork_default_branch ogit "$ORIGIN_URL")
  [[ -n $BASE ]] || spork_die "could not determine default branch of this repository"
fi
if [[ $ON_UPDATE != none && $BASE == "$TARGET" ]]; then
  spork_die "base-branch and target-branch are both '$TARGET'"
fi

if [[ $DISABLE_WF == true ]]; then
  if $gh_ok; then
    spork_disable_foreign_workflows "$REPO" "$SELF_WF"
  else
    spork_warn "gh unavailable; not disabling upstream workflows"
  fi
fi

upstream_sha=$(spork_remote_sha git "$UPSTREAM_URL" "refs/heads/$UPSTREAM_BRANCH")
[[ -n $upstream_sha ]] || spork_die "branch '$UPSTREAM_BRANCH' not found in $UPSTREAM_URL"
previous_sha=$(spork_remote_sha ogit "$ORIGIN_URL" "refs/heads/$TARGET")

result=unchanged
commits=0
forced=false
pr_url=""
work=""

cleanup() { if [[ -n $work ]]; then rm -rf "$work"; fi; }
trap cleanup EXIT

workdir() {
  if [[ -z $work ]]; then
    work=$(mktemp -d)
    git init -q --bare "$work"
  fi
}

# ---------------------------------------------------------------------------
# Applying updates to the base branch.

ensure_pr() {
  if ! $gh_ok; then
    spork_warn "gh unavailable; cannot open a pull request"
    return 0
  fi
  local short=${upstream_sha:0:12} num title body ahead
  title="Sync upstream $UPSTREAM_BRANCH @ $short"
  num=$(gh pr list -R "$REPO" --head "$TARGET" --base "$BASE" --state open \
    --json number --jq '.[0].number // empty')
  if [[ -n $num ]]; then
    gh pr edit "$num" -R "$REPO" --title "$title" >/dev/null
    pr_url=$(gh pr view "$num" -R "$REPO" --json url --jq .url)
    spork_log "updated pull request $pr_url"
    [[ $result == unchanged ]] || result=pr-updated
    return 0
  fi
  ahead=$(gh api "repos/$REPO/compare/$BASE...$TARGET" --jq .ahead_by)
  if [[ ${ahead:-0} -eq 0 ]]; then
    spork_log "'$BASE' already contains '$TARGET'; no pull request needed"
    return 0
  fi
  body=$(printf '%s\n' \
    "Brings \`$BASE\` up to date with upstream." \
    "" \
    "| | |" \
    "|---|---|" \
    "| Upstream | $UPSTREAM_URL |" \
    "| Branch | \`$UPSTREAM_BRANCH\` → \`$TARGET\` |" \
    "| Commit | \`$upstream_sha\` |" \
    "| Commits ahead of \`$BASE\` | $ahead |" \
    "" \
    "_Opened by [spork](https://github.com/$SPORK_ACTION_REPO). New commits are added to this PR automatically._")
  pr_url=$(gh pr create -R "$REPO" --head "$TARGET" --base "$BASE" --title "$title" --body "$body")
  spork_log "opened pull request $pr_url"
  result=pr-opened
}

apply_to_base() {
  workdir
  ogit --git-dir="$work" fetch -q --no-tags "$ORIGIN_URL" "+refs/heads/$BASE:refs/spork/base"
  local base_sha out tree merge
  base_sha=$(git --git-dir="$work" rev-parse refs/spork/base)

  if git --git-dir="$work" merge-base --is-ancestor "$upstream_sha" "$base_sha"; then
    spork_log "'$BASE' already contains upstream"
    return 0
  fi
  if git --git-dir="$work" merge-base --is-ancestor "$base_sha" "$upstream_sha"; then
    ogit --git-dir="$work" push -q --force-with-lease="refs/heads/$BASE:$base_sha" \
      "$ORIGIN_URL" "$upstream_sha:refs/heads/$BASE"
    spork_log "fast-forwarded '$BASE' to $upstream_sha"
    result=fast-forwarded
    return 0
  fi
  if [[ $ON_UPDATE == merge ]]; then
    if out=$(git --git-dir="$work" merge-tree --write-tree "$base_sha" "$upstream_sha" 2>/dev/null); then
      tree=${out%%$'\n'*}
      spork_ensure_identity
      merge=$(git --git-dir="$work" commit-tree "$tree" -p "$base_sha" -p "$upstream_sha" \
        -m "Merge upstream $UPSTREAM_BRANCH (${upstream_sha:0:12}) into $BASE")
      ogit --git-dir="$work" push -q --force-with-lease="refs/heads/$BASE:$base_sha" \
        "$ORIGIN_URL" "$merge:refs/heads/$BASE"
      spork_log "merged upstream into '$BASE' as $merge"
      result=merged
      return 0
    fi
    spork_warn "upstream does not merge cleanly into '$BASE'; falling back to a pull request"
  else
    spork_warn "'$BASE' has diverged from upstream and cannot be fast-forwarded; falling back to a pull request"
  fi
  ensure_pr
}

# ---------------------------------------------------------------------------
# Main.

if [[ $upstream_sha == "$previous_sha" ]]; then
  spork_log "'$TARGET' is up to date with $UPSTREAM_URL $UPSTREAM_BRANCH ($upstream_sha)"
  # Re-check in case a previous run pushed but failed to open the PR.
  if [[ $ON_UPDATE == pr ]]; then ensure_pr; fi
else
  workdir
  spork_log "fetching $UPSTREAM_URL $UPSTREAM_BRANCH"
  git --git-dir="$work" fetch -q --no-tags "$UPSTREAM_URL" "+refs/heads/$UPSTREAM_BRANCH:refs/spork/upstream"
  upstream_sha=$(git --git-dir="$work" rev-parse refs/spork/upstream)

  if [[ -z $previous_sha ]]; then
    commits=$(git --git-dir="$work" rev-list --count "$upstream_sha")
  elif git --git-dir="$work" cat-file -e "$previous_sha^{commit}" 2>/dev/null &&
    git --git-dir="$work" merge-base --is-ancestor "$previous_sha" "$upstream_sha"; then
    commits=$(git --git-dir="$work" rev-list --count "$previous_sha..$upstream_sha")
  else
    forced=true
    commits=$(git --git-dir="$work" rev-list --count "$upstream_sha")
    spork_warn "upstream history was rewritten; force-updating '$TARGET'"
  fi

  ogit --git-dir="$work" push -q --force-with-lease="refs/heads/$TARGET:$previous_sha" \
    "$ORIGIN_URL" "$upstream_sha:refs/heads/$TARGET"
  spork_log "updated '$TARGET' ${previous_sha:-(new)} -> $upstream_sha ($commits commits)"
  result=updated

  case $ON_UPDATE in
    pr) ensure_pr ;;
    fast-forward | merge) apply_to_base ;;
  esac
fi

# Tags: push upstream tags this repository doesn't have. Existing tags are
# never moved.
new_tags=0
if [[ $SYNC_TAGS == true ]]; then
  mapfile -t tags < <(comm -23 \
    <(git ls-remote --tags --refs "$UPSTREAM_URL" | awk '{ print $2 }' | sort) \
    <(ogit ls-remote --tags --refs "$ORIGIN_URL" | awk '{ print $2 }' | sort))
  if ((${#tags[@]})); then
    workdir
    for t in "${tags[@]}"; do printf '+%s:%s\n' "$t" "$t"; done |
      git --git-dir="$work" fetch -q --no-tags --stdin "$UPSTREAM_URL"
    for t in "${tags[@]}"; do printf '%s:%s\n' "$t" "$t"; done |
      xargs -r -n 200 git "${GIT_AUTH[@]}" --git-dir="$work" push -q "$ORIGIN_URL"
    new_tags=${#tags[@]}
    spork_log "pushed $new_tags new tag(s)"
  fi
fi

# Late cleanup: catch workflows/runs created by this run's pushes.
if [[ $DISABLE_WF == true && $gh_ok == true && $result != unchanged ]]; then
  sleep "${SPORK_SETTLE_SECONDS:-10}"
  spork_disable_foreign_workflows "$REPO" "$SELF_WF"
fi

changed=false
[[ $result == unchanged ]] || changed=true

spork_output changed "$changed"
spork_output result "$result"
spork_output upstream-branch "$UPSTREAM_BRANCH"
spork_output upstream-sha "$upstream_sha"
spork_output previous-sha "$previous_sha"
spork_output commits "$commits"
spork_output forced "$forced"
spork_output new-tags "$new_tags"
spork_output pr-url "$pr_url"

spork_summary "### spork sync: \`$result\`"
spork_summary ""
spork_summary "| | |"
spork_summary "|---|---|"
spork_summary "| Upstream | $UPSTREAM_URL \`$UPSTREAM_BRANCH\` |"
spork_summary "| \`$TARGET\` | \`${previous_sha:-none}\` → \`$upstream_sha\` |"
rewritten=""
[[ $forced == false ]] || rewritten=" (history rewritten)"
spork_summary "| New commits | $commits$rewritten |"
spork_summary "| New tags | $new_tags |"
if [[ -n $pr_url ]]; then spork_summary "| Pull request | $pr_url |"; fi
