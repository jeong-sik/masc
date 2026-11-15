### Internal

- Tests: `test_tui_board_request_outcome` starts the TUI request domain in a
  switch of its own inside the fixture's server switch. On the server switch,
  the server's connection fibers waited for the domain's idle keep-alive
  connections, which closed only when the pool evicted them, so each of the
  four cases that call the server directly ran about 90 seconds past its last
  assertion. The 10-second fixture deadline now also covers the end of the
  server switch (#47527, #PENDING).
