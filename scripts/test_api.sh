#!/usr/bin/env bash
#
# Test script for Genswarm REST API
#
# Tests:
# 1. Party swarm (10 agents, full mesh)
# 2. Tic-tac-toe swarm (2 players + game object)
# 3. Bridge swarm (2 swarms with cross-swarm communication)
#
# Usage: ./scripts/test_api.sh
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
API_BASE="http://localhost:4000"
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
    curl -s -X POST "$API_BASE/api/swarms/clean?all=true" > /dev/null 2>&1 || true
    sleep 2
}

wait_for_server() {
    log_info "Waiting for server to start..."
    for i in {1..30}; do
        if curl -s "$API_BASE/" > /dev/null 2>&1; then
            log_success "Server is up"
            return 0
        fi
        sleep 1
    done
    log_error "Server failed to start"
    return 1
}

api_get() {
    curl -s -X GET "$API_BASE$1" -H "Content-Type: application/json"
}

api_post() {
    curl -s -X POST "$API_BASE$1" -H "Content-Type: application/json" -d "$2"
}

api_delete() {
    curl -s -X DELETE "$API_BASE$1" -H "Content-Type: application/json"
}

api_put() {
    curl -s -X PUT "$API_BASE$1" -H "Content-Type: application/json" -d "$2"
}

check_json_field() {
    local json=$1
    local field=$2
    local expected=$3
    if echo "$json" | grep -q "\"$field\".*$expected"; then
        return 0
    fi
    return 1
}

# ============================================================================
# Test Setup
# ============================================================================

log_section "Genswarm REST API Test Suite"

log_info "Project directory: $PROJECT_DIR"
log_info "API base URL: $API_BASE"
log_info "Cleaning up any previous state..."
cleanup

# Start the server
log_info "Starting API server..."
$SWARM_CMD up

wait_for_server || exit 1

# ============================================================================
# Test 0: API Root
# ============================================================================

log_section "Test 0: API Root"

log_info "Testing GET /"
response=$(api_get "/")
if echo "$response" | grep -q "Genswarm API"; then
    log_success "API root returns API info"
else
    log_error "API root response invalid"
    echo "Response: $response"
fi

if echo "$response" | grep -q "websocket"; then
    log_success "API root includes WebSocket info"
else
    log_error "API root missing WebSocket info"
fi

# ============================================================================
# Test 1: Party Swarm via API
# ============================================================================

log_section "Test 1: Party Swarm via API"

log_info "Testing config validation..."
response=$(api_post "/api/config/validate" '{"config_path": "examples/party/party_swarm.exs"}')
if echo "$response" | grep -q '"valid":true'; then
    log_success "Config validation passed"
else
    log_error "Config validation failed"
    echo "Response: $response"
fi

log_info "Creating party swarm..."
response=$(api_post "/api/swarms" '{"config_path": "examples/party/party_swarm.exs"}')
if echo "$response" | grep -q '"status":"created"\|"swarm_name":"party-test"'; then
    log_success "Swarm created via API"
else
    log_error "Swarm creation failed"
    echo "Response: $response"
fi

sleep $STARTUP_WAIT

log_info "Listing all swarms..."
response=$(api_get "/api/swarms")
if echo "$response" | grep -q "party-test"; then
    log_success "Party swarm appears in list"
else
    log_error "Party swarm not in list"
    echo "Response: $response"
fi

log_info "Getting detailed swarm status..."
response=$(api_get "/api/swarms/party-test")
if echo "$response" | grep -q "agent_1"; then
    log_success "Detailed status includes agents"
else
    log_error "Detailed status missing agents"
    echo "Response: $response"
fi

if echo "$response" | grep -q "topology"; then
    log_success "Detailed status includes topology"
else
    log_warn "Topology not in response"
fi

if echo "$response" | grep -q "file_paths"; then
    log_success "Detailed status includes file paths"
else
    log_warn "File paths not in response"
fi

log_info "Listing agents..."
response=$(api_get "/api/swarms/party-test/agents")
if echo "$response" | grep -q "agent_1\|agents"; then
    log_success "Agents list returned"
else
    log_error "Agents list failed"
    echo "Response: $response"
fi

log_info "Getting single agent status..."
response=$(api_get "/api/swarms/party-test/agents/agent_1")
if echo "$response" | grep -q "agent_1\|name"; then
    log_success "Single agent status returned"
else
    log_error "Single agent status failed"
    echo "Response: $response"
fi

log_info "Sending task to agent..."
response=$(api_post "/api/swarms/party-test/agents/agent_1/task" '{"task": "Say hello to agent_2"}')
if echo "$response" | grep -q '"status":"sent"'; then
    log_success "Task sent successfully"
else
    log_warn "Task response unclear: $response"
fi

