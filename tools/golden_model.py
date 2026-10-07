"""PC reference for single-camera lens correction and arbitrary-angle rotation.

Coordinates describe pixel centres. For each output pixel, the inverse affine
transform finds an undistorted image position; the Brown-Conrady model then
finds the corresponding source-camera position. cv2.remap samples that source.
"""

from __future__ import annotations

import argparse
import glob
import json
from pathlib import Path

import cv2
import numpy as np


def load_calibration(path: str | Path) -> tuple[np.ndarray, np.ndarray]:
    record = json.loads(Path(path).read_text(encoding="utf-8"))
    camera_matrix = np.asarray(record["camera_matrix"], dtype=np.float64)
    distortion = np.asarray(record["distortion"], dtype=np.float64).reshape(-1)
    if camera_matrix.shape != (3, 3) or distortion.size < 4:
        raise ValueError("camera_matrix must be 3x3 and distortion needs k1,k2,p1,p2")
    if not np.all(np.isfinite(camera_matrix)) or not np.all(np.isfinite(distortion)):
        raise ValueError("calibration contains non-finite values")
    if camera_matrix[0, 0] <= 0 or camera_matrix[1, 1] <= 0:
        raise ValueError("focal lengths must be positive")
    if not np.allclose(camera_matrix[2], [0, 0, 1]) or abs(camera_matrix[0, 1]) > 1e-12:
        raise ValueError("only conventional zero-skew camera matrices are supported")
    if distortion.size not in (4, 5):
        raise ValueError("this baseline supports k1,k2,p1,p2[,k3] only")
    return camera_matrix, distortion


