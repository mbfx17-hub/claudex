#!/usr/bin/env bash
# Synthetic end-to-end test with MOCKED FCC Codex.
#
# This test uses a stub fcc-codex executable to exercise the full pipeline
# without requiring real FCC credentials or making live API calls.
#
# What it does:
#   1. Spins up a throwaway project at /tmp/claudex_synthetic with its own .git
#   2. Creates a mock fcc-codex that outputs synthetic findings
#   3. Runs start-loop.sh plan with a real topic
#   4. Writes a realistic PLAN.md
#   5. Invokes the Stop hook directly (simulates Claude finishing a turn)
#   6. Executes the generated runner script (mock FCC Codex call)
#   7. Reads output, decides material/not material
#   8. Either revises PLAN.md and loops, or calls mark-done
#   9. Verifies final state
#
# Usage:
#   bash tests/synthetic-e2e.sh

set +e

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HOOK="$PLUGIN_ROOT/hooks/stop-hook.sh"
START="$PLUGIN_ROOT/scripts/start-loop.sh"
MARK_DONE="$PLUGIN_ROOT/scripts/mark-done.sh"
ROLLBACK="$PLUGIN_ROOT/scripts/rollback-loop.sh"

SYNTH_DIR="/tmp/claudex_synthetic"
TOPIC="add expiry dates to short links so they auto-die after a configured time"

# Track results.
pass=0
fail=0

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %s\n' "$name"
    pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s\n' "$name"
    fail=$((fail+1))
  fi
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

printf '\033[1m=== Claudex Synthetic E2E (with mocked FCC Codex) ===\033[0m\n'

# Set up synthetic project.
section "Setup"
rm -rf "$SYNTH_DIR"
mkdir -p "$SYNTH_DIR"
cd "$SYNTH_DIR" || exit 1
git init -q
git commit --allow-empty -q -m "baseline"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
echo "Synthetic project at: $SYNTH_DIR"
echo "Plugin root:          $PLUGIN_ROOT"

# Create mock fcc-codex that outputs synthetic findings
MOCK_BIN_DIR="$SYNTH_DIR/mock_bin"
mkdir -p "$MOCK_BIN_DIR"
cat > "$MOCK_BIN_DIR/fcc-codex" <<'MOCKEOF'
#!/usr/bin/env bash
# Mock fcc-codex for synthetic testing.
# Reads stdin (the prompt) and outputs synthetic findings based on the prompt content.

# Check for --version flag
if [ "$1" = "--version" ]; then
  echo "fcc-codex 0.171.0 (mock)"
  exit 0
fi

# Read the prompt from stdin
PROMPT=$(cat)

# Check if this is a plan mode review (contains "adversarial review of a plan")
if echo "$PROMPT" | grep -q "adversarial review of a plan"; then
  # Extract round number from prompt
  ROUND=1
  if echo "$PROMPT" | grep -q "Round: 2"; then
    ROUND=2
  elif echo "$PROMPT" | grep -q "Round: 3"; then
    ROUND=3
  fi

  if [ "$ROUND" = "1" ]; then
    # Round 1: return some findings
    cat <<FINDOUT
# Round 1 findings

## High
- Missing authentication on expiry check endpoint (add auth middleware)
- No timezone handling for expiry dates (store in UTC, convert on display)

## Medium
- Race condition: concurrent link creation could skip expiry validation (use DB constraints)
- No index on expires_at column (add index for query performance)

## Low
- Consider soft-delete instead of hard-delete for audit trail
- Add metrics for expired link clicks
FINDOUT
  elif [ "$ROUND" = "2" ]; then
    # Round 2: return fewer findings (some addressed)
    cat <<FINDOUT
# Round 2 findings

## High
- Race condition still possible if DB constraint not added (use unique constraint)

## Medium
- No index on expires_at (add index)

## Low
- Soft-delete vs hard-delete: recommend soft-delete with deleted_at
FINDOUT
  else
    # Round 3+: no substantive findings
    cat <<FINDOUT
# Round 3 findings

No substantive findings.
FINDOUT
  fi
  exit 0
fi

