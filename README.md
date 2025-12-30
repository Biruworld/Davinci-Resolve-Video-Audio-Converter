
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
- Shell script ('sh') (**for now**)
- YAD (Yet Another Dialog)
- FFmpeg

## 📦 Features (Current)
- GUI file picker (YAD)
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
- [] Turned it into Python based instead of Shell.
- [] Package as a Flatpak.
- [] Replace YAD with a native Python GUI (GTK or Qt)



## ✅ How to Use!

- Make sure to download:

Arch Linux:

```bash
sudo pacman -S ffmpeg
sudo pacman -S yad
```
After that download the script above, and save as script.sh

⚠️ Don't forget the directories for example, you've downloaded it and put it on Download
```bash
cd /home/---/Downloads/
```
and then

```bash
sudo chmod +x script.sh
```

then run
```bash
./script.sh
```
---

Fedora Linux

```bash
sudo dnf install ffmpeg
sudo dnf install yad
```
⚠️ Don't forget the directories for example, you've downloaded it and put it on Download
```bash
cd /home/---/Downloads/
```
and then

```bash
sudo chmod +x script.sh
```

then run
```bash
./script.sh
```

---

## ⚠️ Caution
This is still an early stage, I am so sorry if I made some serious mistakes or maybe even the script. If there anything, please tell me. Thank you so much!

Regards from Asterlusnce.


## Authors

- [@asterlusnce](https://github.com/Biruworld)

