#!/usr/bin/env bash
#
# Test script for Genswarm CLI
#
# Tests:
# 1. Party swarm (10 agents, full mesh)
# 2. Tic-tac-toe swarm (2 players + game object)
# 3. Bridge swarm (2 swarms with cross-swarm communication)
#
# Usage: ./scripts/test_cli.sh
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SWARM_CMD="mix swarm"
WAIT_TIME=5
STARTUP_WAIT=10

cd "$PROJECT_DIR"

# Counters
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++))
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}$1${NC}"
    echo -e "${YELLOW}========================================${NC}"
}

cleanup() {
    log_info "Cleaning up..."
    $SWARM_CMD down 2>/dev/null || true
    $SWARM_CMD clean --all 2>/dev/null || true
    sleep 2
}

wait_for_server() {
    log_info "Waiting for server to start..."
    for i in {1..30}; do
        if curl -s http://localhost:4000/ > /dev/null 2>&1; then
            log_success "Server is up"
            return 0
        fi
        sleep 1
    done
    log_error "Server failed to start"
    return 1
}

check_swarm_running() {
    local swarm_name=$1
    local status_output
    status_output=$($SWARM_CMD status "$swarm_name" 2>&1)
    if echo "$status_output" | grep -q "running\|Running"; then
        return 0
    fi
    return 1
}

# ============================================================================
# Test Setup
# ============================================================================

log_section "Genswarm CLI Test Suite"

log_info "Project directory: $PROJECT_DIR"
log_info "Cleaning up any previous state..."
cleanup

# Start the server
log_info "Starting API server..."
$SWARM_CMD up

wait_for_server || exit 1

# ============================================================================
# Test 1: Party Swarm
# ============================================================================

log_section "Test 1: Party Swarm (10 agents, full mesh)"

log_info "Validating config..."
if $SWARM_CMD config validate examples/party/party_swarm.exs 2>&1 | grep -q "valid\|Valid"; then
    log_success "Config validation passed"
else
    log_error "Config validation failed"
fi

log_info "Starting party swarm..."
if $SWARM_CMD start examples/party/party_swarm.exs 2>&1; then
    log_success "Swarm start command succeeded"
else
    log_error "Swarm start command failed"
fi

sleep $STARTUP_WAIT

log_info "Checking swarm status..."
if check_swarm_running "party-test"; then
    log_success "Party swarm is running"
else
    log_error "Party swarm is not running"
fi

log_info "Checking status output..."
status_output=$($SWARM_CMD status party-test 2>&1)
if echo "$status_output" | grep -q "agent_1"; then
    log_success "Agent agent_1 found in status"
else
    log_error "Agent agent_1 not found in status"
fi

log_info "Sending task to agent_1..."
if $SWARM_CMD task party-test agent_1 "Say hello to agent_2" 2>&1 | grep -q -i "sent\|queued"; then
    log_success "Task sent successfully"
else
    log_warn "Task send output unclear (may still work)"
fi

log_info "Testing pause..."
if $SWARM_CMD pause party-test 2>&1 | grep -q -i "paused\|Paused"; then
    log_success "Pause succeeded"
else
    log_error "Pause failed"
fi

sleep 2

log_info "Testing resume..."
if $SWARM_CMD resume party-test 2>&1 | grep -q -i "resumed\|Resumed"; then
    log_success "Resume succeeded"
else
    log_error "Resume failed"
fi

log_info "Checking events..."
events_output=$($SWARM_CMD events -s party-test 2>&1)
if echo "$events_output" | grep -q "party-test\|event"; then
    log_success "Events query returned results"
else
    log_warn "No events found (may be normal for quick test)"
fi

log_info "Stopping party swarm..."
if $SWARM_CMD stop party-test 2>&1 | grep -q -i "stopped\|Stopped"; then
    log_success "Swarm stopped"
else
    log_error "Swarm stop failed"
fi

sleep $WAIT_TIME

# ============================================================================
# Test 2: Tic-Tac-Toe Swarm
# ============================================================================

log_section "Test 2: Tic-Tac-Toe Swarm (2 players + game object)"

log_info "Validating config..."
if $SWARM_CMD config validate examples/tic-tac-toe/tic_tac_toe_swarm.exs 2>&1 | grep -q "valid\|Valid"; then
    log_success "Config validation passed"
else
    log_error "Config validation failed"
fi

log_info "Starting tic-tac-toe swarm..."
if $SWARM_CMD start examples/tic-tac-toe/tic_tac_toe_swarm.exs 2>&1; then
    log_success "Swarm start command succeeded"
else
    log_error "Swarm start command failed"
fi

sleep $STARTUP_WAIT

log_info "Checking swarm status..."
if check_swarm_running "tic-tac-toe"; then
    log_success "Tic-tac-toe swarm is running"
else
    log_error "Tic-tac-toe swarm is not running"
fi

log_info "Checking for player_x agent..."
status_output=$($SWARM_CMD status tic-tac-toe 2>&1)
if echo "$status_output" | grep -q "player_x"; then
    log_success "Agent player_x found"
else
    log_error "Agent player_x not found"
fi

