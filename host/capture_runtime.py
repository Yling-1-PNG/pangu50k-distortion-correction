"""Threaded video capture and measurement helpers for the desktop preview."""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
import threading
import time
from typing import Any, Callable

import cv2
import numpy as np


def rolling_rate(timestamps: deque[float] | list[float]) -> float | None:
    """Return events per second over a timestamp window."""
    if len(timestamps) < 2:
        return None
    elapsed = float(timestamps[-1] - timestamps[0])
    if elapsed <= 0.0:
        return None
    return float((len(timestamps) - 1) / elapsed)


def fourcc_text(value: float | int) -> str:
    """Decode OpenCV's numeric FOURCC value, or return ``unknown``."""
    number = int(value or 0)
    if number <= 0:
        return "unknown"
    text = "".join(chr((number >> (8 * index)) & 0xFF) for index in range(4))
    return text if all(32 <= ord(char) <= 126 for char in text) else f"0x{number:08X}"


def configure_capture(capture: Any, *, device: int, width: int, height: int,
                      requested_fps: float = 30.0,
                      requested_fourcc: str = "YUY2") -> dict[str, Any]:
    """Request a video mode and report what OpenCV actually negotiated."""
    if device < 0 or width <= 0 or height <= 0 or requested_fps <= 0:
        raise ValueError("device, resolution and requested FPS must be positive")
    if len(requested_fourcc) != 4:
        raise ValueError("requested FOURCC must contain exactly four characters")

    capture.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*requested_fourcc))
    capture.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    capture.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    capture.set(cv2.CAP_PROP_FPS, requested_fps)

    actual_width = int(round(float(capture.get(cv2.CAP_PROP_FRAME_WIDTH) or 0.0)))
    actual_height = int(round(float(capture.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0.0)))
    reported_fps_value = float(capture.get(cv2.CAP_PROP_FPS) or 0.0)
    reported_fps = reported_fps_value if reported_fps_value > 0.0 else None
    actual_fourcc = fourcc_text(capture.get(cv2.CAP_PROP_FOURCC))
    try:
        backend = str(capture.getBackendName())
    except (AttributeError, cv2.error):
        backend = "unknown"

    return {
        "device": device,
        "backend": backend,
        "requested_resolution": [width, height],
        "actual_resolution": [actual_width, actual_height],
        "requested_fps": float(requested_fps),
        "reported_fps": reported_fps,
        "requested_fourcc": requested_fourcc,
        "actual_fourcc": actual_fourcc,
        "resolution_fallback": [actual_width, actual_height] != [width, height],
        "fourcc_fallback": actual_fourcc not in {requested_fourcc, "unknown"},
    }


def _rate_text(value: float | None) -> str:
    return "--.-" if value is None else f"{value:.1f}"


def format_metric_line(*, width: int, height: int,
                       expected_fps: float | None,
                       arrival_fps: float | None,
                       content_fps: float | None,
                       ui_fps: float | None,
                       pc_processing_fps: float | None) -> str:
    """Format distinct rate domains without implying an FPGA counter."""
    mode = (f"工程模式 {width}×{height}@{expected_fps:.0f}"
            if expected_fps is not None else f"工程模式 {width}×{height}@未配置")
    return (
        f"{mode} | 采集卡到达 {_rate_text(arrival_fps)} FPS | "
        f"内容更新估计 {_rate_text(content_fps)} FPS | "
        f"UI显示 {_rate_text(ui_fps)} FPS | "
        f"PC黄金模型 {_rate_text(pc_processing_fps)} FPS"
    )


@dataclass(frozen=True)
class FramePacket:
    """One captured frame plus metrics measured before any UI work."""

    index: int
    frame: np.ndarray
    completed_at: float
    read_duration_ms: float
    arrival_fps: float | None
    average_arrival_fps: float | None
    content_changed: bool
    content_update_fps: float | None


