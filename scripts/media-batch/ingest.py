#!/usr/bin/env python3
"""Turn one Spine lobby into an installed wallpaper, or re-render one with a new crop.

    # a lobby already extracted into the workspace, by asset id
    python3 scripts/media-batch/ingest.py hanako_home

    # a folder or ZIP of .skel/.atlas/.png, or a lobby fetched with BA-AD
    python3 scripts/media-batch/ingest.py ~/Downloads/ch0400_home.zip --title Someone
    python3 scripts/media-batch/ingest.py --fetch ch0400_home --title Someone

    # re-render an installed export so the crop box saved in its framing sidecar
    # becomes the camera (free when its textures were already upscaled)
    python3 scripts/media-batch/ingest.py --reframe ".../Hina-Restored-4K60.mp4" --from-sidecar

Every run renders a preview first and reports matte before anything slow or paid
happens; --preview stops there. Texture upscaling is the only billable step. It
runs only when the lobby has never been upscaled, is quoted from past runs first,
is capped by restore_modal.py's 15-minute timeout with no retries, and needs a
yes at the prompt or --yes. Installing over an existing export archives the old
file first, then renames the new one over it atomically, so a wallpaper playing
it never reads a half-written file and Library bookmarks resolve by path.
"""
import argparse, datetime, importlib.util, json, math, os, re, shutil, struct, subprocess, sys, tempfile, zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
DEFAULT_WORKSPACE = REPO / 'build/ba-export-study'
DEFAULT_OUTPUT = Path.home() / 'Pictures/Wallpapers/Blue Archive/Live2D Restored'
PLAN_SOURCE = 'Blue Archive Japan Windows assets previously retrieved using BA-AD; not publisher wallpaper downloads'
PLAN_MODEL = 'realesr-animevideov3 x4 downsampled to 2x; original alpha Lanczos'
# Modal's published list prices for what restore_modal.py asks for: one L4,
# 8 CPU cores, 16 GiB. Only used to quote; the bill is Modal's.
L4_PER_SECOND = 0.000222
CPU_CORE_PER_SECOND = 0.0000131
MEMORY_GIB_PER_SECOND = 0.00000222
CONTAINER_SECONDS = L4_PER_SECOND + 8 * CPU_CORE_PER_SECOND + 16 * MEMORY_GIB_PER_SECOND
# Image pull, weight download and model load before the first texture, measured
# loosely from past runs; the quote rounds up rather than down.
STARTUP_SECONDS = 120
TIMEOUT_SECONDS = 900
# A display-time trim is for strips: past this much of an edge it crops composition
# on every display, and a fitted camera keeps more sharpness for the same result.
TRIM_LIMIT = 0.15
# Matte is measured on a 1920-wide preview, so round the trim out a little.
TRIM_MARGIN = 0.003
# The most estimated work one job is allowed to take on, leaving the cap room
# for a slow container rather than cutting a batch off half-way.
BATCH_SECONDS = 600


def ensure_pillow(workspace):
    """calibrate.py needs Pillow; re-run under the workspace venv when this Python lacks it."""
    try:
        import PIL  # noqa: F401
    except ImportError:
        venv = workspace / '.venv/bin/python'
        if not venv.exists() or Path(sys.executable).resolve() == venv.resolve():
            sys.exit('Pillow is required: run with the workspace venv (build/ba-export-study/.venv/bin/python).')
        os.execv(str(venv), [str(venv), __file__] + sys.argv[1:])


APP_DEFAULTS = 'com.teamleaderleo.idlesse.app'


def register_with_app(workspace):
    """Tell Idlesse where this tool lives, so its framing editor can offer a re-render.

    Only paths are recorded. The app runs --reframe without --yes, so it can never
    start a paid upscale: a lobby that still needs one stops at the quote.
    """
    # An app launched from the Finder gets a minimal PATH without Homebrew's ffmpeg
    # or a user-installed modal, so hand over the PATH this shell found them on.
    for key, value in (('IdlessePipelineInterpreter', sys.executable), ('IdlessePipelineScript', str(Path(__file__).resolve())),
                       ('IdlessePipelineWorkspace', str(workspace)), ('IdlessePipelinePath', os.environ.get('PATH', ''))):
        subprocess.run(['defaults', 'write', APP_DEFAULTS, key, '-string', value], check=False, capture_output=True)


LIBRARY_INBOX = Path.home() / 'Library/Application Support/Idlesse/Library/Inbox'


def queue_for_library(media, log):
    """Leave a note for Idlesse to add `media` to the Library.

    The app watches this folder and adds the file itself (or refreshes it, when it
    is already there), so its bookmark is minted by the app that has to read it.
    """
    LIBRARY_INBOX.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime('%Y%m%dT%H%M%S%f')
    partial = LIBRARY_INBOX / f'.{stamp}-{os.getpid()}.partial'
    partial.write_text(json.dumps({'media': str(media)}))
    os.replace(partial, LIBRARY_INBOX / f'{stamp}-{os.getpid()}.json')
    log('Idlesse adds it to the Library as soon as it is running.')


