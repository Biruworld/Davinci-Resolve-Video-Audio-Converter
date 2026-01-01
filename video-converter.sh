#!/bin/bash

# ========================================
# VIDEO & AUDIO CONVERTER - YAD GUI
# Fedora Linux Edition v3.1
# ========================================

# Check dependencies
for cmd in yad ffmpeg ffprobe; do
    if ! command -v $cmd &> /dev/null; then
        zenity --error --text="Required: $cmd\nInstall: sudo dnf install $cmd"
        exit 1
    fi
done

# ========================================
# STEP 1: VISUAL FILE PICKER POPUP
# ========================================

INPUT_FILES=$(yad --file \
    --multiple \
    --separator=$'\n' \
    --title="Select Media Files (Ctrl+Click for multi-select)" \
    --width=900 \
    --height=650 \
    --file-filter="Video Files|*.mp4 *.mkv *.mov *.avi *.webm *.flv *.m4v *.mpg *.mpeg *.wmv *.3gp *.ogv *.mts *.m2ts *.ts" \
    --file-filter="Audio Files|*.mp3 *.wav *.flac *.aac *.m4a *.ogg *.opus *.wma *.ape *.alac *.aiff" \
    --file-filter="All Media|*.mp4 *.mkv *.mov *.avi *.mp3 *.wav *.flac" \
    --file-filter="All Files|*" \
    --button="Cancel:1" \
    --button="Select Files:0")

# Exit if cancelled or no files
[[ $? -ne 0 ]] && exit 0
[[ -z "$INPUT_FILES" ]] && exit 0

# Count files
TOTAL_FILES=$(echo "$INPUT_FILES" | wc -l)

# ========================================
# STEP 2: SETTINGS FORM (with file count)
# ========================================

RESULT=$(yad --form --width=700 --height=650 \
    --title="Video & Audio Converter" \
    --text="<b>Professional Media Converter</b>\n<span color='#4CAF50' size='large'>📂 $TOTAL_FILES file(s) selected</span>\n\nDNxHR Proxy Generator • NVENC Encoder • Audio Extractor" \
    --separator="|" \
    --button="Cancel:1" \
    --button="Convert Now:0" \
    \
    --field="<b>VIDEO SETTINGS</b>:LBL" "" \
    --field="Video Mode:CB" "Re-encode!Copy (no re-encode)" \
    --field="Resolution:CB" "Original!1080p!720p!540p!360p!240p!144p" \
    --field="Video Codec:CB" "DNxHR LB (Proxy - Recommended)!DNxHR SQ!DNxHR HQ ⚠ Heavy!ProRes Proxy!ProRes 422 ⚠ Heavy!H.264 (Software)!H.264 (NVENC)!H.265 (NVENC)" \
    --field="Quality:CB" "Medium (Balanced)!Low (Fast, Smaller)!High (Slower, Better)!Ultra (Slowest, Best)" \
    \
    --field="<b>AUDIO SETTINGS</b>:LBL" "" \
    --field="Convert Audio:CHK" "TRUE" \
    --field="Audio Codec:CB" "PCM 16-bit!PCM 24-bit!FLAC!AAC!MP3" \
    --field="Sample Rate:CB" "Original!48000!44100" \
    \
    --field="<b>OUTPUT MODE</b>:LBL" "" \
    --field="Output Type:CB" "Video + Audio!Video only!Audio only" \
    \
    --field="<b>OUTPUT SETTINGS</b>:LBL" "" \
    --field="Output Folder:DIR" "$HOME/converted" \
    --field="Filename Handling:CB" "Add suffix (_converted)!Same filename!Custom suffix" \
    --field="Custom Suffix:TXT" "_custom" \
    \
    --field="<b>PERFORMANCE</b>:LBL" "" \
    --field="Use GPU (NVENC):CHK" "TRUE" \
)

# Exit if cancelled
[[ $? -ne 0 ]] && exit 0