log_info "Getting topology..."
response=$(api_get "/api/swarms/party-test/topology")
if echo "$response" | grep -q "topology\|agent_1"; then
    log_success "Topology returned"
else
    log_error "Topology request failed"
    echo "Response: $response"
fi

log_info "Getting message log..."
response=$(api_get "/api/swarms/party-test/messages")
if echo "$response" | grep -q "messages"; then
    log_success "Message log returned"
else
    log_error "Message log request failed"
    echo "Response: $response"
fi

log_info "Testing pause..."
response=$(api_post "/api/swarms/party-test/pause" '{}')
if echo "$response" | grep -q '"status":"paused"'; then
    log_success "Pause succeeded"
else
    log_error "Pause failed"
    echo "Response: $response"
fi

sleep 2

log_info "Testing resume..."
response=$(api_post "/api/swarms/party-test/resume" '{}')
if echo "$response" | grep -q '"status":"resumed"'; then
    log_success "Resume succeeded"
else
    log_error "Resume failed"
    echo "Response: $response"
fi

log_info "Getting events..."
response=$(api_get "/api/swarms/party-test/events")
if echo "$response" | grep -q "events"; then
    log_success "Swarm events returned"
else
    log_error "Swarm events request failed"
    echo "Response: $response"
fi

log_info "Testing message routing..."
response=$(api_post "/api/swarms/party-test/message" '{"from": "agent_1", "to": "agent_2", "content": "Hello from API!"}')
if echo "$response" | grep -q '"status":"routed"'; then
    log_success "Message routing succeeded"
else
    log_error "Message routing failed"
    echo "Response: $response"
fi

log_info "Stopping swarm..."
response=$(api_delete "/api/swarms/party-test")
if echo "$response" | grep -q '"status":"stopped"'; then
    log_success "Swarm stopped"
else
    log_error "Swarm stop failed"
    echo "Response: $response"
fi

sleep $WAIT_TIME

# ============================================================================
# Test 2: Tic-Tac-Toe Swarm via API
# ============================================================================

log_section "Test 2: Tic-Tac-Toe Swarm via API"

log_info "Validating config..."
response=$(api_post "/api/config/validate" '{"config_path": "examples/tic-tac-toe/tic_tac_toe_swarm.exs"}')
if echo "$response" | grep -q '"valid":true'; then
    log_success "Config validation passed"
else
    log_error "Config validation failed"
    echo "Response: $response"
fi

log_info "Creating tic-tac-toe swarm..."
response=$(api_post "/api/swarms" '{"config_path": "examples/tic-tac-toe/tic_tac_toe_swarm.exs"}')
if echo "$response" | grep -q '"status":"created"\|"swarm_name":"tic-tac-toe"'; then
    log_success "Swarm created"
else
    log_error "Swarm creation failed"
    echo "Response: $response"
fi

sleep $STARTUP_WAIT

log_info "Getting swarm status..."
response=$(api_get "/api/swarms/tic-tac-toe")
if echo "$response" | grep -q "player_x"; then
    log_success "Player X found in status"
else
    log_error "Player X not found"
    echo "Response: $response"
fi

if echo "$response" | grep -q "player_o"; then
    log_success "Player O found in status"
else
    log_error "Player O not found"
fi

log_info "Sending task to player_x..."
response=$(api_post "/api/swarms/tic-tac-toe/agents/player_x/task" '{"task": "Start the game with your first move"}')
if echo "$response" | grep -q "sent\|status"; then
    log_success "Task sent to player_x"
else
    log_warn "Task response: $response"
fi

sleep 3

log_info "Getting agent history..."
response=$(api_get "/api/swarms/tic-tac-toe/agents/player_x/history")
if echo "$response" | grep -q "history"; then
    log_success "Agent history returned"
else
    log_warn "Agent history response unclear"
fi

log_info "Getting agent skills..."
response=$(api_get "/api/swarms/tic-tac-toe/agents/player_x/skills")
if echo "$response" | grep -q "skills"; then
    log_success "Agent skills returned"
else
    log_warn "Agent skills response unclear"
fi

log_info "Testing restart endpoint..."
response=$(api_post "/api/swarms/tic-tac-toe/restart" '{}')
if echo "$response" | grep -q '"status":"restarted"'; then
    log_success "Restart succeeded"
else
    log_warn "Restart response: $response"
fi

sleep $STARTUP_WAIT

log_info "Stopping with purge..."
response=$(api_delete "/api/swarms/tic-tac-toe?purge=true")
if echo "$response" | grep -q '"status":"purged"\|"status":"stopped"'; then
    log_success "Swarm purged"
else
    log_error "Swarm purge failed"
    echo "Response: $response"
fi

sleep $WAIT_TIME

