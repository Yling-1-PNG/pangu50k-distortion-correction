"""Generate a PC golden corrected frame for a host-side preview.

This is an offline reference entry point.  It does not open a camera, serial
port, HDMI device, or FPGA connection.  Brown-Conrady and OpenCV-fisheye
calibration records are dispatched to the existing reference models, while
the measured mechanical angle is mapped through :mod:`host.angle_mapping`.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import cv2
import numpy as np

from host.angle_mapping import AngleMapping
from host.session_log import append_jsonl, build_session_record
from tools.fisheye_model import correct_fisheye
from tools.golden_model import correct_image


SUPPORTED_MODELS = {"brown_conrady", "opencv_fisheye"}


def load_record(path: str | Path) -> dict[str, Any]:
    """Load and validate the common metadata needed by the preview."""
    record = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(record, dict):
        raise ValueError("calibration JSON must contain an object")
    model = record.get("model")
    if model not in SUPPORTED_MODELS:
        raise ValueError(f"unsupported calibration model: {model!r}")
    image_size = record.get("image_size")
    if (not isinstance(image_size, list) or len(image_size) != 2
            or any(isinstance(value, bool) or not isinstance(value, int) or value <= 0
                   for value in image_size)):
        raise ValueError("image_size must be [width, height] with positive integers")
    return record


def correct_frame(
    image: np.ndarray,
    calibration: dict[str, Any],
    *,
    measured_angle_deg: float | None = None,
    requested_angle_deg: float | None = None,
    zero_deg: float = 0.0,
    compensation_sign: int = -1,
    balance: float = 0.0,
    output_focal_px: float | None = None,
) -> tuple[np.ndarray, dict[str, Any]]:
    """Correct one frame and return ``(image, JSON-ready metadata)``.

    A missing measured angle means zero compensation, which is useful for a
    fixed-camera preview.  When it is present, the returned metadata retains
    the physical reading and the candidate FPGA angle separately.
    """
    if image is None or image.ndim not in (2, 3):
        raise ValueError("image must be a grayscale or color array")
    record_model = calibration.get("model")
    if record_model not in SUPPORTED_MODELS:
        raise ValueError(f"unsupported calibration model: {record_model!r}")
    height, width = image.shape[:2]
    if [width, height] != calibration.get("image_size"):
        raise ValueError("image size differs from calibration; use matching-resolution input")

    angle_record: dict[str, Any] = {
        "source": "none",
        "requested_deg": None,
        "measured_deg": None,
        "zero_deg": float(zero_deg),
        "relative_deg": 0.0,
        "compensation_deg": 0.0,
        "note": "fixed-angle preview",
    }
    if measured_angle_deg is not None:
        angle_record = AngleMapping(
            zero_deg=zero_deg, compensation_sign=compensation_sign,
        ).record(
            measured_angle_deg, source="manual-protractor", requested_deg=requested_angle_deg,
        )
    compensation = float(angle_record["compensation_deg"])

    if record_model == "brown_conrady":
        camera_matrix = np.asarray(calibration["camera_matrix"], dtype=np.float64)
        distortion = np.asarray(calibration["distortion"], dtype=np.float64)
        corrected = correct_image(image, camera_matrix, distortion, compensation)
        valid_fraction = None
    else:
        corrected, valid_mask, _ = correct_fisheye(
            image, calibration["camera_matrix"], calibration["distortion"],
            balance=balance, angle_degrees=compensation,
            output_focal_px=output_focal_px,
        )
        valid_fraction = float(np.mean(valid_mask))

    metadata: dict[str, Any] = {
        "model": record_model,
        "input_size": [width, height],
        "angle": angle_record,
        "coordinate_in_bounds_fraction": valid_fraction,
        "note": "PC golden preview only; not FPGA output or hardware validation",
    }
    return corrected, metadata


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--calibration", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--summary", type=Path,
                        help="optional JSON summary path; existing files are overwritten")
    parser.add_argument("--session-log", type=Path,
                        help="optional append-only JSONL session log")
    parser.add_argument("--note", default="")
    parser.add_argument("--measured-angle", type=float,
                        help="physical angle read from the manual stage/protractor")
    parser.add_argument("--requested-angle", type=float)
    parser.add_argument("--zero-deg", type=float, default=0.0)
    parser.add_argument("--compensation-sign", type=int, choices=(-1, 1), default=-1)
    parser.add_argument("--balance", type=float, default=0.0,
                        help="fisheye FOV balance in 0..1")
    parser.add_argument("--output-focal-px", type=float,
                        help="explicit centered fisheye output focal length")
    args = parser.parse_args(argv)

    calibration = load_record(args.calibration)
    image = cv2.imread(str(args.image), cv2.IMREAD_UNCHANGED)
    if image is None:
        parser.error(f"cannot read image: {args.image}")
    try:
        corrected, summary = correct_frame(
            image, calibration,
            measured_angle_deg=args.measured_angle,
            requested_angle_deg=args.requested_angle,
            zero_deg=args.zero_deg,
            compensation_sign=args.compensation_sign,
            balance=args.balance,
            output_focal_px=args.output_focal_px,
        )
    except (KeyError, TypeError, ValueError) as exc:
        parser.error(str(exc))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(args.output), corrected):
        parser.error(f"cannot write output image: {args.output}")
    if args.summary is not None:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    if args.session_log is not None:
        append_jsonl(args.session_log, build_session_record(
            input_image=args.image,
            output_image=args.output,
            calibration=args.calibration,
            preview_summary=summary,
            note=args.note,
        ))
    print(json.dumps(summary, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
