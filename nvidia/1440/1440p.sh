#!/usr/bin/env bash

set -Eeuo pipefail

show_help() {
  cat <<'EOF'
Convert a Kooha recording to a high-quality 1440p MP4 for YouTube.

Usage:
  youtube-1440p.sh [INPUT] [OUTPUT]

Defaults:
  INPUT   input.mp4 next to this script
  OUTPUT  output.mp4 next to this script

Examples:
  ./youtube-1440p.sh
  ./youtube-1440p.sh "my chess game.mp4" "my chess game - YouTube.mp4"
EOF
}

case "${1:-}" in
  -h|--help)
    show_help
    exit 0
    ;;
esac

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
input=${1:-"$script_dir/input.mp4"}
output=${2:-"$script_dir/output.mp4"}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

if [[ -x /usr/bin/ffmpeg ]]; then
  ffmpeg_bin=/usr/bin/ffmpeg
else
  ffmpeg_bin=$(command -v ffmpeg || true)
fi

if [[ -x /usr/bin/ffprobe ]]; then
  ffprobe_bin=/usr/bin/ffprobe
else
  ffprobe_bin=$(command -v ffprobe || true)
fi

[[ -n "$ffmpeg_bin" ]] || fail "FFmpeg is not installed."
[[ -n "$ffprobe_bin" ]] || fail "ffprobe is not installed."

encoder_list=$("$ffmpeg_bin" -hide_banner -encoders 2>/dev/null) || \
  fail "Could not read the FFmpeg encoder list from: $ffmpeg_bin"
grep -F ' libx264 ' <<<"$encoder_list" >/dev/null || \
  fail "FFmpeg at $ffmpeg_bin does not include the libx264 encoder."

[[ -f "$input" ]] || fail "Input file not found: $input"

input_abs=$(realpath -- "$input")
output_abs=$(realpath -m -- "$output")
[[ "$input_abs" != "$output_abs" ]] || fail "Input and output must be different files."

output_dir=$(dirname -- "$output_abs")
mkdir -p -- "$output_dir"

frame_rate=$(
  "$ffprobe_bin" -v error -select_streams v:0 \
    -show_entries stream=avg_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    -- "$input_abs"
)

dimensions=$(
  "$ffprobe_bin" -v error -select_streams v:0 \
    -show_entries stream=width,height \
    -of csv=s=x:p=0 \
    -- "$input_abs"
)

[[ -n "$frame_rate" && "$frame_rate" != "0/0" ]] || \
  fail "Could not detect a video stream in: $input"

IFS=x read -r source_width source_height <<<"$dimensions"
[[ "$source_width" =~ ^[0-9]+$ && "$source_height" =~ ^[0-9]+$ ]] || \
  fail "Could not detect the video dimensions in: $input"

target_width=2560
target_height=1440
h264_level=5.1

# Keep a 16:9 canvas even for square or vertical recordings. YouTube classifies
# square/vertical uploads up to three minutes long as Shorts; 2560x1440 keeps
# the upload in the regular-video format and supplies a standard 1440p raster.

video_filter="scale=w=${target_width}:h=${target_height}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${target_width}:${target_height}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,format=yuv420p,setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709"

gop_size=30
if [[ "$frame_rate" =~ ^([0-9]+)/([0-9]+)$ ]] && (( BASH_REMATCH[2] > 0 )); then
  rate_numerator=${BASH_REMATCH[1]}
  rate_denominator=${BASH_REMATCH[2]}
  gop_size=$(( (rate_numerator + rate_denominator) / (2 * rate_denominator) ))
  (( gop_size > 0 )) || gop_size=30
fi

temp_output=$(mktemp --tmpdir="$output_dir" .youtube-1440p.XXXXXX.mp4)
cleanup() {
  rm -f -- "$temp_output"
}
trap cleanup EXIT

printf 'Input:  %s\n' "$input_abs"
printf 'Output: %s\n' "$output_abs"
printf 'Video:  %sx%s, source frame rate %s, H.264 High Profile\n\n' \
  "$target_width" "$target_height" "$frame_rate"

"$ffmpeg_bin" -hide_banner -stats -y \
  -i "$input_abs" \
  -map 0:v:0 -map '0:a:0?' -sn -dn \
  -vf "$video_filter" \
  -c:v libx264 \
  -preset slow \
  -crf 16 \
  -profile:v high \
  -level:v "$h264_level" \
  -pix_fmt yuv420p \
  -refs 3 \
  -g "$gop_size" \
  -keyint_min "$gop_size" \
  -sc_threshold 0 \
  -bf 2 \
  -flags +cgop \
  -x264-params b-pyramid=none \
  -tag:v avc1 \
  -fps_mode cfr \
  -color_primaries bt709 \
  -color_trc bt709 \
  -colorspace bt709 \
  -color_range tv \
  -c:a aac \
  -b:a 384k \
  -ar 48000 \
  -ac 2 \
  -movflags +faststart \
  "$temp_output"

mv -f -- "$temp_output" "$output_abs"
chmod 0644 -- "$output_abs"
trap - EXIT

printf '\nFinished: %s\n' "$output_abs"
printf 'YouTube may take several hours to finish the 1440p/HD processing.\n'
