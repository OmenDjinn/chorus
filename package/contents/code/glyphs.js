.pragma library

// Media button glyphs shared by PlayButton and SkipButton.
// kind:    "play" | "pause" | "next" | "prev"
// style:   "classic"   filled shapes
//          "outline"   thin strokes
//          "disc"      solid discs with the glyph cut out
//          "capsule"   the three buttons join into one solid pill, glyphs cut out
//          "neon"      glowing tube lines
//          "pixel"     8-bit glyphs on a pixel grid
//          "sketch"    wobbly hand-drawn double strokes
//          "vinyl"     play/pause as a record, skips as chevrons
//          "equalizer" pause becomes a level meter, skips are double triangles
//          ("icons" is handled by the buttons themselves with theme icons)
// segment: where a capsule button sits: "left" | "middle" | "right" | "single"
// Older configs may hold "rounded" (now classic) or "circle" (now disc).

var STYLES = ["classic", "outline", "disc", "capsule", "neon", "pixel", "sketch", "vinyl", "equalizer", "icons"];

function normalize(style) {
    if (style === "circle") return "disc";
    return STYLES.indexOf(style) >= 0 ? style : "classic";
}

// ---- shared shapes ---------------------------------------------------------------

// path of the classic glyph centred on (cx, cy); g is the glyph's half size
function tracePath(ctx, kind, cx, cy, g) {
    ctx.beginPath();
    if (kind === "play") {
        ctx.moveTo(cx - g * 0.6, cy - g * 0.85);
        ctx.lineTo(cx - g * 0.6, cy + g * 0.85);
        ctx.lineTo(cx + g * 0.8, cy);
        ctx.closePath();
    } else if (kind === "pause") {
        var bw = Math.max(2, g * 0.38);
        var bh = g * 1.7;
        var gap = g * 0.26;
        ctx.roundedRect(cx - gap - bw, cy - bh / 2, bw, bh, bw / 2, bw / 2);
        ctx.roundedRect(cx + gap, cy - bh / 2, bw, bh, bw / 2, bw / 2);
    } else {
        var dir = kind === "next" ? 1 : -1;
        ctx.moveTo(cx - dir * g * 0.75, cy - g * 0.8);
        ctx.lineTo(cx - dir * g * 0.75, cy + g * 0.8);
        ctx.lineTo(cx + dir * g * 0.45, cy);
        ctx.closePath();
        var w = Math.max(1.5, g * 0.18);
        var h = g * 1.6;
        var x = dir > 0 ? cx + g * 0.55 : cx - g * 0.55 - w;
        ctx.roundedRect(x, cy - h / 2, w, h, w / 2, w / 2);
    }
}

// the same glyph as polylines, for styles that stroke rather than fill
function outlinePoints(kind, cx, cy, g) {
    if (kind === "play")
        return [[[cx - g * 0.55, cy - g * 0.8], [cx - g * 0.55, cy + g * 0.8], [cx + g * 0.75, cy], [cx - g * 0.55, cy - g * 0.8]]];
    if (kind === "pause")
        return [[[cx - g * 0.42, cy - g * 0.8], [cx - g * 0.42, cy + g * 0.8]],
                [[cx + g * 0.42, cy - g * 0.8], [cx + g * 0.42, cy + g * 0.8]]];
    var d = kind === "next" ? 1 : -1;
    return [[[cx - d * g * 0.7, cy - g * 0.75], [cx - d * g * 0.7, cy + g * 0.75], [cx + d * g * 0.35, cy], [cx - d * g * 0.7, cy - g * 0.75]],
            [[cx + d * g * 0.65, cy - g * 0.75], [cx + d * g * 0.65, cy + g * 0.75]]];
}

function strokeLines(ctx, lines) {
    ctx.beginPath();
    for (var i = 0; i < lines.length; i++) {
        var pts = lines[i];
        ctx.moveTo(pts[0][0], pts[0][1]);
        for (var j = 1; j < pts.length; j++) ctx.lineTo(pts[j][0], pts[j][1]);
    }
    ctx.stroke();
}

function knockOut(ctx, fn) {
    ctx.globalCompositeOperation = "destination-out";
    fn();
    ctx.globalCompositeOperation = "source-over";
}

// ---- styles -----------------------------------------------------------------------

function drawDisc(ctx, kind, cx, cy, s) {
    var r = s * 0.42;
    var big = kind === "play" || kind === "pause";
    ctx.beginPath();
    ctx.arc(cx, cy, big ? r : r * 0.82, 0, Math.PI * 2);
    ctx.globalAlpha = big ? 1 : 0.85;
    ctx.fill();
    ctx.globalAlpha = 1;
    knockOut(ctx, function () {
        tracePath(ctx, kind, kind === "play" ? cx + s * 0.03 : cx, cy, s * (big ? 0.22 : 0.17));
        ctx.fill();
    });
}