# Check if this is a review mode review (contains "code review of the current git diff")
if echo "$PROMPT" | grep -q "code review of the current git diff"; then
  cat <<FINDOUT
=== FINDINGS ===

# Review findings

## High
- SQL injection risk in user input handling (use parameterized queries)

## Medium
- Missing error handling on external API call (add retry with backoff)

## Low
- Inconsistent naming convention in new functions

=== PROPOSED FIXES ===

--- a/src/api/links.ts
+++ b/src/api/links.ts
@@ -10,7 +10,7 @@ export async function createLink(req, res) {
   const { url, expiresAt } = req.body;
-  const query = \`INSERT INTO links (url, expires_at) VALUES ('\${url}', '\${expiresAt}')\`;
+  const query = 'INSERT INTO links (url, expires_at) VALUES (?, ?)';
   await db.run(query, [url, expiresAt]);
FINDOUT
  exit 0
fi

# Default: echo something
echo "Mock fcc-codex: unknown prompt type"
exit 1
MOCKEOF
chmod +x "$MOCK_BIN_DIR/fcc-codex"
export PATH="$MOCK_BIN_DIR:$PATH"
echo "Mock fcc-codex created at $MOCK_BIN_DIR/fcc-codex"

# Round 0, initialize loop.
section "Round 0: start-loop"
START_OUTPUT=$(bash "$START" plan "$TOPIC" 2>&1)
echo "$START_OUTPUT" | head -8
check "start-loop produced output" test -n "$START_OUTPUT"
check "state file created" bash -c "ls .claude/claudex/*.state >/dev/null"
REVIEW_ID=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs basename | sed 's/.state$//')
echo "Review ID: $REVIEW_ID"
check "review_id format valid" bash -c "[[ '$REVIEW_ID' =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$ ]]"

# Write a realistic PLAN.md with at least one obvious gap so Codex has material to find.
section "Round 1: write initial PLAN.md (with deliberate gaps)"
cat > PLAN.md <<'EOF'
# Plan: Link Expiry

## Scope

Add an expiry date field to short links so they auto-die after a user-set time.

## Steps

1. Add an `expires_at` column to the `links` table.
2. When a user creates a short link, accept an optional expiry date in the form input.
3. When a short link is clicked, check if `expires_at` is in the past. If so, redirect to a 410 Gone page.
4. Add a daily cron job that hard-deletes expired links.
EOF
echo "PLAN.md written ($(wc -l < PLAN.md) lines)."
check "PLAN.md exists" test -f PLAN.md

# Fire hook for round 1, should BLOCK with runner script.
section "Round 1: fire hook (drafting -> reviewing)"
HOOK_OUT=$(echo '{}' | bash "$HOOK" 2>/dev/null)
echo "Hook output: $(printf '%s' "$HOOK_OUT" | head -c 80)..."
check "hook returned block" grep -q block <<< "$HOOK_OUT"
RUNNER=".claude/claudex/$REVIEW_ID-runner.sh"
check "runner script created" test -f "$RUNNER"
check "runner has quoted PROMPTEOF (P1 fix)" grep -q "<<'PROMPTEOF'" "$RUNNER"

# Execute the runner script for real (mock FCC Codex).
section "Round 1: execute runner (mock FCC Codex call)"
echo "Calling mock FCC Codex..."
CODEX_OUTPUT=$(bash "$RUNNER" 2>&1)
RUNNER_RC=$?
echo "Runner exit code: $RUNNER_RC"
echo "$CODEX_OUTPUT" | tail -30 | head -20
check "runner exited with code 0" test "$RUNNER_RC" = "0"
check "FCC Codex output is non-empty" test -n "$CODEX_OUTPUT"
check "FCC Codex did not hit stdin terminal error" bash -c "! echo '$CODEX_OUTPUT' | grep -q 'stdin is not a terminal'"
check "FCC Codex did not hit auth error" bash -c "! echo '$CODEX_OUTPUT' | grep -qi 'not logged in\\|auth.*fail'"
check "FCC Codex output mentions plan/review topic" bash -c "echo '$CODEX_OUTPUT' | grep -qiE 'plan|review|expir|finding'"
check "findings file created" test -f ".claude/claudex/$REVIEW_ID/findings-round-1.md"
check "findings file has content" test -s ".claude/claudex/$REVIEW_ID/findings-round-1.md"
check "findings file has expected format" grep -q "Round 1 findings" ".claude/claudex/$REVIEW_ID/findings-round-1.md"
check "findings file has High section" grep -q "## High" ".claude/claudex/$REVIEW_ID/findings-round-1.md"

# Round 1 done. Now simulate Claude deciding the loop is complete and calling mark-done.
# (We don't try to parse Codex output to decide -- that's Claude's job in production.
#  The point here is to verify the lifecycle ends cleanly when mark-done is called.)
section "Mark loop done (Claude's signal in production)"
bash "$MARK_DONE" "$REVIEW_ID" >/dev/null
PHASE=$(grep '^phase:' ".claude/claudex/$REVIEW_ID.state" | sed 's/^phase: //')
SIGNAL=$(grep '^decision_signal:' ".claude/claudex/$REVIEW_ID.state" | sed 's/^decision_signal: //')
# mark-done sets phase=reviewing (not done) and signal=no-material-findings
# The hook then transitions: reviewing -> summarizing -> done on subsequent fires
check "phase is reviewing after mark-done" test "$PHASE" = "reviewing"
check "signal set to no-material-findings" test "$SIGNAL" = "no-material-findings"

# First hook fire after mark-done: reviewing -> summarizing, returns BLOCK with summary
section "First hook fire after mark-done (summarizing)"
HOOK_OUT=$(echo '{}' | bash "$HOOK" 2>/dev/null)
echo "Hook output: $(printf '%s' "$HOOK_OUT" | head -c 80)..."
check "hook returns block with summary" bash -c "echo '$HOOK_OUT' | grep -q block"
check "summary mentions plan loop complete" bash -c "echo '$HOOK_OUT' | grep -qi 'plan loop complete'"
PHASE=$(grep '^phase:' ".claude/claudex/$REVIEW_ID.state" | sed 's/^phase: //')
check "phase transitioned to summarizing" test "$PHASE" = "summarizing"

# Second hook fire: summarizing -> done, returns APPROVE
section "Second hook fire (summarizing -> done)"
HOOK_OUT=$(echo '{}' | bash "$HOOK" 2>/dev/null)
echo "Final hook output: $HOOK_OUT"
check "final hook returned approve" bash -c "echo '$HOOK_OUT' | grep -q approve"
check "lockfile cleaned up" bash -c "! test -f .claude/claudex/$REVIEW_ID.lock"
check "state file preserved for audit" test -f ".claude/claudex/$REVIEW_ID.state"
check "runner script cleaned up" bash -c "! test -f $RUNNER"
PHASE=$(grep '^phase:' ".claude/claudex/$REVIEW_ID.state" | sed 's/^phase: //')
check "phase is now done" test "$PHASE" = "done"

# Verify back-to-back: another /claudex should accept.
section "Back-to-back check (P2 fix in real conditions)"
NEXT_OUTPUT=$(bash "$START" plan "another small feature" 2>&1)
check "second loop accepted after first complete" bash -c "echo '$NEXT_OUTPUT' | grep -qi 'plan mode initialized'"

# Test review mode with mock FCC Codex
section "Review mode test"
# Rollback first to clean up any previous loops
bash "$ROLLBACK" >/dev/null 2>&1
bash "$START" review >/dev/null 2>&1
# Get the most recent state file (by modification time, like claudex_find_active_loop does)
REVIEW_ID2=$(ls -t .claude/claudex/*.state 2>/dev/null | head -1 | xargs basename | sed 's/.state$//')
# Fire hook to generate runner and create reviews directory
echo '{}' | bash "$HOOK" 2>/dev/null >/dev/null
RUNNER2=".claude/claudex/$REVIEW_ID2-runner.sh"
check "review mode runner created" test -f "$RUNNER2"
REVIEW_OUTPUT=$(bash "$RUNNER2" 2>&1)
check "review mode runner exited with code 0" test $? = "0"
check "review findings file created" test -f "reviews/review-$REVIEW_ID2.md"
check "review findings file has content" test -s "reviews/review-$REVIEW_ID2.md"
check "review proposed fixes file created" test -f "reviews/proposed-fixes-$REVIEW_ID2.md"
check "review proposed fixes has content" test -s "reviews/proposed-fixes-$REVIEW_ID2.md"
check "review findings has High section" grep -q "## High" "reviews/review-$REVIEW_ID2.md"
check "review proposed fixes has diff format" grep -q "^--- " "reviews/proposed-fixes-$REVIEW_ID2.md"

# Review mode: phase goes reviewing -> done directly (no rounds)
bash "$MARK_DONE" "$REVIEW_ID2" >/dev/null
echo '{}' | bash "$HOOK" 2>/dev/null >/dev/null  # summarizing fire
echo '{}' | bash "$HOOK" 2>/dev/null >/dev/null  # done fire -> approve

# --- Failure case tests ---

# Test 1: fcc-codex returns non-zero exit code (plan mode)
section "Failure test: fcc-codex non-zero exit (plan mode)"
# Create a mock that exits with code 1
cat > "$MOCK_BIN_DIR/fcc-codex-fail" <<'FAILEOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "fcc-codex 0.171.0 (mock)"; exit 0; fi
cat >/dev/null  # consume stdin
echo "FCC Codex internal error: connection timeout" >&2
exit 1
FAILEOF
chmod +x "$MOCK_BIN_DIR/fcc-codex-fail"

# Set up a fresh plan loop
bash "$ROLLBACK" >/dev/null 2>&1
bash "$START" plan "test failure handling" >/dev/null 2>&1
FAIL_ID=$(ls -t .claude/claudex/*.state 2>/dev/null | head -1 | xargs basename | sed 's/.state$//')
echo "# plan" > PLAN.md
echo '{}' | bash "$HOOK" 2>/dev/null >/dev/null
FAIL_RUNNER=".claude/claudex/$FAIL_ID-runner.sh"

# Temporarily replace fcc-codex with failing version
mv "$MOCK_BIN_DIR/fcc-codex" "$MOCK_BIN_DIR/fcc-codex.orig"
mv "$MOCK_BIN_DIR/fcc-codex-fail" "$MOCK_BIN_DIR/fcc-codex"
bash "$FAIL_RUNNER" 2>&1
# Restore original mock
mv "$MOCK_BIN_DIR/fcc-codex" "$MOCK_BIN_DIR/fcc-codex-fail"
mv "$MOCK_BIN_DIR/fcc-codex.orig" "$MOCK_BIN_DIR/fcc-codex"

# Verify failure marker was written (runner exits 0 due to fail-open)
check "runner exits 0 on fcc-codex failure (fail-open)" test $? = "0"
# Verify failure marker in findings file
check "findings file contains failure marker" grep -q "REVIEW INCOMPLETE" ".claude/claudex/$FAIL_ID/findings-round-1.md"
check "findings file contains exit code" grep -q "Exit code:" ".claude/claudex/$FAIL_ID/findings-round-1.md"
check "raw output preserved" test -f ".claude/claudex/$FAIL_ID/findings-round-1.md.raw"

# Clean up this loop
bash "$MARK_DONE" "$FAIL_ID" >/dev/null 2>&1
echo '{}' | bash "$HOOK" 2>/dev/null >/dev/null
echo '{}' | bash "$HOOK" 2>/dev/null >/dev/null

# Test 2: fcc-codex returns non-zero exit code (review mode)
section "Failure test: fcc-codex non-zero exit (review mode)"
bash "$ROLLBACK" >/dev/null 2>&1
bash "$START" review >/dev/null 2>&1
FAIL_ID2=$(ls -t .claude/claudex/*.state 2>/dev/null | head -1 | xargs basename | sed 's/.state$//')
echo '{}' | bash "$HOOK" 2>/dev/null >/dev/null
FAIL_RUNNER2=".claude/claudex/$FAIL_ID2-runner.sh"

mv "$MOCK_BIN_DIR/fcc-codex" "$MOCK_BIN_DIR/fcc-codex.orig"
mv "$MOCK_BIN_DIR/fcc-codex-fail" "$MOCK_BIN_DIR/fcc-codex"
bash "$FAIL_RUNNER2" 2>&1
mv "$MOCK_BIN_DIR/fcc-codex" "$MOCK_BIN_DIR/fcc-codex-fail"
mv "$MOCK_BIN_DIR/fcc-codex.orig" "$MOCK_BIN_DIR/fcc-codex"

check "review runner exits 0 on fcc-codex failure (fail-open)" test $? = "0"
check "review findings contains failure marker" grep -q "REVIEW INCOMPLETE" "reviews/review-$FAIL_ID2.md"
check "review proposed-fixes contains failure notice" grep -q "Review incomplete" "reviews/proposed-fixes-$FAIL_ID2.md"
check "review raw output preserved" test -f "reviews/review-$FAIL_ID2.md.raw"

# Test 3: Review mode - missing FINDINGS delimiter
section "Failure test: missing FINDINGS delimiter (review mode)"
cat > "$MOCK_BIN_DIR/fcc-codex-no-findings" <<'NOFINDEOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "fcc-codex 0.171.0 (mock)"; exit 0; fi
cat >/dev/null
cat <<OUT
=== PROPOSED FIXES ===

--- a/test.ts
+++ b/test.ts
@@ -1,1 +1,1 @@
-foo
+bar
OUT
exit 0
NOFINDEOF
chmod +x "$MOCK_BIN_DIR/fcc-codex-no-findings"

bash "$ROLLBACK" >/dev/null 2>&1
bash "$START" review >/dev/null 2>&1
FAIL_ID3=$(ls -t .claude/claudex/*.state 2>/dev/null | head -1 | xargs basename | sed 's/.state$//')
echo '{}' | bash "$HOOK" 2>/dev/null >/dev/null
FAIL_RUNNER3=".claude/claudex/$FAIL_ID3-runner.sh"

mv "$MOCK_BIN_DIR/fcc-codex" "$MOCK_BIN_DIR/fcc-codex.orig"
mv "$MOCK_BIN_DIR/fcc-codex-no-findings" "$MOCK_BIN_DIR/fcc-codex"
bash "$FAIL_RUNNER3" 2>&1
mv "$MOCK_BIN_DIR/fcc-codex" "$MOCK_BIN_DIR/fcc-codex-no-findings"
mv "$MOCK_BIN_DIR/fcc-codex.orig" "$MOCK_BIN_DIR/fcc-codex"

check "review runner exits 0 on missing FINDINGS (fail-open)" test $? = "0"
check "findings contains missing FINDINGS marker" grep -q "missing '=== FINDINGS ===' delimiter" "reviews/review-$FAIL_ID3.md"
check "proposed-fixes contains incomplete notice" grep -q "Review incomplete" "reviews/proposed-fixes-$FAIL_ID3.md"

# Test 4: Review mode - missing PROPOSED FIXES delimiter
section "Failure test: missing PROPOSED FIXES delimiter (review mode)"
cat > "$MOCK_BIN_DIR/fcc-codex-no-fixes" <<'NOFIXEOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "fcc-codex 0.171.0 (mock)"; exit 0; fi
cat >/dev/null
cat <<OUT
=== FINDINGS ===

# Review findings

## High
- Test finding
OUT
exit 0
NOFIXEOF
chmod +x "$MOCK_BIN_DIR/fcc-codex-no-fixes"

bash "$ROLLBACK" >/dev/null 2>&1
bash "$START" review >/dev/null 2>&1
FAIL_ID4=$(ls -t .claude/claudex/*.state 2>/dev/null | head -1 | xargs basename | sed 's/.state$//')
echo '{}' | bash "$HOOK" 2>/dev/null >/dev/null
FAIL_RUNNER4=".claude/claudex/$FAIL_ID4-runner.sh"

mv "$MOCK_BIN_DIR/fcc-codex" "$MOCK_BIN_DIR/fcc-codex.orig"
mv "$MOCK_BIN_DIR/fcc-codex-no-fixes" "$MOCK_BIN_DIR/fcc-codex"
bash "$FAIL_RUNNER4" 2>&1
mv "$MOCK_BIN_DIR/fcc-codex" "$MOCK_BIN_DIR/fcc-codex-no-fixes"
mv "$MOCK_BIN_DIR/fcc-codex.orig" "$MOCK_BIN_DIR/fcc-codex"

check "review runner exits 0 on missing PROPOSED FIXES (fail-open)" test $? = "0"
check "findings contains missing PROPOSED FIXES marker" grep -q "missing '=== PROPOSED FIXES ===' delimiter" "reviews/review-$FAIL_ID4.md"
check "proposed-fixes contains incomplete notice" grep -q "Review incomplete" "reviews/proposed-fixes-$FAIL_ID4.md"

# Test 5: Plan mode - malformed output (missing round header)
section "Failure test: malformed output (plan mode)"
cat > "$MOCK_BIN_DIR/fcc-codex-malformed" <<'MALFORMEOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "fcc-codex 0.171.0 (mock)"; exit 0; fi
cat >/dev/null
echo "Some random output without proper format"
exit 0
MALFORMEOF
chmod +x "$MOCK_BIN_DIR/fcc-codex-malformed"

bash "$ROLLBACK" >/dev/null 2>&1
bash "$START" plan "test malformed output" >/dev/null 2>&1
FAIL_ID5=$(ls -t .claude/claudex/*.state 2>/dev/null | head -1 | xargs basename | sed 's/.state$//')
echo "# plan" > PLAN.md
echo '{}' | bash "$HOOK" 2>/dev/null >/dev/null
FAIL_RUNNER5=".claude/claudex/$FAIL_ID5-runner.sh"

mv "$MOCK_BIN_DIR/fcc-codex" "$MOCK_BIN_DIR/fcc-codex.orig"
mv "$MOCK_BIN_DIR/fcc-codex-malformed" "$MOCK_BIN_DIR/fcc-codex"
bash "$FAIL_RUNNER5" 2>&1
mv "$MOCK_BIN_DIR/fcc-codex" "$MOCK_BIN_DIR/fcc-codex-malformed"
mv "$MOCK_BIN_DIR/fcc-codex.orig" "$MOCK_BIN_DIR/fcc-codex"

check "plan runner exits 0 on malformed output (fail-open)" test $? = "0"
check "plan findings contains malformed marker" grep -q "missing expected plan findings format" ".claude/claudex/$FAIL_ID5/findings-round-1.md"
check "plan raw output preserved" test -f ".claude/claudex/$FAIL_ID5/findings-round-1.md.raw"

# Clean up failure test loops
bash "$ROLLBACK" >/dev/null 2>&1

# Test path with spaces
section "Path with spaces test"
SPACE_DIR="$SYNTH_DIR/with spaces/project"
mkdir -p "$SPACE_DIR"
cd "$SPACE_DIR"
git init -q
git commit --allow-empty -q -m "baseline"
bash "$START" plan "test with spaces" >/dev/null 2>&1
SPACE_ID=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs basename | sed 's/.state$//')
echo "# plan" > PLAN.md
echo '{}' | bash "$HOOK" 2>/dev/null >/dev/null
SPACE_RUNNER=".claude/claudex/$SPACE_ID-runner.sh"
bash "$SPACE_RUNNER" 2>&1 >/dev/null
check "runner works with spaces in path" test -f ".claude/claudex/$SPACE_ID/findings-round-1.md"

# Cleanup.
section "Cleanup"
rm -rf "$SYNTH_DIR"
echo "Synthetic project removed."

# Summary.
printf '\n\033[1m=== Synthetic E2E Results ===\033[0m\n'
printf '  \033[32m%d passed\033[0m\n' "$pass"
if [ $fail -gt 0 ]; then
  printf '  \033[31m%d failed\033[0m\n' "$fail"
  exit 1
fi
printf '\n  Synthetic E2E passed. FCC Codex pipeline works end-to-end (mocked).\n'
exit 0
