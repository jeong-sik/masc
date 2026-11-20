### Changed

- The footer's action notice draws why the server's action reasons are
  not there: `조치 원인 ?` / `Action reasons ?` when the server identity
  did not carry them, `조치 원인 ✕` / `Action reasons ✕` when it carried a
  list this build could not read. Both read `조치 원인 미관측` / `Action
  reasons unobserved` (RFC tui-one-screen-grammar 6.4).
- The context inspector draws `?` for a turn's model the record did not
  carry, and says the context window was "not reported" instead of "not
  observed", as its other lines already do.
