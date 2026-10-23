//! Publish Spotify Soloist as an MPRIS player.
//!
//! Follows Soloist's local WebSocket API (enabled with --ws, discovered through
//! <data-dir>/ws.addr and ws.port) and answers MPRIS calls by sending it the
//! matching commands. Also exposes org.chorus.Soloist with GetPlaylists (the
//! user's library, fetched by webapi.py next to this binary), PlayUri and Status
//! for the Chorus widget.
//!
//! Spotify drops a paused device's session after a while (and Soloist starts without one
//! after a reboot), forgetting the playlist. The bridge remembers the last playlist, track
//! and position, keeps showing that track as paused, and on play brings it back.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value as Json, json};
use tokio::sync::{Notify, mpsc};
use tokio_tungstenite::tungstenite::Message;
use zbus::object_server::{InterfaceRef, SignalEmitter};
use zbus::zvariant::{ObjectPath, OwnedValue, Value};
use zbus::{fdo, interface};

const BUS_NAME: &str = "org.mpris.MediaPlayer2.soloist";
const PATH: &str = "/org/mpris/MediaPlayer2";
const NO_TRACK: &str = "/org/mpris/MediaPlayer2/TrackList/NoTrack";
const SEEK_JUMP_MS: f64 = 1500.0;
/// Like Spotify: past this point Previous restarts the track, before it goes back one.
const RESTART_THRESHOLD_MS: f64 = 3000.0;
const PLAYLIST_CACHE: Duration = Duration::from_secs(60);
/// A restore skips forward to the saved track; further than this it queues the track instead.
const MAX_RESTORE_SKIPS: usize = 300;

fn now_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64() * 1000.0).unwrap_or(0.0)
}

fn data_dir() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
        .unwrap_or_default()
        .join("soloist")
}

/// Where the last-played state is kept across bridge restarts and reboots.
fn saved_file() -> PathBuf {
    std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
        .unwrap_or_default()
        .join("soloist-mpris/last.json")
}

fn entity_name(entity: &Json) -> &str {
    entity["decorations"]["identity"]["name"].as_str().unwrap_or("")
}

#[derive(Default)]
struct State {
    connected: bool,
    logged_in: bool,
    is_active: bool,
    status: String,
    item: Option<Json>,
    volume: f64,
    shuffle: bool,
    repeat: String,
    actions: Vec<String>,
    pos_ms: f64,
    pos_stamp_ms: f64,
    speed: f64,
    /// Soloist's current context (playlist, album, Liked Songs)
    context: String,
    /// upcoming track URIs from the last queue answer, None while waiting for one
    queue: Option<Vec<String>>,
    /// what was last playing, to bring back after Spotify drops the session
    saved: Option<Saved>,
    /// the session is gone; the saved track is shown as paused until play restores it
    detached: bool,
    /// a restore is running: clients aren't told about the intermediate states
    restoring: bool,
}

#[derive(Clone)]
struct Saved {
    context: String,
    track: String,
    pos_ms: f64,
    item: Json,
}

impl Saved {
    fn load() -> Option<Saved> {
        let v: Json = serde_json::from_str(&std::fs::read_to_string(saved_file()).ok()?).ok()?;
        Some(Saved {
            context: v["context"].as_str()?.to_owned(),
            track: v["track"].as_str()?.to_owned(),
            pos_ms: v["pos_ms"].as_f64().unwrap_or(0.0),
            item: v.get("item").filter(|i| i.is_object())?.clone(),
        })
    }

    fn store(&self) {
        let path = saved_file();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let v = json!({ "context": self.context, "track": self.track, "pos_ms": self.pos_ms, "item": self.item });
        let _ = std::fs::write(path, v.to_string());
    }
}

impl State {
    /// Records what's playing while Soloist holds a session with a context.
    fn remember(&mut self) {
        if self.restoring || self.detached || !self.is_active || self.context.is_empty() {
            return;
        }
        let Some(item) = self.item.clone() else { return };
        let track = self.uri().to_owned();
        if track.is_empty() {
            return;
        }
        let changed = self.saved.as_ref().is_none_or(|s| s.context != self.context || s.track != track);
        let pos_ms = self.position_ms();
        self.saved = Some(Saved { context: self.context.clone(), track, pos_ms, item });
        // the file only needs to follow track changes and pauses, not every position update
        if (changed || self.status == "paused")
            && let Some(saved) = &self.saved
        {
            saved.store();
        }
    }

