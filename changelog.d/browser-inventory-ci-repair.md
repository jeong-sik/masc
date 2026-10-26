### Fixed

- The browser inventory TUI decision match now keeps Result exhaustiveness checks active under strict compiler warnings.
- The multi-worker uniqueness regression keeps a semantically unreadable candidate ready, avoiding a race where a background observer consumed a one-shot transport failure.
