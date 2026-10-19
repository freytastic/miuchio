#!/usr/bin/env bash
# Renders every launcher, store, web and social icon from the SVG masters in brand/
# Needs rsvg convert and ImageMagick
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
brand="$root/brand"
res="$root/client/android/app/src/main/res"
ios="$root/client/ios/Runner/Assets.xcassets/AppIcon.appiconset"
flutterweb="$root/client/web"
web="${WEB:-$root/../miuchio-web}"
ground='#FDFAF4'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

png() { rsvg-convert -w "$2" -h "$2" "$1" -o "$3"; }

# The App Store rejects icons with an alpha channel
opaque() { magick "$1" -background "$ground" -alpha remove -alpha off "$1"; }

# Same artwork with a wider margin, for crops that cut deeper than a rounded square
padded() { sed 's/viewBox="0 0 100 100"/viewBox="-6 -6 112 112"/' "$brand/icon.svg" > "$tmp/padded.svg"; png "$tmp/padded.svg" "$1" "$2"; }

rounded() {
  local s=$1 r=$(( $1 * 224 / 1000 ))
  png "$brand/icon.svg" "$s" "$tmp/sq.png"
  magick "$tmp/sq.png" -alpha set \( -size "${s}x${s}" xc:none -fill white -draw "roundrectangle 0,0,$((s - 1)),$((s - 1)),$r,$r" \) \
    -compose DstIn -composite "$2"
}

for d in mdpi:1 hdpi:1.5 xhdpi:2 xxhdpi:3 xxxhdpi:4; do
  dir="$res/mipmap-${d%%:*}"
  scale="${d##*:}"
  mkdir -p "$dir"
  rounded "$(awk "BEGIN{print int(48 * $scale)}")" "$dir/ic_launcher.png"
  fg="$(awk "BEGIN{print int(108 * $scale)}")"
  png "$brand/icon-foreground.svg" "$fg" "$dir/ic_launcher_foreground.png"
  png "$brand/icon-monochrome.svg" "$fg" "$dir/ic_launcher_monochrome.png"
done

for f in "$ios"/Icon-App-*.png; do
  name="$(basename "$f" .png)"
  pt="${name#Icon-App-}"; pt="${pt%%x*}"
  scale="${name##*@}"; scale="${scale%x}"
  png "$brand/icon.svg" "$(awk "BEGIN{print int($pt * $scale + 0.5)}")" "$f"
  opaque "$f"
done

png "$brand/icon-tab.svg" 32 "$flutterweb/favicon.png"
rounded 192 "$flutterweb/icons/Icon-192.png"
rounded 512 "$flutterweb/icons/Icon-512.png"
padded 192 "$flutterweb/icons/Icon-maskable-192.png"
padded 512 "$flutterweb/icons/Icon-maskable-512.png"

png "$brand/icon.svg" 512 "$brand/play-store-512.png"
padded 1024 "$brand/avatar-1024.png"
png "$brand/icon-dark.svg" 1024 "$brand/icon-dark-1024.png"
png "$brand/icon.svg" 1024 "$brand/icon-1024.png"

if [ -d "$web/app" ]; then
  cp "$brand/icon-tab.svg" "$web/app/icon.svg"
  png "$brand/icon.svg" 180 "$web/app/apple-icon.png"
  opaque "$web/app/apple-icon.png"
  png "$brand/icon-tab.svg" 16 "$tmp/16.png"
  png "$brand/icon-tab.svg" 32 "$tmp/32.png"
  png "$brand/icon-tab.svg" 48 "$tmp/48.png"
  magick "$tmp/16.png" "$tmp/32.png" "$tmp/48.png" "$web/app/favicon.ico"
fi
