### Fixed

- A raw trace file that stops accepting writes no longer fails the run it was
  recording. A refused assistant-block record failed response collection before
  the provider response was committed, and a refused tool or hook record ended
  the turn after the tool had already run. Each refused record is now a warning
  that names the run and the record it belonged to, and the response, the tool
  result and the hook decision stand (#50571).
