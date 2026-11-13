### Fixed

- A 500 the HTTP layer writes for a failed request says `Internal server error`
  and no longer carries the OCaml exception's text, which could name a file of
  the server on paths reached without a credential. This covers the HTTP/2 and
  HTTP/1.1 connection error handlers, a route that raises before its response,
  and a route that raises in its request body callback. The exception's text
  is logged once at error; the HTTP/1.1 error handler and the body callback
  path logged nothing before (#PENDING).