    /// The session is gone: keep showing the saved track as paused, or nothing at all.
    fn detach(&mut self) {
        if self.restoring {
            return;
        }
        match self.saved.clone() {
            Some(saved) => {
                saved.store();
                self.detached = true;
                self.item = Some(saved.item);
                self.status = "paused".to_owned();
                self.pos_ms = saved.pos_ms;
                self.pos_stamp_ms = now_ms();
            }
            None => self.set_status("idle"),
        }
    }

    fn position_ms(&self) -> f64 {
        if self.status != "playing" {
            return self.pos_ms;
        }
        let speed = if self.speed > 0.0 { self.speed } else { 1.0 };
        self.pos_ms + (now_ms() - self.pos_stamp_ms) * speed
    }

    fn set_position(&mut self, position: &Json) {
        if position.is_object() {
            self.pos_ms = position["position_ms"].as_f64().unwrap_or(0.0);
            self.pos_stamp_ms = position["timestamp_ms"].as_f64().unwrap_or_else(now_ms);
            self.speed = position["speed"].as_f64().unwrap_or(0.0);
        }
    }

    /// Changes the status keeping the position estimate continuous: progress freezes on
    /// pause and resumes from "now", so a resume after a long pause isn't seen as a seek.
    fn set_status(&mut self, status: &str) {
        let pos = self.position_ms();
        self.status = status.to_owned();
        self.pos_ms = pos;
        self.pos_stamp_ms = now_ms();
    }

    fn is_playing(&self) -> bool {
        self.status == "playing" || self.status == "buffering"
    }

    fn uri(&self) -> &str {
        self.item.as_ref().and_then(|i| i["uri"].as_str()).unwrap_or("")
    }

    fn length_ms(&self) -> Option<f64> {
        self.item.as_ref()?["decorations"]["playback"]["duration_ms"].as_f64()
    }

    /// Everything a client can see, to announce only what an event actually changed.
    fn snapshot(&self) -> Snapshot {
        Snapshot {
            status: self.playback_status(),
            item: self.item.clone(),
            volume: self.volume,
            shuffle: self.shuffle,
            repeat: self.repeat.clone(),
            caps: [self.can("skip_next"), self.can_go_previous(), self.can_pause(), self.can("seek"), self.connected],
        }
    }

    /// Soloist only lists the action that applies right now (pause while playing, play
    /// while paused), but MPRIS clients expect CanPause to stay true whenever there is a
    /// track, or they stop offering the play/pause toggle.
    fn can_pause(&self) -> bool {
        self.can("pause") || self.can("play")
    }

    /// Previous can always restart the track, even on the first track of a context.
    fn can_go_previous(&self) -> bool {
        self.can("skip_prev") || self.can("seek")
    }

    fn set_options(&mut self, options: &Json) {
        self.shuffle = options["shuffle"].as_bool().unwrap_or(false);
        self.repeat = options["repeat"].as_str().unwrap_or("off").to_owned();
    }

    fn playback_status(&self) -> &'static str {
        if !self.connected || self.item.is_none() || self.status == "idle" || self.status.is_empty() {
            "Stopped"
        } else if self.status == "paused" {
            "Paused"
        } else {
            "Playing"
        }
    }

    fn can(&self, action: &str) -> bool {
        if self.detached {
            // everything works again once play restores the session
            return self.connected;
        }
        self.connected && self.item.is_some() && self.actions.iter().any(|a| a == action)
    }

    fn trackid(&self) -> String {
        let uri = self.uri();
        match uri.rsplit(':').next() {
            Some(id) if !uri.is_empty() => format!(
                "/org/mpris/MediaPlayer2/Track/{}",
                id.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect::<String>()
            ),
            _ => NO_TRACK.to_owned(),
        }
    }

    fn metadata(&self) -> HashMap<String, OwnedValue> {
        let mut meta = HashMap::new();
        let Some(item) = &self.item else { return meta };
        let mut put = |key: &str, value: Value<'_>| {
            if let Ok(v) = OwnedValue::try_from(value) {
                meta.insert(key.to_owned(), v);
            }
        };
        if let Ok(path) = ObjectPath::try_from(self.trackid()) {
            put("mpris:trackid", Value::from(path));
        }
        put("xesam:title", Value::from(entity_name(item).to_owned()));
        put("xesam:url", Value::from(item["uri"].as_str().unwrap_or("").to_owned()));
        let dec = &item["decorations"];
        let artists: Vec<String> = dec["creators"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|c| entity_name(&c["entity"]).to_owned())
            .filter(|a| !a.is_empty())
            .collect();
        if !artists.is_empty() {
            put("xesam:artist", Value::from(artists));
        }
        let album = entity_name(&dec["parent"]["entity"]);
        if !album.is_empty() {
            put("xesam:album", Value::from(album.to_owned()));
        }
        if let Some(duration) = dec["playback"]["duration_ms"].as_i64() {
            put("mpris:length", Value::from(duration * 1000));
        }
        let rank = |size: &str| match size {
            "large" => 0,
            "default" => 1,
            "xlarge" => 2,
            "small" => 3,
            _ => 9,
        };
        if let Some(cover) = dec["visual_identity"]["cover"]
            .as_array()
            .and_then(|covers| covers.iter().min_by_key(|c| rank(c["size"].as_str().unwrap_or(""))))
        {
            put("mpris:artUrl", Value::from(cover["url"].as_str().unwrap_or("").to_owned()));
        }
        meta
    }
}

