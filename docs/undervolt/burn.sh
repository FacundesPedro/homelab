#!/usr/bin/env bash
# burn.sh - sustained GPU load with amdgpu thermal sampling.
#
#   bash burn.sh              # 30 s
#   REPEAT=10 bash burn.sh    # 5 min
#
# Run on the Proxmox host. If the host has no hipcc, the load is compiled and
# run inside the container (the Strata venv ships hipcc).
#
# Environment:
#   CTID=121          container used when the host has no hipcc
#   STRATA_DIR=/opt/Strata   engine directory
#   VENV=$STRATA_DIR/.venv   venv that provides hipcc and the ROCm libraries
#   RUN_SECONDS=30    seconds per repetition
#   REPEAT=1          repetitions
#   LIMIT_C=105       junction abort threshold
#   FORCE=0           set 1 to run while strata.service is active
set -euo pipefail

CTID="${CTID:-121}"
STRATA_DIR="${STRATA_DIR:-/opt/Strata}"
VENV="${VENV:-$STRATA_DIR/.venv}"
PER_RUN="${RUN_SECONDS:-30}"
REPEAT="${REPEAT:-1}"
LIMIT_C="${LIMIT_C:-105}"
FORCE="${FORCE:-0}"
DURATION=$((PER_RUN * REPEAT))

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[ "$DURATION" -gt 0 ] || die "RUN_SECONDS x REPEAT must be > 0"

# ---- sensors ---------------------------------------------------------------
H=""
for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = "amdgpu" ] && H="$h"
done
[ -n "$H" ] || die "no amdgpu hwmon device found"

JUNC="$H/temp2_input"
POWER="$H/power1_average"
[ -r "$JUNC" ] || die "junction sensor not found ($JUNC)"

# ---- avoid competing with the model ---------------------------------------
ACTIVE=""
if command -v pct >/dev/null 2>&1; then
    ACTIVE=$(pct exec "$CTID" -- systemctl is-active strata 2>/dev/null || true)
fi
if [ "$ACTIVE" = "active" ] && [ "$FORCE" != "1" ]; then
    die "strata.service is active in CT $CTID; stop it first or set FORCE=1"
fi

# ---- load source ----------------------------------------------------------
SRC=$(mktemp "${TMPDIR:-/tmp}/strata-burn.XXXXXX.cpp")
trap 'rm -f "$SRC"' EXIT
cat >"$SRC" <<'CPP'
#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>

__global__ void burn(float *a, float *b, float *c, int n, int iters) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    int stride = gridDim.x * blockDim.x;
    if (i >= n) return;
    float x = a[i], y = b[i], z = 0.0f;
    for (int k = 0; k < iters; ++k) {
        z = fmaf(x, y, z);
        x += 1.0e-7f;
        y -= 1.0e-7f;
    }
    c[i] = z;
    (void)stride;
}

int main(int argc, char **argv) {
    int iters = (argc > 1) ? atoi(argv[1]) : 2000000;
    int n = 1 << 20;
    float *a, *b, *c;
    if (hipMalloc(&a, n * sizeof(float)) != hipSuccess) return 2;
    if (hipMalloc(&b, n * sizeof(float)) != hipSuccess) return 2;
    if (hipMalloc(&c, n * sizeof(float)) != hipSuccess) return 2;
    if (hipMemset(a, 0, n * sizeof(float)) != hipSuccess) return 2;
    if (hipMemset(b, 0, n * sizeof(float)) != hipSuccess) return 2;
    if (hipMemset(c, 0, n * sizeof(float)) != hipSuccess) return 2;
    int blocks = 1024;
    for (;;) {
        burn<<<blocks, 256>>>(a, b, c, n, iters);
        if (hipDeviceSynchronize() != hipSuccess) {
            fprintf(stderr, "kernel failed\n");
            return 3;
        }
        printf("launch\n");
        fflush(stdout);
    }
}
CPP

compile_local() { hipcc -O2 "$SRC" -o "$BIN" >/dev/null; }

