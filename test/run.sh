#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # check() evals its single-quoted conditions
# Local tests for scripts/sync.sh using bare repositories as "upstream" and
# "origin", and a stub gh that records its calls.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# Like many real setups: bare repos must be addressed with --git-dir.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=explicit
# Running inside Actions must not leak into the tests.
unset GH_TOKEN
while read -r v; do unset "$v"; done < <(compgen -e GITHUB_)

# --- stub gh ---------------------------------------------------------------
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
[[ $2 != --paginate ]] || set -- "$1" "${@:3}"
case "$1 $2" in
  "pr list") [[ -z ${STUB_PR_NUMBER:-} ]] || printf '%s https://github.com/test/repo/pull/%s\n' "$STUB_PR_NUMBER" "$STUB_PR_NUMBER" ;;
  "pr create") printf 'https://github.com/test/repo/pull/99\n' ;;
  "api repos/test/repo/compare/"*) printf '%s\n' "${STUB_AHEAD:-1}" ;;
  "api repos/test/repo/actions/workflows") printf '%b' "${STUB_WORKFLOWS:-}" ;;
  "api repos/test/repo/actions/runs?per_page=100") printf '%b' "${STUB_RUNS:-}" ;;
  *) ;;
esac
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log"

# --- helpers ---------------------------------------------------------------
pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

up="$tmp/upstream.git" origin="$tmp/origin.git" wt="$tmp/wt"

# commit_up FILE CONTENT — commit to upstream main.
commit_up() {
  printf '%s\n' "$2" >"$wt/$1"
  git -C "$wt" add -A
  git -C "$wt" commit -qm "change $1"
  git -C "$wt" push -q origin HEAD:main
}

ref() { git --git-dir="$1" rev-parse --verify -q "refs/heads/$2" || true; }

# sync [ENV=VALUE...] — run sync.sh, outputs in $out.
out="$tmp/out"
sync() {
  : >"$out" && : >"$GH_LOG"
  env SPORK_UPSTREAM_URL="$up" SPORK_ORIGIN_URL="$origin" SPORK_REPO=test/repo \
    SPORK_DISABLE_UPSTREAM_WORKFLOWS=false SPORK_SETTLE_SECONDS=0 \
    GITHUB_OUTPUT="$out" "$@" "$root/scripts/sync.sh" 2>"$tmp/stderr" ||
    { cat "$tmp/stderr"; return 1; }
}
o() { awk -F= -v k="$1" '$1 == k { sub("^[^=]*=", ""); print }' "$out"; }

setup() {
  rm -rf "$up" "$origin" "$wt"
  git init -q --bare -b main "$up"
  git init -q --bare -b main "$origin"
  git init -q -b main "$wt"
  git -C "$wt" remote add origin "$up"
  mkdir -p "$wt/.github/workflows"
  printf 'on: push\n' >"$wt/.github/workflows/ci.yml"
  commit_up a.txt one
  # origin main = upstream + spork commit, like the bootstrap produces.
  git -C "$wt" push -q "$origin" main:main
  git clone -q "$origin" "$tmp/o" && (
    cd "$tmp/o"
    printf 'sync\n' >spork.yml
    git add -A && git commit -qm spork && git push -q origin main
  ) && rm -rf "$tmp/o"
}

# --- tests -----------------------------------------------------------------
echo "first sync creates target branch (base already contains upstream: no PR)"
setup
STUB_AHEAD=0 sync
check "target created at upstream tip" '[[ $(ref "$origin" upstream) == $(ref "$up" main) ]]'
check "result=updated" '[[ $(o result) == updated ]]'
check "commits counted" '[[ $(o commits) == 1 ]]'
check "previous-sha empty" '[[ -z $(o previous-sha) ]]'

echo "no upstream change"
STUB_AHEAD=0 sync
check "result=unchanged" '[[ $(o result) == unchanged ]]'
check "changed=false" '[[ $(o changed) == false ]]'
check "no PR created" '! grep -q "pr create" "$GH_LOG"'

echo "upstream advances, pr mode opens PR"
commit_up b.txt two
commit_up .github/workflows/ci.yml 'on: [push, pull_request]'
sync
check "target updated" '[[ $(ref "$origin" upstream) == $(ref "$up" main) ]]'
check "2 new commits" '[[ $(o commits) == 2 ]]'
check "PR created upstream->main" 'grep -q "pr create -R test/repo --head upstream --base main" "$GH_LOG"'
check "result=pr-opened" '[[ $(o result) == pr-opened ]]'
check "pr-url output" '[[ $(o pr-url) == https://github.com/test/repo/pull/99 ]]'

echo "existing PR is updated, not duplicated"
commit_up c.txt three
STUB_PR_NUMBER=7 sync
check "no new PR" '! grep -q "pr create" "$GH_LOG"'
check "PR title updated" 'grep -q "api -X PATCH repos/test/repo/pulls/7" "$GH_LOG"'
check "existing pr-url output" '[[ $(o pr-url) == https://github.com/test/repo/pull/7 ]]'
check "result=pr-updated" '[[ $(o result) == pr-updated ]]'

echo "unchanged but PR missing gets reconciled"
STUB_AHEAD=3 sync
check "PR created on unchanged run" 'grep -q "pr create" "$GH_LOG"'
check "result=pr-opened" '[[ $(o result) == pr-opened ]]'

