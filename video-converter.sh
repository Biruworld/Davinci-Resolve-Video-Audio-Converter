#!/bin/bash
# Cleanup function
PROGRESS_PIPE=""
PROGRESS_PID=""
CANCEL_FLAG="/tmp/davinci_converter_cancel_$$"

cleanup() {
    exec 3>&- 2>/dev/null
    [[ -n "$PROGRESS_PID" ]] && kill $PROGRESS_PID 2>/dev/null
    rm -f "$PROGRESS_PIPE" "$CANCEL_FLAG" 2>/dev/null
}

trap cleanup EXIT INT TERM

# Check dependencies
for cmd in yad ffmpeg ffprobe; do
    if ! command -v $cmd &> /dev/null; then
        zenity --error --text="Required: $cmd\n\nInstall:\nFedora: sudo dnf install $cmd\nArch: sudo pacman -S $cmd\nUbuntu: sudo apt install $cmd"
        exit 1
    fi
done

# ========================================
# GPU CAPABILITY CHECK
# ========================================

check_nvenc_support() {
    if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_nvenc"; then
        return 1
    fi
    return 0
}

HAS_NVENC=false
if check_nvenc_support; then
    HAS_NVENC=true
fi

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

# Build GPU warning message
GPU_STATUS="✅ NVENC Available"
if [[ "$HAS_NVENC" == false ]]; then
    GPU_STATUS="⚠️ NVENC Not Detected (will use CPU encoding)"
fi

RESULT=$(yad --form --width=700 --height=750 \
    --title="Video & Audio Converter v3.2" \
    --text="<b>Professional Media Converter</b>\n<span color='#4CAF50' size='large'>📂 $TOTAL_FILES file(s) selected</span>\n<span color='#FF9800' size='small'>$GPU_STATUS</span>\n\nDNxHR Proxy Generator • NVENC Encoder • Audio Extractor" \
    --separator="|" \
    --button="Cancel:1" \
    --button="Convert Now:0" \
    \
    --field="<b>QUICK PRESETS</b>:LBL" "" \
    --field="Load Preset:CB" "Custom!DaVinci Proxy (Fast)!DaVinci Proxy (Quality)!Audio Extract Only!YouTube Upload (H.264)" \
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
    --field="Overwrite existing files:CHK" "FALSE" \
    \
    --field="<b>ADVANCED</b>:LBL" "" \
    --field="Use GPU (NVENC):CHK" "$HAS_NVENC" \
    --field="Dry-run (preview commands only):CHK" "FALSE" \
)

# Exit if cancelled
[[ $? -ne 0 ]] && exit 0

# ========================================
# PARSE FORM RESULTS
# ========================================

IFS='|' read -r \
    DUMMY1 \
    PRESET \
    DUMMY2 \
    VIDEO_MODE \
    RESOLUTION \
    VIDEO_CODEC \
    QUALITY \
    DUMMY3 \
    CONVERT_AUDIO \
    AUDIO_CODEC \
    SAMPLE_RATE \
    DUMMY4 \
    OUTPUT_TYPE \
    DUMMY5 \
    OUTPUT_FOLDER \
    FILENAME_MODE \
    CUSTOM_SUFFIX \
    OVERWRITE_FILES \
    DUMMY6 \
    USE_GPU \
    DRY_RUN \
    <<< "$RESULT"

# Apply preset if selected
if [[ "$PRESET" != "Custom" ]]; then
    case "$PRESET" in
        "DaVinci Proxy (Fast)")
            VIDEO_CODEC="DNxHR LB (Proxy - Recommended)"
            RESOLUTION="540p"
            QUALITY="Low (Fast, Smaller)"
            OUTPUT_TYPE="Video + Audio"
            ;;
        "DaVinci Proxy (Quality)")
            VIDEO_CODEC="DNxHR SQ"
            RESOLUTION="1080p"
            QUALITY="Medium (Balanced)"
            OUTPUT_TYPE="Video + Audio"
            ;;
        "Audio Extract Only")
            OUTPUT_TYPE="Audio only"
            AUDIO_CODEC="FLAC"
            SAMPLE_RATE="48000"
            ;;
        "YouTube Upload (H.264)")
            VIDEO_CODEC="H.264 (Software)"
            RESOLUTION="1080p"
            QUALITY="High (Slower, Better)"
            AUDIO_CODEC="AAC"
            OUTPUT_TYPE="Video + Audio"
            ;;
    esac
fi

# Warn if NVENC selected but not available
if [[ "$VIDEO_CODEC" == *"NVENC"* ]] && [[ "$HAS_NVENC" == false ]]; then
    yad --warning \
        --text="⚠️ NVENC encoder not available!\n\nYour system doesn't support NVIDIA hardware encoding.\nFalling back to software encoding (slower)." \
        --button="Continue:0" \
        --button="Cancel:1"
    [[ $? -ne 0 ]] && exit 0
    USE_GPU="FALSE"
