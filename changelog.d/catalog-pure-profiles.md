### Refactored

- Provider catalog parsing now shares pure capability records and presets without
  depending on model-policy lookup or execution configuration. Wire default paths
  live with the closed provider kind. Existing policy values and parsing behavior
  are preserved. Derived debug-printer module prefixes follow the new profile
  owner. Atomic publication of the complete catalog remains separate work.