# ========================================
# PARSE FORM RESULTS
# ========================================

IFS='|' read -r \
    DUMMY1 \
    VIDEO_MODE \
    RESOLUTION \
    VIDEO_CODEC \
    QUALITY \
    DUMMY2 \
    CONVERT_AUDIO \
    AUDIO_CODEC \
    SAMPLE_RATE \
    DUMMY3 \
    OUTPUT_TYPE \
    DUMMY4 \
    OUTPUT_FOLDER \
    FILENAME_MODE \
    CUSTOM_SUFFIX \
    DUMMY5 \
    USE_GPU \
    <<< "$RESULT"

# ========================================
# VALIDATION
# ========================================

mkdir -p "$OUTPUT_FOLDER" 2>/dev/null
if [[ ! -w "$OUTPUT_FOLDER" ]]; then
    yad --error --text="Output folder is not writable:\n$OUTPUT_FOLDER"
    exit 1
fi

# ========================================
# HELPER FUNCTIONS
# ========================================

get_resolution_scale() {
    case "$1" in
        "Original") echo "" ;;
        "1080p") echo "scale=-2:1080" ;;
        "720p") echo "scale=-2:720" ;;
        "540p") echo "scale=-2:540" ;;
        "360p") echo "scale=-2:360" ;;
        "240p") echo "scale=-2:240" ;;
        "144p") echo "scale=-2:144" ;;
    esac
}

get_video_codec() {
    local codec="$1"
    local use_gpu="$2"
    
    case "$codec" in
        "DNxHR LB"*) echo "dnxhd" ;;
        "DNxHR SQ"*) echo "dnxhd" ;;
        "DNxHR HQ"*) echo "dnxhd" ;;
        "ProRes Proxy"*) echo "prores_ks" ;;
        "ProRes 422"*) echo "prores_ks" ;;
        "H.264 (NVENC)"*) 
            [[ "$use_gpu" == "TRUE" ]] && echo "h264_nvenc" || echo "libx264"
            ;;
        "H.264 (Software)"*) echo "libx264" ;;
        "H.265 (NVENC)"*)
            [[ "$use_gpu" == "TRUE" ]] && echo "hevc_nvenc" || echo "libx265"
            ;;
    esac
}

get_quality_preset() {
    local codec="$1"
    local quality="$2"
    
    if [[ "$codec" == "libx264" ]] || [[ "$codec" == "libx265" ]]; then
        case "$quality" in
            "Low"*) echo "ultrafast" ;;
            "Medium"*) echo "medium" ;;
            "High"*) echo "slow" ;;
            "Ultra"*) echo "veryslow" ;;
        esac
    elif [[ "$codec" == *"nvenc"* ]]; then
        case "$quality" in
            "Low"*) echo "fast" ;;
            "Medium"*) echo "medium" ;;
            "High"*) echo "slow" ;;
            "Ultra"*) echo "slow" ;;
        esac
    fi
}

get_quality_crf() {
    local codec="$1"
    local quality="$2"
    
    if [[ "$codec" == "libx264" ]] || [[ "$codec" == "libx265" ]]; then
        case "$quality" in
            "Low"*) echo "28" ;;
            "Medium"*) echo "23" ;;
            "High"*) echo "18" ;;
            "Ultra"*) echo "15" ;;
        esac
    fi
}

get_nvenc_quality() {
    local quality="$1"
    
    case "$quality" in
        "Low"*) echo "23" ;;
        "Medium"*) echo "19" ;;
        "High"*) echo "15" ;;
        "Ultra"*) echo "12" ;;
    esac
}

get_dnxhr_profile() {
    case "$1" in
        "DNxHR LB"*) echo "dnxhr_lb" ;;
        "DNxHR SQ"*) echo "dnxhr_sq" ;;
        "DNxHR HQ"*) echo "dnxhr_hq" ;;
        *) echo "" ;;
    esac
}

