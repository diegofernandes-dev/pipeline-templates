#!/usr/bin/env python3
"""Assert the public manifesto schema and the chart values schema stay in parity.

Two layers describe the same consumer surface:

  schemas/<kind>.manifest.schema.json   → validated in DeployContract (before the image push)
  charts/<chart>/values.schema.json     → validated by helm on every render

They must not drift apart:
  * every public property MUST exist in the chart schema, otherwise a manifest the
    contract accepts would be rejected at deploy time;
  * shared subtrees must be identical, unless the divergence is declared below with a
    reason. A declared divergence that no longer exists is also an error, so the
    allowlist cannot rot.

Platform-owned keys (image, runtime, podSecurityContext, deployment, …) are expected to
exist only in the chart schema and are reported, not failed.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

PAIRS = [
    ("Application", "schemas/application.manifest.schema.json", "charts/asa-application/values.schema.json"),
    ("ScheduledJob", "schemas/scheduled-job.manifest.schema.json", "charts/asa-scheduled-job/values.schema.json"),
]

# (kind, path) -> why this divergence is deliberate.
INTENTIONAL: dict[tuple[str, str], str] = {
    ("Application", "allOf"): (
        "public requires `probes` for web/grpc via schema; the chart enforces the same rule in "
        "_probes.tpl so that `helm lint` against chart defaults still works. The chart's own allOf "
        "covers worker -> legacyDns: false."
    ),
    ("ScheduledJob", "properties.execution"): (
        "chart allows timeoutSeconds: null (values.yaml ships null defaults for helm lint) while "
        "the public schema requires a positive integer; both require the key. _runtime.tpl still "
        "enforces > 0 with a platform-specific message."
    ),
}


def deep_diff(a, b, path: str) -> list[str]:
    if type(a) is not type(b):
        return [path]
    if isinstance(a, dict):
        out: list[str] = []
        for k in sorted(set(a) | set(b)):
            sub = f"{path}.{k}" if path else k
            if k not in a or k not in b:
                out.append(sub)
            else:
                out += deep_diff(a[k], b[k], sub)
        return out
    return [] if a == b else [path]


def prune_declared(diffs: list[str], kind: str) -> list[str]:
    """Drop diffs covered by a declared path (the path itself or anything under it)."""
    kept = []
    for d in diffs:
        covered = any(
            k == kind and (d == p or d.startswith(p + "."))
            for (k, p) in INTENTIONAL
        )
        if not covered:
            kept.append(d)
    return kept


def main() -> int:
    failed = False
    used: set[tuple[str, str]] = set()

    for kind, pub_rel, ch_rel in PAIRS:
        pub = json.loads((ROOT / pub_rel).read_text())
        ch = json.loads((ROOT / ch_rel).read_text())
        pub_props, ch_props = pub.get("properties", {}), ch.get("properties", {})

        print(f"== {kind} ==")

        missing = sorted(k for k in pub_props if k not in ch_props)
        if missing:
            print(f"FAIL: {kind}: public properties absent from the chart schema "
                  f"(contract would accept what the chart rejects): {missing}")
            failed = True

        platform_only = sorted(k for k in ch_props if k not in pub_props)
        print(f"  platform-owned (chart only): {', '.join(platform_only) or 'none'}")

        diffs: list[str] = []
        for k in sorted(set(pub_props) & set(ch_props)):
            diffs += deep_diff(pub_props[k], ch_props[k], f"properties.{k}")
        for kw in ("required", "additionalProperties", "allOf", "type"):
            if pub.get(kw) != ch.get(kw):
                diffs.append(kw)

        for (k, p), _ in INTENTIONAL.items():
            if k != kind:
                continue
            if any(d == p or d.startswith(p + ".") for d in diffs):
                used.add((k, p))
            else:
                print(f"FAIL: {kind}: declared divergence '{p}' no longer exists — "
                      f"remove it from INTENTIONAL in scripts/assert-schema-parity.py")
                failed = True

        undeclared = prune_declared(diffs, kind)
        if undeclared:
            print(f"FAIL: {kind}: undeclared schema drift at:")
            for d in sorted(set(undeclared)):
                print(f"    - {d}")
            print("  Align the two schemas, or declare the divergence with a reason in "
                  "scripts/assert-schema-parity.py")
            failed = True
        else:
            print("  OK: shared surface identical (modulo declared divergences)")

        for (k, p), why in INTENTIONAL.items():
            if k == kind and (k, p) in used:
                print(f"  intentional: {p} — {why.splitlines()[0]}")

    if failed:
        print("Schema parity check failed")
        return 1
    print("Public manifesto schemas and chart values schemas are in parity")
    return 0


if __name__ == "__main__":
    sys.exit(main())
