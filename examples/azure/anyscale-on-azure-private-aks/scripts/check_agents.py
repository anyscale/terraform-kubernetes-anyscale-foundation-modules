#!/usr/bin/env python3
"""Static validator for the Anyscale-on-AKS agent customization files.

Dependency-free (no PyYAML). Validates the `.github/agents/*.agent.md` custom
agents, the path-scoped `.github/instructions/*.instructions.md` files, and the
top-level `AGENTS.md`, enforcing the conventions described in AGENTS.md.

Run: `python3 scripts/check_agents.py`  (exit 0 = all checks pass, 1 = failures)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
AGENTS_DIR = REPO_ROOT / ".github" / "agents"
INSTRUCTIONS_DIR = REPO_ROOT / ".github" / "instructions"

# The expected agent team for this repo (filename stem == frontmatter `name`).
EXPECTED_AGENTS = {
    "anyscale-aks-planner",
    "anyscale-aks-implementer",
    "anyscale-aks-reviewer",
    "anyscale-aks-infra",
    "anyscale-aks-workloads",
}

# Only the high-privilege infra specialist may be excluded from model invocation.
ALLOWED_DISABLE_MODEL_INVOCATION = {"anyscale-aks-infra"}

EXPECTED_INSTRUCTIONS = {
    "terraform.instructions.md",
    "shell.instructions.md",
    "proofs.instructions.md",
    "code-quality.instructions.md",
}

FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)

errors: list[str] = []
warnings: list[str] = []


def fail(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def extract_frontmatter(text: str, label: str) -> str | None:
    m = FRONTMATTER_RE.match(text)
    if not m:
        fail(f"{label}: missing or malformed YAML frontmatter (must start with '---').")
        return None
    return m.group(1)


def scalar_value(frontmatter: str, key: str) -> str | None:
    """Return the inline scalar value for `key:` on its own top-level line."""
    m = re.search(rf"^{re.escape(key)}:[ \t]*(.*)$", frontmatter, re.MULTILINE)
    if not m:
        return None
    return m.group(1).strip()


def key_present(frontmatter: str, key: str) -> bool:
    return re.search(rf"^{re.escape(key)}:", frontmatter, re.MULTILINE) is not None


def model_is_valid(frontmatter: str) -> bool:
    """`model` may be a scalar or a prioritized non-empty YAML list."""
    val = scalar_value(frontmatter, "model")
    if val is None:
        return False
    if val.startswith("["):
        return val.endswith("]") and any(item.strip() for item in val.strip("[]").split(","))
    if val == "":
        block = re.search(r"^model:[ \t]*\n((?:[ \t]*-[ \t].*\n?)+)", frontmatter, re.MULTILINE)
        return bool(block)
    return val != ""


def check_agent_file(path: Path) -> str | None:
    text = path.read_text(encoding="utf-8")
    label = f"agents/{path.name}"
    fm = extract_frontmatter(text, label)
    if fm is None:
        return None

    stem = path.name[: -len(".agent.md")] if path.name.endswith(".agent.md") else path.stem

    name = scalar_value(fm, "name")
    if name is None:
        fail(f"{label}: missing required `name`.")
    elif name != stem:
        fail(f"{label}: `name: {name}` must match filename stem `{stem}`.")

    target = scalar_value(fm, "target")
    if target != "vscode":
        fail(f"{label}: `target` must be `vscode` (got {target!r}).")

    if not key_present(fm, "description"):
        fail(f"{label}: missing required `description`.")

    if not key_present(fm, "model"):
        fail(f"{label}: missing required `model`.")
    elif not model_is_valid(fm):
        fail(f"{label}: `model` must be a string or a non-empty prioritized list.")

    if not key_present(fm, "tools"):
        warn(f"{label}: no `tools` declared (agent inherits all tools).")

    dmi = scalar_value(fm, "disable-model-invocation")
    if dmi == "true" and stem not in ALLOWED_DISABLE_MODEL_INVOCATION:
        fail(
            f"{label}: only {sorted(ALLOWED_DISABLE_MODEL_INVOCATION)} may set "
            f"`disable-model-invocation: true`."
        )
    if stem in ALLOWED_DISABLE_MODEL_INVOCATION and dmi != "true":
        fail(
            f"{label}: high-privilege specialist must set "
            f"`disable-model-invocation: true`."
        )

    return name


def check_handoffs() -> None:
    """Every handoff `agent:` must reference a known agent in this team."""
    known = set(EXPECTED_AGENTS)
    for path in sorted(AGENTS_DIR.glob("*.agent.md")):
        text = path.read_text(encoding="utf-8")
        fm = extract_frontmatter(text, f"agents/{path.name}")
        if fm is None:
            continue
        for ref in re.findall(r"^\s*agent:[ \t]*(\S+)\s*$", fm, re.MULTILINE):
            ref = ref.strip().strip("'\"")
            if ref not in known:
                fail(f"agents/{path.name}: handoff references unknown agent `{ref}`.")


def main() -> int:
    if not AGENTS_DIR.is_dir():
        fail(f"missing agents directory: {AGENTS_DIR.relative_to(REPO_ROOT)}")
        return report()

    if not (REPO_ROOT / "AGENTS.md").is_file():
        fail("missing top-level AGENTS.md.")

    found: set[str] = set()
    for path in sorted(AGENTS_DIR.glob("*.agent.md")):
        name = check_agent_file(path)
        if name:
            found.add(name)

    missing = EXPECTED_AGENTS - found
    if missing:
        fail(f"missing expected agents: {sorted(missing)}.")
    extra = found - EXPECTED_AGENTS
    if extra:
        warn(f"unexpected agent(s) present: {sorted(extra)}.")

    check_handoffs()

    if INSTRUCTIONS_DIR.is_dir():
        present = {p.name for p in INSTRUCTIONS_DIR.glob("*.instructions.md")}
        for name in sorted(EXPECTED_INSTRUCTIONS - present):
            fail(f"missing expected instruction file: .github/instructions/{name}.")
        for path in sorted(INSTRUCTIONS_DIR.glob("*.instructions.md")):
            fm = extract_frontmatter(path.read_text(encoding="utf-8"), f"instructions/{path.name}")
            if fm is not None and not key_present(fm, "applyTo"):
                fail(f"instructions/{path.name}: missing required `applyTo`.")
    else:
        fail("missing .github/instructions/ directory.")

    return report()


def report() -> int:
    for w in warnings:
        print(f"WARN: {w}")
    for e in errors:
        print(f"FAIL: {e}")
    if errors:
        print(f"\ncheck_agents: {len(errors)} error(s), {len(warnings)} warning(s).")
        return 1
    print(f"check_agents: OK ({len(warnings)} warning(s)).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
