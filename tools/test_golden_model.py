"""Offline numerical checks for the PC correction reference."""

import unittest

import cv2
import numpy as np

from golden_model import build_remap, correct_image


class GoldenModelTests(unittest.TestCase):
    def setUp(self):
        self.width, self.height = 96, 72
        self.k = np.array([[75., 0., 47.5], [0., 76., 35.5], [0., 0., 1.]])

    def test_identity_preserves_image(self):
        image = np.arange(self.width * self.height, dtype=np.uint8).reshape(self.height, self.width)
        actual = correct_image(image, self.k, np.zeros(5))
        np.testing.assert_array_equal(actual, image)

    def test_zero_angle_map_matches_opencv_undistort_map(self):
        distortion = np.array([-0.21, 0.04, 0.002, -0.001, 0.008])
        x, y = build_remap(self.width, self.height, self.k, distortion)
        ref_x, ref_y = cv2.initUndistortRectifyMap(
            self.k, distortion, None, self.k, (self.width, self.height), cv2.CV_32FC1
        )
        self.assertLess(float(np.max(np.abs(x - ref_x))), 0.0001)
        self.assertLess(float(np.max(np.abs(y - ref_y))), 0.0001)

    def test_rotation_maps_output_back_to_unrotated_source(self):
        x, y = build_remap(self.width, self.height, self.k, np.zeros(4), 90)
        inverse = cv2.invertAffineTransform(
            cv2.getRotationMatrix2D(((self.width - 1) / 2, (self.height - 1) / 2), 90, 1)
        )
        for row, col in [(35, 47), (10, 20), (50, 70)]:
            source = inverse @ np.array([col, row, 1])
            self.assertAlmostEqual(float(x[row, col]), source[0], places=4)
            self.assertAlmostEqual(float(y[row, col]), source[1], places=4)

    def test_shear_translate_scale_uses_inverse_affine(self):
        forward = np.array([[1.1, 0.2, -5.0], [-0.1, 0.9, 3.0]])
        x, y = build_remap(self.width, self.height, self.k, np.zeros(4), affine_matrix=forward)
        inverse = cv2.invertAffineTransform(forward)
        for row, col in [(35, 47), (10, 20), (50, 70)]:
            source = inverse @ np.array([col, row, 1])
            self.assertAlmostEqual(float(x[row, col]), source[0], places=4)
            self.assertAlmostEqual(float(y[row, col]), source[1], places=4)


if __name__ == "__main__":
    unittest.main()
