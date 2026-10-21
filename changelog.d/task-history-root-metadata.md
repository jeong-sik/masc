### Fixed

- Keep normal Activity sequence and local lock bookkeeping out of Task history
  date validation, so real Task creation can be read alongside audit history.
  Unknown entries and metadata in other stores or month directories remain errors.