#[derive(PartialEq)]
struct Snapshot {
    status: &'static str,
    item: Option<Json>,
    volume: f64,
    shuffle: bool,
    repeat: String,
    caps: [bool; 5],
}

type Shared = Arc<Mutex<State>>;

/// Sends commands to Soloist over the WebSocket; dropped while disconnected.
#[derive(Clone)]
struct Commands(mpsc::UnboundedSender<String>);

impl Commands {
    fn send(&self, command: &str, fields: Json) {
        let mut msg = json!({ "type": "command", "command": command });
        if let (Some(m), Some(f)) = (msg.as_object_mut(), fields.as_object()) {
            m.extend(f.clone());
        }
        let _ = self.0.send(msg.to_string());
    }

    fn simple(&self, command: &str) {
        self.send(command, json!({}));
    }

    /// Play a URI (or resume when None), taking over playback from other devices first.
    fn play(&self, state: &Shared, uri: Option<&str>) {
        if !state.lock().unwrap().is_active {
            self.simple("activate");
        }
        match uri {
            Some(uri) => self.send("play", json!({ "uri": uri })),
            None => self.simple("play"),
        }
    }
}

struct Root;

#[interface(name = "org.mpris.MediaPlayer2")]
impl Root {
    fn raise(&self) {}
    fn quit(&self) {}
    #[zbus(property)]
    fn can_quit(&self) -> bool {
        false
    }
    #[zbus(property)]
    fn can_raise(&self) -> bool {
        false
    }
    #[zbus(property)]
    fn has_track_list(&self) -> bool {
        false
    }
    #[zbus(property)]
    fn identity(&self) -> &str {
        "Spotify Soloist"
    }
    #[zbus(property)]
    fn supported_uri_schemes(&self) -> Vec<String> {
        vec!["spotify".to_owned()]
    }
    #[zbus(property)]
    fn supported_mime_types(&self) -> Vec<String> {
        Vec::new()
    }
}

struct Player {
    state: Shared,
    cmd: Commands,
    refresh: Arc<Notify>,
}

impl Player {
    /// Restores the dropped session, then runs `then` (e.g. skip_next); false if attached.
    fn restore_then(&self, then: Option<&'static str>) -> bool {
        if !self.state.lock().unwrap().detached {
            return false;
        }
        tokio::spawn(restore(self.state.clone(), self.cmd.clone(), self.refresh.clone(), then));
        true
    }
}

