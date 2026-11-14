### Fixed

- A child started through the posix_spawn stub gets each standard stream
  from the descriptor the caller named even when that descriptor is itself
  numbered 0, 1 or 2. A process whose fd 0 was closed and then reused by
  its output file started children whose stdout went to `/dev/null` while
  they still exited 0, and swapped stdout and stderr sources both landed on
  one file (#47475, #PENDING).
- The fork-based detached spawns wire a child the same way: capture pipes
  or an output file that landed on a closed standard descriptor no longer
  leave the child without that stream (#47475, #PENDING).
