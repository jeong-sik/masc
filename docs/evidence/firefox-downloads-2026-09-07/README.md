# Native Firefox downloads, 2026-09-07

Stock Firefox 155.0.1 and geckodriver 0.37.1, isolated local fixture/profile.
The source interpreter loaded production Browser_webdriver, Browser_downloads,
and Browser_bidi_downloads with the installed native ws-direct-eio transport.
The HTTP fixture adapter runs curl in a system thread so BiDi can process
messages while Classic commands are pending. No repository build ran locally.

The final run completed successfully, including session close and reopen.
`execution.json` records exit status; `sources.json` hashes every sampled source.
`probe.log` records native interaction assertions; `downloads.json` preserves
session/download UUIDs, descendant-frame correlation, filenames, verified paths
and sizes. All four completed files matched the fixture's exact 40,960 binary
bytes: attachment, duplicate filename, HTML download attribute, and iframe link.
A different tab saw no records. Closing the task tab retained download lookup
while the Firefox session survived. `screenshot.png` is the same run's validated
viewport capture, not evidence of model-side image understanding.

Artifact publication in this interpreter run uses an explicit byte-count
adapter (`artifact.probe_bytes`), not the production blob store. The compiled CI
fixture and test_browser_downloads instead call the production durable publisher
and keeper_artifact_read, reconstructing every byte through its paged interface.
Their execution remains separate CI evidence; this directory does not claim
those linked tests passed. Two reducer and two setup-lifecycle tests separately
passed in the OCaml source interpreter. Public .mli constraints were also checked
in the interpreter, and changed files passed parser/stanza static checks.

An earlier merged-source run passed interaction/download assertions but timed
out in Classic session deletion; Firefox logged a Remote Settings quit barrier.
The subsequent yielding-HTTP probe completed cleanup. This does not establish
that the asynchronous HTTP adapter alone explains the Firefox-internal barrier.
That failed trace remains at /private/tmp/masc-download-final-probe-20260907.

Reproduction (paths are explicit operator-provided binaries, output owns its
processes and temporary files):

```sh
python3 scripts/probe-firefox-controls.py \
  --geckodriver /path/to/geckodriver \
  --firefox /path/to/firefox \
  --out /path/to/isolated-proof
```

CI supplies `--compiled-probe _build/default/test/firefox_controls_probe.exe`
and therefore also measures the real durable artifact/reader path.
