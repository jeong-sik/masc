### Fixed

- A Codex vendor turn that ends before a dynamic-tool result is delivered
  retains that result the way a host receipt is retained: a base64 `data:`
  image becomes a blob address, and once the result's `inputText` reaches
  2,048 bytes each body that is shorter as a marker becomes that marker. The
  receipt that every later request re-reads until a completed turn
  acknowledges it no longer holds those bytes, and blob maintenance keeps the
  addresses it names. The frame sent to the vendor is unchanged (#PENDING).
