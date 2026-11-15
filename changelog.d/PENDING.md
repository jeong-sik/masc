### Fixed

- The HTTPS listener gives a session 30 seconds from the end of its TLS
  handshake to begin its first request, the bound a cleartext connection has
  from its accept. Before, a client that finished the handshake and sent
  nothing held its connection with no bound. The listener now reads the
  first bytes before it picks the handler, and a session whose first bytes
  are the protocol ALPN did not settle on (an HTTP/1.1 request on an `h2`
  session, the HTTP/2 preface on an `http/1.1` one) is closed instead of
  being served. Both are logged at debug; neither counts as a handshake
  failure (#50483, #PENDING).
