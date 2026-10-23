#!/usr/bin/env python3
"""Publish Spotify Soloist as an MPRIS player.

Follows Soloist's local WebSocket API (enabled with --ws, discovered through
<data-dir>/ws.addr and ws.port) and answers MPRIS calls by sending it the
matching commands. Also exposes org.chorus.Soloist with GetPlaylists (the
user's library via the Spotify Web API) and PlayUri for the Chorus widget.
"""

import json
import os
import sys
import threading
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

import websockets.sync.client  # noqa: E402

import webapi  # noqa: E402

DATA_DIR = os.path.join(
    os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "soloist"
)
BUS_NAME = "org.mpris.MediaPlayer2.soloist"
PATH = "/org/mpris/MediaPlayer2"
NO_TRACK = "/org/mpris/MediaPlayer2/TrackList/NoTrack"
SEEK_JUMP_MS = 1500
# like Spotify: past this point Previous restarts the track, before it goes back one
RESTART_THRESHOLD_MS = 3000

XML = """
<node>
  <interface name="org.mpris.MediaPlayer2">
    <method name="Raise"/>
    <method name="Quit"/>
    <property name="CanQuit" type="b" access="read"/>
    <property name="CanRaise" type="b" access="read"/>
    <property name="HasTrackList" type="b" access="read"/>
    <property name="Identity" type="s" access="read"/>
    <property name="SupportedUriSchemes" type="as" access="read"/>
    <property name="SupportedMimeTypes" type="as" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <method name="Next"/>
    <method name="Previous"/>
    <method name="Pause"/>
    <method name="PlayPause"/>
    <method name="Stop"/>
    <method name="Play"/>
    <method name="Seek"><arg direction="in" name="Offset" type="x"/></method>
    <method name="SetPosition">
      <arg direction="in" name="TrackId" type="o"/>
      <arg direction="in" name="Position" type="x"/>
    </method>
    <method name="OpenUri"><arg direction="in" name="Uri" type="s"/></method>
    <signal name="Seeked"><arg name="Position" type="x"/></signal>
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="LoopStatus" type="s" access="readwrite"/>
    <property name="Rate" type="d" access="readwrite"/>
    <property name="Shuffle" type="b" access="readwrite"/>
    <property name="Metadata" type="a{sv}" access="read"/>
    <property name="Volume" type="d" access="readwrite"/>
    <property name="Position" type="x" access="read"/>
    <property name="MinimumRate" type="d" access="read"/>
    <property name="MaximumRate" type="d" access="read"/>
    <property name="CanGoNext" type="b" access="read"/>
    <property name="CanGoPrevious" type="b" access="read"/>
    <property name="CanPlay" type="b" access="read"/>
    <property name="CanPause" type="b" access="read"/>
    <property name="CanSeek" type="b" access="read"/>
    <property name="CanControl" type="b" access="read"/>
  </interface>
  <interface name="org.chorus.Soloist">
    <method name="GetPlaylists"><arg direction="out" name="json" type="s"/></method>
    <method name="PlayUri"><arg direction="in" name="uri" type="s"/></method>
    <method name="Status"><arg direction="out" name="json" type="s"/></method>
  </interface>
</node>
"""

PLAYER = "org.mpris.MediaPlayer2.Player"


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def entity_name(entity):
    return ((entity or {}).get("decorations") or {}).get("identity", {}).get("name", "")


class Soloist:
    """WebSocket client running in its own thread; events are handed to the GLib loop."""

    def __init__(self, on_event, on_connected):
        self.on_event = on_event
        self.on_connected = on_connected
        self.ws = None
        threading.Thread(target=self.run, daemon=True).start()

    def endpoint(self):
        with open(os.path.join(DATA_DIR, "ws.addr")) as f:
            addr = f.read().strip()
        with open(os.path.join(DATA_DIR, "ws.port")) as f:
            port = f.read().strip()
        return f"ws://{addr}:{port}"

    def run(self):
        while True:
            try:
                with websockets.sync.client.connect(
                    self.endpoint(), open_timeout=5, max_size=None
                ) as ws:
                    self.ws = ws
                    GLib.idle_add(self.on_connected, True)
                    log("connected to soloist")
                    for message in ws:
                        try:
                            event = json.loads(message)
                        except ValueError:
                            continue
                        GLib.idle_add(self.on_event, event)
            except (OSError, websockets.exceptions.WebSocketException) as e:
                if self.ws is not None:
                    log(f"soloist connection lost: {e}")
            self.ws = None
            GLib.idle_add(self.on_connected, False)
            time.sleep(1)

    def send(self, command, **fields):
        ws = self.ws
        if ws is None:
            return False
        try:
            ws.send(json.dumps({"type": "command", "command": command, **fields}))
            return True
        except websockets.exceptions.WebSocketException:
            return False


