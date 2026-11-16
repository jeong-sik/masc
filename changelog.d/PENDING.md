### Fixed

- A dashboard cache read whose computation raises fails with that error
  instead of being taken for a runner that gave up. The cache decided from the
  exception: a closed time window raised an exception the computation could
  raise too, and so could a cancellation. A computation that raised either at
  once was read as its runner giving up, so the read computed again until its
  window closed, or forever without one. The window now answers with a value,
  and a runner gave up only when its own fiber was cancelled. Whatever the
  computation raises, `Eio.Cancel.Cancelled` included, reaches the reader and
  does not count toward the key's timeout circuit. A computation that
  outlasts its window is still a timeout (#52277, #PENDING).
