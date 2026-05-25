## 1) Quick Setup (GitHub Action)

Create `.github/workflows/pr-agent.yml` in your target repository:

```yaml
name: PR-Agent

on:
  pull_request:
    types: [opened, reopened, ready_for_review, synchronize]

permissions:
  issues: write
  pull-requests: write
  contents: write

jobs:
  pr_agent_job:
    if: ${{ github.event.sender.type != 'Bot' }}
    runs-on: ubuntu-latest
    steps:
      - name: PR Agent
        uses: the-pr-agent/pr-agent@main
        env:
          OPENAI_KEY: ${{ secrets.OPENAI_KEY }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

          # Optional model override
          config.model: "gpt-5.3-codex"
          config.fallback_models: '["gpt-5.2-codex"]'

          # Auto tools
          GITHUB_ACTION_CONFIG.AUTO_DESCRIBE: "true"
          GITHUB_ACTION_CONFIG.AUTO_REVIEW: "true"
          GITHUB_ACTION_CONFIG.AUTO_IMPROVE: "true"
```

Add repository secret:

- `OPENAI_KEY`

Then open or update a PR. The workflow runs automatically.

## 2) Use Your Custom PR-Agent Fork

If you customized PR-Agent code, update `uses:` in your target repo workflow:

```yaml
uses: <your-org-or-user>/pr-agent@<branch-or-tag-or-sha>
```

Recommended: pin to commit SHA for deterministic behavior.

## 3) Disable Comment Commands, Keep Auto Run

If you do not want `/review` or other comment triggers:

- Do not include `issue_comment` trigger in workflow.
- Keep only `pull_request` triggers.

Example (already included above):

- `pull_request` with `opened`, `reopened`, `ready_for_review`, `synchronize`

## 4) Local CLI Setup

```bash
pip install pr-agent
export OPENAI_KEY=<your_key>
pr-agent --pr_url https://github.com/owner/repo/pull/123 review
pr-agent --pr_url https://github.com/owner/repo/pull/123 describe
pr-agent --pr_url https://github.com/owner/repo/pull/123 improve
```

## 5) GitLab Setup Options

GitLab does not support GitHub-style `uses: owner/repo@ref` actions.

Choose one:

- Webhook + hosted PR-Agent service (self-hosted).
- GitLab CI job that runs PR-Agent on MR events (no always-on server needed).
