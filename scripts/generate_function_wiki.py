#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import fnmatch
import os
import re
import subprocess
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
WIKI_DIR = ROOT / "wiki"
REFERENCE_PATH = WIKI_DIR / "Function-Reference.md"
UPDATES_PATH = WIKI_DIR / "Function-Updates.md"

INCLUDE_EXTS = {".swift", ".py", ".sh", ".bash", ".zsh"}
SOURCE_DIRS = ["Lumi", "LumiAgentHelper", "Tests", "scripts", "legacy"]
ROOT_GLOBS = ["*.sh", "*.bash", "*.zsh", "*.py", "*.swift"]
SKIP_DIR_NAMES = {
    ".git",
    ".build",
    ".build-check",
    "dist",
    "runable",
    ".vscode",
    "node_modules",
    "DerivedData",
}

SWIFT_PATTERN = re.compile(
    r"^\s*(?:@\w+(?:\([^\)]*\))?\s*)*(?:(?:public|private|fileprivate|internal|open|static|class|override|mutating|nonmutating|convenience|required|final|actor|indirect|isolated|nonisolated|distributed|prefix|postfix|infix|lazy|weak|unowned)\s+)*(func|init|deinit)\b"
)
PYTHON_PATTERN = re.compile(r"^\s*(?:async\s+def|def)\s+\w+\s*\(")
SHELL_PATTERN_A = re.compile(r"^\s*function\s+[A-Za-z_][A-Za-z0-9_]*\s*\{\s*$")
SHELL_PATTERN_B = re.compile(r"^\s*[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{\s*$")

DIFF_FILE_PATTERN = re.compile(r"^\+\+\+ b/(.+)$")


@dataclass
class FunctionEntry:
    path: str
    line: int
    signature: str
    language: str


def should_skip(path: Path) -> bool:
    for part in path.parts:
        if part in SKIP_DIR_NAMES:
            return True
    return False


def iter_source_files(root: Path) -> Iterable[Path]:
    emitted: set[Path] = set()

    for pattern in ROOT_GLOBS:
        for path in root.glob(pattern):
            if not path.is_file():
                continue
            rel = path.relative_to(root)
            if should_skip(rel):
                continue
            if path.suffix in INCLUDE_EXTS and path not in emitted:
                emitted.add(path)
                yield path

    for dirname in SOURCE_DIRS:
        start = root / dirname
        if not start.exists():
            continue
        for path in start.rglob("*"):
            if not path.is_file():
                continue
            rel = path.relative_to(root)
            if should_skip(rel):
                continue
            if path.suffix in INCLUDE_EXTS and path not in emitted:
                emitted.add(path)
                yield path


def clean_signature(sig: str) -> str:
    sig = " ".join(sig.split())
    if "{" in sig:
        sig = sig.split("{", 1)[0].strip()
    if sig.endswith(":"):
        sig = sig[:-1].strip()
    return sig


def parse_swift(path: Path) -> list[FunctionEntry]:
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    entries: list[FunctionEntry] = []

    i = 0
    while i < len(lines):
        line = lines[i]
        if SWIFT_PATTERN.match(line):
            start_line = i + 1
            sig_lines = [line.strip()]
            j = i + 1
            while j < len(lines) and len(sig_lines) < 8:
                current = sig_lines[-1]
                if "{" in current:
                    break
                nxt = lines[j].strip()
                if not nxt or nxt.startswith("//"):
                    break
                sig_lines.append(nxt)
                if "{" in nxt:
                    break
                if nxt.endswith(")") or nxt.endswith("throws") or nxt.endswith("rethrows"):
                    if j + 1 < len(lines):
                        next_line = lines[j + 1].strip()
                        if next_line.startswith("{"):
                            break
                    break
                j += 1

            sig = clean_signature(" ".join(sig_lines))
            entries.append(
                FunctionEntry(
                    path=str(path.relative_to(ROOT)),
                    line=start_line,
                    signature=sig,
                    language="Swift",
                )
            )
        i += 1

    return entries


