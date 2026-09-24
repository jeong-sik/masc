### Added

- The MSX and DOS machines keep a change counter. It rises on every run of
  the machine (a tool, an HTTP press or tick, a load, a restore, a disk
  change, and a DOS run that ends in a guest fault) and never on a read. It
  is one counter per machine kind per process and never resets.
- `GET /api/v1/lane-addons/live?source_kind=msx_capture|dos_capture&since=N`
  answers the current screen of that workspace machine without a Lane
  instance: `{"changed":false,"counter":N}` when the counter still equals
  `since`, otherwise the capture fields (`format`, `width`, `height`,
  `rgb_base64`) with the picture's machine time (`frame` or `steps`),
  `counter` and `incarnation`, or `{"loaded":false}` with no machine. It needs
  read authentication, writes nothing to the Lane store, never advances the
  machine, and takes the machine lock on a system thread. A kind without a
  screen, an unknown kind or a `since` that is not a decimal counter is 400.
