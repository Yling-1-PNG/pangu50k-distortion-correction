"""Offline OpenCV-fisheye reference; never treats a display photo as calibration.

For every output pixel, undo the requested image-plane affine transform,
project its virtual pinhole ray through the fisheye model, then sample the
source camera with bilinear interpolation. This is a PC oracle, not FPGA RTL.
"""

from __future__ import annotations

import argparse
import glob
import json
from pathlib import Path

import cv2
import numpy as np


MODEL_NAME = "opencv_fisheye"


def _camera_matrix(value: np.ndarray) -> np.ndarray:
    matrix = np.asarray(value, dtype=np.float64)
    if (matrix.shape != (3, 3) or not np.all(np.isfinite(matrix))
            or matrix[0, 0] <= 0 or matrix[1, 1] <= 0
            or not np.allclose(matrix[2], [0, 0, 1])
            or abs(matrix[0, 1]) > 1e-12 or abs(matrix[1, 0]) > 1e-12):
        raise ValueError("expected a finite zero-skew 3x3 camera matrix with positive focal lengths")
    return matrix


def _distortion(value: np.ndarray) -> np.ndarray:
    coefficients = np.asarray(value, dtype=np.float64).reshape(-1)
    if coefficients.size != 4 or not np.all(np.isfinite(coefficients)):
        raise ValueError("OpenCV fisheye distortion needs exactly k1,k2,k3,k4")
    return coefficients


def load_calibration(path: str | Path) -> dict:
    record = json.loads(Path(path).read_text(encoding="utf-8"))
    if record.get("model") != MODEL_NAME:
        raise ValueError("calibration is not an OpenCV fisheye record; do not mix it with Brown-Conrady")
    _camera_matrix(record["camera_matrix"])
    _distortion(record["distortion"])
    size = record["image_size"]
    if len(size) != 2 or any(not isinstance(v, int) or v <= 0 for v in size):
        raise ValueError("image_size must contain positive integer width and height")
    return record


def output_camera_matrix(
    width: int, height: int, camera_matrix: np.ndarray, distortion: np.ndarray,
    balance: float = 0.0,
) -> np.ndarray:
    """balance=0 favors a filled rectilinear image; balance=1 retains more FOV."""
    if width <= 0 or height <= 0 or not np.isfinite(balance) or not 0 <= balance <= 1:
        raise ValueError("invalid image size or balance (must be 0..1)")
    return cv2.fisheye.estimateNewCameraMatrixForUndistortRectify(
        _camera_matrix(camera_matrix), _distortion(distortion).reshape(4, 1),
        (width, height), np.eye(3), balance=float(balance), new_size=(width, height),
    )