echo "upstream force-push is mirrored"
git -C "$wt" reset -q --hard HEAD~2
printf 'rewritten\n' >"$wt/d.txt"
git -C "$wt" add -A && git -C "$wt" commit -qm rewrite
git -C "$wt" push -q -f origin HEAD:main
sync SPORK_ON_UPDATE=none
check "target force-updated" '[[ $(ref "$origin" upstream) == $(ref "$up" main) ]]'
check "forced=true" '[[ $(o forced) == true ]]'
check "none mode: no gh pr calls" '! grep -q "^pr " "$GH_LOG"'

echo "fast-forward when base hasn't diverged"
setup
git -C "$wt" push -q -f "$origin" main:main # origin main == upstream (no spork commit)
sync SPORK_ON_UPDATE=none
commit_up e.txt five
sync SPORK_ON_UPDATE=fast-forward
check "main fast-forwarded" '[[ $(ref "$origin" main) == $(ref "$up" main) ]]'
check "result=fast-forwarded" '[[ $(o result) == fast-forwarded ]]'

echo "fast-forward falls back to PR when base diverged"
setup
sync SPORK_ON_UPDATE=none
commit_up f.txt six
main_before=$(ref "$origin" main)
sync SPORK_ON_UPDATE=fast-forward
check "main untouched" '[[ $(ref "$origin" main) == "$main_before" ]]'
check "fell back to PR" '[[ $(o result) == pr-opened ]]'

echo "unchanged run still merges a base that is behind"
setup
sync SPORK_ON_UPDATE=none
commit_up h.txt eight
sync SPORK_ON_UPDATE=none
STUB_AHEAD=1 sync SPORK_ON_UPDATE=merge
check "result=merged without upstream change" '[[ $(o result) == merged ]]'
STUB_AHEAD=0 sync SPORK_ON_UPDATE=merge
check "then unchanged" '[[ $(o result) == unchanged ]]'

echo "merge mode merges cleanly diverged base"
commit_up g.txt seven
sync SPORK_ON_UPDATE=merge
check "result=merged" '[[ $(o result) == merged ]]'
check "merge commit has 2 parents" '[[ $(git --git-dir="$origin" rev-list --parents -n1 main | wc -w) == 3 ]]'
check "main contains upstream" 'git --git-dir="$origin" merge-base --is-ancestor "$(ref "$origin" upstream)" "$(ref "$origin" main)"'
check "main keeps spork commit" '[[ -n $(git --git-dir="$origin" ls-tree main spork.yml) ]]'

echo "merge mode falls back to PR on conflict"
git clone -q "$origin" "$tmp/o2"
(cd "$tmp/o2" && printf 'mine\n' >a.txt && git commit -qam local && git push -q origin main)
rm -rf "$tmp/o2"
commit_up a.txt theirs
main_before=$(ref "$origin" main)
sync SPORK_ON_UPDATE=merge
check "main untouched on conflict" '[[ $(ref "$origin" main) == "$main_before" ]]'
check "fell back to PR" '[[ $(o result) == pr-opened ]]'

echo "tags are mirrored without moving existing ones"
setup
git -C "$wt" tag v1 && git -C "$wt" tag v2 && git -C "$wt" push -q origin v1 v2
git --git-dir="$origin" update-ref refs/tags/v1 "$(ref "$origin" main)"
sync SPORK_SYNC_TAGS=true SPORK_ON_UPDATE=none
check "new tag v2 pushed" '[[ -n $(git --git-dir="$origin" rev-parse -q --verify refs/tags/v2) ]]'
check "existing v1 untouched" '[[ $(git --git-dir="$origin" rev-parse refs/tags/v1) == $(ref "$origin" main) ]]'
check "new-tags=1" '[[ $(o new-tags) == 1 ]]'

echo "foreign workflows disabled and their runs cancelled"
STUB_WORKFLOWS='1\t.github/workflows/spork-sync.yml\tactive\n2\t.github/workflows/ci.yml\tactive\n3\tdynamic/pages\tactive\n4\t.github/workflows/old.yml\tdisabled_manually\n' \
  STUB_RUNS='100\t2\t.github/workflows/ci.yml@refs/heads/upstream\n101\t1\t.github/workflows/spork-sync.yml@refs/heads/main\n' \
  STUB_AHEAD=0 sync SPORK_DISABLE_UPSTREAM_WORKFLOWS=true
check "ci.yml disabled" 'grep -q "actions/workflows/2/disable" "$GH_LOG"'
check "self not disabled" '! grep -q "actions/workflows/1/disable" "$GH_LOG"'
check "dynamic skipped" '! grep -q "actions/workflows/3/disable" "$GH_LOG"'
check "already disabled skipped" '! grep -q "actions/workflows/4/disable" "$GH_LOG"'
check "foreign run cancelled" 'grep -q "actions/runs/100/cancel" "$GH_LOG"'
check "own run kept" '! grep -q "actions/runs/101/cancel" "$GH_LOG"'

echo "input validation"
check "bad on-update rejected" '! sync SPORK_ON_UPDATE=bogus >/dev/null 2>&1'
check "missing upstream branch rejected" '! sync SPORK_UPSTREAM_BRANCH=nope >/dev/null 2>&1'

echo
echo "$pass passed, $fail failed"
((fail == 0))
