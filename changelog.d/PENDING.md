### Fixed

- The count-tokens request an exact-output plan sends before its generation
  request now carries the target binding's declared headers (for an Anthropic
  binding, `anthropic-version`). It was written from the projected config,
  which holds no binding headers, so only the generation request carried
  them. Both header lists are now written by one function from the auth
  headers the plan resolved once, and they differ only in what follows from
  their bodies (#51643).
