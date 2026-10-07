"""Numerical checks against OpenCV's independently implemented fisheye maps."""

import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

import cv2
import numpy as np

from fisheye_model import (
    build_fisheye_remap, correct_fisheye, load_calibration,
    output_camera_matrix, valid_source_mask,
)


class FisheyeModelTests(unittest.TestCase):
    def setUp(self):
        self.width, self.height = 96, 72
        self.k = np.array([[65.0, 0.0, 47.5], [0.0, 66.0, 35.5], [0.0, 0.0, 1.0]])
        self.d = np.array([-0.12, 0.016, -0.002, 0.0001])

    def test_inverse_map_matches_opencv_for_two_balances(self):
        for balance in (0.0, 0.65):
            with self.subTest(balance=balance):
                p = output_camera_matrix(self.width, self.height, self.k, self.d, balance)
                actual_x, actual_y = build_fisheye_remap(
                    self.width, self.height, self.k, self.d, p,
                )
                ref_x, ref_y = cv2.fisheye.initUndistortRectifyMap(
                    self.k, self.d.reshape(4, 1), np.eye(3), p,
                    (self.width, self.height), cv2.CV_32FC1,
                )
                self.assertLess(float(np.max(np.abs(actual_x - ref_x))), 2e-5)
                self.assertLess(float(np.max(np.abs(actual_y - ref_y))), 2e-5)

    def test_angle_and_affine_map_via_independent_project_points(self):
        p = output_camera_matrix(self.width, self.height, self.k, self.d)
        for transform in (
            cv2.getRotationMatrix2D(((self.width - 1) / 2, (self.height - 1) / 2), 17, 1),
            np.array([[1.02, 0.12, -5], [-0.05, 0.98, 4]], dtype=np.float64),
        ):
            with self.subTest(transform=transform.tolist()):
                mx, my = build_fisheye_remap(
                    self.width, self.height, self.k, self.d, p, affine_matrix=transform,
                )
                inverse = cv2.invertAffineTransform(transform)
                for row, col in ((10, 20), (35, 47), (55, 75)):
                    u, v = inverse @ np.array([col, row, 1.0])
                    ray = np.array([[[ (u - p[0, 2]) / p[0, 0],
                                      (v - p[1, 2]) / p[1, 1], 1.0 ]]], dtype=np.float64)
                    expected, _ = cv2.fisheye.projectPoints(
                        ray, np.zeros(3), np.zeros(3), self.k, self.d.reshape(4, 1),
                    )
                    self.assertAlmostEqual(float(mx[row, col]), float(expected[0, 0, 0]), places=4)
                    self.assertAlmostEqual(float(my[row, col]), float(expected[0, 0, 1]), places=4)

    def test_correction_matches_reference_remap_and_bounds_mask(self):
        yy, xx = np.indices((self.height, self.width))
        image = np.stack((xx, yy, (xx + yy) % 256), axis=2).astype(np.uint8)
        corrected, mask, p = correct_fisheye(image, self.k, self.d, balance=0.5)
        ref_x, ref_y = cv2.fisheye.initUndistortRectifyMap(
            self.k, self.d.reshape(4, 1), np.eye(3), p,
            (self.width, self.height), cv2.CV_32FC1,
        )
        expected = cv2.remap(image, ref_x, ref_y, cv2.INTER_LINEAR,
                             borderMode=cv2.BORDER_CONSTANT)
        np.testing.assert_array_equal(corrected, expected)
        np.testing.assert_array_equal(mask, valid_source_mask(ref_x, ref_y, self.width, self.height))

    def test_rejects_brown_parameters_and_unsafe_inputs(self):
        with self.assertRaises(ValueError):
            output_camera_matrix(self.width, self.height, self.k, self.d, 1.2)
        with self.assertRaises(ValueError):
            build_fisheye_remap(self.width, self.height, self.k, np.zeros(5), self.k)
        with self.assertRaises(ValueError):
            build_fisheye_remap(self.width, self.height, self.k, self.d, self.k,
                                affine_matrix=np.zeros((2, 3)))
        with self.assertRaises(ValueError):
            build_fisheye_remap(self.width, self.height, self.k, self.d, self.k,
                                angle_degrees=10, affine_matrix=np.eye(2, 3))
        with TemporaryDirectory() as directory:
            path = Path(directory) / "brown.json"
            path.write_text(json.dumps({
                "camera_matrix": self.k.tolist(), "distortion": [0, 0, 0, 0],
                "image_size": [self.width, self.height],
            }), encoding="utf-8")
            with self.assertRaises(ValueError):
                load_calibration(path)


if __name__ == "__main__":
    unittest.main()
