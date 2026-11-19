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
| `token` | — | personal (or any) token; see [Tokens](#tokens) |
| `app-id`, `app-private-key` | — | GitHub App instead of `token` |

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
mode), `gh`, `awk`, `base64`, and `openssl` for GitHub App auth. Without `gh` the sync fails rather than
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

**GitHub App** (recommended for many repositories): no personal token to
rotate, and pushes and PRs are attributed to the App. Create an App with the
repository permissions **Contents**, **Workflows**, **Pull requests** and
**Actions** (read and write), generate a private key, and install it on the
private copies (installing on *All repositories* covers future copies too).

```sh
SPORK_APP_ID=123456 SPORK_APP_PRIVATE_KEY_FILE=app.pem ./scripts/spork create owner/repo --auth app
```

This stores the `SPORK_APP_ID` variable and `SPORK_APP_PRIVATE_KEY` secret and
checks that the App can access the new repository. The sync workflow then uses:

```yaml
- uses: Shardbyte/spork@v1
  with:
    upstream-url: owner/repo
    app-id: ${{ vars.SPORK_APP_ID }}
    app-private-key: ${{ secrets.SPORK_APP_PRIVATE_KEY }}
```

Each run signs a short-lived JWT with `openssl` and exchanges it for an
installation token scoped to the one repository, without extra actions (which
the Actions allowlist would block). `app-id` may be the numeric App ID or the
client ID. Creating repositories still needs a personal token: Apps can't
create repositories in a personal account.

## Organizations

`spork create --owner <org>` creates the copy in an organization, which lets
all copies share the org's self-hosted runners (runner group with access to
all repositories).

- **Actions policy:** before creating anything, `create` checks the org's
  Actions policy (needs org admin) and stops if it would block spork. Allow
  `Shardbyte/spork@*` if the org restricts actions; if Actions is enabled
  only for selected repositories, the new copy is added.
- **App-only creation:** with the App installed on the org and given
  **Administration**, **Secrets** and **Variables** (read and write) in
  addition to the sync permissions, no personal token is needed:

  ```sh
  SPORK_APP_ID=123456 SPORK_APP_PRIVATE_KEY_FILE=app.pem \
    ./scripts/spork create owner/repo --owner my-org --auth app --admin-auth app
  ```

  An App can't read org-level policy, so the policy check is skipped then.
- **Org-level credentials:** on paid plans, `SPORK_APP_ID` /
  `SPORK_APP_PRIVATE_KEY` / `SPORK_TOKEN` set once at org level are used
  instead of per-repository copies. On **GitHub Free**, private repositories
  can't read org-level secrets or variables, so `create` always stores them
  in the repository.
- **Shared runners:** every repository in the runner group can use them, and
  an upstream workflow targeting `self-hosted` could run before spork disables
  it. Prefer dedicated, unprivileged runners for spork copies.

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