class Bridge:
    def __init__(self):
        self.status = "idle"
        self.item = None
        self.volume = 1.0
        self.shuffle = False
        self.repeat = "off"
        self.actions = {}
        self.is_active = False
        self.logged_in = False
        self.connected = False
        self.pos_ms = 0
        self.pos_stamp = time.time()
        self.speed = 0.0

        self.conn = None
        self.node = Gio.DBusNodeInfo.new_for_xml(XML)
        self.soloist = Soloist(self.on_event, self.on_connected)
        Gio.bus_own_name(
            Gio.BusType.SESSION,
            BUS_NAME,
            Gio.BusNameOwnerFlags.NONE,
            self.on_bus,
            None,
            lambda *a: log("lost bus name"),
        )

    # ---- soloist events -------------------------------------------------

    def on_connected(self, connected):
        old = self.snapshot()
        self.connected = connected
        if not connected:
            self.logged_in = False
            self.status = "idle"
            self.item = None
        self.emit_changes(old)
        return False

    def set_position(self, position):
        if position:
            self.pos_ms = position.get("position_ms", 0)
            stamp = position.get("timestamp_ms")
            self.pos_stamp = stamp / 1000 if stamp else time.time()
            self.speed = position.get("speed", 0.0)

    def set_status(self, status):
        # keep the position estimate continuous: progress freezes on pause and resumes
        # from "now", so a resume after a long pause isn't seen as a seek
        pos = self.position_ms()
        self.status = status
        self.pos_ms, self.pos_stamp = pos, time.time()

    def uri(self):
        return (self.item or {}).get("uri", "")

    def length_ms(self):
        return (((self.item or {}).get("decorations") or {}).get("playback") or {}).get("duration_ms")

    def snapshot(self):
        """Everything a client can see, to announce only what an event actually changed."""
        return {
            "PlaybackStatus": self.playback_status(),
            "Metadata": self.item,
            "Volume": self.volume,
            "Shuffle": self.shuffle,
            "LoopStatus": self.repeat,
            "caps": (self.can("skip_next"), self.can_go_previous(), self.can_pause(),
                     self.can("seek"), self.connected),
        }

    def on_event(self, ev):
        kind = ev.get("type")
        old = self.snapshot()
        expected, uri = self.position_ms(), self.uri()
        position_update = False
        if kind == "playback_state":
            if "status" in ev:
                self.set_status(ev["status"])
            self.item = ev.get("item")
            self.volume = ev.get("volume", 100) / 100
            opts = ev.get("options") or {}
            self.shuffle = bool(opts.get("shuffle", False))
            self.repeat = opts.get("repeat", "off")
            self.actions = ev.get("available_actions") or {}
            self.is_active = bool(ev.get("is_active", False))
            self.set_position(ev.get("position"))
            position_update = bool(ev.get("position"))
        elif kind == "track_changed":
            self.item = ev.get("item")
            self.pos_ms, self.pos_stamp = 0, time.time()
        elif kind == "playback_changed":
            if "status" in ev:
                self.set_status(ev["status"])
        elif kind == "volume_changed":
            self.volume = ev.get("volume", 100) / 100
        elif kind == "options_changed":
            opts = ev.get("options") or {}
            self.shuffle = bool(opts.get("shuffle", False))
            self.repeat = opts.get("repeat", "off")
        elif kind == "device_changed":
            self.is_active = bool(ev.get("is_active", False))
            if not self.is_active:
                self.set_status("idle")
        elif kind == "position_sync":
            self.set_position(ev.get("position"))
            position_update = True
        elif kind == "auth_state":
            self.logged_in = bool(ev.get("logged_in", False))
            self.is_active = bool(ev.get("is_active", False))
        elif kind == "error":
            log(f"soloist error: {ev.get('message')}")
        self.emit_changes(old)
        # a jump within the same track is a seek; track changes and resumes are not
        if (position_update and uri and self.uri() == uri
                and abs(self.position_ms() - expected) > SEEK_JUMP_MS):
            self.emit_seeked()
        return False

    def emit_changes(self, old):
        new = self.snapshot()
        names = [k for k in ("PlaybackStatus", "Metadata", "Volume", "Shuffle", "LoopStatus")
                 if new[k] != old[k]]
        if new["caps"] != old["caps"]:
            names += ["CanGoNext", "CanGoPrevious", "CanPause", "CanSeek", "CanPlay"]
        if names:
            self.emit(PLAYER, names)

    # ---- state helpers --------------------------------------------------

    def position_ms(self):
        if self.status != "playing":
            return self.pos_ms
        return self.pos_ms + (time.time() - self.pos_stamp) * 1000 * (self.speed or 1.0)

    def playback_status(self):
        if not self.connected or self.item is None or self.status == "idle":
            return "Stopped"
        return "Paused" if self.status == "paused" else "Playing"

    def trackid(self):
        uri = (self.item or {}).get("uri", "")
        if not uri:
            return NO_TRACK
        return "/org/mpris/MediaPlayer2/Track/" + "".join(
            c if c.isalnum() else "_" for c in uri.split(":")[-1]
        )

    def metadata(self):
        item = self.item
        if not item:
            return {}
        dec = item.get("decorations") or {}
        meta = {
            "mpris:trackid": GLib.Variant("o", self.trackid()),
            "xesam:title": GLib.Variant("s", entity_name(item)),
            "xesam:url": GLib.Variant("s", item.get("uri", "")),
        }
        artists = [entity_name(c.get("entity")) for c in dec.get("creators") or []]
        artists = [a for a in artists if a]
        if artists:
            meta["xesam:artist"] = GLib.Variant("as", artists)
        album = entity_name((dec.get("parent") or {}).get("entity"))
        if album:
            meta["xesam:album"] = GLib.Variant("s", album)
        duration = (dec.get("playback") or {}).get("duration_ms")
        if duration:
            meta["mpris:length"] = GLib.Variant("x", int(duration) * 1000)
        covers = (dec.get("visual_identity") or {}).get("cover") or []
        if covers:
            order = {"large": 0, "default": 1, "xlarge": 2, "small": 3}
            best = min(covers, key=lambda c: order.get(c.get("size"), 9))
            meta["mpris:artUrl"] = GLib.Variant("s", best.get("url", ""))
        return meta

    def can(self, action):
        return self.connected and self.item is not None and action in self.actions

    def can_go_previous(self):
        # previous can always restart the track, even on the first track of a context
        return self.can("skip_prev") or self.can("seek")

    def can_pause(self):
        # Soloist only lists the action that applies right now (pause while playing, play
        # while paused), but MPRIS clients expect CanPause to stay true whenever there is a
        # track, or they stop offering the play/pause toggle
        return self.can("pause") or self.can("play")

    def loop_status(self):
        return {"track": "Track", "context": "Playlist"}.get(self.repeat, "None")

    # ---- D-Bus ------------------------------------------------------------

    def on_bus(self, conn, name):
        self.conn = conn
        for iface in self.node.interfaces:
            conn.register_object(PATH, iface, self.on_call, self.on_get, self.on_set)
        log(f"published {name}")

    def prop(self, iface, name):
        if iface == "org.mpris.MediaPlayer2":
            return {
                "CanQuit": GLib.Variant("b", False),
                "CanRaise": GLib.Variant("b", False),
                "HasTrackList": GLib.Variant("b", False),
                "Identity": GLib.Variant("s", "Spotify Soloist"),
                "SupportedUriSchemes": GLib.Variant("as", ["spotify"]),
                "SupportedMimeTypes": GLib.Variant("as", []),
            }.get(name)
        if iface == PLAYER:
            return {
                "PlaybackStatus": lambda: GLib.Variant("s", self.playback_status()),
                "LoopStatus": lambda: GLib.Variant("s", self.loop_status()),
                "Rate": lambda: GLib.Variant("d", 1.0),
                "Shuffle": lambda: GLib.Variant("b", self.shuffle),
                "Metadata": lambda: GLib.Variant("a{sv}", self.metadata()),
                "Volume": lambda: GLib.Variant("d", self.volume),
                "Position": lambda: GLib.Variant("x", int(self.position_ms() * 1000)),
                "MinimumRate": lambda: GLib.Variant("d", 1.0),
                "MaximumRate": lambda: GLib.Variant("d", 1.0),
                "CanGoNext": lambda: GLib.Variant("b", self.can("skip_next")),
                "CanGoPrevious": lambda: GLib.Variant("b", self.can_go_previous()),
                "CanPlay": lambda: GLib.Variant("b", self.connected),
                "CanPause": lambda: GLib.Variant("b", self.can_pause()),
                "CanSeek": lambda: GLib.Variant("b", self.can("seek")),
                "CanControl": lambda: GLib.Variant("b", True),
            }.get(name, lambda: None)()
        return None

    def emit(self, iface, names):
        if self.conn is None:
            return
        changed = {n: self.prop(iface, n) for n in names}
        self.conn.emit_signal(
            None, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
            GLib.Variant("(sa{sv}as)", (iface, changed, [])),
        )

    def emit_seeked(self):
        if self.conn is not None:
            self.conn.emit_signal(None, PATH, PLAYER, "Seeked",
                                  GLib.Variant("(x)", (int(self.position_ms() * 1000),)))

    def on_get(self, conn, sender, path, iface, name):
        return self.prop(iface, name)

    def on_set(self, conn, sender, path, iface, name, value):
        if iface != PLAYER:
            return False
        value = value.unpack()
        if name == "Volume":
            self.soloist.send("set_volume", volume=max(0, min(100, round(value * 100))))
        elif name == "Shuffle":
            self.soloist.send("set_shuffle", enabled=bool(value))
        elif name == "LoopStatus":
            # off/context/track need the two repeat flags set in this order
            if value == "Track":
                self.soloist.send("set_repeat_context", enabled=False)
                self.soloist.send("set_repeat_track", enabled=True)
            else:
                self.soloist.send("set_repeat_track", enabled=False)
                self.soloist.send("set_repeat_context", enabled=value == "Playlist")
        return True

    def play_uri(self, uri):
        if not uri.startswith("spotify:"):
            return False
        if not self.is_active:
            self.soloist.send("activate")
        return self.soloist.send("play", uri=uri)

    def on_call(self, conn, sender, path, iface, method, params, invocation):
        args = params.unpack()
        send = self.soloist.send
        if iface == PLAYER:
            if method == "Play":
                if not self.is_active:
                    send("activate")
                send("play")
            elif method in ("Pause", "Stop"):
                send("pause")
            elif method == "PlayPause":
                if self.status in ("playing", "buffering"):
                    send("pause")
                else:
                    if not self.is_active:
                        send("activate")
                    send("play")
            elif method == "Next":
                send("skip_next")
            elif method == "Previous":
                # on the first track there's nothing to go back to, so restart it
                if self.can("seek") and (self.position_ms() > RESTART_THRESHOLD_MS
                                         or not self.can("skip_prev")):
                    send("seek", position_ms=0)
                else:
                    send("skip_prev")
            elif method == "Seek":
                # per MPRIS, seeking past the end moves on to the next track
                pos, length = self.position_ms() + args[0] / 1000, self.length_ms()
                if length is not None and pos >= length:
                    send("skip_next")
                else:
                    send("seek", position_ms=max(0, int(pos)))
            elif method == "SetPosition":
                # per MPRIS, ignored for another track or a position outside this one
                pos, length = args[1] / 1000, self.length_ms()
                if args[0] == self.trackid() and pos >= 0 and (length is None or pos <= length):
                    send("seek", position_ms=int(pos))
            elif method == "OpenUri":
                self.play_uri(args[0])
            invocation.return_value(None)
        elif iface == "org.chorus.Soloist":
            if method == "PlayUri":
                self.play_uri(args[0])
                invocation.return_value(None)
            elif method == "Status":
                status = {"connected": self.connected, "logged_in": self.logged_in,
                          "is_active": self.is_active}
                invocation.return_value(GLib.Variant("(s)", (json.dumps(status),)))
            elif method == "GetPlaylists":
                # the Web API call can take a second; answer from a thread
                def work():
                    try:
                        result = GLib.Variant("(s)", (webapi.playlists_json(),))
                        GLib.idle_add(lambda: invocation.return_value(result) and False)
                    except Exception as e:  # noqa: BLE001 - reported to the caller
                        msg = str(e)
                        GLib.idle_add(lambda: invocation.return_dbus_error(
                            "org.chorus.Soloist.Error", msg) and False)
                threading.Thread(target=work, daemon=True).start()
        else:
            invocation.return_value(None)


def main():
    Bridge()
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