def emit(enabled, event, **fields):
    """One machine-readable line for the app; plain logs stay human text."""
    if enabled:
        print('IDLESSE ' + json.dumps({'event': event, **fields}), flush=True)


NAMES_URL = 'https://schaledb.com/data/en/students.min.json'


def update_names(workspace, log):
    """Cache lobby names from SchaleDB, whose student DevName is the lobby's code (CH0064 is ch0064_home)."""
    import urllib.request
    request = urllib.request.Request(NAMES_URL, headers={'User-Agent': 'Idlesse media pipeline'})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read(16 * 1024 * 1024 + 1)
    if len(data) > 16 * 1024 * 1024:
        raise SystemExit('The name list is unexpectedly large; not caching it.')
    students = json.loads(data)
    students = students.values() if isinstance(students, dict) else students
    names = {}
    for student in students:
        code, name = str(student.get('DevName', '')), student.get('Name')
        if re.fullmatch(r'CH\d{4}', code, re.I) and isinstance(name, str):
            names[f'{code.lower()}_home'] = re.sub('-+', '-', re.sub(r'[^A-Za-z0-9]+', '-', name)).strip('-')
    (workspace / 'lobby-names.json').write_text(json.dumps({'source': NAMES_URL, 'names': names}, indent=2, sort_keys=True))
    log(f'Cached {len(names)} lobby names from SchaleDB.')


def known_titles(workspace, output):
    """Titles for an asset: installed receipts, then local plans, then cached SchaleDB names."""
    titles, installed = {}, {}
    cache = workspace / 'lobby-names.json'
    if cache.exists():
        try:
            titles.update(json.loads(cache.read_text()).get('names', {}))
        except ValueError:
            pass
    for plan in sorted(HERE.glob('plans/*.json')) + [HERE / 'batch.json']:
        try:
            for item in json.loads(plan.read_text())['items']:
                titles[item['id']] = item['title']
        except (OSError, ValueError, KeyError):
            continue
    for receipt in output.glob('*-Restored-4K60.source.json'):
        try:
            data = json.loads(receipt.read_text())
        except ValueError:
            continue
        if data.get('asset'):
            titles[data['asset']] = data.get('title') or titles.get(data['asset'])
            installed.setdefault(data['asset'], []).append(str(receipt.with_name(receipt.name.replace('.source.json', '.mp4'))))
    for receipt in output.glob('*-Restored-4K60.source.txt'):
        # Early exports wrote free-text receipts that still name the lobby they came from.
        try:
            text = receipt.read_text(errors='replace')[:65536]
        except OSError:
            continue
        for asset in set(re.findall(r'\b([a-z0-9]+(?:_[a-z0-9]+)*_home)\b', text)):
            installed.setdefault(asset, []).append(str(receipt.with_name(receipt.name.replace('.source.txt', '.mp4'))))
    return titles, installed


def list_lobbies(workspace, output):
    titles, installed = known_titles(workspace, output)
    lobbies = []
    for folder in sorted((workspace / 'assets-pc').iterdir()):
        if not folder.is_dir() or not list(folder.glob('*.skel')):
            continue
        asset = folder.name
        upscaled = restored_complete(workspace, asset)
        title = titles.get(asset) or default_title(asset)
        found = installed.get(asset, [])
        # Early exports carried a text receipt, so match those by the name they were installed under.
        if not found and title and (output / f'{title}-Restored-4K60.mp4').exists():
            found = [str(output / f'{title}-Restored-4K60.mp4')]
        entry = {'asset': asset, 'title': title, 'installed': found, 'upscaled': upscaled}
        if not upscaled:
            entry['quote'] = quote(workspace, asset)
        lobbies.append(entry)
    return lobbies


def find_modal():
    found = shutil.which('modal')
    if found:
        return found
    for candidate in sorted(Path.home().glob('Library/Python/*/bin/modal'), reverse=True):
        return str(candidate)
    return None


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f'{name}.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def png_size(path):
    with open(path, 'rb') as f:
        head = f.read(24)
    if head[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'Not a PNG: {path}')
    return struct.unpack('>II', head[16:24])


def default_title(asset):
    name = re.sub(r'_home$', '', asset)
    if re.fullmatch(r'ch\d+', name):
        return None
    return '-'.join(part.capitalize() for part in name.split('_'))


def safe_name(value):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', value):
        raise SystemExit(f'Use letters, digits, - and _ for names: {value!r}')
    return value


# --- sources -----------------------------------------------------------------

