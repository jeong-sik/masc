# Firefox native messaging host

`masc-browser-host` is an OCaml/Eio executable. Firefox starts it through
`runtime.connectNative("masc_browser_host")`. It reads the lane token from a
file, long-polls `/browser-lane/poll`, forwards `tabs.list` and `page.read` as
native frames, and posts correlated replies to `/browser-lane/result`.

Install a CI-built executable without building locally:

```sh
connectors/browser/install-host.sh \
  --binary /path/to/masc-browser-host \
  --base-path /path/to/workspace \
  --server http://127.0.0.1:8935
```

The installer copies the executable into
`<base-path>/.masc/browser-lane/host/` and registers the launcher there.
Deleting or moving the source checkout therefore cannot break the installed
host. Rerun installation to promote another built executable. The token is
created with mode `0600` if absent; an existing nonempty token is preserved.
The launcher carries file paths, never the token value.

`--base-path` defaults to the existing `MASC_BASE_PATH` setting. `--server`
defaults to existing `MASC_HTTP_BASE_URL`, or the configured MASC host/port.
`--token-file` defaults to `<base-path>/.masc/browser-lane/token`; relative
paths resolve against the base path. For a browser launched by the desktop,
use explicit installer arguments so its shell environment is unnecessary.
The installer requires a custom `--token-file` to exist already. It must
match the canonical server token; if the canonical file does not exist yet,
the installer initializes it from that provisioned token.
The host accepts only HTTP origins at `127.0.0.1`, `localhost`, or `::1`.
Remote destinations and URL credentials, paths, queries, and fragments are
rejected before the token is read or sent.

The native protocol uses a 4-byte little-endian length followed by UTF-8 JSON.
Mozilla specifies native byte order and a 1 MiB host-to-browser limit; the
supported macOS/Linux release architectures are little-endian. This host
also caps incoming frames at 1 MiB as an application memory bound, below
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
