# Repository writer coverage before-change PTY

Installed binary reported build `1a932903317b6e2d526dc242fa371578e7721414`.
`python3 test/test_tui_repository_writers_pty.py /Users/dancer/.local/bin/masc-tui`
ran a real PTY against synthetic HTTP data: roster alpha/beta, repository assigned
only to alpha, one repository write from each and another-repository beta write.
The first 60-column scenario failed waiting for beta-change.ml; only alpha's
write was visible. The final completed screen is `before-60.txt`, with right cell
padding removed. No live Keeper work was invoked.

The repair reads the loaded roster and retains exact repository-ID filtering.
Deleted/unloaded Keepers remain outside this stated scope. Parsing and source
review do not prove candidate behavior; after-change PTY and deployment are
separate, pending stages.
