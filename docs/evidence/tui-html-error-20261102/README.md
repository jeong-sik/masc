# HTML error in Usage: isolated TUI capture

2026-11-02 10:08 KST. In an isolated workspace, a loopback proxy answered the TUI's `GET /api/v1/runtime/resolved` with HTTP 409 and a `text/html; charset=utf-8` error page. The other reads went to an isolated MASC server. Before the change, the error occupied six rows with markup and CSS; the candidate showed the status and the synthetic server's explanation in four rows. The result is a fixture observation, not evidence of a live server error or an installed build.

The TUI was 80 columns by 32 rows with `TERM=xterm-256color`, `NO_COLOR=1` and a 60-second refresh. In each run the input was `:`, `go usage`, Enter, capture, Escape, `q`, `q`. Both TUI processes exited 0. The server reported effective base `/private/tmp/masc-tui-html-final-oi3n09mn/workspace`, runtime instance `01a199cc-e779-7000-a368-7425f27f00eb`, and zero account-email rows before and after. Its process exited 0; the owned proxy was terminated.

The TUI and server ran under macOS sandbox profiles that denied access to `/Users/dancer`, selected Keychain services and unapproved child processes. The TUI could connect only to the loopback proxy; preflight checks denied a home-directory read, direct server connection and unapproved child execution. These checks are not a complete sandbox or Keychain audit. A limited token/email-pattern scan of the retained text and ANSI files found no matches; it is not a complete privacy audit.

## Identities and rendering

- Parent source: `77f06b0bf0f7c5cc2ca1c1502fb5fa6258e7105f`. The candidate binary was built from that parent plus the uncommitted source and test changes; the combined diff/untracked-file SHA-256 at review was `e01ba6f722588b77001eb65740a0d3a3f910dc75644dab4a89f7ec4559b02687`. It is not a clean final-head build.
- Baseline TUI: `7429523a412af65caaba13049fef80607ea972ac38e027fef5002124543e5ef3`. Its embedded build commit is `4a6a946bb8bc4541c28adb1eef9f6e47517b890f`; it was built with the workspace-read recovery code subsequently committed in #47449.
- Candidate TUI: `04cacc320790109e9da64489f4e5839b3cbc0bbb9073bf39c024b4cf54f68f7e`, embedded build commit `77f06b0bf0f7c5cc2ca1c1502fb5fa6258e7105f`.
- Fixture server: `b0ce0fc4e3e5af10d013693efc6015dddff60796a43f49688c3a126ef9bbcf25`, embedded build commit `a7d4cb680c21dfe1bb32288bde0ab249c2b01b92`.
- `before.ansi` and `after.ansi` are unmodified PTY byte prefixes. `before.txt` and `after.txt` are pyte renderings. `before.png` and `after.png` are headless Chrome replays in xterm.js 6.0.0, not screenshots of the user's terminal. The replay removed the unsupported Kitty graphics capability query; the raw ANSI files retain it.

The HTML summary applies to the shared JSON GET path. It does not cover every TUI HTTP request, execute CSS, or guarantee that the excerpt contains the server's most useful explanation. The HTTP client has already received the body before the HTML parser input limit applies. Unsupported or ambiguous encodings without a usable BOM fall back to the existing decoder.

The design follows the [Command Line Interface Guidelines on errors](https://clig.dev/#errors), which emphasize useful, low-noise error output. [RFC 9110 section 8.3.1](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.3.1) defines case-insensitive media type tokens and parameters. These sources informed the display and Content-Type handling; they do not validate this implementation.
