### Added

- Ego native workflow Fetch can save binary responses through the existing download artifact broker. A requested filename maps to a private UUID path; receipts identify the saved response, and completed saves remain retrievable after a later workflow failure while the same SDK session survives.

### Fixed

- Ego download rows distinguish native download events from Fetch saves and reject unknown provenance before publication.
