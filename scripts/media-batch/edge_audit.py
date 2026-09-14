#!/usr/bin/env python3
"""Find straight seams that each display still shows at the edge of a wallpaper.

Simulates the app's crop (SceneFocus.filledFrame with the sidecar's focus/bleed)
for every display, then looks for long vertical/horizontal discontinuities near
each edge -- a painted panel boundary, the end of the painted area, matte -- that
fall inside the visible region. Writes a JSON report and, per flagged edge, a
crop of what the display shows with the seam marked, to look at before fixing.

    python3 scripts/media-batch/edge_audit.py FOLDER [FOLDER...] OUTDIR

Flags are candidates, not verdicts: long straight lines in the art (door frames,
poles, hair) also trip it. Seams far from the visible edge are usually art.
Needs numpy and Pillow. Keep DISPLAYS in step with the machine's screens.
"""
import json, subprocess, sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw

DISPLAYS = {'27in': (5120, 2880), 'mba': (2880, 1864)}
BAND = 0.12          # how far into the frame to look for seams
THRESH = 12          # grey-level step that counts as an edge
MIN_RUN = 0.22       # fraction of the frame's height/width a seam must span
SAMPLES = 8         # frames sampled across the loop
PAD_PX = 2           # crop this far past a seam


def clamp_bleed(b):
    return {k: min(max(float(b.get(k, 0)), 0), 0.45) for k in ('top', 'left', 'bottom', 'right')}


def filled_frame(content, bounds, focus, bleed):
    cw, ch = content; bw, bh = bounds
    m = clamp_bleed(bleed)
    sw = cw * max(1 - m['left'] - m['right'], 0.05); sh = ch * max(1 - m['top'] - m['bottom'], 0.05)
    s = max(bw / cw, bh / ch, bw / sw, bh / sh)
    fw, fh = cw * s, ch * s

    def off(span, across, lead, trail, t):
        v = -(span - across) * t
        lo = across - span * (1 - trail); hi = -span * lead
        if lo > hi: return (lo + hi) / 2
        return min(max(v, lo), hi)
    x = off(fw, bw, m['left'], m['right'], focus[0])
    y = off(fh, bh, m['bottom'], m['top'], 1 - focus[1])
    return x, y, fw, fh


def visible(content, display, focus, bleed):
    """Visible region in unit coords from the top-left: (left, top, right, bottom)."""
    bw, bh = display
    x, y, fw, fh = filled_frame(content, display, focus, bleed)
    left = -x / fw; top = (y + fh - bh) / fh
    return left, top, left + bw / fw, top + bh / fh


def probe(path):
    out = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                          'stream=width,height:format=duration', '-of', 'json', str(path)],
                         capture_output=True, text=True, check=True).stdout
    d = json.loads(out)
    return d['streams'][0]['width'], d['streams'][0]['height'], float(d['format']['duration'])


def frame(path, t, w, h):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-ss', f'{t:.2f}', '-i', str(path), '-frames:v', '1',
                          '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(h, w, 3)


def seam_profile(grey, axis_len_px, vertical):
    """Per position (column if vertical), the fraction of the other axis crossed by a same-sign step."""
    g = grey if vertical else grey.T
    d = g[:, 2:].astype(np.int16) - g[:, :-2].astype(np.int16)   # step centred on column x+1
    pos = d > THRESH; neg = d < -THRESH
    # Tolerate slightly tilted or antialiased edges: a hit within 2 columns counts.
    def spread(m):
        out = m.copy()
        for k in (1, 2):
            out[:, k:] |= m[:, :-k]; out[:, :-k] |= m[:, k:]
        return out
    frac = np.maximum(spread(pos).mean(0), spread(neg).mean(0))
    return np.concatenate([[0], frac, [0]])


def profiles(img):
    grey = img.mean(2).astype(np.uint8)
    return seam_profile(grey, None, True), seam_profile(grey, None, False)


def worst_profile(profs):
    """Maximum across frames: scenes drift over a loop, so a seam counts wherever any frame shows it."""
    return np.maximum.reduce(profs)


