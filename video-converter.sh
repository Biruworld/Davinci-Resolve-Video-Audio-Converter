#!/usr/bin/env python3
"""
DaVinci Converter — GTK4 / libadwaita edition (v2)

A native ffmpeg front-end for prepping footage for DaVinci Resolve:
DNxHR / ProRes proxies, NVENC hardware encodes, and plain audio
extraction — with a queue you can inspect, reorder and re-run.

Dependencies (Arch):
    sudo pacman -S python-gobject gtk4 libadwaita ffmpeg
"""

from __future__ import annotations

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Gtk, Adw, GLib, Gio, Gdk

import os
import re
import json
import shutil
import logging
import subprocess
import threading
import concurrent.futures
import dataclasses
import datetime
from dataclasses import dataclass, field, asdict
from typing import Optional

APP_ID = "sh.asterlusnce.davinciconverter"

CONFIG_DIR = os.path.join(GLib.get_user_config_dir(), "davinci-converter")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
log = logging.getLogger("davinci-converter")


def load_config() -> dict:
    try:
        with open(CONFIG_PATH, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_config(data: dict) -> None:
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(CONFIG_PATH, "w") as f:
            json.dump(data, f, indent=2)
    except OSError as e:
        log.warning("Could not save config: %s", e)


# --------------------------------------------------------------------------
# Static option lists
# --------------------------------------------------------------------------

PRESETS = [
    "Custom",
    "DaVinci Proxy (Fast)",
    "DaVinci Proxy (Quality)",
    "Audio Extract Only",
    "YouTube Upload (H.264)",
    "Archive (ProRes 422 HQ)",
]
VIDEO_MODES = ["Re-encode", "Copy (no re-encode)"]
RESOLUTIONS = ["Original", "1080p", "720p", "540p", "360p", "240p", "144p"]
VIDEO_CODECS = [
    "DNxHR LB (Proxy - Recommended)",
    "DNxHR SQ",
    "DNxHR HQ ⚠ Heavy",
    "ProRes Proxy",
    "ProRes 422 ⚠ Heavy",
    "H.264 (Software)",
    "H.264 (NVENC)",
    "H.265 (NVENC)",
]
QUALITIES = [
    "Medium (Balanced)",
    "Low (Fast, Smaller)",
    "High (Slower, Better)",
    "Ultra (Slowest, Best)",
]
AUDIO_CODECS = ["PCM 16-bit", "PCM 24-bit", "FLAC", "AAC", "MP3"]
SAMPLE_RATES = ["Original", "48000", "44100"]
OUTPUT_TYPES = ["Video + Audio", "Video only", "Audio only"]
FILENAME_MODES = ["Add suffix (_converted)", "Same filename", "Custom suffix"]
PARALLEL_JOB_OPTIONS = ["1 (Safest)", "2", "3", "4"]

PRESET_OVERRIDES = {
    "DaVinci Proxy (Fast)": {
        "video_codec": "DNxHR LB (Proxy - Recommended)",
        "resolution": "540p",
        "quality": "Low (Fast, Smaller)",
        "output_type": "Video + Audio",
    },
    "DaVinci Proxy (Quality)": {
        "video_codec": "DNxHR SQ",
        "resolution": "1080p",
        "quality": "Medium (Balanced)",
        "output_type": "Video + Audio",
    },
    "Audio Extract Only": {
        "output_type": "Audio only",
        "audio_codec": "FLAC",
        "sample_rate": "48000",
    },
    "YouTube Upload (H.264)": {
        "video_codec": "H.264 (Software)",
        "resolution": "1080p",
        "quality": "High (Slower, Better)",
        "audio_codec": "AAC",
        "output_type": "Video + Audio",
    },
    "Archive (ProRes 422 HQ)": {
        "video_codec": "ProRes 422 ⚠ Heavy",
        "resolution": "Original",
        "quality": "Ultra (Slowest, Best)",
        "audio_codec": "PCM 24-bit",
        "output_type": "Video + Audio",
    },
}

VIDEO_EXTS = ("mp4", "mkv", "mov", "avi", "webm", "flv", "m4v", "mpg", "mpeg",
              "wmv", "3gp", "ogv", "mts", "m2ts", "ts")
AUDIO_EXTS = ("mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "wma", "ape",
              "alac", "aiff")


# --------------------------------------------------------------------------
# Settings model — replaces the loose dict from v1 so typos fail fast
# --------------------------------------------------------------------------

@dataclass
class ConversionSettings:
    video_mode: str = VIDEO_MODES[0]
    resolution: str = RESOLUTIONS[0]
    video_codec: str = VIDEO_CODECS[0]
    quality: str = QUALITIES[0]
    convert_audio: bool = True
    audio_codec: str = AUDIO_CODECS[0]
    sample_rate: str = SAMPLE_RATES[0]
    output_type: str = OUTPUT_TYPES[0]
    filename_mode: str = FILENAME_MODES[0]
    custom_suffix: str = "_custom"
    overwrite: bool = False
    use_gpu: bool = False
    dry_run: bool = False
    parallel_jobs: int = 1

    def to_json(self) -> dict:
        return asdict(self)

    @classmethod
    def from_json(cls, data: dict) -> "ConversionSettings":
        valid = {f.name for f in dataclasses.fields(cls)}
        return cls(**{k: v for k, v in data.items() if k in valid})


# --------------------------------------------------------------------------
# ffmpeg mapping helpers
# --------------------------------------------------------------------------

def q_word(quality: str) -> str:
    return quality.split(" ")[0]


def get_resolution_scale(res: str) -> str:
    return {
        "Original": "",
        "1080p": "scale=-2:1080",
        "720p": "scale=-2:720",
        "540p": "scale=-2:540",
        "360p": "scale=-2:360",
        "240p": "scale=-2:240",
        "144p": "scale=-2:144",
    }.get(res, "")


def get_video_codec_name(video_codec: str, use_gpu: bool) -> str:
    if video_codec.startswith("DNxHR"):
        return "dnxhd"
    if video_codec.startswith("ProRes"):
        return "prores_ks"
    if video_codec.startswith("H.264 (NVENC)"):
        return "h264_nvenc" if use_gpu else "libx264"
    if video_codec.startswith("H.264 (Software)"):
        return "libx264"
    if video_codec.startswith("H.265 (NVENC)"):
        return "hevc_nvenc" if use_gpu else "libx265"
    return "libx264"


def get_quality_preset(codec: str, quality: str) -> Optional[str]:
    q = q_word(quality)
    if codec in ("libx264", "libx265"):
        return {"Low": "ultrafast", "Medium": "medium", "High": "slow", "Ultra": "veryslow"}[q]
    if "nvenc" in codec:
        return {"Low": "fast", "Medium": "medium", "High": "slow", "Ultra": "slow"}[q]
    return None


def get_quality_crf(codec: str, quality: str) -> Optional[str]:
    q = q_word(quality)
    if codec in ("libx264", "libx265"):
        return {"Low": "28", "Medium": "23", "High": "18", "Ultra": "15"}[q]
    return None


def get_nvenc_quality(quality: str) -> str:
    q = q_word(quality)
    return {"Low": "23", "Medium": "19", "High": "15", "Ultra": "12"}[q]


def get_dnxhr_profile(video_codec: str) -> Optional[str]:
    if video_codec.startswith("DNxHR LB"):
        return "dnxhr_lb"
    if video_codec.startswith("DNxHR SQ"):
        return "dnxhr_sq"
    if video_codec.startswith("DNxHR HQ"):
        return "dnxhr_hq"
    return None


def get_prores_profile(video_codec: str) -> Optional[str]:
    if video_codec.startswith("ProRes Proxy"):
        return "0"
    if video_codec.startswith("ProRes 422"):
        return "2"
    return None


def get_pix_fmt(video_codec: str) -> str:
    return "yuv422p" if video_codec.startswith(("DNxHR", "ProRes")) else "yuv420p"


def get_audio_codec_name(audio_codec: str) -> str:
    return {
        "PCM 16-bit": "pcm_s16le",
        "PCM 24-bit": "pcm_s24le",
        "FLAC": "flac",
        "AAC": "aac",
        "MP3": "libmp3lame",
    }[audio_codec]


def get_audio_quality(audio_codec: str, quality: str) -> Optional[str]:
    q = q_word(quality)
    if audio_codec in ("AAC", "MP3"):
        return {"Low": "128k", "Medium": "192k", "High": "256k", "Ultra": "320k"}[q]
    if audio_codec == "FLAC":
        return {"Low": "5", "Medium": "8", "High": "10", "Ultra": "12"}[q]
    return None


def get_output_extension(video_codec: str, output_type: str, audio_codec: str) -> str:
    if output_type == "Audio only":
        if audio_codec.startswith("PCM"):
            return "wav"
        return {"FLAC": "flac", "AAC": "m4a", "MP3": "mp3"}.get(audio_codec, "flac")
    if "DNxHR" in video_codec or "ProRes" in video_codec:
        return "mov"
    return "mp4"


def get_suffix(filename_mode: str, output_type: str, custom_suffix: str) -> str:
    if filename_mode.startswith("Add suffix"):
        return "_audio" if output_type == "Audio only" else "_converted"
    if filename_mode.startswith("Same filename"):
        return ""
    return custom_suffix


def get_output_path(input_file: str, output_folder: str, s: ConversionSettings) -> str:
    basename = os.path.basename(input_file)
    filename, _ = os.path.splitext(basename)
    suffix = get_suffix(s.filename_mode, s.output_type, s.custom_suffix)
    ext = get_output_extension(s.video_codec, s.output_type, s.audio_codec)
    return os.path.join(output_folder, f"{filename}{suffix}.{ext}")


def get_file_duration(path: str) -> int:
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=15,
        ).stdout.strip()
        return int(float(out))
    except Exception:
        return 0


