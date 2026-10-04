# H2 common Lane inventory parity

Baseline `e6f576349f9d54242148d7d3b95e20202256c86c`, review 4177754958.
The actual H2 gateway lacked GET `/api/v1/lanes`; authenticated admin requests
returned 404. The new arm uses the existing CanAdmin gate and the same
Server_lane_inventory snapshot/serialization as H1, with existing H2 CORS.

A real H2 client/server socketpair runs through Server_bootstrap_http and the
actual gateway. The baseline returned 404 instead of 200 (red.log). With the
seven-line route addition, all five inventory tests passed. The H2 case checks
admin 200, anonymous 401, Worker 403, the common schema and every builtin row,
and verifies that reading constructs no package manager and changes no files.
The original H1 authorization/projection boundary tests remain.

```sh
opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_server_lane_inventory.exe
_build/default/test/test_server_lane_inventory.exe test 'read boundaries' 4
_build/default/test/test_server_lane_inventory.exe
```

Both focused builds passed. These are local actual HTTP/2 protocol and native
fixture tests, not a deployed H2_only service, browser, full-suite, CI or release
result. Parent propagation remains pending; evidence binds this repair baseline.
Raw logs and EOF whitespace are preserved.