def audit(path, outdir):
    w, h, dur = probe(path)
    sidecar = path.with_suffix('.framing.json')
    framing = json.loads(sidecar.read_text()) if sidecar.exists() else {}
    focus = (framing.get('focus', {}).get('x', 0.5), framing.get('focus', {}).get('y', 0.5))
    bleed = framing.get('bleed', {})
    times = [dur * (i + 0.5) / SAMPLES for i in range(SAMPLES)]
    frames = [frame(path, t, w, h) for t in times]
    ps = [profiles(f) for f in frames]
    col = worst_profile([c for c, _ in ps]); row = worst_profile([r for _, r in ps])
    bx, by = int(w * BAND), int(h * BAND)
    bands = {'left': [(x, col[x]) for x in range(1, bx)], 'right': [(x, col[x]) for x in range(w - bx, w - 1)],
             'top': [(y, row[y]) for y in range(1, by)], 'bottom': [(y, row[y]) for y in range(h - by, h - 1)]}
    report = {'name': path.stem, 'size': [w, h], 'bleed': bleed, 'focus': focus, 'displays': {}, 'flags': []}
    for dname, dsize in DISPLAYS.items():
        report['displays'][dname] = visible((w, h), dsize, focus, bleed)
    for dname in DISPLAYS:
        l, t, r, b = report['displays'][dname]
        edges = {'left': (l * w, w), 'right': (r * w, w), 'top': (t * h, h), 'bottom': (b * h, h)}
        for edge, (limit, span) in edges.items():
            stable = [(p, f) for p, f in bands[edge] if f >= MIN_RUN]
            if edge in ('left', 'top'):
                inview = [(p, f) for p, f in stable if p > limit + 1]
                if not inview: continue
                p, f = max(inview, key=lambda s: s[0])   # innermost seam in the band
                proposal = (p + PAD_PX) / span
            else:
                inview = [(p, f) for p, f in stable if p < limit - 1]
                if not inview: continue
                p, f = min(inview, key=lambda s: s[0])
                proposal = 1 - (p - PAD_PX) / span
            report['flags'].append({'display': dname, 'edge': edge, 'seam_px': int(p), 'run': round(float(f), 2),
                                    'visible_edge_px': round(limit, 1), 'shown_px': round(abs(limit - p), 1),
                                    'proposed_bleed': round(proposal, 4)})
    if report['flags']:
        e = report['flags'][0]; k = 0 if e['edge'] in ('left', 'right') else 1
        best = max(range(len(frames)), key=lambda i: ps[i][k][e['seam_px']])
        sheet(path.stem, frames[best], report, outdir)
    return report


def sheet(name, img, report, outdir):
    h, w, _ = img.shape
    tiles = []
    for fl in report['flags']:
        e, p, lim = fl['edge'], fl['seam_px'], fl['visible_edge_px']
        if e in ('left', 'right'):
            x0 = int(max(0, min(p, lim) - 260)); x1 = int(min(w, max(p, lim) + 260))
            tile = Image.fromarray(img[:, x0:x1]).copy(); d = ImageDraw.Draw(tile)
            d.line([(lim - x0, 0), (lim - x0, h)], fill=(255, 0, 0), width=3)
            d.line([(p - x0, 0), (p - x0, h)], fill=(255, 255, 0), width=1)
            tile = tile.resize((tile.width // 2, h // 2))
        else:
            y0 = int(max(0, min(p, lim) - 200)); y1 = int(min(h, max(p, lim) + 200))
            tile = Image.fromarray(img[y0:y1]).copy(); d = ImageDraw.Draw(tile)
            d.line([(0, lim - y0), (w, lim - y0)], fill=(255, 0, 0), width=3)
            d.line([(0, p - y0), (w, p - y0)], fill=(255, 255, 0), width=1)
            tile = tile.resize((w // 4, tile.height // 2))
        tiles.append((e, tile))
    W = sum(t.width for _, t in tiles) + 20 * len(tiles); H = max(t.height for _, t in tiles) + 30
    out = Image.new('RGB', (W, H), (40, 40, 40)); d = ImageDraw.Draw(out); x = 0
    for (e, t), fl in zip(tiles, report['flags']):
        out.paste(t, (x, 30)); d.text((x + 4, 8), f"{fl['display']} {e} shows {fl['shown_px']}px run {fl['run']}", fill=(255, 255, 255))
        x += t.width + 20
    out.save(outdir / f'{name}.png')


def main():
    folders = [Path(p) for p in sys.argv[1:-1]]; outdir = Path(sys.argv[-1]); outdir.mkdir(parents=True, exist_ok=True)
    results = []
    videos = sorted(v for f in folders for v in f.glob('*.mp4'))
    for i, v in enumerate(videos, 1):
        try:
            r = audit(v, outdir)
        except Exception as e:
            r = {'name': v.stem, 'error': str(e)}
        results.append(r)
        flags = ', '.join(f"{f['display']} {f['edge']} {f['shown_px']}px" for f in r.get('flags', []))
        print(f'[{i}/{len(videos)}] {v.stem}: {flags or r.get("error", "clean")}', flush=True)
        (outdir / 'report.json').write_text(json.dumps(results, indent=1))


if __name__ == '__main__':
    main()
