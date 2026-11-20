# spork step-by-step guide

This guide walks you through making your first private copy of a public
repository with spork, and keeping it up to date. It takes about 15 minutes.
For every option and detail, see the [README](../README.md).

**What you'll end up with:** a private repository with two branches:

- `upstream` — an exact mirror of the public repository, updated
  automatically every 6 hours. Don't commit to it.
- `main` — your branch. When upstream changes, spork opens a pull request
  into `main` for you to review and merge.

```
public repo ──(every 6 h)──▶ your-copy: upstream ──(pull request)──▶ your-copy: main
```

---

## Step 1 — Install the tools

You need `git` and the GitHub CLI `gh` on your computer.

1. Install `gh`: see <https://cli.github.com> (for example `sudo apt install gh`
   on Debian/Ubuntu, `brew install gh` on macOS).
2. Sign in:

   ```sh
   gh auth login
   ```

   Choose **GitHub.com**, **HTTPS**, and log in with a web browser.
   If you'll create copies in an organization you administer, also run
   `gh auth refresh -s admin:org` so spork can check the org's settings.
3. Download spork:

   ```sh
   git clone https://github.com/Shardbyte/spork.git
   cd spork
   ```

---

## Step 2 — Choose how the sync logs in

The automatic sync needs its own credential, because GitHub's built-in
workflow token isn't allowed to push changes to workflow files, and almost
every project has some. Pick one:

| | **A. Personal access token** | **B. GitHub App** |
|---|---|---|
| Best for | one or two copies | many copies, or an organization |
| Setup | 2 minutes | 5 minutes, once |
| Expires | when you choose (must be renewed) | never; nothing to renew |
| Shows up as | you | the App (e.g. `my-sync[bot]`) |

Follow **Step 3A** *or* **Step 3B**, then continue with Step 4.

---

## Step 3A — Create the copy (personal access token)

1. **Preview** what spork will do (nothing is created):

   ```sh
   ./scripts/spork create OWNER/REPO --dry-run
   ```

   Replace `OWNER/REPO` with the public repository, e.g.
   `actions/hello-world-javascript-action`. Add `--name my-copy` to choose a
   different name, or `--owner my-org` to create it in an organization.

2. **Create** the copy:

   ```sh
   ./scripts/spork create OWNER/REPO
   ```

   At the end you'll see a warning that `SPORK_TOKEN` is not set. That's
   expected; you'll add it next. Note the repository name it printed
   (`repository=you/REPO`).

3. **Make a token** that only works on the new copy. On GitHub go to
   **Settings → Developer settings → Personal access tokens → Fine-grained
   tokens → Generate new token**, then:
   - **Token name:** e.g. `spork REPO`
   - **Resource owner:** you (or the organization the copy is in)
   - **Expiration:** your choice. Set a reminder; the sync stops when it
     expires.
   - **Repository access:** *Only select repositories* → pick your new copy
   - **Permissions → Repository permissions**, set to **Read and write**:
     **Actions**, **Contents**, **Pull requests**, **Workflows**
   - Click **Generate token** and copy it.

4. **Store the token** in the copy. This command asks you to paste it, so
   it doesn't end up in your shell history:

   ```sh
   gh secret set SPORK_TOKEN -R YOU/REPO
   ```

Continue with [Step 4](#step-4--choose-where-the-sync-runs).

---

## Step 3B — Create the copy (GitHub App)

You create the App once and reuse it for every copy.

1. **Create the App.** On GitHub go to **Settings → Developer settings →
   GitHub Apps → New GitHub App** (for an organization: the org's
   **Settings → Developer settings → GitHub Apps**). Fill in:
   - **GitHub App name:** anything, e.g. `yourname-spork-sync`
   - **Homepage URL:** anything, e.g. `https://github.com/Shardbyte/spork`
   - **Webhook:** untick **Active**
   - **Repository permissions**, set to **Read and write**:
     **Actions**, **Contents**, **Pull requests**, **Workflows**
   - *Organizations only, optional:* also **Administration**, **Secrets** and
     **Variables** (read and write). This lets spork create copies as the
     App, without your personal login (`--admin-auth app` below).
   - **Where can this GitHub App be installed?** *Only on this account*
   - Click **Create GitHub App**.

2. **Note the App ID** shown at the top of the App's page (a number such as
   `123456`).

3. **Generate a private key:** on the same page, under **Private keys**, click
   **Generate a private key**. A `.pem` file downloads. Keep it somewhere
   safe and private:

   ```sh
   chmod 600 ~/Downloads/your-app.*.private-key.pem
   ```

4. **Install the App:** in the left menu click **Install App**, choose your
   account (or organization), select **All repositories**, and confirm.
   *All repositories* means future copies work without extra steps.

