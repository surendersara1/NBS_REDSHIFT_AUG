# MCP server setup — for developers

This repo ships a **project-scoped** MCP configuration at [`.mcp.json`](../../.mcp.json) (repo root). Claude Code reads it automatically when you open this project, and prompts you once to approve the servers.

> **Never share `~/.claude.json`.** That is the *personal, user-scope* config (Windows: `C:\Users\<you>\.claude.json`, macOS/Linux: `~/.claude.json`). It contains conversation history and **live API tokens**. `.mcp.json` is the file designed for the team.

## 1. Config file locations (Claude Code, not VSCode)

| Scope | File | Shared? |
|---|---|---|
| **Project** | `.mcp.json` in the repo root | ✅ committed to git — **use this** |
| **User** | `~/.claude.json` (`C:\Users\<you>\.claude.json`) | ❌ personal; holds secrets |
| **Settings** (not MCP servers) | `~/.claude/settings.json`, `.claude/settings.json` | permissions, env, hooks |

## 2. Set the required secrets

`.mcp.json` uses `${VAR}` placeholders — Claude Code expands them from your environment at launch, so no credentials live in git. Set these before starting Claude Code:

| Variable | Where to get it |
|---|---|
| `GITHUB_PERSONAL_ACCESS_TOKEN` | GitHub → Settings → Developer settings → PAT (repo scope) |
| `CONFLUENCE_URL`, `CONFLUENCE_USERNAME`, `CONFLUENCE_API_TOKEN` | Atlassian account → API tokens |
| `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN` | Atlassian account → API tokens |
| `SLACK_MCP_XOXC_TOKEN`, `SLACK_MCP_XOXD_TOKEN` | Slack browser session tokens |
| `WORKSPACE_ROOT` | Absolute path you want the `filesystem` server to expose, e.g. `E:\NBS_Tamimi_Lakehouse` |

**Windows (PowerShell, persistent):**
```powershell
[Environment]::SetEnvironmentVariable("GITHUB_PERSONAL_ACCESS_TOKEN","<token>","User")
[Environment]::SetEnvironmentVariable("WORKSPACE_ROOT","E:\NBS_Tamimi_Lakehouse","User")
# …repeat for the Atlassian + Slack variables, then restart the terminal
```

**macOS / Linux (`~/.zshrc` or `~/.bashrc`):**
```bash
export GITHUB_PERSONAL_ACCESS_TOKEN="<token>"
export WORKSPACE_ROOT="$HOME/NBS_Tamimi_Lakehouse"
```

## 3. Prerequisites
- **Node.js 18+** (`npx`) — for filesystem, playwright, sequential-thinking, github, fetch
- **uv / uvx** (`pip install uv`) — for git and the AWS Labs servers
- **AWS SSO profile** for the AWS servers (`AWS_PROFILE`, `AWS_REGION` are set in `.mcp.json`; default region `eu-west-1`)

## 4. Verify
```bash
claude          # from the repo root — approve the project servers when prompted
/mcp            # lists each server and its connection status
```
Servers needing interactive OAuth (e.g. Atlassian, Slack) are authorised from `/mcp` in an interactive session.

## 5. What's included (17 servers)
`filesystem` · `git` · `github` · `playwright` · `fetch` · `sequential-thinking` · `atlassian` · `slack-direct` · `agent-sops` · `strands-agents` · plus AWS: `aws-mcp`, `ecs-mcp`, `awslabs.aws-documentation-mcp-server`, `awslabs.cdk-mcp-server`, `awslabs.aws-serverless-mcp-server`, `awslabs.aws-iac-mcp-server`, `awslabs.well-architected-security-mcp-server`.

## 6. Safety
`.mcp.json` was generated from a working config with every credential stripped and replaced by `${VAR}`. It was scanned for `ghp_ / github_pat_ / xox*- / ATATT / AKIA` patterns before commit — clean. **Re-run that scan if you ever regenerate it.**