class CaptureMetrics:
    """Pure capture-side accounting, independent of display cadence."""

    def __init__(self, *, window_size: int = 60,
                 content_threshold: float = 1.5) -> None:
        if window_size < 2 or content_threshold < 0.0:
            raise ValueError("invalid capture metric configuration")
        self._arrival_timestamps: deque[float] = deque(maxlen=window_size)
        self._content_events: deque[tuple[float, bool]] = deque(maxlen=window_size)
        self._first_timestamp: float | None = None
        self._previous_signature: np.ndarray | None = None
        self._content_threshold = float(content_threshold)

    @staticmethod
    def _signature(frame: np.ndarray) -> np.ndarray:
        if frame is None or frame.ndim not in (2, 3) or frame.size == 0:
            raise ValueError("captured frame must be a non-empty image")
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if frame.ndim == 3 else frame
        reduced = cv2.resize(gray, (64, 36), interpolation=cv2.INTER_AREA)
        return cv2.GaussianBlur(reduced, (3, 3), 0)

    def record(self, frame: np.ndarray, index: int, completed_at: float,
               read_duration: float) -> FramePacket:
        if index < 0 or read_duration < 0.0:
            raise ValueError("frame index and read duration must be nonnegative")
        if self._arrival_timestamps and completed_at <= self._arrival_timestamps[-1]:
            raise ValueError("capture timestamps must increase")

        signature = self._signature(frame)
        if self._previous_signature is None:
            changed = True
        else:
            difference = cv2.absdiff(signature, self._previous_signature)
            changed = float(np.mean(difference)) >= self._content_threshold
        self._previous_signature = signature

        self._arrival_timestamps.append(float(completed_at))
        self._content_events.append((float(completed_at), changed))
        if self._first_timestamp is None:
            self._first_timestamp = float(completed_at)

        arrival_fps = rolling_rate(self._arrival_timestamps)
        average_fps = None
        if index > 0 and completed_at > self._first_timestamp:
            average_fps = float(index / (completed_at - self._first_timestamp))

        content_fps = None
        if len(self._content_events) >= 2:
            elapsed = self._content_events[-1][0] - self._content_events[0][0]
            if elapsed > 0.0:
                changed_intervals = sum(
                    1 for _, event_changed in list(self._content_events)[1:]
                    if event_changed
                )
                content_fps = float(changed_intervals / elapsed)

        return FramePacket(
            index=index,
            frame=frame,
            completed_at=float(completed_at),
            read_duration_ms=float(read_duration * 1000.0),
            arrival_fps=arrival_fps,
            average_arrival_fps=average_fps,
            content_changed=changed,
            content_update_fps=content_fps,
        )


class CaptureWorker:
    """Continuously read the source while exposing only the newest frame."""

    def __init__(self, capture: Any, *, window_size: int = 60,
                 content_threshold: float = 1.5,
                 clock: Callable[[], float] = time.perf_counter) -> None:
        self._capture = capture
        self._clock = clock
        self._metrics = CaptureMetrics(
            window_size=window_size, content_threshold=content_threshold,
        )
        self._stop_event = threading.Event()
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._latest: FramePacket | None = None
        self._error: str | None = None

    @property
    def error(self) -> str | None:
        with self._lock:
            return self._error

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            raise RuntimeError("capture worker is already running")
        self._stop_event.clear()
        self._thread = threading.Thread(
            target=self._run, name="hdmi-capture", daemon=True,
        )
        self._thread.start()

    def _run(self) -> None:
        index = 0
        while not self._stop_event.is_set():
            started = self._clock()
            ok, frame = self._capture.read()
            completed = self._clock()
            if self._stop_event.is_set():
                break
            if not ok or frame is None:
                with self._lock:
                    self._error = "video source read failed or disconnected"
                break
            try:
                packet = self._metrics.record(
                    frame, index, completed, max(0.0, completed - started),
                )
            except (TypeError, ValueError, cv2.error) as exc:
                with self._lock:
                    self._error = f"capture metric failure: {exc}"
                break
            with self._lock:
                self._latest = packet
            index += 1

    def latest_packet(self, after_index: int | None = None) -> FramePacket | None:
        with self._lock:
            packet = self._latest
        if packet is None or (after_index is not None and packet.index <= after_index):
            return None
        return packet

    def is_alive(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def join(self, timeout: float | None = None) -> None:
        if self._thread is not None:
            self._thread.join(timeout=timeout)

    def stop(self, timeout: float = 1.0) -> None:
        self._stop_event.set()
        self._capture.release()
        self.join(timeout=timeout)