def format_time(seconds: float) -> str:
    seconds = int(seconds or 0)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def get_file_size_mb(path: str) -> float:
    try:
        return round(os.path.getsize(path) / 1048576, 1)
    except OSError:
        return 0.0


def check_nvenc_support() -> bool:
    try:
        out = subprocess.run(
            ["ffmpeg", "-hide_banner", "-encoders"],
            capture_output=True, text=True, timeout=10,
        ).stdout
        return "h264_nvenc" in out
    except Exception:
        return False


def build_ffmpeg_cmd(input_file: str, output_file: str, s: ConversionSettings) -> list[str]:
    cmd = ["ffmpeg", "-i", input_file, "-y", "-hide_banner", "-loglevel", "error", "-stats"]

    if s.output_type == "Audio only":
        cmd += ["-vn"]
    elif s.video_mode.startswith("Copy"):
        cmd += ["-c:v", "copy"]
    else:
        vcodec = get_video_codec_name(s.video_codec, s.use_gpu)
        cmd += ["-c:v", vcodec]

        profile = get_dnxhr_profile(s.video_codec)
        if profile:
            cmd += ["-profile:v", profile]

        prores_profile = get_prores_profile(s.video_codec)
        if prores_profile:
            cmd += ["-profile:v", prores_profile]

        cmd += ["-pix_fmt", get_pix_fmt(s.video_codec)]

        scale = get_resolution_scale(s.resolution)
        if scale:
            cmd += ["-vf", scale]

        if vcodec in ("libx264", "libx265"):
            cmd += ["-preset", get_quality_preset(vcodec, s.quality),
                    "-crf", get_quality_crf(vcodec, s.quality)]
        elif "nvenc" in vcodec:
            cmd += ["-preset", get_quality_preset(vcodec, s.quality),
                    "-cq", get_nvenc_quality(s.quality)]

    if s.output_type == "Video only" or not s.convert_audio:
        cmd += ["-an"]
    else:
        acodec = get_audio_codec_name(s.audio_codec)
        cmd += ["-c:a", acodec]
        if s.sample_rate != "Original":
            cmd += ["-ar", s.sample_rate]
        if s.audio_codec in ("AAC", "MP3"):
            cmd += ["-b:a", get_audio_quality(s.audio_codec, s.quality)]
        elif s.audio_codec == "FLAC":
            cmd += ["-compression_level", get_audio_quality(s.audio_codec, s.quality)]

    cmd += [output_file]
    return cmd


