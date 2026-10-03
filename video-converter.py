#!/usr/bin/env python3
"""
DaVinci Converter — GTK4 / libadwaita edition (v4)
Resolve Proxy & Transcode Manager for Linux

A native ffmpeg front-end that creates *Resolve-compatible media files*
(proxies, intermediates, masters, delivery exports) from H.264/H.265 footage.

NOTE: this app does NOT register anything inside DaVinci Resolve. It only
writes files; you link/import them in Resolve yourself.

v4 changes (on top of v3):
  - Presets redesigned around Resolve workflows (Proxy / Master / YouTube).
  - Size estimator rebuilt: per-file (duration, resolution, fps), corrected
    DNxHR bitrates, honest ranges, % vs source, preset comparison table.
  - Codec explanations, workflow role labels, validation warnings.
  - Predictable output names (original_proxy_720p_DNxHR_LB.mov), safe
    handling of existing outputs (ask / skip / overwrite / keep both).
  - Real job queue: reorder, remove, cancel, retry, re-run, per-file output.
  - ffmpeg: -progress pipe, stderr captured, no stdin, partial-file output,
    staged CPU fallback (NVDEC -> CPU decode -> CPU encode), no upscaling,
    portrait-safe scaling, NVENC rate-control fix, configurable ffmpeg path.

Dependencies (Arch):
    sudo pacman -S python-gobject gtk4 libadwaita ffmpeg

Dependencies (NixOS, e.g. in your shell.nix / home-manager):
    pkgs.python3.withPackages (ps: [ ps.pygobject3 ])
    pkgs.gtk4
    pkgs.libadwaita
    pkgs.ffmpeg-full   # build with --enable-cuda / nvdec + nvenc support

Optional: set DAVINCI_CONVERTER_FFMPEG=/path/to/ffmpeg, or use the
"FFmpeg path" field under Advanced.
"""

from __future__ import annotations

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Gtk, Adw, GLib, Gio, Gdk, Pango

import os
import json
import shlex
import shutil
import logging
import datetime
import subprocess
import threading
import time
import dataclasses
from collections import deque
from dataclasses import dataclass, field, asdict, replace
from types import SimpleNamespace
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


def esc(text) -> str:
    """Escape dynamic text for Adw rows (titles/subtitles are Pango markup,
    so a filename containing '&' or '<' would otherwise break the row)."""
    return GLib.markup_escape_text(str(text))


# --------------------------------------------------------------------------
# ffmpeg / ffprobe discovery (no hardcoded /usr/bin — NixOS friendly)
# --------------------------------------------------------------------------

TOOLS = SimpleNamespace(ffmpeg="ffmpeg", ffprobe="ffprobe", found=False)


def _is_exe(path: str) -> bool:
    return os.path.isfile(path) and os.access(path, os.X_OK)


def resolve_tools(custom: str = "") -> None:
    """Find ffmpeg/ffprobe: configured path > $DAVINCI_CONVERTER_FFMPEG > PATH."""
    custom = (custom or os.environ.get("DAVINCI_CONVERTER_FFMPEG", "")).strip()
    ffmpeg = None
    if custom:
        p = os.path.expanduser(custom)
        if os.path.isdir(p):
            p = os.path.join(p, "ffmpeg")
        if _is_exe(p):
            ffmpeg = p
    ffmpeg = ffmpeg or shutil.which("ffmpeg")

    ffprobe = None
    if ffmpeg:
        sibling = os.path.join(os.path.dirname(ffmpeg), "ffprobe")
        if _is_exe(sibling):
            ffprobe = sibling
    ffprobe = ffprobe or shutil.which("ffprobe")

    TOOLS.ffmpeg = ffmpeg or "ffmpeg"
    TOOLS.ffprobe = ffprobe or "ffprobe"
    TOOLS.found = bool(ffmpeg and ffprobe)


# --------------------------------------------------------------------------
# Static option lists
# --------------------------------------------------------------------------

VIDEO_MODES = ["Re-encode", "Copy (no re-encode)"]
RESOLUTIONS = ["Original", "1080p", "720p", "540p", "360p", "240p", "144p"]
RESOLUTION_HEIGHTS = {"1080p": 1080, "720p": 720, "540p": 540,
                      "360p": 360, "240p": 240, "144p": 144}
QUALITIES = [
    "Medium (Balanced)",
    "Low (Fast, Smaller)",
    "High (Slower, Better)",
    "Ultra (Slowest, Best)",
]
AUDIO_CODECS = ["PCM 16-bit", "PCM 24-bit", "FLAC", "AAC", "MP3"]
SAMPLE_RATES = ["Original", "48000", "44100"]
OUTPUT_TYPES = ["Video + Audio", "Video only", "Audio only"]
FILENAME_MODES = [
    "Workflow naming (recommended)",
    "Add suffix (_converted)",
    "Custom suffix",
    "Same filename",
]
EXISTS_OPTIONS = ["Ask me", "Skip", "Overwrite", "Keep both (auto-number)"]
PARALLEL_JOB_OPTIONS = ["1 (Safest)", "2", "3", "4"]

VIDEO_EXTS = ("mp4", "mkv", "mov", "avi", "webm", "flv", "m4v", "mpg", "mpeg",
              "wmv", "3gp", "ogv", "mts", "m2ts", "ts")
AUDIO_EXTS = ("mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "wma", "ape",
              "alac", "aiff")

# Warning thresholds
LARGE_ESTIMATE_GB = 20      # warn when the estimated output exceeds this
LARGE_RATIO = 8             # ...or is this many times bigger than the source
LONG_DURATION_S = 30 * 60   # "very long video" for heavy codecs
FREE_SPACE_MARGIN = 0.9     # warn if estimate > 90% of free disk space


# --------------------------------------------------------------------------
# Codec table — ONE place that describes every codec (encoder, profile,
# pixel format, bitrate assumptions, wording). Replaces the ~10 small
# "if video_codec.startswith(...)" helper functions of v3.
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class CodecInfo:
    label: str                      # string shown in UI and stored in config
    family: str                     # dnxhr | prores | h264 | h265
    sw_encoder: str
    hw_encoder: Optional[str] = None
    profile: Optional[str] = None
    pix_fmt: str = "yuv420p"
    intra: bool = False             # fixed-bitrate intermediate codec
    ref_mbps: float = 0.0           # intra: Mbit/s at 1080p / 29.97 fps
    quality_mbps: Optional[dict] = None     # CRF codecs: Mbit/s @1080p by quality
    quality_mbps_hw: Optional[dict] = None  # same, for NVENC
    role_label: str = ""
    name_role: str = ""
    name_tag: str = ""
    heavy: bool = False
    short_desc: str = ""


_GPU_NOTE = " Uses the GPU encoder when 'Use GPU (NVENC)' is on."

CODEC_LIST = [
    CodecInfo(
        "DNxHR LB (Proxy - Recommended)", "dnxhr", "dnxhd", profile="dnxhr_lb",
        pix_fmt="yuv422p", intra=True, ref_mbps=45,
        role_label="Proxy", name_role="proxy", name_tag="DNxHR_LB",
        short_desc="Lightweight editing proxy. Recommended for most Resolve proxy workflows.",
    ),
    CodecInfo(
        "DNxHR SQ", "dnxhr", "dnxhd", profile="dnxhr_sq",
        pix_fmt="yuv422p", intra=True, ref_mbps=145,
        role_label="Intermediate (higher-quality proxy)", name_role="proxy",
        name_tag="DNxHR_SQ",
        short_desc="Higher-quality editing intermediate. Larger files than LB.",
    ),
    CodecInfo(
        "DNxHR HQ ⚠ Heavy", "dnxhr", "dnxhd", profile="dnxhr_hq",
        pix_fmt="yuv422p", intra=True, ref_mbps=220, heavy=True,
        role_label="Master / mezzanine", name_role="master", name_tag="DNxHR_HQ",
        short_desc="High-quality mezzanine format. Very large files. "
                   "Usually unnecessary for ordinary proxy editing.",
    ),
    CodecInfo(
        "ProRes Proxy", "prores", "prores_ks", profile="0",
        pix_fmt="yuv422p10le", intra=True, ref_mbps=45,
        role_label="Proxy", name_role="proxy", name_tag="ProRes_Proxy",
        short_desc="Lightweight ProRes editing proxy.",
    ),
    CodecInfo(
        "ProRes 422 ⚠ Heavy", "prores", "prores_ks", profile="2",
        pix_fmt="yuv422p10le", intra=True, ref_mbps=147, heavy=True,
        role_label="Master / mezzanine", name_role="master", name_tag="ProRes_422",
        short_desc="High-quality intermediate. Large files.",
    ),
    CodecInfo(
        "H.264 (Software)", "h264", "libx264", pix_fmt="yuv420p",
        quality_mbps={"Low": 2.5, "Medium": 6, "High": 12, "Ultra": 20},
        role_label="Delivery / export", name_role="export", name_tag="h264",
        short_desc="Delivery/source codec. Small files, but generally less "
                   "convenient for intensive editing.",
    ),
    CodecInfo(
        "H.264 (NVENC)", "h264", "libx264", hw_encoder="h264_nvenc",
        pix_fmt="yuv420p",
        quality_mbps={"Low": 2.5, "Medium": 6, "High": 12, "Ultra": 20},
        quality_mbps_hw={"Low": 3, "Medium": 7, "High": 14, "Ultra": 22},
        role_label="Delivery / export", name_role="export", name_tag="h264",
        short_desc="Delivery/source codec, fast on NVIDIA GPUs. Small files, but "
                   "less convenient for editing." + _GPU_NOTE,
    ),
    CodecInfo(
        "H.265 (Software)", "h265", "libx265", pix_fmt="yuv420p",
        quality_mbps={"Low": 1.5, "Medium": 3.5, "High": 7, "Ultra": 12},
        role_label="Delivery / export", name_role="export", name_tag="h265",
        short_desc="Delivery/source codec. Smallest files, but slow to encode and "
                   "hard to edit with.",
    ),
    CodecInfo(
        "H.265 (NVENC)", "h265", "libx265", hw_encoder="hevc_nvenc",
        pix_fmt="yuv420p",
        quality_mbps={"Low": 1.5, "Medium": 3.5, "High": 7, "Ultra": 12},
        quality_mbps_hw={"Low": 2, "Medium": 4.5, "High": 9, "Ultra": 14},
        role_label="Delivery / export", name_role="export", name_tag="h265",
        short_desc="Delivery/source codec, fast on NVIDIA GPUs. Small files, but "
                   "less convenient for editing." + _GPU_NOTE,
    ),
]
CODECS = {c.label: c for c in CODEC_LIST}
VIDEO_CODECS = [c.label for c in CODEC_LIST]


def codec_info(label: str) -> CodecInfo:
    return CODECS.get(label) or CODEC_LIST[0]


C_LB, C_SQ, C_HQ = VIDEO_CODECS[0], VIDEO_CODECS[1], VIDEO_CODECS[2]
C_PRPROXY, C_PR422 = VIDEO_CODECS[3], VIDEO_CODECS[4]
C_X264, C_X265 = "H.264 (Software)", "H.265 (Software)"


# --------------------------------------------------------------------------
# Presets — organised by Resolve workflow, not by "speed"
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Preset:
    name: str
    kind: str          # custom | proxy | master | delivery | audio
    summary: str
    overrides: dict