BIN=""
MODE=""
if command -v hipcc >/dev/null 2>&1; then
    BIN=$(mktemp "${TMPDIR:-/tmp}/strata-burn.XXXXXX")
    compile_local && MODE=local || die "hipcc failed to compile the burn kernel"
elif command -v pct >/dev/null 2>&1 && pct exec "$CTID" -- test -x "$VENV/bin/hipcc" >/dev/null 2>&1; then
    pct push "$CTID" "$SRC" /tmp/strata-burn.cpp >/dev/null
    pct exec "$CTID" -- "$VENV/bin/hipcc" -O2 /tmp/strata-burn.cpp -o /tmp/strata-burn >/dev/null \
        || die "hipcc failed to compile the burn kernel inside CT $CTID"
    # The ROCm wheels do not add themselves to the loader path; the engine
    # does this in its launcher, so the burn binary needs it explicitly.
    ROCM_LIBS=$(pct exec "$CTID" -- bash -c 'ls -d "$1"/lib/python*/site-packages/_rocm_sdk_*/lib 2>/dev/null | paste -sd: -' _ "$VENV")
    [ -n "$ROCM_LIBS" ] || die "no ROCm libraries under $VENV"
    MODE=ct
else
    die "no hipcc found (host or CT $CTID); install ROCm or set CTID"
fi

# ---- run and sample -------------------------------------------------------
OUT=$(mktemp "${TMPDIR:-/tmp}/strata-burn-out.XXXXXX")
cleanup() {
    rm -f "$SRC" "$OUT" "${BIN:-}"
    [ "$MODE" = "ct" ] && pct exec "$CTID" -- rm -f /tmp/strata-burn /tmp/strata-burn.cpp >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "burn: ${DURATION}s ($REPEAT x ${PER_RUN}s), mode=$MODE, abort at ${LIMIT_C}C junction"
if [ "$MODE" = "local" ]; then
    timeout --signal=INT "$DURATION" "$BIN" >"$OUT" 2>&1 &
else
    pct exec "$CTID" -- env LD_LIBRARY_PATH="$ROCM_LIBS" timeout --signal=INT "$DURATION" /tmp/strata-burn >"$OUT" 2>&1 &
fi
BPID=$!

MIN=999999
MAX=0
SUM=0
N=0
PMAX=0
while kill -0 "$BPID" 2>/dev/null; do
    J=$(( $(cat "$JUNC" 2>/dev/null || echo 0) / 1000 ))
    P=$(( $(cat "$POWER" 2>/dev/null || echo 0) / 1000000 ))
    if [ "$J" -gt 0 ]; then
        [ "$J" -lt "$MIN" ] && MIN=$J
        [ "$J" -gt "$MAX" ] && MAX=$J
        [ "$P" -gt "$PMAX" ] && PMAX=$P
        SUM=$((SUM + J))
        N=$((N + 1))
    fi
    if [ "$J" -ge "$LIMIT_C" ]; then
        echo "ABORT: junction ${J}C >= ${LIMIT_C}C" >&2
        kill "$BPID" 2>/dev/null || true
        [ "$MODE" = "ct" ] && pct exec "$CTID" -- pkill -f strata-burn >/dev/null 2>&1 || true
        break
    fi
    sleep 2
done
wait "$BPID" 2>/dev/null || true

LAUNCHES=$(grep -c '^launch$' "$OUT" 2>/dev/null || true)
LAUNCHES=${LAUNCHES:-0}
if [ "$LAUNCHES" -eq 0 ]; then
    echo "--- burn output ---" >&2
    tail -20 "$OUT" >&2 2>/dev/null || true
    echo "-------------------" >&2
fi
AVG=0
[ "$N" -gt 0 ] && AVG=$((SUM / N))
[ "$MIN" -eq 999999 ] && MIN=0

printf 'result: junction min=%dC avg=%dC peak=%dC  power peak=%dW  launches=%s\n' \
    "$MIN" "$AVG" "$MAX" "$PMAX" "$LAUNCHES"
if [ "$MAX" -ge 90 ]; then
    echo "warning: peak junction is at or above 90C; improve the profile or the cooling" >&2
fi
