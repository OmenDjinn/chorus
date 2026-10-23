#!/bin/sh
# Installs and manages Spotify Soloist for Chorus (all per-user, no root needed).
#   soloist-setup.sh install      download Soloist, install the MPRIS bridge and services
#   soloist-setup.sh set-key KEY  store the Soloist API key and (re)start Soloist
#   soloist-setup.sh get-key      print the stored API key
#   soloist-setup.sh status       print the setup state as JSON
#   soloist-setup.sh sign-in [ID] log in to the Web API for the playlist list, using the
#                                 given Spotify app client ID (default: Chorus's setting)
set -u

src=$(cd "$(dirname "$0")" && pwd)
opt="$HOME/.local/opt/soloist"
conf="${XDG_CONFIG_HOME:-$HOME/.config}/soloist"
units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

have_key() {
    grep -qE '^SOLOIST_API_KEY=.+' "$conf/env" 2>/dev/null
}

# the Rust bridge needs ~2 MB; the Python one (~24 MB) is the fallback off x86_64
rust_bridge() {
    [ "$(uname -m)" = x86_64 ]
}

missing_deps() {
    for cmd in curl tar python3 systemctl busctl; do
        command -v "$cmd" >/dev/null 2>&1 || printf '%s ' "$cmd"
    done
    # webapi.py only needs the standard library; these are for the Python bridge
    if ! rust_bridge; then
        python3 -c 'import websockets.sync.client' 2>/dev/null || printf 'python-websockets '
        python3 -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null || printf 'python-gobject '
    fi
}

bridge_cmd() {
    if rust_bridge && [ -x "$opt/soloist-mpris" ]; then
        echo "%h/.local/opt/soloist/soloist-mpris"
    else
        echo "/usr/bin/python3 %h/.local/opt/soloist/soloist-mpris.py"
    fi
}

write_units() {
    mkdir -p "$units"
    cat > "$units/soloist.service" <<'EOF'
[Unit]
Description=Spotify Soloist (headless Spotify Connect player)
After=pipewire-pulse.service pipewire.service
Wants=pipewire-pulse.service
# an expired build exits with code 10; fetch the current one right away
OnFailure=soloist-update.service

[Service]
EnvironmentFile=%h/.config/soloist/env
ExecStart=%h/.local/opt/soloist/soloist --device-name %H --api-key ${SOLOIST_API_KEY} --ws 127.0.0.1:0 --initial-volume 100
Restart=on-failure
RestartSec=5
# exit code 10 = build expired; soloist-update.service fetches a new one
RestartPreventExitStatus=10

[Install]
WantedBy=default.target
EOF
    cat > "$units/soloist-mpris.service" <<EOF
[Unit]
Description=MPRIS bridge for Spotify Soloist
After=soloist.service
BindsTo=soloist.service

[Service]
WorkingDirectory=%h/.local/opt/soloist
ExecStart=$(bridge_cmd)
Restart=on-failure
RestartSec=2

[Install]
WantedBy=soloist.service
EOF
    cat > "$units/soloist-update.service" <<'EOF'
[Unit]
Description=Update Spotify Soloist to the current build
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=%h/.local/opt/soloist/update.sh
EOF
    cat > "$units/soloist-update.timer" <<'EOF'
[Unit]
Description=Weekly Spotify Soloist update (builds expire after 90 days)

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
}

start_player() {
    systemctl --user enable soloist.service soloist-mpris.service >/dev/null 2>&1
    systemctl --user restart soloist.service soloist-mpris.service
}

cmd_install() {
    deps=$(missing_deps)
    if [ -n "$deps" ]; then
        echo "error: missing $deps- install with: sudo pacman -S --needed $deps"
        exit 1
    fi
    echo "Downloading Soloist from Spotify..."
    mkdir -p "$opt"
    install -m755 "$src/soloist-update.sh" "$opt/update.sh"
    "$opt/update.sh" || { echo "error: download failed"; exit 1; }
    echo "Installing the media player bridge..."
    install -m755 "$src/soloist-mpris.py" "$opt/soloist-mpris.py"
    if rust_bridge; then
        install -m755 "$src/soloist-mpris" "$opt/soloist-mpris"
    fi
    install -m755 "$src/webapi.py" "$opt/webapi.py"
    (umask 077; mkdir -p "$conf"; [ -e "$conf/env" ] || printf 'SOLOIST_API_KEY=\n' > "$conf/env")
    chmod 700 "$conf"
    chmod 600 "$conf/env"
    write_units
    systemctl --user daemon-reload
    systemctl --user enable --now soloist-update.timer >/dev/null 2>&1
    if systemctl --user is-active --quiet soloist.service; then
        # update.sh already restarted Soloist if there was a new build; only the bridge
        # needs a restart, which leaves the music playing
        systemctl --user enable soloist.service soloist-mpris.service >/dev/null 2>&1
        systemctl --user restart soloist-mpris.service
        echo "done: Soloist is up to date"
    elif have_key; then
        start_player
        echo "done: Soloist installed and running"
    else
        echo "done: Soloist installed, now add your API key"
    fi
}