def _p(name, kind, summary, codec, res, quality="Medium (Balanced)", audio="PCM 16-bit"):
    return Preset(name, kind, summary, dict(
        video_mode=VIDEO_MODES[0], video_codec=codec, resolution=res,
        quality=quality, audio_codec=audio, output_type=OUTPUT_TYPES[0],
        convert_audio=True,
    ))


DEFAULT_PRESET = "Proxy — DNxHR LB 720p"

PRESETS = [
    Preset("Custom", "custom", "Choose every setting yourself.", {}),
    _p("Proxy — DNxHR LB 540p", "proxy",
       "Very small files for weak hardware or heavy 4K/8K timelines.", C_LB, "540p"),
    _p(DEFAULT_PRESET, "proxy",
       "Recommended general-purpose editing proxy.", C_LB, "720p"),
    _p("Proxy — DNxHR LB 1080p", "proxy",
       "Sharper proxy for judging focus and detail while editing.", C_LB, "1080p"),
    _p("Proxy — DNxHR SQ 1080p", "proxy",
       "Higher-quality editing intermediate. Noticeably bigger than LB.", C_SQ, "1080p"),
    _p("Master — DNxHR HQ", "master",
       "Original resolution, maximum quality. ⚠ Very large files.",
       C_HQ, "Original", "Ultra (Slowest, Best)", "PCM 24-bit"),
    _p("Master — ProRes 422", "master",
       "Original resolution ProRes 422 mezzanine. ⚠ Large files.",
       C_PR422, "Original", "Ultra (Slowest, Best)", "PCM 24-bit"),
    _p("YouTube — H.264", "delivery",
       "Final upload: 1080p H.264 + AAC.", C_X264, "1080p", "High (Slower, Better)", "AAC"),
    _p("YouTube — H.265", "delivery",
       "Final upload: 1080p H.265 + AAC. Slow to encode on CPU.",
       C_X265, "1080p", "High (Slower, Better)", "AAC"),
    Preset("Audio Extract Only", "audio", "Audio only, FLAC at 48 kHz.",
           {"output_type": "Audio only", "audio_codec": "FLAC", "sample_rate": "48000"}),
]
PRESET_NAMES = [p.name for p in PRESETS]
PRESET_BY_NAME = {p.name: p for p in PRESETS}
COMPARE_PRESETS = [p for p in PRESETS if p.kind in ("proxy", "master", "delivery")]


# --------------------------------------------------------------------------
# Settings model
# --------------------------------------------------------------------------

@dataclass
class ConversionSettings:
    preset: str = DEFAULT_PRESET
    video_mode: str = VIDEO_MODES[0]
    resolution: str = "720p"
    video_codec: str = C_LB
    quality: str = QUALITIES[0]
    convert_audio: bool = True
    audio_codec: str = AUDIO_CODECS[0]
    sample_rate: str = SAMPLE_RATES[0]
    output_type: str = OUTPUT_TYPES[0]
    filename_mode: str = FILENAME_MODES[0]
    custom_suffix: str = "_custom"
    on_exists: str = EXISTS_OPTIONS[0]
    use_gpu: bool = False
    use_hwaccel_decode: bool = False
    dry_run: bool = False
    parallel_jobs: int = 1

    def to_json(self) -> dict:
        return asdict(self)

    @classmethod
    def from_json(cls, data: dict) -> "ConversionSettings":
        data = dict(data)
        # Migrate v3 configs
        if "preset" not in data or data["preset"] not in PRESET_BY_NAME:
            data["preset"] = "Custom"
        if "on_exists" not in data:
            data["on_exists"] = EXISTS_OPTIONS[2] if data.get("overwrite") else EXISTS_OPTIONS[0]
        if data.get("filename_mode") not in FILENAME_MODES:
            data["filename_mode"] = FILENAME_MODES[0]
        if data.get("video_codec") not in CODECS:
            data["video_codec"] = C_LB
        valid = {f.name for f in dataclasses.fields(cls)}
        return cls(**{k: v for k, v in data.items() if k in valid})


def exists_policy(s: ConversionSettings) -> str:
    return {"Ask": "ask", "Ski": "skip", "Ove": "overwrite", "Kee": "rename"}.get(
        s.on_exists[:3], "ask")


# --------------------------------------------------------------------------
# Naming helpers
# --------------------------------------------------------------------------

def q_word(quality: str) -> str:
    return quality.split(" ")[0]


def pick(table: dict, q: str):
    return table.get(q, table["Medium"])


def get_audio_codec_name(audio_codec: str) -> str:
    return {
        "PCM 16-bit": "pcm_s16le", "PCM 24-bit": "pcm_s24le",
        "FLAC": "flac", "AAC": "aac", "MP3": "libmp3lame",
    }[audio_codec]


def get_audio_quality(audio_codec: str, quality: str) -> Optional[str]:
    q = q_word(quality)
    if audio_codec in ("AAC", "MP3"):
        return pick({"Low": "128k", "Medium": "192k", "High": "256k", "Ultra": "320k"}, q)
    if audio_codec == "FLAC":
        return pick({"Low": "5", "Medium": "8", "High": "10", "Ultra": "12"}, q)
    return None


def get_output_extension(video_codec: str, output_type: str, audio_codec: str) -> str:
    if output_type == "Audio only":
        if audio_codec.startswith("PCM"):
            return "wav"
        return {"FLAC": "flac", "AAC": "m4a", "MP3": "mp3"}.get(audio_codec, "flac")
    if codec_info(video_codec).family in ("dnxhr", "prores"):
        return "mov"
    return "mp4"


def workflow_suffix(s: ConversionSettings) -> str:
    """original.mp4 -> original_proxy_720p_DNxHR_LB.mov, _master_DNxHR_HQ, _youtube_h264 ..."""
    if s.video_mode.startswith("Copy"):
        return "_copy"
    ci = codec_info(s.video_codec)
    role = ci.name_role
    if ci.family in ("h264", "h265") and s.preset.startswith("YouTube"):
        role = "youtube"
    parts = [role]
    if s.resolution != "Original" and not (role == "youtube" and s.resolution == "1080p"):
        parts.append(s.resolution)
    parts.append(ci.name_tag)
    return "_" + "_".join(parts)


def get_suffix(s: ConversionSettings) -> str:
    mode = s.filename_mode
    if mode.startswith("Same"):
        return ""
    if mode.startswith("Custom"):
        return s.custom_suffix
    if s.output_type == "Audio only":
        return "_audio"
    if mode.startswith("Add suffix"):
        return "_converted"
    return workflow_suffix(s)


def get_output_path(input_file: str, output_folder: str, s: ConversionSettings) -> str:
    stem = os.path.splitext(os.path.basename(input_file))[0]
    ext = get_output_extension(s.video_codec, s.output_type, s.audio_codec)
    return os.path.join(output_folder, f"{stem}{get_suffix(s)}.{ext}")


def unique_path(path: str, taken: set) -> str:
    root, ext = os.path.splitext(path)
    n = 1
    while True:
        cand = f"{root}_{n}{ext}"
        if cand not in taken and not os.path.exists(cand):
            return cand
        n += 1


def partial_path(path: str) -> str:
    """ffmpeg writes here; renamed to the real name only on success, so a
    cancelled/crashed encode never leaves a half-written .mov for Resolve."""
    root, ext = os.path.splitext(path)
    return f"{root}.partial{ext}"


def format_time(seconds: float) -> str:
    seconds = int(seconds or 0)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def format_size(mb: float) -> str:
    if mb >= 1024 * 1024:
        return f"{mb / 1048576:.2f} TB"
    if mb >= 1024:
        return f"{mb / 1024:.1f} GB"
    return f"{mb:.0f} MB"


def get_file_size_mb(path: str) -> float:
    try:
        return os.path.getsize(path) / 1048576
    except OSError:
        return 0.0


def get_free_mb(folder: str) -> Optional[float]:
    path = os.path.abspath(folder)
    while path and not os.path.exists(path):
        parent = os.path.dirname(path)
        if parent == path:
            return None
        path = parent
    try:
        return shutil.disk_usage(path).free / 1048576
    except OSError:
        return None


def is_media_file(path: str) -> bool:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    return ext in VIDEO_EXTS or ext in AUDIO_EXTS


# --------------------------------------------------------------------------
# Probing
# --------------------------------------------------------------------------

@dataclass
class MediaInfo:
    duration: float = 0.0
    width: int = 0
    height: int = 0
    fps: float = 0.0
    vcodec: str = ""
    size_mb: float = 0.0

    @property
    def ok(self) -> bool:
        return self.duration > 0


def probe_media(path: str) -> MediaInfo:
    """One ffprobe call per file: duration, first video stream's size/fps/codec."""
    info = MediaInfo(size_mb=get_file_size_mb(path))
    try:
        res = subprocess.run(
            [TOOLS.ffprobe, "-v", "error", "-show_entries",
             "format=duration:stream=codec_type,codec_name,width,height,avg_frame_rate",
             "-of", "json", path],
            capture_output=True, text=True, timeout=30,
        )
        data = json.loads(res.stdout or "{}")
    except (OSError, subprocess.SubprocessError, ValueError):
        return info
    try:
        info.duration = float((data.get("format") or {}).get("duration") or 0)
    except (TypeError, ValueError):
        info.duration = 0.0
    for st in data.get("streams") or []:
        if st.get("codec_type") == "video" and st.get("width"):
            info.width = int(st.get("width") or 0)
            info.height = int(st.get("height") or 0)
            info.vcodec = st.get("codec_name") or ""
            num, _, den = (st.get("avg_frame_rate") or "0/1").partition("/")
            try:
                info.fps = float(num) / float(den) if float(den) else 0.0
            except ValueError:
                info.fps = 0.0
            break
    return info


CODEC_PRETTY = {"h264": "H.264", "hevc": "H.265", "prores": "ProRes", "dnxhd": "DNxHD/HR",
                "vp9": "VP9", "av1": "AV1", "mpeg4": "MPEG-4"}


def describe_media(info: Optional[MediaInfo]) -> str:
    if info is None:
        return "Reading file info…"
    bits = []
    if info.vcodec:
        bits.append(CODEC_PRETTY.get(info.vcodec, info.vcodec.upper()))
    if info.width:
        bits.append(f"{info.width}×{info.height}")
    if info.fps:
        bits.append(f"{info.fps:.2f}".rstrip("0").rstrip(".") + " fps")
    bits.append(format_size(info.size_mb))
    if info.duration:
        bits.append(format_time(info.duration))
    return " · ".join(bits)


# --------------------------------------------------------------------------
# Hardware detection
# --------------------------------------------------------------------------

