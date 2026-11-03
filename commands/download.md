---
description: Download a URL fast with Gopeed (multi-connection engine), wait for it, and report the saved file path
---

The link is `$ARGUMENTS`. Run this as one self-contained turn — it checks every
endpoint case itself (unix socket first, then TCP 9999), starts Gopeed if needed,
then queues the download and waits for `saved to:`.

```bash
# 1. Find the binary. The managed copy is the source of truth; this same
#    path works on every machine once the plugin is installed (+ /plugins reload).
DL=~/.kimi-code/plugins/managed/gopeed/bin/gopeed-dl
if [ ! -x "$DL" ]; then
  echo "gopeed-dl binary not found at $DL — run /plugins reload in kimi-code, or reinstall the plugin." >&2
  exit 1
fi
ls -l "$DL"

# 2. Doctor checks all endpoint cases at once and reports what it found.
"$DL" doctor

# 3. Queue the download and wait up to 600 s for it to finish.
"$DL" add "$ARGUMENTS" --dir ~/Downloads

# 4. Read the task id from step 3's output ("added task <id>"), then:
"$DL" wait <task-id> --timeout 600
```

If `doctor` finds nothing answering, dig deeper:

- Is Gopeed running at all? `ps aux | grep -i gopeed` — if not, launch it:
  - Desktop app: open `/Applications/Gopeed.app` (or set `GOPEED_APP=/custom/path`).
  - Headless: `gopeed-web -A 127.0.0.1 -P 9999`.
- Which endpoint should the plugin use?
  - Desktop app default (Unix protocol): `~/Library/Caches/gopeed.sock`, no token — auto-detected.
  - If you switched Settings -> Advanced -> Protocol to TCP: `http://127.0.0.1:9999`; set `GOPEED_TOKEN` if you set an API token in the app.
- Pin an endpoint permanently: `export GOPEED_URL=http://127.0.0.1:9999` (or `unix:///path/to/gopeed.sock`).
- To watch progress without blocking: `"$DL" list` and `"$DL" status <task-id>`.

Report the task id, and after `wait` prints `saved to: <path>`, the full path, the file size in bytes, and how long it took.
