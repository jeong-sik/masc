### Fixed

- Closing the GitHub login window now cancels the login, including while a
  Remote_ssh lane is still being shaped (endpoint preflight, control-root
  bootstrap, workspace preflight) and while the identity probe after a
  successful login runs. Before, only the login process was covered, and over
  HTTP/1.1 not even that: the server learns that a client left only when a
  write fails, and a waiting login wrote nothing after the one-time code, so
  `gh auth login` and its endpoint session stayed until the 600-second login
  timeout. The login stream now sends an SSE keepalive comment every 30
  seconds. The cancelled request ends its ssh process, and the endpoint's
  shim stops `gh` when that channel closes. Once `gh` is seen to exit 0, securing
  the credential it wrote runs to the end even if the window closes at that
  moment, its last output arrives after the close, or an HTTP/2 stream reset
  cancels the whole response. Before, each of those skipped securing
  (#32910, #PENDING).
