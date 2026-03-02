#!/usr/bin/env bash
# ralph.sh — runs the Ralph Loop using GitHub Copilot CLI
# Usage: ./ralph.sh [max_iterations]
# Env:   MAX_ITERATIONS=50 ./ralph.sh

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
MAX_ITERATIONS="${1:-${MAX_ITERATIONS:-50}}"
STOP_FILE=".ralph-stop"
STALL_LIMIT=3
LOG_DIR="ralph-logs"

# ── Colour output ──────────────────────────────────────────────────────────────
BOLD=$'\033[1m'; RESET=$'\033[0m'
GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; CYAN=$'\033[0;36m'

log()    { echo "${CYAN}[ralph]${RESET} $*"; }
success(){ echo "${GREEN}[ralph]${RESET} $*"; }
warn()   { echo "${YELLOW}[ralph]${RESET} $*"; }
error()  { echo "${RED}[ralph]${RESET} $*" >&2; }

# ── Pre-flight checks ──────────────────────────────────────────────────────────
if ! command -v copilot &>/dev/null; then
    error "GitHub Copilot CLI ('copilot') not found in PATH."
    error "Install with: npm install -g @github/copilot"
    exit 1
fi
if ! command -v jq &>/dev/null; then
    error "'jq' is required but not found in PATH."
    error "Install with: brew install jq"
    exit 1
fi
for required_file in PRD.json PROMPT.md; do
    if [[ ! -f "$required_file" ]]; then
        error "Required file not found: $required_file"
        exit 1
    fi
done

# ── Helpers ────────────────────────────────────────────────────────────────────

# Returns 0 (true) if every task in PRD.json has status "Done"
all_tasks_done() {
    jq -e '[.tasks[].status] | all(. == "Done")' PRD.json > /dev/null 2>&1
}

# Stable checksum of PRD.json for stall detection
prd_checksum() {
    if command -v shasum &>/dev/null; then
        shasum PRD.json | awk '{print $1}'
    else
        cksum PRD.json | awk '{print $1}'
    fi
}

# ── Setup ──────────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
rm -f "$STOP_FILE"

ITERATION=0
STALL_COUNT=0

log "${BOLD}Starting Ralph Loop${RESET} (max $MAX_ITERATIONS iterations)"
echo ""

# ── Trap CTRL+C ────────────────────────────────────────────────────────────────
trap 'echo ""; warn "Interrupted by user."; exit 130' INT

# ── Main loop ──────────────────────────────────────────────────────────────────
while [[ $ITERATION -lt $MAX_ITERATIONS ]]; do
    ITERATION=$(( ITERATION + 1 ))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    LOG_FILE="$LOG_DIR/iteration-$(printf '%03d' "$ITERATION")-$(date '+%Y%m%d-%H%M%S').log"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Iteration ${BOLD}$ITERATION / $MAX_ITERATIONS${RESET} — $TIMESTAMP"
    echo ""

    CHECKSUM_BEFORE=$(prd_checksum 2>/dev/null || echo "")

    # ── Invoke Copilot CLI ────────────────────────────────────────────────────
    copilot -p "$(cat PROMPT.md)" --allow-all-tools 2>&1 | tee "$LOG_FILE"
    EXIT_CODE=${PIPESTATUS[0]}

    if [[ $EXIT_CODE -ne 0 ]]; then
        warn "copilot exited with code $EXIT_CODE"
    fi

    echo ""

    # ── Check stop-signal file ────────────────────────────────────────────────
    if [[ -f "$STOP_FILE" ]]; then
        STOP_REASON=$(cat "$STOP_FILE")
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [[ "$STOP_REASON" == DONE:* ]]; then
            success "${BOLD}Ralph Loop complete!${RESET} $STOP_REASON"
            exit 0
        else
            error "${BOLD}Ralph Loop stopped with blocker:${RESET} $STOP_REASON"
            exit 2
        fi
    fi

    # ── Check PRD.json for full completion ────────────────────────────────────
    if all_tasks_done; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        success "${BOLD}All tasks complete!${RESET} (detected via PRD.json)"
        exit 0
    fi

    # ── Stall detection ───────────────────────────────────────────────────────
    CHECKSUM_AFTER=$(prd_checksum 2>/dev/null || echo "")
    if [[ -n "$CHECKSUM_BEFORE" && "$CHECKSUM_BEFORE" == "$CHECKSUM_AFTER" ]]; then
        STALL_COUNT=$(( STALL_COUNT + 1 ))
        warn "No progress detected (PRD.json unchanged). Stall count: $STALL_COUNT / $STALL_LIMIT"
        if [[ $STALL_COUNT -ge $STALL_LIMIT ]]; then
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            error "${BOLD}Loop halted:${RESET} $STALL_LIMIT consecutive iterations with no PRD.json progress."
            exit 3
        fi
    else
        STALL_COUNT=0
    fi

    log "Task completed. Continuing to next iteration..."
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
error "${BOLD}Maximum iterations ($MAX_ITERATIONS) reached.${RESET} Loop stopped without full completion."
exit 1
