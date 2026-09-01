# DIY Broadcast Assembler

A small pile of bash scripts for building a fake TV station night out of folders of videos.

The main script walks you through picking show folders, station IDs, "we'll be right back" bumps, commercials, "welcome back" bumps, and a sign-off. It writes a rundown, remembers which program files already aired so the next night is different, and either encodes the whole thing on Linux or (more usefully) dumps a portable **broadcast pack** you can copy to another machine.

The rest of the scripts are helpers you will probably want *before* you run the assembler: splitting a long commercial dump into spots, cutting a file in half when it is too big for whatever you are doing, muxing a video track with a separate audio file, and prefixing insert clips so they air in a sane order.

None of this is a real traffic system. It is a hobbyist rundown builder that happens to know about bump-out / spots / bump-in pods.

License is GNU GPL v3. See the bottom of this file.

---

## What you get

| Script | What it is for |
| --- | --- |
| `broadcast_assemblerlauncher.sh` | Finds the newest `broadcast_assembler_vN.sh` in the same folder and runs it. Use this one. |
| `broadcast_assembler_v11.sh` | The actual assembler (Linux). Interactive prompts, rundown, memory, stage pack and/or encode. |
| `renumber_inserts_v2.sh` | Prefixes videos in a folder `001_`, `002_`, … so filename order is air order. Linux. |
| `split_on_black.sh` | Cuts a long file into clips at black frames. Good for a dumped commercial reel. |
| `splitinhalf.sh` | Splits one video into two equal-length pieces (`_part1` / `_part2`). Stream copy. |
| `mux.sh` | Puts a video file and a separate audio file into one `.mkv` without re-encoding. Works anywhere you have ffmpeg if you pass paths. The click-to-choose dialog is macOS-only. |

You can use any helper on its own. You do not have to run the assembler to use `split_on_black.sh`.

---

## Requirements

### Assembler + renumber (Linux)

These two check `uname` and refuse to run on anything that is not Linux. They want GNU bash, GNU coreutils, and ffmpeg.

Install the boring stuff:

```bash
# Debian / Ubuntu
sudo apt update
sudo apt install ffmpeg bash coreutils findutils gawk

# Fedora
sudo dnf install ffmpeg bash coreutils findutils gawk
```

`shuf`, `sort -V`, `find -printf`, and `stat -c` show up in a few places. BusyBox or macOS BSD userland will fight you. That is why the assembler is marked Linux-only.

Optional but nice:

- **fzf** — multi-select folder browser when you point the assembler at a drive. Without it you get a numbered list and type `1 3 7` or `1-5` or `all`.
- **HandBrakeCLI** — only needed later, on whatever machine encodes the stage pack. Not required on the Linux box if you choose `stage` and encode elsewhere.

Check you have the two binaries the assembler actually calls during a run:

```bash
ffmpeg -version | head -n 1
ffprobe -version | head -n 1
command -v fzf && echo "fzf is installed" || echo "no fzf; numbered picker will be used"
```

### Helpers

`split_on_black.sh` and `splitinhalf.sh` need `ffmpeg`. `splitinhalf.sh` will use `ffprobe` if it is on PATH, otherwise it scrapes `ffmpeg -i`. They do not care which OS you are on as long as those tools exist.

`mux.sh` needs `ffmpeg`. Pass the two inputs (and an optional output name) and it is ordinary portable bash:

```bash
bash mux.sh /path/to/picture.mov /path/to/sound.wav show.mkv
```

Run it with no arguments and it tries to open a "choose file" dialog via `osascript`. That call only exists on macOS. On Linux, no paths means it prints `ERROR: no video selected` and exits. There is no Linux file picker in this script.

### Permissions

```bash
chmod +x broadcast_assemblerlauncher.sh broadcast_assembler_v11.sh \
         renumber_inserts_v2.sh split_on_black.sh splitinhalf.sh mux.sh
```

Or skip that and always run them as `bash scriptname.sh …`.

---

## How a night is structured

The assembler treats **programs** as the unpredictable pile (cartoons, sitcom episodes, public-domain features, whatever). Everything else is an *insert library* and plays in **filename order**.

A commercial break is always this pod:

```
bump-out  →  K commercials  →  bump-in
```

