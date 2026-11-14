### Internal

- The `/mcp` credential verdicts of `Server_auth` (`verify_mcp_auth`,
  `verify_seat_mcp_auth`, `verify_mcp_auth_for_authority`,
  `verify_mcp_observer_stream_auth`, `verify_operator_mcp_auth`) return
  `(unit, masc_error) result`. They returned an `'a option` that was `None`
  on every admission, so the type promised a `Some` that never came and a
  caller could not read "a credential was checked" from it. Which requests
  are admitted or refused is unchanged (#51752, #PENDING).
