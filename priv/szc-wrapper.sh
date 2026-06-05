#!/usr/bin/env bash
# szc-wrapper.sh - Shell-based protocol translator for Genswarm
#
# Usage: szc-wrapper.sh <agent_name> <subzeroclaw_path> [skills_dir]
#
# This is a simpler alternative to the Elixir wrapper for environments
# where Elixir might not be available.

AGENT_NAME="$1"
SZC_PATH="$2"
SKILLS_DIR="$3"

if [ -z "$AGENT_NAME" ] || [ -z "$SZC_PATH" ]; then
    echo "Usage: szc-wrapper.sh <agent_name> <subzeroclaw_path> [skills_dir]" >&2
    exit 1
fi

# Set environment
export SUBZEROCLAW_AGENT_NAME="$AGENT_NAME"
if [ -n "$SKILLS_DIR" ]; then
    export SUBZEROCLAW_SKILLS="$SKILLS_DIR"
fi

# Create named pipes for communication
INPUT_PIPE=$(mktemp -u)
OUTPUT_PIPE=$(mktemp -u)
mkfifo "$INPUT_PIPE"
mkfifo "$OUTPUT_PIPE"

# Cleanup on exit
cleanup() {
    rm -f "$INPUT_PIPE" "$OUTPUT_PIPE"
    kill $SZC_PID 2>/dev/null
}
trap cleanup EXIT

# Start subzeroclaw
"$SZC_PATH" < "$INPUT_PIPE" > "$OUTPUT_PIPE" &
SZC_PID=$!

# Process stdin (JSON from orchestrator) and write to subzeroclaw
process_input() {
    while IFS= read -r line; do
        # Try to parse as JSON and translate
        type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)

        case "$type" in
            "task")
                from=$(echo "$line" | jq -r '.from // "orchestrator"')
                content=$(echo "$line" | jq -r '.content // ""')
                echo "[From $from] $content"
                ;;
            "message")
                from=$(echo "$line" | jq -r '.from // "unknown"')
                content=$(echo "$line" | jq -r '.content // ""')
                echo "[From $from] $content"
                ;;
            "system")
                cmd=$(echo "$line" | jq -r '.command // ""')
                echo "/$cmd"
                ;;
            *)
                # Not JSON or unknown type, pass through
                echo "$line"
                ;;
        esac
    done > "$INPUT_PIPE"
}

# Process output from subzeroclaw and convert to JSON
process_output() {
    while IFS= read -r line; do
        # Check for @agent: patterns
        if [[ "$line" =~ @([a-zA-Z_][a-zA-Z0-9_]*):\ *(.*) ]]; then
            target="${BASH_REMATCH[1]}"
            content="${BASH_REMATCH[2]}"

            if [ "$target" = "all" ]; then
                # Escape content for JSON
                escaped_content=$(echo "$content" | jq -Rs '.')
                echo "{\"type\":\"broadcast\",\"content\":$escaped_content}"
            else
                escaped_content=$(echo "$content" | jq -Rs '.')
                echo "{\"type\":\"send\",\"to\":\"$target\",\"content\":$escaped_content}"
            fi
        fi

        # Always output the full line
        escaped_line=$(echo "$line" | jq -Rs '.')
        echo "{\"type\":\"output\",\"content\":$escaped_line}"
    done < "$OUTPUT_PIPE"
}

# Run both processors
process_input &
INPUT_PID=$!

process_output &
OUTPUT_PID=$!

# Wait for subzeroclaw to exit
wait $SZC_PID
EXIT_STATUS=$?

# Output exit message
echo "{\"type\":\"exit\",\"status\":$EXIT_STATUS}"

# Clean up
kill $INPUT_PID $OUTPUT_PID 2>/dev/null
exit $EXIT_STATUS
