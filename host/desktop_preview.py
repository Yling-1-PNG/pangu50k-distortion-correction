"""PGL50H desktop monitor and PC golden-model preview.

The HDMI input is an FPGA output, so the default live mode only displays it;
it must not be passed through the PC distortion model a second time. The PC
golden model is reserved for an offline, uncorrected camera frame. A static
comparison can show an FPGA output file beside a golden result generated from
its matching uncorrected input.
"""

from __future__ import annotations

import argparse
import base64
from collections import deque
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
import time
from typing import Any

import cv2
import numpy as np

from host.golden_preview import correct_frame, load_record
from host.capture_runtime import (
    CaptureWorker,
    configure_capture,
    format_metric_line,
)
from host.session_log import append_jsonl, build_session_record


VIEW_MODES = ("并排", "原始", "矫正")
FPGA_VIEW_MODE = "FPGA输出"
FPGA_REFERENCE_VIEW_MODE = "FPGA对照"
PIPELINE_MODES = ("PC黄金模型", "FPGA监视", "对比")
PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CALIBRATION_PATH = (
    PROJECT_ROOT / "profiles" / "fisheye.json"
)
DEFAULT_OUTPUT_FOCAL_PX = 350.0
PIPELINE_MODE_LABELS = {
    "PC黄金模型": "原始画面",
    "FPGA监视": "FPGA矫正实时",
    "对比": "文件对比",
}
PIPELINE_MODE_HINTS = {
    "FPGA监视": "显示 FPGA 当前 HDMI 输出；不执行 PC 二次矫正",
    "PC黄金模型": "显示原始 HDMI 视频流；点击“PC处理当前帧”后再手动保存",
    "对比": "离线文件对比：FPGA 输出 vs PC 黄金模型结果",
}


def visible_panels(mode: str) -> tuple[str, ...]:
    """Return the image panels that should be visible for one UI mode."""
    if mode == FPGA_VIEW_MODE:
        return ("input",)
    if mode == FPGA_REFERENCE_VIEW_MODE:
        return ("input", "corrected")
    if mode == "并排":
        return ("input", "corrected")
    if mode == "原始":
        return ("input",)
    if mode == "矫正":
        return ("corrected",)
    raise ValueError(f"unsupported view mode: {mode}")


def rolling_frame_rate(timestamps: list[float] | tuple[float, ...],
                       *, minimum_samples: int = 2) -> float | None:
    """Return the measured arrival rate over the supplied recent timestamps."""
    if len(timestamps) < minimum_samples:
        return None
    elapsed = float(timestamps[-1] - timestamps[0])
    if elapsed <= 0.0:
        return None
    return float((len(timestamps) - 1) / elapsed)


def rotate_for_display(image: np.ndarray, rotate_180: bool) -> np.ndarray:
    """Return a display copy while keeping the captured image unchanged."""
    if image is None or image.ndim not in (2, 3):
        raise ValueError("image must be a grayscale or color array")
    return cv2.rotate(image, cv2.ROTATE_180) if rotate_180 else image.copy()


def prepare_display_image(image: np.ndarray, rotate_180: bool = False) -> np.ndarray:
    """Prepare an OpenCV BGR image for ``cv2.imencode`` and Tk PNG display.

    ``cv2.imencode`` consumes OpenCV's BGR convention and writes the PNG
    channel order expected by Tk. Converting to RGB before encoding would
    swap red and blue a second time.
    """
    return rotate_for_display(image, rotate_180)


def live_frame_reference(device: int, frame_index: int) -> str:
    """Return a stable human-readable reference for a live HDMI frame."""
    if device < 0 or frame_index < 0:
        raise ValueError("device and frame_index must be nonnegative")
    return f"hdmi://device-{device}/frame-{frame_index:06d}"


def live_frame_metrics(frame: np.ndarray,
                       previous: np.ndarray | None = None) -> dict[str, float | None]:
    """Return simple visible black/freeze indicators for a live frame."""
    if frame is None or frame.ndim not in (2, 3) or frame.size == 0:
        raise ValueError("frame must be a non-empty grayscale or color array")
    if frame.ndim == 3:
        black_fraction = float(np.mean(np.max(frame, axis=2) <= 8))
    else:
        black_fraction = float(np.mean(frame <= 8))
    difference = None
    if previous is not None:
        if previous.shape != frame.shape:
            raise ValueError("previous frame shape differs")
        difference = float(
            np.abs(frame.astype(np.int16) - previous.astype(np.int16)).mean()
        )
    return {
        "black_fraction": black_fraction,
        "mean_absolute_difference": difference,
    }


def live_quality_gate(metrics: dict[str, float | None], *,
                      black_threshold: float = 0.98,
                      freeze_threshold: float = 0.2) -> dict[str, Any]:
    """Classify one live frame without confusing diagnostics with acceptance."""
    warnings: list[str] = []
    black_fraction = metrics.get("black_fraction")
    difference = metrics.get("mean_absolute_difference")
    if black_fraction is not None and black_fraction > black_threshold:
        warnings.append("疑似黑帧")
    if difference is not None and difference < freeze_threshold:
        warnings.append("疑似冻结")
    return {
        "status": "FAIL" if warnings else "PASS",
        "warnings": warnings,
        "black_threshold": black_threshold,
        "freeze_threshold": freeze_threshold,
    }


def paired_output_paths(corrected_path: Path) -> tuple[Path, Path]:
    """Return ``(raw_path, corrected_path)`` for one saved frame pair."""
    if corrected_path.suffix.lower() not in {".png", ".jpg", ".jpeg", ".bmp"}:
        raise ValueError("output path must have an image suffix")
    raw_path = corrected_path.with_name(
        f"{corrected_path.stem}_raw{corrected_path.suffix}"
    )
    return raw_path, corrected_path


def build_capture_metadata(*, source: str, resolution: tuple[int, int],
                           fps: float | None, frame_index: int | None = None,
                           captured_utc: str | None = None,
                           device: int | None = None,
                           black_fraction: float | None = None,
                           mean_absolute_difference: float | None = None,
                           processing_fps: float | None = None,
                           pipeline_mode: str | None = None,
                           rotate_180: bool = False,
                           correction_applied: bool = False,
                           display_color_conversion: str = "BGR preserved for cv2.imencode PNG",
                           ) -> dict[str, Any]:
    """Build the capture evidence saved beside every raw/corrected pair."""
    if source not in {"file", "hdmi"}:
        raise ValueError("source must be file or hdmi")
    width, height = resolution
    if width <= 0 or height <= 0:
        raise ValueError("resolution must be positive")
    if fps is not None and (not np.isfinite(fps) or fps < 0):
        raise ValueError("fps must be finite and nonnegative")
    if (processing_fps is not None
            and (not np.isfinite(processing_fps) or processing_fps < 0)):
        raise ValueError("processing_fps must be finite and nonnegative")
    if frame_index is not None and frame_index < 0:
        raise ValueError("frame_index must be nonnegative")
    return {
        "source": source,
        "device": device,
        "frame_index": frame_index,
        "resolution": [width, height],
        "fps": fps,
        "processing_fps": processing_fps,
        "black_fraction": black_fraction,
        "mean_absolute_difference": mean_absolute_difference,
        "captured_utc": captured_utc,
        "pipeline_mode": pipeline_mode,
        "rotate_180_display": rotate_180,
        "correction_applied": correction_applied,
        "display_color_conversion": display_color_conversion,
    }


def _parse_float(value: str, name: str) -> float:
    try:
        result = float(value)
    except ValueError as exc:
        raise ValueError(f"{name} must be a number") from exc
    if not np.isfinite(result):
        raise ValueError(f"{name} must be finite")
    return result


def fit_size(width: int, height: int, max_width: int = 620,
             max_height: int = 420) -> tuple[int, int]:
    """Return a display size without enlarging a source image."""
    if width <= 0 or height <= 0:
        raise ValueError("image dimensions must be positive")
    scale = min(max_width / width, max_height / height, 1.0)
    return max(1, round(width * scale)), max(1, round(height * scale))


def encode_preview_png(image: np.ndarray, *, max_width: int = 620,
                       max_height: int = 420) -> str:
    """Encode an OpenCV image as base64 PNG data accepted by Tk PhotoImage."""
    if image is None or image.ndim not in (2, 3):
        raise ValueError("image must be a grayscale or color array")
    height, width = image.shape[:2]
    display_width, display_height = fit_size(
        width, height, max_width=max_width, max_height=max_height,
    )
    display = image
    if (display_width, display_height) != (width, height):
        display = cv2.resize(display, (display_width, display_height),
                             interpolation=cv2.INTER_AREA)
    display = prepare_display_image(display, False)
    ok, encoded = cv2.imencode(".png", display)
    if not ok:
        raise ValueError("failed to encode preview image")
    return base64.b64encode(encoded.tobytes()).decode("ascii")


