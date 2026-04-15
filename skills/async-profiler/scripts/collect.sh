#!/usr/bin/env bash
# collect.sh — Agent-friendly async-profiler background collection.
#
# Designed for coding agents that need to start profiling without blocking
# so they can reproduce the problem, run load, or do other work while data
# is being collected.
#
# Usage:
#   bash scripts/collect.sh start <PID|app-name> [--asprof PATH]
#   bash scripts/collect.sh stop  <PID|app-name> [--asprof PATH]
#   bash scripts/collect.sh timed [-d N] <PID|app-name> [--asprof PATH]
#
# Subcommands:
#   start   Attach asprof and begin recording all events; returns immediately.
#           Session state is saved to /tmp so 'stop' knows where to write output.
#   stop    Stop the active session, split the JFR into four per-event flamegraphs
#           in parallel (cpu, alloc, wall, lock), then print paths to all outputs.
#   timed   Fixed-duration all-event capture that blocks for the duration.
#           Run with & to let the agent continue working; then: wait $PROF_PID
#
# Agent workflow — start/stop (full control):
#   bash scripts/collect.sh start 12345
#   # ... reproduce the problem, trigger load, wait for requests, etc. ...
#   bash scripts/collect.sh stop 12345
#
# Agent workflow — timed background:
#   bash scripts/collect.sh timed -d 30 12345 &
#   PROF_PID=$!
#   # ... trigger load while profiling runs ...
#   wait $PROF_PID
#
# Output layout:
#   profile-<target>-<timestamp>/
#     combined.jfr          — multi-event JFR (open in IntelliJ or JMC)
#     profile-cpu.html      — CPU flamegraph
#     profile-alloc.html    — allocation flamegraph
#     profile-wall.html     — wall-clock flamegraph
#     profile-lock.html     — lock contention flamegraph

set -euo pipefail

# ── Parse subcommand ──────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
    sed -n '2,35p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
fi

SUBCMD="$1"; shift

# ── Parse options ─────────────────────────────────────────────────────────────
DURATION=30
TARGET=""
ASPROF_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--duration) DURATION="$2"; shift 2 ;;
        --asprof)      ASPROF_ARG="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,35p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            echo "❌ Unknown option: $1" >&2
            exit 1
            ;;
        *)
            TARGET="$1"; shift ;;
    esac
done

if [[ -z "$TARGET" && "$SUBCMD" != "help" ]]; then
    echo "❌ No target specified. Provide a PID or app name." >&2
    echo "   List Java processes: jps -l" >&2
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
locate_asprof() {
    local asprof=""
    if [[ -n "$ASPROF_ARG" ]]; then
        asprof="$ASPROF_ARG"
    elif command -v asprof &>/dev/null; then
        asprof="$(command -v asprof)"
    else
        for candidate in \
            "$HOME/async-profiler-4.3/bin/asprof" \
            "$HOME/async-profiler/bin/asprof" \
            "/opt/async-profiler/bin/asprof" \
            "/usr/local/bin/asprof"
        do
            if [[ -x "$candidate" ]]; then
                asprof="$candidate"
                break
            fi
        done
    fi
    if [[ -z "$asprof" ]]; then
        echo "❌ asprof not found. Install with: bash scripts/install.sh" >&2
        exit 1
    fi
    echo "$asprof"
}

locate_jfrconv() {
    local asprof="$1"
    if command -v jfrconv &>/dev/null; then
        command -v jfrconv
    elif [[ -x "$(dirname "$asprof")/jfrconv" ]]; then
        echo "$(dirname "$asprof")/jfrconv"
    else
        echo ""
    fi
}

# Session state file — stores output path and asprof path between start/stop.
session_file() {
    local safe; safe="${TARGET//[^a-zA-Z0-9_-]/_}"
    echo "/tmp/asprof-session-${safe}"
}