IDs are not stuffed into breaks. They open the night, optionally fire again when runtime crosses each "hour", and can close the night. Two IDs will not air back to back. Out-bumps and in-bumps are separate folders on purpose so a "we'll be right back" never gets pulled from the welcome-back pile.

If you give it a sign-off folder, exactly one of those files is always last, after the close ID.

Typical folder layout on disk:

```
~/station/
  shows/
    toonerville/          # episodes
    late_movie/           # features
    kitchen_demo/
  ids/                    # 001_open.mp4, 002_legal.mp4, …
  bumps_out/              # we'll be right back
  bumps_in/               # welcome back
  commercials/            # individual spots, already cut
  signoff/                # anthem, clock, "this concludes our broadcast day"
```

Programs can live in as many folders as you want. Inserts should be one folder per type.

---

## Workflow

Rough order most people end up using:

1. Get the raw files into folders.
2. If commercials arrived as one long dump, cut them with `split_on_black.sh`.
3. Number the insert folders with `renumber_inserts_v2.sh` so `01` actually airs before `10`.
4. Run the launcher. Answer the prompts. Look at the rundown. Say yes.
5. Take the `broadcast_pack/` folder to the machine that will encode, *or* encode on the same Linux box.
6. Play the playlist or stitch the encoded files into one `broadcast.mp4`.

