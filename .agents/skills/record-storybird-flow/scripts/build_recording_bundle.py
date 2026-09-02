#!/usr/bin/env python3
"""Build a versioned Storybird agent recording package atomically."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PACKAGE_EXTENSION = ".storybirdrecording"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def load_spec(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        raise ValueError("spec must be a regular JSON file")
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("spec root must be an object")
    return value


def required_text(spec: dict, key: str) -> str:
    value = spec.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{key} must be a non-empty string")
    return value.strip()


def validate_click(value: object, index: int) -> dict[str, float]:
    if not isinstance(value, dict):
        raise ValueError(f"step {index + 1} must include a click object")
    result: dict[str, float] = {}
    for key in ("x", "y"):
        coordinate = value.get(key)
        if not isinstance(coordinate, (int, float)):
            raise ValueError(f"step {index + 1} click {key} must be a number")
        coordinate = float(coordinate)
        if not math.isfinite(coordinate) or not 0 <= coordinate <= 1:
            raise ValueError(
                f"step {index + 1} click {key} must be between 0 and 1"
            )
        result[key] = coordinate
    return result


def validate_png(path: Path, index: int) -> None:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"step {index + 1} image must be a regular file")
    with path.open("rb") as handle:
        if handle.read(len(PNG_SIGNATURE)) != PNG_SIGNATURE:
            raise ValueError(f"step {index + 1} image must be PNG")


def reencode_png(source: Path, destination: Path, index: int) -> None:
    try:
        subprocess.run(
            [
                "sips",
                "-s",
                "format",
                "png",
                str(source),
                "--out",
                str(destination),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise ValueError(
            f"step {index + 1} image could not be re-encoded: {detail.strip()}"
        ) from error
    validate_png(destination, index)


def build_manifest(spec: dict, assets_dir: Path) -> dict:
    project_name = required_text(spec, "project_name")
    source_name = required_text(spec, "source_name")
    steps = spec.get("steps")
    if not isinstance(steps, list) or not steps:
        raise ValueError("steps must contain at least one screen")

    manifest_steps: list[dict] = []
    for index, value in enumerate(steps):
        if not isinstance(value, dict):
            raise ValueError(f"step {index + 1} must be an object")
        image_value = value.get("image")
        if not isinstance(image_value, str) or not image_value:
            raise ValueError(f"step {index + 1} image is required")
        image = Path(image_value).expanduser().resolve()
        validate_png(image, index)

        click = value.get("click")
        if index == 0:
            if click is not None:
                raise ValueError("the first step cannot include a click")
            normalized_click = None
        else:
            normalized_click = validate_click(click, index)

        asset_filename = f"step-{index + 1:04d}.png"
        reencode_png(image, assets_dir / asset_filename, index)
        manifest_step: dict[str, object] = {
            "assetFilename": asset_filename,
        }
        if normalized_click is not None:
            manifest_step["clickFromPrevious"] = normalized_click
        manifest_steps.append(manifest_step)

    return {
        "version": 1,
        "projectName": project_name,
        "sourceName": source_name,
        "steps": manifest_steps,
    }


def main() -> None:
    args = parse_args()
    output = args.output.expanduser().resolve()
    if output.suffix.lower() != PACKAGE_EXTENSION:
        raise ValueError(f"output must end in {PACKAGE_EXTENSION}")
    if output.exists():
        raise FileExistsError(f"output already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)

    spec = load_spec(args.spec.expanduser().resolve())
    staging_root = Path(
        tempfile.mkdtemp(prefix=f".{output.stem}-", dir=output.parent)
    )
    staging_package = staging_root / output.name
    assets_dir = staging_package / "assets"

    try:
        assets_dir.mkdir(parents=True)
        manifest = build_manifest(spec, assets_dir)
        manifest_path = staging_package / "manifest.json"
        with manifest_path.open("w", encoding="utf-8") as handle:
            json.dump(
                manifest,
                handle,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            handle.write("\n")
        os.replace(staging_package, output)
    finally:
        shutil.rmtree(staging_root, ignore_errors=True)

    print(output)


if __name__ == "__main__":
    main()