#[interface(name = "org.mpris.MediaPlayer2.Player")]
impl Player {
    fn next(&self) {
        if !self.restore_then(Some("skip_next")) {
            self.cmd.simple("skip_next");
        }
    }
    fn previous(&self) {
        if self.restore_then(Some("skip_prev")) {
            return;
        }
        let restart = {
            let s = self.state.lock().unwrap();
            // on the first track there's nothing to go back to, so restart it
            s.can("seek") && (s.position_ms() > RESTART_THRESHOLD_MS || !s.can("skip_prev"))
        };
        if restart {
            self.cmd.send("seek", json!({ "position_ms": 0 }));
        } else {
            self.cmd.simple("skip_prev");
        }
    }
    fn pause(&self) {
        self.cmd.simple("pause");
    }
    fn stop(&self) {
        self.cmd.simple("pause");
    }
    fn play(&self) {
        if !self.restore_then(None) {
            self.cmd.play(&self.state, None);
        }
    }
    fn play_pause(&self) {
        let playing = self.state.lock().unwrap().is_playing();
        if self.restore_then(None) {
        } else if playing {
            self.cmd.simple("pause");
        } else {
            self.cmd.play(&self.state, None);
        }
    }
    /// Per MPRIS, seeking past the end moves on to the next track.
    fn seek(&self, offset: i64) {
        let (pos, length) = {
            let s = self.state.lock().unwrap();
            (s.position_ms() + offset as f64 / 1000.0, s.length_ms())
        };
        if length.is_some_and(|len| pos >= len) {
            self.cmd.simple("skip_next");
        } else {
            self.cmd.send("seek", json!({ "position_ms": pos.max(0.0) as i64 }));
        }
    }
    /// Per MPRIS, ignored for another track or a position outside this one.
    fn set_position(&self, track_id: ObjectPath<'_>, position: i64) {
        let s = self.state.lock().unwrap();
        let pos_ms = position as f64 / 1000.0;
        if track_id.as_str() == s.trackid() && pos_ms >= 0.0 && s.length_ms().is_none_or(|len| pos_ms <= len) {
            self.cmd.send("seek", json!({ "position_ms": pos_ms as i64 }));
        }
    }
    fn open_uri(&self, uri: &str) {
        if uri.starts_with("spotify:") {
            self.state.lock().unwrap().detached = false;
            self.cmd.play(&self.state, Some(uri));
        }
    }

    #[zbus(signal)]
    async fn seeked(emitter: &SignalEmitter<'_>, position: i64) -> zbus::Result<()>;

    #[zbus(property)]
    fn playback_status(&self) -> &'static str {
        self.state.lock().unwrap().playback_status()
    }
    #[zbus(property)]
    fn loop_status(&self) -> &'static str {
        match self.state.lock().unwrap().repeat.as_str() {
            "track" => "Track",
            "context" => "Playlist",
            _ => "None",
        }
    }
    #[zbus(property)]
    fn set_loop_status(&self, value: String) {
        // off/context/track need the two repeat flags set in this order
        if value == "Track" {
            self.cmd.send("set_repeat_context", json!({ "enabled": false }));
            self.cmd.send("set_repeat_track", json!({ "enabled": true }));
        } else {
            self.cmd.send("set_repeat_track", json!({ "enabled": false }));
            self.cmd.send("set_repeat_context", json!({ "enabled": value == "Playlist" }));
        }
    }
    #[zbus(property)]
    fn rate(&self) -> f64 {
        1.0
    }
    #[zbus(property)]
    fn set_rate(&self, _value: f64) {}
    #[zbus(property)]
    fn shuffle(&self) -> bool {
        self.state.lock().unwrap().shuffle
    }
    #[zbus(property)]
    fn set_shuffle(&self, value: bool) {
        self.cmd.send("set_shuffle", json!({ "enabled": value }));
    }
    #[zbus(property)]
    fn metadata(&self) -> HashMap<String, OwnedValue> {
        self.state.lock().unwrap().metadata()
    }
    #[zbus(property)]
    fn volume(&self) -> f64 {
        self.state.lock().unwrap().volume
    }
    #[zbus(property)]
    fn set_volume(&self, value: f64) {
        let volume = (value * 100.0).round().clamp(0.0, 100.0) as i64;
        self.cmd.send("set_volume", json!({ "volume": volume }));
    }
    #[zbus(property(emits_changed_signal = "false"))]
    fn position(&self) -> i64 {
        (self.state.lock().unwrap().position_ms() * 1000.0) as i64
    }
    #[zbus(property)]
    fn minimum_rate(&self) -> f64 {
        1.0
    }
    #[zbus(property)]
    fn maximum_rate(&self) -> f64 {
        1.0
    }
    #[zbus(property)]
    fn can_go_next(&self) -> bool {
        self.state.lock().unwrap().can("skip_next")
    }
    #[zbus(property)]
    fn can_go_previous(&self) -> bool {
        self.state.lock().unwrap().can_go_previous()
    }
    #[zbus(property)]
    fn can_play(&self) -> bool {
        self.state.lock().unwrap().connected
    }
    #[zbus(property)]
    fn can_pause(&self) -> bool {
        self.state.lock().unwrap().can_pause()
    }
    #[zbus(property)]
    fn can_seek(&self) -> bool {
        self.state.lock().unwrap().can("seek")
    }
    #[zbus(property(emits_changed_signal = "const"))]
    fn can_control(&self) -> bool {
        true
    }
}