def build_fisheye_remap(
    width: int, height: int, camera_matrix: np.ndarray, distortion: np.ndarray,
    output_matrix: np.ndarray, angle_degrees: float = 0.0,
    affine_matrix: np.ndarray | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    """Return output-to-source maps; angle and affine are mutually exclusive."""
    if width <= 0 or height <= 0 or not np.isfinite(angle_degrees):
        raise ValueError("invalid image size or angle")
    if affine_matrix is not None and angle_degrees != 0:
        raise ValueError("choose either angle_degrees or affine_matrix")
    source_k = _camera_matrix(camera_matrix)
    output_k = _camera_matrix(output_matrix)
    k1, k2, k3, k4 = _distortion(distortion)

    forward = (cv2.getRotationMatrix2D(((width - 1) / 2, (height - 1) / 2), angle_degrees, 1)
               if affine_matrix is None else np.asarray(affine_matrix, dtype=np.float64))
    if forward.shape != (2, 3) or not np.all(np.isfinite(forward)):
        raise ValueError("affine_matrix must be a finite 2x3 matrix")
    if abs(np.linalg.det(forward[:, :2])) < 1e-12:
        raise ValueError("affine_matrix is singular")
    inverse = cv2.invertAffineTransform(forward)
    yy, xx = np.indices((height, width), dtype=np.float64)
    ux = inverse[0, 0] * xx + inverse[0, 1] * yy + inverse[0, 2]
    uy = inverse[1, 0] * xx + inverse[1, 1] * yy + inverse[1, 2]

    x = (ux - output_k[0, 2]) / output_k[0, 0]
    y = (uy - output_k[1, 2]) / output_k[1, 1]
    radius = np.hypot(x, y)
    theta = np.arctan(radius)
    theta2 = theta * theta
    theta_d = theta * (1 + theta2 * (k1 + theta2 * (k2 + theta2 * (k3 + theta2 * k4))))
    scale = np.divide(theta_d, radius, out=np.ones_like(radius), where=radius > 1e-12)
    map_x = source_k[0, 0] * x * scale + source_k[0, 2]
    map_y = source_k[1, 1] * y * scale + source_k[1, 2]
    return map_x.astype(np.float32), map_y.astype(np.float32)


def valid_source_mask(map_x: np.ndarray, map_y: np.ndarray, width: int, height: int) -> np.ndarray:
    """Only coordinate bounds, not the camera's physical image-circle validity."""
    return ((map_x >= 0) & (map_x <= width - 1)
            & (map_y >= 0) & (map_y <= height - 1))


def correct_fisheye(
    image: np.ndarray, camera_matrix: np.ndarray, distortion: np.ndarray,
    balance: float = 0.0, angle_degrees: float = 0.0,
    affine_matrix: np.ndarray | None = None,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    height, width = image.shape[:2]
    output_k = output_camera_matrix(width, height, camera_matrix, distortion, balance)
    map_x, map_y = build_fisheye_remap(
        width, height, camera_matrix, distortion, output_k, angle_degrees, affine_matrix,
    )
    corrected = cv2.remap(image, map_x, map_y, cv2.INTER_LINEAR,
                          borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    return corrected, valid_source_mask(map_x, map_y, width, height), output_k


def calibrate_fisheye(images: list[Path], columns: int, rows: int, square_size: float) -> dict:
    """Fit one camera using inner checkerboard corners from original sensor frames."""
    if columns < 2 or rows < 2 or not np.isfinite(square_size) or square_size <= 0:
        raise ValueError("invalid checkerboard geometry")
    pattern = (columns, rows)
    object_grid = np.zeros((1, columns * rows, 3), np.float64)
    object_grid[0, :, :2] = np.mgrid[0:columns, 0:rows].T.reshape(-1, 2) * square_size
    object_points, image_points, accepted = [], [], []
    image_size = None
    for path in images:
        image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
        if image is None:
            continue
        size = (image.shape[1], image.shape[0])
        if image_size is None:
            image_size = size
        if size != image_size:
            raise ValueError(f"mixed image sizes: {path}")
        found, corners = cv2.findChessboardCornersSB(image, pattern)
        if not found:
            found, corners = cv2.findChessboardCorners(image, pattern)
            if found:
                corners = cv2.cornerSubPix(
                    image, corners, (5, 5), (-1, -1),
                    (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001),
                )
        if found:
            object_points.append(object_grid.copy())
            image_points.append(corners.reshape(1, -1, 2).astype(np.float64))
            accepted.append(str(path))
    if len(accepted) < 8:
        raise ValueError(f"only {len(accepted)} usable views; need at least 8 diverse raw checkerboard frames")
    k = np.eye(3, dtype=np.float64)
    d = np.zeros((4, 1), dtype=np.float64)
    try:
        rms, k, d, _, _ = cv2.fisheye.calibrate(
            object_points, image_points, image_size, k, d,
            flags=cv2.fisheye.CALIB_RECOMPUTE_EXTRINSIC | cv2.fisheye.CALIB_CHECK_COND,
            criteria=(cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 100, 1e-7),
        )
    except cv2.error as exc:
        raise ValueError("fisheye calibration failed; vary board pose/coverage and remove blurry frames") from exc
    if not np.isfinite(rms) or not np.all(np.isfinite(k)) or not np.all(np.isfinite(d)):
        raise ValueError("fisheye calibration returned non-finite values")
    return {
        "model": MODEL_NAME,
        "camera_matrix": k.tolist(), "distortion": d.reshape(-1).tolist(),
        "image_size": list(image_size), "rms_reprojection_error_px": float(rms),
        "checkerboard_inner_corners": [columns, rows], "square_size": square_size,
        "accepted_images": accepted,
        "note": "Real calibration only if accepted_images are original frames from the actual camera.",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    c = commands.add_parser("calibrate", help="calibrate from original checkerboard frames")
    c.add_argument("--images", required=True, help="glob such as photos/*.png")
    c.add_argument("--columns", type=int, required=True, help="inner corners per row")
    c.add_argument("--rows", type=int, required=True, help="inner corners per column")
    c.add_argument("--square-size", type=float, required=True, help="e.g. millimetres")
    c.add_argument("--output", type=Path, required=True)
    r = commands.add_parser("correct", help="fisheye correction and optional angle/affine")
    r.add_argument("--image", type=Path, required=True)
    r.add_argument("--calibration", type=Path, required=True)
    r.add_argument("--balance", type=float, default=0.0, help="0..1; more FOV may cause borders")
    r.add_argument("--angle", type=float, default=0.0)
    r.add_argument("--affine", type=Path, help="JSON containing a forward 2x3 affine_matrix")
    r.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "calibrate":
        record = calibrate_fisheye(
            [Path(p) for p in sorted(glob.glob(args.images))], args.columns, args.rows, args.square_size,
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(record, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"accepted={len(record['accepted_images'])} rms_px={record['rms_reprojection_error_px']:.4f}")
    else:
        record = load_calibration(args.calibration)
        image = cv2.imread(str(args.image), cv2.IMREAD_UNCHANGED)
        if image is None:
            raise ValueError(f"cannot read {args.image}")
        if list(image.shape[1::-1]) != record["image_size"]:
            raise ValueError("image size differs from calibration; use original matching-resolution frames")
        affine = None
        if args.affine:
            affine = np.asarray(json.loads(args.affine.read_text(encoding="utf-8"))["affine_matrix"])
        corrected, mask, _ = correct_fisheye(
            image, record["camera_matrix"], record["distortion"], args.balance, args.angle, affine,
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        if not cv2.imwrite(str(args.output), corrected):
            raise OSError(f"cannot write {args.output}")
        print(f"{args.output} coordinate_in_bounds={np.mean(mask):.3%}; physical image circle not assessed")


if __name__ == "__main__":
    main()
