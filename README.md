# deploy-gates

Approval gates for deployments, plus the shared pieces the deploy workflows use.

Required reviewers on an environment work in private repositories only on GitHub
Enterprise, so the Approve buttons live here, in a public repository. Nothing but the
repository name, environment, run ID and short commit reaches this repository, and it
has no cloud access: approving only re-runs a job of the held run through a GitHub App.

## How a gated release runs

```
app repo run (attempt 1)                         deploy-gates
  test -> build -> Approve ──dispatch approve.yml──> Release (links)
                     │                                  │
                     └ deploy skipped                   Approve  (environment <repo>-<env>, reviewers)
                                                        │ approved
app repo run (attempt 2) <──re-run the Approve job──────┘
  Approve -> deploy
```

The app's `Approve` job asks for approval on its first attempt and lets the deploy run
on any later one. Re-running a job also re-runs the jobs that need it, and keeps the
outputs of the others, so the deploy gets the image built in attempt 1.

## Pieces

| Path | What |
|---|---|
| `.github/workflows/approve.yml` | the gate: one Approve button per `<repository>-<env>` |
| `.github/workflows/frontend-deploy.yml` | the frontend's gate: Switch traffic, then optionally stop the old slot |
| `.github/actions/request-approval` | used by an app's `Approve` job: dispatches `approve.yml`, returns the approval page |
| `.github/actions/slack-card` | one Slack message per release, redrawn at every stage |
| `.github/scripts/rerun-job.sh` | re-runs the held job and waits for the result |

Apps use the actions as `Like-Spinco/deploy-gates/.github/actions/<name>@main`.

## Connecting a repository

1. The gate GitHub App is installed on the repository (Actions: read and write).
2. Here: Settings → Environments → New environment `<repository>-<env>`, e.g.
   `api-php-prod`, with required reviewers and deployment branches limited to `main`.
   `approve.yml` refuses an environment that is missing or has no reviewers.
3. Organization (or repository) settings of the app, Actions:
   - variable `GATE_APP_CLIENT_ID`, secret `GATE_APP_PRIVATE_KEY`;
   - Slack: secret `SLACK_DEPLOY_TOKEN`, variables `SLACK_DEPLOY_CHANNEL_DEV` and
     `SLACK_DEPLOY_CHANNEL_PROD`.

   This repository needs `GATE_APP_CLIENT_ID` and `GATE_APP_PRIVATE_KEY` too.

## Slack card

The bot needs the scopes `chat:write`, `channels:read` and `groups:read` (the last two
list the channel members) and must be invited to the channel.

- The card is posted once and edited at each stage, which never notifies anyone.
- Waiting for approval, deployed, failed and cancelled also get a reply in the card's
  thread that mentions every channel member: `@channel` is silent in threads.
- Once approved, the Approval stage links the gate run and names the approver.
- `times` (JSON stage -> seconds) puts how long a finished stage took on its label, e.g.
  `Built in 4m 28s`, `Deployed in 1m 59s`, `Switched in 9s`; several objects are merged.
- The done card names the time from approval to live, the done reply repeats it with the switch
  or deploy time, and the waiting reply says how long after the start the release was ready.
- With no token or channel the action does nothing; Slack errors are warnings and never
  fail a deploy.

```yaml
- id: card
  uses: Like-Spinco/deploy-gates/.github/actions/slack-card@main
  continue-on-error: true
  with:
    state: start                     # running:<Stage>, waiting:<Stage>, done, failed:<Stage>, cancelled
    token: ${{ secrets.SLACK_DEPLOY_TOKEN }}
    channel: ${{ vars.SLACK_DEPLOY_CHANNEL_DEV }}
    stages: "Test Build Approval Deploy"
    environment: dev
    ref: ${{ github.sha }}
# later jobs pass ts and meta from this step, and check-run-id: ${{ job.check_run_id }}
```
