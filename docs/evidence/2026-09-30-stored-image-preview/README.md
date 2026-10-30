# Stored image preview

Patched execution follow-up: [2026-10-01 Queue/image build and PTY evidence](../2026-10-01-tui-queue-image/README.md). The observations below retain their original source/binary scope.

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

The patch gives active queued or inflight session images priority over loaded
history, including when the server clock runs ahead. Settled session images
instead follow the canonical loaded/session timeline: an old local user row
can remain after it falls outside the server's bounded history tail, and must
not permanently hide a newer saved image. With a staged draft, only session
observations after its saved anchor can supersede it. When such an observation
cannot be established, the draft wins. History loading alone cannot steal its
preview. This conservative policy does not implement persistent arrival
ordering.

The authenticated artifact request and non-success refusal stay on the Eio
fiber. Only successful JSON/base64 decoding moves to the system thread.
Before base64 decoding, the artifact envelope must contain typed `sha256`,
`bytes`, and `content` fields. Its digest and byte count must match the recorded
reference, and the actual content length and SHA-256 must match as well. These
checks cover the retained wire string, including a data URI prefix when
present; they do not compare the decoded PNG size to the wire byte count.
The existing generation, view and Keeper guards discard obsolete previews.

Validation:

- `artifact-decoder-typecheck.json` records successful OCaml 5.5.1 standalone
  type checks of the new image-preview interface, implementation and test.
  These used existing repository/opam dependency interfaces; implementation
  and test checks stopped after typing. This is neither linked test execution
  nor a whole-application type check.

- Installed binary: the failure above reproduced in an isolated PTY.
- Changed OCaml files: OCaml 5.5.1 parsing passed.
- Whole-main isolated typecheck: unavailable. Existing build CMIs made
  inconsistent assumptions over `Masc`; no dependencies were rebuilt.
- Python scenario syntax and `git diff --check`: passed.
- The Keeper `ocaml-agent-ic` independently advised keeping HTTP refusal
  handling on the fiber, then found that a future-clock loaded row could hide
  an eligible session image. The follow-up selects the eligible session
  candidate before falling back to the historical timeline. Independent source
  review passed at `9f539386806b15b2a75c35353bbd40be30f4eb25`. The parent's
  subsequent queue-status change is integrated with the corresponding PTY
  expectation updated from waiting to pending.

The registered PTY scenario covers successful retained bytes, HTTP refusal,
malformed or missing envelope fields, mismatched reference digest or byte
count, same-length content corruption, queued images and delayed history.
Additional queued and delayed-history cases simulate a server clock one hour
ahead of the client. The settled-history case sends a local image, observes its
reply and a completed frame without pending activity, then requires Ctrl-O to
open a newer saved image from a bounded tail that omits the old user request.
Pure artifact tests cover both bare base64 and data URI payloads, required
envelope fields, and substituted or corrupted content.
The cancellation case is a bounded negative observation, not proof that a late client mailbox
event was consumed. These scenarios have not run against a patched binary.
No CI, local full build, installation or production success is claimed.