def encode_live_ppm(image: np.ndarray, *, rotate_180: bool,
                    max_width: int, max_height: int) -> bytes:
    """Return an uncompressed RGB PPM frame for Tk's low-latency live path."""
    display = rotate_for_display(image, rotate_180)
    width, height = fit_size(
        display.shape[1], display.shape[0], max_width, max_height,
    )
    if (width, height) != (display.shape[1], display.shape[0]):
        display = cv2.resize(display, (width, height), interpolation=cv2.INTER_AREA)
    rgb = (cv2.cvtColor(display, cv2.COLOR_GRAY2RGB)
           if display.ndim == 2 else cv2.cvtColor(display, cv2.COLOR_BGR2RGB))
    return f"P6\n{width} {height}\n255\n".encode("ascii") + rgb.tobytes()


def capture_backend_id(name: str) -> int:
    """Translate a user-facing capture backend name to an OpenCV backend."""
    backends = {
        "auto": cv2.CAP_ANY,
        "dshow": cv2.CAP_DSHOW,
        "msmf": cv2.CAP_MSMF,
    }
    try:
        return backends[name.lower()]
    except KeyError as exc:
        raise ValueError(f"unsupported capture backend: {name}") from exc


class PreviewApp:
    """Tk front end around the already-tested golden preview functions."""

    def __init__(self, root: tk.Tk, *, image_path: Path | None = None,
                 calibration_path: Path | None = None,
                 measured_angle: float | None = None,
                 zero_deg: float = 0.0, compensation_sign: int = -1,
                 balance: float = 0.0, output_focal_px: float | None = None,
                 note: str = "manual stage offline preview",
                 session_log: Path | None = None,
                 capture_device: int | None = None,
                 capture_width: int = 1280, capture_height: int = 720,
                  capture_requested_fps: float = 30.0,
                  capture_fourcc: str = "YUY2",
                 capture_backend: str = "msmf" if os.name == "nt" else "auto",
                 pipeline_mode: str = "PC黄金模型",
                 rotate_180: bool = True,
                 fpga_output_path: Path | None = None,
                 expected_signal_fps: float | None = 30.0) -> None:
        if pipeline_mode not in PIPELINE_MODES:
            raise ValueError(f"unsupported pipeline mode: {pipeline_mode}")
        if capture_requested_fps <= 0.0 or len(capture_fourcc) != 4:
            raise ValueError("invalid capture FPS or FOURCC")
        capture_backend_id(capture_backend)
        self.root = root
        self.root.title("PGL50H FPGA Monitor / PC Golden Preview")
        self.root.geometry("1440x900")
        self.root.minsize(1120, 720)
        self.image_path = image_path
        self.calibration_path = calibration_path
        self.session_log = session_log
        self.input_image: np.ndarray | None = None
        self.corrected_image: np.ndarray | None = None
        self.preview_summary: dict[str, Any] | None = None
        self.last_pc_raw_image: np.ndarray | None = None
        self.last_pc_corrected_image: np.ndarray | None = None
        self.last_pc_summary: dict[str, Any] | None = None
        self.last_pc_raw_path: Path | None = None
        self.last_pc_corrected_path: Path | None = None
        self._logo_photo: tk.PhotoImage | None = None
        self._input_photo: tk.PhotoImage | None = None
        self._corrected_photo: tk.PhotoImage | None = None
        self.images_frame: ttk.Frame | None = None
        self.view_combo: ttk.Combobox | None = None
        self._resize_after_id: str | None = None
        self._rendered_view_signature: tuple[Any, ...] | None = None
        self.pipeline_mode_var = tk.StringVar(value=pipeline_mode)
        self.mode_badge_var = tk.StringVar(value=pipeline_mode)
        self.mode_hint_var = tk.StringVar(value=PIPELINE_MODE_HINTS[pipeline_mode])
        self.canvas_hint_var = tk.StringVar(value="FPGA 输出监视 / PC 黄金模型 / 静态对比")
        self.mode_buttons: dict[str, tk.Button] = {}
        self.rotate_180_var = tk.BooleanVar(value=rotate_180)
        self.view_mode_var = tk.StringVar(
            value=FPGA_VIEW_MODE if pipeline_mode == "FPGA监视" else "并排",
        )
        self.capture_device_var = tk.StringVar(
            value="" if capture_device is None else str(capture_device),
        )
        self.capture_width_var = tk.StringVar(value=str(capture_width))
        self.capture_height_var = tk.StringVar(value=str(capture_height))
        self.capture_requested_fps = float(capture_requested_fps)
        self.capture_fourcc = capture_fourcc.upper()
        self.capture_backend = capture_backend.lower()
        self.capture: cv2.VideoCapture | None = None
        self.capture_worker: CaptureWorker | None = None
        self.capture_after_id: str | None = None
        self.capture_device: int | None = None
        self.capture_frame_index = 0
        self.capture_previous_frame: np.ndarray | None = None
        self.live_metrics: dict[str, float | None] = {
            "black_fraction": 0.0,
            "mean_absolute_difference": None,
        }
        self.quality_sample_interval = 6
        self.capture_reported_fps: float | None = None
        self.capture_arrival_fps: float | None = None
        self.capture_content_fps: float | None = None
        self.capture_info: dict[str, Any] | None = None
        self.ui_render_timestamps: deque[float] = deque(maxlen=60)
        self.ui_render_fps: float | None = None
        self.pc_processing_fps: float | None = None
        self.last_displayed_capture_index = -1
        self.expected_signal_fps = expected_signal_fps
        self.capture_metric_var = tk.StringVar(value="")
        self.capture_device_info_var = tk.StringVar(value="采集协商：尚未打开设备")
        self.current_input_reference = str(image_path or "")

        self.image_var = tk.StringVar(value=str(image_path or ""))
        self.fpga_output_var = tk.StringVar(value=str(fpga_output_path or ""))
        self.calibration_var = tk.StringVar(
            value=str(calibration_path or DEFAULT_CALIBRATION_PATH),
        )
        self.angle_var = tk.StringVar(
            value="" if measured_angle is None else str(measured_angle),
        )
        self.zero_var = tk.StringVar(value=str(zero_deg))
        self.sign_var = tk.StringVar(value=str(compensation_sign))
        self.balance_var = tk.StringVar(value=str(balance))
        self.focal_var = tk.StringVar(
            value=str(DEFAULT_OUTPUT_FOCAL_PX if output_focal_px is None else output_focal_px),
        )
        self.note_var = tk.StringVar(value=note)
        self.status_var = tk.StringVar(
            value=("FPGA HDMI 输出监视：尚未连接采集器"
                   if pipeline_mode == "FPGA监视"
                   else "PC 离线模式：未连接 HDMI、串口、JTAG 或 FPGA"),
        )
        self._configure_theme()
        self._build_widgets()
        self._refresh_metric_line()
        self._on_pipeline_mode_changed()
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        if capture_device is not None:
            self.root.after(0, self.start_capture)
        elif image_path is not None and calibration_path is not None:
            self.root.after(0, self.preview)

    def _configure_theme(self) -> None:
        """Apply a dependency-free dark workbench style inspired by VS Code."""
        self.colors = {
            "bg": "#1e1e1e",
            "panel": "#252526",
            "panel_alt": "#2d2d30",
            "input": "#3c3c3c",
            "border": "#454545",
            "text": "#d4d4d4",
            "muted": "#9d9d9d",
            "accent": "#a855f7",
            "accent_hover": "#c084fc",
            "ok": "#4ec9b0",
        }
        self.root.configure(bg=self.colors["bg"])
        self.root.option_add("*Font", ("Microsoft YaHei UI", 12))
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure(".", font=("Microsoft YaHei UI", 12))
        style.configure("TFrame", background=self.colors["bg"])
        style.configure("Header.TFrame", background="#181818")
        style.configure("Sidebar.TFrame", background=self.colors["panel"])
        style.configure("Surface.TFrame", background="#202020")
        style.configure("Canvas.TFrame", background="#181818")
        style.configure("Panel.TFrame", background=self.colors["panel"])
        style.configure("Card.TFrame", background=self.colors["panel_alt"])
        style.configure("TLabel", background=self.colors["bg"], foreground=self.colors["text"])
        style.configure("Muted.TLabel", background=self.colors["bg"], foreground=self.colors["muted"])
        style.configure("Title.TLabel", background=self.colors["bg"], foreground="#ffffff",
                        font=("Microsoft YaHei UI", 18, "bold"))
        style.configure("HeaderTitle.TLabel", background="#181818", foreground="#ffffff",
                        font=("Microsoft YaHei UI", 17, "bold"))
        style.configure("Kicker.TLabel", background="#181818", foreground=self.colors["accent_hover"],
                        font=("Microsoft YaHei UI", 11, "bold"))
        style.configure("PanelTitle.TLabel", background=self.colors["panel"], foreground="#ffffff",
                        font=("Microsoft YaHei UI", 12, "bold"))
        style.configure("PanelHint.TLabel", background=self.colors["panel"], foreground=self.colors["muted"],
                        font=("Microsoft YaHei UI", 11))
        style.configure("CanvasTitle.TLabel", background="#181818", foreground="#ffffff",
                        font=("Microsoft YaHei UI", 13, "bold"))
        style.configure("CanvasHint.TLabel", background="#181818", foreground=self.colors["muted"],
                        font=("Microsoft YaHei UI", 11))
        style.configure("Badge.TLabel", background="#3d2160", foreground="#e9d5ff",
                        padding=(10, 5), font=("Microsoft YaHei UI", 11, "bold"))
        style.configure("Metric.TLabel", background="#181818", foreground=self.colors["ok"],
                        font=("Consolas", 11))
        style.configure("Mode.TButton", background=self.colors["panel_alt"],
                        foreground=self.colors["text"], bordercolor=self.colors["border"],
                        padding=(8, 6), relief="flat", font=("Microsoft YaHei UI", 11, "bold"))
        style.map("Mode.TButton", background=[("selected", self.colors["accent"]),
                                                ("active", self.colors["border"])],
                  foreground=[("selected", "#ffffff")])
        style.configure("Subtitle.TLabel", background=self.colors["bg"], foreground=self.colors["muted"],
                        font=("Microsoft YaHei UI", 11))
        style.configure("Section.TLabel", background=self.colors["panel"], foreground=self.colors["accent_hover"],
                        font=("Microsoft YaHei UI", 12, "bold"))
        style.configure("TButton", background=self.colors["panel_alt"], foreground=self.colors["text"],
                        bordercolor=self.colors["border"], padding=(10, 6), relief="flat")
        style.map("TButton", background=[("active", self.colors["border"]), ("pressed", self.colors["accent"])])
        style.configure("Accent.TButton", background=self.colors["accent"], foreground="#ffffff",
                        bordercolor=self.colors["accent"], padding=(12, 7), relief="flat")
        style.map("Accent.TButton", background=[("active", self.colors["accent_hover"]),
                                                  ("pressed", self.colors["accent"])])
        style.configure("TEntry", fieldbackground=self.colors["input"], foreground=self.colors["text"],
                        insertcolor=self.colors["text"], bordercolor=self.colors["border"], padding=5)
        style.configure("TCombobox", fieldbackground=self.colors["input"], foreground=self.colors["text"],
                        selectbackground=self.colors["accent"], selectforeground="#ffffff", padding=4)
        style.map("TCombobox", fieldbackground=[("readonly", self.colors["input"])],
                  foreground=[("readonly", self.colors["text"])])
        style.configure("TCheckbutton", background=self.colors["panel"], foreground=self.colors["text"],
                        padding=(2, 3))
        style.map("TCheckbutton", background=[("active", self.colors["panel"])])
        style.configure("Status.TLabel", background="#181818", foreground=self.colors["ok"], padding=7)
        style.configure("TSeparator", background=self.colors["border"])

    def _build_widgets(self) -> None:
        shell = ttk.Frame(self.root, style="Surface.TFrame")
        shell.pack(fill=tk.BOTH, expand=True)

        brand = ttk.Frame(shell, padding=(18, 14, 18, 12), style="Header.TFrame")
        brand.pack(fill=tk.X)
        brand.columnconfigure(1, weight=1)
        logo_path = Path(__file__).with_name("assets") / "pangomicro_logo.png"
        if logo_path.is_file():
            self._logo_photo = tk.PhotoImage(file=str(logo_path)).subsample(2, 2)
            ttk.Label(brand, image=self._logo_photo).grid(
                row=0, column=0, rowspan=2, sticky="w", padx=(0, 12),
            )
        ttk.Label(brand, text="PGL50H 视觉矫正工作台",
                  style="HeaderTitle.TLabel").grid(row=0, column=1, sticky="w")
        ttk.Label(brand, text="紫光同创 FPGA 嵌入式赛道",
                  style="Kicker.TLabel").grid(row=1, column=1, sticky="w", pady=(3, 0))
        ttk.Label(brand, textvariable=self.mode_badge_var, style="Badge.TLabel").grid(
            row=0, column=2, rowspan=2, sticky="e", padx=(12, 0),
        )

        body = ttk.Frame(shell, style="Surface.TFrame")
        body.pack(fill=tk.BOTH, expand=True)
        body.columnconfigure(1, weight=1)
        body.rowconfigure(0, weight=1)

        sidebar = ttk.Frame(body, width=408, style="Sidebar.TFrame")
        sidebar.grid(row=0, column=0, sticky="nsew")
        sidebar.grid_propagate(False)
        sidebar.rowconfigure(0, weight=1)
        sidebar.columnconfigure(0, weight=1)
        sidebar_canvas = tk.Canvas(sidebar, width=1, height=1,
                                   bg=self.colors["panel"], highlightthickness=0,
                                   yscrollincrement=20)
        sidebar_canvas.grid(row=0, column=0, sticky="nsew")
        scrollbar = ttk.Scrollbar(sidebar, orient=tk.VERTICAL,
                                  command=sidebar_canvas.yview)
        scrollbar.grid(row=0, column=1, sticky="ns")
        sidebar_canvas.configure(yscrollcommand=scrollbar.set)
        controls = ttk.Frame(sidebar_canvas, padding=(16, 16, 14, 12),
                             style="Sidebar.TFrame")
        controls.columnconfigure(1, weight=1)
        controls_window = sidebar_canvas.create_window(0, 0, anchor="nw", window=controls)
        controls.bind("<Configure>", lambda _event: sidebar_canvas.configure(
            scrollregion=sidebar_canvas.bbox("all")))
        sidebar_canvas.bind("<Configure>", lambda event: sidebar_canvas.itemconfigure(
            controls_window, width=event.width))

        ttk.Label(controls, text="视频控制", style="PanelTitle.TLabel").grid(
            row=0, column=0, columnspan=3, sticky="w", pady=(0, 2),
        )
        ttk.Label(controls, text="先选板卡当前输出模式，再打开采集器。",
                  style="PanelHint.TLabel").grid(
            row=1, column=0, columnspan=3, sticky="w", pady=(0, 14),
        )

        ttk.Label(controls, text="处理模式", style="Section.TLabel").grid(
            row=4, column=0, columnspan=3, sticky="w", pady=(8, 4),
        )
        mode_switch = ttk.Frame(controls, style="Sidebar.TFrame")
        mode_switch.grid(row=5, column=0, columnspan=3, sticky="ew", pady=3)
        for index, mode in enumerate(PIPELINE_MODES):
            mode_switch.columnconfigure(index, weight=1)
            if mode == "FPGA监视":
                command = self.show_fpga_monitor
            elif mode == "PC黄金模型":
                command = self.show_raw_stream
            else:
                command = lambda selected_mode=mode: self._select_pipeline_mode(selected_mode)
            button = tk.Button(
                mode_switch, text=PIPELINE_MODE_LABELS[mode],
                command=command,
                relief=tk.FLAT, borderwidth=0, highlightthickness=0,
                padx=7, pady=6, font=("Microsoft YaHei UI", 11, "bold"),
                fg=self.colors["text"], bg=self.colors["panel_alt"],
                activeforeground="#ffffff", activebackground=self.colors["accent"],
            )
            self.mode_buttons[mode] = button
            button.grid(row=0, column=index, sticky="ew", padx=(0 if index == 0 else 2, 0))
        ttk.Label(controls, textvariable=self.mode_hint_var,
                  style="PanelHint.TLabel", wraplength=320).grid(
            row=6, column=0, columnspan=3, sticky="w", pady=(2, 5),
        )
        ttk.Checkbutton(
            controls, text="旋转 180°显示", variable=self.rotate_180_var,
            command=self._rerender_current_frame,
        ).grid(row=7, column=0, columnspan=2, sticky="w", pady=3)
        ttk.Label(controls, text="视图", style="PanelHint.TLabel").grid(
            row=8, column=0, sticky="w", pady=3,
        )
        view_combo = ttk.Combobox(controls, textvariable=self.view_mode_var,
                                  values=VIEW_MODES, state="readonly", width=9)
        self.view_combo = view_combo
        view_combo.grid(row=8, column=1, sticky="ew", pady=3)
        view_combo.bind("<<ComboboxSelected>>", lambda _event: self._render_view())
        ttk.Label(controls, text="矫正参数", style="Section.TLabel").grid(
            row=9, column=0, columnspan=3, sticky="w", pady=(14, 4),
        )
        self._param_row(controls, 10, "实测角度 °", self.angle_var)
        self._param_row(controls, 11, "零点 °", self.zero_var)
        self._param_row(controls, 12, "补偿符号", self.sign_var, values=("-1", "1"))
        self._param_row(controls, 13, "鱼眼 balance", self.balance_var)
        self._param_row(controls, 14, "输出焦距 px", self.focal_var)
        self._param_row(controls, 15, "备注", self.note_var)
        actions = ttk.Frame(controls, style="Sidebar.TFrame")
        actions.grid(row=16, column=0, columnspan=3, sticky="ew", pady=(12, 2))
        actions.columnconfigure(0, weight=1)
        actions.columnconfigure(1, weight=1)
        ttk.Button(actions, text="PC处理当前帧", command=self.process_current_raw,
                   style="Accent.TButton").grid(row=0, column=0, sticky="ew", padx=(0, 4))
        ttk.Button(actions, text="保存当前帧", command=self.save_output).grid(
            row=0, column=1, sticky="ew", padx=(4, 0),
        )

        ttk.Label(controls, text="HDMI 采集器", style="Section.TLabel").grid(
            row=17, column=0, columnspan=3, sticky="w", pady=(16, 4),
        )
        ttk.Label(controls, text="设备编号").grid(row=18, column=0, sticky="w", pady=3)
        ttk.Entry(controls, textvariable=self.capture_device_var, width=7).grid(row=18, column=1, sticky="w", pady=3)
        ttk.Label(controls, text="分辨率").grid(row=19, column=0, sticky="w", pady=3)
        resolution = ttk.Frame(controls, style="Sidebar.TFrame")
        resolution.grid(row=19, column=1, columnspan=2, sticky="ew", pady=3)
        ttk.Entry(resolution, textvariable=self.capture_width_var, width=7).pack(side=tk.LEFT)
        ttk.Label(resolution, text=" × ").pack(side=tk.LEFT)
        ttk.Entry(resolution, textvariable=self.capture_height_var, width=7).pack(side=tk.LEFT)
        ttk.Button(controls, text="打开实时采集", command=self.start_capture,
                   style="Accent.TButton").grid(row=20, column=0, columnspan=2, sticky="ew", pady=(8, 3), padx=(0, 4))
        ttk.Button(controls, text="停止采集", command=self.stop_capture).grid(
            row=20, column=2, sticky="ew", pady=(8, 3), padx=(4, 0),
        )
        ttk.Label(controls, text="原始/FPGA 都是视频流；PC处理和保存都由你手动触发",
                  style="PanelHint.TLabel", wraplength=320).grid(
            row=21, column=0, columnspan=3, sticky="w", pady=(6, 0),
        )

        def scroll_controls(event: tk.Event) -> str:
            if event.delta and controls.winfo_reqheight() > sidebar_canvas.winfo_height():
                sidebar_canvas.yview_scroll(-3 if event.delta > 0 else 3, "units")
            return "break"

        pending = [controls]
        while pending:
            widget = pending.pop()
            widget.bind("<MouseWheel>", scroll_controls, add="+")
            pending.extend(widget.winfo_children())

        content = ttk.Frame(body, padding=(0, 0, 14, 12), style="Surface.TFrame")
        content.grid(row=0, column=1, sticky="nsew")
        content.columnconfigure(0, weight=1)
        content.rowconfigure(1, weight=1)
        canvas_toolbar = ttk.Frame(content, padding=(14, 12, 14, 10), style="Canvas.TFrame")
        canvas_toolbar.grid(row=0, column=0, sticky="ew")
        canvas_toolbar.columnconfigure(1, weight=1)
        ttk.Label(canvas_toolbar, text="实时画布", style="CanvasTitle.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Label(canvas_toolbar, textvariable=self.canvas_hint_var,
                  style="CanvasHint.TLabel").grid(row=1, column=0, sticky="w", pady=(3, 0))
        metric_label = ttk.Label(canvas_toolbar, textvariable=self.capture_metric_var,
                                 style="Metric.TLabel", wraplength=760)
        metric_label.grid(row=2, column=0, columnspan=2, sticky="ew", pady=(5, 0))
        canvas_toolbar.bind("<Configure>", lambda event: metric_label.configure(
            wraplength=max(240, event.width - 28)))
        ttk.Label(canvas_toolbar, textvariable=self.capture_device_info_var,
                  style="CanvasHint.TLabel").grid(
            row=3, column=0, columnspan=2, sticky="w", pady=(4, 0),
        )

        images = ttk.Frame(content, padding=(12, 8, 12, 12), style="Canvas.TFrame")
        images.grid(row=1, column=0, sticky="nsew")
        self.images_frame = images
        # Keep the two comparison columns identical even when the source
        # images have different native dimensions and therefore different
        # requested widget sizes.
        images.columnconfigure(0, weight=1, uniform="preview_panels")
        images.columnconfigure(1, weight=1, uniform="preview_panels")
        images.rowconfigure(1, weight=1)
        self.input_header = ttk.Label(images, text="FPGA HDMI 输出（硬件当前模式）")
        self.input_header.grid(row=0, column=0, pady=4)
        self.corrected_header = ttk.Label(images, text="PC 黄金模型结果")
        self.corrected_header.grid(row=0, column=1, pady=4)
        self.input_label = ttk.Label(images, anchor="center")
        self.input_label.grid(row=1, column=0, sticky="nsew", padx=4)
        self.corrected_label = ttk.Label(images, anchor="center")
        self.corrected_label.grid(row=1, column=1, sticky="nsew", padx=4)
        images.bind("<Configure>", self._schedule_resize_render)

        ttk.Label(shell, textvariable=self.status_var, style="Status.TLabel",
                  anchor="w").pack(side=tk.BOTTOM, fill=tk.X)

    @staticmethod
    def _param_row(parent: ttk.Frame, row: int, label: str,
                   variable: tk.StringVar,
                   values: tuple[str, ...] | None = None) -> None:
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", pady=3)
        if values is None:
            ttk.Entry(parent, textvariable=variable).grid(
                row=row, column=1, columnspan=2, sticky="ew", pady=3,
            )
        else:
            ttk.Combobox(parent, textvariable=variable, values=values,
                         state="readonly", width=8).grid(
                row=row, column=1, columnspan=2, sticky="ew", pady=3,
            )

    def _render_view(self) -> None:
        """Switch between raw, corrected, and side-by-side display."""
        if self.images_frame is None:
            return
        signature = (
            self.pipeline_mode_var.get(), self.view_mode_var.get(),
            self.last_pc_corrected_image is not None,
            self.corrected_image is not None,
        )
        if signature == self._rendered_view_signature:
            return
        self._rendered_view_signature = signature
        self.input_header.grid_forget()
        self.corrected_header.grid_forget()
        self.input_label.grid_forget()
        self.corrected_label.grid_forget()
        mode = self.view_mode_var.get()
        if self.pipeline_mode_var.get() == "FPGA监视":
            if self.last_pc_corrected_image is None:
                mode = FPGA_VIEW_MODE
                self.view_mode_var.set(FPGA_VIEW_MODE)
            else:
                if mode not in (FPGA_VIEW_MODE, FPGA_REFERENCE_VIEW_MODE):
                    mode = FPGA_REFERENCE_VIEW_MODE
                    self.view_mode_var.set(mode)
            self.input_header.configure(text="FPGA HDMI 输出（硬件当前模式）")
            self.corrected_header.configure(
                text=("上一次原始帧的 PC 黄金模型结果"
                      if mode == FPGA_REFERENCE_VIEW_MODE else "PC 黄金模型未加载")
            )
        elif self.pipeline_mode_var.get() == "对比":
            self.input_header.configure(text="FPGA HDMI 输出帧（文件）")
            self.corrected_header.configure(text="PC 黄金模型（原始鱼眼帧）")
        else:
            if self.corrected_image is None:
                mode = "原始"
                self.view_mode_var.set(mode)
                self.input_header.configure(text="原始 HDMI 视频流（等待抓帧）")
                self.corrected_header.configure(text="点击“原始画面→PC矫正”后生成")
            else:
                self.input_header.configure(text="输入：未经 FPGA 矫正的原始鱼眼帧")
                self.corrected_header.configure(text="PC 黄金模型矫正结果")
        panels = visible_panels(mode)
        if panels == ("input", "corrected"):
            self.input_header.grid(row=0, column=0, pady=4)
            self.corrected_header.grid(row=0, column=1, pady=4)
            self.input_label.grid(row=1, column=0, sticky="nsew", padx=4)
            self.corrected_label.grid(row=1, column=1, sticky="nsew", padx=4)
        elif panels == ("input",):
            self.input_header.grid(row=0, column=0, columnspan=2, pady=4)
            self.input_label.grid(row=1, column=0, columnspan=2,
                                  sticky="nsew", padx=4)
        else:
            self.corrected_header.grid(row=0, column=0, columnspan=2, pady=4)
            self.corrected_label.grid(row=1, column=0, columnspan=2,
                                      sticky="nsew", padx=4)

    @staticmethod
    def _path_row(parent: ttk.Frame, row: int, label: str,
                  variable: tk.StringVar, callback: Any) -> None:
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=4, pady=3)
        ttk.Entry(parent, textvariable=variable).grid(row=row, column=1,
                                                      sticky="ew", padx=4, pady=3)
        ttk.Button(parent, text="选择", command=callback).grid(row=row, column=2,
                                                               padx=(4, 0), pady=3)

    def _choose_image(self) -> None:
        selected = filedialog.askopenfilename(
            title="选择未经 FPGA 矫正的原始鱼眼帧或 PNG",
            filetypes=(("图像", "*.png *.jpg *.jpeg *.bmp"), ("所有文件", "*.*")),
        )
        if selected:
            self.image_var.set(selected)

    def _choose_fpga_output(self) -> None:
        selected = filedialog.askopenfilename(
            title="选择 FPGA HDMI 输出帧",
            filetypes=(("图像", "*.png *.jpg *.jpeg *.bmp"), ("所有文件", "*.*")),
        )
        if selected:
            self.fpga_output_var.set(selected)

    def _choose_calibration(self) -> None:
        selected = filedialog.askopenfilename(
            title="选择标定 JSON", filetypes=(("JSON", "*.json"), ("所有文件", "*.*")),
        )
        if selected:
            self.calibration_var.set(selected)

    def _on_pipeline_mode_changed(self) -> None:
        mode = self.pipeline_mode_var.get()
        if mode == "对比" and self.capture is not None:
            self.stop_capture(update_status=False)
        self.mode_badge_var.set(mode)
        self.mode_hint_var.set(PIPELINE_MODE_HINTS[mode])
        for button_mode, button in self.mode_buttons.items():
            selected = button_mode == mode
            button.configure(
                bg=self.colors["accent"] if selected else self.colors["panel_alt"],
                fg="#ffffff" if selected else self.colors["text"],
            )
        if mode == "FPGA监视":
            if self.last_pc_corrected_image is None:
                self.view_mode_var.set(FPGA_VIEW_MODE)
                if self.view_combo is not None:
                    self.view_combo.configure(values=(FPGA_VIEW_MODE,), state="disabled")
                self.canvas_hint_var.set("FPGA 输出监视：仅显示 HDMI 采集画面")
                self.status_var.set("FPGA HDMI 输出监视（尚未抓取原始帧，不显示 PC 参考）")
            else:
                self.view_mode_var.set(FPGA_REFERENCE_VIEW_MODE)
                if self.view_combo is not None:
                    self.view_combo.configure(
                        values=(FPGA_REFERENCE_VIEW_MODE, FPGA_VIEW_MODE),
                        state="readonly",
                    )
                self.canvas_hint_var.set("FPGA 输出实时画面 + 上一次原始帧的 PC 黄金模型参考")
                self.status_var.set("FPGA HDMI 输出监视（PC 参考来自已保存原始帧，未二次矫正）")
        elif mode == "PC黄金模型":
            self.view_mode_var.set("并排" if self.last_pc_corrected_image is not None else "原始")
            if self.view_combo is not None:
                self.view_combo.configure(values=VIEW_MODES, state="readonly")
            self.canvas_hint_var.set("原始 HDMI 视频流：点击按钮保存当前帧并运行 PC 黄金模型")
            self.status_var.set("原始 HDMI 视频流（不自动处理，等待手动抓帧）")
        else:
            self.view_mode_var.set("并排")
            if self.view_combo is not None:
                self.view_combo.configure(values=VIEW_MODES, state="readonly")
            self.canvas_hint_var.set("静态对比：FPGA 输出 vs PC 黄金模型")
            self.status_var.set("对比模式：需要匹配的原始鱼眼帧和 FPGA 输出帧")
        self._render_view()

    def _select_pipeline_mode(self, mode: str) -> None:
        self.pipeline_mode_var.set(mode)
        self._on_pipeline_mode_changed()

    def show_fpga_monitor(self) -> None:
        """Select the FPGA-output view and start HDMI capture if needed."""
        self._select_pipeline_mode("FPGA监视")
        if self.capture is None:
            self.start_capture()

    def show_raw_stream(self) -> None:
        """Select the raw HDMI stream without saving or processing a frame."""
        self._select_pipeline_mode("PC黄金模型")
        if self.capture is None:
            self.start_capture()

    def process_current_raw(self) -> None:
        """Run the PC golden model on one manually selected raw frame.

        The HDMI device carries whatever the FPGA is currently outputting. The
        operator must select the raw stream before pressing this action. No file
        is written here; ``保存当前帧`` is the explicit save operation.
        """
        if self.pipeline_mode_var.get() != "PC黄金模型":
            message = "请先点击“原始画面”，确认 FPGA 已切到原始输出后再处理。"
            self.status_var.set(message)
            messagebox.showwarning("不是原始视频流", message, parent=self.root)
            return
        if self.input_image is None:
            message = "还没有原始 HDMI 帧，请先点击“原始画面”并等待画面稳定。"
            self.status_var.set(message)
            messagebox.showwarning("没有可处理的原始帧", message, parent=self.root)
            return
        raw_image = self.input_image.copy()
        capture_metadata = dict(
            (self.preview_summary or {}).get("capture") or {}
        )
        capture_metadata.update({
            "source": "hdmi",
            "pipeline_mode": "PC黄金模型",
            "correction_applied": True,
            "captured_utc": datetime.now(timezone.utc).isoformat(
                timespec="milliseconds",
            ),
        })
        capture_metadata.setdefault(
            "resolution", [raw_image.shape[1], raw_image.shape[0]],
        )
        capture_metadata.setdefault("rotate_180_display", self.rotate_180_var.get())

        try:
            options = self._read_options(require_image=False)
            calibration_path = options["calibration_path"]
            if calibration_path is None or not calibration_path.is_file():
                raise ValueError(f"默认标定 JSON 不存在: {calibration_path}")
            calibration = load_record(calibration_path)
            self.stop_capture(update_status=False)
            self.pipeline_mode_var.set("PC黄金模型")
            self._on_pipeline_mode_changed()
            self._display_processed_frame(
                raw_image, calibration, options,
                self.current_input_reference or "hdmi://selected-raw-frame",
                "已完成当前原始帧的 PC 黄金模型处理，请手动保存",
                capture_metadata,
            )
            self.status_var.set(
                "PC 黄金模型处理完成；请点击“保存当前帧”手动保存原始帧、PC 结果和摘要"
            )
        except (OSError, KeyError, TypeError, ValueError) as exc:
            self.status_var.set(f"原始帧处理失败: {exc}")
            messagebox.showerror("原始画面处理失败", str(exc), parent=self.root)

    def _rerender_current_frame(self) -> None:
        if self.input_image is None:
            return
        if self.pipeline_mode_var.get() == "FPGA监视":
            self._set_input_photo(self.input_image)
            if (self.view_mode_var.get() == FPGA_REFERENCE_VIEW_MODE
                    and self.last_pc_corrected_image is not None):
                self._set_corrected_photo(self.last_pc_corrected_image)
        elif self.corrected_image is not None:
            self._set_input_photo(self.input_image)
            self._set_corrected_photo(self.corrected_image)

    def _set_input_photo(self, image: np.ndarray) -> None:
        max_width, max_height = self._preview_bounds(self.input_label)
        self._input_photo = tk.PhotoImage(
            data=encode_live_ppm(
                image, rotate_180=self.rotate_180_var.get(),
                max_width=max_width, max_height=max_height,
            ),
            format="PPM",
        )
        self.input_label.configure(image=self._input_photo)

    def _set_corrected_photo(self, image: np.ndarray) -> None:
        max_width, max_height = self._preview_bounds(self.corrected_label)
        self._corrected_photo = tk.PhotoImage(
            data=encode_live_ppm(
                image, rotate_180=self.rotate_180_var.get(),
                max_width=max_width, max_height=max_height,
            ),
            format="PPM",
        )
        self.corrected_label.configure(image=self._corrected_photo)

    @staticmethod
    def _preview_bounds(label: ttk.Label) -> tuple[int, int]:
        """Use the current image panel size without enlarging the source."""
        width = label.winfo_width()
        height = label.winfo_height()
        if width <= 2 or height <= 2:
            return 620, 420
        return max(160, width - 16), max(120, height - 16)

    def _schedule_resize_render(self, _event: Any = None) -> None:
        """Debounce image re-encoding while the main window is resized."""
        if self._resize_after_id is not None:
            try:
                self.root.after_cancel(self._resize_after_id)
            except tk.TclError:
                pass
        self._resize_after_id = self.root.after(100, self._resize_render)

    def _resize_render(self) -> None:
        self._resize_after_id = None
        self._rerender_current_frame()

    def _read_options(self, *, require_image: bool = True) -> dict[str, Any]:
        image_text = self.image_var.get().strip()
        image_path = Path(image_text) if image_text else None
        calibration_text = self.calibration_var.get().strip()
        calibration_path = Path(calibration_text) if calibration_text else None
        if require_image and (image_path is None or not image_path.is_file()):
            raise ValueError(f"输入帧不存在: {image_path}")
        if self.pipeline_mode_var.get() != "FPGA监视" and (
                calibration_path is None or not calibration_path.is_file()):
            raise ValueError(f"标定 JSON 不存在: {calibration_path}")
        measured_text = self.angle_var.get().strip()
        measured_angle = None if not measured_text else _parse_float(measured_text, "实测角度")
        focal_text = self.focal_var.get().strip()
        output_focal = None if not focal_text else _parse_float(focal_text, "输出焦距")
        sign = int(self.sign_var.get())
        if sign not in (-1, 1):
            raise ValueError("补偿符号必须是 -1 或 1")
        balance = _parse_float(self.balance_var.get(), "balance")
        if not 0.0 <= balance <= 1.0:
            raise ValueError("balance 必须在 0 到 1 之间")
        return {
            "image_path": image_path,
            "calibration_path": calibration_path,
            "measured_angle": measured_angle,
            "zero_deg": _parse_float(self.zero_var.get(), "零点"),
            "compensation_sign": sign,
            "balance": balance,
            "output_focal_px": output_focal,
        }

    def _display_processed_frame(self, image: np.ndarray,
                                 calibration: dict[str, Any],
                                 options: dict[str, Any],
                                 input_reference: str,
                                 status_prefix: str,
                                 capture_metadata: dict[str, Any] | None = None,
                                 ) -> None:
        expected_size = calibration.get("image_size")
        actual_size = [image.shape[1], image.shape[0]]
        if expected_size != actual_size:
            expected_text = "×".join(str(value) for value in expected_size)
            actual_text = "×".join(str(value) for value in actual_size)
            raise ValueError(
                f"尺寸不匹配：输入帧 {actual_text}，标定 JSON 要求 {expected_text}"
            )
        processing_started = time.perf_counter()
        corrected, summary = correct_frame(
            image, calibration,
            measured_angle_deg=options["measured_angle"],
            zero_deg=options["zero_deg"],
            compensation_sign=options["compensation_sign"],
            balance=options["balance"],
            output_focal_px=options["output_focal_px"],
        )
        processing_elapsed = max(time.perf_counter() - processing_started, 1e-6)
        self.pc_processing_fps = 1.0 / processing_elapsed
        self._refresh_metric_line()
        self.input_image = image
        self.corrected_image = corrected
        summary = dict(summary)
        summary["capture"] = capture_metadata or build_capture_metadata(
            source="file", resolution=(image.shape[1], image.shape[0]),
            fps=None,
            pipeline_mode="PC黄金模型",
            rotate_180=self.rotate_180_var.get(),
            correction_applied=True,
        )
        if capture_metadata is not None:
            summary["quality_gate"] = live_quality_gate(capture_metadata)
        else:
            summary["quality_gate"] = {
                "status": "NOT_APPLIED", "warnings": [],
            }
        self.preview_summary = summary
        summary["pipeline_mode"] = "PC黄金模型"
        summary["source_image_type"] = "uncorrected_fisheye_offline"
        summary["correction_applied"] = True
        summary["rotate_180_display"] = self.rotate_180_var.get()
        summary["pc_golden_processing_fps"] = self.pc_processing_fps
        if capture_metadata is not None and capture_metadata.get("source") == "hdmi":
            self.last_pc_raw_image = image.copy()
            self.last_pc_corrected_image = corrected.copy()
            self.last_pc_summary = dict(summary)
            self.last_pc_raw_path = Path(input_reference)
            self.last_pc_corrected_path = None
        self.current_input_reference = input_reference
        self._set_input_photo(image)
        self._set_corrected_photo(corrected)
        self._render_view()
        angle = summary["angle"]
        self.status_var.set(
            f"{status_prefix} | measured={angle['measured_deg']}° | "
            f"compensation={angle['compensation_deg']}° | "
            f"valid={summary['coordinate_in_bounds_fraction']} | "
            "PC 黄金模型，非 FPGA 硬件验收",
        )

    def _display_monitor_frame(self, image: np.ndarray,
                               input_reference: str,
                               status_prefix: str,
                               capture_metadata: dict[str, Any],
                               pipeline_mode: str = "FPGA监视") -> None:
        """Display one live HDMI stream without applying PC correction."""
        self.input_image = image
        self.corrected_image = (
            self.last_pc_corrected_image
            if pipeline_mode == "FPGA监视"
            and self.view_mode_var.get() == FPGA_REFERENCE_VIEW_MODE
            and self.last_pc_corrected_image is not None else None
        )
        capture_metadata.update({
            "pipeline_mode": pipeline_mode,
            "rotate_180_display": self.rotate_180_var.get(),
            "correction_applied": False,
            "display_color_conversion": "BGR converted to RGB for Tk PPM live display",
            "expected_signal_fps": self.expected_signal_fps,
            "source_fps_provenance": "project video mode; not measured by DirectShow"
            if self.expected_signal_fps is not None else "not configured",
        })
        self.preview_summary = {
            "pipeline_mode": pipeline_mode,
            "input_size": [image.shape[1], image.shape[0]],
            "angle": {"source": "not_used", "note": "live HDMI stream"},
            "note": ("FPGA HDMI 输出监视，未进行 PC 二次矫正"
                     if pipeline_mode == "FPGA监视"
                     else "原始 HDMI 视频流，等待用户抓帧后运行 PC 黄金模型"),
            "capture": capture_metadata,
            "quality_gate": live_quality_gate(capture_metadata),
        }
        if self.corrected_image is not None:
            self.preview_summary["pc_reference"] = {
                "source_image": str(self.last_pc_raw_path or ""),
                "corrected_image": str(self.last_pc_corrected_path or ""),
                "note": "静态参考，不是当前 FPGA 帧的 PC 二次矫正",
            }
        self.current_input_reference = input_reference
        self._set_input_photo(image)
        if self.corrected_image is not None:
            self._set_corrected_photo(self.corrected_image)
        self._render_view()
        measured_fps = capture_metadata.get("capture_arrival_fps",
                                            capture_metadata.get("read_fps"))
        self.capture_arrival_fps = measured_fps
        self.capture_content_fps = capture_metadata.get("content_update_estimate_fps")
        self._refresh_metric_line()
        quality = self.preview_summary["quality_gate"]
        warning = "；".join(quality["warnings"]) if quality["warnings"] else "帧质量通过"
        black_fraction = capture_metadata.get("black_fraction")
        black_text = ("n/a" if black_fraction is None
                      else f"{float(black_fraction):.2%}")
        measured_text = ("--.-" if measured_fps is None
                         else f"{float(measured_fps):.1f}")
        signal_text = ("工程视频模式未配置" if self.expected_signal_fps is None
                       else f"工程视频模式 {self.expected_signal_fps:.0f} FPS")
        self.status_var.set(
            f"{status_prefix}（当前帧未执行 PC 矫正） | "
            f"{signal_text} | "
            f"采集卡到达 {measured_text} FPS | "
            f"black={black_text} | "
            f"质量门禁={quality['status']}（{warning}） | "
            f"旋转180°={'开' if self.rotate_180_var.get() else '关'}",
        )

    def _display_comparison(self, raw_image: np.ndarray,
                            fpga_image: np.ndarray,
                            calibration: dict[str, Any],
                            options: dict[str, Any],
                            raw_reference: str,
                            fpga_reference: str) -> None:
        """Show FPGA output beside a golden result made from its raw pair."""
        if raw_image.shape != fpga_image.shape:
            raise ValueError("对比模式要求原始帧和 FPGA 输出帧尺寸完全一致")
        processing_started = time.perf_counter()
        corrected, summary = correct_frame(
            raw_image, calibration,
            measured_angle_deg=options["measured_angle"],
            zero_deg=options["zero_deg"],
            compensation_sign=options["compensation_sign"],
            balance=options["balance"],
            output_focal_px=options["output_focal_px"],
        )
        processing_elapsed = max(time.perf_counter() - processing_started, 1e-6)
        self.pc_processing_fps = 1.0 / processing_elapsed
        self._refresh_metric_line()
        self.input_image = fpga_image
        self.corrected_image = corrected
        summary = dict(summary)
        summary["pipeline_mode"] = "对比"
        summary["pc_golden_processing_fps"] = self.pc_processing_fps
        summary["source_images"] = {
            "raw_fisheye": raw_reference,
            "fpga_output": fpga_reference,
        }
        summary["capture"] = build_capture_metadata(
            source="file", resolution=(fpga_image.shape[1], fpga_image.shape[0]),
            fps=None, pipeline_mode="对比",
            rotate_180=self.rotate_180_var.get(), correction_applied=True,
        )
        summary["quality_gate"] = {"status": "NOT_APPLIED", "warnings": []}
        self.preview_summary = summary
        self.current_input_reference = fpga_reference
        self._set_input_photo(fpga_image)
        self._set_corrected_photo(corrected)
        self._render_view()
        self.status_var.set(
            "对比模式：左=FPGA HDMI 输出文件，右=PC 黄金模型（原始鱼眼输入）" \
            f" | 旋转180°={'开' if self.rotate_180_var.get() else '关'}",
        )

    def preview(self) -> None:
        try:
            options = self._read_options(require_image=True)
            mode = self.pipeline_mode_var.get()
            if mode == "FPGA监视":
                image = cv2.imread(str(options["image_path"]), cv2.IMREAD_COLOR)
                if image is None:
                    raise ValueError(f"无法读取输入帧: {options['image_path']}")
                self._display_monitor_frame(
                    image, str(options["image_path"]), "FPGA HDMI 输出文件",
                    build_capture_metadata(
                        source="file", resolution=(image.shape[1], image.shape[0]),
                        fps=None, pipeline_mode="FPGA监视",
                        rotate_180=self.rotate_180_var.get(), correction_applied=False,
                    ),
                )
                return
            calibration = load_record(options["calibration_path"])
            image = cv2.imread(str(options["image_path"]), cv2.IMREAD_COLOR)
            if image is None:
                raise ValueError(f"无法读取输入帧: {options['image_path']}")
            if mode == "对比":
                fpga_path = Path(self.fpga_output_var.get().strip())
                if not fpga_path.is_file():
                    raise ValueError("对比模式必须提供 FPGA 输出帧")
                fpga_image = cv2.imread(str(fpga_path), cv2.IMREAD_COLOR)
                if fpga_image is None:
                    raise ValueError(f"无法读取 FPGA 输出帧: {fpga_path}")
                self._display_comparison(
                    image, fpga_image, calibration, options,
                    str(options["image_path"]), str(fpga_path),
                )
                return
            self._display_processed_frame(
                image, calibration, options, str(options["image_path"]),
                "PC 黄金模型离线预览",
                build_capture_metadata(
                    source="file", resolution=(image.shape[1], image.shape[0]),
                    fps=None, pipeline_mode="PC黄金模型",
                    rotate_180=self.rotate_180_var.get(), correction_applied=True,
                ),
            )
        except (OSError, KeyError, TypeError, ValueError) as exc:
            self.status_var.set(f"失败: {exc}")
            messagebox.showerror("预览失败", str(exc), parent=self.root)

    def _refresh_metric_line(self) -> None:
        """Show each measured rate in its own clock and processing domain."""
        try:
            width = int(self.capture_width_var.get().strip())
            height = int(self.capture_height_var.get().strip())
        except ValueError:
            width, height = 0, 0
        if self.capture_info is not None:
            actual = self.capture_info.get("actual_resolution", [width, height])
            if len(actual) == 2 and all(int(value) > 0 for value in actual):
                width, height = int(actual[0]), int(actual[1])
        self.capture_metric_var.set(format_metric_line(
            width=width, height=height,
            expected_fps=self.expected_signal_fps,
            arrival_fps=self.capture_arrival_fps,
            content_fps=self.capture_content_fps,
            ui_fps=self.ui_render_fps,
            pc_processing_fps=self.pc_processing_fps,
        ))

    def _refresh_device_info(self) -> None:
        if self.capture_info is None:
            self.capture_device_info_var.set("采集协商：尚未打开设备")
            return
        requested = self.capture_info["requested_resolution"]
        actual = self.capture_info["actual_resolution"]
        reported = self.capture_info["reported_fps"]
        reported_text = "设备未报告" if reported is None else f"{reported:.1f} FPS"
        fallback = "；分辨率发生回退" if self.capture_info["resolution_fallback"] else ""
        self.capture_device_info_var.set(
            f"采集协商：请求 {requested[0]}×{requested[1]}/"
            f"{self.capture_info['requested_fourcc']}/{self.capture_info['requested_fps']:.1f} FPS；"
            f"实际 {actual[0]}×{actual[1]}/{self.capture_info['actual_fourcc']}/"
            f"{reported_text}；后端 {self.capture_info['backend']}{fallback}"
        )

    def _schedule_capture_poll(self, delay_ms: int = 10) -> None:
        if self.capture_worker is not None:
            self.capture_after_id = self.root.after(delay_ms, self._poll_capture)

    def start_capture(self) -> None:
        """Open the capture device and start a UI-independent reader thread."""
        if self.pipeline_mode_var.get() not in ("FPGA监视", "PC黄金模型"):
            message = "文件对比模式不能打开实时采集，请先选择原始画面或 FPGA 实时流程。"
            self.status_var.set(message)
            messagebox.showwarning("无法打开实时采集", message, parent=self.root)
            return
        try:
            options = self._read_options(require_image=False)
            device_text = self.capture_device_var.get().strip()
            if not device_text:
                raise ValueError("请填写 HDMI 采集器设备编号")
            device = int(device_text)
            width = int(self.capture_width_var.get().strip())
            height = int(self.capture_height_var.get().strip())
            if device < 0 or width <= 0 or height <= 0:
                raise ValueError("设备编号必须非负，宽高必须为正数")
        except (KeyError, TypeError, ValueError) as exc:
            self.status_var.set(f"实时采集配置失败: {exc}")
            messagebox.showerror("实时采集配置失败", str(exc), parent=self.root)
            return

        self.stop_capture(update_status=False)
        backend = capture_backend_id(self.capture_backend)
        capture = cv2.VideoCapture(device, backend)
        if not capture.isOpened():
            capture.release()
            message = f"无法打开视频设备 {device}"
            self.status_var.set(message)
            messagebox.showerror("打开采集器失败", message, parent=self.root)
            return
        try:
            capture_info = configure_capture(
                capture, device=device, width=width, height=height,
                requested_fps=self.capture_requested_fps,
                requested_fourcc=self.capture_fourcc,
            )
        except (TypeError, ValueError, cv2.error) as exc:
            capture.release()
            message = f"采集器模式协商失败: {exc}"
            self.status_var.set(message)
            messagebox.showerror("打开采集器失败", message, parent=self.root)
            return
        self.capture = capture
        self.capture_info = capture_info
        self.capture_device = device
        self.capture_reported_fps = capture_info["reported_fps"]
        self.capture_frame_index = 0
        self.capture_previous_frame = None
        self.live_metrics = {
            "black_fraction": 0.0,
            "mean_absolute_difference": None,
        }
        self.capture_arrival_fps = None
        self.capture_content_fps = None
        self.ui_render_timestamps.clear()
        self.ui_render_fps = None
        self.last_displayed_capture_index = -1
        self.capture_worker = CaptureWorker(capture)
        self.capture_worker.start()
        self._refresh_metric_line()
        self._refresh_device_info()
        stream_name = "FPGA 输出" if self.pipeline_mode_var.get() == "FPGA监视" else "原始视频流"
        actual_width, actual_height = capture_info["actual_resolution"]
        reported = capture_info["reported_fps"]
        reported_text = "设备未报告" if reported is None else f"{reported:.1f} FPS"
        fallback = "，发生模式回退" if capture_info["resolution_fallback"] else ""
        self.status_var.set(
            f"采集器 {device} 已打开：{stream_name}，"
            f"{actual_width}×{actual_height}/{capture_info['actual_fourcc']}/"
            f"{reported_text}/{capture_info['backend']}{fallback}；不自动做 PC 矫正"
        )
        self._schedule_capture_poll(0)

    def _poll_capture(self) -> None:
        worker = self.capture_worker
        if worker is None or self.capture_device is None:
            return
        packet = worker.latest_packet(self.last_displayed_capture_index)
        if packet is None:
            if worker.error is not None:
                message = f"HDMI 采集器 {self.capture_device} 已停止: {worker.error}"
                self.stop_capture(update_status=False)
                self.status_var.set(message)
                messagebox.showerror("实时采集已停止", message, parent=self.root)
                return
            self._schedule_capture_poll()
            return
        frame = packet.frame
        try:
            frame_index = packet.index
            if self.capture_info is not None:
                actual_resolution = [frame.shape[1], frame.shape[0]]
                if actual_resolution != self.capture_info["actual_resolution"]:
                    self.capture_info["actual_resolution"] = actual_resolution
                    self.capture_info["resolution_fallback"] = (
                        actual_resolution != self.capture_info["requested_resolution"]
                    )
                    self._refresh_device_info()
            self.capture_arrival_fps = packet.arrival_fps
            self.capture_content_fps = packet.content_update_fps
            if (self.capture_previous_frame is None
                    or frame_index % self.quality_sample_interval == 0):
                metrics = live_frame_metrics(frame, self.capture_previous_frame)
                self.live_metrics = metrics
                self.capture_previous_frame = frame.copy()
            else:
                metrics = self.live_metrics
            capture_metadata = build_capture_metadata(
                source="hdmi", device=self.capture_device,
                frame_index=frame_index, resolution=(frame.shape[1], frame.shape[0]),
                fps=packet.arrival_fps,
                black_fraction=metrics["black_fraction"],
                mean_absolute_difference=metrics["mean_absolute_difference"],
                captured_utc=datetime.now(timezone.utc).isoformat(
                    timespec="milliseconds",
                ),
                pipeline_mode=self.pipeline_mode_var.get(),
                rotate_180=self.rotate_180_var.get(),
                correction_applied=False,
            )
            capture_metadata["source_reported_fps"] = self.capture_reported_fps
            capture_metadata["capture_arrival_fps"] = packet.arrival_fps
            capture_metadata["average_capture_arrival_fps"] = packet.average_arrival_fps
            capture_metadata["content_update_estimate_fps"] = packet.content_update_fps
            capture_metadata["content_changed"] = packet.content_changed
            capture_metadata["read_duration_ms"] = packet.read_duration_ms
            capture_metadata["read_fps"] = packet.arrival_fps
            capture_metadata["average_read_fps"] = packet.average_arrival_fps
            capture_metadata["read_fps_provenance"] = (
                "capture-thread read completion rate; excludes UI scheduling and rendering"
            )
            capture_metadata["content_fps_provenance"] = (
                "noise-filtered frame-difference estimate; not an FPGA internal counter"
            )
            capture_metadata["expected_signal_fps"] = self.expected_signal_fps
            capture_metadata["source_fps_provenance"] = (
                "project video mode; not measured by DirectShow"
                if self.expected_signal_fps is not None else "not configured"
            )
            capture_metadata["device_negotiation"] = dict(self.capture_info or {})
            reference = live_frame_reference(self.capture_device, frame_index)
            ui_started = time.perf_counter()
            self._display_monitor_frame(
                frame, reference,
                (f"FPGA HDMI 输出实时 {self.capture_device} {frame.shape[1]}×{frame.shape[0]}"
                 if self.pipeline_mode_var.get() == "FPGA监视"
                 else f"原始 HDMI 视频流实时 {self.capture_device} {frame.shape[1]}×{frame.shape[0]}"),
                capture_metadata,
                self.pipeline_mode_var.get(),
            )
            rendered_at = time.perf_counter()
            ui_processing_elapsed = max(rendered_at - ui_started, 1e-6)
            self.ui_render_timestamps.append(rendered_at)
            self.ui_render_fps = rolling_frame_rate(list(self.ui_render_timestamps))
            capture_metadata["ui_render_fps"] = self.ui_render_fps
            capture_metadata["ui_frame_processing_fps"] = 1.0 / ui_processing_elapsed
            capture_metadata["pc_golden_processing_fps"] = self.pc_processing_fps
            if self.preview_summary is not None:
                self.preview_summary["capture"] = capture_metadata
        except (KeyError, TypeError, ValueError, cv2.error, tk.TclError) as exc:
            self.stop_capture(update_status=False)
            self.status_var.set(f"实时监视失败: {exc}")
            messagebox.showerror("实时监视失败", str(exc), parent=self.root)
            return
        self.last_displayed_capture_index = packet.index
        self.capture_frame_index = packet.index + 1
        quality_gate = live_quality_gate(metrics)
        quality = "；".join(quality_gate["warnings"]) if quality_gate["warnings"] else "帧质量通过"
        stream_name = ("FPGA HDMI 监视"
                       if self.pipeline_mode_var.get() == "FPGA监视"
                       else "原始 HDMI 采集")
        if frame_index % 15 == 0:
            self._refresh_metric_line()
            self.status_var.set(
                f"{stream_name} {self.capture_device} | "
                f"工程模式 {self.expected_signal_fps or '未配置'} FPS（非实测） | "
                f"采集卡到达 {packet.arrival_fps or 0:.1f} FPS | "
                f"内容更新估计 {packet.content_update_fps or 0:.1f} FPS | "
                f"UI显示 {self.ui_render_fps or 0:.1f} FPS | "
                f"black={metrics['black_fraction']:.2%} | "
                f"质量门禁={quality_gate['status']} ({quality}) | "
                f"旋转180°={'开' if self.rotate_180_var.get() else '关'}",
            )
        self._schedule_capture_poll()

    def stop_capture(self, *, update_status: bool = True) -> None:
        if self.capture_after_id is not None:
            try:
                self.root.after_cancel(self.capture_after_id)
            except tk.TclError:
                pass
            self.capture_after_id = None
        if self.capture_worker is not None:
            self.capture_worker.stop()
            self.capture_worker = None
        elif self.capture is not None:
            self.capture.release()
        self.capture = None
        self.capture_device = None
        self.capture_reported_fps = None
        self.capture_previous_frame = None
        self.capture_arrival_fps = None
        self.capture_content_fps = None
        self.capture_info = None
        self.ui_render_timestamps.clear()
        self.ui_render_fps = None
        self.last_displayed_capture_index = -1
        self._refresh_metric_line()
        self._refresh_device_info()
        if update_status:
            self.status_var.set("实时采集已停止；仍未连接 FPGA 控制通道")

    def close(self) -> None:
        self.stop_capture(update_status=False)
        self.root.destroy()

    def save_output(self) -> None:
        if self.input_image is None or self.preview_summary is None:
            self.preview()
        if self.input_image is None or self.preview_summary is None:
            return
        monitor_mode = self.pipeline_mode_var.get() == "FPGA监视"
        raw_only_mode = self.pipeline_mode_var.get() == "PC黄金模型" and self.corrected_image is None
        output_name = filedialog.asksaveasfilename(
            title=("保存 FPGA 原始帧和旋转显示帧（输入显示帧文件名）"
                   if monitor_mode else
                   "保存原始帧（输入原始帧文件名）" if raw_only_mode else
                   "保存原始帧和矫正帧（输入矫正帧文件名）"),
            defaultextension=".png",
            filetypes=(("PNG", "*.png"), ("所有文件", "*.*")),
        )
        if not output_name:
            return
        output_path = Path(output_name)
        if raw_only_mode:
            if output_path.suffix.lower() not in {".png", ".jpg", ".jpeg", ".bmp"}:
                messagebox.showerror("保存失败", "输出路径必须带图像后缀", parent=self.root)
                return
            if output_path.exists():
                messagebox.showwarning("拒绝覆盖", f"文件已存在，请换一个路径:\n{output_path}", parent=self.root)
                return
            if not cv2.imwrite(str(output_path), self.input_image):
                messagebox.showerror("保存失败", str(output_path), parent=self.root)
                return
            summary_path = output_path.with_suffix(".json")
            saved_summary = dict(self.preview_summary)
            saved_summary.update({
                "calibration_path": str(self.calibration_var.get()),
                "note": self.note_var.get(),
                "saved_utc": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                "saved_input_image": str(output_path),
                "saved_output_image": None,
                "correction_applied": False,
                "workflow": "manual save raw HDMI frame",
            })
            summary_path.write_text(
                json.dumps(saved_summary, indent=2, ensure_ascii=False),
                encoding="utf-8",
            )
            self.status_var.set(f"已手动保存原始帧：{output_path}；摘要：{summary_path}")
            return
        try:
            raw_path, output_path = paired_output_paths(output_path)
        except ValueError as exc:
            messagebox.showerror("保存失败", str(exc), parent=self.root)
            return
        if output_path.exists() or raw_path.exists():
            messagebox.showwarning(
                "拒绝覆盖", f"文件已存在，请换一个路径:\n{raw_path}\n{output_path}",
                parent=self.root,
            )
            return
        if not cv2.imwrite(str(raw_path), self.input_image):
            messagebox.showerror("保存失败", str(raw_path), parent=self.root)
            return
        output_image = (
            rotate_for_display(self.input_image, self.rotate_180_var.get())
            if monitor_mode else self.corrected_image
        )
        if output_image is None or not cv2.imwrite(str(output_path), output_image):
            messagebox.showerror("保存失败", str(output_path), parent=self.root)
            return
        summary_path = output_path.with_suffix(".json")
        saved_summary = dict(self.preview_summary)
        saved_summary["calibration_path"] = str(self.calibration_var.get())
        saved_summary["note"] = self.note_var.get()
        saved_summary["saved_utc"] = datetime.now(timezone.utc).isoformat(
            timespec="milliseconds",
        )
        saved_summary["saved_input_image"] = str(raw_path)
        saved_summary["saved_output_image"] = str(output_path)
        saved_summary["saved_rotated_display_image"] = (
            str(output_path) if monitor_mode and self.rotate_180_var.get() else None
        )
        saved_summary["correction_applied"] = not monitor_mode
        summary_path.write_text(
            json.dumps(saved_summary, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        calibration_path = Path(self.calibration_var.get().strip())
        if self.session_log is not None and calibration_path.is_file():
            append_jsonl(self.session_log, build_session_record(
                input_image=raw_path, output_image=output_path,
                calibration=calibration_path,
                preview_summary=saved_summary, note=self.note_var.get(),
            ))
        if not monitor_mode:
            self.last_pc_raw_path = raw_path
            self.last_pc_corrected_path = output_path
        self.status_var.set(
            f"已保存原始帧: {raw_path}；观察帧: {output_path}；摘要: {summary_path}"
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path)
    parser.add_argument("--calibration", type=Path)
    parser.add_argument("--measured-angle", type=float)
    parser.add_argument("--zero-deg", type=float, default=0.0)
    parser.add_argument("--compensation-sign", type=int, choices=(-1, 1), default=-1)
    parser.add_argument("--balance", type=float, default=0.0)
    parser.add_argument("--output-focal-px", type=float)
    parser.add_argument("--note", default="manual stage offline preview")
    parser.add_argument("--session-log", type=Path)
    parser.add_argument("--mode", choices=PIPELINE_MODES, default="PC黄金模型",
                        help="默认进入原始 HDMI 视频流；PC按钮才抓帧处理，FPGA按钮只监视输出")
    parser.add_argument("--device", type=int,
                        help="optional OpenCV DirectShow HDMI capture device index")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--expected-fps", type=float, default=30.0,
                        help="当前工程 HDMI 视频模式的预期 FPS，仅作配置证据，不冒充采集器实测")
    parser.add_argument("--capture-fps", type=float, default=30.0,
                        help="向采集器请求的 FPS；实际协商结果会单独记录")
    parser.add_argument("--fourcc", default="YUY2",
                        help="向采集器请求的四字符格式，例如 YUY2 或 MJPG")
    parser.add_argument(
        "--backend", choices=("auto", "dshow", "msmf"),
        default="msmf" if os.name == "nt" else "auto",
        help="OpenCV采集后端；本项目采集卡在Windows下MSMF可达30 FPS",
    )
    parser.set_defaults(rotate_180=True)
    rotation = parser.add_mutually_exclusive_group()
    rotation.add_argument("--rotate-180", dest="rotate_180", action="store_true")
    rotation.add_argument("--no-rotate-180", dest="rotate_180", action="store_false")
    parser.add_argument("--fpga-output", type=Path,
                        help="对比模式下的 FPGA HDMI 输出帧")
    args = parser.parse_args(argv)
    root = tk.Tk()
    PreviewApp(
        root, image_path=args.image, calibration_path=args.calibration,
        measured_angle=args.measured_angle, zero_deg=args.zero_deg,
        compensation_sign=args.compensation_sign, session_log=args.session_log,
        balance=args.balance, output_focal_px=args.output_focal_px,
        note=args.note,
        capture_device=args.device, capture_width=args.width,
        capture_height=args.height, capture_requested_fps=args.capture_fps,
        capture_fourcc=args.fourcc, capture_backend=args.backend,
        pipeline_mode=args.mode,
        rotate_180=args.rotate_180, fpga_output_path=args.fpga_output,
        expected_signal_fps=args.expected_fps,
    )
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