def adopt_source(source, workspace, asset_override):
    """Copy a folder or ZIP of Spine files into assets-pc/<id>; return the id."""
    source = Path(source).expanduser()
    with tempfile.TemporaryDirectory() as tmp:
        if source.suffix.lower() == '.zip':
            with zipfile.ZipFile(source) as archive:
                for member in archive.namelist():
                    if member.startswith('/') or '..' in Path(member).parts:
                        raise SystemExit(f'Refusing unsafe ZIP entry: {member}')
                archive.extractall(tmp)
            root = Path(tmp)
        else:
            root = source
        skels = sorted(p for p in root.rglob('*.skel') if not p.name.startswith('._'))
        if not skels:
            raise SystemExit(f'No .skel file in {source}')
        folder = skels[0].parent
        asset = safe_name(asset_override or folder.name if folder != Path(tmp) else asset_override or skels[0].stem.lower())
        dest = workspace / 'assets-pc' / asset
        files = [p for p in folder.iterdir() if p.suffix.lower() in ('.skel', '.atlas', '.png') and not p.name.startswith('._')]
        if dest.exists():
            same = {p.name for p in dest.iterdir()} == {p.name for p in files} and all(
                (dest / p.name).read_bytes() == p.read_bytes() for p in files)
            if not same:
                raise SystemExit(f'{dest} already holds different files; pass --asset to choose a new id.')
            return asset
        dest.mkdir(parents=True)
        for path in files:
            shutil.copy2(path, dest / path.name)
        print(f'Copied {len(files)} files into {dest}')
        return asset


def fetch(asset, workspace):
    """Download one lobby's Windows bundles with BA-AD and extract its Spine files."""
    baad = workspace / 'baad/baad'
    if not baad.exists():
        raise SystemExit(f'No BA-AD binary at {baad}')
    bundles = workspace / 'newer-windows'
    print(f'Fetching {asset} with BA-AD (Japan, Windows); this downloads only that lobby.', flush=True)
    subprocess.run([str(baad), 'download', 'japan', '--assets', '--platform', 'windows',
                    '--filter', f'spinelobbies-{asset}-', '--output', str(bundles)], cwd=workspace, check=True)
    python = workspace / '.venv/bin/python'
    subprocess.run([str(python), 'extract.py', asset], cwd=workspace, check=True)
    if not list((workspace / 'assets-pc' / asset).glob('*.skel')):
        raise SystemExit(f'BA-AD found nothing for {asset}; check the id against the game files.')


def stem_of(workspace, asset):
    skels = sorted((workspace / 'assets-pc' / asset).glob('*.skel'))
    main = [p for p in skels if p.stem.lower().endswith('_home')] or skels
    if not main:
        raise SystemExit(f'No skeleton in assets-pc/{asset}')
    return main[0].stem


# --- camera ------------------------------------------------------------------

def crop_to_camera(base, crop):
    """Camera that frames `crop`, a unit box of the frame `base` renders.

    The renderer maps a stage point p to 0.5 + (p - c) * zoom in frame units, so
    a point at q in the current frame sits at p = c + (q - 0.5) / zoom. Centre the
    box there and scale so its longer side (relative to the 16:9 frame) fills it:
    a box that is not 16:9 is shown whole, with a little extra around it.
    """
    zoom, cx, cy = base or [1.0, 0.5, 0.5]
    x, y, w, h = crop
    if not (0 <= x < 1 and 0 <= y < 1 and 0 < w <= 1 and 0 < h <= 1 and x + w <= 1.0001 and y + h <= 1.0001):
        raise SystemExit(f'Crop must be a unit box inside the frame: {crop}')
    return [round(zoom / max(w, h), 4), round(cx + (x + w / 2 - 0.5) / zoom, 4), round(cy + (y + h / 2 - 0.5) / zoom, 4)]


def recipe_for(cameras, stem, animation):
    entry = cameras.get(stem)
    if isinstance(entry, dict):
        return entry.get(animation) or entry.get('default')
    return entry


def with_recipe(cameras, stem, animation, camera):
    """Set a recipe for one animation without changing what the others use."""
    result = dict(cameras)
    entry = result.get(stem)
    if isinstance(entry, dict):
        result[stem] = {**entry, animation: camera}
    elif isinstance(entry, list) and entry != camera:
        result[stem] = {'default': entry, animation: camera}
    else:
        result[stem] = camera
    return result


def write_cameras(path, cameras):
    path.write_text(json.dumps(cameras, indent=2) + '\n')


# --- restoration -------------------------------------------------------------

def restored_complete(workspace, asset):
    source = workspace / 'assets-pc' / asset
    restored = workspace / 'assets-ai-batch' / asset
    if not restored.is_dir():
        return False
    for png in source.glob('*.png'):
        copy = restored / png.name
        if not copy.exists():
            return False
        w, h = png_size(png)
        if png_size(copy) != (w * 2, h * 2):
            return False
    return all((restored / p.name).exists() for p in source.iterdir() if p.suffix in ('.skel', '.atlas'))


def past_rate(workspace):
    """Seconds of GPU per source megapixel, from every past restoration report."""
    seconds = megapixels = 0.0
    for report in workspace.glob('*/restored.zip.json'):
        try:
            data = json.loads(report.read_text())
            for texture in data['textures']:
                seconds += texture['seconds']
                megapixels += texture['size'][0] * texture['size'][1] / 4 / 1e6
        except (ValueError, KeyError, TypeError):
            continue
    return seconds / megapixels if megapixels else 1.5


