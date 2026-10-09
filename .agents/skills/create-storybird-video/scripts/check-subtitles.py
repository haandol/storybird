#!/usr/bin/env python3
"""Read-only audit of MCP project JSON against the complete requested transcript."""

import argparse
import json
from pathlib import Path


def audit(document, source, selected_ids=(), allow_style_variation=False):
    project = document.get("project", document)
    subtitles = list(project.get("subtitles", []))
    subtitles.extend(
        dict(click["cueSubtitle"], id=click["id"])
        for click in project.get("clicks", [])
        if click.get("cueSubtitle", {}).get("text", "").strip()
    )
    selected_ids = set(selected_ids)
    issues = []
    if selected_ids:
        missing = selected_ids - {subtitle["id"] for subtitle in subtitles}
        if missing:
            issues.append({"kind": "missing_subtitle_ids", "ids": sorted(missing)})
        subtitles = [subtitle for subtitle in subtitles if subtitle["id"] in selected_ids]
    subtitles.sort(key=lambda subtitle: (subtitle["startTime"], subtitle["id"]))
    expected = source.split()
    actual = [word for subtitle in subtitles for word in subtitle["text"].split()]
    if actual != expected:
        first = next((i for i, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]),
                     min(len(expected), len(actual)))
        issues.append({"kind": "source_text_mismatch", "first_different_word": first + 1,
                       "source_words": len(expected), "subtitle_words": len(actual)})
    styles = sorted({(subtitle.get("position", "bottom"), subtitle.get("style", {}).get("fontSize", 17))
                     for subtitle in subtitles})
    if len(styles) > 1 and not allow_style_variation:
        issues.append({"kind": "inconsistent_position_or_font_size"})
    return {"ok": not issues, "subtitle_count": len(subtitles),
            "styles": [{"position": position, "font_size": size} for position, size in styles],
            "issues": issues}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True, type=Path, help="Saved get_project or get_edit_context response")
    parser.add_argument("--source", required=True, type=Path, help="Complete requested subtitle transcript (UTF-8)")
    parser.add_argument("--subtitle-id", action="append", default=[], help="Limit a targeted audit; repeat for each ID")
    parser.add_argument("--allow-style-variation", action="store_true", help="Only for explicit user styling exceptions")
    args = parser.parse_args()
    try:
        result = audit(json.loads(args.project.read_text(encoding="utf-8")),
                       args.source.read_text(encoding="utf-8"), args.subtitle_id, args.allow_style_variation)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        result = {"ok": False, "issues": [{"kind": "invalid_input", "message": str(error)}]}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
