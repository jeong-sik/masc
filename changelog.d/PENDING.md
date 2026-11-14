### Changed

- A provider request answers with the final HTTP response: interim 1xx
  responses sent before it (100 Continue, 103 Early Hints) are read past on
  the same connection instead of being returned as the answer. This holds for
  `get_sync`, `post_sync`, `delete_sync`, `post_sync_once` and
  `with_post_stream`. 101 Switching Protocols is still returned as it is. An
  exact-output attempt that met an interim response is now decided on the
  final response of the same dispatch instead of staying unresolved as
  `Response_informational` (#48910, #PENDING).

### Fixed

- A response body the peer's close ends before its `Content-Length`, or
  before the last chunk of the chunked coding, is no longer returned as a
  successful response holding the bytes that arrived. The request fails with
  `NetworkError { kind = End_of_file }`; `post_sync_once` reports it as
  `Response_received_error` with the status it read. A response that declares
  neither a length nor the chunked coding still ends where the server closes
  the connection (#48910, #PENDING).
- `get_sync`, `post_sync` and `delete_sync` called without a connection cache
  return the peer's close as `NetworkError { kind = End_of_file }` instead of
  raising cohttp's `Failure "connection closed by peer"` (#48910, #PENDING).
