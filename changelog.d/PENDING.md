### Fixed

- A server started with `--host ::1`, or any other IPv6 address, boots: the
  base URL and the MCP URL it writes put the address in brackets
  (`http://[::1]:8935`), where `http://::1:8935` was refused as its own
  trusted identity and the boot ended with exit 1. The `servers` URL of
  `/api/v1/openapi.json`, the gRPC URL of the transport status, the base URL
  derived from `MASC_HOST` and the URL `masc keeper up --host` posts to
  bracket an IPv6 host the same way (#PENDING).