split_jfr() {
    local jfrconv="$1"
    local jfr_path="$2"
    local base="$3"

    local cpu_html="${base}-cpu.html"
    local alloc_html="${base}-alloc.html"
    local wall_html="${base}-wall.html"
    local lock_html="${base}-lock.html"

    echo "Splitting JFR into per-event flamegraphs in parallel..."
    # jfrconv: event flag must come FIRST, before the input file
    "$jfrconv" --cpu   "$jfr_path" "$cpu_html"   & local pid_cpu=$!
    "$jfrconv" --alloc "$jfr_path" "$alloc_html" & local pid_alloc=$!
    "$jfrconv" --wall  "$jfr_path" "$wall_html"  & local pid_wall=$!
    "$jfrconv" --lock  "$jfr_path" "$lock_html"  & local pid_lock=$!
    wait $pid_cpu $pid_alloc $pid_wall $pid_lock

    echo ""
    echo "📊 Flamegraphs ready:"
    echo "   CPU time        : $cpu_html"
    echo "   Allocations     : $alloc_html"
    echo "   Wall-clock      : $wall_html"
    echo "   Lock contention : $lock_html"
    echo "   Combined JFR    : $jfr_path"

    if [[ "$(uname)" == "Darwin" ]]; then
        echo ""
        echo "Opening all flamegraphs in browser..."
        open "$cpu_html" "$alloc_html" "$wall_html" "$lock_html"
    fi

    local base_dir; base_dir="$(dirname "$jfr_path")"
    echo ""
    echo "💡 Next step: analyze results."
    echo "   For collapsed stack analysis (CPU):"
    echo "   jfrconv --cpu $jfr_path ${base}-cpu.collapsed"
    echo "   python3 scripts/analyze_collapsed.py ${base}-cpu.collapsed"
}

# ── start ─────────────────────────────────────────────────────────────────────
cmd_start() {
    local asprof; asprof="$(locate_asprof)"
    local timestamp; timestamp="$(date +%Y%m%d-%H%M%S)"
    local outdir="profile-${TARGET}-${timestamp}"
    mkdir -p "$outdir"
    local jfr_path; jfr_path="$(pwd)/${outdir}/combined.jfr"
    local sess; sess="$(session_file)"

    echo "▶ Starting all-event async-profiler on target: $TARGET"
    echo "  Binary    : $asprof"
    echo "  Output dir: $outdir/"
    echo "  Events    : cpu + alloc + wall + lock (combined JFR)"
    echo ""

    # macOS: asprof stop ignores -f and writes to /var/folders instead.
    # Create a sentinel so we can find the JFR after stop via find -newer.
    local sentinel="/tmp/asprof-sentinel-$$"
    touch "$sentinel"

    "$asprof" start --all "$TARGET"

    # Save session state (jfr_path, asprof binary, sentinel path)
    printf '%s\n%s\n%s\n' "$jfr_path" "$asprof" "$sentinel" > "$sess"

    echo "✅ Profiling started. Session state: $sess"
    echo ""
    echo "Now reproduce the problem — make requests, run load, wait for the"
    echo "slow operation, etc. asprof is collecting all event types."
    echo ""
    echo "When ready to collect results:"
    echo "   bash scripts/collect.sh stop $TARGET"
}

