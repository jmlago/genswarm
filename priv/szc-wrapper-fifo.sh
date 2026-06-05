#!/usr/bin/env bash
# szc-wrapper-fifo.sh - FIFO-based protocol translator for Genswarm
#
# Usage: szc-wrapper-fifo.sh <agent_name> <subzeroclaw_path> [skills_dir]

AGENT_NAME="$1"
SZC_PATH="${2:-subzeroclaw}"
SKILLS_DIR="$3"

if [ -z "$AGENT_NAME" ] || [ -z "$SZC_PATH" ]; then
    echo '{"type":"error","content":"Usage: szc-wrapper-fifo.sh <agent_name> <subzeroclaw_path> [skills_dir]"}' >&2
    exit 1
fi

# Set environment
export SUBZEROCLAW_AGENT_NAME="$AGENT_NAME"
[ -n "$SKILLS_DIR" ] && export SUBZEROCLAW_SKILLS="$SKILLS_DIR"

# Create temp FIFOs
FIFO_DIR=$(mktemp -d)
INPUT_FIFO="$FIFO_DIR/input"
OUTPUT_FIFO="$FIFO_DIR/output"
mkfifo "$INPUT_FIFO" "$OUTPUT_FIFO"

# Cleanup on exit
cleanup() {
    rm -rf "$FIFO_DIR"
    [ -n "$SZC_PID" ] && kill $SZC_PID 2>/dev/null
    [ -n "$OUTPUT_PID" ] && kill $OUTPUT_PID 2>/dev/null
}
trap cleanup EXIT

# Helper function: escape string for JSON
json_escape() {
    printf '%s' "$1" | jq -Rs '.'
}

# Process output from subzeroclaw
process_output() {
    while IFS= read -r line; do
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
        # Always output the line as JSON
        echo "{\"type\":\"output\",\"content\":$(json_escape "$line")}"
    done < "$OUTPUT_FIFO"
}

# Start output processor in background
process_output &
OUTPUT_PID=$!

# Start subzeroclaw with FIFOs
"$SZC_PATH" < "$INPUT_FIFO" > "$OUTPUT_FIFO" 2>&1 &
SZC_PID=$!

# Open input FIFO for writing (this blocks until subzeroclaw opens it for reading)
exec 3>"$INPUT_FIFO"

# Process stdin (JSON from orchestrator) and send to subzeroclaw
while IFS= read -r line; do
    msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
    case "$msg_type" in
        "task"|"message")
            from=$(echo "$line" | jq -r '.from // "orchestrator"')
            content=$(echo "$line" | jq -r '.content // ""')
            echo "[From $from] $content" >&3
            ;;
        "system")
            cmd=$(echo "$line" | jq -r '.command // ""')
            echo "/$cmd" >&3
            ;;
        *)
            # Pass through as-is
            echo "$line" >&3
            ;;
    esac
done

# Close input pipe
exec 3>&-

# Wait for subzeroclaw to finish
wait $SZC_PID 2>/dev/null
EXIT_STATUS=$?

# Wait for output processing
wait $OUTPUT_PID 2>/dev/null

echo "{\"type\":\"exit\",\"status\":$EXIT_STATUS}"
exit $EXIT_STATUS