Details for each step follow. There is a full made-up night in [A worked example](#a-worked-example).

---

## The assembler

```bash
cd /path/to/this/repo        # or wherever you keep the scripts
bash broadcast_assemblerlauncher.sh
```

The launcher prints which version it found and `exec`s it. Frozen copies can sit next to it (`broadcast_assembler_v10.sh`, …); only the highest `vN` runs.

It is interactive. First time through you will be asked a lot. Answers are written to `broadcast.conf` in the current working directory, so the next run offers them as defaults. A second file, `broadcast_memory.txt`, records which **program** and **sign-off** paths already aired. Inserts (IDs, bumps, spots) are *not* remembered that way; they just cycle in filename order.

### Choosing program folders

Three ways:

1. Type paths one per line, blank line to finish.
2. Point it at one or more drive roots. It finds folders that contain video files, optionally filtered by name (`Season*` is the default filter — clear it if your folders are not named that way). Then fzf (or a numbered list) to pick.
3. Load `program_folders.txt` from a previous run.

It will offer to save the list. Do that if you are going to run this again next week.

### How programs are picked

- **1 — Random N clips.** Draws across the selected folders instead of shuffling one giant list (which tends to empty the biggest folder first). Then it rearranges so you do not get two clips from the same folder in a row if anything else is left.
- **2 — All unused clips, shuffled**, same "don't repeat the folder" pass.
- **3 — All unused clips, filename order.** No shuffle.
- **4 — A text file of paths**, one per line. Comments and blank lines ignored.

"Unused" means "not already listed as PROGRAM in `broadcast_memory.txt`". When every file in those folders has been used, it asks whether to clear program memory and start the library over.

### Insert libraries

Blank a prompt to disable that type. Missing folders just omit that slot in the pod. Filename order is `sort -V`, which is why numbering matters.

Prompts after that:

- Break after every **N** program clips.
- **K** commercials per pod.
- Open with an ID? Close with an ID?
- Sign-off mode: `random` (different closer each run) or `first` (always the first file in filename order).
- Optional ID when runtime crosses each hour. The "hour" is just a number of seconds; 3600 is a real hour, 1800 is a half-hour clock.
- Whether each insert list loops when it runs out. If you say no and the list is exhausted, that slot is simply skipped.
- What to assume for 720×480 / 720×576 files that have square or missing SAR: `square`, `4:3`, or `16:9`. Stored SAR is honored when it is actually present.
- Extra optical unsqueeze for those 720-wide SD frames only. Leave it at `1` unless you shot with a 1.33× adapter or a 2× anamorphic lens and the file does not already say so.
- Fade seconds on each segment if you encode on this machine. `0` is a hard cut. The stage-pack HandBrake script does **not** apply this fade; it is an encode-here option.
- Output filename (used when you encode here).
- Output mode: `stage`, `encode`, or `both`.

It prints the rundown with running times before it writes anything lasting. If the rundown looks wrong, say no. Config and memory stay as they were.

If you say yes it writes:

- `rundown.txt` — type and path of every segment
- `broadcast.conf` — your answers
- `broadcast_memory.txt` — PROGRAM and SIGNOFF paths from this rundown appended
- and then either a stage pack, an encode, or both

### Output modes

**stage** (default) copies every file in rundown order into `broadcast_pack/sources/` with a numbered name like `001_ID_001_open.mp4`. It also writes playlists and two small scripts. Nothing is encoded on this box. The pack is what you copy to a USB drive or another computer.

**encode** normalizes every segment on this Linux machine to 1920×1080, 30 fps, H.264 + AAC, then concatenates with stream copy to `broadcast.mp4` (or whatever you named it). Slow. Uses a temp dir under `/tmp` and deletes it on exit.

**both** does the pack and then encodes here anyway.

### What is inside a broadcast pack

```
broadcast_pack/
  sources/                 # numbered copies of the originals
  encoded/                 # empty until you run encode.sh
  rundown.txt
  playlist_sources.m3u     # play the copies as-is in VLC / mpv
  playlist_encoded.m3u     # same order, after encode.sh
  concat.txt               # ffmpeg concat list pointing at encoded/
  encode.sh                # HandBrakeCLI batch
  stitch.sh                # ffmpeg -c copy → broadcast.mp4
```

Play the raw pack without encoding:

```bash
mpv broadcast_pack/playlist_sources.m3u
# or open that m3u in VLC
```

That is useful as a sanity check: right order, right bumps, no surprise two-hour movie you did not mean to include. The sources are still whatever codec and frame size they started as, so playback may hitch. That is expected.

Encode the pack (Mac or Linux, anywhere HandBrakeCLI lives):

```bash
cd broadcast_pack
bash encode.sh
bash stitch.sh
```

`encode.sh` looks for the VideoToolbox H.264 encoder (`vt_h264`) and falls back to x264. Target is 1920×1080, 30 fps CFR, pad to fill, AAC 128k stereo 48 kHz. Quality is HandBrake RF 35 — a bit crunchy, fine for a living-room pretend station. Change the flags in `encode.sh` if you hate that.

`stitch.sh` does not re-encode. It joins `encoded/*.mp4` in rundown order and writes `broadcast.mp4` next to the scripts.

You can skip `stitch.sh` and just play `playlist_encoded.m3u` if you would rather keep the night as many files.

---

## Script notes (using them separately)

### `renumber_inserts_v2.sh`

Insert libraries air in filename order. `2_welcome.mp4` sorts after `10_welcome.mp4` with a naive sort, and `sort -V` still does better if everything has a padded prefix. This script strips an existing `001_` / `01-` / `7.` style prefix and writes a clean `001_original-name.ext`.

```bash
bash renumber_inserts_v2.sh --dry-run ~/station/ids
bash renumber_inserts_v2.sh ~/station/ids
bash renumber_inserts_v2.sh --sort mtime --start 1 ~/station/bumps_out
bash renumber_inserts_v2.sh -y ~/station/commercials    # no confirm prompt
```

- `--sort name` (default) or `mtime`
- `--start N` if you want to begin at 040 or whatever
- `--dry-run` prints the plan and stops
- `--yes` skips the confirm

It stages through a temp dir *inside the target folder* so it does not copy every byte across filesystems. Re-running is safe; it will not give you `001_001_open.mp4`. Linux only (`find -printf`, `stat -c`).

Do this to IDs, bumps, and commercials. You usually do **not** want to renumber program folders — those are picked by the assembler, not played as a numbered list.

### `split_on_black.sh`

Takes one video, runs ffmpeg `blackdetect`, and cuts a new file for each stretch of picture between the gaps.

```bash
bash split_on_black.sh
bash split_on_black.sh commercials_dump.mp4
bash split_on_black.sh commercials_dump.mp4 spots
```

If you pass no filename it looks for `source.mp4`, then for a single video in the current directory. Output folder defaults to `clips/`. Cuts are stream-copy, so they land on keyframes and may start a few frames early or late. The script itself says to fine-trim in LosslessCut if a spot still has a half-second of black or clips a logo.

Default detector:

```
blackdetect=d=0.2:pic_th=0.98:pix_th=0.10
```

If it finds no gaps it tells you to loosen those. Edits under 0.4 seconds are skipped. A log is left in `blackdetect.log`.

This is the tool for "I have one two-hour file that is just commercials back to back with black in between."

### `splitinhalf.sh`

```bash
bash splitinhalf.sh
bash splitinhalf.sh late_movie.mkv
```

Writes `late_movie_part1.mkv` and `late_movie_part2.mkv` (same extension as the source) with `-c copy`. The second half seeks with `-ss` after `-i`, so the split point is approximate. Files already named `*_part1.*` / `*_part2.*` are ignored when it auto-picks a source.

Use it when a single program file is uncomfortably long and you would rather air it as two blocks with a break in the middle — or when a USB stick hates 8 GB files.

### `mux.sh`

```bash
bash mux.sh
bash mux.sh picture.mov sound.wav
bash mux.sh picture.mov sound.wav show.mkv
```

Maps the first video stream of file 1 and the first audio stream of file 2, copies both, stops at the shorter one. Default output name is the video basename with `.mkv`. No dialog on Linux; pass the paths.

Handy after a capture where video and audio landed in two files, or after you cleaned audio in something else and want it back on the picture without another generate.

---

## A worked example

Sam has a weekend "station" and a messy disk.

```
/media/sam/library/shows/toonerville/     18 episodes, various mp4
/media/sam/library/shows/drive_in/        6 features, mixed mkv/mp4
/media/sam/library/ids/                   4 IDs, names like open.mp4, legal.mov
/media/sam/library/bumps_out/
/media/sam/library/bumps_in/
/media/sam/library/signoff/
/media/sam/library/raw/saturday_ads.mp4   one 94-minute dump of spots + black
```

Goal: a portable pack for Saturday night. About ten programs, a break after every show, two spots per break, ID at the top and the bottom, sign-off last. Encode later on a Mac that already has HandBrakeCLI.

### 1. Cut the ad dump

```bash
cd /media/sam/library/raw
bash ~/station-tools/split_on_black.sh saturday_ads.mp4 ../commercials
```

It prints each `clip_001.mp4` with start/end times. Sam watches a couple in VLC. Clip 007 still has a second of black on the head; that one gets a trim in LosslessCut. The rest are fine.

### 2. Number the inserts

```bash
bash ~/station-tools/renumber_inserts_v2.sh /media/sam/library/ids
bash ~/station-tools/renumber_inserts_v2.sh /media/sam/library/bumps_out
bash ~/station-tools/renumber_inserts_v2.sh /media/sam/library/bumps_in
bash ~/station-tools/renumber_inserts_v2.sh /media/sam/library/commercials
bash ~/station-tools/renumber_inserts_v2.sh /media/sam/library/signoff
```

`open.mp4` becomes `001_open.mp4`. Next run of the assembler will play IDs in that order.

### 3. Run the assembler on the Linux box

```bash
cd ~/broadcast-work          # a writable folder; conf/memory land here
bash ~/station-tools/broadcast_assemblerlauncher.sh
```

Answers for this night (defaults in brackets after the first run):

- Program folders: option 2, root `/media/sam/library/shows`, filter cleared so it is not looking for `Season*`. Mark `toonerville` and `drive_in`. Save `program_folders.txt`.
- IDs / bump-out / commercials / bump-in / sign-off: the five folders above.
- Pick mode 1, 10 program clips. Inventory shows 24 files, none in memory yet.
- N = 1 (break after every program), K = 2.
- Open with ID: yes. Close with ID: yes.
- Sign-off: random.
- Hour ID: no.
- Loop all insert lists: yes.
- SD assume: `4:3` (old camcorder tapes in the movie folder). Optical unsqueeze: `1`.
- Fade: `0`.
- Output mode: `stage`. Stage folder: `./broadcast_pack`.

The rundown looks something like:

```
#    TYPE         LENGTH     FILE
1    ID           00:00:08   /media/sam/library/ids/001_open.mp4
2    PROGRAM      00:21:14   /media/sam/library/shows/toonerville/ep03.mp4
3    BUMP-OUT     00:00:06   /media/sam/library/bumps_out/001_brb.mp4
4    COMMERCIAL   00:00:30   /media/sam/library/commercials/001_clip_001.mp4
5    COMMERCIAL   00:00:15   /media/sam/library/commercials/002_clip_002.mp4
6    BUMP-IN      00:00:05   /media/sam/library/bumps_in/001_welcome.mp4
7    PROGRAM      01:28:02   /media/sam/library/shows/drive_in/night_of_the.mkv
…    …            …          …
…    ID           00:00:08   /media/sam/library/ids/002_legal.mov
…    SIGNOFF      00:01:40   /media/sam/library/signoff/001_anthem.mp4
```

Sam does not want a 90-minute feature in the middle of Saturday morning. Abort, switch that title out of the folder (or pick mode 4 with a hand-built list), run again. Second rundown is all shorts. Yes.

Working directory now has `rundown.txt`, `broadcast.conf`, `broadcast_memory.txt`, and `broadcast_pack/`.

### 4. What Sam does with the pack

Copy `broadcast_pack/` to a stick, take it to the Mac.

Quick check, no encode yet:

```text
Open playlist_sources.m3u in VLC. Scrub. Confirm the feature is gone
and the bumps actually say "we'll be right back" before the spots.
```

Then:

```bash
cd /Volumes/stick/broadcast_pack
bash encode.sh          # one HandBrake pass per segment → encoded/
bash stitch.sh          # → broadcast.mp4
```

`broadcast.mp4` is the whole night as a single file, same order as the rundown. Alternatively leave the files separate and play `playlist_encoded.m3u` so the "station" can still skip a spot live.

### 5. Next Saturday

Same Linux folder. Launcher again. It offers last week's program folders and insert paths. Memory still has last week's ten programs, so those will not be drawn. New rundown, new pack. When the well is dry the script asks whether to clear program memory.

Sign-offs work the same way: once every file in that folder has closed a night, the folder starts over.

---

## Files the assembler leaves behind

These show up in *the directory you launched from*, not next to the script (unless that is the same place).

| File | Purpose |
| --- | --- |
| `broadcast.conf` | Last answers. Safe to edit by hand if you know what you are doing. Sourced on the next run. |
| `broadcast_memory.txt` | Tab-separated `KIND` + path. Only PROGRAM and SIGNOFF are written. Missing files are pruned at startup. |
| `program_folders.txt` | Optional saved list of show folders. |
| `rundown.txt` | The night that was just approved. Also copied into the pack. |
| `broadcast_pack/` | Portable tree described above. |

To pretend you have never aired anything, delete `broadcast_memory.txt`. To start the prompts from scratch, delete `broadcast.conf`.

---

## Formats and gotchas

Video extensions the assembler will pick up: mp4, mkv, mov, webm, m4v, avi, mpg, mpeg, wmv, flv, ts, vob, m2ts. Hidden files (`.*`) are ignored. `renumber_inserts_v2.sh` recognizes a slightly shorter list (no mpeg/ts/vob/m2ts); rename those first or add the extension in the script if you care.

Stream-copy cuts (`split_on_black.sh`, `splitinhalf.sh`, `mux.sh`, and the assembler's own `-c copy` stitch) cannot start on an arbitrary frame. If a commercial still has black on the head, trim it. If a half-split lands a second late, that is the nearest keyframe.

The Linux encode path and the HandBrake stage path are not bit-identical. Same idea (1080p30, padded, stereo AAC), different encoders and option names. Pick one path for a given night.

The assembler and the renamer need Linux. `mux.sh` needs macOS only if you want the file dialog; with paths on the command line it is the same as the split scripts.

`ffmpeg -n` in the split / mux helpers means "do not overwrite." Delete or rename the output if you are re-running.

If `split_on_black.sh` says there are no gaps, the dump may use fades instead of black, or the black is not dark enough. Lower `pic_th` / raise `pix_th` / shorten `d=` in the script and try again. Read `blackdetect.log` before you guess.

Very large libraries: the drive browser walks every video under the roots you give it. Point it at `shows/`, not `/`.

---

## License

These scripts are free software under the GNU General Public License, version 3 (or, at your option, any later version).

You can run them, copy them, and change them. If you distribute this toolkit or a modified version, you have to keep it under GPL-3.0-or-later and include the corresponding source. There is no warranty. If a rundown eats a Saturday, that is on the rundown.

A copy of the license should travel with the repo as `LICENSE` or `COPYING` ([https://www.gnu.org/licenses/gpl-3.0.html](https://www.gnu.org/licenses/gpl-3.0.html)).
