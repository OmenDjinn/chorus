#!/usr/bin/env python3
"""Spotify Web API access for the user's library, using their own developer app.

Run `webapi.py auth [CLIENT_ID]` once to log in (PKCE in the browser); tokens are
kept in ~/.config/soloist/webapi.json together with the client ID they belong to.
Without an argument the client ID configured in Chorus is used.
"""

import base64
import hashlib
import http.server
import json
import os
import re
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

CONFIG_DIR = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "soloist"
)
TOKEN_FILE = os.path.join(CONFIG_DIR, "webapi.json")
APPLETS_RC = os.path.expanduser("~/.config/plasma-org.kde.plasma.desktop-appletsrc")
REDIRECT_PORT = 8989
REDIRECT_URI = f"http://127.0.0.1:{REDIRECT_PORT}/login"
SCOPES = "playlist-read-private playlist-read-collaborative user-library-read"
CACHE_SECONDS = 60
SIGN_IN_TIMEOUT = 300

_lock = threading.Lock()
_cache = {"at": 0.0, "json": None}


def chorus_client_id():
    with open(APPLETS_RC) as f:
        m = re.search(r"^spotifyClientId=([0-9a-f]{32})\s*$", f.read(), re.M)
    if not m:
        raise RuntimeError("no Spotify client ID configured in Chorus")
    return m.group(1)


def _load():
    with open(TOKEN_FILE) as f:
        return json.load(f)


def client_id():
    # a refresh must use the app the tokens were issued to
    try:
        return _load()["client_id"]
    except (FileNotFoundError, KeyError, ValueError):
        return chorus_client_id()


def _post_token(fields, cid):
    body = urllib.parse.urlencode({"client_id": cid, **fields}).encode()
    req = urllib.request.Request("https://accounts.spotify.com/api/token", data=body)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def _save(tok, cid):
    tok["client_id"] = cid
    tok["expires_at"] = time.time() + tok.get("expires_in", 3600) - 60
    os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(tok, f)


def access_token():
    try:
        tok = _load()
    except FileNotFoundError:
        raise RuntimeError("not logged in: run webapi.py auth") from None
    if time.time() < tok.get("expires_at", 0):
        return tok["access_token"]
    cid = tok.get("client_id") or chorus_client_id()
    new = _post_token({"grant_type": "refresh_token", "refresh_token": tok["refresh_token"]}, cid)
    new.setdefault("refresh_token", tok["refresh_token"])
    _save(new, cid)
    return new["access_token"]


def get(path):
    url = path if path.startswith("https://") else "https://api.spotify.com/v1/" + path
    for _ in range(2):
        req = urllib.request.Request(url, headers={"Authorization": "Bearer " + access_token()})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(min(int(e.headers.get("Retry-After", "1")), 5))
                continue
            raise
    raise RuntimeError("rate limited by Spotify")


def _image(images):
    images = images or []
    if not images:
        return ""
    # smallest one that is still crisp at thumbnail size
    sized = [i for i in images if (i.get("width") or 0) >= 120]
    pick = min(sized, key=lambda i: i["width"]) if sized else images[0]
    return pick.get("url", "")


def playlists_json():
    with _lock:
        if _cache["json"] is not None and time.time() - _cache["at"] < CACHE_SECONDS:
            return _cache["json"]
        me = get("me")
        liked = get("me/tracks?limit=1")
        out = [{
            "uri": f"spotify:user:{me['id']}:collection",
            "name": "Liked Songs",
            "owner": "",
            "tracks": liked.get("total", 0),
            "image": "",
            "liked": True,
        }]
        page = get("me/playlists?limit=50")
        while page:
            for p in page.get("items") or []:
                if not p:
                    continue
                owner = p.get("owner") or {}
                count = (p.get("items") or p.get("tracks") or {}).get("total", 0)
                out.append({
                    "uri": p["uri"],
                    "name": p.get("name", ""),
                    "owner": "" if owner.get("id") == me["id"] else owner.get("display_name") or owner.get("id", ""),
                    "tracks": count,
                    "image": _image(p.get("images")),
                    "liked": False,
                })
            page = get(page["next"]) if page.get("next") else None
        _cache["json"] = json.dumps(out)
        _cache["at"] = time.time()
        return _cache["json"]


def authenticate(cid):
    if not re.fullmatch(r"[0-9a-f]{32}", cid or ""):
        raise RuntimeError("enter your Spotify app's client ID first")
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            ok = q.get("state", [""])[0] == state and "code" in q
            if ok:
                result["code"] = q["code"][0]
            self.send_response(200 if ok else 400)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Logged in, you can close this tab." if ok else b"Login failed.")

        def log_message(self, *a):
            pass

    server = http.server.HTTPServer(("127.0.0.1", REDIRECT_PORT), Handler)
    server.timeout = 1
    url = "https://accounts.spotify.com/authorize?" + urllib.parse.urlencode({
        "client_id": cid, "response_type": "code", "redirect_uri": REDIRECT_URI,
        "code_challenge_method": "S256", "code_challenge": challenge,
        "scope": SCOPES, "state": state,
    })
    print("Opening the Spotify login page; if it doesn't open, visit:\n" + url)
    webbrowser.open(url)
    # give up if the browser tab is closed without logging in
    deadline = time.time() + SIGN_IN_TIMEOUT
    while "code" not in result:
        if time.time() > deadline:
            raise RuntimeError("timed out waiting for the browser login")
        server.handle_request()
    server.server_close()
    tok = _post_token({"grant_type": "authorization_code", "code": result["code"],
                       "redirect_uri": REDIRECT_URI, "code_verifier": verifier}, cid)
    _save(tok, cid)
    print("Logged in.")


if __name__ == "__main__":
    if sys.argv[1:2] == ["auth"] and len(sys.argv) <= 3:
        try:
            cid = sys.argv[2] if len(sys.argv) == 3 else chorus_client_id()
        except (OSError, RuntimeError):
            cid = ""
        authenticate(cid)
    elif sys.argv[1:] == ["json"]:
        print(playlists_json())
    elif sys.argv[1:] == ["list"]:
        for p in json.loads(playlists_json()):
            print(p["tracks"], p["name"], p["owner"], p["uri"], p["image"][:50], sep=" | ")
    else:
        sys.exit("usage: webapi.py auth [CLIENT_ID]|json|list")