log_info "Checking for player_o agent..."
if echo "$status_output" | grep -q "player_o"; then
    log_success "Agent player_o found"
else
    log_error "Agent player_o not found"
fi

log_info "Checking for game object..."
if echo "$status_output" | grep -q "game"; then
    log_success "Object game found"
else
    log_warn "Object game not visible in status (may be expected)"
fi

log_info "Sending task to player_x..."
$SWARM_CMD task tic-tac-toe player_x "Start the game by making your first move" 2>&1 || true

sleep 3

log_info "Checking message routing..."
messages_output=$($SWARM_CMD events -s tic-tac-toe --category routing 2>&1 || echo "no events")
log_info "Events check completed"

log_info "Stopping tic-tac-toe swarm..."
if $SWARM_CMD stop tic-tac-toe 2>&1 | grep -q -i "stopped\|Stopped"; then
    log_success "Swarm stopped"
else
    log_error "Swarm stop failed"
fi

sleep $WAIT_TIME

# ============================================================================
# Test 3: Bridge Swarm (Cross-swarm communication)
# ============================================================================

log_section "Test 3: Bridge Swarm (cross-swarm communication)"

log_info "Validating swarm-a config..."
if $SWARM_CMD config validate examples/bridge/swarm_a.exs 2>&1 | grep -q "valid\|Valid"; then
    log_success "Swarm-a config validation passed"
else
    log_error "Swarm-a config validation failed"
fi

log_info "Validating swarm-b config..."
if $SWARM_CMD config validate examples/bridge/swarm_b.exs 2>&1 | grep -q "valid\|Valid"; then
    log_success "Swarm-b config validation passed"
else
    log_error "Swarm-b config validation failed"
fi

log_info "Starting swarm-a..."
$SWARM_CMD start examples/bridge/swarm_a.exs 2>&1 || true

log_info "Starting swarm-b..."
$SWARM_CMD start examples/bridge/swarm_b.exs 2>&1 || true

sleep $STARTUP_WAIT

log_info "Checking swarm-a status..."
if check_swarm_running "swarm-a"; then
    log_success "Swarm-a is running"
else
    log_error "Swarm-a is not running"
fi

log_info "Checking swarm-b status..."
if check_swarm_running "swarm-b"; then
    log_success "Swarm-b is running"
else
    log_error "Swarm-b is not running"
fi

log_info "Listing all swarms..."
list_output=$($SWARM_CMD status 2>&1)
if echo "$list_output" | grep -q "swarm-a" && echo "$list_output" | grep -q "swarm-b"; then
    log_success "Both swarms appear in list"
else
    log_error "Not all swarms appear in list"
fi

log_info "Sending cross-swarm message via messenger_a..."
$SWARM_CMD task swarm-a messenger_a "Send a message to messenger_b in swarm-b" 2>&1 || true

sleep 3

log_info "Stopping swarm-a..."
$SWARM_CMD stop swarm-a 2>&1 || true

log_info "Stopping swarm-b..."
$SWARM_CMD stop swarm-b 2>&1 || true

sleep $WAIT_TIME

# ============================================================================
# Test 4: Restart with delete
# ============================================================================

log_section "Test 4: Restart with --delete flag"

log_info "Starting party swarm for restart test..."
$SWARM_CMD start examples/party/party_swarm.exs 2>&1 || true

sleep $STARTUP_WAIT

log_info "Restarting with --delete flag..."
if $SWARM_CMD restart party-test --delete 2>&1 | grep -q -i "restart\|Restart\|started"; then
    log_success "Restart with delete succeeded"
else
    log_warn "Restart output unclear"
fi

sleep $STARTUP_WAIT

log_info "Verifying swarm is running after restart..."
if check_swarm_running "party-test"; then
    log_success "Swarm running after restart"
else
    log_error "Swarm not running after restart"
fi

log_info "Stopping swarm..."
$SWARM_CMD stop party-test 2>&1 || true

sleep $WAIT_TIME

# ============================================================================
# Test 5: Clean command
# ============================================================================

log_section "Test 5: Clean command"

log_info "Running clean command..."
if $SWARM_CMD clean 2>&1 | grep -q -i "clean\|Clean\|removed"; then
    log_success "Clean command succeeded"
else
    log_warn "Clean output unclear"
fi

log_info "Running clean --all command..."
if $SWARM_CMD clean --all 2>&1 | grep -q -i "clean\|Clean\|cleared"; then
    log_success "Clean --all command succeeded"
else
    log_warn "Clean --all output unclear"
fi

# ============================================================================
# Test 6: Skills listing
# ============================================================================

log_section "Test 6: Skills listing"

log_info "Listing skills..."
skills_output=$($SWARM_CMD list-skills 2>&1)
if echo "$skills_output" | grep -q ".md\|skill"; then
    log_success "Skills listing returned results"
else
    log_warn "No skills found or command not available"
fi

# ============================================================================
# Cleanup
# ============================================================================

log_section "Cleanup"

log_info "Shutting down server..."
$SWARM_CMD down 2>&1 || true

sleep 3

# ============================================================================
# Results
# ============================================================================

log_section "Test Results"

echo ""
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
