#!/usr/bin/env python3
"""Validate a public deploy manifesto against schemas/*.manifest.schema.json.

Uses only the Python stdlib + optional PyYAML. If PyYAML is missing, expects
JSON on stdin (caller may pipe: yq -o=json . file | validate-manifest.py --stdin SCHEMA).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def _load_yaml(path: Path) -> Any:
    try:
        import yaml  # type: ignore
    except ImportError as exc:
        raise SystemExit(
            "PyYAML is required to read YAML manifests (pip install pyyaml), "
            "or pass JSON via --stdin"
        ) from exc
    with path.open() as f:
        return yaml.safe_load(f)


def _type_name(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int) and not isinstance(value, bool):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def _matches_type(value: Any, typ: str) -> bool:
    if typ == "null":
        return value is None
    if typ == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if typ == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if typ == "boolean":
        return isinstance(value, bool)
    if typ == "string":
        return isinstance(value, str)
    if typ == "array":
        return isinstance(value, list)
    if typ == "object":
        return isinstance(value, dict)
    return False


def _validate(instance: Any, schema: dict[str, Any], path: str, errors: list[str]) -> None:
    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: expected const {schema['const']!r}, got {instance!r}")
        return

    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: expected one of {schema['enum']}, got {instance!r}")
        return

    if "oneOf" in schema:
        matched = 0
        local: list[str] = []
        for i, sub in enumerate(schema["oneOf"]):
            sub_errors: list[str] = []
            _validate(instance, sub, f"{path}#oneOf[{i}]", sub_errors)
            if not sub_errors:
                matched += 1
            else:
                local.extend(sub_errors)
        if matched != 1:
            errors.append(f"{path}: failed oneOf ({matched} matches)")
            if matched == 0:
                errors.extend(local[:8])
        return

    if "type" in schema:
        types = schema["type"]
        if isinstance(types, str):
            types = [types]
        if not any(_matches_type(instance, t) for t in types):
            errors.append(f"{path}: expected type {types}, got {_type_name(instance)}")
            return

    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            errors.append(f"{path}: string shorter than minLength {schema['minLength']}")
        if "pattern" in schema:
            import re

            if not re.search(schema["pattern"], instance):
                errors.append(f"{path}: does not match pattern {schema['pattern']}")

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append(f"{path}: {instance} < minimum {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            errors.append(f"{path}: {instance} > maximum {schema['maximum']}")

    if isinstance(instance, list) and "items" in schema:
        for i, item in enumerate(instance):
            _validate(item, schema["items"], f"{path}[{i}]", errors)

    if isinstance(instance, dict):
        props = schema.get("properties", {})
        required = schema.get("required", [])
        for key in required:
            if key not in instance:
                errors.append(f"{path}.{key}: required property missing")
        additional = schema.get("additionalProperties", True)
        for key, value in instance.items():
            if key in props:
                prop_schema = props[key]
                if prop_schema is False:
                    errors.append(f"{path}.{key}: property is forbidden")
                elif isinstance(prop_schema, dict):
                    _validate(value, prop_schema, f"{path}.{key}", errors)
            elif additional is False:
                errors.append(f"{path}.{key}: additional property not allowed")
            elif isinstance(additional, dict):
                _validate(value, additional, f"{path}.{key}", errors)

        for clause in schema.get("allOf", []):
            if "if" in clause and "then" in clause:
                if_errors: list[str] = []
                _validate(instance, clause["if"], path, if_errors)
                # Soft if: only apply then when if properties match loosely
                if_props = clause["if"].get("properties", {})
                applies = True
                for k, sub in if_props.items():
                    if k not in instance:
                        applies = False
                        break
                    probe: list[str] = []
                    _validate(instance[k], sub, f"{path}.{k}", probe)
                    if probe:
                        applies = False
                        break
                if applies:
                    _validate(instance, clause["then"], path, errors)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("schema", type=Path, help="Path to JSON Schema")
    parser.add_argument("manifest", type=Path, nargs="?", help="YAML manifesto path")
    parser.add_argument("--stdin", action="store_true", help="Read JSON instance from stdin")
    args = parser.parse_args()

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

    errors: list[str] = []
    _validate(instance, schema, "$", errors)
    if errors:
        print("Manifest schema validation failed:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    print(f"OK: manifesto matches {args.schema.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
