### Fixed

- The Keeper roster keeps its rows when the fleet moves across 60 keepers.
  It drew a plain list up to 60 list items (keepers plus status group
  headers) and a `VirtualList` above that, so crossing the count rebuilt
  every row and dropped the keyboard focus inside it. The roster now draws
  through `VirtualList` at every count, which keeps one DOM tree across its
  own 40-item threshold (#51991, #PENDING).
