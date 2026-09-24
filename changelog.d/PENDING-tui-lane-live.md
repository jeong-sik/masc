### Changed

- The TUI reads the machine screen through
  `GET /api/v1/lane-addons/live` instead of `/api/v1/msx/frame`. Each read
  sends the `since` change count and `incarnation` of the picture already
  drawn. A `state: "unchanged"` answer draws nothing and decodes no pixels.
  `state: "no_machine"` says no machine is loaded. A failed read is drawn
  as its error, not as an empty machine or an old picture. The MSX tick
  (`POST /api/v1/msx/tick`) still advances a watched MSX game.
- The MSX load menu (`&` or `:go msx`) now also lists `watch DOS machine`
  while a DOS machine is loaded. Picking it shows the DOS screen, scaled the
  way an MSX frame is and titled by its change count. Only `Esc` and `+`/`-`
  act there, and no key reaches either machine.
- The live route names no mode or cartridge, so the menu's MSX watch row
  reads `watch MSX machine` instead of the cartridge name. The spectator
  title shows the mode and cartridge again once the first tick answers.
