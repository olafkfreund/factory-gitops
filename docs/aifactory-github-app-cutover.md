# AIFactory GitHub App cutover (AIFactory#1973, #1700, #1701)

Replaces the fleet PAT (`factory-secrets/GITHUB_TOKEN`, admin and `delete_repo` scopes) with an owner-managed GitHub App. The gitops side is already wired and **inert**: three optional variables and `AIFACTORY_AGENT_TOKEN_ADMIN_POLICY=warn` in `apps/aifactory/manifests/manifests.yaml`. Nothing below is done by an agent; creating the App and its secrets is the owner's.

## 1. Create the App (owner, workstation)

From an AIFactory checkout. This needs only the Python standard library and does not touch the cluster:

```bash
python scripts/github_app_setup.py manifest --out app.html      # add --org ORG for an org-owned App
```

Open `app.html`, create the App (permissions are fixed by the manifest: Contents R/W, Pull requests R/W, Issues R/W, Checks R, Metadata R; nothing else), copy the `code` from the redirect URL within one hour:

```bash
python scripts/github_app_setup.py convert CODE --out secret.yaml
```

Install the App on **only the Factory repos**. Note the App id and the installation id (the number at the end of the installation settings URL). Add Actions: read only if the PR endgame must read workflow runs.

## 2. Cutover (owner, one window)

Order matters: the server refuses to boot with a partial App set, and with any PAT still present. A pod restart (every image bump restarts it) between the two steps would crash-loop.

1. Put `AIFACTORY_GITHUB_APP_ID`, `AIFACTORY_GITHUB_APP_INSTALLATION_ID` and `AIFACTORY_GITHUB_APP_PRIVATE_KEY` (the PEM) into `factory-secrets` with the usual secrets flow (agenix / `kubectl patch secret`), reading the values from a file; never paste them into a command line or a log.
2. Immediately merge a PR deleting the `GITHUB_TOKEN` env line in `apps/aifactory/manifests/manifests.yaml`. Argo CD restarts the pod.
3. Confirm the pod booted (`kubectl -n factory logs deploy/aifactory | grep -i "github app"`), and that none of these is set in the pod: `GH_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN`, the `github.tokenEnv` alias, `AIFACTORY_AGENT_GITHUB_TOKEN` (it would override the App token for children), and no GitHub token in `apps/backend/.env` or `gh` `hosts.yml`.
4. Run one agent task and confirm clone, branch push and PR creation work.

Rollback: restore the `GITHUB_TOKEN` line and remove the three keys from `factory-secrets`.

## 3. After the cutover

1. #1701: from a workstation that holds the PEM (so it never enters the cluster):
   `python scripts/github_app_setup.py probe-copilot --repo OWNER/NAME --pr N --app-id ID --installation-id ID --key-file private-key.pem`
   on a test PR opened by the App. Record the result on AIFactory#1701. If it fails, enable the repository ruleset "Automatically request Copilot code review" and set `AIFACTORY_PR_REVIEWER=copilot-ruleset`.
2. Revoke the old PAT's admin, `delete_repo` and org scopes (or delete the PAT) on GitHub.
3. Change `AIFACTORY_AGENT_TOKEN_ADMIN_POLICY` to `"refuse"` in the manifest. From then on a classic token with `delete_repo` or an `admin:*` scope is withheld from agent children.
4. #1700: for a second tenant under a different installation, set `githubApp.orgInstallations`-style `AIFACTORY_GITHUB_APP_ORG_INSTALLATIONS` (`<org_id>=<installation_id>,...`) and test with two installations. An unbound org gets no token.