def quote(workspace, assets):
    """Estimate for one Modal job upscaling `assets` (an id or a list): one startup, shared."""
    assets = [assets] if isinstance(assets, str) else list(assets)
    pngs = [p for asset in assets for p in sorted((workspace / 'assets-pc' / asset).glob('*.png'))]
    megapixels = sum(math.prod(png_size(p)) for p in pngs) / 1e6
    work = megapixels * past_rate(workspace)
    estimate = STARTUP_SECONDS + work
    return {'textures': len(pngs), 'megapixels': round(megapixels, 1), 'gpuSeconds': round(work),
            'estimateSeconds': round(estimate), 'estimateUSD': estimate * CONTAINER_SECONDS,
            'capUSD': TIMEOUT_SECONDS * CONTAINER_SECONDS}


def confirm_paid(workspace, asset, yes):
    q = quote(workspace, asset)
    if q['estimateSeconds'] > BATCH_SECONDS:
        raise SystemExit(f'That is about {q["estimateSeconds"]}s of work, too close to the {TIMEOUT_SECONDS}s cap for one job; '
                         'upscale fewer lobbies at a time.')
    names = asset if isinstance(asset, str) else asset[0] if len(asset) == 1 else f'{len(asset)} lobbies together'
    print(f'\nUpscaling {names} needs one Modal L4 job: {q["textures"]} texture(s), {q["megapixels"]} MP.')
    print(f'  Estimate ~{q["estimateSeconds"]}s of container time (~{q["gpuSeconds"]}s on the GPU), about ${q["estimateUSD"]:.2f}.')
    print(f'  Hard cap: {TIMEOUT_SECONDS // 60} minutes, one container, no retries, so at most about ${q["capUSD"]:.2f}.')
    print('  Estimate uses list prices and your past runs; Modal bills the actual time.')
    if yes:
        print('  --yes given; starting.')
        return
    if not sys.stdin.isatty():
        raise SystemExit('Not starting a paid job without confirmation: rerun with --yes.')
    if input('Start it? [y/N] ').strip().lower() not in ('y', 'yes'):
        raise SystemExit('Stopped before anything was billed.')


def prepare_free_restore(workspace, asset, job):
    """run.py only calls Modal when the job lacks restored.zip; build it from textures we already have."""
    with zipfile.ZipFile(job / 'restored.zip', 'w', zipfile.ZIP_STORED) as archive:
        for png in sorted((workspace / 'assets-pc' / asset).glob('*.png')):
            archive.write(workspace / 'assets-ai-batch' / asset / png.name, f'{asset}/{png.name}')


def upscale_batch(workspace, assets, yes, json_events, log):
    """Upscale several lobbies in one Modal job, so each pays for its GPU seconds and not its own startup."""
    for asset in assets:
        safe_name(asset)
        if not list((workspace / 'assets-pc' / asset).glob('*.skel')):
            raise SystemExit(f'No lobby {asset} in assets-pc.')
    pending = sorted({asset for asset in assets if not restored_complete(workspace, asset)})
    skipped = sorted(set(assets) - set(pending))
    if skipped:
        log(f'Already upscaled, skipping: {", ".join(skipped)}')
    if not pending:
        emit(json_events, 'upscaled', assets=[], skipped=skipped)
        log('Nothing to upscale.')
        return
    modal = find_modal()
    if not modal:
        raise SystemExit('Upscaling needs the modal CLI, and it is not installed.')
    confirm_paid(workspace, pending, yes)
    job = workspace / f'upscale-{datetime.datetime.now():%Y%m%d-%H%M%S}'
    job.mkdir()
    plan = job / 'plan.json'
    plan.write_text(json.dumps({'schema': 1, 'model': PLAN_MODEL, 'source': PLAN_SOURCE, 'items': [
        {'id': asset, 'title': asset, 'stem': stem_of(workspace, asset), 'animation': 'Idle_01', 'seconds': 1}
        for asset in pending]}, indent=2))
    subprocess.run([sys.executable, str(HERE / 'run.py'), '--root', str(workspace), '--output', str(job / 'out'),
                    '--plan', str(plan), '--job-name', job.name, '--port', '0', '--modal', modal, '--restore-only'], check=True)
    missing = [asset for asset in pending if not restored_complete(workspace, asset)]
    if missing:
        raise SystemExit(f'The job finished but these are not fully upscaled: {", ".join(missing)}')
    report = job / 'restored.zip.json'
    seconds = json.loads(report.read_text()).get('seconds') if report.exists() else None
    emit(json_events, 'upscaled', assets=pending, skipped=skipped, gpuSeconds=seconds)
    log(f'Upscaled {len(pending)} lobbies; importing them is now local and free.')


# --- install -----------------------------------------------------------------

def tidy_job(job, staged_dir, names):
    """Drop an installed job's texture archives and staged media; its logs and reports stay.

    Each job otherwise keeps the lobby's textures twice over plus its render, and
    a batch of re-exports filled the disk with them."""
    for path in [job / 'input.zip', job / 'restored.zip', *(Path(staged_dir) / name for name in names[:2])]:
        path.unlink(missing_ok=True)

