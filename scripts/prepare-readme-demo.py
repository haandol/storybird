#!/usr/bin/env python3
"""Create synthetic README footage and a disposable library under .build only.

Requires Pillow, FFmpeg, and the project's Swift toolchain. This does not launch
Storybird, change saved settings, or access an existing project/voice library.
"""
from pathlib import Path
import shutil
import subprocess

from PIL import Image, ImageDraw, ImageFont

REPOSITORY = Path(__file__).resolve().parents[1]
OUTPUT = REPOSITORY / ".build/readme-demo"


def draw_demo() -> None:
    """Draw a fictional workspace with fixed text and no external assets."""
    image = Image.new("RGB", (1280, 720), "#F6F7FC")
    draw = ImageDraw.Draw(image)
    fonts = Path("/System/Library/Fonts/Supplemental")

    def text(x, y, value, size=22, color="#25314D", bold=False):
        font = fonts / ("Arial Bold.ttf" if bold else "Arial.ttf")
        draw.text((x, y), value, font=ImageFont.truetype(str(font), size), fill=color)

    draw.rectangle((0, 0, 1280, 75), fill="#18233D")
    text(34, 23, "Northstar", 26, "#FFFFFF", True)
    text(1010, 28, "Demo workspace", 17, "#BFCBE5")
    draw.rectangle((0, 75, 234, 720), fill="#EDF0F8")
    text(28, 116, "WORKSPACE", 13, "#7D88A1", True)
    draw.rounded_rectangle((16, 156, 218, 211), 12, fill="#DDDFFA")
    text(34, 173, "Projects", 20, "#4F46C8", True)
    for y, label in [(235, "Templates"), (292, "Team"), (350, "Settings")]:
        text(34, y, label, 19, "#6D7893")
    text(282, 119, "Launch checklist", 36, bold=True)
    text(284, 170, "Everything your team needs for a clear product walkthrough.", 19, "#7C879D")
    draw.rounded_rectangle((282, 226, 1230, 350), 18, fill="#FFFFFF")
    text(310, 250, "Product introduction", 24, bold=True)
    text(310, 296, "3 steps  /  English tutorial  /  Demo content only", 18, "#7B869A")
    draw.rounded_rectangle((1010, 266, 1198, 312), 12, fill="#6152D9")
    text(1038, 280, "Create project", 17, "#FFFFFF", True)
    rows = [
        (384, "Create a project", "Choose a name and start with a clear goal.", "Ready", "#29A781"),
        (481, "Record the workflow", "Show the action and the result on screen.", "Next", "#6855D9"),
        (578, "Explain with your voice", "Add narration, captions, and a final preview.", "Next", "#6855D9"),
    ]
    for y, title, description, status, color in rows:
        draw.rounded_rectangle((282, y, 1230, y + 80), 14, fill="#FFFFFF")
        draw.ellipse((307, y + 26, 335, y + 54), fill=color)
        text(357, y + 13, title, 21, bold=True)
        text(357, y + 44, description, 16, "#7B869A")
        text(1130, y + 30, status, 17, color, True)
    image.save(OUTPUT / "demo-source.png")


def main() -> None:
    """Build with current objects, then prepare only the disposable demo root."""
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise SystemExit("Install FFmpeg before generating the README demo.")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    draw_demo()
    subprocess.run([
        ffmpeg, "-y", "-loglevel", "error", "-loop", "1", "-i",
        str(OUTPUT / "demo-source.png"), "-t", "18", "-r", "30",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", str(OUTPUT / "demo-source.mp4"),
    ], check=True)
    subprocess.run(["swift", "build", "-c", "debug"], cwd=REPOSITORY, check=True)
    binary_root = Path(subprocess.check_output(
        ["swift", "build", "-c", "debug", "--show-bin-path"],
        cwd=REPOSITORY, text=True,
    ).strip())
    # Use the current link list: old object files may survive source renames.
    objects = [line for line in (binary_root / "Storybird.product/Objects.LinkFileList")
               .read_text().splitlines() if "/StorybirdCore.build/" in line]
    subprocess.run([
        "swiftc", "-I", str(binary_root / "Modules"),
        str(REPOSITORY / "scripts/prepare-readme-demo.swift"), *objects,
        "-o", str(OUTPUT / "prepare"),
    ], cwd=REPOSITORY, check=True)
    subprocess.run([str(OUTPUT / "prepare")], cwd=REPOSITORY, check=True)


if __name__ == "__main__":
    main()
