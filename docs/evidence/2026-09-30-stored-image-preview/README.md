# Stored image preview

Issue: https://github.com/jeong-sik/masc/issues/40081

The installed TUI 0.49.0 was run in an isolated PTY against an HTTP fixture,
with a temporary workspace. Its SHA-256 was
`0ba80256daabb703cdcfbed4097a31b0c5a2cb136a424d59015da1d919951f44`;
its exact source commit was not verified.

Command from this branch:

```sh
python3 test/test_tui_stored_image_pty.py /Users/dancer/.local/bin/masc-tui \
  --mode success --evidence-dir /tmp/masc-stored-image-before
```

The test failed with `Ctrl-O did not fetch the displayed retained attachment`.
The recorded screen shows the retained image attachment, followed by
`Ctrl-O: no image in this conversation or the composer`. The fixture observed
zero artifact GETs. This directly reproduces the loaded-history selection
gap. The HTTP-in-system-thread defect described in the issue was not reached
in this run; its correction is source-reviewed, not runtime-proven here.

`before.ansi` contains the captured terminal output. `before.txt` is the final
screen projection, and `before.png` renders that projection with Pillow;
colours are illustrative. No production Keeper input or runtime setting was
changed by this fixture.

The patch selects the newest observed session image first, including queued
rows. With a staged draft, only observations after its saved session anchor
qualify. The loaded/session timeline supplies a fallback when no such image
exists; its timestamps cannot hide a newer session candidate even when the
server clock runs ahead. When an image cannot be proven newer than the staged
draft from retained session observations, the draft wins. History loading
alone cannot steal its preview. This conservative policy does not implement
persistent arrival ordering.

The authenticated artifact request and non-success refusal stay on the Eio
fiber. Only successful JSON/base64 decoding moves to the system thread.
The existing generation, view and Keeper guards discard obsolete previews.

Validation:

- Installed binary: the failure above reproduced in an isolated PTY.
- Changed OCaml files: OCaml 5.5.1 parsing passed.
- Whole-main isolated typecheck: unavailable. Existing build CMIs made
  inconsistent assumptions over `Masc`; no dependencies were rebuilt.
- Python scenario syntax and `git diff --check`: passed.
- The Keeper `ocaml-agent-ic` independently advised keeping HTTP refusal
  handling on the fiber, then found that a future-clock loaded row could hide
  an eligible session image. The follow-up selects the eligible session
  candidate before falling back to the historical timeline. Independent review
  of this follow-up is still pending.

The registered PTY scenario covers successful retained bytes, HTTP refusal,
malformed content, queued images and delayed history. Additional queued and
delayed-history cases simulate a server clock one hour ahead of the client.
The cancellation case is a bounded negative observation, not proof that a late client mailbox
event was consumed. These scenarios have not run against a patched binary.
No CI, local full build, installation or production success is claimed.