def parse_python(path: Path) -> list[FunctionEntry]:
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    entries: list[FunctionEntry] = []

    i = 0
    while i < len(lines):
        line = lines[i]
        if PYTHON_PATTERN.match(line):
            start_line = i + 1
            sig_lines = [line.strip()]
            j = i + 1
            while j < len(lines) and len(sig_lines) < 8:
                if sig_lines[-1].endswith(":"):
                    break
                nxt = lines[j].strip()
                if not nxt or nxt.startswith("#"):
                    break
                sig_lines.append(nxt)
                if nxt.endswith(":"):
                    break
                j += 1

            sig = clean_signature(" ".join(sig_lines))
            entries.append(
                FunctionEntry(
                    path=str(path.relative_to(ROOT)),
                    line=start_line,
                    signature=sig,
                    language="Python",
                )
            )
        i += 1

    return entries


def parse_shell(path: Path) -> list[FunctionEntry]:
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    entries: list[FunctionEntry] = []

    for idx, line in enumerate(lines, start=1):
        stripped = line.strip()
        if SHELL_PATTERN_A.match(stripped) or SHELL_PATTERN_B.match(stripped):
            sig = clean_signature(stripped)
            entries.append(
                FunctionEntry(
                    path=str(path.relative_to(ROOT)),
                    line=idx,
                    signature=sig,
                    language="Shell",
                )
            )

    return entries


def parse_file(path: Path) -> list[FunctionEntry]:
    if path.suffix == ".swift":
        return parse_swift(path)
    if path.suffix == ".py":
        return parse_python(path)
    return parse_shell(path)


def collect_functions() -> list[FunctionEntry]:
    entries: list[FunctionEntry] = []
    for path in sorted(iter_source_files(ROOT)):
        try:
            entries.extend(parse_file(path))
        except Exception:
            continue
    return sorted(entries, key=lambda e: (e.path, e.line, e.signature))