def install(staged_dir, names, output, replace, clear_framing, log):
    """Put a staged export in place. `names` is (video, poster, receipt, sidecar)."""
    video, poster, receipt, sidecar_name = names
    output.mkdir(parents=True, exist_ok=True)
    final = output / video
    stamp = datetime.date.today().isoformat()
    if final.exists():
        if not replace:
            raise SystemExit(f'{final} exists; pass --replace to archive it and install over it.')
        archive = output / f'superseded-{stamp}'
        archive.mkdir(exist_ok=True)
        for name in names:
            if (output / name).exists() and not (archive / name).exists():
                shutil.copy2(output / name, archive / name)
        log(f'Archived the previous export in {archive}')
    for name in (video, poster, receipt):
        # Copy beside the target, then rename over it. The rename is atomic, so a
        # wallpaper playing the old file keeps reading the old inode until it
        # reloads, instead of decoding a file being truncated and rewritten under
        # it. Library bookmarks resolve by path, so a new inode is found.
        partial = output / f'.{name}.partial'
        shutil.copyfile(staged_dir / name, partial)
        os.replace(partial, output / name)
    sidecar = output / sidecar_name
    if clear_framing and sidecar.exists():
        data = json.loads(sidecar.read_text())
        dropped = [k for k in ('bleed', 'focus') if data.pop(k, None) is not None]
        if dropped:
            if data:
                sidecar.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
            else:
                sidecar.unlink()
            log(f'The new camera replaces the sidecar {" and ".join(dropped)}; kept {sorted(data) or "nothing else"}.')
    return final


class Target:
    """What is being rendered, and where its camera, files and exporter live.

    `lobby` is a Blue Archive lobby from assets-pc, exported by run.py (and the
    only kind that can need a paid upscale). `spine` and `live2d` are Azur Lane
    models already exported by scripts/azur-lane/export.py from original textures;
    they only come through --reframe, which is always local.
    """
    def __init__(self, kind, workspace, asset, animation, title, output):
        self.kind, self.workspace, self.asset, self.animation, self.title, self.output = kind, workspace, asset, animation, title, output
        if kind == 'lobby':
            self.asset_path = f'assets-pc/{asset}'
            self.stem = stem_of(workspace, asset)
            self.tracked = HERE / 'cameras.json'
        else:
            self.asset_path = f'models/{asset}'
            self.stem = asset
            self.tracked = REPO / 'scripts/azur-lane' / kind / 'cameras.json'
        self.cameras_path = workspace / 'cameras.json'

    @property
    def names(self):
        if self.kind == 'lobby':
            base = f'{self.title}-Restored-4K60'
            return (f'{base}.mp4', f'{self.title}.jpg', f'{base}.source.json', f'{base}.framing.json')
        base = f'{self.title}-4K60'
        return (f'{base}.mp4', f'{self.title}.jpg', f'{base}.source.json', f'{base}.framing.json')

    def recipe(self, cameras):
        if self.kind == 'live2d':
            entry = cameras.get(self.stem)
            return list(entry['view']) if isinstance(entry, dict) and entry.get('view') else None
        return recipe_for(cameras, self.stem, self.animation)

    def with_camera(self, cameras, camera):
        if self.kind == 'live2d':
            # The Live2D recipe's number zooms the character alone; a crop frames the
            # whole stage, so it is kept beside that zoom as `view`.
            entry = cameras.get(self.stem, 1)
            zoom = entry if isinstance(entry, (int, float)) else entry.get('zoom', 1)
            return {**cameras, self.stem: {'zoom': zoom, 'view': camera}}
        return with_recipe(cameras, self.stem, self.animation, camera)

    def apply(self, calibrate, camera):
        cameras = json.loads(self.cameras_path.read_text()) if self.cameras_path.exists() else {}
        write_cameras(self.cameras_path, self.with_camera(cameras, camera))
        # The lobby and Spine renderers bundle their recipes; Live2D fetches them.
        if self.kind != 'live2d':
            calibrate.rebundle(self.workspace)

    def export(self, job, duration, modal, log, encoder='x265', edges='original'):
        staged = job / 'out'
        if self.kind == 'lobby':
            plan = job / 'plan.json'
            plan.write_text(json.dumps({'schema': 1, 'model': PLAN_MODEL, 'source': PLAN_SOURCE, 'items': [
                {'id': self.asset, 'title': self.title, 'stem': self.stem, 'animation': self.animation, 'seconds': duration}]}, indent=2))
            subprocess.run([sys.executable, str(HERE / 'run.py'), '--root', str(self.workspace), '--output', str(staged),
                            '--plan', str(plan), '--job-name', job.name, '--port', '0', '--modal', modal,
                            '--encoder', encoder, '--edges', edges], check=True)
        else:
            plan = job / 'plan.json'
            plan.write_text(json.dumps({'items': [{**self.item, 'animation': self.animation}]}, indent=2))
            azur = self.workspace.parent
            subprocess.run([sys.executable, str(REPO / 'scripts/azur-lane/export.py'), '--plan', str(plan),
                            '--live2d-root', str(azur / 'azur-render'), '--spine-root', str(azur / 'azur-spine'),
                            '--output', str(staged), '--job', str(job / 'state')], check=True)
        return staged


