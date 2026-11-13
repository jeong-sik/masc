### Fixed

- The account server reads the `redirect_uri` of a login client as it is
  written. A path that only percent-decodes to the callback
  (`/%61uth/github/callback`) passed the boot check, and the provider then
  sent every login to a path the server answers 404 on; the boot now stops
  and names the path. A redirect with a userinfo, an empty port or a port
  above 65535 stops the boot as well (#PENDING).
