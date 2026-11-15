### Fixed

- The Plugins overview packs its key row from whole keys, so a narrow window
  breaks the row between two keys instead of cutting `n:new` into `n:n` and
  `ew`. The body joins the keys with ` · ` like the other key lists on that
  screen; the footer keeps its two-space row and still drops keys from the
  back (#50573, #PENDING).
- The MSX game menu wraps the reason it shows above the list over up to half
  of the rows between the title and the footer, so the list keeps a row and
  Enter still picks the highlighted entry. With no picture, the MSX and DOS
  screen titles wrap the same way, so a failed read is shown to its end; a
  title over a picture stays one row (#50573, #PENDING).
