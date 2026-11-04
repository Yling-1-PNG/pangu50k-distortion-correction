"""Append-only JSONL records for reproducible PC correction sessions."""

from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any


def build_session_record(
    *,
    input_image: str | Path,
    output_image: str | Path,
    calibration: str | Path,
    preview_summary: dict[str, Any],
    note: str = "",
    timestamp_utc: str | None = None,
) -> dict[str, Any]:
    """Build one JSON-ready record without modifying the filesystem."""
    if not isinstance(preview_summary, dict):
        raise TypeError("preview_summary must be a dictionary")
    timestamp = (datetime.now(timezone.utc).isoformat(timespec="milliseconds")
                 if timestamp_utc is None else timestamp_utc)
    if not timestamp:
        raise ValueError("timestamp_utc must not be empty")
    return {
        "timestamp_utc": timestamp,
        "input_image": str(input_image),
        "output_image": str(output_image),
        "calibration": str(calibration),
        "preview": preview_summary,
        "note": note,
    }


def append_jsonl(path: str | Path, record: dict[str, Any]) -> None:
    """Append one record and flush it; existing sessions are intentionally retained."""
    if not isinstance(record, dict):
        raise TypeError("record must be a dictionary")
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("a", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
        stream.flush()