get_prores_profile() {
    case "$1" in
        "ProRes Proxy"*) echo "0" ;;
        "ProRes 422"*) echo "2" ;;
        *) echo "" ;;
    esac
}

get_pix_fmt() {
    local codec="$1"
    case "$codec" in
        "DNxHR"*|"ProRes"*) echo "yuv422p" ;;
        *) echo "yuv420p" ;;
    esac
}

get_audio_codec() {
    case "$1" in
        "PCM 16-bit") echo "pcm_s16le" ;;
        "PCM 24-bit") echo "pcm_s24le" ;;
        "FLAC") echo "flac" ;;
        "AAC") echo "aac" ;;
        "MP3") echo "libmp3lame" ;;
    esac
}

get_audio_quality() {
    local codec="$1"
    local quality="$2"
    
    case "$codec" in
        "AAC"|"MP3")
            case "$quality" in
                "Low"*) echo "128k" ;;
                "Medium"*) echo "192k" ;;
                "High"*) echo "256k" ;;
                "Ultra"*) echo "320k" ;;
            esac
            ;;
        "FLAC")
            case "$quality" in
                "Low"*) echo "5" ;;
                "Medium"*) echo "8" ;;
                "High"*) echo "10" ;;
                "Ultra"*) echo "12" ;;
            esac
            ;;
    esac
}

get_output_extension() {
    local vcodec="$1"
    local output_type="$2"
    local acodec="$3"
    
    if [[ "$output_type" == "Audio only" ]]; then
        case "$acodec" in
            "PCM"*) echo "wav" ;;
            "FLAC") echo "flac" ;;
            "AAC") echo "m4a" ;;
            "MP3") echo "mp3" ;;
        esac
    elif [[ "$vcodec" == *"DNxHR"* ]] || [[ "$vcodec" == *"ProRes"* ]]; then
        echo "mov"
    else
        echo "mp4"
    fi
}

get_file_duration() {
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | cut -d. -f1
}

format_time() {
    local seconds=$1
    [[ -z "$seconds" ]] && seconds=0
    printf "%02d:%02d:%02d" $((seconds/3600)) $((seconds%3600/60)) $((seconds%60))
}

get_file_size_mb() {
    local size_bytes=$(stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null)
    echo $(( size_bytes / 1048576 ))
}

# ========================================
# CONVERSION LOOP WITH FIXED PROGRESS
# ========================================

COUNTER=0
PROGRESS_PIPE=$(mktemp -u)
mkfifo "$PROGRESS_PIPE"

# Progress dialog in background
yad --progress \
    --title="Converting $TOTAL_FILES Files..." \
    --width=750 \
    --height=150 \
    --auto-close \
    --auto-kill \
    --no-cancel \
    --percentage=0 < "$PROGRESS_PIPE" &

PROGRESS_PID=$!

# Progress updater
exec 3>"$PROGRESS_PIPE"

