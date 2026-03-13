#!/usr/bin/env bash
# ============================================================
# AVENGER INITIATIVE — Backup Script v2
# Branch-per-night strategy with retention policy:
#   - Daily branches: backup/daily/YYYY-MM-DD  (keep 7)
#   - Weekly branches: backup/weekly/YYYY-WNN  (keep 8, created on Sundays)
#   - Monthly branches: backup/monthly/YYYY-MM (keep 12, created on 1st)
#   - All merged into main
# Usage: backup.sh ["optional commit message"]
# ============================================================
set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_HOME:-$HOME/.openclaw}"
CONFIG_FILE="$OPENCLAW_DIR/credentials/avenger-config.json"
KEY_FILE="$OPENCLAW_DIR/credentials/avenger.key"
WORKSPACE_DIR="$OPENCLAW_DIR/workspace"
LOG_FILE="$WORKSPACE_DIR/memory/avenger-backup.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[AVENGER]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# ---- Preflight --------------------------------------------
[ -f "$KEY_FILE" ] || fail "Not configured. Run: bash setup.sh --repo <github-url>"
[ -f "$CONFIG_FILE" ] || fail "Config missing. Run setup.sh first."
AVENGER_KEY=$(cat "$KEY_FILE")
[ -n "$AVENGER_KEY" ] || fail "Encryption key is empty"
command -v git >/dev/null 2>&1 || fail "git not installed"
command -v gh >/dev/null 2>&1 || fail "gh CLI not installed"
command -v openssl >/dev/null 2>&1 || fail "openssl not installed"
gh auth status >/dev/null 2>&1 || fail "gh not authenticated — run: gh auth login"

VAULT_REPO=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['vault_repo'])")
[ -n "$VAULT_REPO" ] || fail "vault_repo not set in avenger-config.json"

# ---- Branch names -----------------------------------------
TODAY=$(date -u '+%Y-%m-%d')
DOW=$(date -u '+%u')        # 1=Mon … 7=Sun
DOM=$(date -u '+%d')        # day of month
WEEK=$(date -u '+%Y-W%V')   # ISO week
MONTH=$(date -u '+%Y-%m')

DAILY_BRANCH="backup/daily/$TODAY"
COMMIT_MSG="${1:-"🛡️ Avenger backup — $TODAY"}"
VAULT_DIR="/tmp/avenger-vault-$$"

# ---- Encrypt helper ----------------------------------------
encrypt_file() {
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -pass "pass:$AVENGER_KEY" -in "$1" -out "$2"
}

# ---- Clone repo --------------------------------------------
log "Cloning vault..."
GH_TOKEN=$(gh auth token)
REPO_URL=$(echo "$VAULT_REPO" | sed "s|https://|https://${GH_TOKEN}@|")
git clone --quiet "$REPO_URL" "$VAULT_DIR"
cd "$VAULT_DIR"
git config user.email "avenger@openclaw.ai"
git config user.name "Avenger Initiative"

# ---- Create daily branch ----------------------------------
git checkout -b "$DAILY_BRANCH" 2>/dev/null || git checkout "$DAILY_BRANCH"

mkdir -p config workspace/memory skills

# ---- Auto-detect agent workspaces -------------------------
AGENT_DIRS=$(find "$OPENCLAW_DIR" -maxdepth 1 -name "workspace-*" -type d 2>/dev/null | grep -v workspace-main || true)
for ws in $AGENT_DIRS; do
    agent_name=$(basename "$ws" | sed 's/workspace-//')
    mkdir -p "agents/$agent_name"
done
mkdir -p agents/main

# ---- 1. openclaw.json (ENCRYPTED) -------------------------
log "Encrypting openclaw.json..."
[ -f "$OPENCLAW_DIR/openclaw.json" ] && encrypt_file "$OPENCLAW_DIR/openclaw.json" "config/openclaw.json.enc"

# ---- 2. Cron jobs -----------------------------------------
[ -f "$OPENCLAW_DIR/cron/jobs.json" ] && \
    cp "$OPENCLAW_DIR/cron/jobs.json" "config/cron-jobs.json" && log "  ✓ cron jobs"

