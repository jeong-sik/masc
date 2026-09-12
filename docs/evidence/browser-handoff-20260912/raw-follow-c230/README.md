# Raw text follows a changed page from its first line

The native TUI runs against an isolated HTTP browser fixture. After observing
Beta, the test scrolls its raw text away from the first line, then the fixture
changes the pinned tab to Gamma. No key refreshes the page after the change.

- Before: source `a3ebdbc879`, TUI SHA-256
  `1861debe1a6249453c7e2b57efeff44c5f37475b78280a88b7583ec2cb97e778`.
  `before.log` preserves the failure waiting for Gamma's first line.
- After: source `c2304e75b9287f50ff006ef5ffdca768ed9bb4e7`, TUI SHA-256
  `821a88fe8299a0e367496adff2e65ddaafd3af6f6de9be4c0c5712e9a5a6d781`.
  `after.log` retains five native PTY records; the full scenario exited 0.
  Gamma's current URL and `GAMMA TEXT READY` appear together at `Text 1/81`.
- [Compiled focused tests](https://github.com/jeong-sik/masc/actions/runs/34696276490)
  and [native macOS artifact](https://github.com/jeong-sik/masc/actions/runs/34696278011)
  are both bound to c230. The artifact's SOURCE_COMMIT and SHA256SUMS were verified.

`external-raw-navigation-resets-scroll.png` is a replay of captured native PTY
bytes in xterm at 100 columns by 30 rows. It is not a physical-terminal screenshot.
The fixture labels the source live/Zen, but this test does not attach to a real
browser or Keeper. Actual Firefox/Keeper region following is proved separately
in [persistent-follow](../persistent-follow/README.md). The later main merge is
covered by its own PR checks; this runtime proof remains bound to c230.
