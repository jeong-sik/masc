### Fixed

- A dashboard cache read whose computation raises fails with that error
  instead of being taken for a closed time window. The window used to close
  by raising an exception that the computation could raise too; a computation
  that raised it at once was read as its runner giving up, so the read
  computed again forever and never returned. The window now answers with a
  value, so whatever the computation raises reaches the reader and does not
  count toward the key's timeout circuit. A computation that outlasts its
  window is still a timeout (#52277, #PENDING).