fi

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
    local size_bytes=$(stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null)
    [[ -z "$size_bytes" ]] && echo "0" || echo $(( size_bytes / 1048576 ))
}

# ========================================
# DRY RUN MODE
# ========================================

if [[ "$DRY_RUN" == "TRUE" ]]; then
    PLAN_FILE="$OUTPUT_FOLDER/conversion_plan_$(date +%Y%m%d_%H%M%S).txt"
    
    {
        echo "========================================="
        echo "  DAVINCI CONVERTER - DRY RUN"
        echo "========================================="
        echo "Date: $(date)"
        echo "Total files: $TOTAL_FILES"
        echo ""
        echo "Settings:"
        echo "  Video: $VIDEO_CODEC | $RESOLUTION | $QUALITY"
        echo "  Audio: $AUDIO_CODEC | $SAMPLE_RATE"
        echo "  Output: $OUTPUT_TYPE"
        echo "  GPU: $USE_GPU"
        echo ""
        echo "========================================="
        echo "Commands to be executed:"
        echo "========================================="
        echo ""
    } > "$PLAN_FILE"
    
    echo "$INPUT_FILES" | while IFS= read -r INPUT_FILE; do
        [[ -z "$INPUT_FILE" ]] && continue
        [[ ! -f "$INPUT_FILE" ]] && continue
        
        BASENAME=$(basename "$INPUT_FILE")
        FILENAME="${BASENAME%.*}"
        
        case "$FILENAME_MODE" in
            "Add suffix"*)
                [[ "$OUTPUT_TYPE" == "Audio only" ]] && SUFFIX="_audio" || SUFFIX="_converted"
                ;;
            "Same filename") SUFFIX="" ;;
            "Custom"*) SUFFIX="$CUSTOM_SUFFIX" ;;
        esac
        
        EXT=$(get_output_extension "$VIDEO_CODEC" "$OUTPUT_TYPE" "$AUDIO_CODEC")
        OUTPUT_FILE="$OUTPUT_FOLDER/${FILENAME}${SUFFIX}.${EXT}"
        
        echo "# File: $BASENAME" >> "$PLAN_FILE"
        echo "# Output: $(basename "$OUTPUT_FILE")" >> "$PLAN_FILE"
        echo "ffmpeg -i \"$INPUT_FILE\" [encoding parameters...] \"$OUTPUT_FILE\"" >> "$PLAN_FILE"
        echo "" >> "$PLAN_FILE"
    done
    
    yad --text-info \
        --title="Dry Run - Preview Commands" \
        --width=800 \
        --height=600 \
        --filename="$PLAN_FILE" \
        --button="Save Plan:0" \
        --button="Close:1"
    
    exit 0
fi

# ========================================
# CONVERSION LOOP WITH ENHANCED PROGRESS
# ========================================

COUNTER=0
SUCCESS_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
START_TIME=$(date +%s)

PROGRESS_PIPE=$(mktemp -u)
mkfifo "$PROGRESS_PIPE"

# Progress dialog in background
yad --progress \
    --title="Converting $TOTAL_FILES Files..." \
    --width=750 \
    --height=150 \
    --auto-close \
    --auto-kill \
    --percentage=0 \
    --button="Cancel:1" < "$PROGRESS_PIPE" &

PROGRESS_PID=$!

# Progress updater
exec 3>"$PROGRESS_PIPE"

# Create log file
LOG_FILE="$OUTPUT_FOLDER/conversion_log_$(date +%Y%m%d_%H%M%S).txt"
{
    echo "========================================="
    echo "  DAVINCI CONVERTER LOG"
    echo "========================================="
    echo "Date: $(date)"
    echo "Total files: $TOTAL_FILES"
    echo ""
    echo "Settings:"
    echo "  Video: $VIDEO_CODEC | $RESOLUTION | $QUALITY"
    echo "  Audio: $AUDIO_CODEC | $SAMPLE_RATE"
    echo "  Output: $OUTPUT_TYPE"
    echo "  GPU: $USE_GPU"
    echo ""
    echo "========================================="
    echo ""
} > "$LOG_FILE"