struct Chorus {
    state: Shared,
    cmd: Commands,
    playlists: tokio::sync::Mutex<Option<(Instant, String)>>,
}

#[interface(name = "org.chorus.Soloist")]
impl Chorus {
    async fn get_playlists(&self) -> fdo::Result<String> {
        let mut cache = self.playlists.lock().await;
        if let Some((at, json)) = cache.as_ref()
            && at.elapsed() < PLAYLIST_CACHE
        {
            return Ok(json.clone());
        }
        // webapi.py lives next to this binary and only runs while a list is being fetched
        let script = std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(|dir| dir.join("webapi.py")))
            .ok_or_else(|| fdo::Error::Failed("cannot locate webapi.py".into()))?;
        let out = tokio::process::Command::new("python3")
            .arg(script)
            .arg("json")
            .output()
            .await
            .map_err(|e| fdo::Error::Failed(e.to_string()))?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr);
            return Err(fdo::Error::Failed(err.lines().last().unwrap_or("webapi.py failed").to_owned()));
        }
        let json = String::from_utf8_lossy(&out.stdout).trim().to_owned();
        *cache = Some((Instant::now(), json.clone()));
        Ok(json)
    }

    fn play_uri(&self, uri: &str) {
        if uri.starts_with("spotify:") {
            self.state.lock().unwrap().detached = false;
            self.cmd.play(&self.state, Some(uri));
        }
    }

    fn status(&self) -> String {
        let s = self.state.lock().unwrap();
        json!({ "connected": s.connected, "logged_in": s.logged_in, "is_active": s.is_active })
            .to_string()
    }
}

/// Applies one Soloist event; returns true when it moved the position within the same
/// track (a seek), as opposed to normal progress, a pause/resume or a track change.
fn apply_event(state: &mut State, ev: &Json) -> bool {
    let expected = state.position_ms();
    let uri = state.uri().to_owned();
    let mut position_update = false;
    match ev["type"].as_str().unwrap_or("") {
        "playback_state" => {
            let active = ev["is_active"].as_bool().unwrap_or(false);
            if !active && (state.detached || state.saved.is_some()) && !state.restoring {
                // no session: keep showing the saved track instead of an empty state
                state.is_active = false;
                state.set_options(&ev["options"]);
                if !state.detached {
                    state.detach();
                }
                return false;
            }
            if active && state.detached && !state.restoring {
                // another device started playback here, it brought its own context
                state.detached = false;
            }
            if let Some(status) = ev["status"].as_str() {
                state.set_status(status);
            }
            state.item = ev.get("item").filter(|i| i.is_object()).cloned();
            state.context = ev["context"]["uri"].as_str().unwrap_or("").to_owned();
            if !state.restoring {
                // muted while restoring; clients keep seeing the real volume
                state.volume = ev["volume"].as_f64().unwrap_or(100.0) / 100.0;
            }
            state.set_options(&ev["options"]);
            state.actions = ev["available_actions"]
                .as_object()
                .map(|a| a.keys().cloned().collect())
                .unwrap_or_default();
            state.is_active = active;
            state.set_position(&ev["position"]);
            position_update = ev["position"].is_object();
        }
        "track_changed" if !state.detached || state.restoring => {
            state.item = ev.get("item").filter(|i| i.is_object()).cloned();
            state.pos_ms = 0.0;
            state.pos_stamp_ms = now_ms();
        }
        "context_changed" => {
            state.context = ev["context"]["uri"].as_str().unwrap_or("").to_owned();
        }
        "playback_changed" if !state.detached || state.restoring => {
            if let Some(status) = ev["status"].as_str() {
                state.set_status(status);
            }
        }
        "volume_changed" if !state.restoring => {
            state.volume = ev["volume"].as_f64().unwrap_or(100.0) / 100.0;
        }
        "options_changed" => state.set_options(&ev["options"]),
        "queue_changed" => {
            state.queue = Some(
                ev["upcoming"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|e| e["item"]["uri"].as_str().map(str::to_owned))
                    .collect(),
            );
        }
        "device_changed" => {
            state.is_active = ev["is_active"].as_bool().unwrap_or(false);
            if !state.is_active {
                state.detach();
            }
        }
        "position_sync" if !state.detached || state.restoring => {
            state.set_position(&ev["position"]);
            position_update = true;
        }
        "auth_state" => {
            state.logged_in = ev["logged_in"].as_bool().unwrap_or(false);
            state.is_active = ev["is_active"].as_bool().unwrap_or(false);
        }
        "error" => eprintln!("soloist error: {}", ev["message"].as_str().unwrap_or("?")),
        _ => {}
    }
    state.remember();
    position_update && !uri.is_empty() && state.uri() == uri
        && (state.position_ms() - expected).abs() > SEEK_JUMP_MS
}

