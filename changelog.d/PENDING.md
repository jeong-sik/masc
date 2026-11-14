### Fixed

- A Lane Add-on Detach says what it did to the declaration that wanted the
  worker. The reply carries a `declaration` object: `removed` with the deleted
  file's `path`, `absent`, `kept` with a `reason`, or `not_declared`. A
  deletion is also written to the server log with the instance and the path
  (#45289, #PENDING).