def azur_title(title):
    """export.py's file name for a plan title."""
    return re.sub('-+', '-', re.sub(r'[^\w.-]+', '-', title)).strip('-')


# --- main --------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('source', nargs='?', help='Asset id in assets-pc, or a folder or ZIP of Spine files')
    p.add_argument('--fetch', metavar='ASSET', help='Download this lobby with BA-AD first')
    p.add_argument('--reframe', type=Path, metavar='MEDIA', help='Re-render an installed export')
    p.add_argument('--asset', help='Id to store a folder or ZIP under (default: its folder name)')
    p.add_argument('--title', help='Name of the installed file, e.g. Hoshino-Swimsuit')
    p.add_argument('--animation', default='Idle_01')
    p.add_argument('--crop', type=float, nargs=4, metavar=('X', 'Y', 'W', 'H'),
                   help='Unit box of the current frame to keep, from its top-left')
    p.add_argument('--camera', type=float, nargs=3, metavar=('ZOOM', 'CX', 'CY'), help='Use this camera recipe (before --crop)')
    p.add_argument('--fit', action='store_true', help='Zoom and recentre the camera until the preview shows no matte')
    p.add_argument('--fit-toward', type=float, nargs=2, default=[0.5, 0.5], metavar=('X', 'Y'),
                   help='Where --fit leans when the painted area has room to spare; 0.5 0 keeps the top of a tall scene')
    p.add_argument('--trim-edges', action='store_true',
                   help='Keep the camera and crop thin matte strips at display time instead, through the framing sidecar')
    p.add_argument('--from-sidecar', action='store_true', help='With --reframe, use the crop box saved by the framing editor')
    p.add_argument('--preview', action='store_true', help='Render and measure the preview, then stop')
    p.add_argument('--allow-matte', action='store_true', help='Export even if the preview shows matte')
    p.add_argument('--replace', action='store_true', help='Archive and replace an existing export of the same title')
    p.add_argument('--yes', action='store_true', help='Start a quoted paid upscale without prompting')
    p.add_argument('--fast-encode', action='store_true',
                   help='Encode on the GPU in about a minute instead of x265 10-bit, at the cost of banding in soft gradients')
    p.add_argument('--edges', choices=['smooth', 'original'],
                   help="Lobby silhouettes: smooth evens out the art's stair-stepped outlines (default, or what the "
                        're-rendered export used); original keeps them exactly as painted')
    p.add_argument('--no-library', action='store_true', help='Install the file without adding it to the Idlesse Library')
    p.add_argument('--workspace', type=Path, default=DEFAULT_WORKSPACE)
    p.add_argument('--output', type=Path, help=f'Install folder (default: {DEFAULT_OUTPUT}, or the reframed file\'s folder)')
    p.add_argument('--upscale', nargs='+', metavar='ASSET',
                   help='Upscale these lobbies together in one quoted Modal job, so later imports are free')
    p.add_argument('--update-names', action='store_true', help='Cache lobby names from SchaleDB for --list and default titles')
    p.add_argument('--list', action='store_true', help='Print every extracted lobby as JSON, with install and upscale state')
    p.add_argument('--json', action='store_true', help='Also print IDLESSE-prefixed JSON events, for the app')
    a = p.parse_args()
    workspace = a.workspace.expanduser().resolve()
    ensure_pillow(workspace)
    calibrate = load('calibrate')
    smooth_edges = load('smooth_edges')
    register_with_app(workspace)
    log = lambda message: print(message, flush=True)
    if a.update_names:
        update_names(workspace, log)
        if not a.list:
            return
    if a.list:
        print(json.dumps(list_lobbies(workspace, (a.output or DEFAULT_OUTPUT).expanduser().resolve()), indent=2))
        return
    if a.upscale:
        upscale_batch(workspace, a.upscale, a.yes, a.json, log)
        return

    receipt = None
    if a.reframe:
        media = a.reframe.expanduser().resolve()
        receipt_path = media.with_suffix('.source.json')
        if not receipt_path.exists():
            raise SystemExit(f'No {receipt_path.name} beside it; only pipeline exports can be re-rendered.')
        receipt = json.loads(receipt_path.read_text())
        output = (a.output or media.parent).expanduser().resolve()
        if receipt.get('asset'):
            title = safe_name(a.title or receipt.get('title') or re.sub(r'-Restored-4K60$', '', media.stem))
            target = Target('lobby', workspace, receipt['asset'], receipt['animation'], title, output)
        elif receipt.get('kind') in ('spine', 'live2d') and receipt.get('id'):
            root = workspace.parent / ('azur-spine' if receipt['kind'] == 'spine' else 'azur-render')
            if not (root / 'render').exists():
                raise SystemExit(f'No Azur Lane {receipt["kind"]} workspace at {root}.')
            target = Target(receipt['kind'], root, safe_name(receipt['id']), receipt['animation'], azur_title(receipt['title']), output)
            target.item = {k: receipt[k] for k in ('id', 'kind', 'title') if k in receipt}
        else:
            raise SystemExit(f'{receipt_path.name} does not say which asset it was rendered from.')
        if target.names[0] != media.name:
            raise SystemExit(f'Expected {target.names[0]}, got {media.name}; pass --title.')
        a.replace = True
        if a.from_sidecar:
            sidecar = media.with_name(media.stem + '.framing.json')
            bleed = json.loads(sidecar.read_text()).get('bleed') if sidecar.exists() else None
            if not bleed:
                raise SystemExit('The sidecar has no crop box to use; draw one in Adjust Framing… first.')
            left, top = bleed.get('left', 0), bleed.get('top', 0)
            a.crop = [left, top, 1 - left - bleed.get('right', 0), 1 - top - bleed.get('bottom', 0)]
        if not a.crop and not a.fit and not a.camera:
            raise SystemExit('--reframe needs --crop, --from-sidecar, --camera or --fit.')
    else:
        if a.fetch:
            asset = safe_name(a.fetch)
            if not (workspace / 'assets-pc' / asset).exists():
                fetch(asset, workspace)
        elif not a.source:
            p.error('give an asset id, a folder or ZIP, --fetch, --upscale, --list or --reframe')
        elif (workspace / 'assets-pc' / a.source).is_dir() and '/' not in a.source:
            asset = a.source
        else:
            asset = adopt_source(a.source, workspace, a.asset)
        title = a.title or known_titles(workspace, (a.output or DEFAULT_OUTPUT).expanduser().resolve())[0].get(asset) or default_title(asset)
        if not title and not a.preview:
            raise SystemExit(f'{asset} has no readable name; pass --title.')
        target = Target('lobby', workspace, asset, a.animation, safe_name(title) if title else None,
                        (a.output or DEFAULT_OUTPUT).expanduser().resolve())
    asset, stem, animation, title, output = target.asset, target.stem, target.animation, target.title, target.output
    lobby = target.kind == 'lobby'

    # Camera: the recipe the installed export was rendered with when re-framing,
    # otherwise whatever the workspace would use, then the crop applied on top.
    cameras_path = target.cameras_path
    cameras = json.loads(cameras_path.read_text()) if cameras_path.exists() else {}
    base = (receipt or {}).get('camera') or target.recipe(cameras)
    if a.camera:
        base = [round(v, 4) for v in a.camera]
    camera = crop_to_camera(base, a.crop) if a.crop else base
    original_cameras = cameras_path.read_text() if cameras_path.exists() else None
    changed = camera is not None and camera != target.recipe(cameras)
    job = target.workspace / f'ingest-{asset}-{datetime.datetime.now():%Y%m%d-%H%M%S}'
    keep_camera = False
    server = calibrate.serve(target.workspace)
    try:
        if changed:
            target.apply(calibrate, camera)
            log(f'Camera for {stem}/{animation}: {base or "fit"} -> {camera}')

        # Preview through the same renderer (for a lobby, from the original
        # textures: same skeleton and framing, and free).
        preview_args = argparse.Namespace(asset=target.asset_path, stem=stem, animation=animation, seconds=0.0)
        edges, image, duration = calibrate.worst_edges(target.workspace, server, preview_args, 1920, 1080, 4)
        # An import fits only when it has to; a re-render asked to fit re-frames even a clean camera.
        if a.fit and duration and (a.reframe or not calibrate.clean(edges)) and target.kind != 'live2d':
            # Frame the largest painted area first; it keeps far more of an irregular
            # scene than stepping the zoom towards the matte does.
            with tempfile.TemporaryDirectory() as tmp:
                _, meta = calibrate.render(target.workspace, server, target.asset_path, stem, animation, Path(tmp) / 'm', 64, 36, 0)
            boxed = calibrate.fit_to_painted_area(target.workspace, server, target.asset_path, stem, animation, duration,
                                                  meta.get('bounds'), lambda recipe: target.apply(calibrate, recipe),
                                                  toward=tuple(a.fit_toward))
            if boxed:
                camera = boxed
                target.apply(calibrate, camera)
                changed = True
                edges, image, duration = calibrate.worst_edges(target.workspace, server, preview_args, 1920, 1080, 4)
                log(f'  fitted to the painted area: {camera} -> worst matte {edges["_native"]}px')
        if a.fit and duration:
            for round_ in range(8):
                if calibrate.clean(edges):
                    break
                camera = calibrate.next_camera(camera or [1.0, 0.5, 0.5], edges)
                target.apply(calibrate, camera)
                changed = True
                edges, image, duration = calibrate.worst_edges(target.workspace, server, preview_args, 1920, 1080, 4)
                log(f'  fit round {round_ + 1}: {camera} -> worst matte {edges["_native"]}px')
        previews = workspace / 'ingest-previews'
        previews.mkdir(exist_ok=True)
        preview = previews / f'{asset}-{animation}.png'
        image.save(preview)
        if not duration:
            with tempfile.TemporaryDirectory() as tmp:
                _, meta = calibrate.render(target.workspace, server, target.asset_path, stem, animation, Path(tmp) / 'm', 64, 36, 0)
            raise SystemExit(f'{stem} has no animation {animation!r}; it has {[x["name"] for x in meta.get("animations", [])]}.')
        matte = edges['_native']
        log(f'Preview {preview}')
        log(f'  {animation}: {duration:.3f}s loop; worst matte over the loop {matte}px '
            + ('(clean)' if calibrate.clean(edges) else '(MATTE: the camera leaves part of the frame uncovered)'))
        # Matte depth per edge as a fraction of the frame, the shape a sidecar bleed takes.
        # A strip along a side costs a narrow display nothing, which already crops more
        # than the strip; zooming the camera instead removes that art from every display.
        margins = {k: round(edges[k] / (512 if k in ('left', 'right') else 288), 4) for k in ('top', 'left', 'bottom', 'right')}
        trim = {k: min(round(v + TRIM_MARGIN, 4), 0.45) for k, v in margins.items() if v > 0} if not calibrate.clean(edges) else {}
        free = not lobby or restored_complete(workspace, asset)
        existing = output / target.names[0] if title else None
        emit(a.json, 'preview', asset=asset, title=title, animation=animation, image=str(preview), seconds=duration,
             matte=matte, clean=calibrate.clean(edges), camera=camera, upscaled=free, edges=margins,
             trimmable=bool(trim) and max(trim.values()) <= TRIM_LIMIT,
             quote=None if free else quote(workspace, asset),
             replaces=str(existing) if existing and existing.exists() else None)
        if a.preview:
            log('Preview only: nothing exported, camera left as it was.')
            return
        # Before anything slow or paid: an existing wallpaper is only replaced on request.
        if existing.exists() and not a.replace:
            raise SystemExit(f'{existing.name} already exists in {output}; pass --replace to archive it and install over it.')
        if a.trim_edges and trim:
            if max(trim.values()) > TRIM_LIMIT:
                raise SystemExit(f'The matte reaches {max(margins.values()):.0%} into the frame, too deep to trim at display time; use --fit.')
            log(f'Trimming matte at display time: {trim}')
        elif not calibrate.clean(edges) and not a.allow_matte:
            raise SystemExit('Stopping before export because the preview shows matte; adjust the crop or pass --allow-matte.')

        # Smooth edges need the upscaled masks: a paid upscale now returns them, and
        # lobbies upscaled before they existed fall back rather than pay again.
        edges = 'original'
        if lobby and (a.edges or (receipt or {}).get('edges') or 'smooth') == 'smooth':
            if not free or smooth_edges.has_masks(workspace, asset):
                edges = 'smooth'
            else:
                log('No edge masks for this lobby yet; exporting with its original edges.')
        job.mkdir()
        modal = '/usr/bin/false'
        if lobby and free:
            prepare_free_restore(workspace, asset, job)
            log('Textures were upscaled before; this export is local and free.')
        elif lobby:
            modal = find_modal()
            if not modal:
                raise SystemExit('This lobby needs upscaling, and the modal CLI is not installed.')
            confirm_paid(workspace, asset, a.yes)
        else:
            log('Azur Lane models render from their original textures; this export is local and free.')

        if a.reframe:
            # Background tracks can loop on longer cycles than the main animation, and
            # the installed export already covers all of them; keep its length.
            probed = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0',
                                     str(media)], capture_output=True, text=True).stdout.strip()
            installed = round(float(probed) * 60) if probed else 0
            loop = round(duration * 60)
            if loop and installed > loop and installed % loop == 0:
                log(f'Keeping the installed {installed / 60:.3f}s length ({installed // loop} loops).')
                duration = installed / 60
        staged = target.export(job, duration, modal, log, encoder='webcodecs' if a.fast_encode else 'x265', edges=edges)
        keep_camera = True
        final = install(staged, target.names, output, a.replace, clear_framing=changed, log=log)
        tidy_job(job, staged, target.names)
        if a.trim_edges and trim:
            sidecar = output / target.names[3]
            data = json.loads(sidecar.read_text()) if sidecar.exists() else {}
            data['bleed'] = trim
            sidecar.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
            log(f'Wrote the trim to {sidecar.name}.')
        if changed and target.tracked.exists():
            write_cameras(target.tracked, target.with_camera(json.loads(target.tracked.read_text()), camera))
            log(f'Recorded the camera in {target.tracked.relative_to(REPO)}; commit it to keep the recipe.')
        log(f'\nInstalled {final}')
        emit(a.json, 'installed', path=str(final), camera=camera)
        if not a.no_library:
            queue_for_library(final, log)
    finally:
        server.shutdown(); server.server_close()
        if changed and not keep_camera:
            if original_cameras is None:
                cameras_path.unlink(missing_ok=True)
            else:
                cameras_path.write_text(original_cameras)
            if target.kind != 'live2d':
                calibrate.rebundle(target.workspace)


if __name__ == '__main__':
    main()
