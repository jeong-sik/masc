### Internal

- `test_h2_gateway_http` reads Fusion runs with the fixture's Worker token and
  asserts that a Player token gets 403: #50387 put those reads behind the
  Board reader check, which needs `CanReadState`, and the case still read as
  a Player. The fixture also clears `MASC_HTTP_BASE_URL` and `MASC_HOST` for
  its run, so a shell that exports a non-loopback value no longer turns
  strict auth on under cases that declare it off (#PENDING).