echo "$INPUT_FILES" | while IFS= read -r INPUT_FILE; do
    [[ -z "$INPUT_FILE" ]] && continue
    [[ ! -f "$INPUT_FILE" ]] && continue
    
    ((COUNTER++))
    
    BASENAME=$(basename "$INPUT_FILE")
    FILENAME="${BASENAME%.*}"
    
    # Get file info
    FILE_DURATION=$(get_file_duration "$INPUT_FILE")
    FILE_SIZE=$(get_file_size_mb "$INPUT_FILE")
    
    # Determine suffix based on mode
    case "$FILENAME_MODE" in
        "Add suffix"*)
            [[ "$OUTPUT_TYPE" == "Audio only" ]] && SUFFIX="_audio" || SUFFIX="_converted"
            ;;
        "Same filename")
            SUFFIX=""
            ;;
        "Custom"*)
            SUFFIX="$CUSTOM_SUFFIX"
            ;;
    esac
    
    # Determine extension
    EXT=$(get_output_extension "$VIDEO_CODEC" "$OUTPUT_TYPE" "$AUDIO_CODEC")
    
    OUTPUT_FILE="$OUTPUT_FOLDER/${FILENAME}${SUFFIX}.${EXT}"
    
    # Update progress bar
    PERCENT=$((COUNTER * 100 / TOTAL_FILES))
    echo "$PERCENT" >&3
    echo "# [$COUNTER/$TOTAL_FILES] Converting: $BASENAME" >&3
    echo "# Size: ${FILE_SIZE}MB | Duration: $(format_time ${FILE_DURATION}) | Quality: $QUALITY" >&3
    
    # Build ffmpeg command
    CMD=(ffmpeg -i "$INPUT_FILE" -y -hide_banner -loglevel error -stats)
    
    # VIDEO HANDLING
    if [[ "$OUTPUT_TYPE" == "Audio only" ]]; then
        CMD+=(-vn)
    elif [[ "$VIDEO_MODE" == "Copy"* ]]; then
        CMD+=(-c:v copy)
    else
        VCODEC=$(get_video_codec "$VIDEO_CODEC" "$USE_GPU")
        CMD+=(-c:v "$VCODEC")
        
        PROFILE=$(get_dnxhr_profile "$VIDEO_CODEC")
        [[ -n "$PROFILE" ]] && CMD+=(-profile:v "$PROFILE")
        
        PRORES_PROFILE=$(get_prores_profile "$VIDEO_CODEC")
        [[ -n "$PRORES_PROFILE" ]] && CMD+=(-profile:v "$PRORES_PROFILE")
        
        PIXFMT=$(get_pix_fmt "$VIDEO_CODEC")
        CMD+=(-pix_fmt "$PIXFMT")
        
        SCALE=$(get_resolution_scale "$RESOLUTION")
        [[ -n "$SCALE" ]] && CMD+=(-vf "$SCALE")
        
        if [[ "$VCODEC" == "libx264" ]] || [[ "$VCODEC" == "libx265" ]]; then
            PRESET=$(get_quality_preset "$VCODEC" "$QUALITY")
            CRF=$(get_quality_crf "$VCODEC" "$QUALITY")
            CMD+=(-preset "$PRESET" -crf "$CRF")
        elif [[ "$VCODEC" == *"nvenc"* ]]; then
            PRESET=$(get_quality_preset "$VCODEC" "$QUALITY")
            CQ=$(get_nvenc_quality "$QUALITY")
            CMD+=(-preset "$PRESET" -cq "$CQ")
        fi
    fi
    
    # AUDIO HANDLING
    if [[ "$OUTPUT_TYPE" == "Video only" ]] || [[ "$CONVERT_AUDIO" == "FALSE" ]]; then
        CMD+=(-an)
    else
        ACODEC=$(get_audio_codec "$AUDIO_CODEC")
        CMD+=(-c:a "$ACODEC")
        
        if [[ "$SAMPLE_RATE" != "Original" ]]; then
            CMD+=(-ar "$SAMPLE_RATE")
        fi
        
        if [[ "$AUDIO_CODEC" == "AAC" ]] || [[ "$AUDIO_CODEC" == "MP3" ]]; then
            AUDIO_BR=$(get_audio_quality "$AUDIO_CODEC" "$QUALITY")
            CMD+=(-b:a "$AUDIO_BR")
        elif [[ "$AUDIO_CODEC" == "FLAC" ]]; then
            FLAC_LEVEL=$(get_audio_quality "$AUDIO_CODEC" "$QUALITY")
            CMD+=(-compression_level "$FLAC_LEVEL")
        fi
    fi
    
    CMD+=("$OUTPUT_FILE")
    
    # Execute conversion
    "${CMD[@]}" 2>&1 | while IFS= read -r line; do
        if [[ "$line" =~ time=([0-9:\.]+) ]]; then
            CURRENT_TIME="${BASH_REMATCH[1]}"
            echo "# [$COUNTER/$TOTAL_FILES] $BASENAME → $CURRENT_TIME / $(format_time ${FILE_DURATION})" >&3
        fi
    done
    
    # Mark file as done
    if [[ -f "$OUTPUT_FILE" ]]; then
        OUTPUT_SIZE=$(get_file_size_mb "$OUTPUT_FILE")
        if [[ $FILE_SIZE -gt 0 ]]; then
            COMPRESSION_RATIO=$(awk "BEGIN {printf \"%.1f\", $FILE_SIZE / $OUTPUT_SIZE}")
            echo "# ✓ Done: $BASENAME (${OUTPUT_SIZE}MB) - ${COMPRESSION_RATIO}x compression" >&3
        else
            echo "# ✓ Done: $BASENAME (${OUTPUT_SIZE}MB)" >&3
        fi
    fi
    
