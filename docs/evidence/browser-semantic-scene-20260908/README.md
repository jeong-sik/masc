# Browser semantic scene: real Gecko evidence

An owned loopback fixture exercises the exact shared JavaScript embedded in the
OCaml WebDriver backend and Firefox/Zen extension. Both browser executables passed
12 checks, including stable references through reordering, literal Unicode fill,
replacement/reload refusal, visibility inheritance, and unchanged page DOM/CSS.

| Browser | Scene request | Scene UTF-8 JSON | Viewport PNG |
| --- | ---: | ---: | ---: |
| Zen | 14.23 ms | 2,618 bytes | 38,876 bytes |
| Firefox | 8.15 ms | 2,634 bytes | 39,161 bytes |

These are single loopback WebDriver observations, not throughput benchmarks. Scene
and screenshot encode different information: the scene omits full paint order,
occlusion, pseudo-elements and shadow trees. PNG retains the painted appearance.
The scene does not expose input values. Its resource ceiling covers complete
serialized UTF-8 JSON, including metadata; oversized identity is rejected.

- [Zen receipt](zen.json), [Zen screenshot](zen.png)
- [Firefox receipt](firefox.json), [Firefox screenshot](firefox.png)
- Reproduce: `python3 test/test_browser_scene.py --driver /path/to/geckodriver --browser /path/to/browser --out /tmp/scene-proof`
- Resource/HTTP-context check: `node test/test_browser_scene_resource.cjs`
- Existing interaction contract: `node test/test_browser_interact_extension.mjs`

The first probe failed because WebDriver's temporary `globalThis` did not retain
scene references. Using the frame's `window` preserved references on both tested
browsers. Same-URL reload still invalidates the old document identity.

This receipt proves actual Gecko execution of shared scripts. It does not prove a
new OCaml server/native-host binary, extension installation/reload, TUI rendering,
or the ordinary logged-in profile. Those are separate deployment checks. Local
Dune builds were not run.

Primary references:
- [Mozilla Marionette execution contexts](https://firefox-source-docs.mozilla.org/python/marionette_driver.html)
- [MDN getRandomValues](https://developer.mozilla.org/en-US/docs/Web/API/Crypto/getRandomValues)
- [MDN Range.getClientRects](https://developer.mozilla.org/en-US/docs/Web/API/Range/getClientRects)
- [MDN native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging)