# ---- 3. Workspace .md files -------------------------------
BACKED=0
for f in "$WORKSPACE_DIR"/*.md; do
    [ -f "$f" ] || continue
    cp "$f" "workspace/$(basename $f)"
    BACKED=$((BACKED+1))
done
log "  ✓ $BACKED workspace files"

# ---- 4. Memory logs ----------------------------------------
COUNT=0
for mf in "$WORKSPACE_DIR/memory"/*.md; do
    [ -f "$mf" ] || continue
    cp "$mf" "workspace/memory/$(basename $mf)"
    COUNT=$((COUNT+1))
done
log "  ✓ $COUNT memory logs"

# ---- 5. Agent workspaces ----------------------------------
for ws in $AGENT_DIRS; do
    agent_name=$(basename "$ws" | sed 's/workspace-//')
    COUNT=0
    for f in SOUL.md IDENTITY.md MEMORY.md HEARTBEAT.md TOOLS.md AGENTS.md USER.md BOOTSTRAP.md; do
        [ -f "$ws/$f" ] && cp "$ws/$f" "agents/$agent_name/$f" && COUNT=$((COUNT+1)) || true
    done
    [ $COUNT -gt 0 ] && log "  ✓ agent:$agent_name ($COUNT files)"
done
for f in SOUL.md IDENTITY.md MEMORY.md HEARTBEAT.md TOOLS.md; do
    [ -f "$WORKSPACE_DIR/$f" ] && cp "$WORKSPACE_DIR/$f" "agents/main/$f" || true
done

# ---- 6. Custom skills (SKILL.md + scripts + references) ---
SKILLS_DIR="$WORKSPACE_DIR/skills"
if [ -d "$SKILLS_DIR" ]; then
    SKILL_COUNT=0
    for skill_dir in "$SKILLS_DIR"/*/; do
        skill_name=$(basename "$skill_dir")
        mkdir -p "skills/$skill_name"
        [ -f "$skill_dir/SKILL.md" ] && cp "$skill_dir/SKILL.md" "skills/$skill_name/"
        [ -d "$skill_dir/scripts" ]    && cp -r "$skill_dir/scripts" "skills/$skill_name/" 2>/dev/null || true
        [ -d "$skill_dir/references" ] && cp -r "$skill_dir/references" "skills/$skill_name/" 2>/dev/null || true
        SKILL_COUNT=$((SKILL_COUNT+1))
    done
    log "  ✓ $SKILL_COUNT skills"
fi

# ---- 7. Manifest ------------------------------------------
HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
OC_VER=$(python3 -c "import json; print(json.load(open('$OPENCLAW_DIR/update-check.json')).get('current','?'))" 2>/dev/null || echo "?")

cat > AVENGER-MANIFEST.md << MANIFEST
# 🛡️ Avenger Initiative — Vault Manifest

