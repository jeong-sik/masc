# Browser lane connectors

The live connector reads the operator's Firefox/Zen session through the extension
in `extension/`. The automation daemon owns a separate browser session. Installing
the native host does not install or connect the extension.

## Install the live host (macOS)

Point the installer at the same base directory used by the MASC server:

```sh
export MASC_BASE_PATH="/path/to/masc-base"
bash connectors/browser/install-host.sh
```

The lane directory is `$MASC_BASE_PATH/.masc/browser-lane`. An explicit
`MASC_BROWSER_LANE_BASE` or `--base` selects the lane directory itself; it must
contain the token used by the server. All base paths must be absolute (`~/` is
expanded using HOME). An absent base is an installation error.

The installer copies the host, configuration helper, and executable launcher to
`~/Library/Application Support/Mozilla/NativeMessagingHosts/masc_browser_host/`
and writes `masc_browser_host.json` alongside that directory. The launcher captures
the resolved base and Node executable, so a GUI browser does not need the terminal's
base environment or Node on PATH. Moving or deleting the checkout does not break
this installed host. Rerun the installer to update its code or select another base;
reinstallation preserves an existing valid token.

Load `extension/manifest.json` separately from Firefox/Zen's `about:debugging` page.
The extension keeps the live lane read-only (`tabs.list`, `page.read`). Temporary
extension loading is browser-owned and distinct from native-host installation;
a successful host test does not prove that an extension is connected.

## Authentication and automation

Both connectors use the same configuration rules:

1. Base: `--base`, then `MASC_BROWSER_LANE_BASE`, then
   `$MASC_BASE_PATH/.masc/browser-lane`.
2. Token: explicit `MASC_BROWSER_LANE_TOKEN`, otherwise `token` in that lane
   directory. An explicitly empty token is invalid and does not fall back.
3. The file is read for each poll/result request, matching server-side token
   rotation. Missing or invalid credentials produce a diagnostic without sending
   an anonymous request. The installer creates a token with mode `0600` if absent.

`MASC_BROWSER_LANE_POLL` can override the default local poll endpoint. For a GUI
launch, configure any endpoint override in the browser's launch environment.

The automation daemon accepts these same base and token settings:

```sh
MASC_BASE_PATH="/path/to/masc-base" node connectors/browser/automation/masc-browser-automation.js
```

## Fixture verification

```sh
node --test connectors/browser/test/host-install.test.cjs
```

The tests install into a temporary HOME, remove the copied source checkout, and
exercise HTTP authentication plus native-message framing against fake peers.
They do not launch a browser or access real tabs, page content, or messages.

Native-host manifest and stdio conventions follow
[Mozilla native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging).
