#!/usr/bin/env bash
set -euo pipefail

# Fast performance smoke test for ffast_tree.
# Keeps total runtime well under 10 seconds for fast iteration.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT_DIR/zig-out/bin/ffast}"
MAX_TOTAL_MS="${MAX_TOTAL_MS:-10000}"

python3 - <<'PY' "$BIN" "$MAX_TOTAL_MS"
import json
import pathlib
import statistics
import subprocess
import tempfile
import time
import sys

bin_path = sys.argv[1]
max_total_ms = int(sys.argv[2])

with tempfile.TemporaryDirectory(prefix="ffast-perf-") as td:
    root = pathlib.Path(td)
    (root / "app" / "one").mkdir(parents=True)
    (root / "app" / "two").mkdir(parents=True)

    for i in range(1500):
        (root / "app" / "one" / f"f{i}.zig").write_text("pub fn a() void {}\n")
        (root / "app" / "two" / f"f{i}.php").write_text("<?php function x() {}\n")

    req_init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}

    def run_case(args, runs=4):
        req_call = {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": "ffast_tree", "arguments": args},
        }
        payload = (json.dumps(req_init) + "\n" + json.dumps(req_call) + "\n").encode()
        times = []
        for _ in range(runs):
            t0 = time.perf_counter()
            p = subprocess.run(
                [bin_path, "mcp"],
                cwd=str(root),
                input=payload,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            dt = (time.perf_counter() - t0) * 1000
            if p.returncode != 0:
                raise SystemExit(f"ffast_tree perf run failed rc={p.returncode}: {p.stderr.decode()}")
            times.append(dt)
        return {
            "avg_ms": round(statistics.mean(times), 2),
            "p50_ms": round(statistics.median(times), 2),
            "max_ms": round(max(times), 2),
        }

    t0 = time.perf_counter()
    baseline = run_case({})
    filtered = run_case(
        {
            "path": "app",
            "depth": 2,
            "max_nodes": 200,
            "include": "*.php",
            "sort": "name",
            "dirs_first": True,
        }
    )
    total_ms = round((time.perf_counter() - t0) * 1000, 2)

    print("baseline", baseline)
    print("filtered", filtered)
    print("total_ms", total_ms)

    if total_ms > max_total_ms:
        raise SystemExit(
            f"perf smoke exceeded budget: {total_ms}ms > {max_total_ms}ms"
        )

    # Verify status endpoint includes RAM-bounded indexing fields
    req_status = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": "ffast_status", "arguments": {}},
    }
    status_payload = (json.dumps(req_init) + "\n" + json.dumps(req_status) + "\n").encode()
    sp = subprocess.run(
        [bin_path, "mcp"],
        cwd=str(root),
        input=status_payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if sp.returncode != 0:
        raise SystemExit(f"ffast_status failed rc={sp.returncode}: {sp.stderr.decode()}")
    status_out = sp.stdout.decode()
    for field in ["tier2_coverage", "ram_mb_current", "ram_mb_cap", "throttle_state"]:
        # Fields appear in escaped JSON inside MCP text content
        if f'"{field}"' not in status_out and f'\\"{field}\\"' not in status_out:
            raise SystemExit(f"ffast_status missing field: {field}")
    print("status fields: OK (tier2_coverage, ram_mb_current, ram_mb_cap, throttle_state)")
PY
