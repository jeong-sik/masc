### Fixed

- A server keeps its BasePath lease when it asks about its own lease file a
  second time. A POSIX lock ends when the process closes any descriptor of
  the file, and two paths reopened it: a lease root spelled another way
  (macOS names one directory `/private/tmp/X` and
  `/System/Volumes/Data/private/tmp/X`) was not recognised as the lease the
  process holds, and `masc start` read the lease file through a second
  descriptor after its exec, so a `masc start --wait-for-previous-owner`
  sleeping on the lease could take it from the start that had won. The
  process now finds what it holds by the `(st_dev, st_ino)` of the lease
  file, and after an exec commits on the one descriptor it opens (#PENDING).
