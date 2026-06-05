#!/usr/bin/env bash
#
# Run all Genswarm tests
#
# Usage: ./scripts/test_all.sh [cli|api]
#
# Without arguments, runs both CLI and API tests.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}Genswarm Full Test Suite${NC}"
echo -e "${YELLOW}============================================${NC}"

if [ "$1" = "cli" ]; then
    echo ""
    echo -e "${YELLOW}Running CLI tests only...${NC}"
    "$SCRIPT_DIR/test_cli.sh"
    exit $?
elif [ "$1" = "api" ]; then
    echo ""
    echo -e "${YELLOW}Running API tests only...${NC}"
    "$SCRIPT_DIR/test_api.sh"
    exit $?
fi

# Run both tests
CLI_RESULT=0
API_RESULT=0

echo ""
echo -e "${YELLOW}Running CLI tests...${NC}"
echo ""
"$SCRIPT_DIR/test_cli.sh" || CLI_RESULT=$?

echo ""
echo -e "${YELLOW}Running API tests...${NC}"
echo ""
"$SCRIPT_DIR/test_api.sh" || API_RESULT=$?

# Summary
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}Final Summary${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""

if [ $CLI_RESULT -eq 0 ]; then
    echo -e "CLI Tests: ${GREEN}PASSED${NC}"
else
    echo -e "CLI Tests: ${RED}FAILED${NC}"
fi

if [ $API_RESULT -eq 0 ]; then
    echo -e "API Tests: ${GREEN}PASSED${NC}"
else
    echo -e "API Tests: ${RED}FAILED${NC}"
fi

echo ""

if [ $CLI_RESULT -eq 0 ] && [ $API_RESULT -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
