### Fixed

- Standalone test execution applies the declared directory and suite environment
  through the existing Dune stanza reader, preserving empty values and nested
  overrides. Unsupported action dependency values fail before compilation.
