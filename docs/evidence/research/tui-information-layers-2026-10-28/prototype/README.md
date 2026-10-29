# Synthetic layer sketches

These are static, generated sketches, not captures of MASC, interactive TUI
behavior, or a usability study. On 2026-10-28 around 18:14 KST, Python 3.14.4
ran [prototype.py](prototype.py) with one synthetic 12-line chat and 18-row
queue. The selected queue row is the same in every sketch. Each queue frame
includes a status, action receipt and selected-item note; the common footer
shows actions. The sketch uses Unicode East Asian width plus combining-mark
handling; terminal-specific glyph widths, emoji and line wrapping are not
evaluated. Long rows are truncated to one line with an ellipsis.

The side sketch assigns 52% of columns to chat; the bottom sketch assigns 60%
of body rows to the sheet. These fractions are experimental inputs, not
product thresholds. The full sketch also uses this simplified fixture and is
not the current Queue renderer. Run the helper with an output directory to
regenerate the nine frames and [measurements.json](measurements.json). At
18:55 KST the text files were regenerated with trailing blank cells omitted;
the recorded measurement values did not change.

| Size | Frame | Queue rows visible / clipped | Chat rows visible / clipped | Selected queue row clipped |
| --- | --- | ---: | ---: | --- |
| 80×24 | [full](full-80x24.txt) | 15 / 0 | 0 / 0 | no |
| 80×24 | [side](side-80x24.txt) | 15 / 4 | 12 / 5 | yes |
| 80×24 | [bottom](bottom-80x24.txt) | 6 / 0 | 8 / 0 | no |
| 120×36 | [full](full-120x36.txt) | 18 / 0 | 0 / 0 | no |
| 120×36 | [side](side-120x36.txt) | 18 / 1 | 12 / 0 | yes |
| 120×36 | [bottom](bottom-120x36.txt) | 13 / 0 | 12 / 0 | no |
| 160×40 | [full](full-160x40.txt) | 18 / 0 | 0 / 0 | no |
| 160×40 | [side](side-160x40.txt) | 18 / 0 | 12 / 0 | no |
| 160×40 | [bottom](bottom-160x40.txt) | 16 / 0 | 12 / 0 | no |

These are counts for the synthetic strings and chosen proportions. The row
counts do not establish whether an operator can understand, select, reorder,
or recover focus correctly. No keystroke, resizing, mouse, latency or user
preference was measured. In particular, this cannot establish a breakpoint at
120 or 160 columns.

SHA-256 of the generator is
`35abd6937dfb1a4dad9fb46b1aabdbaa0d4b883201f57d803233b5379018a41a`; the
measurements file is
`6527f24fe97bc76922c8d1276783389c55fe1007a23c04d93bc6b5110b465b03`.
