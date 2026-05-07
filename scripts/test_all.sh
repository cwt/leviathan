#!/usr/bin/env bash
# Compatible with bash 3.x (macOS) and 4.x+
# Usage: bash scripts/test_all.sh
set -eu

# Trap signals so child processes are cleaned up on CTRL-C
cleanup_pids() {
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup_pids EXIT INT TERM

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

# ---- helpers ----

clean() {
    rm -rf zig-out zig-cache .zig-cache .pytest_cache 2>/dev/null || true
    find . -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
    find . -name '*.pyc' -delete 2>/dev/null || true
}

get_python_lib() {
    local py="$1"
    local libdir soname
    libdir="$("$py" -c "import sysconfig; print(sysconfig.get_config_var('LIBDIR'))" 2>/dev/null)"
    soname="$("$py" -c "import sysconfig; print(sysconfig.get_config_var('INSTSONAME'))" 2>/dev/null)"
    echo "${libdir}/${soname}"
}

get_python_include() {
    local py="$1"
    "$py" -c "import sysconfig; print(sysconfig.get_config_var('INCLUDEPY'))" 2>/dev/null
}

is_free_threading() {
    local py="$1"
    "$py" -c "import sys; exit(0 if not sys._is_gil_enabled() else 1)" 2>/dev/null
}

has_timeout() {
    command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1
}

get_timeout_cmd() {
    if command -v timeout >/dev/null 2>&1; then echo "timeout"; else echo "gtimeout"; fi
}

run_tests() {
    local py="$1" label="$2" cmd=""
    printf "${YELLOW}[%s]${NC} Running tests...\n" "$label"
    if has_timeout; then
        cmd="$(get_timeout_cmd) -k 5 120 $py"
    else
        cmd="$py"
    fi
    if PYTHONPATH=. $cmd -m pytest tests/ \
        --ignore=tests/test_create_connection.py \
        -q 2>/dev/null; then
        printf "${GREEN}[%s] PASS${NC}\n" "$label"
        PASS=$((PASS + 1))
        return 0
    else
        rc=$?
        if [ "$rc" -eq 139 ] 2>/dev/null; then
            printf "${YELLOW}[%s] SEGFAULT (pytest + free-threading — standalone tests pass)${NC}\n" "$label"
        else
            printf "${RED}[%s] FAIL${NC}\n" "$label"
        fi
        FAIL=$((FAIL + 1))
        return 1
    fi
}

# ---- main ----

echo "=== Leviathan Test Suite ==="
echo ""

for py in python3.13 python3.14 python3.13t python3.14t; do
    if ! command -v "$py" >/dev/null 2>&1; then
        printf "${YELLOW}[%s]${NC} not found — skipping\n" "$py"
        continue
    fi

    lib="$(get_python_lib "$py")"
    inc="$(get_python_include "$py")"

    if [ ! -f "$lib" ]; then
        printf "${RED}[%s]${NC} lib not found at %s — skipping\n" "$py" "$lib"
        continue
    fi
    if [ ! -d "$inc" ]; then
        printf "${RED}[%s]${NC} include not found at %s — skipping\n" "$py" "$inc"
        continue
    fi

    printf "${YELLOW}[%s]${NC} Building...\n" "$py"
    clean

    gilflag=""
    if is_free_threading "$py"; then
        gilflag="-Dpython-gil-disabled=true"
    fi

    if ! zig build install -Doptimize=Debug \
        -Dpython-include-dir="$inc" \
        -Dpython-lib-dir="$(dirname "$lib")" \
        -Dpython-lib="$lib" \
        $gilflag 2>/dev/null; then
        printf "${RED}[%s]${NC} BUILD FAILED\n" "$py"
        FAIL=$((FAIL + 1))
        continue
    fi

    cp zig-out/lib/libleviathan.so leviathan/leviathan_zig.so
    run_tests "$py" "$py" || true
    echo ""
done

# ---- zig tests ----
printf "${YELLOW}[zig]${NC} Running zig unit tests...\n"
REF_INC="$(get_python_include python3.13)"
REF_LIB="$(get_python_lib python3.13)"
if zig build test \
    -Dpython-include-dir="$REF_INC" \
    -Dpython-lib-dir="$(dirname "$REF_LIB")" \
    -Dpython-lib="$REF_LIB" 2>/dev/null; then
    printf "${GREEN}[zig] PASS${NC}\n"
else
    printf "${RED}[zig] FAIL${NC}\n"
    FAIL=$((FAIL + 1))
fi || true

echo ""
printf "=== Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC} ===\n" "$PASS" "$FAIL"
exit $FAIL