def find_changes_in_worktree() -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    added: dict[str, list[str]] = defaultdict(list)
    removed: dict[str, list[str]] = defaultdict(list)

    try:
        out = subprocess.check_output(
            ["git", "diff", "--unified=0"],
            cwd=ROOT,
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return {}, {}

    current_file: str | None = None
    for raw in out.splitlines():
        m = DIFF_FILE_PATTERN.match(raw)
        if m:
            current_file = m.group(1)
            continue

        if current_file is None:
            continue

        if Path(current_file).suffix not in INCLUDE_EXTS:
            continue

        if raw.startswith("+++") or raw.startswith("---") or raw.startswith("@@"):
            continue

        def is_func_signature(text: str, path: str) -> bool:
            if path.endswith(".swift"):
                return bool(SWIFT_PATTERN.match(text))
            if path.endswith(".py"):
                return bool(PYTHON_PATTERN.match(text))
            return bool(SHELL_PATTERN_A.match(text.strip()) or SHELL_PATTERN_B.match(text.strip()))

        if raw.startswith("+"):
            line = raw[1:]
            if is_func_signature(line, current_file):
                added[current_file].append(clean_signature(line.strip()))
        elif raw.startswith("-"):
            line = raw[1:]
            if is_func_signature(line, current_file):
                removed[current_file].append(clean_signature(line.strip()))

    # dedupe while preserving order
    def dedupe(values: list[str]) -> list[str]:
        seen = set()
        result = []
        for v in values:
            if v in seen:
                continue
            seen.add(v)
            result.append(v)
        return result

    return ({k: dedupe(v) for k, v in added.items()}, {k: dedupe(v) for k, v in removed.items()})


def untracked_function_files(entries: list[FunctionEntry]) -> dict[str, list[FunctionEntry]]:
    try:
        out = subprocess.check_output(
            ["git", "status", "--porcelain"],
            cwd=ROOT,
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return {}

    untracked: set[str] = set()
    for row in out.splitlines():
        if not row.startswith("?? "):
            continue
        path = row[3:].strip()
        if Path(path).suffix in INCLUDE_EXTS:
            untracked.add(path)

    grouped: dict[str, list[FunctionEntry]] = defaultdict(list)
    for e in entries:
        if e.path in untracked:
            grouped[e.path].append(e)
    return dict(grouped)


def write_reference(entries: list[FunctionEntry]) -> None:
    now = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    by_lang: dict[str, int] = defaultdict(int)
    by_file: dict[str, list[FunctionEntry]] = defaultdict(list)
    for e in entries:
        by_lang[e.language] += 1
        by_file[e.path].append(e)

    lines: list[str] = []
    lines.append("# Function Reference")
    lines.append("")
    lines.append("This page is auto-generated from the current repository source and includes the latest code updates.")
    lines.append("")
    lines.append(f"Generated: `{now}`")
    lines.append("")
    lines.append("Regenerate with: `scripts/generate_function_wiki.py`")
    lines.append("")
    lines.append("## Coverage")
    lines.append("")
    lines.append(f"- Total functions found: **{len(entries)}**")
    for lang in sorted(by_lang):
        lines.append(f"- {lang}: **{by_lang[lang]}**")
    lines.append(f"- Files with functions: **{len(by_file)}**")
    lines.append("")
    lines.append("## By File")
    lines.append("")

    for file_path in sorted(by_file):
        lines.append(f"### `{file_path}`")
        lines.append("")
        for e in by_file[file_path]:
            lines.append(f"- `L{e.line}` `{e.signature}`")
        lines.append("")

    REFERENCE_PATH.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def write_updates(entries: list[FunctionEntry]) -> None:
    now = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    added, removed = find_changes_in_worktree()
    untracked = untracked_function_files(entries)

    indexed: dict[tuple[str, str], FunctionEntry] = {
        (e.path, e.signature): e for e in entries
    }

    lines: list[str] = []
    lines.append("# Function Updates")
    lines.append("")
    lines.append("This page tracks function-level changes currently present in the working tree compared to `HEAD`.")
    lines.append("")
    lines.append(f"Generated: `{now}`")
    lines.append("")
    lines.append("Regenerate with: `scripts/generate_function_wiki.py`")
    lines.append("")

    if not added and not removed and not untracked:
        lines.append("No function signature changes detected in the current working tree.")
    else:
        if added:
            lines.append("## Added or Updated Signatures")
            lines.append("")
            for file_path in sorted(added):
                lines.append(f"### `{file_path}`")
                lines.append("")
                for sig in added[file_path]:
                    entry = indexed.get((file_path, sig))
                    if entry:
                        lines.append(f"- `L{entry.line}` `{sig}`")
                    else:
                        lines.append(f"- `{sig}`")
                lines.append("")

        if removed:
            lines.append("## Removed Signatures")
            lines.append("")
            for file_path in sorted(removed):
                lines.append(f"### `{file_path}`")
                lines.append("")
                for sig in removed[file_path]:
                    lines.append(f"- `{sig}`")
                lines.append("")

        if untracked:
            lines.append("## Functions in Untracked Source Files")
            lines.append("")
            for file_path in sorted(untracked):
                lines.append(f"### `{file_path}`")
                lines.append("")
                for e in untracked[file_path]:
                    lines.append(f"- `L{e.line}` `{e.signature}`")
                lines.append("")

    UPDATES_PATH.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def main() -> None:
    entries = collect_functions()
    write_reference(entries)
    write_updates(entries)
    print(f"Wrote {REFERENCE_PATH.relative_to(ROOT)} and {UPDATES_PATH.relative_to(ROOT)}")
    print(f"Functions indexed: {len(entries)}")


if __name__ == "__main__":
    main()
