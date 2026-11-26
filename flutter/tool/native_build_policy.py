#!/usr/bin/env python3
"""Map changed Flutter files to native app rebuild targets.

Dart feature code and verified pure-Dart dependencies are delivered through
Web deployment and Shorebird OTA. Only native sources/configuration,
platform plugins, and packaged resources require rebuilt app binaries.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from collections.abc import Iterable

ANDROID_PREFIXES = (
    "flutter/android/",
    "flutter/tool/android/",
)
MACOS_PREFIXES = (
    "flutter/macos/",
    "flutter/tool/macos/",
)
DEPENDENCY_MANIFEST_FILES = {
    "flutter/pubspec.yaml",
    "flutter/pubspec.lock",
}
SHARED_NATIVE_FILES = {
    "flutter/tool/prepare_platforms.py",
    "flutter/tool/prepare_fonts.py",
}

# These packages have been reviewed as pure Dart / browser-library code:
# no Flutter plugin registration, FFI, native assets, or platform build steps.
# Add a package here only after checking its complete runtime dependency graph.
DART_ONLY_DEPENDENCIES = {
    "koni_archive_core",
    "koni_codecs",
    "koni_zip",
    "args",
    "petitparser",
    "xml",
    "web",
    "crypto",
    "flutter_svg",
    "vector_graphics",
    "vector_graphics_codec",
    "vector_graphics_compiler",
    "vector_math",
    "path_parsing",
    "path",
    "cli_util",
    "meta",
}
PUBSPEC_SECTIONS = {"dependencies", "dev_dependencies", "dependency_overrides"}


def _parse_pubspec(content: str) -> tuple[tuple[str, ...], dict[str, tuple[str, ...]]]:
    """Separate non-dependency settings from named dependency blocks."""
    other: list[str] = []
    packages: dict[str, tuple[str, ...]] = {}
    section: str | None = None
    current_name: str | None = None
    current_block: list[str] = []

    def finish_package() -> None:
        nonlocal current_name, current_block
        if current_name is not None:
            packages[current_name] = tuple(current_block)
        current_name = None
        current_block = []

    for line in content.splitlines():
        stripped = line.strip()
        is_root = bool(line) and not line[0].isspace()

        if is_root:
            finish_package()
            section = None
            if stripped.endswith(":") and stripped[:-1] in PUBSPEC_SECTIONS:
                section = stripped[:-1]
            else:
                other.append(stripped)
            continue

        if section is None:
            if stripped:
                other.append(stripped)
            continue

        if line.startswith("  ") and not line.startswith("    ") and ":" in line:
            finish_package()
            name = stripped.split(":", 1)[0]
            current_name = f"{section}:{name}"
            current_block = [stripped]
        elif current_name is not None and stripped:
            current_block.append(stripped)

    finish_package()
    return tuple(other), packages


def _parse_lockfile(content: str) -> tuple[tuple[str, ...], dict[str, tuple[str, ...]]]:
    """Separate package records from SDK / lockfile metadata."""
    other: list[str] = []
    packages: dict[str, tuple[str, ...]] = {}
    in_packages = False
    current_name: str | None = None
    current_block: list[str] = []

    def finish_package() -> None:
        nonlocal current_name, current_block
        if current_name is not None:
            packages[current_name] = tuple(current_block)
        current_name = None
        current_block = []

    for line in content.splitlines():
        stripped = line.strip()
        is_root = bool(line) and not line[0].isspace()

        if is_root:
            finish_package()
            in_packages = stripped == "packages:"
            if not in_packages:
                other.append(stripped)
            continue

        if not in_packages:
            if stripped:
                other.append(stripped)
            continue

        if line.startswith("  ") and not line.startswith("    ") and stripped.endswith(":"):
            finish_package()
            current_name = stripped[:-1].strip("\"'")
            current_block = [stripped]
        elif current_name is not None and stripped:
            current_block.append(stripped)

    finish_package()
    return tuple(other), packages


def _manifest_is_dart_only(
    before: str,
    after: str,
    parser,
) -> bool:
    before_other, before_packages = parser(before)
    after_other, after_packages = parser(after)
    if before_other != after_other:
        return False

    changed = {
        name
        for name in before_packages.keys() | after_packages.keys()
        if before_packages.get(name) != after_packages.get(name)
    }
    package_names = {name.split(":", 1)[-1] for name in changed}
    return package_names.issubset(DART_ONLY_DEPENDENCIES)


def pubspec_change_is_dart_only(before: str, after: str) -> bool:
    return _manifest_is_dart_only(before, after, _parse_pubspec)


def lockfile_change_is_dart_only(before: str, after: str) -> bool:
    return _manifest_is_dart_only(before, after, _parse_lockfile)


def _git_show(ref: str, path: str) -> str | None:
    result = subprocess.run(
        ["git", "show", f"{ref}:{path}"],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout if result.returncode == 0 else None


def dependency_manifests_are_dart_only(base_ref: str, head_ref: str) -> bool:
    """Check both dependency manifests before suppressing native rebuilds."""
    if not base_ref or not head_ref or re.fullmatch(r"0+", base_ref):
        return False

    changed_any = False
    for path, classifier in (
        ("flutter/pubspec.yaml", pubspec_change_is_dart_only),
        ("flutter/pubspec.lock", lockfile_change_is_dart_only),
    ):
        before = _git_show(base_ref, path)
        after = _git_show(head_ref, path)
        if before == after:
            continue
        changed_any = True
        if before is None or after is None or not classifier(before, after):
            return False

    return changed_any


def native_targets(
    paths: Iterable[str],
    *,
    dart_only_dependency_manifests: bool = False,
) -> tuple[bool, bool]:
    android = False
    macos = False

    for raw_path in paths:
        path = raw_path.strip()
        if not path:
            continue

        if path.startswith(ANDROID_PREFIXES):
            android = True
        if path.startswith(MACOS_PREFIXES):
            macos = True
        if path in DEPENDENCY_MANIFEST_FILES:
            if not dart_only_dependency_manifests:
                android = True
                macos = True
        elif path in SHARED_NATIVE_FILES or path.startswith("flutter/assets/"):
            android = True
            macos = True

    return android, macos


def main() -> None:
    paths = list(sys.stdin)
    manifest_changed = any(
        path.strip() in DEPENDENCY_MANIFEST_FILES for path in paths
    )
    dart_only = False
    if manifest_changed:
        dart_only = dependency_manifests_are_dart_only(
            os.environ.get("BASE_SHA", ""),
            os.environ.get("HEAD_SHA", ""),
        )

    android, macos = native_targets(
        paths,
        dart_only_dependency_manifests=dart_only,
    )
    print(f"android={'true' if android else 'false'}")
    print(f"macos={'true' if macos else 'false'}")


if __name__ == "__main__":
    main()