function drawCapsule(ctx, kind, w, h, s, segment) {
    var ph = Math.min(h, s) * 0.8;
    var top = (h - ph) / 2, r = ph / 2;
    var roundL = segment === "left" || segment === "single";
    var roundR = segment === "right" || segment === "single";
    // a sliver of overlap so neighbouring segments join without a seam
    var x0 = roundL ? w / 2 - s * 0.45 : -1;
    var x1 = roundR ? w / 2 + s * 0.45 : w + 1;
    ctx.beginPath();
    ctx.moveTo(x0 + (roundL ? r : 0), top);
    ctx.lineTo(x1 - (roundR ? r : 0), top);
    if (roundR) ctx.arc(x1 - r, top + r, r, -Math.PI / 2, Math.PI / 2);
    else ctx.lineTo(x1, top + ph);
    ctx.lineTo(x0 + (roundL ? r : 0), top + ph);
    if (roundL) ctx.arc(x0 + r, top + r, r, Math.PI / 2, Math.PI * 1.5);
    else ctx.lineTo(x0, top);
    ctx.closePath();
    ctx.fill();
    knockOut(ctx, function () {
        tracePath(ctx, kind, w / 2, h / 2, s * (kind === "play" || kind === "pause" ? 0.22 : 0.18));
        ctx.fill();
    });
}

function drawNeon(ctx, kind, cx, cy, s, color) {
    var lines = outlinePoints(kind, cx, cy, s * 0.3);
    ctx.shadowColor = color;
    // a wide soft glow, then a brighter core on top
    ctx.shadowBlur = s * 0.35;
    ctx.lineWidth = Math.max(1.5, s * 0.07);
    ctx.globalAlpha = 0.55;
    strokeLines(ctx, lines);
    ctx.shadowBlur = s * 0.12;
    ctx.lineWidth = Math.max(1, s * 0.035);
    ctx.globalAlpha = 1;
    strokeLines(ctx, lines);
    ctx.shadowBlur = 0;
}

var PIXELS = {
    play:  ["#....", "##...", "###..", "####.", "#####", "####.", "###..", "##...", "#...."],
    pause: ["###..###", "###..###", "###..###", "###..###", "###..###", "###..###", "###..###", "###..###", "###..###"],
    next:  ["#.....##", "##....##", "###...##", "####..##", "#####.##", "####..##", "###...##", "##....##", "#.....##"],
    prev:  ["##.....#", "##....##", "##...###", "##..####", "##.#####", "##..####", "##...###", "##....##", "##.....#"]
};

function drawPixel(ctx, kind, cx, cy, s) {
    var rows = PIXELS[kind];
    var px = Math.max(1, Math.round(s * 0.068));
    var x0 = Math.round(cx - px * rows[0].length / 2), y0 = Math.round(cy - px * rows.length / 2);
    var gap = px >= 4 ? 1 : 0;
    for (var y = 0; y < rows.length; y++)
        for (var x = 0; x < rows[y].length; x++)
            if (rows[y][x] === "#") ctx.fillRect(x0 + x * px, y0 + y * px, px - gap, px - gap);
}

// deterministic jitter, so a glyph looks the same on every repaint
function wobble(seed) {
    var v = seed;
    return function () {
        v = (v * 1103515245 + 12345) % 2147483648;
        return v / 2147483648 - 0.5;
    };
}

function drawSketch(ctx, kind, cx, cy, s) {
    var g = s * 0.3;
    // pencil hatching inside the shape first
    ctx.save();
    tracePath(ctx, kind, cx, cy, g * 1.05);
    ctx.clip();
    ctx.lineWidth = Math.max(1, s * 0.025);
    ctx.globalAlpha = 0.7;
    ctx.beginPath();
    var step = Math.max(2, s * 0.075);
    for (var hx = cx - g * 2.2; hx < cx + g * 2.2; hx += step) {
        ctx.moveTo(hx, cy + g * 1.1);
        ctx.lineTo(hx + g * 1.2, cy - g * 1.1);
    }
    ctx.stroke();
    ctx.restore();

    var lines = outlinePoints(kind, cx, cy, g);
    var amp = s * 0.05;
    ctx.lineWidth = Math.max(1.2, s * 0.045);
    // two passes with different jitter read as pencil strokes
    for (var pass = 0; pass < 2; pass++) {
        var rnd = wobble(kind.length * 97 + pass * 31 + 7);
        ctx.globalAlpha = pass === 0 ? 1 : 0.6;
        ctx.beginPath();
        for (var i = 0; i < lines.length; i++) {
            var pts = lines[i];
            ctx.moveTo(pts[0][0] + rnd() * amp, pts[0][1] + rnd() * amp);
            for (var j = 1; j < pts.length; j++) {
                var ax = pts[j - 1][0], ay = pts[j - 1][1], bx = pts[j][0], by = pts[j][1];
                var mx = (ax + bx) / 2 + rnd() * amp * 1.6, my = (ay + by) / 2 + rnd() * amp * 1.6;
                ctx.quadraticCurveTo(mx, my, bx + rnd() * amp, by + rnd() * amp);
            }
        }
        ctx.stroke();
    }
    ctx.globalAlpha = 1;
}

