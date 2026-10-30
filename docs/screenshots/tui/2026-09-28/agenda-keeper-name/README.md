# Agenda keeper-name PTY frames

These PNGs replay the **actual 100×30 PTY frames** captured by the `schedule-source-status` targeted test. Text and cell positions come from the captured frames. The local replay font is DejaVu Sans Mono and colours are simplified to monochrome; use the linked raw job logs for exact ANSI bytes.

Fixture: `payload_keeper_name = recovered-keeper`; encoded `payload_target` is either `keeper:encoded-keeper` or `encoded-keeper`. The agenda is row 29.

| Input | Before (base probe) | After (PR #39504) |
| --- | --- | --- |
| `keeper:encoded-keeper` | [PNG](before-prefixed.png): `encoded-keeper` | [PNG](after-prefixed.png): `recovered-keeper` |
| `encoded-keeper` | [PNG](before-unprefixed.png): `encoded-keeper` | [PNG](after-unprefixed.png): `recovered-keeper` |

- Before: [Test run 36363985816, job 108746608791](https://github.com/jeong-sik/masc/actions/runs/36363985816/job/108746608791), head `0949e47f124c289a01638e957ee1ab196964c68f`, success. TUI binary SHA-256 `e09a137e220c944b3fd9f998a6b6dbc0892212f83aa07613905e785ebaedaf59`.
- After: [Test run 36363983638, job 108746602782](https://github.com/jeong-sik/masc/actions/runs/36363983638/job/108746602782), head `2d329544b0369b76b304256a7a97e329dc9d4d9c`, success. TUI binary SHA-256 `25ddc0644edab5add243d86fca871273ad0813185d11ef25700e242a0fb3d0ab`.
- The test logged each frame as compressed raw PTY bytes under `SCHEDULE_SOURCE_PTY_EVIDENCE`; the PNGs are derived from the `source-recovered` frame. Raw frame SHA-256 values, in table order: before prefixed `cf4525695b58aa4a18110634c9187b82a6f0d04ed15f8612d57c52e92f36aba5`; after prefixed `6c6d4f7ad501e442896ac6e8139c36be21fec8974ae05a8708a3eda755124a6e`; before unprefixed `cebe4b14e8ad92aee6beabe0373da2c9809ef9f8bac47495637207161d05d415`; after unprefixed `05e666877e400bb42da1dccf849d56e1ae389060a1f007c3b10fd00bfc737174`.