# ============================================================================
# Test 3: Bridge Swarms via API
# ============================================================================

log_section "Test 3: Bridge Swarms via API"

log_info "Creating swarm-a..."
response=$(api_post "/api/swarms" '{"config_path": "examples/bridge/swarm_a.exs"}')
if echo "$response" | grep -q "swarm-a\|created"; then
    log_success "Swarm-a created"
else
    log_error "Swarm-a creation failed"
    echo "Response: $response"
fi

log_info "Creating swarm-b..."
response=$(api_post "/api/swarms" '{"config_path": "examples/bridge/swarm_b.exs"}')
if echo "$response" | grep -q "swarm-b\|created"; then
    log_success "Swarm-b created"
else
    log_error "Swarm-b creation failed"
    echo "Response: $response"
fi

sleep $STARTUP_WAIT

log_info "Listing all swarms..."
response=$(api_get "/api/swarms")
swarm_count=$(echo "$response" | grep -o '"name"' | wc -l)
if [ "$swarm_count" -ge 2 ]; then
    log_success "Multiple swarms listed ($swarm_count)"
else
    log_error "Expected at least 2 swarms, got $swarm_count"
    echo "Response: $response"
fi

log_info "Getting swarm-a status..."
response=$(api_get "/api/swarms/swarm-a")
if echo "$response" | grep -q "messenger_a"; then
    log_success "Messenger_a found in swarm-a"
else
    log_error "Messenger_a not found"
    echo "Response: $response"
fi

log_info "Getting swarm-b status..."
response=$(api_get "/api/swarms/swarm-b")
if echo "$response" | grep -q "messenger_b"; then
    log_success "Messenger_b found in swarm-b"
else
    log_error "Messenger_b not found"
    echo "Response: $response"
fi

log_info "Sending cross-swarm message..."
response=$(api_post "/api/swarms/swarm-a/agents/messenger_a/task" '{"task": "Send a greeting to messenger_b in swarm-b via the bridge"}')
log_info "Task sent (cross-swarm)"

sleep 3

log_info "Stopping swarm-a..."
api_delete "/api/swarms/swarm-a" > /dev/null

log_info "Stopping swarm-b..."
api_delete "/api/swarms/swarm-b" > /dev/null

sleep $WAIT_TIME

# ============================================================================
# Test 4: Events API
# ============================================================================

log_section "Test 4: Events API"

log_info "Getting all events..."
response=$(api_get "/api/events")
if echo "$response" | grep -q "events"; then
    log_success "Events endpoint works"
else
    log_error "Events endpoint failed"
    echo "Response: $response"
fi

log_info "Getting events with filters..."
response=$(api_get "/api/events?level=info&limit=10")
if echo "$response" | grep -q "events"; then
    log_success "Filtered events returned"
else
    log_warn "Filtered events response unclear"
fi

# ============================================================================
# Test 5: Skills API
# ============================================================================

log_section "Test 5: Skills API"

log_info "Listing skills..."
response=$(api_get "/api/skills")
if echo "$response" | grep -q "skills"; then
    log_success "Skills list returned"
else
    log_error "Skills list failed"
    echo "Response: $response"
fi

# ============================================================================
# Test 6: Clean API
# ============================================================================

log_section "Test 6: Clean API"

log_info "Running clean endpoint..."
response=$(api_post "/api/swarms/clean" '{}')
if echo "$response" | grep -q '"status":"cleaned"'; then
    log_success "Clean endpoint works"
else
    log_warn "Clean response: $response"
fi

log_info "Running clean with all flag..."
response=$(api_post "/api/swarms/clean?all=true" '{}')
if echo "$response" | grep -q '"events_cleared":true\|"status":"cleaned"'; then
    log_success "Clean all endpoint works"
else
    log_warn "Clean all response: $response"
fi

# ============================================================================
# Test 7: Error handling
# ============================================================================

log_section "Test 7: Error Handling"

log_info "Testing 404 for non-existent swarm..."
response=$(api_get "/api/swarms/nonexistent-swarm-12345")
if echo "$response" | grep -q "not found\|error\|404"; then
    log_success "404 returned for non-existent swarm"
else
    log_error "Expected 404 for non-existent swarm"
    echo "Response: $response"
fi

log_info "Testing invalid task request..."
response=$(api_post "/api/swarms/nonexistent/agents/agent/task" '{}')
if echo "$response" | grep -q "error\|Missing"; then
    log_success "Error returned for invalid request"
else
    log_warn "Response for invalid request: $response"
fi

log_info "Testing invalid config validation..."
response=$(api_post "/api/config/validate" '{"config": {"name": "test"}}')
if echo "$response" | grep -q "valid.*false\|error"; then
    log_success "Validation fails for incomplete config"
else
    log_warn "Validation response: $response"
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
