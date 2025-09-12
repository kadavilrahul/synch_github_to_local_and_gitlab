# GitHub to GitLab Sync Tool

A simple bash script that syncs all your GitHub repositories to GitLab with local backups.

## Quick Start

```bash
git clone https://github.com/kadavilrahul/synch_github_to_local_and_gitlab.git
```
```bash
cd synch_github_to_local_and_gitlab
```
```bash
bash run.sh
```

## Setup

### 1. Create config.json
Copy the sample config and update with your credentials:
```bash
cp config.json.sample config.json
# Then edit config.json with your actual credentials
```

```json
{
  "github": {
    "username": "your-github-username",
    "token": "ghp_your_github_personal_access_token_here"
  },
  "gitlab": {
    "username": "your-gitlab-username", 
    "token": "glpat-your_gitlab_personal_access_token_here"
  },
  "gitlab_api": "https://gitlab.com/api/v4",
  "workdir": "/tmp/github-gitlab-sync",
  "local_backup_dir": "/root/github_repos_backup"
}
```

### 2. Get API Tokens

**GitHub Token:** https://github.com/settings/tokens
- Click "Generate new token" → "Generate new token (classic)"
- Required scopes: `repo` (Full control of private repositories), `read:org`, `read:user`
- Copy the token immediately (starts with `ghp_`)
- Save it securely - you won't be able to see it again

**GitLab Token:** https://gitlab.com/-/profile/personal_access_tokens  
- Click "Add new token"
- Required scopes: `api`, `read_user`, `read_repository`, `write_repository`
- Set expiration date (optional but recommended)
- Copy the token immediately (starts with `glpat-`)
- Save it securely - you won't be able to see it again

**Menu Options:**
1. **🔄 Full Sync** - Mirror all GitHub repos to GitLab + create local backups
2. **🏷️ GitLab Only** - Mirror GitHub repos to GitLab only
3. **💾 Local Only** - Clone GitHub repos locally only
4. **📊 Quick Status** - Check connections and repository counts
5. **🚪 Exit**

## What It Does

- **Discovers** all your GitHub repositories (public + private)
- **Creates** corresponding private repositories on GitLab
- **Mirrors** all branches and tags to GitLab
- **Clones** repositories locally for backup
- **Handles** authentication automatically
- **Shows** progress and success/error counts

## File Structure

```
sync_github_to_gitlab/
├── run.sh              # Main script
├── config.json.sample  # Sample configuration file
├── config.json         # Your credentials (create from sample)
├── repos/              # Local backups (auto-created)
├── sync_errors.log     # Error log
└── sync_success.log    # Success log
```

## Troubleshooting

**Token Issues:**
- Make sure tokens have correct scopes
- GitHub: repo, read:org, read:user
- GitLab: api, read_user, read_repository, write_repository

**Missing Dependencies:**
The script auto-installs: `jq`, `git`, `curl`, `gh`, `glab`

## Security

- Keep `config.json` private (contains API tokens)
- Never commit tokens to git
- `.gitignore` excludes sensitive files

## Requirements

- Linux (Ubuntu/Debian)
- Sudo access (for dependency installation)