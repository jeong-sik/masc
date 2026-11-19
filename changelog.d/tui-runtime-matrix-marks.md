### Changed

- The TUI Keepers runtime view draws each row's gutter, status mark and pulse
  like the other grid views: a sound Keeper reads `●` instead of a warn `!`,
  and only a failed half hour wears the warn tone. A Keeper with no failure
  reads `—` in the last-failure column instead of `?`, a resting head wears
  the waiting mark, and the legend follows the screen language.
