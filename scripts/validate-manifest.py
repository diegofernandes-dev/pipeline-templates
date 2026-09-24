#!/usr/bin/env python3
"""Validate a public deploy manifesto against schemas/*.manifest.schema.json.

Requires: PyYAML + jsonschema (pip install pyyaml jsonschema).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _load_yaml(path: Path):
    try:
        import yaml  # type: ignore
    except ImportError as exc:
        raise SystemExit(
            "PyYAML is required (pip install pyyaml), or pass JSON via --stdin"
        ) from exc
    with path.open() as f:
        return yaml.safe_load(f)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("schema", type=Path, help="Path to JSON Schema")
    parser.add_argument("manifest", type=Path, nargs="?", help="YAML manifesto path")
    parser.add_argument("--stdin", action="store_true", help="Read JSON instance from stdin")
    args = parser.parse_args()

    try:
        import jsonschema  # type: ignore
        from jsonschema import Draft7Validator
    except ImportError as exc:
        raise SystemExit(
            "jsonschema is required (pip install jsonschema)"
        ) from exc

    schema = json.loads(args.schema.read_text())
    if args.stdin:
        instance = json.load(sys.stdin)
    elif args.manifest is not None:
        instance = _load_yaml(args.manifest)
    else:
        parser.error("manifest path or --stdin is required")

    if instance is None:
        print("manifest is empty", file=sys.stderr)
        return 1

    validator = Draft7Validator(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.path))
    if errors:
        print("Manifest schema validation failed:", file=sys.stderr)
        for err in errors:
            path = "$"
            if err.absolute_path:
                path = "$." + ".".join(str(p) for p in err.absolute_path)
            print(f"  - {path}: {err.message}", file=sys.stderr)
        return 1
    print(f"OK: manifesto matches {args.schema.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