function drawVinyl(ctx, kind, cx, cy, s) {
    if (kind === "next" || kind === "prev") {
        // a pair of chevrons
        var d = kind === "next" ? 1 : -1, g = s * 0.16;
        ctx.lineWidth = Math.max(1.5, s * 0.07);
        ctx.beginPath();
        for (var k = 0; k < 2; k++) {
            var ox = cx + d * (k * g * 1.1 - g * 0.55);
            ctx.moveTo(ox - d * g * 0.5, cy - g);
            ctx.lineTo(ox + d * g * 0.5, cy);
            ctx.lineTo(ox - d * g * 0.5, cy + g);
        }
        ctx.stroke();
        return;
    }
    var r = s * 0.43;
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.fill();
    knockOut(ctx, function () {
        // grooves
        ctx.lineWidth = Math.max(0.8, s * 0.018);
        for (var i = 0; i < 3; i++) {
            ctx.beginPath();
            ctx.arc(cx, cy, r * (0.86 - i * 0.12), 0, Math.PI * 2);
            ctx.stroke();
        }
        // the label, with the play/pause glyph left on it
        ctx.beginPath();
        ctx.arc(cx, cy, r * 0.42, 0, Math.PI * 2);
        ctx.fill();
    });
    ctx.globalAlpha = 0.9;
    tracePath(ctx, kind, kind === "play" ? cx + s * 0.015 : cx, cy, s * 0.1);
    ctx.fill();
    ctx.globalAlpha = 1;
}

function drawEqualizer(ctx, kind, cx, cy, s) {
    var g = s * 0.3;
    if (kind === "pause") {
        // a level meter: it shows "now playing" and pauses when pressed
        var heights = [0.55, 1.0, 0.75, 0.4];
        var bw = Math.max(2, s * 0.085), gap = Math.max(1, s * 0.045);
        var total = heights.length * bw + (heights.length - 1) * gap;
        var base = cy + g * 0.85;
        for (var i = 0; i < heights.length; i++) {
            var h = g * 1.7 * heights[i];
            var x = cx - total / 2 + i * (bw + gap);
            ctx.beginPath();
            ctx.roundedRect(x, base - h, bw, h, bw / 2, bw / 2);
            ctx.fill();
        }
        return;
    }
    if (kind === "play") {
        tracePath(ctx, "play", cx, cy, g);
        ctx.fill();
        return;
    }
    // fast-forward / rewind: two triangles
    var d = kind === "next" ? 1 : -1;
    ctx.beginPath();
    for (var k = 0; k < 2; k++) {
        var ox = cx + d * (k - 0.5) * g * 0.95;
        ctx.moveTo(ox - d * g * 0.5, cy - g * 0.65);
        ctx.lineTo(ox - d * g * 0.5, cy + g * 0.65);
        ctx.lineTo(ox + d * g * 0.5, cy);
        ctx.closePath();
    }
    ctx.fill();
}

// ---- entry point --------------------------------------------------------------------

function draw(ctx, kind, style, width, height, size, color, segment) {
    ctx.reset();
    var s = size;
    var cx = width / 2, cy = height / 2;
    ctx.fillStyle = color;
    ctx.strokeStyle = color;
    ctx.lineJoin = "round";
    ctx.lineCap = "round";

    switch (normalize(style)) {
    case "outline":
        ctx.lineWidth = Math.max(1.2, s * 0.055);
        strokeLines(ctx, outlinePoints(kind, cx, cy, s * 0.33));
        break;
    case "disc": drawDisc(ctx, kind, cx, cy, s); break;
    case "capsule": drawCapsule(ctx, kind, width, height, s, segment || "single"); break;
    case "neon": drawNeon(ctx, kind, cx, cy, s, color); break;
    case "pixel": drawPixel(ctx, kind, cx, cy, s); break;
    case "sketch": drawSketch(ctx, kind, cx, cy, s); break;
    case "vinyl": drawVinyl(ctx, kind, cx, cy, s); break;
    case "equalizer": drawEqualizer(ctx, kind, cx, cy, s); break;
    default:
        tracePath(ctx, kind, cx, cy, s * 0.34);
        ctx.fill();
    }
}

function iconName(kind) {
    return kind === "play" ? "media-playback-start"
         : kind === "pause" ? "media-playback-pause"
         : kind === "next" ? "media-skip-forward"
         : "media-skip-backward";
}
