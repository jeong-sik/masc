# imp first-conversation acceptance

The acceptance target is an operator selecting one owned runtime, starting the
seeded `imp` in its default Docker sandbox, exchanging a real greeting, creating
a Board post and an open Task, listing that sandbox directory, and fetching a
public web page. Completion of the Task is outside this release check.

`baseline-macos-spark/` records an earlier installed binary and an existing CLI
login. Its receipt names the source revision. It is baseline evidence, not proof
of the final distribution or a fresh CLI home.

For a downloaded native release installation, run these checks with an isolated
workspace and CLI home. Keep credentials outside the output directory:

```sh
python3 scripts/imp-onboarding-setup-pty.py \
  --binary /path/to/installed/masc \
  --base-path /path/to/configured/disposable-workspace \
  --output /path/to/new/setup-evidence

python3 scripts/imp-onboarding-acceptance.py \
  --binary /path/to/installed/masc \
  --codex-auth /path/to/private/auth.json \
  --model gpt-5.3-codex-spark --context 128000 \
  --output /path/to/new/conversation-evidence
```

The PTY check uses the caller's configured runtime and authentication environment.
It starts `masc setup` with no existing server, verifies an actual TUI frame and
an already-live imp, then checks that leaving the TUI stops the owned server.
The conversation check copies only the supplied Codex credential into a private
temporary home and removes that home at exit. It uses real model inference and
Docker, with no approval overrides. Its output includes SSE, raw tool traces,
persisted Board/Task records and the installed source revision. Failed runs retain
raw evidence but do not write a success receipt. Output directories must be fresh.

Optional `--playwright-module` and `--browser-executable` arguments exercise a
real browser chat and save a screenshot and separate browser receipt. The browser
uses the disposable workspace's operator token without putting it in the URL.

An isolated home on macOS shares the machine's installed native dependencies.
An Ubuntu container with the Docker socket shares its host's Docker daemon.
These environments test clean configuration and installed userland; they are not
claims of pristine physical machines or every supported model provider.
