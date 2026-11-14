### Fixed

- A restart that fails a direct Keeper operation running with no native call
  and nothing to resume also settles its semantic execution as `Failed`, with
  the operation's failure detail, in the same transaction. The execution used
  to stay `Recovering` with an interrupted origin that no action ends, so the
  Keeper's history clear and retirement check refused forever and the failed
  operation's native history read was refused as a damaged binding
  (#46918, #PENDING).
