### Fixed

- A release installation carries the browser Add-on programs. The release
  build, its assets and `scripts/install.sh` left out
  `masc-native-addon-launcher` and `masc-browser-addon-worker`, so a browser
  Add-on declared on a release installation could not start, and
  `browser-lane-setup` reported both as not found beside masc or on PATH. Both
  are now built on every release platform, published, checksummed and
  installed into the prefix beside masc; `--uninstall` removes them. The
  release-list consistency suite now reads every copy of the release
  executable list and requires the programs the browser Add-on runs
  (#45119, #PENDING).
