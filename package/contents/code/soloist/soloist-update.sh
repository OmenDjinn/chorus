#!/bin/sh
# Fetch the current Soloist build from Spotify; builds expire 90 days after their build date.
set -eu
dir="$HOME/.local/opt/soloist"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl --fail --location --silent --show-error -o "$tmp/soloist.tar.gz" \
    https://soloist-builds.spotifycdn.com/soloist_release_x86_64.tar.gz
tar -xzf "$tmp/soloist.tar.gz" -C "$tmp" soloist
new=$("$tmp/soloist" --version | sed -n 's/.* build \([0-9]*\) .*/\1/p')
old=$("$dir/soloist" --version 2>/dev/null | sed -n 's/.* build \([0-9]*\) .*/\1/p' || true)

if [ -n "$new" ] && [ "$new" != "${old:-}" ]; then
    install -m755 "$tmp/soloist" "$dir/soloist.new"
    mv -f "$dir/soloist.new" "$dir/soloist"
    echo "updated soloist: build ${old:-none} -> $new"
    if systemctl --user is-active --quiet soloist || systemctl --user is-failed --quiet soloist; then
        systemctl --user restart soloist
    fi
else
    echo "soloist is current (build $old)"
fi
