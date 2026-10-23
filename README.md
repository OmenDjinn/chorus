# Chorus with Spotify Soloist

A modified version of [Chorus](https://github.com/Netherizzium/chorus) by Netherizzium, the KDE
Plasma 6 music bar with synced lyrics. It adds support for **Spotify Soloist**, Spotify's own
headless Linux player, and many appearance options.

## What's added

**Spotify Soloist** (Configure → Music App → Music app: *Spotify Soloist*)
- One-button install and update. Everything is per-user, no root needed. A weekly timer
  replaces Soloist builds before their 90-day expiry.
- Soloist API key field with show/hide, pairing instructions, and sign-in for the playlist list.
- A **Playlists** section in the popup: Liked Songs and your library, with covers.
- An MPRIS bridge so Soloist works with the widget, media keys and `playerctl`. It's written in
  Rust (about 2 MB of RAM), with a Python fallback. Previous restarts a song past 3 seconds,
  like Spotify.

**Look & Feel**
- Fonts: the theme font, any installed font (searchable list), or font files.
- **Pixel** text style using bundled pixel fonts (Micro 5, Press Start 2P, Silkscreen,
  Jacquard 12) that sit exactly on a pixel grid, so they render as crisp blocks.
- Lyrics position, line-change animation, scrolling and lyrics area width.
- Cover size, position and shape. Song name and artist next to the cover, with separate sizes
  or automatic fit.
- Ten button styles: classic, outline, disc, capsule, neon, pixel, sketch, vinyl, equalizer
  and theme icons.

## Layout

| Path | What it is |
|---|---|
| `package/` | The Plasma widget (install or link this as `net.netherizzium.chorus`) |
| `package/contents/code/soloist/` | Soloist installer, updater, bridge binary and Web API helper |
| `soloist-mpris-rs/` | Rust source of the bridge |
| `tests/` | Render checks for the button styles and pixel text (`qml tests/glyph-sheet.qml`) |

## Install

```sh
ln -s "$PWD/package" ~/.local/share/plasma/plasmoids/net.netherizzium.chorus
systemctl --user restart plasma-plasmashell
```

To rebuild the bridge, run `cargo build --release` in `soloist-mpris-rs/`, copy
`target/release/soloist-mpris` into `package/contents/code/soloist/`, then click
*Update Spotify Soloist* in the settings.

## Credits and licenses

- Chorus © Netherizzium, GPL-3.0. This modified version is also GPL-3.0 (see `LICENSE`).
- The fonts in `package/contents/fonts/` are under the SIL Open Font License 1.1 (see the
  `OFL-*.txt` files there).
- Spotify Soloist is Spotify's software under Spotify's terms. It is downloaded from Spotify
  when you install it and isn't included here.
