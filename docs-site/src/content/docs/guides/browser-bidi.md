---
title: Firefox BiDi Browser Addon
description: Configure a dedicated Firefox, attach the browser Addon, and verify its owned BiDi connection.
---

The browser Addon can start a dedicated Firefox and own its WebDriver BiDi
connection. Configure the backend, then attach the Addon using the
[Browser Lane guide](../browser-lanes/#install-the-browser-addon). The server
loads the configuration; the attached worker owns the browser's lifetime.

## Prepare Firefox and its profile

Use an installed Firefox executable and an existing dedicated profile directory
owned by the account running MASC, with permissions `0700`. The setup command
creates a missing profile with those permissions and writes the runtime table.
It does not repair an existing directory: verify that dedicated directory's
ownership and permissions before attachment:

```bash
masc browser-lane-setup --mode bidi --base-path /path/to/workspace \
  --firefox /absolute/path/to/firefox \
  --profile /absolute/path/to/dedicated-firefox-profile \
  --port 9222
```

Explicit `--firefox`, `--profile`, and `--port` update their existing keys;
omitted keys retain their values. `--base-path` names the workspace containing
`.masc`. If `MASC_CONFIG_DIR` selects another config root, edit the resolved
`runtime.toml` there. Edit existing tables rather than appending duplicate ones:

```toml
[browser.live]
enabled = true

[browser.live.bidi]
firefox = "/absolute/path/to/firefox"
profile = "/absolute/path/to/dedicated-firefox-profile"
port = 9222
```

The port defaults to `9222`. Keep it free and close any Firefox already using
that dedicated profile before attaching. A busy port is refused; MASC does not
adopt the browser listening there. Log in once in the managed Firefox to keep
those logins in its dedicated profile. The loopback debugging port has no
authentication: other local programs can control that Firefox and read its
cookies, so use a profile limited to the sites the agent needs.

## Attach and verify

1. Restart MASC after changing `runtime.toml` so it loads the backend settings.
2. Install the bundled browser package in the active config root's
   `lane-addons/` directory as described in the [installation guide](../browser-lanes/#install-the-browser-addon).
   For an existing installation, detach it and attach a new instance to capture
   changed backend settings.
3. Inspect the installation's `desired_revision`, `applied_revision`, `phase`,
   and configuration issues. A saved TOML or configured `bidiHost` status alone
   does not establish an attached worker or usable connection.
4. Discover connections and tabs with `BrowserTabs`. Keep the observed
   `clientId` and `tabId` for subsequent reads and interactions. Read a normal
   HTTP(S) page and capture a fresh viewport before pointer input.

The worker checks its original process owner, kernel lease, child birth/group,
profile identity, and BiDi `moz:processID` before publishing its connection.
Configured Firefox startup failure prevents that installation from becoming
ready and joins the other backends it started. The private worker allocation
contains `live-firefox.log`; inspect Addon observations for readiness and failure
rather than inferring them from a browser window.

## Stop or change the managed browser

Set `enabled = false` at the top level of the installation TOML and let
reconciliation detach it. File changes are read at startup and on the existing
maintenance pulse; Dashboard Refresh reads the result and does not force
application. Check the detached state and cleanup result before reusing its
profile or port. Removing the declaration is applied after a complete config
scan; an unreadable scan does not authorize removal.

Detachment fences new input before joining the original peer and child. An
orderly shutdown sends `browser.close` once; failure retains an unconfirmed
outcome. Profile contents and stable claim files are preserved. A retired
connection cannot be reused; discover the new instance's connection after
reattachment. An uncertain input is never replayed automatically.

`[browser.live] enabled = false` excludes this backend from the next attachment.
It does not stop an existing worker that already captured the settings. Stop
that installation through its Addon lifecycle.

## External Firefox connections

A manually started Firefox and standalone
`masc-browser-host --bidi-url ws://127.0.0.1:9222/session` remain an explicit
external connection. Install its launcher with
`masc browser-lane-setup --mode host --base-path /path/to/workspace` and connect
it to an attached browser Addon. The operator owns that browser's process
lifetime. This host's manual connection diagnostics are separate from the
managed Addon's readiness.

## Interaction scope

BiDi provides native hover, pointer input, keyboard input, and guarded semantic
interactions on readable pages. Firefox internal pages can reject scripts and
remain in `unavailableTabs` with `complete: false`; another readable tab can
still be used. Explicit `BrowserAct action="open_tab" lane="live"` with the
observed `clientId` and an HTTP(S) URL creates a new tab without replacing an
existing one.

After hover, read or capture again to find newly exposed controls. Verify the
application state after a drag: a successful input receipt does not prove the
page accepted the drop. Check the connection's reported capabilities for other
actions; browser zoom, uploads, and other features are not interchangeable
between transports. The Addon lifecycle scenarios use a scripted BiDi peer;
they do not establish operation on every installed Firefox build or website.
