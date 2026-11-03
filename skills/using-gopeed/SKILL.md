---
name: using-gopeed
description: Download a file as fast as possible with Gopeed's multi-connection engine (one file split into parallel connections — much faster than curl/wget on big files; also BitTorrent/magnet/ed2k). Use when the user asks to download a file, says "fast" / "as fast as possible" / "faster than curl" / "big file", or gives a torrent/magnet link. Not for small text files or API calls.
type: prompt
whenToUse: The user wants to download something and speed matters (big file, "as fast as possible", "faster than a single-connection download"), or the link is a torrent/magnet/ed2k link.
---

# Using the Gopeed plugin

Gopeed (https://gopeed.com) is a free, open-source download manager. Its engine splits one HTTP file into many parallel connections, so a big file that crawls with curl often finishes in a fraction of the time. It also handles BitTorrent, magnet and ed2k links.

## When to use it

Use this plugin when the user wants to download something and speed matters — a big file, "as fast as possible", "faster than curl" — or the link is a torrent/magnet link. Do not use it for small text files or API calls — those belong to normal tools.

## How it works

1. A Gopeed app (desktop or `gopeed` web/headless binary) runs on the machine. The desktop app's default Unix mode serves the REST API on a unix socket (`~/Library/Caches/gopeed.sock` on macOS), which gopeed-dl auto-detects; TCP mode or headless `gopeed-web` serve it on `http://127.0.0.1:9999`. If TCP has an API token set, export `GOPEED_TOKEN`.
2. The plugin's `bin/gopeed-dl` binary sends JSON requests to that API: `add` creates a task, `wait` polls it until done, `list`/`status` show progress, `pause`/`continue`/`remove` manage tasks.
3. `bin/gopeed-dl` is compiled from `src/gopeed_dl.rb` by Spinel (Ruby -> C -> native binary), so there is no Ruby to install. Spinel's runtime garbage-collects Ruby objects, and the binary proves it instead of hoping: every 10th run (or `GOPEEDSELFCHECK=1`) it forces a full GC at exit and prints the retained heap to stderr (~0.7 MB baseline, warns above 4 MiB).

## Steps

```bash
DL=~/.kimi-code/plugins/managed/gopeed/bin/gopeed-dl
# GOPEED_URL unset = auto-detect (unix socket first, then TCP 9999); set it to
# http://127.0.0.1:9999 or unix:///path/to/gopeed.sock to pin one. GOPEED_TOKEN if the TCP API has a token, GOPEED_APP to override the app path.

"$DL" doctor                                 # finds the app (GOPEED_APP, /Applications, PATH, ...) and checks the API
"$DL" start                                  # launches the found app/binary and waits for the API
"$DL" ping                                   # is Gopeed up? exit 1 with a clear message if not
"$DL" add "$URL" --dir ~/Downloads           # prints: added task <id>
"$DL" wait <id> --timeout 600                # polls once a second, prints progress, ends with "saved to: <path>"
"$DL" list                                   # all tasks with status and percent
```

## Big files

`add` returns immediately — never block a turn on a huge download. For big files, queue
it and poll: `add` then `status <id>` / `list` (each call answers in about a second and
prints the percent), and only use `wait <id>` when you want one call that ends with
`saved to: <path>`. If `wait` times out, the task keeps running in Gopeed — poll again
or raise `--timeout` (default 600 s).

## First run on a new machine

The plugin ships a prebuilt binary for macOS (`bin/gopeed-dl-darwin-*`). On Linux or Windows the
shipped binary will not run — build your own once: `./build.sh` (needs Spinel, see README). It
writes `bin/gopeed-dl-<os>-<arch>` and repoints the `bin/gopeed-dl` symlink.

## Failure handling

- `cannot reach gopeed at ...` — no endpoint answered. If the desktop app runs in its default Unix mode, gopeed-dl already uses its socket; otherwise start it (`gopeed-dl start`) or enable Settings -> Advanced -> Protocol TCP (port 9999) and restart Gopeed, or point `GOPEED_URL` at a remote instance.
- `gopeed error: unauthorized` — wrong/missing `GOPEED_TOKEN`; the token lives in Settings -> Advanced -> API token.
- `wait` timeout — report the last progress line; the task keeps running in Gopeed, resume with `wait <id>` again or `continue <id>`.

## Testing without Gopeed

`test/run_tests.sh` starts `test/mock_gopeed.rb` (a small in-memory API stand-in that also serves a unix socket) and runs 32 checks against `bin/gopeed-dl`: ping/add/list/status/pause/continue/wait/remove over TCP and unix, auto-detect, doctor, error paths, token accept/reject, and the heap self-check on success and error paths.
