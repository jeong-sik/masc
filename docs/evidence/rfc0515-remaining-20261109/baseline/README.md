# Installed baseline for the remaining RFC-0515 views

These are actual tmux captures from the installed `masc-tui`, in a private tmux server at 120×35 and 80×24, in both densities. They are the **before** observation; they are not captures of the candidate source.

- Embedded build commit: `6a6ec4c28e2f26edcf272e37115ac2f655005f2b` (`0.69.0`). This predates the implementation stack and the merged G2 half-hour pulse change.
- Live runtime supplied the rows; no synthetic Keeper values were added. Counts and ongoing work can change between captures. The running fleet itself reported a stale scan; that message is preserved.
- A local read-only HTTP proxy forwarded GET requests and their original admission headers; it rejected all POST, PUT, PATCH, and DELETE requests. The proxy queue was enlarged for the TUI's initial concurrent reads. Local presentation preferences were isolated with `MASC_CONFIG_DIR`; the real preference file was checked byte-for-byte unchanged after the run. No token was printed or retained.
- The first two proxy attempts are not part of this bundle: they lacked admission headers or adequate connection backlog and displayed workspace/read failures. The first narrow captures sent input before raw mode and remained on Overview, so they are excluded too. The retained 120×35 capture began at 10:04:03Z; the retained 80×24 recapture began at 10:06:22Z and waited for termios input readiness. These are separate live observation windows.
- Opaque account-specific runtime IDs and the user's filesystem root are redacted in these text derivatives. Runtime ID masks preserve character count. Keeper names are preserved as row identities. The manifest hashes these sanitized bytes. Its first HTTP audit also covers the excluded initial narrow attempt; only the selected text captures are completion evidence. This is a text tmux capture, not a raster screenshot or a compile/test result.
- `manifest.json` records installed binary SHA-256, capture digests, GET statuses, and blocked mutation paths. The paths in request queries use `<base-path>` in this retained derivative.

File names are `before-<terminal size>-<view>-<density>.txt`. The list panel's usable width is two cells less than the terminal width.
