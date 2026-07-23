#!/usr/bin/env python3
"""
DaVinci Converter — GTK4 / libadwaita edition
A native rewrite of the yad-based bash converter: same ffmpeg presets
(DNxHR / ProRes proxies, NVENC, plain audio extraction) but as a real
Adwaita app instead of a chain of yad dialogs.

Dependencies (Arch):
    sudo pacman -S python-gobject gtk4 libadwaita ffmpeg
"""

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Gtk, Adw, GLib, Gio

import os
import re
import json
import shutil
import subprocess
import threading
import datetime

APP_ID = "sh.asterlusnce.davinciconverter"

CONFIG_DIR = os.path.join(GLib.get_user_config_dir(), "davinci-converter")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")


def load_config():
    try:
        with open(CONFIG_PATH, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_config(data):
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(CONFIG_PATH, "w") as f:
            json.dump(data, f)
    except OSError:
        pass

# --------------------------------------------------------------------------
# Static option lists (kept identical to the original yad --field choices
# so presets / muscle memory carry over 1:1)
# --------------------------------------------------------------------------

PRESETS = [
    "Custom",
    "DaVinci Proxy (Fast)",
    "DaVinci Proxy (Quality)",
    "Audio Extract Only",
    "YouTube Upload (H.264)",
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
}


# --------------------------------------------------------------------------
# ffmpeg mapping helpers — direct ports of the bash case statements
# --------------------------------------------------------------------------

def q_word(quality):
    """'Low (Fast, Smaller)' -> 'Low'"""
    return quality.split(" ")[0]


def get_resolution_scale(res):
    return {
        "Original": "",
        "1080p": "scale=-2:1080",
        "720p": "scale=-2:720",
        "540p": "scale=-2:540",
        "360p": "scale=-2:360",
        "240p": "scale=-2:240",
        "144p": "scale=-2:144",
    }.get(res, "")


def get_video_codec_name(video_codec, use_gpu):
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


def get_quality_preset(codec, quality):
    q = q_word(quality)
    if codec in ("libx264", "libx265"):
        return {"Low": "ultrafast", "Medium": "medium", "High": "slow", "Ultra": "veryslow"}[q]
    if "nvenc" in codec:
        return {"Low": "fast", "Medium": "medium", "High": "slow", "Ultra": "slow"}[q]
    return None


def get_quality_crf(codec, quality):
    q = q_word(quality)
    if codec in ("libx264", "libx265"):
        return {"Low": "28", "Medium": "23", "High": "18", "Ultra": "15"}[q]
    return None


def get_nvenc_quality(quality):
    q = q_word(quality)
    return {"Low": "23", "Medium": "19", "High": "15", "Ultra": "12"}[q]


def get_dnxhr_profile(video_codec):
    if video_codec.startswith("DNxHR LB"):
        return "dnxhr_lb"
    if video_codec.startswith("DNxHR SQ"):
        return "dnxhr_sq"
    if video_codec.startswith("DNxHR HQ"):
        return "dnxhr_hq"
    return None


def get_prores_profile(video_codec):
    if video_codec.startswith("ProRes Proxy"):
        return "0"
    if video_codec.startswith("ProRes 422"):
        return "2"
    return None


def get_pix_fmt(video_codec):
    return "yuv422p" if video_codec.startswith(("DNxHR", "ProRes")) else "yuv420p"


def get_audio_codec_name(audio_codec):
    return {
        "PCM 16-bit": "pcm_s16le",
        "PCM 24-bit": "pcm_s24le",
        "FLAC": "flac",
        "AAC": "aac",
        "MP3": "libmp3lame",
    }[audio_codec]


def get_audio_quality(audio_codec, quality):
    q = q_word(quality)
    if audio_codec in ("AAC", "MP3"):
        return {"Low": "128k", "Medium": "192k", "High": "256k", "Ultra": "320k"}[q]
    if audio_codec == "FLAC":
        return {"Low": "5", "Medium": "8", "High": "10", "Ultra": "12"}[q]
    return None


def get_output_extension(video_codec, output_type, audio_codec):
    if output_type == "Audio only":
        if audio_codec.startswith("PCM"):
            return "wav"
        return {"FLAC": "flac", "AAC": "m4a", "MP3": "mp3"}.get(audio_codec, "flac")
    if "DNxHR" in video_codec or "ProRes" in video_codec:
        return "mov"
    return "mp4"


def get_suffix(filename_mode, output_type, custom_suffix):
    if filename_mode.startswith("Add suffix"):
        return "_audio" if output_type == "Audio only" else "_converted"
    if filename_mode.startswith("Same filename"):
        return ""
    return custom_suffix


def get_file_duration(path):
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=15,
        ).stdout.strip()
        return int(float(out))
    except Exception:
        return 0


