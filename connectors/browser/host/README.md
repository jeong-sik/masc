# Firefox native messaging host

`masc-browser-host` is an OCaml/Eio executable. Firefox starts it through
`runtime.connectNative("masc_browser_host")`. It reads the lane token from a
file, long-polls `/browser-lane/poll`, and forwards `browser.info`, `tabs.list`,
`page.read`, `page.elements`, `page.capture`, and `page.interact` as native
frames. It posts correlated replies to `/browser-lane/result`. These cover
browser metadata, tab listing, page text/elements, screenshots, and page interactions.

After installing MASC, register its native host separately. Use the same
published tag as the installed binary (the example requires `v0.34.0` to have
been published). No source checkout or local build is required:

```sh
TAG=v0.34.0
BASE_PATH="$HOME/masc-workspace"
curl -fsSL "https://raw.githubusercontent.com/jeong-sik/masc/$TAG/connectors/browser/install-host.sh" \
  -o /tmp/masc-install-host.sh
less /tmp/masc-install-host.sh
bash /tmp/masc-install-host.sh \
  --binary "$HOME/.local/bin/masc-browser-host" \
  --base-path "$BASE_PATH"

EXTENSION_DIR="$BASE_PATH/.masc/browser-lane/extension"
mkdir -p "$EXTENSION_DIR"
for file in manifest.json background.js; do
  curl -fsSL "https://raw.githubusercontent.com/jeong-sik/masc/$TAG/connectors/browser/extension/$file" \
    -o "$EXTENSION_DIR/$file"
done
```

Adjust `--binary` for a custom installation prefix. Start the MASC server with
the same base path. In Firefox, open `about:debugging#/runtime/this-firefox`,
choose **Load Temporary Add-on**, and select `manifest.json` in the extension
directory above. Firefox removes temporary add-ons on restart; load it again
for a later browser session. Keep both extension files together and update
them from the same tag when upgrading the native host.

The installer copies the executable into
`<base-path>/.masc/browser-lane/host/` and registers the launcher there.
Deleting or moving the source checkout therefore cannot break the installed
host. Rerun installation to promote another built executable. The token is
created with mode `0600` if absent; an existing nonempty token is preserved.
The launcher carries file paths, never the token value.

`--base-path` defaults to the existing `MASC_BASE_PATH` setting. The launcher
names no server address. The host reads the port from
`<base-path>/.masc/config/connection.toml`, which the MASC server rewrites each
time it starts listening and `masc workspace-connection --save` also writes.
The file is the desired port, not proof that a server is there. When a poll
fails, the host reads the file again and moves to the port it names only when
its current server no longer answers `/browser-lane/ping` and the new port
does; otherwise it retries where it is. `MASC_HTTP_BASE_URL` or
`MASC_HTTP_PORT` in the browser's environment fixes the address instead, as
`masc-browser-host --server URL` does for a manual run; neither is re-read.
A result is sent again only when its request may not have reached the server;
a result the server answered with any status is logged and the host returns to
polling. The installer also writes `launch.json` beside the launcher with the
launcher's SHA-256, which the onboarding check and the browser tools read to
say where the host takes its address from; a launcher edited afterwards no
longer matches it. If a host was installed before `launch.json` existed, its
launcher may fix a port: run the installer again for that workspace and reload
the extension. To point a running host at a server on another port, save that
port with `masc workspace-connection --port PORT --save` and reload the
extension; a host that is still connected to a server answering on its old
address stays there.
`--token-file` defaults to `<base-path>/.masc/browser-lane/token`; relative
paths resolve against the base path. For a browser launched by the desktop,
use explicit installer arguments so its shell environment is unnecessary.
The installer requires a custom `--token-file` to exist already. It must
match the canonical server token; if the canonical file does not exist yet,
the installer initializes it from that provisioned token.
An isolated Firefox profile may pass `--host-name` with a unique lowercase
name. The installer writes that exact name to both the manifest filename and
the manifest name; the matching extension must use the same host name.
Remove only that exact manifest after the owned profile and native host stop.
The host accepts only HTTP origins at `127.0.0.1`, `localhost`, or `::1`.
Remote destinations and URL credentials, paths, queries, and fragments are
rejected before the token is read or sent.

## Connecting an ordinary Firefox / Zen profile

A `live` Browser Lane uses the extension in the browser profile you are currently
using. A separate WebDriver `automation` session does not register a live browser.
Installing MASC's built-in browser Skill does not install a browser extension.

After registering the native host above, open
`about:debugging#/runtime/this-firefox` in the intended Firefox / Zen profile,
choose **Load Temporary Add-on**, and select
`connectors/browser/extension/manifest.json` from this checkout. Then refresh the
Browser Lane connections with `r` and choose that browser.

This is a development installation: Firefox removes a temporary extension on
browser restart, so it must be loaded again. See
[Mozilla's extension installation instructions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Your_first_WebExtension#installing).

`coordinator HTTP [connected]` together with an empty browser list means the MASC
server is reachable but has no active native browser connection. Check extension
loading in the intended profile, then its native host registration and server
configuration. Opening the browser alone is insufficient. The TUI now distinguishes
this empty state from a failed HTTP request; an older installed TUI may still label
it `HTTP failed`.

The native protocol uses a 4-byte little-endian length followed by UTF-8 JSON.
Mozilla specifies native byte order and a 1 MiB host-to-browser limit; the
supported macOS/Linux release architectures are little-endian. This host
caps browser-to-host replies at 8 MiB to admit a 5 MiB PNG after base64/JSON
encoding, below
Mozilla's 4 GiB incoming protocol limit. Oversized or truncated frames fail
explicitly. stdout is reserved for frames; diagnostics go to stderr without
tokens or page content. An independent stdin fiber detects browser closure
even while HTTP is waiting and cancels the host immediately.
The extension deadline also covers writing the command. A timeout during a
partial write terminates the host so reconnection starts with a fresh frame
stream; a reply timeout after a complete write posts a failed result.

Source: [Mozilla native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging#app_side).

The executable integration test runs a local fake lane HTTP server and a
framed extension peer. It requires an already-built host:

```sh
python3 test/test_browser_native_host.py /path/to/masc-browser-host
```

The host marks its stdout pipe nonblocking before starting Eio. On the POSIX
backend, a blocking descriptor can enter a blocking `writev` even after it was
reported writable; a large native frame can then stop the entire domain,
including the timeout and stdin EOF fibers. Nonblocking writes return control to
Eio when the pipe fills, keeping both cancellation paths effective. The executable
tests retain the unread-output timeout case and also close stdin during a partial
frame write. See the [Eio POSIX I/O implementation](https://github.com/ocaml-multicore/eio/blob/main/lib_eio_posix/low_level.ml).
