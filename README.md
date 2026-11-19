# spork

Private copies of public repositories that stay in sync with upstream.

GitHub won't let you fork a public repository and make the fork private. spork
creates a regular private repository holding the upstream history, and a small
scheduled workflow keeps a branch (`upstream` by default) mirrored to upstream.
You work on `main`; upstream changes arrive as a pull request (or are
fast-forwarded / merged, if you prefer).

```
upstream repo ──(spork-sync, scheduled)──▶ your-copy:upstream ──(PR / ff / merge)──▶ your-copy:main
```

## Create a private copy

### From your machine

Requires `git` and an authenticated [`gh`](https://cli.github.com/) (`gh auth login`).

```sh
SPORK_TOKEN=github_pat_... ./scripts/spork create owner/repo
./scripts/spork create owner/repo --name my-copy --on-update merge --dry-run
```

`scripts/spork --help` lists all options.

### From GitHub Actions

Copy [`templates/spork-create.yml`](templates/spork-create.yml) into a
**private** repository (Actions logs of public repositories are public), add
the `SPORK_ADMIN_TOKEN` and `SPORK_TOKEN` secrets, and run it from the Actions
tab. It uses the `Shardbyte/spork/create@v1` action.

### What `create` does

1. Fetches upstream's default branch (full history).
2. Creates the private repository and **disables Actions** on it.
3. Pushes upstream to `upstream`, and upstream + one commit adding
   `.github/workflows/spork-sync.yml` to `main` (the default branch).
4. Re-enables Actions, allowing only `Shardbyte/spork` actions and read-only
   default `GITHUB_TOKEN` permissions.
5. Disables all of upstream's workflows, so they never use your Actions minutes.
6. Stores `SPORK_TOKEN` as a repository secret.

## The sync action

```yaml
- uses: Shardbyte/spork@v1
  with:
    upstream-url: owner/repo
    token: ${{ secrets.SPORK_TOKEN }}
```

| Input | Default | |
|---|---|---|
| `upstream-url` | — | `owner/repo` or a git URL |
| `upstream-branch` | upstream's default | branch to mirror |
| `target-branch` | `upstream` | mirror branch here; force-updated, don't commit to it |
| `base-branch` | repo default | branch that receives updates |
| `on-update` | `pr` | `pr`, `none`, `fast-forward`, `merge` (see below) |
| `sync-tags` | `false` | push upstream tags missing here; never moves existing tags |
| `disable-upstream-workflows` | `true` | disable all other workflows and cancel their pending runs |
| `token` | — | see [Tokens](#tokens) |

`on-update` modes:

- **pr**: open a pull request `upstream` → `main`, or update the open one.
- **none**: only update the `upstream` branch.
- **fast-forward**: move `main` to upstream when `main` has no commits of its
  own. Because `create` adds the sync workflow commit to `main`, this usually
  falls back to **pr**. It's useful when the workflow lives elsewhere.
- **merge**: create a merge commit on `main` when it merges cleanly, otherwise
  fall back to **pr**.

Outputs: `changed`, `result` (`unchanged`, `updated`, `pr-opened`,
`pr-updated`, `fast-forwarded`, `merged`), `upstream-sha`, `previous-sha`,
`commits`, `forced`, `pr-url`.

If upstream rewrites its history, `upstream` is force-updated to match
(`forced=true`); `main` is never force-pushed.

## Runners

The sync job defaults to `ubuntu-latest`. To avoid using GitHub-hosted minutes, pass
`--runs-on self-hosted` (or a label list such as `"[self-hosted, linux]"`) to
`spork create`. A self-hosted runner needs `bash`, `git` (2.38+ for `merge`
mode), `gh`, `awk` and `base64`. Without `gh` the sync fails rather than
silently skipping upstream-workflow disabling or PR creation.

Caution: upstream workflows that target `self-hosted` could run on your machine
in the short window before spork disables them (see below). Use a dedicated,
unprivileged runner for spork repositories.

## Tokens

The default `GITHUB_TOKEN` can't push commits that modify `.github/workflows/`,
which nearly every upstream does, so syncing needs its own token.

**Personal access token (fine-grained)**, scoped to the private copies:

| Token | Permissions (read and write) |
|---|---|
| `SPORK_TOKEN` (sync) | Contents, Workflows, Pull requests, Actions |
| `SPORK_ADMIN_TOKEN` (create) | Administration, Contents, Workflows, Actions, Secrets; *All repositories* so it can create new ones |

**GitHub App installation token**: planned; any token with the same
permissions works with the `token` input.

## Upstream workflows and your Actions minutes

Upstream's workflow files are present on `upstream` (and on `main` once
merged). Pushes made with a personal or App token trigger workflows, so spork:

- creates the repository with Actions disabled while pushing history,
- disables every upstream workflow after creation and on every sync,
- cancels any of their runs that are queued or running.

A workflow file that upstream adds *later* can run once (on the sync push)
before the same sync run disables it and cancels the run.

## Development

```sh
./test/run.sh                  # local tests (bare repos + stub gh)
shellcheck -x scripts/*.sh scripts/spork test/run.sh
```
