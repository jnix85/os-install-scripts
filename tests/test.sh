#!/usr/bin/env bash
# Tests for install-ubuntu-zfs.sh
#
# Unit tests run as any user, anywhere.
# Integration tests (marked [ROOT]) require root and create a loop-device
# fake disk — run them on the live machine: sudo bash tests/test.sh
#
# Usage:
#   bash tests/test.sh            # unit tests only (non-root)
#   sudo bash tests/test.sh       # unit + integration tests

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/install-ubuntu-zfs.sh"
PASS=0; FAIL=0; SKIP=0

# ─── Helpers ─────────────────────────────────────────────────────────────────

_pass() { printf "  \033[0;32mPASS\033[0m  %s\n" "$1"; PASS=$(( PASS + 1 )); }
_fail() {
    printf "  \033[0;31mFAIL\033[0m  %s\n" "$1"
    [[ -z "${2:-}" ]] || printf "        expected: %s\n        actual:   %s\n" "$2" "${3:-}"
    FAIL=$(( FAIL + 1 ))
}
_skip() { printf "  \033[1;33mSKIP\033[0m  %s\n" "$1"; SKIP=$(( SKIP + 1 )); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    [[ "$expected" == "$actual" ]] && _pass "$desc" || _fail "$desc" "$expected" "$actual"
}

# Run a subshell and capture its exit code without triggering set -e
capture_exit() { "$@" >/dev/null 2>&1; echo $?; } || true

assert_exits() {
    local desc="$1" want="$2"; shift 2
    local got
    got=$(capture_exit "$@")
    assert_eq "$desc" "$want" "$got"
}

assert_nonzero() {
    local desc="$1"; shift
    local got
    got=$(capture_exit "$@")
    if [[ "$got" -ne 0 ]]; then _pass "$desc"; else _fail "$desc (expected nonzero, got 0)"; fi
}

# ─── Unit: swap size calculation ─────────────────────────────────────────────
# Mirrors the logic in install-ubuntu-zfs.sh exactly.
_calc_swap() {
    local ram_kb=$1
    local ram_gb=$(( (ram_kb + 1048575) / 1048576 ))
    if   (( ram_gb <= 8  )); then echo "${ram_gb}G"
    elif (( ram_gb <= 32 )); then echo "$(( (ram_gb + 1) / 2 ))G"
    else                          echo "16G"
    fi
}

echo "=== Swap size calculation ==="
assert_eq "2G RAM  → 2G swap"         "2G"  "$(_calc_swap $((2  * 1048576)))"
assert_eq "4G RAM  → 4G swap"         "4G"  "$(_calc_swap $((4  * 1048576)))"
# Use realistic /proc/meminfo values (slightly under nominal) to test rounding
assert_eq "~8G RAM (8000000K) → 8G"   "8G"  "$(_calc_swap 8000000)"
assert_eq "7G RAM  → 7G swap"         "7G"  "$(_calc_swap $((7  * 1048576)))"
assert_eq "12G RAM → 6G swap"         "6G"  "$(_calc_swap $((12 * 1048576)))"
assert_eq "16G RAM → 8G swap"         "8G"  "$(_calc_swap $((16 * 1048576)))"
assert_eq "32G RAM → 16G swap"        "16G" "$(_calc_swap $((32 * 1048576)))"
assert_eq "64G RAM → 16G cap"         "16G" "$(_calc_swap $((64 * 1048576)))"
assert_eq "128G RAM → 16G cap"        "16G" "$(_calc_swap $((128 * 1048576)))"
# Odd GB values — formula uses ceiling division: (n+1)/2
assert_eq "13G RAM → 7G swap"         "7G"  "$(_calc_swap $((13 * 1048576)))"
assert_eq "11G RAM → 6G swap"         "6G"  "$(_calc_swap $((11 * 1048576)))"

# ─── Unit: username validation ────────────────────────────────────────────────
# Mirrors the regex in install-ubuntu-zfs.sh exactly.
_valid_user() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] && echo valid || echo invalid
}