5. **Create the copy:**

   ```sh
   SPORK_APP_ID=123456 \
   SPORK_APP_PRIVATE_KEY_FILE=~/Downloads/your-app.private-key.pem \
     ./scripts/spork create OWNER/REPO --auth app
   ```

   Add `--dry-run` first if you want a preview. spork stores the App ID and
   key in the new copy and finishes with
   `verified: GitHub App 123456 can access ...`.

   **In an organization**, add `--owner my-org`. If you gave the App the
   optional permissions in step 1, you can also add `--admin-auth app` so
   the App creates the repository instead of your personal account.

---

## Step 4 — Choose where the sync runs

By default the sync runs on GitHub's own machines (`ubuntu-latest`). For a
private repository that uses your account's included Actions minutes. A sync
takes well under a minute.

**Using your own runner instead** (no minutes used): add
`--runs-on '[self-hosted, linux]'` to the `create` command in Step 3. The
runner machine needs `git`, `gh`, `bash`, `awk`, `base64` and, for the App
option, `openssl`. It does *not* need to be logged in to `gh`.

> **Note:** If you have several copies, put them in an organization and
> register the runner on the organization. Then every copy can use it
> without registering the runner on each repository.

Already created the copy? Change the `runs-on:` line in
`.github/workflows/spork-sync.yml` on `main` instead.

---

## Step 5 — Check that it works

1. Run the sync once by hand:

   ```sh
   gh workflow run spork-sync.yml -R YOU/REPO
   gh run watch -R YOU/REPO
   ```

   (`gh run watch` asks which run; pick the newest.)

2. It should finish with a green check. The log ends with
   `spork: result=unchanged`, because the copy is brand new.

3. On the copy's **Actions** tab, only **spork-sync** should be listed as
   active. spork disabled all of the original project's workflows so they
   don't use your minutes or runners.

That's it. From now on the sync runs every 6 hours.

---

## Day to day

- **Work on `main`** (or branches off it), as in any repository.
- **When upstream changes**, a pull request titled
  *Sync upstream main @ 1a2b3c…* appears. Review it and merge it with
  **Create a merge commit**.
  - Don't use *Squash* or *Rebase*: `main` would no longer contain upstream's
    real commits, so every later sync PR would show them again and conflict.
  - Don't click **Delete branch** after merging. The `upstream` branch must
    stay.
- **Never commit to `upstream`.** The sync overwrites it to match the
  original exactly.
- **Want a different behaviour?** Edit `on-update:` in
  `.github/workflows/spork-sync.yml` on `main`:
  - `pr` (default): open a pull request
  - `merge`: merge automatically when there are no conflicts, otherwise open
    a pull request
  - `none`: only update the `upstream` branch
- **Want a different schedule?** Edit the `cron:` line in the same file
  (e.g. `"0 3 * * *"` for daily at 03:00 UTC).

---

## Troubleshooting

Open the failed run on the copy's **Actions** tab and look for a line
starting with `spork:` or an error annotation.

| You see | What to do |
|---|---|
| *The job was not started because recent account payments have failed or your spending limit needs to be increased* | GitHub won't run hosted jobs on your account. Fix billing, or use your own runner (Step 4). |
| *the GitHub CLI (gh) is required …* | Install `gh` on your self-hosted runner. |
| *set either token, or app-id and app-private-key* | The copy has no credentials. Do Step 3A.4, or for the App: `gh variable set SPORK_APP_ID -R YOU/REPO --body 123456` and `gh secret set SPORK_APP_PRIVATE_KEY -R YOU/REPO < key.pem`. On GitHub Free, private repositories can't use organization-level secrets, so set them on the repository. |
| *GitHub App … is not installed on YOU/REPO* | Install the App on that repository (Step 3B.4), or switch the installation to *All repositories*. |
| *refusing to allow … to create or update workflow* | The token lacks **Workflows: Read and write**. Edit the token or App permissions. With an App, also approve the updated permissions on the installation. |
| *Bad credentials*, *Authentication failed* or *401* | The token expired or was revoked. Make a new one and run `gh secret set SPORK_TOKEN -R YOU/REPO` again. |
| *… already exists* (when creating) | A repository with that name exists. Use `--name another-name`. |
| *… allowed actions don't include Shardbyte/spork* | Your organization restricts Actions. In the org's **Settings → Actions → General**, allow `Shardbyte/spork@*`. |
| The sync PR has conflicts | You changed the same lines as upstream. Resolve them like any pull request, e.g. in the GitHub web editor. |

---

## Removing a copy

Delete it like any repository: the copy's **Settings → General → Danger
Zone → Delete this repository**. With an App, nothing else needs cleaning
up. With a personal access token, also delete the token under **Settings →
Developer settings → Personal access tokens**.