def _ffmpeg_list(arg: str) -> str:
    try:
        return subprocess.run(
            [TOOLS.ffmpeg, "-hide_banner", arg],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def check_nvenc_support() -> bool:
    """Does this ffmpeg build have NVENC *encoders*? (Build support only —
    check_nvenc_works() verifies a GPU is really usable.)"""
    return "h264_nvenc" in _ffmpeg_list("-encoders")


def check_nvenc_works() -> bool:
    """Tiny real test encode, so a machine without an NVIDIA GPU doesn't
    advertise NVENC just because ffmpeg was built with it."""
    try:
        r = subprocess.run(
            [TOOLS.ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi",
             "-i", "color=c=black:s=256x256:d=0.2:r=25",
             "-c:v", "h264_nvenc", "-f", "null", "-"],
            capture_output=True, text=True, timeout=20,
        )
        return r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def check_nvdec_support() -> bool:
    """Does ffmpeg advertise the 'cuda' hwaccel (NVDEC)? Independent of NVENC.
    Whether a given file decodes on the GPU is only known at run time, which
    is why jobs fall back to CPU decode automatically."""
    return "cuda" in _ffmpeg_list("-hwaccels").lower()


# --------------------------------------------------------------------------
# Output-size estimation
#
# Ballpark data rates, NOT exact: real size depends on content, motion and
# encoder version. DNxHR/ProRes are (near) constant-bitrate per resolution &
# fps, so those are fairly predictable; CRF-based H.264/H.265 are not.
# --------------------------------------------------------------------------

BASE_PIXELS_1080P = 1920 * 1080
BASE_FPS = 29.97

PCM_KBPS = {"PCM 16-bit": 1536, "PCM 24-bit": 2304}          # 48 kHz stereo
FLAC_APPROX_KBPS = {"Low": 700, "Medium": 850, "High": 950, "Ultra": 1000}
COPIED_AUDIO_MBPS = 0.192                                    # guess when audio is copied


def output_pixels(resolution: str, info: MediaInfo) -> float:
    """Pixels of the encoded frame. Never upscales (matches scale_filter())."""
    w, h = (info.width, info.height) if info.width and info.height else (1920, 1080)
    target = RESOLUTION_HEIGHTS.get(resolution)
    if not target:
        return w * h
    short = min(w, h)
    if short <= target:
        return w * h
    return w * h * (target / short) ** 2


def estimate_audio_mbps(s: ConversionSettings) -> float:
    if not s.convert_audio and s.output_type != "Audio only":
        return COPIED_AUDIO_MBPS
    if s.audio_codec in PCM_KBPS:
        return PCM_KBPS[s.audio_codec] / 1000
    q = q_word(s.quality)
    if s.audio_codec == "FLAC":
        return pick(FLAC_APPROX_KBPS, q) / 1000
    kbps = get_audio_quality(s.audio_codec, s.quality)
    return int(kbps.rstrip("k")) / 1000 if kbps else 0.0


def estimate_rates(info: MediaInfo, s: ConversionSettings) -> Optional[tuple]:
    """(video_mbps, audio_mbps) for one file, or None if it can't be estimated."""
    if not info.ok:
        return None
    audio = 0.0 if s.output_type == "Video only" else estimate_audio_mbps(s)
    if s.output_type == "Audio only":
        return 0.0, audio
    if s.video_mode.startswith("Copy"):
        return info.size_mb * 8 / info.duration, 0.0   # output ≈ source
    ci = codec_info(s.video_codec)
    ratio = output_pixels(s.resolution, info) / BASE_PIXELS_1080P
    if ci.intra:
        fps = info.fps if info.fps > 0 else BASE_FPS
        video = ci.ref_mbps * ratio * min(max(fps / BASE_FPS, 0.5), 4.0)
    else:
        table = ci.quality_mbps_hw if (s.use_gpu and ci.hw_encoder and ci.quality_mbps_hw) \
            else ci.quality_mbps
        video = pick(table, q_word(s.quality)) * ratio
    return video, audio


def spread_for(s: ConversionSettings) -> tuple:
    """(low, high) multipliers around the estimate — how unsure we are."""
    if s.output_type == "Audio only":
        return 0.9, 1.1
    if s.video_mode.startswith("Copy"):
        return 0.95, 1.05
    if codec_info(s.video_codec).intra:
        return 0.85, 1.2        # near-constant bitrate
    return 0.5, 2.0             # CRF: strongly content-dependent


@dataclass
class SizeEstimate:
    est_mb: float
    low_mb: float
    high_mb: float
    source_mb: float
    duration: float
    video_mbit: float           # Mbit/s × seconds, summed over files
    audio_mbit: float
    counted: int
    total: int

    @property
    def video_mbps(self) -> float:
        return self.video_mbit / self.duration if self.duration else 0.0

    @property
    def audio_mbps(self) -> float:
        return self.audio_mbit / self.duration if self.duration else 0.0

    @property
    def change_pct(self) -> Optional[float]:
        return (self.est_mb / self.source_mb - 1) * 100 if self.source_mb else None


def estimate_total(infos: list, s: ConversionSettings, total_files: Optional[int] = None) -> Optional[SizeEstimate]:
    """estimated_size = duration × bitrate / 8, summed per file."""
    est = vid = aud = src = dur = 0.0
    counted = 0
    for info in infos:
        rates = estimate_rates(info, s)
        if rates is None:
            continue
        v, a = rates
        est += (v + a) * info.duration / 8
        vid += v * info.duration
        aud += a * info.duration
        src += info.size_mb
        dur += info.duration
        counted += 1
    if not counted:
        return None
    lo, hi = spread_for(s)
    return SizeEstimate(est, est * lo, est * hi, src, dur, vid, aud,
                        counted, total_files if total_files is not None else len(infos))


def change_text(est: SizeEstimate) -> str:
    pct = est.change_pct
    if pct is None:
        return ""
    if abs(pct) < 5:
        return "≈ same as source"
    return f"{pct:+.0f}% vs source"


# --------------------------------------------------------------------------
# Validation — warn, never block
# --------------------------------------------------------------------------

@dataclass
class Warn:
    text: str
    confirm: bool = False   # ask for confirmation before queueing


def validate_choices(s: ConversionSettings, infos: list, est: Optional[SizeEstimate],
                     free_mb: Optional[float]) -> list:
    warns: list = []
    ci = codec_info(s.video_codec)
    audio_only = s.output_type == "Audio only"
    copy = s.video_mode.startswith("Copy")
    encoding_video = not audio_only and not copy
    ext = get_output_extension(s.video_codec, s.output_type, s.audio_codec)
    name = ci.name_tag.replace("_", " ")

    if copy and not audio_only:
        warns.append(Warn("ℹ Stream copy keeps the original video codec — this is not an editing proxy."))

    if encoding_video:
        height = RESOLUTION_HEIGHTS.get(s.resolution)
        total_dur = sum(i.duration for i in infos)

        if ci.heavy:
            warns.append(Warn("⚠ Large intermediate — not normally required for proxy editing."))
            if height:
                warns.append(Warn(
                    f"⚠ {name} at {s.resolution}: a master-grade codec on downscaled video. "
                    "For proxies, DNxHR LB/SQ is far smaller with no practical editing benefit.",
                    confirm=True))
            if total_dur > LONG_DURATION_S:
                extra = f" Estimated total: ~{format_size(est.est_mb)}." if est else ""
                warns.append(Warn(
                    f"⚠ {name} on {format_time(total_dur)} of footage will take a lot of disk space.{extra}",
                    confirm=True))
        if height and height <= 360 and (ci.heavy or ci.name_tag == "DNxHR_SQ"):
            warns.append(Warn(
                f"⚠ {name} at {s.resolution} doesn't make much sense — at this size the extra "
                "bitrate buys nothing visible. DNxHR LB is enough.", confirm=True))
        if height:
            small = sum(1 for i in infos if i.width and min(i.width, i.height) < height)
            if small:
                warns.append(Warn(f"ℹ {small} file(s) are already smaller than {s.resolution}; "
                                  "they won't be upscaled."))

    if est:
        if est.est_mb > LARGE_ESTIMATE_GB * 1024 or (
                est.source_mb and est.est_mb > est.source_mb * LARGE_RATIO and est.est_mb > 2048):
            ratio = f" ({est.est_mb / est.source_mb:.0f}× the source)" if est.source_mb else ""
            warns.append(Warn(f"⚠ Estimated output ~{format_size(est.est_mb)}{ratio} — very large.",
                              confirm=True))
        if free_mb and est.est_mb > free_mb * FREE_SPACE_MARGIN:
            warns.append(Warn(f"⛔ Estimated output ~{format_size(est.est_mb)} but only "
                              f"{format_size(free_mb)} is free in the output folder.", confirm=True))

    audio_encoded = s.output_type != "Video only" and (s.convert_audio or audio_only)
    if audio_encoded and not audio_only:
        if ext == "mp4" and s.audio_codec.startswith("PCM"):
            warns.append(Warn("⚠ PCM audio in MP4 is non-standard — ffmpeg writes it, but many players "
                              "and upload sites choke on it. Use AAC for H.264/H.265.", confirm=True))
        if ext == "mov" and s.audio_codec == "FLAC":
            warns.append(Warn("⛔ FLAC can't be stored in a .mov — the encode will fail. "
                              "Use PCM (best for Resolve).", confirm=True))
        if ext == "mov" and s.audio_codec == "MP3":
            warns.append(Warn("⚠ MP3 audio in a .mov may not be readable in Resolve. PCM is safest.",
                              confirm=True))
        if ext == "mov" and s.audio_codec == "AAC":
            warns.append(Warn("ℹ Resolve on Linux often can't decode AAC audio. PCM is safer for proxies."))
    return warns


# --------------------------------------------------------------------------
# ffmpeg command construction
# --------------------------------------------------------------------------

X26_PRESET = {"Low": "ultrafast", "Medium": "medium", "High": "slow", "Ultra": "veryslow"}
CRF_H264 = {"Low": "28", "Medium": "23", "High": "18", "Ultra": "15"}
CRF_H265 = {"Low": "31", "Medium": "28", "High": "23", "Ultra": "20"}   # x265 CRF runs ~5 higher than x264
NVENC_PRESET = {"Low": "p3", "Medium": "p5", "High": "p6", "Ultra": "p7"}
NVENC_CQ = {"Low": "23", "Medium": "19", "High": "15", "Ultra": "12"}


def scale_filter(resolution: str) -> str:
    """Scale the SHORT side to the target: works for portrait video, keeps
    aspect (-2 = even), and never upscales. Evaluated by ffmpeg after
    auto-rotation, so phone footage with rotation metadata is handled."""
    t = RESOLUTION_HEIGHTS.get(resolution)
    if not t:
        return ""
    # commas are escaped for the filtergraph parser (no shell is involved)
    return (f"scale=w=if(gte(iw\\,ih)\\,-2\\,min({t}\\,iw)):"
            f"h=if(gte(iw\\,ih)\\,min({t}\\,ih)\\,-2)")


def video_args(s: ConversionSettings) -> list:
    ci = codec_info(s.video_codec)
    q = q_word(s.quality)
    encoder = ci.hw_encoder if (s.use_gpu and ci.hw_encoder) else ci.sw_encoder
    args = ["-c:v", encoder]
    if ci.family == "dnxhr":
        args += ["-profile:v", ci.profile]
    elif ci.family == "prores":
        args += ["-profile:v", ci.profile, "-vendor", "apl0"]
    elif encoder in ("libx264", "libx265"):
        crf = CRF_H264 if encoder == "libx264" else CRF_H265
        args += ["-preset", pick(X26_PRESET, q), "-crf", pick(crf, q)]
        if encoder == "libx265":        # x265 ignores -loglevel; keep stderr = real errors only
            args += ["-x265-params", "log-level=error"]
    else:  # nvenc: -cq only takes effect with -rc vbr
        args += ["-preset", pick(NVENC_PRESET, q), "-rc", "vbr",
                 "-cq", pick(NVENC_CQ, q), "-b:v", "0"]
    args += ["-pix_fmt", ci.pix_fmt]
    if ci.family == "h265":
        args += ["-tag:v", "hvc1"]      # QuickTime/Apple friendly tag
    flt = scale_filter(s.resolution)
    if flt:
        args += ["-vf", flt]
    return args


def audio_args(s: ConversionSettings) -> list:
    args = ["-c:a", get_audio_codec_name(s.audio_codec)]
    if s.sample_rate != "Original":
        args += ["-ar", s.sample_rate]
    if s.audio_codec in ("AAC", "MP3"):
        args += ["-b:a", get_audio_quality(s.audio_codec, s.quality)]
    elif s.audio_codec == "FLAC":
        args += ["-compression_level", get_audio_quality(s.audio_codec, s.quality)]
    return args


def build_ffmpeg_cmd(input_file: str, output_file: str, s: ConversionSettings) -> list:
    """Argument LIST (never a shell string). Global options first, then
    input options, -i, then output options — the order ffmpeg expects."""
    audio_only = s.output_type == "Audio only"
    copy_video = s.video_mode.startswith("Copy")
    cmd = [TOOLS.ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error",
           "-nostats", "-progress", "pipe:1", "-y"]

    # NVDEC decode of the *source*. No -hwaccel_output_format: decoded frames
    # return to system memory so scale / dnxhd / prores_ks / libx264 / nvenc
    # all keep working. Pointless for audio-only or stream copy.
    if s.use_hwaccel_decode and not audio_only and not copy_video:
        cmd += ["-hwaccel", "cuda"]

    cmd += ["-i", input_file]

    if audio_only:
        cmd += ["-vn", "-map", "0:a:0?"]
    else:
        cmd += ["-map", "0:v:0?"]
        if s.output_type == "Video only":
            cmd += ["-an"]
        else:
            cmd += ["-map", "0:a?"]
        cmd += ["-c:v", "copy"] if copy_video else video_args(s)

    if s.output_type != "Video only":
        if s.convert_audio or audio_only:
            cmd += audio_args(s)
        else:
            cmd += ["-c:a", "copy"]

    if os.path.splitext(output_file)[1].lower() in (".mp4", ".m4a"):
        cmd += ["-movflags", "+faststart"]

    cmd.append(output_file)
    return cmd


def fallback_attempts(s: ConversionSettings) -> list:
    """Run order: as configured -> CPU decode -> CPU decode + CPU encode."""
    attempts = [s]
    ci = codec_info(s.video_codec)
    video = s.output_type != "Audio only" and not s.video_mode.startswith("Copy")
    if video and s.use_hwaccel_decode:
        attempts.append(replace(s, use_hwaccel_decode=False))
    if video and s.use_gpu and ci.hw_encoder:
        s3 = replace(s, use_hwaccel_decode=False, use_gpu=False)
        if s3 not in attempts:
            attempts.append(s3)
    return attempts


def is_non_gpu_failure(tail: str) -> bool:
    """Errors a CPU retry cannot fix — don't redo a long encode for these."""
    t = tail.lower()
    return any(m in t for m in ("no space left", "permission denied",
                                "no such file", "read-only file system"))


# --------------------------------------------------------------------------
# Jobs
# --------------------------------------------------------------------------

QUEUED, RUNNING, DONE, FAILED, SKIPPED, CANCELLED = (
    "queued", "running", "done", "failed", "skipped", "cancelled")
TERMINAL = (DONE, FAILED, SKIPPED, CANCELLED)


@dataclass(eq=False)
class Job:
    id: int
    input_path: str
    output_path: str
    settings: ConversionSettings
    status: str = QUEUED
    progress: float = 0.0
    message: str = ""
    error_tail: str = ""
    duration: float = 0.0
    last_cmd: list = field(default_factory=list)
    cancel_requested: bool = False
    proc: Optional[subprocess.Popen] = None


# --------------------------------------------------------------------------
# UI helpers
# --------------------------------------------------------------------------

def make_combo_row(title: str, items: list, selected: int = 0, subtitle: str = None) -> Adw.ComboRow:
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


def parallel_label(n: int) -> str:
    return PARALLEL_JOB_OPTIONS[min(max(n, 1), len(PARALLEL_JOB_OPTIONS)) - 1]


STATUS_ICONS = {
    QUEUED: ("document-open-recent-symbolic", []),
    RUNNING: ("media-playback-start-symbolic", ["accent"]),
    DONE: ("emblem-ok-symbolic", ["success"]),
    FAILED: ("dialog-error-symbolic", ["error"]),
    SKIPPED: ("go-next-symbolic", ["dim-label"]),
    CANCELLED: ("process-stop-symbolic", ["warning"]),
}


# --------------------------------------------------------------------------
# Main window
# --------------------------------------------------------------------------

class ConverterWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="DaVinci Converter")
        self.set_default_size(720, 900)

        self._ready = False
        self._applying = False
        self.config = load_config()
        resolve_tools(self.config.get("ffmpeg_path", ""))

        self.input_files: list = []
        self.media_info: dict = {}          # path -> MediaInfo (main thread only)
        self._probing: set = set()
        self.file_rows: dict = {}
        self.has_nvenc = check_nvenc_support() if TOOLS.found else False
        self.has_nvdec = check_nvdec_support() if TOOLS.found else False

        self.jobs: list = []
        self.jobs_lock = threading.Lock()
        self.active_workers = 0
        self.job_widgets: dict = {}
        self._job_counter = 0
        self.batch_started: Optional[float] = None
        self.run_log_lines: list = []
        self._chooser = None                # keep FileChooserNative alive!
        self._compare_children: list = []

        self.toast_overlay = Adw.ToastOverlay()
        self.set_content(self.toast_overlay)
        self.toolbar_view = Adw.ToolbarView()
        self.toast_overlay.set_child(self.toolbar_view)

        header = Adw.HeaderBar()
        self.back_btn = Gtk.Button(icon_name="go-previous-symbolic")
        self.back_btn.set_tooltip_text("Back to settings")
        self.back_btn.connect("clicked", lambda _b: self.show_page("settings"))
        self.back_btn.set_visible(False)
        header.pack_start(self.back_btn)
        self.queue_btn = Gtk.Button(label="Queue")
        self.queue_btn.connect("clicked", lambda _b: self.show_page("queue"))
        self.queue_btn.set_visible(False)
        header.pack_end(self.queue_btn)
        self.toolbar_view.add_top_bar(header)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.SLIDE_LEFT_RIGHT)
        self.toolbar_view.set_content(self.stack)
        self.stack.add_named(self.build_settings_page(), "settings")
        self.stack.add_named(self.build_queue_page(), "queue")

        self.setup_drag_and_drop()
        self.restore_settings()
        self._ready = True
        self.refresh_derived()
        self.update_hw_description()

        if not TOOLS.found:
            GLib.idle_add(self.show_missing_deps_dialog)
        else:
            self.verify_nvenc_async()

    # ---------------- small utilities ----------------

    def ui(self, fn, *args):
        """Run fn(*args) on the GTK main thread, exactly once."""
        def _call():
            fn(*args)
            return False
        GLib.idle_add(_call)

    def show_toast(self, text: str, timeout: int = 3):
        self.toast_overlay.add_toast(Adw.Toast(title=text, timeout=timeout))

    def open_path(self, path: str):
        if os.path.exists(path):
            subprocess.Popen(["xdg-open", path])
        else:
            self.show_toast("Path does not exist yet")

    def confirm(self, heading, body, ok_label, on_ok, destructive=False):
        d = Adw.MessageDialog(transient_for=self, heading=heading, body=body)
        d.add_response("cancel", "Cancel")
        d.add_response("ok", ok_label)
        d.set_response_appearance(
            "ok", Adw.ResponseAppearance.DESTRUCTIVE if destructive
            else Adw.ResponseAppearance.SUGGESTED)
        d.set_default_response("cancel")
        d.set_close_response("cancel")
        d.connect("response", lambda _d, r: on_ok() if r == "ok" else None)
        d.present()

    def show_text_window(self, title: str, text: str):
        win = Adw.Window(title=title, transient_for=self, modal=True,
                         default_width=700, default_height=440)
        tv = Adw.ToolbarView()
        tv.add_top_bar(Adw.HeaderBar())
        buf = Gtk.TextBuffer()
        buf.set_text(text)
        view = Gtk.TextView(buffer=buf, editable=False, monospace=True,
                            wrap_mode=Gtk.WrapMode.WORD_CHAR)
        for m in ("top", "bottom", "left", "right"):
            getattr(view, f"set_{m}_margin")(10)
        sc = Gtk.ScrolledWindow()
        sc.set_child(view)
        tv.set_content(sc)
        win.set_content(tv)
        win.present()

    def show_page(self, name: str):
        self.stack.set_visible_child_name(name)
        self.back_btn.set_visible(name == "queue")
        self.queue_btn.set_visible(name == "settings" and bool(self.jobs))

    def show_missing_deps_dialog(self):
        dialog = Adw.MessageDialog(
            transient_for=self,
            heading="ffmpeg / ffprobe not found",
            body="Install ffmpeg, or set its location under Advanced → FFmpeg path.\n\n"
                 "Arch:  sudo pacman -S ffmpeg\n"
                 "NixOS: add pkgs.ffmpeg-full to your environment",
        )
        dialog.add_response("ok", "OK")
        dialog.present()

    # ---------------- settings page ----------------

    def build_settings_page(self):
        scroller = Gtk.ScrolledWindow(vexpand=True)
        page = Adw.PreferencesPage()
        scroller.set_child(page)

        # 1 · Input
        files_group = Adw.PreferencesGroup(title="1 · Input")
        page.add(files_group)
        pick_btn = Gtk.Button(label="Select Files…", valign=Gtk.Align.CENTER)
        pick_btn.add_css_class("suggested-action")
        pick_btn.connect("clicked", self.on_pick_files)
        clear_btn = Gtk.Button(label="Clear", valign=Gtk.Align.CENTER)
        clear_btn.connect("clicked", self.on_clear_files)
        btn_box = Gtk.Box(spacing=6)
        btn_box.append(pick_btn)
        btn_box.append(clear_btn)
        self.hint_row = Adw.ActionRow(
            title="No files selected",
            subtitle="Drag files onto this window, or select them. "
                     "H.264/H.265 camera files are your usual source.")
        self.hint_row.add_suffix(btn_box)
        files_group.add(self.hint_row)
        self.files_listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self.files_listbox.add_css_class("boxed-list")
        self.files_listbox.set_visible(False)
        files_group.add(self.files_listbox)

        # 2 · Preset
        preset_group = Adw.PreferencesGroup(
            title="2 · Preset",
            description="Creates Resolve-compatible media files. This app does not register "
                        "them inside DaVinci Resolve — link or import them yourself "
                        "(e.g. Media Pool → right-click → Proxy Media → Link Proxy Media…; "
                        "wording varies by Resolve version).")
        page.add(preset_group)
        self.preset_row = make_combo_row("Workflow Preset", PRESET_NAMES)
        self.preset_row.connect("notify::selected", self.on_preset_changed)
        self.role_row = Adw.ActionRow(title="This creates")
        preset_group.add(self.preset_row)
        preset_group.add(self.role_row)

        video_group = Adw.PreferencesGroup(title="Video")
        page.add(video_group)
        self.video_mode_row = make_combo_row("Video Mode", VIDEO_MODES)
        self.resolution_row = make_combo_row(
            "Resolution", RESOLUTIONS,
            subtitle="Scales the short side; smaller files are never upscaled")
        self.video_codec_row = make_combo_row("Video Codec", VIDEO_CODECS)
        self.quality_row = make_combo_row(
            "Quality", QUALITIES,
            subtitle="Affects H.264/H.265 and compressed audio. DNxHR/ProRes bitrate is fixed by profile.")
        for r in (self.video_mode_row, self.resolution_row, self.video_codec_row, self.quality_row):
            r.connect("notify::selected", self.on_preset_field_changed)
            video_group.add(r)

        audio_group = Adw.PreferencesGroup(title="Audio")
        page.add(audio_group)
        self.convert_audio_row = Adw.SwitchRow(
            title="Convert Audio", active=True,
            subtitle="Off = copy the original audio untouched (use 'Video only' to drop it)")
        self.convert_audio_row.connect("notify::active", self.on_preset_field_changed)
        self.audio_codec_row = make_combo_row("Audio Codec", AUDIO_CODECS)
        self.audio_codec_row.connect("notify::selected", self.on_preset_field_changed)
        self.sample_rate_row = make_combo_row("Sample Rate", SAMPLE_RATES)
        self.sample_rate_row.connect("notify::selected", self.on_preset_field_changed)
        for r in (self.convert_audio_row, self.audio_codec_row, self.sample_rate_row):
            audio_group.add(r)

        # 3 · Output
        output_group = Adw.PreferencesGroup(title="3 · Output")
        page.add(output_group)
        self.output_type_row = make_combo_row("Output Type", OUTPUT_TYPES)
        self.output_type_row.connect("notify::selected", self.on_preset_field_changed)
        output_group.add(self.output_type_row)

        default_folder = os.path.join(os.path.expanduser("~"), "converted")
        self.output_folder = self.config.get("output_folder", default_folder)
        self.folder_row = Adw.ActionRow(title="Output Folder", subtitle=esc(self.output_folder))
        folder_btn = Gtk.Button(label="Choose…", valign=Gtk.Align.CENTER)
        folder_btn.connect("clicked", self.on_pick_folder)
        open_folder_btn = Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER)
        open_folder_btn.set_tooltip_text("Open output folder")
        open_folder_btn.connect("clicked", lambda _b: self.open_path(self.output_folder))
        self.folder_row.add_suffix(open_folder_btn)
        self.folder_row.add_suffix(folder_btn)
        output_group.add(self.folder_row)

        self.filename_mode_row = make_combo_row("Filename Handling", FILENAME_MODES)
        self.filename_mode_row.connect("notify::selected", self.on_other_changed)
        output_group.add(self.filename_mode_row)
        self.custom_suffix_row = Adw.EntryRow(title="Custom Suffix", text="_custom")
        self.custom_suffix_row.set_visible(False)
        self.custom_suffix_row.connect("changed", self.on_other_changed)
        output_group.add(self.custom_suffix_row)
        self.on_exists_row = make_combo_row("If Output Exists", EXISTS_OPTIONS)
        output_group.add(self.on_exists_row)

        # 4 · Estimated size
        est_group = Adw.PreferencesGroup(title="4 · Estimated size")
        page.add(est_group)
        self.estimate_row = Adw.ActionRow(title="Estimated output (rough)",
                                          subtitle="Add files to see an estimate")
        est_group.add(self.estimate_row)
        self.warning_row = Adw.ActionRow(title="Heads up")
        self.warning_row.add_prefix(Gtk.Image(icon_name="dialog-warning-symbolic"))
        self.warning_row.add_css_class("warning")
        self.warning_row.set_visible(False)
        est_group.add(self.warning_row)
        self.compare_row = Adw.ExpanderRow(
            title="Compare presets for these files",
            subtitle="Estimated size of every workflow preset")
        est_group.add(self.compare_row)

        # 5 · Hardware acceleration
        self.hw_group = Adw.PreferencesGroup(title="5 · Hardware acceleration")
        page.add(self.hw_group)
        self.use_gpu_row = Adw.SwitchRow(
            title="Use GPU (NVENC)", subtitle="Hardware-encode H.264/H.265 output",
            active=self.has_nvenc)
        self.use_gpu_row.set_sensitive(self.has_nvenc)
        self.use_gpu_row.connect("notify::active", self.on_other_changed)
        self.hwaccel_decode_row = Adw.SwitchRow(
            title="Use GPU Decoding (NVDEC)", active=self.has_nvdec,
            subtitle=("Decode the source on GPU to cut CPU load — works with any output codec. "
                      "Falls back to CPU automatically if it fails." if self.has_nvdec else
                      "Not detected — this ffmpeg build has no CUDA/NVDEC hwaccel"))
        self.hwaccel_decode_row.set_sensitive(self.has_nvdec)
        self.hwaccel_decode_row.connect("notify::active", self.on_other_changed)
        self.parallel_row = make_combo_row(
            "Parallel Conversions", PARALLEL_JOB_OPTIONS,
            subtitle="Run more than one ffmpeg job at once (uses more CPU/RAM)")
        for r in (self.use_gpu_row, self.hwaccel_decode_row, self.parallel_row):
            self.hw_group.add(r)

        # Advanced
        adv_group = Adw.PreferencesGroup(title="Advanced")
        page.add(adv_group)
        self.ffmpeg_path_row = Adw.EntryRow(
            title="FFmpeg path (blank = search PATH)", show_apply_button=True,
            text=self.config.get("ffmpeg_path", ""))
        self.ffmpeg_path_row.connect("apply", self.on_ffmpeg_path_apply)
        self.dry_run_row = Adw.SwitchRow(
            title="Dry Run", subtitle="Write the ffmpeg commands to a plan file instead of running them",
            active=False)
        self.cmd_row = Adw.ExpanderRow(title="Show FFmpeg command",
                                       subtitle="Exact command for the first file")
        self.cmd_label = Gtk.Label(xalign=0, wrap=True, selectable=True,
                                   wrap_mode=Pango.WrapMode.WORD_CHAR)
        self.cmd_label.add_css_class("monospace")
        for m in ("top", "bottom", "start", "end"):
            getattr(self.cmd_label, f"set_margin_{m}")(10)
        self.cmd_row.add_row(self.cmd_label)
        for r in (self.ffmpeg_path_row, self.dry_run_row, self.cmd_row):
            adv_group.add(r)

        reset_group = Adw.PreferencesGroup()
        page.add(reset_group)
        reset_btn = Gtk.Button(label="Reset to Defaults")
        reset_btn.connect("clicked", self.on_reset_defaults)
        reset_group.add(reset_btn)

        # 6 · Queue
        action_group = Adw.PreferencesGroup(title="6 · Queue")
        page.add(action_group)
        add_btn = Gtk.Button(label="Add to Queue")
        add_btn.connect("clicked", lambda _b: self.request_enqueue(start=False))
        convert_btn = Gtk.Button(label="Convert Now")
        convert_btn.add_css_class("suggested-action")
        convert_btn.add_css_class("pill")
        convert_btn.connect("clicked", lambda _b: self.request_enqueue(start=True))
        box = Gtk.Box(spacing=12, halign=Gtk.Align.CENTER, margin_top=12, margin_bottom=24)
        box.append(add_btn)
        box.append(convert_btn)
        action_group.add(box)

        return scroller

    # ---------------- queue / progress page ----------------

    def build_queue_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10,
                      margin_top=18, margin_bottom=18, margin_start=18, margin_end=18)

        self.queue_title = Gtk.Label(label="Queue", xalign=0)
        self.queue_title.add_css_class("title-2")
        box.append(self.queue_title)

        self.progress_bar = Gtk.ProgressBar(show_text=True)
        box.append(self.progress_bar)
        self.progress_status = Gtk.Label(label="", xalign=0, wrap=True)
        box.append(self.progress_status)
        self.progress_eta = Gtk.Label(label="", xalign=0)
        self.progress_eta.add_css_class("dim-label")
        box.append(self.progress_eta)

        self.queue_listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self.queue_listbox.add_css_class("boxed-list")
        sc = Gtk.ScrolledWindow(vexpand=True, min_content_height=200)
        sc.set_child(self.queue_listbox)
        box.append(sc)

        btns = Gtk.Box(spacing=8)
        self.start_btn = Gtk.Button(label="Start Queue")
        self.start_btn.add_css_class("suggested-action")
        self.start_btn.connect("clicked", lambda _b: self.start_queue())
        retry_btn = Gtk.Button(label="Retry Failed")
        retry_btn.connect("clicked", lambda _b: self.retry_failed())
        clear_btn = Gtk.Button(label="Clear Finished")
        clear_btn.connect("clicked", lambda _b: self.clear_finished())
        cancel_btn = Gtk.Button(label="Cancel All")
        cancel_btn.add_css_class("destructive-action")
        cancel_btn.connect("clicked", lambda _b: self.cancel_all())
        for b in (self.start_btn, retry_btn, clear_btn, cancel_btn):
            btns.append(b)
        box.append(btns)

        expander = Gtk.Expander(label="ffmpeg log")
        self.log_buffer = Gtk.TextBuffer()
        self.log_view = Gtk.TextView(buffer=self.log_buffer, editable=False, monospace=True,
                                     wrap_mode=Gtk.WrapMode.WORD_CHAR)
        self.log_end_mark = self.log_buffer.create_mark("end", self.log_buffer.get_end_iter(), False)
        log_sc = Gtk.ScrolledWindow(min_content_height=140)
        log_sc.add_css_class("card")
        log_sc.set_child(self.log_view)
        expander.set_child(log_sc)
        box.append(expander)
        return box

    def append_log(self, text: str):
        self.log_buffer.insert(self.log_buffer.get_end_iter(), text + "\n")
        self.log_view.scroll_to_mark(self.log_end_mark, 0.0, False, 0.0, 0.0)

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
        paths = [f.get_path() for f in files if f.get_path() and is_media_file(f.get_path())]
        added = self.add_input_files(paths)
        if added:
            self.show_toast(f"Added {added} file(s)")
        return True

    # ---------------- settings <-> widgets ----------------

    def default_settings(self) -> ConversionSettings:
        return ConversionSettings(use_gpu=self.has_nvenc, use_hwaccel_decode=self.has_nvdec)

    def gather_settings(self) -> ConversionSettings:
        parallel_str = combo_value(self.parallel_row)
        return ConversionSettings(
            preset=combo_value(self.preset_row) or "Custom",
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
            on_exists=combo_value(self.on_exists_row),
            use_gpu=self.use_gpu_row.get_active(),
            use_hwaccel_decode=self.hwaccel_decode_row.get_active(),
            dry_run=self.dry_run_row.get_active(),
            parallel_jobs=int(parallel_str.split(" ")[0]) if parallel_str else 1,
        )

    def apply_settings(self, s: ConversionSettings):
        """Push a ConversionSettings into the widgets (used by restore, reset
        and presets — one code path instead of three copies)."""
        self._applying = True
        try:
            set_combo_value(self.preset_row, s.preset)
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
            set_combo_value(self.on_exists_row, s.on_exists)
            self.use_gpu_row.set_active(s.use_gpu and self.has_nvenc)
            self.hwaccel_decode_row.set_active(s.use_hwaccel_decode and self.has_nvdec)
            self.dry_run_row.set_active(s.dry_run)
            set_combo_value(self.parallel_row, parallel_label(s.parallel_jobs))
        finally:
            self._applying = False
        self.refresh_derived()

    def restore_settings(self):
        saved = self.config.get("settings")
        if saved:
            self.apply_settings(ConversionSettings.from_json(saved))
        else:
            self.apply_settings(self.default_settings())

    def persist_settings(self, s: ConversionSettings):
        self.config["settings"] = s.to_json()
        self.config["output_folder"] = self.output_folder
        save_config(self.config)

    def on_reset_defaults(self, _btn):
        self.apply_settings(self.default_settings())
        self.show_toast("Settings reset to defaults")

    def on_preset_changed(self, row, _pspec):
        if self._applying:
            return
        preset = PRESET_BY_NAME.get(combo_value(row))
        if preset and preset.overrides:
            self.apply_settings(replace(self.gather_settings(), preset=preset.name, **preset.overrides))
        else:
            self.refresh_derived()

    def on_preset_field_changed(self, *_args):
        """A video/audio/output field changed by hand: we're no longer exactly on a preset."""
        if self._applying or not self._ready:
            return
        if combo_value(self.preset_row) != "Custom":
            self._applying = True
            set_combo_value(self.preset_row, "Custom")
            self._applying = False
        self.refresh_derived()

    def on_other_changed(self, *_args):
        if not self._applying and self._ready:
            self.refresh_derived()

    # ---------------- hardware ----------------

    def update_hw_description(self):
        nvenc = "✅ NVENC available" if self.has_nvenc else "⚠️ NVENC not usable — CPU encoding"
        nvdec = "✅ NVDEC available" if self.has_nvdec else "NVDEC not detected"
        self.hw_group.set_description(f"{nvenc} · {nvdec}. Everything works CPU-only too.")

    def verify_nvenc_async(self):
        if not self.has_nvenc:
            return

        def worker():
            if not check_nvenc_works():
                self.ui(self._nvenc_unusable)
        threading.Thread(target=worker, daemon=True).start()

    def _nvenc_unusable(self):
        self.has_nvenc = False
        self.use_gpu_row.set_active(False)
        self.use_gpu_row.set_sensitive(False)
        self.update_hw_description()
        self.refresh_derived()

    def on_ffmpeg_path_apply(self, row):
        path = row.get_text().strip()
        self.config["ffmpeg_path"] = path
        save_config(self.config)
        resolve_tools(path)
        self.has_nvenc = check_nvenc_support() if TOOLS.found else False
        self.has_nvdec = check_nvdec_support() if TOOLS.found else False
        self.use_gpu_row.set_sensitive(self.has_nvenc)
        self.hwaccel_decode_row.set_sensitive(self.has_nvdec)
        self.update_hw_description()
        self.media_info.clear()
        self.refresh_files_ui()
        if TOOLS.found:
            self.show_toast(f"Using {TOOLS.ffmpeg}")
            self.verify_nvenc_async()
        else:
            self.show_toast("ffmpeg/ffprobe not found at that path")

    # ---------------- derived UI state ----------------

    def current_infos(self) -> list:
        return [self.media_info[p] for p in self.input_files
                if p in self.media_info and self.media_info[p].ok]

    def refresh_derived(self):
        if not self._ready:
            return
        s = self.gather_settings()
        ci = codec_info(s.video_codec)
        is_copy = s.video_mode.startswith("Copy")
        audio_only = s.output_type == "Audio only"
        video_only = s.output_type == "Video only"
        video_active = not audio_only and not is_copy

        self.video_mode_row.set_sensitive(not audio_only)
        self.resolution_row.set_sensitive(video_active)
        self.video_codec_row.set_sensitive(video_active)
        self.convert_audio_row.set_sensitive(not video_only and not audio_only)
        audio_on = not video_only and (s.convert_audio or audio_only)
        self.audio_codec_row.set_sensitive(audio_on)
        self.sample_rate_row.set_sensitive(audio_on)
        self.use_gpu_row.set_sensitive(bool(self.has_nvenc and ci.hw_encoder and video_active))
        self.hwaccel_decode_row.set_sensitive(bool(self.has_nvdec and video_active))
        self.custom_suffix_row.set_visible(s.filename_mode.startswith("Custom"))

        self.video_codec_row.set_subtitle(ci.short_desc)
        preset = PRESET_BY_NAME.get(s.preset)
        self.preset_row.set_subtitle(preset.summary if preset else "")
        if audio_only:
            role = "Audio file (not video media)"
        elif is_copy:
            role = "Stream copy — original codec, not a proxy"
        else:
            role = ci.role_label
        self.role_row.set_subtitle(esc(role))

        infos = self.current_infos()
        est = estimate_total(infos, s, len(self.input_files)) if infos else None
        self.update_estimate_ui(s, est)
        self.update_warning_ui(s, infos, est)
        self.update_compare_ui(s, infos)
        self.update_command_preview(s)

    def update_estimate_ui(self, s, est):
        if not self.input_files:
            self.estimate_row.set_subtitle("Add files to see an estimate")
            return
        pending = [p for p in self.input_files if p not in self.media_info]
        if est is None:
            self.estimate_row.set_subtitle("Measuring source files…" if pending
                                           else "Can't estimate (no duration info for these files)")
            return
        lines = [f"Source: {format_size(est.source_mb)} · {est.counted} file(s) · "
                 f"{format_time(est.duration)}"]
        change = change_text(est)
        lines.append(f"Estimated output: ~{format_size(est.est_mb)} "
                     f"(likely {format_size(est.low_mb)}–{format_size(est.high_mb)})"
                     + (f" · {change}" if change else ""))
        bits = []
        if est.video_mbps:
            bits.append(f"~{est.video_mbps:.0f} Mbit/s video")
        if est.audio_mbps:
            bits.append(f"~{est.audio_mbps:.1f} Mbit/s audio")
        if bits:
            lines.append("Estimated bitrate: " + " + ".join(bits) + " (average)")
        note = "Rough estimate — actual size may vary."
        if pending or est.counted < len(self.input_files):
            note = "Partial estimate (some files unmeasured). " + note
        lines.append(note)
        self.estimate_row.set_subtitle(esc("\n".join(lines)))

    def update_warning_ui(self, s, infos, est):
        warns = validate_choices(s, infos, est, get_free_mb(self.output_folder))
        if not warns:
            self.warning_row.set_visible(False)
            return
        self.warning_row.set_subtitle(esc("\n".join(w.text for w in warns)))
        self.warning_row.set_visible(True)

    def update_compare_ui(self, s, infos):
        for child in self._compare_children:
            self.compare_row.remove(child)
        self._compare_children = []
        self.compare_row.set_sensitive(bool(infos))
        if not infos:
            return
        for p in COMPARE_PRESETS:
            s2 = replace(s, preset=p.name, **p.overrides)
            est = estimate_total(infos, s2, len(self.input_files))
            if est is None:
                continue
            big = est.est_mb > LARGE_ESTIMATE_GB * 1024
            row = Adw.ActionRow(
                title=esc(p.name),
                subtitle=esc(f"~{format_size(est.est_mb)} "
                             f"({format_size(est.low_mb)}–{format_size(est.high_mb)}) · "
                             f"{change_text(est)}" + (" ⚠" if big else "")))
            self.compare_row.add_row(row)
            self._compare_children.append(row)

    def update_command_preview(self, s):
        if not self.input_files:
            self.cmd_label.set_label("(add a file to preview the command)")
            return
        first = self.input_files[0]
        out = get_output_path(first, self.output_folder, s)
        self.cmd_label.set_label(shlex.join(build_ffmpeg_cmd(first, out, s)))

    # ---------------- input files ----------------

    def on_pick_files(self, _btn):
        dialog = Gtk.FileChooserNative.new(
            "Select Media Files", self, Gtk.FileChooserAction.OPEN, "Select", "Cancel")
        dialog.set_select_multiple(True)
        for name, exts in (("Video Files", VIDEO_EXTS), ("Audio Files", AUDIO_EXTS)):
            flt = Gtk.FileFilter(name=name)
            for ext in exts:
                flt.add_pattern(f"*.{ext}")
                flt.add_pattern(f"*.{ext.upper()}")
            dialog.add_filter(flt)
        all_filter = Gtk.FileFilter(name="All Files")
        all_filter.add_pattern("*")
        dialog.add_filter(all_filter)
        dialog.connect("response", self.on_files_chosen)
        self._chooser = dialog          # PyGObject would otherwise GC it mid-dialog
        dialog.show()

    def on_files_chosen(self, dialog, response):
        if response == Gtk.ResponseType.ACCEPT:
            paths = [f.get_path() for f in dialog.get_files() if f.get_path()]
            self.add_input_files(paths)
        self._chooser = None

    def add_input_files(self, paths: list) -> int:
        added = 0
        for p in paths:
            p = os.path.abspath(p)
            if p not in self.input_files:
                self.input_files.append(p)
                added += 1
        if added:
            self.refresh_files_ui()
        return added

    def on_clear_files(self, _btn):
        self.input_files = []
        self.refresh_files_ui()

    def remove_file(self, path):
        if path in self.input_files:
            self.input_files.remove(path)
            self.refresh_files_ui()

    def refresh_files_ui(self):
        while True:
            row = self.files_listbox.get_row_at_index(0)
            if row is None:
                break
            self.files_listbox.remove(row)
        self.file_rows = {}

        if not self.input_files:
            self.hint_row.set_title("No files selected")
            self.hint_row.set_subtitle("Drag files onto this window, or select them. "
                                       "H.264/H.265 camera files are your usual source.")
            self.files_listbox.set_visible(False)
            self.refresh_derived()
            return

        self.files_listbox.set_visible(True)
        for path in self.input_files:
            row = Adw.ActionRow(title=esc(os.path.basename(path)))
            remove_btn = Gtk.Button(icon_name="user-trash-symbolic", valign=Gtk.Align.CENTER)
            remove_btn.add_css_class("flat")
            remove_btn.connect("clicked", lambda _b, p=path: self.remove_file(p))
            row.add_suffix(remove_btn)
            self.files_listbox.append(row)
            self.file_rows[path] = row
            self.update_file_row(path)
        self.update_files_summary()
        self.probe_new_files()
        self.refresh_derived()

    def update_file_row(self, path):
        row = self.file_rows.get(path)
        if row:
            row.set_subtitle(esc(f"Source · {describe_media(self.media_info.get(path))}\n{path}"))

    def update_files_summary(self):
        n = len(self.input_files)
        total_mb = sum(get_file_size_mb(p) for p in self.input_files)
        dur = sum(self.media_info[p].duration for p in self.input_files if p in self.media_info)
        self.hint_row.set_title(f"{n} file(s) selected")
        self.hint_row.set_subtitle(f"{format_size(total_mb)} source" +
                                   (f" · {format_time(dur)} total" if dur else ""))

    def probe_new_files(self):
        todo = [p for p in self.input_files if p not in self.media_info and p not in self._probing]
        if not todo:
            return
        self._probing.update(todo)

        def worker():
            for p in todo:
                self.ui(self._probe_done, p, probe_media(p))
        threading.Thread(target=worker, daemon=True).start()

    def _probe_done(self, path, info):
        self._probing.discard(path)
        self.media_info[path] = info        # failed probes are cached too → no retry loop
        if path in self.file_rows:
            self.update_file_row(path)
            self.update_files_summary()
            self.refresh_derived()

    # ---------------- output folder ----------------

    def on_pick_folder(self, _btn):
        dialog = Gtk.FileChooserNative.new(
            "Select Output Folder", self, Gtk.FileChooserAction.SELECT_FOLDER, "Select", "Cancel")
        dialog.connect("response", self.on_folder_chosen)
        self._chooser = dialog
        dialog.show()

    def on_folder_chosen(self, dialog, response):
        if response == Gtk.ResponseType.ACCEPT:
            f = dialog.get_file()
            folder = f.get_path() if f else None
            if folder:
                self.output_folder = folder
                self.folder_row.set_subtitle(esc(folder))
                self.config["output_folder"] = folder
                save_config(self.config)
                self.refresh_derived()
        self._chooser = None

    # ---------------- enqueue flow ----------------

    def request_enqueue(self, start: bool):
        if not self.input_files:
            self.show_toast("Pick some files first!")
            return
        if not TOOLS.found:
            self.show_missing_deps_dialog()
            return

        s = self.gather_settings()
        ci = codec_info(s.video_codec)
        if ci.hw_encoder and not self.has_nvenc:
            self.show_toast("NVENC not available — using the software encoder instead")
        s = replace(s, use_gpu=s.use_gpu and self.has_nvenc,
                    use_hwaccel_decode=s.use_hwaccel_decode and self.has_nvdec)
        self.persist_settings(s)

        try:
            os.makedirs(self.output_folder, exist_ok=True)
        except OSError as e:
            self.show_toast(f"Can't create output folder: {e}")
            return
        if not os.access(self.output_folder, os.W_OK):
            self.show_toast(f"Output folder not writable: {self.output_folder}")
            return

        infos = self.current_infos()
        est = estimate_total(infos, s, len(self.input_files)) if infos else None
        serious = [w.text for w in validate_choices(s, infos, est, get_free_mb(self.output_folder))
                   if w.confirm]
        if serious:
            self.confirm("Check these choices", "\n\n".join(serious) +
                         "\n\nYou can still continue — this is just a heads-up.",
                         "Continue anyway", lambda: self._after_validation(s, start))
        else:
            self._after_validation(s, start)

    def _after_validation(self, s: ConversionSettings, start: bool):
        if s.dry_run:
            self.run_dry_run(s)
            return
        planned, conflicts = self.plan_jobs(list(self.input_files), s)
        policy = exists_policy(s)
        if conflicts and policy == "ask":
            self.ask_conflict(planned, conflicts, start)
        else:
            self.commit_jobs(planned, conflicts, policy, start)

    def plan_jobs(self, files: list, s: ConversionSettings):
        """Build Job objects. Outputs that would clobber a source file, another
        input of this batch, or a queued job's output are ALWAYS renamed;
        outputs that merely exist on disk are returned as 'conflicts' so the
        user can choose."""
        with self.jobs_lock:
            taken = {os.path.abspath(j.output_path) for j in self.jobs if j.status in (QUEUED, RUNNING)}
        sources = {os.path.abspath(f) for f in files}
        planned, conflicts = [], []
        for f in files:
            src = os.path.abspath(f)
            out = os.path.abspath(get_output_path(f, self.output_folder, s))
            renamed = False
            if out == src or out in sources or out in taken:
                out = unique_path(out, taken | sources)
                renamed = True
            taken.add(out)
            self._job_counter += 1
            job = Job(self._job_counter, src, out, s)
            if renamed:
                job.message = "Renamed to avoid overwriting another file"
            elif os.path.exists(out):
                conflicts.append(job)
            planned.append(job)
        return planned, conflicts

    def ask_conflict(self, planned, conflicts, start):
        names = "\n".join("• " + os.path.basename(j.output_path) for j in conflicts[:6])
        more = f"\n…and {len(conflicts) - 6} more" if len(conflicts) > 6 else ""
        d = Adw.MessageDialog(
            transient_for=self, heading="Output files already exist",
            body=f"{len(conflicts)} of {len(planned)} output file(s) already exist in "
                 f"{self.output_folder}:\n{names}{more}")
        d.add_response("cancel", "Cancel")
        d.add_response("skip", "Skip Existing")
        d.add_response("rename", "Keep Both")
        d.add_response("overwrite", "Overwrite")
        d.set_response_appearance("rename", Adw.ResponseAppearance.SUGGESTED)
        d.set_response_appearance("overwrite", Adw.ResponseAppearance.DESTRUCTIVE)
        d.set_default_response("rename")
        d.set_close_response("cancel")

        def on_response(_d, r):
            if r in ("skip", "rename", "overwrite"):
                self.commit_jobs(planned, conflicts, r, start)
        d.connect("response", on_response)
        d.present()

    def commit_jobs(self, planned, conflicts, policy, start):
        with self.jobs_lock:
            taken = {os.path.abspath(j.output_path) for j in self.jobs if j.status in (QUEUED, RUNNING)}
        taken |= {j.output_path for j in planned}
        for job in conflicts:
            if policy == "skip":
                job.status = SKIPPED
                job.message = "Output already exists — skipped (use ⟳ to run anyway)"
            elif policy == "rename":
                job.output_path = unique_path(job.output_path, taken)
                taken.add(job.output_path)
                job.message = "Renamed to keep the existing file"
        with self.jobs_lock:
            self.jobs.extend(planned)
        for job in planned:
            self.add_job_row(job)
        self.input_files = []
        self.refresh_files_ui()
        self.show_page("queue")
        self.update_overall()
        if start:
            self.start_queue()
        else:
            self.show_toast(f"Added {len(planned)} job(s) to the queue")

    # ---------------- dry run ----------------

    def run_dry_run(self, s: ConversionSettings):
        plan_path = os.path.join(
            self.output_folder, f"conversion_plan_{datetime.datetime.now():%Y%m%d_%H%M%S}.txt")
        lines = [
            "=" * 41, "  DAVINCI CONVERTER - DRY RUN", "=" * 41,
            f"Date: {datetime.datetime.now()}",
            f"Total files: {len(self.input_files)}", "",
            "Settings:",
            f"  Preset: {s.preset}",
            f"  Video: {s.video_codec} | {s.resolution} | {s.quality}",
            f"  Audio: {s.audio_codec} | {s.sample_rate}",
            f"  Output: {s.output_type}",
            f"  GPU encode: {s.use_gpu} | GPU decode (NVDEC): {s.use_hwaccel_decode}",
            "", "=" * 41, "Commands (copy-pasteable, quoted for the shell):", "=" * 41, "",
        ]
        for f in self.input_files:
            out = get_output_path(f, self.output_folder, s)
            lines += [f"# File: {os.path.basename(f)}", f"# Output: {out}",
                      shlex.join(build_ffmpeg_cmd(f, out, s)), ""]
        try:
            with open(plan_path, "w", encoding="utf-8") as fh:
                fh.write("\n".join(lines))
        except OSError as e:
            self.show_toast(f"Could not write plan: {e}")
            return
        d = Adw.MessageDialog(transient_for=self, heading="Dry Run — Preview Saved",
                              body=f"Plan written to:\n{plan_path}")
        d.add_response("open", "Open File")
        d.add_response("close", "Close")
        d.connect("response", lambda _d, r: self.open_path(plan_path) if r == "open" else None)
        d.present()

    # ---------------- queue UI ----------------

    def add_job_row(self, job: Job):
        row = Adw.ActionRow()
        icon = Gtk.Image()
        row.add_prefix(icon)
        bar = Gtk.ProgressBar(valign=Gtk.Align.CENTER)
        bar.set_size_request(100, -1)

        def btn(icon_name, tip, cb):
            b = Gtk.Button(icon_name=icon_name, valign=Gtk.Align.CENTER)
            b.add_css_class("flat")
            b.set_tooltip_text(tip)
            b.connect("clicked", lambda _b: cb(job))
            return b

        w = SimpleNamespace(
            row=row, icon=icon, bar=bar,
            up=btn("go-up-symbolic", "Move up", lambda j: self.move_job(j, -1)),
            down=btn("go-down-symbolic", "Move down", lambda j: self.move_job(j, +1)),
            again=btn("view-refresh-symbolic", "Retry / run again", self.run_again),
            cancel=btn("process-stop-symbolic", "Cancel this file", self.cancel_job),
            remove=btn("user-trash-symbolic", "Remove from queue", self.remove_job),
            info=btn("dialog-information-symbolic", "Details & ffmpeg command", self.show_job_details),
        )
        row.add_suffix(bar)
        for b in (w.up, w.down, w.again, w.cancel, w.info, w.remove):
            row.add_suffix(b)
        self.job_widgets[job] = w
        self.queue_listbox.append(row)
        self.update_job_row(job)

    def update_job_row(self, job: Job):
        w = self.job_widgets.get(job)
        if not w:
            return
        icon_name, css = STATUS_ICONS[job.status]
        w.icon.set_from_icon_name(icon_name)
        w.icon.set_css_classes(css)
        w.row.set_title(esc(os.path.basename(job.input_path)))
        status = {QUEUED: "Queued", RUNNING: f"{int(job.progress * 100)}%"}.get(job.status, "")
        if job.message:
            status = f"{status} · {job.message}" if status else job.message
        w.row.set_subtitle(esc(f"→ {job.output_path}\n{status}"))
        w.bar.set_visible(job.status == RUNNING)
        w.bar.set_fraction(job.progress)
        queued, running = job.status == QUEUED, job.status == RUNNING
        w.up.set_visible(queued)
        w.down.set_visible(queued)
        w.cancel.set_visible(running)
        w.remove.set_visible(not running)
        w.again.set_visible(job.status in TERMINAL)

    def rebuild_queue_list(self):
        for w in self.job_widgets.values():
            if w.row.get_parent() is not None:
                self.queue_listbox.remove(w.row)
        with self.jobs_lock:
            jobs = list(self.jobs)
        for j in jobs:
            self.queue_listbox.append(self.job_widgets[j].row)

    def update_overall(self):
        with self.jobs_lock:
            jobs = list(self.jobs)
            active = self.active_workers
        n = len(jobs)
        self.queue_btn.set_visible(self.stack.get_visible_child_name() == "settings" and n > 0)
        self.queue_title.set_label(f"Queue — {n} file(s)")
        if not n:
            self.progress_bar.set_fraction(0)
            self.progress_bar.set_text("")
            self.progress_status.set_label("Queue is empty")
            self.progress_eta.set_label("")
            return
        frac = sum(1.0 if j.status in TERMINAL else (j.progress if j.status == RUNNING else 0.0)
                   for j in jobs) / n
        done = sum(1 for j in jobs if j.status in TERMINAL)
        self.progress_bar.set_fraction(frac)
        self.progress_bar.set_text(f"{done}/{n}")
        running = [j for j in jobs if j.status == RUNNING]
        if running:
            self.progress_status.set_label("Now: " + ", ".join(
                f"{os.path.basename(j.input_path)} ({int(j.progress * 100)}%)" for j in running))
        else:
            queued = sum(1 for j in jobs if j.status == QUEUED)
            self.progress_status.set_label(f"Idle — {queued} waiting" if queued else "All done")
        if running and self.batch_started and frac > 0.02:
            elapsed = time.monotonic() - self.batch_started
            self.progress_eta.set_label(f"Estimated time remaining: {format_time(elapsed * (1 - frac) / frac)}")
        else:
            self.progress_eta.set_label("")
        self.start_btn.set_sensitive(active == 0 and any(j.status == QUEUED for j in jobs))

    def show_job_details(self, job: Job):
        cmd = job.last_cmd or build_ffmpeg_cmd(job.input_path, job.output_path, job.settings)
        text = [f"Source:  {job.input_path}", f"Output:  {job.output_path}",
                f"Status:  {job.status}" + (f" — {job.message}" if job.message else ""),
                f"Preset:  {job.settings.preset}", "", "ffmpeg command:", shlex.join(cmd)]
        if job.error_tail:
            text += ["", "ffmpeg said:", job.error_tail]
        self.show_text_window(os.path.basename(job.input_path), "\n".join(text))

    # ---------------- queue actions (main thread) ----------------

    def move_job(self, job: Job, delta: int):
        with self.jobs_lock:
            i = self.jobs.index(job)
            j = i + delta
            if not 0 <= j < len(self.jobs) or self.jobs[j].status != QUEUED:
                return
            self.jobs[i], self.jobs[j] = self.jobs[j], self.jobs[i]
        self.rebuild_queue_list()

    def remove_job(self, job: Job):
        with self.jobs_lock:
            if job.status == RUNNING or job not in self.jobs:
                return
            self.jobs.remove(job)
        w = self.job_widgets.pop(job, None)
        if w:
            self.queue_listbox.remove(w.row)
        self.update_overall()

    def cancel_job(self, job: Job):
        proc = None
        with self.jobs_lock:
            if job.status == QUEUED:
                job.status, job.message = CANCELLED, "Cancelled before start"
            elif job.status == RUNNING:
                job.cancel_requested = True
                proc = job.proc
        self._terminate(proc)
        self.update_job_row(job)
        self.update_overall()

    @staticmethod
    def _terminate(proc):
        if proc is None:
            return
        try:
            proc.terminate()
        except OSError:
            return
        threading.Timer(5, lambda: proc.kill() if proc.poll() is None else None).start()

    def cancel_all(self):
        with self.jobs_lock:
            jobs = list(self.jobs)
        for j in jobs:
            if j.status in (QUEUED, RUNNING):
                self.cancel_job(j)

    def run_again(self, job: Job):
        with self.jobs_lock:
            if job.status not in TERMINAL:
                return
            job.status, job.progress, job.message = QUEUED, 0.0, ""
            job.error_tail, job.cancel_requested = "", False
        self.update_job_row(job)
        self.start_queue()

    def retry_failed(self):
        with self.jobs_lock:
            failed = [j for j in self.jobs if j.status in (FAILED, CANCELLED)]
        for j in failed:
            with self.jobs_lock:
                j.status, j.progress, j.message = QUEUED, 0.0, ""
                j.error_tail, j.cancel_requested = "", False
            self.update_job_row(j)
        if failed:
            self.start_queue()
        else:
            self.show_toast("Nothing to retry")

    def clear_finished(self):
        with self.jobs_lock:
            finished = [j for j in self.jobs if j.status in TERMINAL]
            self.jobs = [j for j in self.jobs if j.status not in TERMINAL]
        for j in finished:
            w = self.job_widgets.pop(j, None)
            if w:
                self.queue_listbox.remove(w.row)
        self.update_overall()

    # ---------------- workers (background threads) ----------------

    def start_queue(self):
        parallel = self.gather_settings().parallel_jobs
        with self.jobs_lock:
            queued = sum(1 for j in self.jobs if j.status == QUEUED)
            busy = sum(1 for j in self.jobs if j.status == RUNNING)
            spawn = max(0, min(parallel, queued + busy) - self.active_workers)
            if spawn and self.active_workers == 0:
                self.batch_started = time.monotonic()
                self.run_log_lines = []
            self.active_workers += spawn
        for _ in range(spawn):
            threading.Thread(target=self._worker_loop, daemon=True).start()
        self.update_overall()

    def _worker_loop(self):
        while True:
            job = self._claim_or_exit()
            if job is None:
                return
            self.ui(self._on_job_update, job)
            try:
                self._run_job(job)
            except Exception as e:      # never let a worker die silently
                log.exception("job crashed: %s", job.input_path)
                self._finish_job(job, FAILED, f"Internal error: {e}")

    def _claim_or_exit(self):
        """Atomically take the next queued job, or retire this worker."""
        with self.jobs_lock:
            for j in self.jobs:
                if j.status == QUEUED:
                    j.status, j.progress, j.cancel_requested = RUNNING, 0.0, False
                    return j
            self.active_workers -= 1
            last = self.active_workers == 0
        if last:
            self.ui(self._on_batch_finished)
        return None

    def _finish_job(self, job: Job, status: str, message: str):
        job.status, job.message = status, message
        job.progress = 1.0 if status == DONE else job.progress
        self.ui(self._on_job_update, job)
        self.ui(self._record_result, job)

    def _record_result(self, job: Job):
        icons = {DONE: "✓", FAILED: "❌", SKIPPED: "⏭", CANCELLED: "⚠"}
        name = os.path.basename(job.input_path)
        self.append_log(f"{icons.get(job.status, '?')} {name}: {job.message}")
        self.run_log_lines.append(f"{job.status.upper()}: {job.input_path} -> {job.output_path} — {job.message}")

    def _on_job_update(self, job: Job):
        self.update_job_row(job)
        self.update_overall()

    def _run_ffmpeg(self, job: Job, cmd: list) -> tuple:
        """Run one ffmpeg command. Progress comes from `-progress pipe:1`;
        stderr (errors only) is drained on its own thread so neither pipe can
        fill up and deadlock. Returns (returncode, stderr_tail)."""
        tail: deque = deque(maxlen=25)
        try:
            proc = subprocess.Popen(
                cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, encoding="utf-8", errors="replace", bufsize=1)
        except OSError as e:
            return 127, f"Could not start ffmpeg: {e}"
        job.proc = proc
        if job.cancel_requested:        # cancel pressed between claim and Popen
            self._terminate(proc)

        def drain():
            for line in proc.stderr:
                line = line.rstrip()
                if line:
                    tail.append(line)
        t = threading.Thread(target=drain, daemon=True)
        t.start()

        for line in proc.stdout:
            key, _, val = line.strip().partition("=")
            if key in ("out_time_us", "out_time_ms") and job.duration > 0:
                try:
                    frac = int(val) / 1e6 / job.duration
                except ValueError:
                    continue
                frac = min(0.999, max(0.0, frac))
                if frac > job.progress + 0.002:
                    job.progress = frac
                    self.ui(self._on_job_update, job)
        rc = proc.wait()
        t.join(timeout=2)
        job.proc = None
        return rc, "\n".join(tail)

    def _run_job(self, job: Job):
        s = job.settings
        name = os.path.basename(job.input_path)
        if not os.path.isfile(job.input_path):
            return self._finish_job(job, FAILED, "Input file missing")

        info = self.media_info.get(job.input_path) or probe_media(job.input_path)
        job.duration = info.duration
        src_mb = get_file_size_mb(job.input_path)
        tmp = partial_path(job.output_path)
        self.ui(self.append_log, f"▶ {name}")

        ok, last_tail, used = False, "", s
        for i, attempt in enumerate(fallback_attempts(s)):
            if job.cancel_requested:
                break
            if i:
                what = "CPU decode" if attempt.use_gpu == s.use_gpu else "CPU decode + CPU encode"
                self.ui(self.append_log, f"⚠ {name}: GPU path failed, retrying with {what}…")
                job.progress = 0.0
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
            except OSError:
                pass
            cmd = build_ffmpeg_cmd(job.input_path, tmp, attempt)
            job.last_cmd = cmd
            rc, tail = self._run_ffmpeg(job, cmd)
            if rc == 0 and os.path.isfile(tmp):
                ok, used = True, attempt
                break
            last_tail = tail
            if tail:
                self.ui(self.append_log, tail)
            if is_non_gpu_failure(tail):
                break

        if job.cancel_requested:
            self._cleanup(tmp)
            return self._finish_job(job, CANCELLED, "Cancelled")
        if not ok:
            self._cleanup(tmp)
            job.error_tail = last_tail
            reason = (last_tail.splitlines() or ["ffmpeg returned an error"])[-1]
            return self._finish_job(job, FAILED, reason[:200])

        try:
            os.replace(tmp, job.output_path)
        except OSError as e:
            self._cleanup(tmp)
            return self._finish_job(job, FAILED, f"Could not save output: {e}")

        out_mb = get_file_size_mb(job.output_path)
        msg = format_size(out_mb)
        if src_mb:
            msg += f" ({out_mb / src_mb * 100:.0f}% of source)"
        if used.use_gpu != s.use_gpu:
            msg += " · CPU encode fallback"
        elif used.use_hwaccel_decode != s.use_hwaccel_decode:
            msg += " · CPU decode fallback"
        self._finish_job(job, DONE, msg)

    @staticmethod
    def _cleanup(path: str):
        try:
            if os.path.exists(path):
                os.remove(path)
        except OSError:
            pass

    def _on_batch_finished(self):
        with self.jobs_lock:
            if self.active_workers > 0:      # a retry started new workers meanwhile
                return
            jobs = list(self.jobs)
        self.update_overall()
        if not self.run_log_lines:
            return
        counts = {k: sum(1 for j in jobs if j.status == k) for k in TERMINAL}
        start = datetime.datetime.now()
        log_path = os.path.join(self.output_folder, f"conversion_log_{start:%Y%m%d_%H%M%S}.txt")
        try:
            with open(log_path, "w", encoding="utf-8") as f:
                f.write("\n".join(["DAVINCI CONVERTER LOG", f"Date: {start}", ""] + self.run_log_lines +
                                  ["", f"Done: {counts[DONE]}  Failed: {counts[FAILED]}  "
                                       f"Skipped: {counts[SKIPPED]}  Cancelled: {counts[CANCELLED]}"]))
        except OSError:
            log_path = ""
        self.run_log_lines = []

        if counts[FAILED] == 0 and counts[CANCELLED] == 0:
            heading, body = "Queue Complete 🎉", f"✅ {counts[DONE]} file(s) created."
        else:
            heading = "Finished with problems"
            body = (f"✅ Done: {counts[DONE]}\n❌ Failed: {counts[FAILED]}\n"
                    f"⚠️ Cancelled: {counts[CANCELLED]}\n⏭ Skipped: {counts[SKIPPED]}")
        d = Adw.MessageDialog(transient_for=self, heading=heading,
                              body=f"{body}\n\n📁 {self.output_folder}")
        d.add_response("open_folder", "Open Folder")
        if log_path:
            d.add_response("view_log", "View Log")
        d.add_response("close", "Close")

        def handle(_d, r):
            if r == "open_folder":
                self.open_path(self.output_folder)
            elif r == "view_log":
                self.open_path(log_path)
        d.connect("response", handle)
        d.present()


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