/// Polls the shared state until `done` holds or `limit` passes.
async fn wait_for(state: &Shared, limit: Duration, done: impl Fn(&State) -> bool) -> bool {
    let start = Instant::now();
    while start.elapsed() < limit {
        if done(&state.lock().unwrap()) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    false
}

/// Brings back the saved playlist at the saved track and position after Spotify dropped
/// the session: Soloist can only start a context from its beginning, so this starts it
/// muted, skips forward to the track (or queues it when shuffled or far away), seeks,
/// and unmutes. Clients see none of the steps, only the result.
async fn restore(state: Shared, cmd: Commands, refresh: Arc<Notify>, then: Option<&'static str>) {
    let (saved, volume, shuffle) = {
        let mut s = state.lock().unwrap();
        if s.restoring || !s.detached {
            return;
        }
        let Some(saved) = s.saved.clone() else { return };
        s.restoring = true;
        (saved, s.volume, s.shuffle)
    };
    let volume = (volume * 100.0).round().clamp(0.0, 100.0) as i64;
    // Soloist ignores the volume until it's the active device, so take over first
    cmd.simple("activate");
    wait_for(&state, Duration::from_secs(5), |s| s.is_active).await;
    cmd.send("set_volume", json!({ "volume": 0 }));
    tokio::time::sleep(Duration::from_millis(100)).await;
    cmd.send("play", json!({ "uri": saved.context }));
    let started = wait_for(&state, Duration::from_secs(8), |s| {
        s.is_active && s.context == saved.context && !s.uri().is_empty() && s.is_playing()
    })
    .await;
    let at_track = |s: &State| s.uri() == saved.track;
    if started && !at_track(&state.lock().unwrap()) {
        let mut queued = shuffle;
        let mut skips = 1;
        if !shuffle {
            state.lock().unwrap().queue = None;
            cmd.send("get_queue", json!({ "limit": 0 }));
            wait_for(&state, Duration::from_secs(2), |s| {
                s.queue.as_ref().is_some_and(|q| q.contains(&saved.track))
            })
            .await;
            let index = state.lock().unwrap().queue.as_ref()
                .and_then(|q| q.iter().position(|t| *t == saved.track));
            match index {
                Some(i) if i < MAX_RESTORE_SKIPS => {
                    skips = i + 1;
                    for _ in 0..skips {
                        cmd.simple("skip_next");
                    }
                }
                _ => queued = true,
            }
        }
        if queued {
            // shuffled, or not found in order: play it next, the context continues after it
            cmd.send("add_to_queue", json!({ "uri": saved.track }));
            cmd.simple("skip_next");
        }
        // each skip loads a track, so allow more time the further it is
        wait_for(&state, Duration::from_millis(5000 + 150 * skips as u64), at_track).await;
    }
    if saved.pos_ms > RESTART_THRESHOLD_MS && at_track(&state.lock().unwrap()) {
        cmd.send("seek", json!({ "position_ms": saved.pos_ms as i64 }));
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    cmd.send("set_volume", json!({ "volume": volume }));
    tokio::time::sleep(Duration::from_millis(200)).await;
    {
        let mut s = state.lock().unwrap();
        s.restoring = false;
        s.detached = false;
        s.volume = volume as f64 / 100.0;
        s.remember();
    }
    if let Some(then) = then {
        cmd.simple(then);
    }
    refresh.notify_one();
}

/// Tells clients what differs between what they last saw and the current state.
async fn emit(player: &InterfaceRef<Player>, old: &Snapshot, seeked: bool) -> zbus::Result<Snapshot> {
    let p = player.get().await;
    let e = player.signal_emitter();
    let new = p.state.lock().unwrap().snapshot();
    if new.status != old.status {
        p.playback_status_changed(e).await?;
    }
    if new.item != old.item {
        p.metadata_changed(e).await?;
    }
    if new.volume != old.volume {
        p.volume_changed(e).await?;
    }
    if new.shuffle != old.shuffle {
        p.shuffle_changed(e).await?;
    }
    if new.repeat != old.repeat {
        p.loop_status_changed(e).await?;
    }
    if new.caps != old.caps {
        p.can_go_next_changed(e).await?;
        p.can_go_previous_changed(e).await?;
        p.can_pause_changed(e).await?;
        p.can_seek_changed(e).await?;
        p.can_play_changed(e).await?;
    }
    if seeked {
        let pos = (p.state.lock().unwrap().position_ms() * 1000.0) as i64;
        Player::seeked(e, pos).await?;
    }
    Ok(new)
}

async fn endpoint() -> Option<String> {
    let dir = data_dir();
    let addr = tokio::fs::read_to_string(dir.join("ws.addr")).await.ok()?;
    let port = tokio::fs::read_to_string(dir.join("ws.port")).await.ok()?;
    Some(format!("ws://{}:{}", addr.trim(), port.trim()))
}

/// Keeps a WebSocket connection to Soloist, reconnecting whenever it drops.
async fn follow_soloist(
    state: Shared,
    player: InterfaceRef<Player>,
    refresh: Arc<Notify>,
    mut rx: mpsc::UnboundedReceiver<String>,
) {
    let mut was_connected = false;
    // what clients last saw, so changes made during a restore are announced once at the end
    let mut client = state.lock().unwrap().snapshot();
    loop {
        let conn = match endpoint().await {
            Some(url) => tokio::time::timeout(Duration::from_secs(5), tokio_tungstenite::connect_async(url))
                .await
                .ok()
                .and_then(Result::ok),
            None => None,
        };
        if let Some((ws, _)) = conn {
            eprintln!("connected to soloist");
            was_connected = true;
            state.lock().unwrap().connected = true;
            let (mut write, mut read) = ws.split();
            // commands queued while disconnected are stale
            while rx.try_recv().is_ok() {}
            loop {
                tokio::select! {
                    msg = read.next() => match msg {
                        Some(Ok(Message::Text(text))) => {
                            let Ok(ev) = serde_json::from_str::<Json>(&text) else { continue };
                            let (seeked, quiet) = {
                                let mut s = state.lock().unwrap();
                                (apply_event(&mut s, &ev), s.restoring)
                            };
                            if !quiet {
                                match emit(&player, &client, seeked).await {
                                    Ok(new) => client = new,
                                    Err(e) => eprintln!("emit failed: {e}"),
                                }
                            }
                        }
                        Some(Ok(_)) => {}
                        Some(Err(e)) => { eprintln!("soloist connection lost: {e}"); break; }
                        None => { eprintln!("soloist connection closed"); break; }
                    },
                    cmd = rx.recv() => match cmd {
                        Some(cmd) => if write.send(Message::text(cmd)).await.is_err() { break },
                        None => return,
                    },
                    // a restore finished: announce where it ended up, the position jumped too
                    () = refresh.notified() => match emit(&player, &client, true).await {
                        Ok(new) => client = new,
                        Err(e) => eprintln!("emit failed: {e}"),
                    },
                }
            }
        }
        if was_connected {
            was_connected = false;
            {
                let mut s = state.lock().unwrap();
                s.connected = false;
                s.logged_in = false;
                s.is_active = false;
                s.restoring = false;
                s.detach();
            }
            if let Ok(new) = emit(&player, &client, false).await {
                client = new;
            }
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> zbus::Result<()> {
    let state: Shared = Arc::new(Mutex::new(State { volume: 1.0, saved: Saved::load(), ..Default::default() }));
    let (tx, rx) = mpsc::unbounded_channel();
    let cmd = Commands(tx);
    let refresh = Arc::new(Notify::new());

    let conn = zbus::connection::Builder::session()?
        .serve_at(PATH, Root)?
        .serve_at(PATH, Player { state: state.clone(), cmd: cmd.clone(), refresh: refresh.clone() })?
        .serve_at(PATH, Chorus { state: state.clone(), cmd, playlists: Default::default() })?
        .name(BUS_NAME)?
        .build()
        .await?;
    eprintln!("published {BUS_NAME}");

    let player = conn.object_server().interface::<_, Player>(PATH).await?;
    follow_soloist(state, player, refresh, rx).await;
    Ok(())
}