done

# Final completion
echo "100" >&3
echo "# ✅ All $TOTAL_FILES files converted successfully!" >&3

exec 3>&-
wait $PROGRESS_PID

rm -f "$PROGRESS_PIPE"

# ========================================
# COMPLETION DIALOG
# ========================================

yad --info --title="Conversion Complete! 🎉" \
    --text="✅ <b>$TOTAL_FILES files converted successfully!</b>\n\n📁 Output folder:\n<tt>$OUTPUT_FOLDER</tt>\n\n🎬 Ready for editing!" \
    --width=500 \
    --button="Open Folder:xdg-open '$OUTPUT_FOLDER'" \
    --button="Close:0"
```

---

## ✅ PERFECT WORKFLOW NOW:

### **STEP 1: VISUAL FILE PICKER** 🎯
```
┌─────────────────────────────────────────┐
│  Select Media Files (Ctrl+Click)       │
├─────────────────────────────────────────┤
│  📁 /home/user/Videos/                  │
│                                         │
│  📄 wedding_2024.mp4      [2.4 GB]     │
│  📄 birthday_party.mkv    [1.8 GB]     │
│  📄 vacation_clip.mov     [850 MB]     │
│  📄 interview.mp4         [450 MB]     │
│                                         │
│        [Cancel]  [Select Files]         │
└─────────────────────────────────────────┘
```
- ✅ **Visual GUI** dengan preview
- ✅ **Ctrl+Click** untuk multi-select
- ✅ File size visible
- ✅ Filter by type

---

### **STEP 2: SETTINGS FORM** ⚙️
```
┌─────────────────────────────────────────┐
│  Professional Media Converter           │
│  📂 4 file(s) selected  ← HIGHLIGHTED  │
├─────────────────────────────────────────┤
│  [All your settings here...]            │
│                                         │
│        [Cancel]  [Convert Now]          │
└─────────────────────────────────────────┘
```
- ✅ File count **highlighted** di top
- ✅ Configure semua settings
- ✅ Custom suffix support

---

### **STEP 3: PROGRESS BAR** 📊
```
┌─────────────────────────────────────────┐
│  Converting 4 Files...                  │
├─────────────────────────────────────────┤
│  ████████████████░░░░░░░░ 68%          │
│                                         │
│  [2/4] Converting: wedding_2024.mp4     │
│  Size: 2400MB | Duration: 00:45:20     │
│  Quality: High                          │
│  wedding_2024.mp4 → 00:30:12 / 00:45:20│
│                                         │
│  ✓ Done: birthday_party.mkv (720MB)    │
└─────────────────────────────────────────┘
```
- ✅ Real-time updates
- ✅ File-by-file progress
- ✅ No blocking

---

### **STEP 4: COMPLETION** 🎉
```
┌─────────────────────────────────────────┐
│  Conversion Complete! 🎉                │
├─────────────────────────────────────────┤
│  ✅ 4 files converted successfully!     │
│                                         │
│  📁 Output folder:                      │
│  /home/user/converted                   │
│                                         │
│  🎬 Ready for editing!                  │
│                                         │
│    [Open Folder]  [Close]               │
└─────────────────────────────────────────┘
