### Fixed

- A DOS call that takes the controller is refused as unavailable while
  `auth/config.json` cannot be read. Such a file was treated like an install
  that does not require tokens, so a seat that had left its play session could
  still move the machine (#PENDING).