**Last backup:** $(date -u '+%Y-%m-%dT%H:%M:%SZ')
**Branch:** \`$DAILY_BRANCH\`
**Host:** $HOSTNAME | **OpenClaw:** $OC_VER

## Retention Policy

| Branch type | Pattern | Retention |
|---|---|---|
| Daily | \`backup/daily/YYYY-MM-DD\` | Last 7 days |
| Weekly | \`backup/weekly/YYYY-WNN\` | Last 8 weeks |
| Monthly | \`backup/monthly/YYYY-MM\` | Last 12 months |

## Contents

| Path | Encrypted | Notes |
|------|-----------|-------|
| \`config/openclaw.json.enc\` | ✅ AES-256 | All API keys & bot tokens |
| \`config/cron-jobs.json\` | No | Scheduled jobs |
| \`workspace/*.md\` | No | SOUL, IDENTITY, MEMORY, etc. |
| \`workspace/memory/\` | No | Daily memory logs |
| \`agents/*/\` | No | Per-agent files |
| \`skills/\` | No | Custom skill definitions |

## Restore

\`\`\`bash
# From a specific date
git checkout backup/daily/YYYY-MM-DD
bash skills/avenger-initiative/scripts/restore.sh --vault .

# Latest (main branch)
git checkout main
bash skills/avenger-initiative/scripts/restore.sh --vault .
\`\`\`
MANIFEST

# ---- .gitignore -------------------------------------------
cat > .gitignore << 'GITIGNORE'
*.key
*.pem
.env
credentials/
node_modules/
__pycache__/
*.pyc
.DS_Store
GITIGNORE

# ---- Commit to daily branch --------------------------------
log "Committing to $DAILY_BRANCH..."
git add -A
DIFF=$(git diff --cached --stat 2>/dev/null || echo "")
if git diff --cached --quiet; then
    warn "No changes since last backup."
    cd /; rm -rf "$VAULT_DIR"
    exit 0
fi
git commit -m "$COMMIT_MSG" --quiet

# ---- Push daily branch ------------------------------------
git push origin "$DAILY_BRANCH" --force --quiet
log "  ✓ Pushed $DAILY_BRANCH"

# ---- Merge to main ----------------------------------------
git checkout main --quiet
git merge --no-ff "$DAILY_BRANCH" -m "merge: $DAILY_BRANCH" --quiet
git push origin main --quiet
log "  ✓ Merged to main"

# ---- Create weekly branch (on Sunday = DOW 7) -------------
if [ "$DOW" = "7" ]; then
    WEEKLY_BRANCH="backup/weekly/$WEEK"
    git checkout -b "$WEEKLY_BRANCH" "$DAILY_BRANCH" --quiet 2>/dev/null || true
    git push origin "$WEEKLY_BRANCH" --force --quiet
    log "  ✓ Weekly branch: $WEEKLY_BRANCH"
fi

# ---- Create monthly branch (on 1st of month) --------------
if [ "$DOM" = "01" ]; then
    MONTHLY_BRANCH="backup/monthly/$MONTH"
    git checkout -b "$MONTHLY_BRANCH" "$DAILY_BRANCH" --quiet 2>/dev/null || true
    git push origin "$MONTHLY_BRANCH" --force --quiet
    log "  ✓ Monthly branch: $MONTHLY_BRANCH"
fi

# ---- Prune old branches -----------------------------------
log "Pruning old branches..."

# Fetch all remote branches
git fetch --prune --quiet

# Prune daily: keep last 7
DAILY_BRANCHES=$(git branch -r --list "origin/backup/daily/*" | sed 's|origin/||' | sort -r)
COUNT=0
for b in $DAILY_BRANCHES; do
    COUNT=$((COUNT+1))
    if [ $COUNT -gt 7 ]; then
        git push origin --delete "$b" --quiet 2>/dev/null && log "  🗑 Pruned $b" || true
    fi
done

# Prune weekly: keep last 8
WEEKLY_BRANCHES=$(git branch -r --list "origin/backup/weekly/*" | sed 's|origin/||' | sort -r)
COUNT=0
for b in $WEEKLY_BRANCHES; do
    COUNT=$((COUNT+1))
    if [ $COUNT -gt 8 ]; then
        git push origin --delete "$b" --quiet 2>/dev/null && log "  🗑 Pruned $b" || true
    fi
done

# Prune monthly: keep last 12
MONTHLY_BRANCHES=$(git branch -r --list "origin/backup/monthly/*" | sed 's|origin/||' | sort -r)
COUNT=0
for b in $MONTHLY_BRANCHES; do
    COUNT=$((COUNT+1))
    if [ $COUNT -gt 12 ]; then
        git push origin --delete "$b" --quiet 2>/dev/null && log "  🗑 Pruned $b" || true
    fi
done

# ---- Cleanup + log ----------------------------------------
cd /; rm -rf "$VAULT_DIR"
mkdir -p "$(dirname $LOG_FILE)"
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') OK | branch=$DAILY_BRANCH | $VAULT_REPO" >> "$LOG_FILE"
log "✅ Backup complete → $VAULT_REPO ($DAILY_BRANCH → main)"