def format_time(seconds):
    seconds = int(seconds or 0)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def get_file_size_mb(path):
    try:
        return os.path.getsize(path) // 1048576
    except OSError:
        return 0


def check_nvenc_support():
    try:
        out = subprocess.run(
            ["ffmpeg", "-hide_banner", "-encoders"],
            capture_output=True, text=True, timeout=10,
        ).stdout
        return "h264_nvenc" in out
    except Exception:
        return False


def build_ffmpeg_cmd(input_file, output_file, s):
    """s = settings dict (see ConverterWindow.gather_settings)"""
    cmd = ["ffmpeg", "-i", input_file, "-y", "-hide_banner", "-loglevel", "error", "-stats"]

    if s["output_type"] == "Audio only":
        cmd += ["-vn"]
    elif s["video_mode"].startswith("Copy"):
        cmd += ["-c:v", "copy"]
    else:
        vcodec = get_video_codec_name(s["video_codec"], s["use_gpu"])
        cmd += ["-c:v", vcodec]

        profile = get_dnxhr_profile(s["video_codec"])
        if profile:
            cmd += ["-profile:v", profile]

        prores_profile = get_prores_profile(s["video_codec"])
        if prores_profile:
            cmd += ["-profile:v", prores_profile]

        cmd += ["-pix_fmt", get_pix_fmt(s["video_codec"])]

        scale = get_resolution_scale(s["resolution"])
        if scale:
            cmd += ["-vf", scale]

        if vcodec in ("libx264", "libx265"):
            cmd += ["-preset", get_quality_preset(vcodec, s["quality"]),
                    "-crf", get_quality_crf(vcodec, s["quality"])]
        elif "nvenc" in vcodec:
            cmd += ["-preset", get_quality_preset(vcodec, s["quality"]),
                    "-cq", get_nvenc_quality(s["quality"])]

    if s["output_type"] == "Video only" or not s["convert_audio"]:
        cmd += ["-an"]
    else:
        acodec = get_audio_codec_name(s["audio_codec"])
        cmd += ["-c:a", acodec]
        if s["sample_rate"] != "Original":
            cmd += ["-ar", s["sample_rate"]]
        if s["audio_codec"] in ("AAC", "MP3"):
            cmd += ["-b:a", get_audio_quality(s["audio_codec"], s["quality"])]
        elif s["audio_codec"] == "FLAC":
            cmd += ["-compression_level", get_audio_quality(s["audio_codec"], s["quality"])]

    cmd += [output_file]
    return cmd


# --------------------------------------------------------------------------
# UI helpers
# --------------------------------------------------------------------------

def make_combo_row(title, items, selected=0, subtitle=None):
    row = Adw.ComboRow(title=title)
    if subtitle:
        row.set_subtitle(subtitle)
    row.set_model(Gtk.StringList.new(items))
    row.set_selected(selected)
    return row


def combo_value(row: Adw.ComboRow):
    idx = row.get_selected()
    model = row.get_model()
    return model.get_string(idx) if idx != Gtk.INVALID_LIST_POSITION else ""


def set_combo_value(row: Adw.ComboRow, value):
    model = row.get_model()
    for i in range(model.get_n_items()):
        if model.get_string(i) == value:
            row.set_selected(i)
            return


# --------------------------------------------------------------------------
# Main window
# --------------------------------------------------------------------------

class ConverterWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="DaVinci Converter")
        self.set_default_size(640, 780)

        self.input_files = []
        self.has_nvenc = check_nvenc_support()
        self.cancel_event = threading.Event()
        self.config = load_config()

        self.toolbar_view = Adw.ToolbarView()
        self.set_content(self.toolbar_view)

        header = Adw.HeaderBar()
        self.toolbar_view.add_top_bar(header)

        # Stack: settings page <-> progress page
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.SLIDE_LEFT_RIGHT)
        self.toolbar_view.set_content(self.stack)

        self.settings_page = self.build_settings_page()
        self.stack.add_named(self.settings_page, "settings")

        self.progress_page = self.build_progress_page()
        self.stack.add_named(self.progress_page, "progress")

        if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
            GLib.idle_add(self.show_missing_deps_dialog)

    # ---------------- settings page ----------------

    def build_settings_page(self):
        scroller = Gtk.ScrolledWindow(vexpand=True)
        page = Adw.PreferencesPage()
        scroller.set_child(page)

        # Files group
        files_group = Adw.PreferencesGroup(
            title="Media Files",
            description="✅ NVENC available" if self.has_nvenc else "⚠️ NVENC not detected — will use CPU encoding",
        )
        page.add(files_group)

        self.files_row = Adw.ActionRow(title="No files selected")
        pick_btn = Gtk.Button(label="Select Files…", valign=Gtk.Align.CENTER)
        pick_btn.add_css_class("suggested-action")
        pick_btn.connect("clicked", self.on_pick_files)
        self.files_row.add_suffix(pick_btn)
        files_group.add(self.files_row)

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
        self.resolution_row = make_combo_row("Resolution", RESOLUTIONS)
        self.video_codec_row = make_combo_row("Video Codec", VIDEO_CODECS)
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
        self.dry_run_row = Adw.SwitchRow(title="Dry Run (preview commands only)", active=False)
        advanced_group.add(self.use_gpu_row)
        advanced_group.add(self.dry_run_row)

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

        log_scroller = Gtk.ScrolledWindow(vexpand=True)
        self.log_buffer = Gtk.TextBuffer()
        log_view = Gtk.TextView(buffer=self.log_buffer, editable=False, monospace=True)
        log_view.set_top_margin(6)
        log_view.set_bottom_margin(6)
        log_view.set_left_margin(6)
        log_scroller.set_child(log_view)
        log_scroller.add_css_class("card")
        box.append(log_scroller)

        self.cancel_btn = Gtk.Button(label="Cancel")
        self.cancel_btn.add_css_class("destructive-action")
        self.cancel_btn.connect("clicked", self.on_cancel_clicked)
        box.append(self.cancel_btn)

        return box

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
        for ext in ("mp4", "mkv", "mov", "avi", "webm", "flv", "m4v", "mpg", "mpeg", "wmv",
                    "3gp", "ogv", "mts", "m2ts", "ts"):
            video_filter.add_pattern(f"*.{ext}")

        audio_filter = Gtk.FileFilter(name="Audio Files")
        for ext in ("mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "wma", "ape", "alac", "aiff"):
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
            self.input_files = [f.get_path() for f in files]
            n = len(self.input_files)
            if n:
                self.files_row.set_title(f"{n} file(s) selected")
                names = ", ".join(os.path.basename(p) for p in self.input_files[:3])
                if n > 3:
                    names += f", +{n - 3} more"
                self.files_row.set_subtitle(names)
        dialog.destroy()

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

    def gather_settings(self):
        return {
            "video_mode": combo_value(self.video_mode_row),
            "resolution": combo_value(self.resolution_row),
            "video_codec": combo_value(self.video_codec_row),
            "quality": combo_value(self.quality_row),
            "convert_audio": self.convert_audio_row.get_active(),
            "audio_codec": combo_value(self.audio_codec_row),
            "sample_rate": combo_value(self.sample_rate_row),
            "output_type": combo_value(self.output_type_row),
            "filename_mode": combo_value(self.filename_mode_row),
            "custom_suffix": self.custom_suffix_row.get_text(),
            "overwrite": self.overwrite_row.get_active(),
            "use_gpu": self.use_gpu_row.get_active(),
            "dry_run": self.dry_run_row.get_active(),
        }

    def on_convert_clicked(self, _btn):
        if not self.input_files:
            self.toast("Pick some files first!")
            return

        s = self.gather_settings()

        if s["video_codec"].endswith("(NVENC)") and not self.has_nvenc:
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
            s["use_gpu"] = False
            self.begin_conversion(s)

    def begin_conversion(self, s):
        os.makedirs(self.output_folder, exist_ok=True)
        if not os.access(self.output_folder, os.W_OK):
            self.toast(f"Output folder not writable: {self.output_folder}")
            return

        if s["dry_run"]:
            self.run_dry_run(s)
            return

        self.cancel_event.clear()
        self.stack.set_visible_child_name("progress")
        self.progress_title.set_label(f"Converting {len(self.input_files)} file(s)…")
        self.progress_bar.set_fraction(0.0)
        self.progress_status.set_label("")
        self.log_buffer.set_text("")

        thread = threading.Thread(target=self.run_conversion, args=(s,), daemon=True)
        thread.start()

    def on_cancel_clicked(self, _btn):
        self.cancel_event.set()
        self.progress_status.set_label("Cancelling after current file…")

    def toast(self, text):
        # Lightweight fallback: use a transient message dialog since this
        # window doesn't own a ToastOverlay.
        dialog = Adw.MessageDialog(transient_for=self, heading="Heads up", body=text)
        dialog.add_response("ok", "OK")
        dialog.present()

    def append_log(self, text):
        end = self.log_buffer.get_end_iter()
        self.log_buffer.insert(end, text + "\n")

    # ---------------- dry run ----------------

    def run_dry_run(self, s):
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
            f"  Video: {s['video_codec']} | {s['resolution']} | {s['quality']}",
            f"  Audio: {s['audio_codec']} | {s['sample_rate']}",
            f"  Output: {s['output_type']}",
            f"  GPU: {s['use_gpu']}",
            "",
            "=" * 41,
            "Commands to be executed:",
            "=" * 41,
            "",
        ]
        for input_file in self.input_files:
            basename = os.path.basename(input_file)
            filename, _ = os.path.splitext(basename)
            suffix = get_suffix(s["filename_mode"], s["output_type"], s["custom_suffix"])
            ext = get_output_extension(s["video_codec"], s["output_type"], s["audio_codec"])
            output_file = os.path.join(self.output_folder, f"{filename}{suffix}.{ext}")
            cmd = build_ffmpeg_cmd(input_file, output_file, s)
            lines.append(f"# File: {basename}")
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
        dialog.connect("response", lambda d, r: subprocess.Popen(["xdg-open", plan_path]) if r == "open" else None)
        dialog.present()

    # ---------------- real conversion (background thread) ----------------

    def run_conversion(self, s):
        total = len(self.input_files)
        success = failed = skipped = 0
        start_time = datetime.datetime.now()

        log_path = os.path.join(
            self.output_folder,
            f"conversion_log_{start_time:%Y%m%d_%H%M%S}.txt",
        )
        log_lines = [
            "=" * 41, "  DAVINCI CONVERTER LOG", "=" * 41,
            f"Date: {start_time}", f"Total files: {total}", "",
            "Settings:",
            f"  Video: {s['video_codec']} | {s['resolution']} | {s['quality']}",
            f"  Audio: {s['audio_codec']} | {s['sample_rate']}",
            f"  Output: {s['output_type']}", f"  GPU: {s['use_gpu']}", "",
            "=" * 41, "",
        ]

        for i, input_file in enumerate(self.input_files, start=1):
            if self.cancel_event.is_set():
                log_lines.append("⚠️ Cancelled by user")
                break
            if not os.path.isfile(input_file):
                continue

            basename = os.path.basename(input_file)
            filename, _ = os.path.splitext(basename)
            file_duration = get_file_duration(input_file)
            file_size = get_file_size_mb(input_file)

            suffix = get_suffix(s["filename_mode"], s["output_type"], s["custom_suffix"])
            ext = get_output_extension(s["video_codec"], s["output_type"], s["audio_codec"])
            output_file = os.path.join(self.output_folder, f"{filename}{suffix}.{ext}")

            if os.path.exists(output_file) and not s["overwrite"]:
                skipped += 1
                GLib.idle_add(self.progress_status.set_label, f"⏭️  Skipped: {basename} (already exists)")
                GLib.idle_add(self.append_log, f"SKIPPED: {basename} (file exists)")
                log_lines.append(f"SKIPPED: {basename} (file exists)")
                continue

            fraction = i / total
            GLib.idle_add(self.progress_bar.set_fraction, fraction)
            GLib.idle_add(self.progress_bar.set_text, f"{i}/{total}")
            GLib.idle_add(
                self.progress_status.set_label,
                f"[{i}/{total}] {basename}  ·  {file_size}MB  ·  {format_time(file_duration)}  ·  {s['quality']}",
            )

            cmd = build_ffmpeg_cmd(input_file, output_file, s)
            log_lines.append(f"Converting: {basename}")
            log_lines.append(f"Command: {' '.join(cmd)}")
            GLib.idle_add(self.append_log, f"▶ {basename}")

            try:
                proc = subprocess.Popen(
                    cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, bufsize=1,
                )
                for line in proc.stdout:
                    if self.cancel_event.is_set():
                        proc.terminate()
                        break
                    m = re.search(r"time=([0-9:.]+)", line)
                    if m:
                        GLib.idle_add(
                            self.progress_status.set_label,
                            f"[{i}/{total}] {basename} → {m.group(1)} / {format_time(file_duration)}",
                        )
                proc.wait()
                ok = proc.returncode == 0
            except FileNotFoundError:
                ok = False

            if ok and os.path.isfile(output_file):
                out_size = get_file_size_mb(output_file)
                if file_size > 0 and out_size > 0:
                    ratio = file_size / out_size
                    msg = f"✓ Done: {basename} ({out_size}MB) — {ratio:.1f}x compression"
                    log_lines.append(f"SUCCESS: {basename} → {out_size}MB ({ratio:.1f}x)")
                else:
                    msg = f"✓ Done: {basename} ({out_size}MB)"
                    log_lines.append(f"SUCCESS: {basename} → {out_size}MB")
                success += 1
            else:
                msg = f"❌ FAILED: {basename}"
                log_lines.append(f"FAILED: {basename}")
                failed += 1

            GLib.idle_add(self.append_log, msg)
            log_lines.append("")

        elapsed = (datetime.datetime.now() - start_time).total_seconds()
        log_lines += [
            "=" * 41, "  CONVERSION SUMMARY", "=" * 41,
            f"Total files: {total}", f"Successful: {success}",
            f"Failed: {failed}", f"Skipped: {skipped}", "",
            f"Total time: {format_time(elapsed)}", "=" * 41,
        ]
        with open(log_path, "w") as f:
            f.write("\n".join(log_lines))

        GLib.idle_add(self.progress_bar.set_fraction, 1.0)
        GLib.idle_add(self.finish_conversion, success, failed, skipped, log_path)

    def finish_conversion(self, success, failed, skipped, log_path):
        self.stack.set_visible_child_name("settings")

        if failed == 0:
            body = f"✅ {success} file(s) converted successfully!"
            if skipped:
                body += f"\n⏭️  {skipped} file(s) skipped (already existed)"
        else:
            body = f"⚠️ Completed with errors\n\n✅ Success: {success}\n❌ Failed: {failed}\n⏭️  Skipped: {skipped}"

        dialog = Adw.MessageDialog(
            transient_for=self,
            heading="Conversion Complete 🎉",
            body=f"{body}\n\n📁 {self.output_folder}\n📄 {os.path.basename(log_path)}",
        )
        dialog.add_response("open_folder", "Open Folder")
        dialog.add_response("view_log", "View Log")
        dialog.add_response("close", "Close")

        def handle(d, r):
            if r == "open_folder":
                subprocess.Popen(["xdg-open", self.output_folder])
            elif r == "view_log":
                subprocess.Popen(["xdg-open", log_path])

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