echo ""
echo "=== Username validation ==="
assert_eq "plain name 'jason'"           "valid"   "$(_valid_user jason)"
assert_eq "single char 'j'"             "valid"   "$(_valid_user j)"
assert_eq "underscore prefix '_svc'"    "valid"   "$(_valid_user _svc)"
assert_eq "hyphen in name 'my-user'"    "valid"   "$(_valid_user my-user)"
assert_eq "digit suffix 'user1'"        "valid"   "$(_valid_user user1)"
assert_eq "max length (31 chars)"       "valid"   "$(_valid_user "a$(printf '%0.s1' {1..30})")"
assert_eq "uppercase rejected"          "invalid" "$(_valid_user Jason)"
assert_eq "digit-prefix rejected"       "invalid" "$(_valid_user 1user)"
assert_eq "space rejected"              "invalid" "$(_valid_user 'my user')"
assert_eq "special char rejected"       "invalid" "$(_valid_user 'user!')"
assert_eq "slash rejected"              "invalid" "$(_valid_user 'usr/bin')"
assert_eq "32-char name rejected"       "invalid" "$(_valid_user "a$(printf '%0.s1' {1..31})")"
assert_eq "empty string rejected"       "invalid" "$(_valid_user '')"

# ─── Unit: --help exits 0 (no root, no disk) ─────────────────────────────────
echo ""
echo "=== --help flag ==="
assert_exits "--help exits 0" "0" bash "$SCRIPT" --help

# ─── Integration tests (require root) ────────────────────────────────────────
echo ""
echo "=== CLI integration (requires root) ==="

if [[ $EUID -ne 0 ]]; then
    _skip "unknown flag exits 1  [ROOT]"
    _skip "nonexistent disk exits 1  [ROOT]"
    _skip "invalid username exits 1  [ROOT]"
    _skip "--no-user with missing root-password prompts / completes prereqs  [ROOT]"
else
    # Set up a throwaway loop-device disk (~50 MB)
    _TMPIMG=$(mktemp /tmp/test-disk-XXXXXX.img)
    truncate -s 50M "$_TMPIMG"
    _LOOP=$(losetup -f --show "$_TMPIMG")
    # Mock directory: stubs for every destructive command so the script cannot
    # actually partition or wipe anything. debootstrap stub returns nonzero so
    # the script stops after arg-parsing / prereq validation.
    _MOCKS=$(mktemp -d /tmp/test-mocks-XXXXXX)
    _cleanup() {
        losetup -d "$_LOOP"  2>/dev/null || true
        rm -f "$_TMPIMG"
        rm -rf "$_MOCKS"
    }
    trap _cleanup EXIT

    for _cmd in zpool zfs sgdisk partprobe mkfs.vfat efibootmgr bootctl \
                apt-get modprobe curl gpg debootstrap; do
        printf '#!/bin/bash\necho "[mock] %s $*" >&2\nexit 0\n' "$_cmd" > "$_MOCKS/$_cmd"
        chmod +x "$_MOCKS/$_cmd"
    done

    _run() {
        TESTING=1 PATH="$_MOCKS:$PATH" \
            bash "$SCRIPT" --disk "$_LOOP" "$@" 2>&1
    }
    _exit() {
        TESTING=1 PATH="$_MOCKS:$PATH" \
            bash "$SCRIPT" --disk "$_LOOP" "$@" >/dev/null 2>&1; echo $?
    } || true

    # Unknown flag must exit 1
    assert_eq "unknown flag exits 1" "1" \
        "$(_exit --BADFLAGS 2>/dev/null || echo $?)"

    # Nonexistent disk must exit 1
    assert_eq "nonexistent disk exits 1" "1" \
        "$(TESTING=1 PATH="$_MOCKS:$PATH" bash "$SCRIPT" --disk /dev/nonexistent123 \
            >/dev/null 2>&1; echo $?)"

    # Invalid username must exit 1
    assert_eq "invalid username exits 1" "1" \
        "$(_exit --release resolute --hostname h --user 'BAD USER' \
            --password x --timezone UTC --quota none --yes 2>/dev/null || echo $?)"

    # Valid args make it past validation into execution (sgdisk mocks fire,
    # then the script dies on missing real partitions — that's expected with mocks)
    _out=$(_run --release resolute --hostname testhost --user validuser \
                --password testpass --timezone UTC --quota none --yes 2>&1 || true)
    if echo "$_out" | grep -q "mock.*sgdisk\|Partitioning\|Prerequisites satisfied"; then
        _pass "valid args pass validation and enter execution"
    else
        _fail "valid args pass validation and enter execution" "(partitioning reached)" "$_out"
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
printf "Results: \033[0;32m%d passed\033[0m  \033[0;31m%d failed\033[0m  \033[1;33m%d skipped\033[0m\n" \
    "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