echo "$INPUT_FILES" | while IFS= read -r INPUT_FILE; do
    # Check for cancel
    if ! kill -0 $PROGRESS_PID 2>/dev/null; then
        echo "⚠️ Cancelled by user" >> "$LOG_FILE"
        break
    fi
    
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
    
    # Check if file exists
    if [[ -f "$OUTPUT_FILE" ]] && [[ "$OVERWRITE_FILES" == "FALSE" ]]; then
        echo "# ⏭️  Skipped: $BASENAME (already exists)" >&3
        echo "SKIPPED: $BASENAME (file exists)" >> "$LOG_FILE"
        ((SKIPPED_COUNT++))
        continue
    fi
    
    # Update progress bar
    PERCENT=$((COUNTER * 100 / TOTAL_FILES))
    echo "$PERCENT" >&3
    echo "# [$COUNTER/$TOTAL_FILES] Converting: $BASENAME" >&3
    echo "# Size: ${FILE_SIZE}MB | Duration: $(format_time ${FILE_DURATION}) | Quality: $QUALITY" >&3
    
    # Calculate ETA
    if [[ $COUNTER -gt 1 ]]; then
        ELAPSED=$(($(date +%s) - START_TIME))
        AVG_TIME=$((ELAPSED / (COUNTER - 1)))
        REMAINING_FILES=$((TOTAL_FILES - COUNTER))
        ETA=$((AVG_TIME * REMAINING_FILES))
        echo "# ETA: $(format_time $ETA) remaining" >&3
    fi
    
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
    
    # Log the command
    echo "Converting: $BASENAME" >> "$LOG_FILE"
    echo "Command: ${CMD[@]}" >> "$LOG_FILE"
    
    # Execute conversion
    if "${CMD[@]}" 2>&1 | while IFS= read -r line; do
        if [[ "$line" =~ time=([0-9:\.]+) ]]; then
            CURRENT_TIME="${BASH_REMATCH[1]}"
            echo "# [$COUNTER/$TOTAL_FILES] $BASENAME → $CURRENT_TIME / $(format_time ${FILE_DURATION})" >&3
        fi
    done; then
        # Success
        if [[ -f "$OUTPUT_FILE" ]]; then
            OUTPUT_SIZE=$(get_file_size_mb "$OUTPUT_FILE")
            
            if [[ $FILE_SIZE -gt 0 ]] && [[ $OUTPUT_SIZE -gt 0 ]]; then
                COMPRESSION_RATIO=$(awk "BEGIN {printf \"%.1f\", $FILE_SIZE / $OUTPUT_SIZE}")
                echo "# ✓ Done: $BASENAME (${OUTPUT_SIZE}MB) - ${COMPRESSION_RATIO}x compression" >&3
                echo "SUCCESS: $BASENAME → ${OUTPUT_SIZE}MB (${COMPRESSION_RATIO}x)" >> "$LOG_FILE"
            else
                echo "# ✓ Done: $BASENAME (${OUTPUT_SIZE}MB)" >&3
                echo "SUCCESS: $BASENAME → ${OUTPUT_SIZE}MB" >> "$LOG_FILE"
            fi
            ((SUCCESS_COUNT++))
        else
            echo "# ❌ FAILED: $BASENAME (output file not created)" >&3
            echo "FAILED: $BASENAME (output not created)" >> "$LOG_FILE"
            ((FAILED_COUNT++))
        fi
    else
        # FFmpeg error
        echo "# ❌ FAILED: $BASENAME (ffmpeg error)" >&3
        echo "FAILED: $BASENAME (ffmpeg error)" >> "$LOG_FILE"
        ((FAILED_COUNT++))
    fi
    
    echo "" >> "$LOG_FILE"
    
done

# Final completion
echo "100" >&3

# Generate summary
{
    echo "========================================="
    echo "  CONVERSION SUMMARY"
    echo "========================================="
    echo "Total files: $TOTAL_FILES"
    echo "Successful: $SUCCESS_COUNT"
    echo "Failed: $FAILED_COUNT"
    echo "Skipped: $SKIPPED_COUNT"
    echo ""
    echo "Total time: $(format_time $(($(date +%s) - START_TIME)))"
    echo "========================================="
} >> "$LOG_FILE"

if [[ $FAILED_COUNT -eq 0 ]]; then
    echo "# ✅ All files processed successfully! ($SUCCESS_COUNT succeeded, $SKIPPED_COUNT skipped)" >&3
else
    echo "# ⚠️  Completed with errors! ($SUCCESS_COUNT succeeded, $FAILED_COUNT failed, $SKIPPED_COUNT skipped)" >&3
fi

exec 3>&-
wait $PROGRESS_PID 2>/dev/null

# ========================================
# COMPLETION DIALOG
# ========================================

if [[ $FAILED_COUNT -eq 0 ]]; then
    COMPLETION_TEXT="✅ <b>$SUCCESS_COUNT files converted successfully!</b>"
    [[ $SKIPPED_COUNT -gt 0 ]] && COMPLETION_TEXT="$COMPLETION_TEXT\n⏭️  $SKIPPED_COUNT files skipped (already exist)"
else
    COMPLETION_TEXT="⚠️  <b>Completed with errors</b>\n\n✅ Success: $SUCCESS_COUNT\n❌ Failed: $FAILED_COUNT\n⏭️  Skipped: $SKIPPED_COUNT"
fi

yad --info --title="Conversion Complete! 🎉" \
    --text="$COMPLETION_TEXT\n\n📁 Output folder:\n<tt>$OUTPUT_FOLDER</tt>\n\n📄 Log file:\n<tt>$(basename "$LOG_FILE")</tt>\n\n🎬 Ready for DaVinci Resolve!" \
    --width=550 \
    --button="Open Folder:xdg-open '$OUTPUT_FOLDER'" \
    --button="View Log:xdg-open '$LOG_FILE'" \
    --button="Close:0"
