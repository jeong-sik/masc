### Fixed

- A `HEAD` request is answered by the `GET` route with the same fields and no
  content, on HTTP/1.1 and HTTP/2. It used to get a 405 with a 22-byte body,
  which an HTTP/2 client refused as a protocol error and which an HTTP/1.1
  keep-alive client read as the start of the next response. A 405 on an exact
  path now carries `Allow`, and a 204 no longer carries `content-length`
  (#50861, #PENDING).
