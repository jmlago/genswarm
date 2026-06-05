#!/usr/bin/env bash
# szc-wrapper-direct.sh - Direct protocol translator for Genswarm
#
# Usage: szc-wrapper-direct.sh <agent_name> <subzeroclaw_path> [skills_dir]
#
# Simpler wrapper that connects stdin/stdout directly and uses coprocesses.

AGENT_NAME="$1"
SZC_PATH="${2:-subzeroclaw}"
SKILLS_DIR="$3"

if [ -z "$AGENT_NAME" ] || [ -z "$SZC_PATH" ]; then
    echo '{"type":"error","content":"Usage: szc-wrapper-direct.sh <agent_name> <subzeroclaw_path> [skills_dir]"}' >&2
    exit 1
fi

# Set environment
export SUBZEROCLAW_AGENT_NAME="$AGENT_NAME"
[ -n "$SKILLS_DIR" ] && export SUBZEROCLAW_SKILLS="$SKILLS_DIR"

# Helper function: extract JSON field value (simple parsing without jq for fallback)
get_json_field() {
    local json="$1"
    local field="$2"
    echo "$json" | jq -r ".${field} // empty" 2>/dev/null
}

# Helper function: escape string for JSON
json_escape() {
    printf '%s' "$1" | jq -Rs '.'
}

# Start subzeroclaw as coprocess
coproc SZC { "$SZC_PATH" 2>&1; }

# Read output from subzeroclaw and emit as JSON
process_output() {
    while IFS= read -r line <&"${SZC[0]}"; do
        # Check for @agent: patterns
        if [[ "$line" =~ @([a-zA-Z_][a-zA-Z0-9_]*):\ *(.*) ]]; then
            target="${BASH_REMATCH[1]}"
            content="${BASH_REMATCH[2]}"
            if [ "$target" = "all" ]; then
                echo "{\"type\":\"broadcast\",\"content\":$(json_escape "$content")}"
            else
                echo "{\"type\":\"send\",\"to\":\"$target\",\"content\":$(json_escape "$content")}"
            fi
        fi
        # Always output the line
        echo "{\"type\":\"output\",\"content\":$(json_escape "$line")}"
    done
}

# Process stdin (JSON from orchestrator)
process_input() {
    while IFS= read -r line; do
        msg_type=$(get_json_field "$line" "type")
        case "$msg_type" in
            "task"|"message")
                from=$(get_json_field "$line" "from")
                content=$(get_json_field "$line" "content")
                [ -z "$from" ] && from="orchestrator"
                echo "[From $from] $content" >&"${SZC[1]}"
                ;;
            "system")
                cmd=$(get_json_field "$line" "command")
                echo "/$cmd" >&"${SZC[1]}"
                ;;
            *)
                # Not JSON or unknown type, pass through
                echo "$line" >&"${SZC[1]}"
                ;;
        esac
    done
}

# Run output processor in background
process_output &
OUTPUT_PID=$!

# Run input processor (blocks until stdin closes)
process_input

# Wait for coprocess to exit
wait $SZC_PID 2>/dev/null
EXIT_STATUS=$?

# Clean up
kill $OUTPUT_PID 2>/dev/null

echo "{\"type\":\"exit\",\"status\":$EXIT_STATUS}"
exit $EXIT_STATUS
