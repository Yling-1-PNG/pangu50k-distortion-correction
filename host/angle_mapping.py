"""Map a measured mechanical angle to a candidate FPGA compensation angle.

This module deliberately contains no serial, camera, or FPGA code.  It is the
shared math layer for a manual protractor/rotary stage and the legacy 26ticar
YAW source.  The compensation sign is a calibration parameter, not a claim
about the final PGL50H wiring or optical-axis convention.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
from numbers import Real


def _finite_number(value: Real, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, Real):
        raise TypeError(f"{name} must be a real number")
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f"{name} must be finite")
    return result


def wrap_degrees(angle_deg: Real) -> float:
    """Return a finite angle in the canonical half-open range [-180, 180)."""
    angle = _finite_number(angle_deg, "angle_deg")
    return (angle + 180.0) % 360.0 - 180.0


@dataclass(frozen=True)
class AngleMapping:
    """Convert physical readings into a candidate reverse compensation.

    ``zero_deg`` is the measured reading at the optical/mechanical zero.
    ``compensation_sign`` is normally ``-1`` for reverse compensation, but it
    remains configurable because the final sign must be checked on hardware.
    """

    zero_deg: float = 0.0
    compensation_sign: int = -1

    def __post_init__(self) -> None:
        zero = _finite_number(self.zero_deg, "zero_deg")
        if self.compensation_sign not in (-1, 1):
            raise ValueError("compensation_sign must be either -1 or 1")
        object.__setattr__(self, "zero_deg", zero)

    def relative_angle(self, measured_deg: Real) -> float:
        """Remove the mechanical zero offset from one measured reading."""
        measured = _finite_number(measured_deg, "measured_deg")
        return wrap_degrees(measured - self.zero_deg)

    def compensation_angle(self, measured_deg: Real) -> float:
        """Return the candidate angle to send to the correction pipeline."""
        return wrap_degrees(self.compensation_sign * self.relative_angle(measured_deg))

    def record(self, measured_deg: Real, *, source: str = "manual-protractor",
               requested_deg: Real | None = None, note: str = "") -> dict[str, object]:
        """Create a deterministic, JSON-ready angle record for a test session."""
        if not source:
            raise ValueError("source must not be empty")
        measured = _finite_number(measured_deg, "measured_deg")
        requested = None if requested_deg is None else _finite_number(requested_deg, "requested_deg")
        return {
            "source": source,
            "requested_deg": requested,
            "measured_deg": measured,
            "zero_deg": self.zero_deg,
            "relative_deg": self.relative_angle(measured),
            "compensation_deg": self.compensation_angle(measured),
            "note": note,
        }
