#!/usr/bin/env bash
# fm-safety-surface-check.sh - prove every canonical safety sentence still
# reaches the agent, by verifying it appears verbatim in the always-read surface.
#
# Usage:
#   bin/fm-safety-surface-check.sh
#   bin/fm-safety-surface-check.sh --root <repo> [--manifest <path>] [--surface <path>]
#
# The manifest (docs/safety-surface-manifest.json) owns the never-moves list and
# names the surface it guards; --surface overrides that for fixture runs.
# Exit 0 prints the rule and sentence counts it proved; exit 1 names the first
# missing sentence and its rule, or the structural refusal.
# This check compares bytes only: it does not judge which rules belong there.
# It refuses an empty, structurally incomplete, or missing manifest, so it can
# never pass by checking nothing.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


class CheckError(Exception):
    """One deterministic safety-surface failure."""


def fail(message: str) -> None:
    raise CheckError(message)


def load_manifest(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"manifest is missing: {path}")
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"manifest is unreadable: {exc}")
    if not isinstance(data, dict):
        fail("manifest root must be an object")
    if data.get("version") != 1:
        fail("manifest version must be 1")
    surface = data.get("surface")
    if not isinstance(surface, str) or not surface.strip():
        fail("manifest must name the surface it guards")
    return data


def manifest_rules(data: dict) -> list[dict]:
    rules = data.get("rules")
    if not isinstance(rules, list) or not rules:
        fail("manifest lists no safety rules, so it would prove nothing")
    seen: set[str] = set()
    for index, rule in enumerate(rules):
        if not isinstance(rule, dict):
            fail(f"rule {index} must be an object")
        rule_id = rule.get("id")
        if not isinstance(rule_id, str) or not rule_id.strip():
            fail(f"rule {index} needs a non-empty id")
        if rule_id in seen:
            fail(f"rule id appears more than once: {rule_id}")
        seen.add(rule_id)
        if not isinstance(rule.get("rule"), str) or not rule["rule"].strip():
            fail(f"rule {rule_id} needs a non-empty rule description")
        sentences = rule.get("sentences")
        if not isinstance(sentences, list) or not sentences:
            fail(f"rule {rule_id} lists no sentences, so it would prove nothing")
        for sentence in sentences:
            if not isinstance(sentence, str) or not sentence.strip():
                fail(f"rule {rule_id} has an empty sentence")
    return rules


def read_surface(path: Path) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"safety surface is missing: {path}")
    except OSError as exc:
        fail(f"safety surface is unreadable: {exc}")
    if not text.strip():
        fail(f"safety surface is empty: {path}")
    return text


def validate(root: Path, manifest_path: Path, surface_override: Path | None) -> tuple[int, int, Path]:
    data = load_manifest(manifest_path)
    rules = manifest_rules(data)
    surface_path = surface_override or Path(data["surface"])
    if not surface_path.is_absolute():
        surface_path = root / surface_path
    surface = read_surface(surface_path)
    sentences = 0
    for rule in rules:
        for sentence in rule["sentences"]:
            sentences += 1
            if sentence not in surface:
                fail(
                    f"{surface_path.name} no longer contains this safety sentence "
                    f"(rule {rule['id']}): {sentence}"
                )
    return len(rules), sentences, surface_path


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify every manifest safety sentence appears verbatim in the always-read surface."
    )
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--surface", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()

    manifest_path = args.manifest or Path("docs/safety-surface-manifest.json")
    if not manifest_path.is_absolute():
        manifest_path = root / manifest_path

    try:
        rules, sentences, surface_path = validate(root, manifest_path, args.surface)
    except CheckError as exc:
        print(f"fm-safety-surface-check: {exc}", file=sys.stderr)
        return 1
    print(f"fm-safety-surface-check: ok rules={rules} sentences={sentences} surface={surface_path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
