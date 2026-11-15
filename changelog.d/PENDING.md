### Fixed

- When the workspace `runtime.toml` cannot be read or does not parse, the
  server log now carries a warning that names the file, says which of the two
  happened (`reason` is `unreadable` or `unparsable`), and quotes the loader's
  or the parser's own report. This covers every route that reads it for a
  person or for web setup: the integration list, the provider account list
  (also through the person's MCP `Runtimes` tool), model setup and account
  login. The person still gets the same 503 and the same sentence. Before,
  both cases became one error with no reason and nothing was logged
  (#51793, #PENDING).
