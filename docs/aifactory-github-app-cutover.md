# AIFactory GitHub App cutover (AIFactory#1973, #1700, #1701)

Replaced the fleet PAT (`factory-secrets/GITHUB_TOKEN`, admin and `delete_repo` scopes) with an owner-managed GitHub App. This page is the verified runbook, done on 2026-11-17. The generic, user-facing guide is the AIFactory page: <https://aifactory.freundcloud.com/concepts/github-app>. This page holds only what is specific to this deployment.

## This deployment's values (examples, not secrets)

| Item | Value |
|---|---|
| App id | `5797279` |
| Installation id | `182861497` |
| Secret | `factory-secrets`, keys `AIFACTORY_GITHUB_APP_ID`, `AIFACTORY_GITHUB_APP_INSTALLATION_ID`, `AIFACTORY_GITHUB_APP_PRIVATE_KEY` |
| Secret source | agenix (keep the three keys there so a rebuild keeps them) |

The private key is never in git. Keep it in a password manager and delete loose copies.

## State

- Cutover merged: factory-gitops#367 (App variables wired, `GITHUB_TOKEN` line removed).
- `AIFACTORY_AGENT_TOKEN_ADMIN_POLICY=refuse`: factory-gitops#368.
- Reviewer: the default stays `aifactory` (AIFactory's own review engine). The earlier `copilot-ruleset` default (#369) is reverted by #370. Copilot review is opt-in, see below.

## 1. Create the App (workstation)

From an AIFactory checkout (standard library only; does not touch the cluster):

```bash
python scripts/github_app_setup.py manifest --out app.html   # --org ORG for an org-owned App; --name NAME if "AIFactory" is taken
```

App names are global. Open `app.html` and create the App. GitHub redirects to `http://localhost/?code=...`, which does not load: copy the `code` from the address bar. It works once and expires in 1 hour.

```bash
python scripts/github_app_setup.py convert CODE --out secret.yaml   # 0600; prints app id, slug, install URL
```

Gotcha: the Secret `convert` writes (`aifactory-github-app`, key `private-key`) is not what this deployment reads. The deployment reads the three `factory-secrets` keys above, so extract the raw PEM (the 4-space-indented lines):

```bash
(umask 077; sed -n 's/^    //p' secret.yaml > private-key.pem)
```

Install the App with "Only select repositories" and pick every repo your AIFactory projects build on (a project whose repo is not covered cannot push). The installation id is the number at the end of the installation settings URL, or `GET /app/installations` with an App JWT.

## 2. Cutover (one window)

The server refuses to boot with a partial App set, with any PAT (`GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN`, the `github.tokenEnv` alias) and with a `gh` `hosts.yml` token. A pod restart (every image bump) between seeding and removal would crash-loop. So do both at once:

1. Load the keys without printing them:

   ```bash
   jq -n --arg id "$APP_ID" --arg inst "$INSTALLATION_ID" --rawfile pem private-key.pem \
     '{stringData:{AIFACTORY_GITHUB_APP_ID:$id,
                   AIFACTORY_GITHUB_APP_INSTALLATION_ID:$inst,
                   AIFACTORY_GITHUB_APP_PRIVATE_KEY:$pem}}' |
     kubectl -n factory patch secret factory-secrets --type merge --patch-file /dev/stdin
   ```

   Also put the three keys into agenix.
2. Immediately merge the PR that deletes the `GITHUB_TOKEN` env line in `apps/aifactory/manifests/manifests.yaml` (#367). Argo CD restarts the pod.
3. Verify: the pod boots (`kubectl -n factory logs deploy/aifactory | grep -i "github app"`); none of `GH_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN`, the `github.tokenEnv` alias or `AIFACTORY_AGENT_GITHUB_TOKEN` is set in the pod (the last would override the App token for children); no GitHub token in `apps/backend/.env` or `gh` `hosts.yml`.
4. Run one small task. Success: the PR is authored by `app/<slug>` (here: olafkfreund/aifactory-demo#595).
5. Set `AIFACTORY_AGENT_TOKEN_ADMIN_POLICY` to `"refuse"` (#368).
6. Delete `secret.yaml` and `private-key.pem`.

The server mints installation tokens (1 hour, refreshed every 30 minutes) and exports `GH_TOKEN` and `GITHUB_TOKEN` in-process, so the `gh` git-credential helper keeps working with no PAT in the pod's environment.

Rollback: restore the `GITHUB_TOKEN` line and remove the three keys from `factory-secrets`.

## 3. Copilot review (opt-in)

Observed on this deployment: `probe-copilot` against a test PR, with an App installation token, returned `HTTP 201; copilot_listed: False`. The App token did not get Copilot requested as a reviewer. The probe POSTs a real review request, so run it on a test PR and before any Copilot ruleset is active:

```bash
python scripts/github_app_setup.py probe-copilot --repo OWNER/NAME --pr N --app-id ID --installation-id ID --key-file private-key.pem
```

(needs `httpx` and `python-jose`, for example AIFactory's `.venv`).

Because of that, the default reviewer is `aifactory`. A project that wants Copilot opts in with both:

1. Project settings: reviewer `copilot-ruleset`.
2. A repository ruleset `copilot_code_review` that is active (`review_on_push=false`, `review_draft_pull_requests=false`, all branches). Create it with `gh api -X POST repos/OWNER/REPO/rulesets`, or enable an existing one with `gh api -X PUT repos/OWNER/REPO/rulesets/ID -f enforcement=active`. The rulesets created on 2026-11-17 on four repos are kept with `enforcement=disabled`.

A repo without an active ruleset never gets a Copilot review, so keep its project on `aifactory`. Re-review on new pushes is untested. Full steps and caveats: the AIFactory page above.

## 4. After the cutover

1. Reduce the old classic PAT's scopes to `repo`, `workflow`, `copilot`, `read:org`, with an expiry. Other services still use it, so do not delete it.
2. #1700: for a second tenant under a different installation, set `AIFACTORY_GITHUB_APP_ORG_INSTALLATIONS` (`<org_id>=<installation_id>,...`) and test with two installations. An unbound org gets no token.