# --------------------------------------------------------------------------
# UI helpers
# --------------------------------------------------------------------------

def make_combo_row(title: str, items: list[str], selected: int = 0, subtitle: str = None) -> Adw.ComboRow:
    row = Adw.ComboRow(title=title)
    if subtitle:
        row.set_subtitle(subtitle)
    row.set_model(Gtk.StringList.new(items))
    row.set_selected(selected)
    return row


def combo_value(row: Adw.ComboRow) -> str:
    idx = row.get_selected()
    model = row.get_model()
    return model.get_string(idx) if idx != Gtk.INVALID_LIST_POSITION else ""


def set_combo_value(row: Adw.ComboRow, value: str) -> None:
    model = row.get_model()
    for i in range(model.get_n_items()):
        if model.get_string(i) == value:
            row.set_selected(i)
            return


def is_media_file(path: str) -> bool:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    return ext in VIDEO_EXTS or ext in AUDIO_EXTS


# --------------------------------------------------------------------------
# Main window
# --------------------------------------------------------------------------

class ConverterWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="DaVinci Converter")
        self.set_default_size(680, 820)

        self.input_files: list[str] = []
        self.has_nvenc = check_nvenc_support()
        self.cancel_event = threading.Event()
        self.config = load_config()

        self.toast_overlay = Adw.ToastOverlay()
        self.set_content(self.toast_overlay)

        self.toolbar_view = Adw.ToolbarView()
        self.toast_overlay.set_child(self.toolbar_view)

        header = Adw.HeaderBar()
        self.toolbar_view.add_top_bar(header)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.SLIDE_LEFT_RIGHT)
        self.toolbar_view.set_content(self.stack)

        self.settings_page = self.build_settings_page()
        self.stack.add_named(self.settings_page, "settings")

        self.progress_page = self.build_progress_page()
        self.stack.add_named(self.progress_page, "progress")

        self.setup_drag_and_drop()
        self.restore_settings()

        if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
            GLib.idle_add(self.show_missing_deps_dialog)

    # ---------------- settings page ----------------

    def build_settings_page(self):
        scroller = Gtk.ScrolledWindow(vexpand=True)
        page = Adw.PreferencesPage()
        scroller.set_child(page)

        # Files group — now a real, editable queue instead of a single label
        files_group = Adw.PreferencesGroup(
            title="Media Files",
            description="✅ NVENC available" if self.has_nvenc else "⚠️ NVENC not detected — will use CPU encoding",
        )
        page.add(files_group)

        pick_btn = Gtk.Button(label="Select Files…", valign=Gtk.Align.CENTER)
        pick_btn.add_css_class("suggested-action")
        pick_btn.connect("clicked", self.on_pick_files)

        clear_btn = Gtk.Button(label="Clear", valign=Gtk.Align.CENTER)
        clear_btn.connect("clicked", self.on_clear_files)

        btn_box = Gtk.Box(spacing=6)
        btn_box.append(pick_btn)
        btn_box.append(clear_btn)

        hint_row = Adw.ActionRow(
            title="No files selected",
            subtitle="Drag files onto this window, or select them",
        )
        hint_row.add_suffix(btn_box)
        files_group.add(hint_row)
        self.hint_row = hint_row

        self.files_listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self.files_listbox.add_css_class("boxed-list")
        self.files_listbox.set_visible(False)
        files_group.add(self.files_listbox)

        # Preset
        preset_group = Adw.PreferencesGroup(title="Quick Preset")
        page.add(preset_group)
        self.preset_row = make_combo_row("Load Preset", PRESETS)
        self.preset_row.connect("notify::selected", self.on_preset_changed)
        preset_group.add(self.preset_row)

        # Video
        video_group = Adw.PreferencesGroup(title="Video Settings")
        page.add(video_group)
        self.video_mode_row = make_combo_row("Video Mode", VIDEO_MODES)
        self.video_mode_row.connect("notify::selected", self.on_video_mode_changed)
        self.resolution_row = make_combo_row("Resolution", RESOLUTIONS)
        self.video_codec_row = make_combo_row("Video Codec", VIDEO_CODECS)
        self.video_codec_row.connect("notify::selected", self.on_video_codec_changed)
        self.quality_row = make_combo_row("Quality", QUALITIES)
        for r in (self.video_mode_row, self.resolution_row, self.video_codec_row, self.quality_row):
            video_group.add(r)

        # Audio
        audio_group = Adw.PreferencesGroup(title="Audio Settings")
        page.add(audio_group)
        self.convert_audio_row = Adw.SwitchRow(title="Convert Audio", active=True)
        self.audio_codec_row = make_combo_row("Audio Codec", AUDIO_CODECS)
        self.sample_rate_row = make_combo_row("Sample Rate", SAMPLE_RATES)
        for r in (self.convert_audio_row, self.audio_codec_row, self.sample_rate_row):
            audio_group.add(r)

        # Output
        output_group = Adw.PreferencesGroup(title="Output")
        page.add(output_group)
        self.output_type_row = make_combo_row("Output Type", OUTPUT_TYPES)
        output_group.add(self.output_type_row)

        default_folder = os.path.join(os.path.expanduser("~"), "converted")
        self.output_folder = self.config.get("output_folder", default_folder)
        self.folder_row = Adw.ActionRow(title="Output Folder", subtitle=self.output_folder)
        folder_btn = Gtk.Button(label="Choose…", valign=Gtk.Align.CENTER)
        folder_btn.connect("clicked", self.on_pick_folder)
        open_folder_btn = Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER)
        open_folder_btn.set_tooltip_text("Open output folder")
        open_folder_btn.connect("clicked", lambda _b: self.open_path(self.output_folder))
        self.folder_row.add_suffix(open_folder_btn)
        self.folder_row.add_suffix(folder_btn)
        output_group.add(self.folder_row)

        self.filename_mode_row = make_combo_row("Filename Handling", FILENAME_MODES)
        self.filename_mode_row.connect("notify::selected", self.on_filename_mode_changed)
        output_group.add(self.filename_mode_row)

        self.custom_suffix_row = Adw.EntryRow(title="Custom Suffix", text="_custom")
        self.custom_suffix_row.set_visible(False)
        output_group.add(self.custom_suffix_row)

        self.overwrite_row = Adw.SwitchRow(title="Overwrite Existing Files", active=False)
        output_group.add(self.overwrite_row)

        # Advanced
        advanced_group = Adw.PreferencesGroup(title="Advanced")
        page.add(advanced_group)
        self.use_gpu_row = Adw.SwitchRow(title="Use GPU (NVENC)", active=self.has_nvenc)
        self.use_gpu_row.set_sensitive(self.has_nvenc)
        self.parallel_row = make_combo_row(
            "Parallel Conversions", PARALLEL_JOB_OPTIONS,
            subtitle="Run more than one ffmpeg job at once (uses more CPU/RAM)",
        )
        self.dry_run_row = Adw.SwitchRow(
            title="Dry Run", subtitle="Preview the ffmpeg commands without running them", active=False,
        )
        advanced_group.add(self.use_gpu_row)
        advanced_group.add(self.parallel_row)
        advanced_group.add(self.dry_run_row)

        reset_group = Adw.PreferencesGroup()
        page.add(reset_group)
        reset_btn = Gtk.Button(label="Reset to Defaults")
        reset_btn.connect("clicked", self.on_reset_defaults)
        reset_group.add(reset_btn)

        # Convert button
        action_group = Adw.PreferencesGroup()
        page.add(action_group)
        convert_btn = Gtk.Button(label="Convert Now")
        convert_btn.add_css_class("suggested-action")
        convert_btn.add_css_class("pill")
        convert_btn.set_margin_top(12)
        convert_btn.set_margin_bottom(24)
        convert_btn.connect("clicked", self.on_convert_clicked)
        action_group.add(convert_btn)

        return scroller

    # ---------------- progress page ----------------

    def build_progress_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12,
                       margin_top=24, margin_bottom=24, margin_start=24, margin_end=24)

        self.progress_title = Gtk.Label(label="Converting…", xalign=0)
        self.progress_title.add_css_class("title-2")
        box.append(self.progress_title)

        self.progress_bar = Gtk.ProgressBar(show_text=True)
        box.append(self.progress_bar)

        self.progress_status = Gtk.Label(label="", xalign=0, wrap=True)
        box.append(self.progress_status)

        self.progress_eta = Gtk.Label(label="", xalign=0)
        self.progress_eta.add_css_class("dim-label")
        box.append(self.progress_eta)

        log_scroller = Gtk.ScrolledWindow(vexpand=True)
        self.log_buffer = Gtk.TextBuffer()
        log_view = Gtk.TextView(buffer=self.log_buffer, editable=False, monospace=True)
        log_view.set_top_margin(6)
        log_view.set_bottom_margin(6)
        log_view.set_left_margin(6)
        log_scroller.set_child(log_view)
        log_scroller.add_css_class("card")
        box.append(log_scroller)
        self.log_scroller = log_scroller

        self.cancel_btn = Gtk.Button(label="Cancel")
        self.cancel_btn.add_css_class("destructive-action")
        self.cancel_btn.connect("clicked", self.on_cancel_clicked)
        box.append(self.cancel_btn)

        return box

    # ---------------- drag & drop ----------------

    def setup_drag_and_drop(self):
        drop_target = Gtk.DropTarget.new(Gdk.FileList, Gdk.DragAction.COPY)
        drop_target.connect("drop", self.on_files_dropped)
        self.add_controller(drop_target)

    def on_files_dropped(self, _target, value, _x, _y):
        try:
            files = value.get_files()
        except AttributeError:
            files = [value] if isinstance(value, Gio.File) else []
        added = 0
        for f in files:
            path = f.get_path()
            if path and is_media_file(path) and path not in self.input_files:
                self.input_files.append(path)
                added += 1
        if added:
            self.refresh_files_ui()
            self.show_toast(f"Added {added} file(s)")
        return True

    # ---------------- persistence ----------------

    def restore_settings(self):
        saved = self.config.get("settings")
        if not saved:
            return
        s = ConversionSettings.from_json(saved)
        set_combo_value(self.video_mode_row, s.video_mode)
        set_combo_value(self.resolution_row, s.resolution)
        set_combo_value(self.video_codec_row, s.video_codec)
        set_combo_value(self.quality_row, s.quality)
        self.convert_audio_row.set_active(s.convert_audio)
        set_combo_value(self.audio_codec_row, s.audio_codec)
        set_combo_value(self.sample_rate_row, s.sample_rate)
        set_combo_value(self.output_type_row, s.output_type)
        set_combo_value(self.filename_mode_row, s.filename_mode)
        self.custom_suffix_row.set_text(s.custom_suffix)
        self.overwrite_row.set_active(s.overwrite)
        if self.has_nvenc:
            self.use_gpu_row.set_active(s.use_gpu)
        self.dry_run_row.set_active(s.dry_run)
        set_combo_value(self.parallel_row, PARALLEL_JOB_OPTIONS[max(0, s.parallel_jobs - 1)])

    def persist_settings(self, s: ConversionSettings):
        self.config["settings"] = s.to_json()
        self.config["output_folder"] = self.output_folder
        save_config(self.config)

    def on_reset_defaults(self, _btn):
        defaults = ConversionSettings()
        set_combo_value(self.video_mode_row, defaults.video_mode)
        set_combo_value(self.resolution_row, defaults.resolution)
        set_combo_value(self.video_codec_row, defaults.video_codec)
        set_combo_value(self.quality_row, defaults.quality)
        self.convert_audio_row.set_active(defaults.convert_audio)
        set_combo_value(self.audio_codec_row, defaults.audio_codec)
        set_combo_value(self.sample_rate_row, defaults.sample_rate)
        set_combo_value(self.output_type_row, defaults.output_type)
        set_combo_value(self.filename_mode_row, defaults.filename_mode)
        self.custom_suffix_row.set_text(defaults.custom_suffix)
        self.overwrite_row.set_active(defaults.overwrite)
        self.use_gpu_row.set_active(self.has_nvenc)
        self.dry_run_row.set_active(defaults.dry_run)
        set_combo_value(self.parallel_row, PARALLEL_JOB_OPTIONS[0])
        set_combo_value(self.preset_row, "Custom")
        self.show_toast("Settings reset to defaults")

    # ---------------- event handlers ----------------

    def show_missing_deps_dialog(self):
        dialog = Adw.MessageDialog(
            transient_for=self,
            heading="Missing dependency",
            body="ffmpeg / ffprobe not found.\n\nInstall on Arch:\n  sudo pacman -S ffmpeg",
        )
        dialog.add_response("ok", "OK")
        dialog.present()

    def on_pick_files(self, _btn):
        dialog = Gtk.FileChooserNative.new(
            "Select Media Files", self, Gtk.FileChooserAction.OPEN, "Select", "Cancel"
        )
        dialog.set_select_multiple(True)

        video_filter = Gtk.FileFilter(name="Video Files")
        for ext in VIDEO_EXTS:
            video_filter.add_pattern(f"*.{ext}")

        audio_filter = Gtk.FileFilter(name="Audio Files")
        for ext in AUDIO_EXTS:
            audio_filter.add_pattern(f"*.{ext}")

        all_filter = Gtk.FileFilter(name="All Files")
        all_filter.add_pattern("*")

        dialog.add_filter(video_filter)
        dialog.add_filter(audio_filter)
        dialog.add_filter(all_filter)

        dialog.connect("response", self.on_files_chosen)
        dialog.show()

    def on_files_chosen(self, dialog, response):
        if response == Gtk.ResponseType.ACCEPT:
            files = dialog.get_files()
            for f in files:
                path = f.get_path()
                if path and path not in self.input_files:
                    self.input_files.append(path)
            self.refresh_files_ui()
        dialog.destroy()

    def on_clear_files(self, _btn):
        self.input_files = []
        self.refresh_files_ui()

    def remove_file(self, path):
        if path in self.input_files:
            self.input_files.remove(path)
            self.refresh_files_ui()

    def refresh_files_ui(self):
        n = len(self.input_files)
        while True:
            row = self.files_listbox.get_row_at_index(0)
            if row is None:
                break
            self.files_listbox.remove(row)

        if n == 0:
            self.hint_row.set_title("No files selected")
            self.hint_row.set_subtitle("Drag files onto this window, or select them")
            self.files_listbox.set_visible(False)
            return

        total_mb = sum(get_file_size_mb(p) for p in self.input_files)
        self.hint_row.set_title(f"{n} file(s) selected")
        self.hint_row.set_subtitle(f"{total_mb:.0f} MB total")
        self.files_listbox.set_visible(True)

        for path in self.input_files:
            row = Adw.ActionRow(title=os.path.basename(path), subtitle=path)
            remove_btn = Gtk.Button(icon_name="user-trash-symbolic", valign=Gtk.Align.CENTER)
            remove_btn.add_css_class("flat")
            remove_btn.connect("clicked", lambda _b, p=path: self.remove_file(p))
            row.add_suffix(remove_btn)
            self.files_listbox.append(row)

    def on_pick_folder(self, _btn):
        dialog = Gtk.FileChooserNative.new(
            "Select Output Folder", self, Gtk.FileChooserAction.SELECT_FOLDER, "Select", "Cancel"
        )
        dialog.connect("response", self.on_folder_chosen)
        dialog.show()

    def on_folder_chosen(self, dialog, response):
        if response == Gtk.ResponseType.ACCEPT:
            folder = dialog.get_file().get_path()
            if folder:
                self.output_folder = folder
                self.folder_row.set_subtitle(folder)
                self.config["output_folder"] = folder
                save_config(self.config)
        dialog.destroy()

    def on_filename_mode_changed(self, row, _pspec):
        self.custom_suffix_row.set_visible(combo_value(row).startswith("Custom"))

    def on_video_mode_changed(self, row, _pspec):
        is_copy = combo_value(row).startswith("Copy")
        for r in (self.resolution_row, self.video_codec_row, self.quality_row):
            r.set_sensitive(not is_copy)

    def on_video_codec_changed(self, row, _pspec):
        codec = combo_value(row)
        self.use_gpu_row.set_sensitive(self.has_nvenc and codec.endswith("(NVENC)"))

    def on_preset_changed(self, row, _pspec):
        preset = combo_value(row)
        overrides = PRESET_OVERRIDES.get(preset)
        if not overrides:
            return
        if "video_codec" in overrides:
            set_combo_value(self.video_codec_row, overrides["video_codec"])
        if "resolution" in overrides:
            set_combo_value(self.resolution_row, overrides["resolution"])
        if "quality" in overrides:
            set_combo_value(self.quality_row, overrides["quality"])
        if "audio_codec" in overrides:
            set_combo_value(self.audio_codec_row, overrides["audio_codec"])
        if "sample_rate" in overrides:
            set_combo_value(self.sample_rate_row, overrides["sample_rate"])
        if "output_type" in overrides:
            set_combo_value(self.output_type_row, overrides["output_type"])

    def gather_settings(self) -> ConversionSettings:
        parallel_str = combo_value(self.parallel_row)
        parallel_jobs = int(parallel_str.split(" ")[0]) if parallel_str else 1
        return ConversionSettings(
            video_mode=combo_value(self.video_mode_row),
            resolution=combo_value(self.resolution_row),
            video_codec=combo_value(self.video_codec_row),
            quality=combo_value(self.quality_row),
            convert_audio=self.convert_audio_row.get_active(),
            audio_codec=combo_value(self.audio_codec_row),
            sample_rate=combo_value(self.sample_rate_row),
            output_type=combo_value(self.output_type_row),
            filename_mode=combo_value(self.filename_mode_row),
            custom_suffix=self.custom_suffix_row.get_text(),
            overwrite=self.overwrite_row.get_active(),
            use_gpu=self.use_gpu_row.get_active(),
            dry_run=self.dry_run_row.get_active(),
            parallel_jobs=parallel_jobs,
        )

    def on_convert_clicked(self, _btn):
        if not self.input_files:
            self.show_toast("Pick some files first!")
            return

        s = self.gather_settings()
        self.persist_settings(s)

        if s.video_codec.endswith("(NVENC)") and not self.has_nvenc:
            dialog = Adw.MessageDialog(
                transient_for=self,
                heading="NVENC not available",
                body="Your system doesn't support NVIDIA hardware encoding.\n"
                     "Falling back to software encoding (slower).",
            )
            dialog.add_response("cancel", "Cancel")
            dialog.add_response("continue", "Continue")
            dialog.set_response_appearance("continue", Adw.ResponseAppearance.SUGGESTED)
            dialog.connect("response", self.on_nvenc_warning_response, s)
            dialog.present()
            return

        self.begin_conversion(s)

    def on_nvenc_warning_response(self, dialog, response, s):
        if response == "continue":
            s.use_gpu = False
            self.begin_conversion(s)

    def begin_conversion(self, s: ConversionSettings):
        try:
            os.makedirs(self.output_folder, exist_ok=True)
        except OSError as e:
            self.show_toast(f"Can't create output folder: {e}")
            return
        if not os.access(self.output_folder, os.W_OK):
            self.show_toast(f"Output folder not writable: {self.output_folder}")
            return

        # Guard against clobbering an input file with its own output
        for f in self.input_files:
            if os.path.abspath(get_output_path(f, self.output_folder, s)) == os.path.abspath(f):
                self.show_toast(f"Output would overwrite input: {os.path.basename(f)}. Change filename handling.")
                return

        if s.dry_run:
            self.run_dry_run(s)
            return

        self.cancel_event.clear()
        self.stack.set_visible_child_name("progress")
        self.progress_title.set_label(f"Converting {len(self.input_files)} file(s)…")
        self.progress_bar.set_fraction(0.0)
        self.progress_status.set_label("")
        self.progress_eta.set_label("")
        self.log_buffer.set_text("")

        thread = threading.Thread(target=self.run_conversion, args=(s,), daemon=True)
        thread.start()

    def on_cancel_clicked(self, _btn):
        self.cancel_event.set()
        self.progress_status.set_label("Cancelling remaining jobs…")

    def show_toast(self, text: str, timeout: int = 3):
        toast = Adw.Toast(title=text, timeout=timeout)
        self.toast_overlay.add_toast(toast)

    def open_path(self, path: str):
        if os.path.exists(path):
            subprocess.Popen(["xdg-open", path])
        else:
            self.show_toast("Path does not exist yet")

    def append_log(self, text: str):
        end = self.log_buffer.get_end_iter()
        self.log_buffer.insert(end, text + "\n")
        # Auto-scroll to the bottom
        mark = self.log_buffer.create_mark(None, self.log_buffer.get_end_iter(), False)
        self.log_scroller.get_child().scroll_mark_onscreen(mark)

    # ---------------- dry run ----------------

    def run_dry_run(self, s: ConversionSettings):
        plan_path = os.path.join(
            self.output_folder,
            f"conversion_plan_{datetime.datetime.now():%Y%m%d_%H%M%S}.txt",
        )
        lines = [
            "=" * 41,
            "  DAVINCI CONVERTER - DRY RUN",
            "=" * 41,
            f"Date: {datetime.datetime.now()}",
            f"Total files: {len(self.input_files)}",
            "",
            "Settings:",
            f"  Video: {s.video_codec} | {s.resolution} | {s.quality}",
            f"  Audio: {s.audio_codec} | {s.sample_rate}",
            f"  Output: {s.output_type}",
            f"  GPU: {s.use_gpu}",
            f"  Parallel jobs: {s.parallel_jobs}",
            "",
            "=" * 41,
            "Commands to be executed:",
            "=" * 41,
            "",
        ]
        for input_file in self.input_files:
            output_file = get_output_path(input_file, self.output_folder, s)
            cmd = build_ffmpeg_cmd(input_file, output_file, s)
            lines.append(f"# File: {os.path.basename(input_file)}")
            lines.append(f"# Output: {os.path.basename(output_file)}")
            lines.append(" ".join(cmd))
            lines.append("")

        with open(plan_path, "w") as f:
            f.write("\n".join(lines))

        dialog = Adw.MessageDialog(
            transient_for=self,
            heading="Dry Run — Preview Saved",
            body=f"Plan written to:\n{plan_path}",
        )
        dialog.add_response("open", "Open File")
        dialog.add_response("close", "Close")
        dialog.connect("response", lambda d, r: self.open_path(plan_path) if r == "open" else None)
        dialog.present()

    # ---------------- real conversion (background thread(s)) ----------------

    def _convert_one(self, input_file: str, s: ConversionSettings) -> tuple[str, str, str]:
        """Runs in a worker thread. Returns (status, basename, message)."""
        basename = os.path.basename(input_file)
        if self.cancel_event.is_set():
            return "cancelled", basename, "Cancelled before start"
        if not os.path.isfile(input_file):
            return "failed", basename, "Input file missing"

        file_size = get_file_size_mb(input_file)
        file_duration = get_file_duration(input_file)
        output_file = get_output_path(input_file, self.output_folder, s)

        if os.path.exists(output_file) and not s.overwrite:
            return "skipped", basename, "already exists"

        cmd = build_ffmpeg_cmd(input_file, output_file, s)
        GLib.idle_add(self.append_log, f"▶ {basename}")
        GLib.idle_add(
            self.progress_status.set_label,
            f"{basename}  ·  {file_size}MB  ·  {format_time(file_duration)}",
        )

        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
            )
            for line in proc.stdout:
                if self.cancel_event.is_set():
                    proc.terminate()
                    break
                m = re.search(r"time=([0-9:.]+)", line)
                if m and file_duration:
                    GLib.idle_add(
                        self.progress_status.set_label,
                        f"{basename} → {m.group(1)} / {format_time(file_duration)}",
                    )
            proc.wait()
            ok = proc.returncode == 0
        except FileNotFoundError:
            ok = False
        except Exception as e:
            log.exception("ffmpeg failed for %s", basename)
            return "failed", basename, str(e)

        if self.cancel_event.is_set() and not ok:
            return "cancelled", basename, "Cancelled mid-conversion"

        if ok and os.path.isfile(output_file):
            out_size = get_file_size_mb(output_file)
            if file_size and out_size:
                ratio = file_size / out_size
                msg = f"{out_size}MB — {ratio:.1f}x compression"
            else:
                msg = f"{out_size}MB"
            return "success", basename, msg

        return "failed", basename, "ffmpeg returned an error"

    def run_conversion(self, s: ConversionSettings):
        total = len(self.input_files)
        counts = {"success": 0, "failed": 0, "skipped": 0, "cancelled": 0}
        start_time = datetime.datetime.now()
        completed = 0

        log_path = os.path.join(
            self.output_folder,
            f"conversion_log_{start_time:%Y%m%d_%H%M%S}.txt",
        )
        log_lines = [
            "=" * 41, "  DAVINCI CONVERTER LOG", "=" * 41,
            f"Date: {start_time}", f"Total files: {total}", "",
            "Settings:",
            f"  Video: {s.video_codec} | {s.resolution} | {s.quality}",
            f"  Audio: {s.audio_codec} | {s.sample_rate}",
            f"  Output: {s.output_type}", f"  GPU: {s.use_gpu}",
            f"  Parallel jobs: {s.parallel_jobs}", "",
            "=" * 41, "",
        ]

        def handle_result(status, basename, message):
            nonlocal completed
            completed += 1
            counts[status] = counts.get(status, 0) + 1

            icons = {"success": "✓", "failed": "❌", "skipped": "⏭️", "cancelled": "⚠️"}
            GLib.idle_add(self.append_log, f"{icons.get(status, '?')} {basename}: {message}")
            log_lines.append(f"{status.upper()}: {basename} — {message}")

            fraction = completed / total
            elapsed = (datetime.datetime.now() - start_time).total_seconds()
            avg = elapsed / completed if completed else 0
            remaining = avg * (total - completed)
            GLib.idle_add(self.progress_bar.set_fraction, fraction)
            GLib.idle_add(self.progress_bar.set_text, f"{completed}/{total}")
            if remaining > 1:
                GLib.idle_add(self.progress_eta.set_label, f"Estimated time remaining: {format_time(remaining)}")

        max_workers = max(1, min(s.parallel_jobs, total))
        if max_workers == 1:
            for input_file in self.input_files:
                if self.cancel_event.is_set():
                    log_lines.append("⚠️ Cancelled by user")
                    break
                status, basename, message = self._convert_one(input_file, s)
                handle_result(status, basename, message)
        else:
            with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
                futures = {pool.submit(self._convert_one, f, s): f for f in self.input_files}
                for future in concurrent.futures.as_completed(futures):
                    status, basename, message = future.result()
                    handle_result(status, basename, message)

        elapsed = (datetime.datetime.now() - start_time).total_seconds()
        log_lines += [
            "", "=" * 41, "  CONVERSION SUMMARY", "=" * 41,
            f"Total files: {total}",
            f"Successful: {counts['success']}",
            f"Failed: {counts['failed']}",
            f"Skipped: {counts['skipped']}",
            f"Cancelled: {counts['cancelled']}",
            "",
            f"Total time: {format_time(elapsed)}", "=" * 41,
        ]
        with open(log_path, "w") as f:
            f.write("\n".join(log_lines))

        GLib.idle_add(self.progress_bar.set_fraction, 1.0)
        GLib.idle_add(self.finish_conversion, counts, log_path)

    def finish_conversion(self, counts: dict, log_path: str):
        self.stack.set_visible_child_name("settings")
        self.progress_eta.set_label("")

        success, failed = counts["success"], counts["failed"]
        skipped, cancelled = counts["skipped"], counts["cancelled"]

        if failed == 0 and cancelled == 0:
            heading = "Conversion Complete 🎉"
            body = f"✅ {success} file(s) converted successfully!"
            if skipped:
                body += f"\n⏭️  {skipped} file(s) skipped (already existed)"
        elif cancelled and not failed:
            heading = "Conversion Cancelled"
            body = f"✅ Success: {success}\n⚠️ Cancelled: {cancelled}\n⏭️  Skipped: {skipped}"
        else:
            heading = "Completed with Errors"
            body = f"✅ Success: {success}\n❌ Failed: {failed}\n⏭️  Skipped: {skipped}\n⚠️ Cancelled: {cancelled}"

        dialog = Adw.MessageDialog(
            transient_for=self,
            heading=heading,
            body=f"{body}\n\n📁 {self.output_folder}\n📄 {os.path.basename(log_path)}",
        )
        dialog.add_response("open_folder", "Open Folder")
        dialog.add_response("view_log", "View Log")
        dialog.add_response("close", "Close")

        def handle(d, r):
            if r == "open_folder":
                self.open_path(self.output_folder)
            elif r == "view_log":
                self.open_path(log_path)

        dialog.connect("response", handle)
        dialog.present()


class ConverterApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID)

    def do_activate(self):
        win = self.props.active_window or ConverterWindow(self)
        win.present()


if __name__ == "__main__":
    import sys
    app = ConverterApp()
    app.run(sys.argv)
