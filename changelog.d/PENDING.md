### Fixed

- A dashboard bundle read from a folder (`MASC_ASSETS_DIR`, an unbound
  source tree) answers only the names its directories list. Every path
  component must equal a listed name byte for byte, so on a file system that
  folds case (APFS as macOS formats it) `INDEX-48NNFFCC.JS` is 404 instead
  of the bytes of `index-48nnffcc.js`, and such spellings no longer add
  entries to the asset table. A path through a regular file, a name longer
  than a directory entry and a name of a directory are 404 too; they were
  503. A symbolic link and a file with a second hard link stay 503
  (#51705, #PENDING).