cmd_set_key() {
    key=${1:-}
    case $key in
        *[!A-Za-z0-9._~+/=-]* | "") echo "error: that doesn't look like an API key"; exit 1 ;;
    esac
    (umask 077; mkdir -p "$conf"; printf 'SOLOIST_API_KEY=%s\n' "$key" > "$conf/env.new")
    mv -f "$conf/env.new" "$conf/env"
    if [ -x "$opt/soloist" ]; then
        start_player
        echo "done: key saved, Soloist restarted"
    else
        echo "done: key saved"
    fi
}

cmd_status() {
    installed=false version="" days=-1
    if [ -x "$opt/soloist" ]; then
        installed=true
        line=$("$opt/soloist" --version 2>/dev/null)
        version=$(printf '%s' "$line" | sed -n 's/^soloist \([0-9.]*\) .*/\1/p')
        built=$(printf '%s' "$line" | sed -n 's/.* (\([0-9]\{8\}\)) .*/\1/p')
        if [ -n "$built" ]; then
            expires=$(( $(date -d "$built" +%s) + 90 * 86400 ))
            days=$(( (expires - $(date +%s)) / 86400 ))
        fi
    fi
    key=false; have_key && key=true
    running=false; systemctl --user is-active --quiet soloist.service && running=true
    # the reply is `s "{...}"` with the JSON's quotes escaped; it only holds booleans
    bridge=$(busctl --user call org.mpris.MediaPlayer2.soloist /org/mpris/MediaPlayer2 \
        org.chorus.Soloist Status 2>/dev/null | sed -n 's/^s "\(.*\)"$/\1/p' | sed 's/\\"/"/g')
    [ -n "$bridge" ] || bridge='{"connected": false, "logged_in": false, "is_active": false}'
    webapi=false; [ -s "$conf/webapi.json" ] && webapi=true
    # why the player stopped, e.g. a rejected key (quotes and backslashes dropped for JSON)
    log=""
    if $installed && ! $running; then
        log=$(journalctl --user -u soloist.service -n 1 -o cat --no-pager 2>/dev/null | tr -d '"\\' | cut -c1-200)
    fi
    printf '{"installed": %s, "version": "%s", "days_left": %s, "key": %s, "running": %s, "bridge": %s, "webapi": %s, "device": "%s", "missing": "%s", "log": "%s"}\n' \
        "$installed" "$version" "$days" "$key" "$running" "$bridge" "$webapi" "$(uname -n)" "$(missing_deps)" "$log"
}

cmd_sign_in() {
    [ -x "$opt/webapi.py" ] || { echo "error: install Soloist first"; exit 1; }
    cid=${1:-}
    case $cid in
        *[!0-9a-f]*) echo "error: that doesn't look like a client ID"; exit 1 ;;
    esac
    if err=$(python3 "$opt/webapi.py" auth $cid 2>&1 >/dev/null); then
        echo "done: signed in"
    else
        # last line of the traceback, e.g. "RuntimeError: no Spotify client ID configured"
        echo "error: sign-in failed: $(printf '%s' "$err" | tail -n1 | sed 's/^[A-Za-z.]*Error: //')"
    fi
}

case ${1:-} in
    install) cmd_install ;;
    set-key) cmd_set_key "${2:-}" ;;
    get-key) sed -n 's/^SOLOIST_API_KEY=//p' "$conf/env" 2>/dev/null ;;
    status) cmd_status ;;
    sign-in) cmd_sign_in "${2:-}" ;;
    *) echo "usage: $0 install|set-key KEY|get-key|status|sign-in [CLIENT_ID]"; exit 2 ;;
esac
