# Board attachments and the alphaTex tab in the TUI

Screens from the top of the board attachments stack (#42766, #42767, #42768,
#42769, #42775, #42777, #42779), taken on 2026-10-13 KST.

## How they were taken

- `bin/main_eio.exe` and `bin/masc_tui.exe` built from the stack top, the
  server started on loopback with an empty base path made for this run. No
  operator workspace and no running server were involved.
- The TUI ran in a detached tmux session, 112x34 for images 01 to 06 and
  72x40 for image 07, and was driven with `tmux send-keys`.
- Each image is the pane as `tmux capture-pane -e` returned it, drawn to PNG
  by a script with a monospace font. They are not photographs of a terminal
  window: colours are the pane's own, but the spacing of wide characters (the
  Korean in the fence header) is the script's, not a terminal's.

The two attached files are 45 and 26 bytes of placeholder content named
`riff.gp5` and `take1.mid`. Nothing here shows a real Guitar Pro or MIDI file
being read, because the TUI does not read them: it stores and lists them.

## What each image shows

| Image | Keys | What is on screen |
|---|---|---|
| `01-compose-attach-path.png` | Board, `w`, type the post, `Ctrl-A`, type a path | The attach path is typed on its own row above the draft, and the footer names its keys. |
| `02-compose-staged-and-refused.png` | `Enter`, attach a second file, then a path that does not exist | Two files are staged with their kinds. The third path is refused with its reason and stays in the input. |
| `03-compose-send-menu.png` | `Esc`, `Esc` | The staged list stays while the send menu is open. |
| `04-read-attachments.png` | `s`, `Enter` on the post | The post was sent after both uploads. The read pane lists each attachment by kind, name and size. |
| `05-read-alphatex-tab.png` | a post with an `alphatex` fence, `Enter` | The fence is drawn as tablature in two systems. `7*` is a note that carried technique markup, and the measure with two-digit frets is wider so `12` and `10` do not run together. |
| `06-read-alphatex-fallback.png` | a post whose fence uses `\subtitle` | The score is outside what the TUI draws, so the fence shows the reason and the highlighted source. |
| `07-read-alphatex-tab-narrow.png` | the post of image 05 at 72 columns | The same tab breaks after the third measure instead of the fourth. |

## Not covered

- The dashboard was not opened. Its attachment cards are covered by the
  Vitest suites named in #42766.
- Every upload here is a few bytes. The 32 MiB limit and the refusals for a
  symlink, a directory and an empty file are covered by
  `test/test_tui_board_attachments.ml` and `test/test_artifacts_upload.ml`,
  not by these images.
- A tab body with a literal TAB character reaches the fence as `\x09` on the
  board read pane and fails as an unknown directive. That is the board body's
  sanitizer, tracked in #42782.
