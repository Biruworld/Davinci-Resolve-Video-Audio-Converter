
# Davinci-Resolve Video/Audio Converter (Alpha)

A simple GUI Converter for **Davinci Resolve on Linux** built because due to limitations by pre-converting media into Resolve-friendly format, such as: ProRes, DNxHR and more!

> ⚠️ Status **STILL IN ALPHA**
> This is a learning project and still it's an early prototype/early stage experimentation.

## 🎯 Problem
A free Davinci-Resolve on Linux is quite **Limited codec support**, especially for format like:
- H.264 / H.265 (in certain containers)
- AAC / MP3 audio (for me)
- Variable behavior across GPUs and drivers

---

## ✨ Solution
This tool provides a **mininal GUI** to:
- Select media files
- Convert them into **Resolve-friendly codecs**
- Avoid repetitive terminal commands (ffmpeg)

---
## 🧰 Tools Used
- Python
- GTK4
- FFmpeg

## 📦 Features (Current)
- GUI file picker (GTK4)
- Preset-based conversion for Davinci Resolve
- Focused output formats:
    - DNxHR
    - Apple ProRes 
    - PCM / FLAC audio

---
## 🚫 Limitation 
- Still on Alpha quality
- Shell-based logic
- Limited Presets
- Minimal Error handling
- Linux-only (already tested on Fedora and Arch.)
These limitations are **known** at this stage.

---
## ⏩ Future Plan
- [] Package as a Flatpak.
- Recompile, remaking it.



## ✅ How to Use!

- Make sure to download:

Linux:

```bash
git clone https://github.com/Biruworld/Davinci-Resolve-Video-Audio-Converter
cd Davinci-Resolve-Video-Audio-Converter
chmod +x install.sh
./install.sh
```
How to Run?
```bash
davinci-resolve
```

Tips for NixOS: 
```bash
nix-shell -p python3 python3Packages.pygobject3 ffmpeg
```
Then run the py file. Make sure you're on the directory itself.
or
```bash
nix-shell -p gobject-introspection gtk4 libadwaita ffmpeg "python3.withPackages (ps: [ ps.pygobject3 ])" --run "python3 'video-converter.py'"
```
## Screenshot
<img width="708" height="898" alt="image" src="https://github.com/user-attachments/assets/809586bc-e892-41a6-a65f-38ff3e07036f" />
<img width="712" height="1006" alt="image" src="https://github.com/user-attachments/assets/48f28995-2de5-4792-8b8b-b87a7697162a" />
<img width="712" height="899" alt="image" src="https://github.com/user-attachments/assets/f7536974-9f1b-4129-a7fd-9db5ba969565" />


## ⚠️ Caution
This is still an early stage, I am apologize if I made some serious mistakes or maybe even the script. If there anything, please tell me. Thank you so much!

Regards from Asterlusnce.


## Authors

- [@asterlusnce](https://github.com/Biruworld)