# ── stop ──────────────────────────────────────────────────────────────────────
cmd_stop() {
    local sess; sess="$(session_file)"

    if [[ ! -f "$sess" ]]; then
        echo "❌ No active session found for target '$TARGET'." >&2
        echo "   Expected state file: $sess" >&2
        echo "   Run first: bash scripts/collect.sh start $TARGET" >&2
        exit 1
    fi

    local jfr_path; jfr_path="$(sed -n '1p' "$sess")"
    local asprof;   asprof="$(sed -n '2p' "$sess")"
    local sentinel; sentinel="$(sed -n '3p' "$sess")"
    [[ -n "$ASPROF_ARG" ]] && asprof="$ASPROF_ARG"

    echo "⏹  Stopping profiler on target: $TARGET"
    # Note: on macOS, -f is silently ignored by asprof stop — handled below.
    "$asprof" stop "$TARGET"
    rm -f "$sess"

    # ── macOS JFR path workaround ────────────────────────────────────────────
    # On macOS, asprof stop ignores -f and writes the JFR to:
    #   /var/folders/<hash>/T/<timestamp>_<pid>/<timestamp>.jfr
    # Use the sentinel (created at 'start') to find the file via find -newer.
    if [[ "$(uname)" == "Darwin" ]] && [[ -n "$sentinel" ]] && [[ -f "$sentinel" ]]; then
        echo ""
        echo "⚠️  macOS: -f is ignored by asprof stop — locating JFR in /var/folders..."
        local found_jfr
        found_jfr=$(find /var/folders -name "*.jfr" -newer "$sentinel" -maxdepth 8 2>/dev/null | head -1)
        rm -f "$sentinel"
        if [[ -n "$found_jfr" ]]; then
            cp "$found_jfr" "$jfr_path"
            echo "   Found: $found_jfr"
            echo "   Copied to: $jfr_path"
        else
            echo "❌ Could not find JFR in /var/folders. Try:"
            echo "   find /var/folders -name '*.jfr' -maxdepth 8 2>/dev/null"
            echo "   (The JFR may still be there — copy it manually to $jfr_path)"
            exit 1
        fi
    else
        rm -f "$sentinel" 2>/dev/null || true
    fi
    # ────────────────────────────────────────────────────────────────────────

    echo ""
    echo "✅ Capture saved: $jfr_path"
    echo ""

    local jfrconv; jfrconv="$(locate_jfrconv "$asprof")"
    if [[ -z "$jfrconv" ]]; then
        echo "⚠️  jfrconv not found — skipping flamegraph split."
        echo "   Convert manually: jfrconv --cpu $jfr_path cpu.html"
        echo "   Or open in IntelliJ IDEA or JDK Mission Control."
        return
    fi

    local base; base="$(dirname "$jfr_path")/profile"
    split_jfr "$jfrconv" "$jfr_path" "$base"
}

# ── timed ─────────────────────────────────────────────────────────────────────
cmd_timed() {
    local asprof; asprof="$(locate_asprof)"
    local timestamp; timestamp="$(date +%Y%m%d-%H%M%S)"
    local outdir="profile-${TARGET}-${timestamp}"
    mkdir -p "$outdir"
    local jfr_path="${outdir}/combined.jfr"

    echo "⏱  ${DURATION}s all-event capture on target: $TARGET"
    echo "   Binary  : $asprof"
    echo "   Output  : $jfr_path"
    echo "   Events  : cpu + alloc + wall + lock"
    echo ""
    echo "Running for ${DURATION}s — trigger your workload now."
    echo "(If called with &, the agent can do other work and then: wait \$PROF_PID)"
    echo ""

    "$asprof" -d "$DURATION" --all -f "$jfr_path" "$TARGET"

    echo ""
    echo "✅ Capture complete: $jfr_path"
    echo ""

    local jfrconv; jfrconv="$(locate_jfrconv "$asprof")"
    if [[ -z "$jfrconv" ]]; then
        echo "⚠️  jfrconv not found — skipping flamegraph split."
        echo "   Open $jfr_path in IntelliJ IDEA or JDK Mission Control."
        return
    fi

    local base="${outdir}/profile"
    split_jfr "$jfrconv" "$jfr_path" "$base"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$SUBCMD" in
    start)           cmd_start ;;
    stop)            cmd_stop  ;;
    timed)           cmd_timed ;;
    help|-h|--help)
        sed -n '2,35p' "$0" | grep '^#' | sed 's/^# \?//'
        exit 0
        ;;
    *)
        echo "❌ Unknown subcommand: '$SUBCMD'" >&2
        echo "   Valid subcommands: start | stop | timed" >&2
        exit 1
        ;;
esac