def build_remap(
    width: int,
    height: int,
    camera_matrix: np.ndarray,
    distortion: np.ndarray,
    angle_degrees: float = 0.0,
    affine_matrix: np.ndarray | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    """Map output (rectified, then forward-affine-transformed) to camera pixels."""
    if width <= 0 or height <= 0 or not np.isfinite(angle_degrees):
        raise ValueError("invalid image size or angle")
    if affine_matrix is not None and angle_degrees != 0:
        raise ValueError("choose either angle_degrees or affine_matrix")
    k = np.asarray(camera_matrix, dtype=np.float64)
    d = np.asarray(distortion, dtype=np.float64).reshape(-1)
    if k.shape != (3, 3) or d.size not in (4, 5):
        raise ValueError("expected a 3x3 camera matrix and 4 or 5 distortion coefficients")
    k1, k2, p1, p2 = d[:4]
    k3 = d[4] if d.size == 5 else 0.0

    yy, xx = np.indices((height, width), dtype=np.float64)
    cx_image, cy_image = (width - 1) / 2.0, (height - 1) / 2.0
    forward = (
        cv2.getRotationMatrix2D((cx_image, cy_image), angle_degrees, 1.0)
        if affine_matrix is None else np.asarray(affine_matrix, dtype=np.float64)
    )
    if forward.shape != (2, 3) or not np.all(np.isfinite(forward)):
        raise ValueError("affine_matrix must be a finite 2x3 matrix")
    if abs(np.linalg.det(forward[:, :2])) < 1e-12:
        raise ValueError("affine_matrix is singular")
    inverse = cv2.invertAffineTransform(forward)
    ux = inverse[0, 0] * xx + inverse[0, 1] * yy + inverse[0, 2]
    uy = inverse[1, 0] * xx + inverse[1, 1] * yy + inverse[1, 2]

    x = (ux - k[0, 2]) / k[0, 0]
    y = (uy - k[1, 2]) / k[1, 1]
    r2 = x * x + y * y
    radial = 1.0 + k1 * r2 + k2 * r2 * r2 + k3 * r2 * r2 * r2
    xd = x * radial + 2.0 * p1 * x * y + p2 * (r2 + 2.0 * x * x)
    yd = y * radial + p1 * (r2 + 2.0 * y * y) + 2.0 * p2 * x * y
    return (k[0, 0] * xd + k[0, 2]).astype(np.float32), (
        k[1, 1] * yd + k[1, 2]
    ).astype(np.float32)


def correct_image(
    image: np.ndarray, camera_matrix: np.ndarray, distortion: np.ndarray,
    angle_degrees: float = 0.0, affine_matrix: np.ndarray | None = None,
) -> np.ndarray:
    height, width = image.shape[:2]
    map_x, map_y = build_remap(width, height, camera_matrix, distortion, angle_degrees, affine_matrix)
    return cv2.remap(image, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)


def calibrate(images: list[Path], columns: int, rows: int, square_size: float) -> dict:
    """columns/rows are inner corners; square_size uses the caller's length unit."""
    if columns < 2 or rows < 2 or square_size <= 0:
        raise ValueError("invalid checkerboard geometry")
    pattern = (columns, rows)
    object_grid = np.zeros((columns * rows, 3), np.float32)
    object_grid[:, :2] = np.mgrid[0:columns, 0:rows].T.reshape(-1, 2) * square_size
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
        found, corners = cv2.findChessboardCorners(image, pattern)
        if not found:
            continue
        corners = cv2.cornerSubPix(
            image, corners, (5, 5), (-1, -1),
            (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001),
        )
        object_points.append(object_grid.copy())
        image_points.append(corners)
        accepted.append(str(path))
    if len(accepted) < 3:
        raise ValueError(f"only {len(accepted)} usable views; provide at least 3 diverse checkerboard photos")
    rms, matrix, coefficients, _, _ = cv2.calibrateCamera(
        object_points, image_points, image_size, None, None
    )
    return {
        "camera_matrix": matrix.tolist(),
        "distortion": coefficients.reshape(-1)[:5].tolist(),
        "image_size": list(image_size),
        "rms_reprojection_error_px": float(rms),
        "checkerboard_inner_corners": [columns, rows],
        "square_size": square_size,
        "accepted_images": accepted,
    }


def demo(output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    height, width = 360, 640
    ideal = np.full((height, width, 3), 245, np.uint8)
    for x in range(0, width, 40):
        cv2.line(ideal, (x, 0), (x, height - 1), (40, 40, 40), 1)
    for y in range(0, height, 40):
        cv2.line(ideal, (0, y), (width - 1, y), (40, 40, 40), 1)
    cv2.putText(ideal, "FPGA 50K", (195, 185), cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 0, 230), 2)
    matrix = np.array([[460., 0., 319.5], [0., 460., 179.5], [0., 0., 1.]])
    coefficients = np.array([-0.23, 0.055, 0.001, -0.001, 0.0])
    yy, xx = np.indices((height, width), np.float32)
    distorted_points = np.stack((xx, yy), axis=-1).reshape(-1, 1, 2)
    source = cv2.undistortPoints(distorted_points, matrix, coefficients, P=matrix).reshape(height, width, 2)
    distorted = cv2.remap(ideal, source[..., 0], source[..., 1], cv2.INTER_LINEAR)
    cv2.imwrite(str(output_dir / "01_ideal_grid.png"), ideal)
    cv2.imwrite(str(output_dir / "02_simulated_camera.png"), distorted)
    cv2.imwrite(str(output_dir / "03_corrected.png"), correct_image(distorted, matrix, coefficients))
    cv2.imwrite(str(output_dir / "04_corrected_rotated_17deg.png"), correct_image(distorted, matrix, coefficients, 17.0))
    affine = np.array([[1.0, 0.20, -36.0], [-0.05, 1.0, 17.0]])
    cv2.imwrite(str(output_dir / "05_corrected_affine.png"), correct_image(
        distorted, matrix, coefficients, affine_matrix=affine
    ))
    (output_dir / "affine_demo.json").write_text(json.dumps({
        "affine_matrix": affine.tolist(), "note": "Forward transform from undistorted to output pixels",
    }, indent=2), encoding="utf-8")
    (output_dir / "calibration_demo.json").write_text(json.dumps({
        "camera_matrix": matrix.tolist(), "distortion": coefficients.tolist(),
        "image_size": [width, height], "note": "Synthetic values; do not use for a real camera",
    }, indent=2), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    c = commands.add_parser("calibrate", help="fit camera parameters from chessboard photos")
    c.add_argument("--images", required=True, help="glob such as photos/*.png")
    c.add_argument("--columns", type=int, required=True, help="inner corners per row")
    c.add_argument("--rows", type=int, required=True, help="inner corners per column")
    c.add_argument("--square-size", type=float, required=True, help="e.g. millimetres")
    c.add_argument("--output", type=Path, required=True)
    r = commands.add_parser("correct", help="undistort and optionally rotate one image")
    r.add_argument("--image", type=Path, required=True)
    r.add_argument("--calibration", type=Path, required=True)
    r.add_argument("--angle", type=float, default=0.0)
    r.add_argument("--affine", type=Path, help="JSON file containing a forward 2x3 affine_matrix")
    r.add_argument("--output", type=Path, required=True)
    d = commands.add_parser("demo", help="generate and correct a synthetic grid")
    d.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "calibrate":
        result = calibrate([Path(p) for p in sorted(glob.glob(args.images))], args.columns, args.rows, args.square_size)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"accepted={len(result['accepted_images'])} rms_px={result['rms_reprojection_error_px']:.4f}")
    elif args.command == "correct":
        image = cv2.imread(str(args.image), cv2.IMREAD_UNCHANGED)
        if image is None:
            raise ValueError(f"cannot read {args.image}")
        matrix, coefficients = load_calibration(args.calibration)
        record = json.loads(args.calibration.read_text(encoding="utf-8"))
        if "image_size" in record and list(image.shape[1::-1]) != record["image_size"]:
            raise ValueError("image size differs from calibration; re-calibrate or use matching resolution")
        affine = None
        if args.affine is not None:
            affine = np.asarray(json.loads(args.affine.read_text(encoding="utf-8"))["affine_matrix"])
        args.output.parent.mkdir(parents=True, exist_ok=True)
        if not cv2.imwrite(str(args.output), correct_image(image, matrix, coefficients, args.angle, affine)):
            raise OSError(f"cannot write {args.output}")
        print(args.output)
    else:
        demo(args.output_dir)
        print(args.output_dir)


if __name__ == "__main__":
    main()
