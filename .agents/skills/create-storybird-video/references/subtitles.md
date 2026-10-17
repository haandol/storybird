# Complete and consistent subtitles

Read for independent or Cue caption text, style, timing, split/merge, SRT, or caption verification.
For shared edit/revision rules, use [editing.md](editing.md).

Choose one subtitle style for the video before placing text: bottom-center by
default, the system font, one `font_size`, and consistent color/background settings.
Reuse it for independent and Cue subtitles; Cue fields are `subtitle_position`
and `subtitle_font_size`. Honor explicit user styling and
preserve existing styles in targeted edits. The renderer uses the full frame
width inside safe margins; do not simulate a narrow column with manual newlines.
Line breaks belong between words (Korean eojeol), never inside a word.

Unless the user explicitly permits shortening, include **all** text requested as
subtitles, in order. Narration subtitles must cover the full spoken script.
Do not summarize, omit clauses, add ellipses or reduce an individual caption's
font size to make it fit. Split long passages into successive timed segments at
word boundaries, preserving every word and punctuation mark. Use actual speech
timing and retain one style across those segments. If even one word cannot fit,
adjust the common size for the sequence or follow the user's explicit styling;
do not break that word or silently alter text.

Use independent-caption `split` only with both an internal project `time` and
`text_offset` counted in Unicode grapheme clusters. Use `merge` with the earliest
caption ID, adjacent non-overlapping `related_ids`, and explicit combined `text`.
Cue captions remain Cue components. Import an existing UTF-8 SRT with
`storybird_import_subtitles` (`project_id`, `expected_revision`, absolute `path`);
it appends all entries atomically. Export SRT only when requested, with an explicit
`scope` (`independent`, `cue`, `both`) and optional output directory. Read the
returned new path; export leaves the project and existing files unchanged.

Read back the saved subtitles and compare their ordered text with the source,
allowing only whitespace changes caused by wrapping/segmentation. Save the MCP
project response and full transcript outside the project library, then run:

```bash
python3 <skill-directory>/scripts/check-subtitles.py --project project.json --source transcript.txt
```

Resolve `<skill-directory>` to the directory containing SKILL.md, not this references directory. The read-only checker accepts
`get_project` or `get_edit_context` JSON, includes Cue subtitles, and fails on missing,
repeated, reordered or changed words and inconsistent position/size. For a targeted
edit, repeat `--subtitle-id` for its complete source scope. Use
`--allow-style-variation` only for explicit user styling exceptions; it never
bypasses text preservation. If shortening was authorized, use the approved revised
transcript as the source. Repair audit failures through MCP and read back again.

Inspect every changed segment, including the longest and multiline cases, for full text,
consistent size, bottom/top anchor and word boundaries. An overflow error requires
repair before export; successful text storage alone does not prove it is visible.
Check segment boundaries for accidental overlap: subtitle end times are inclusive.
