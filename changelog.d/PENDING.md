### Fixed

- A Task history note that is a deeply nested JSON document no longer holds
  the TUI's preparation for seconds and gigabytes. The served document used
  to spell every line's indent out as spaces before a row kept at most half
  its width of them, so a note nested 10,000 deep built 200 MB of text. Its
  lines now carry their indent as a count, and a row makes only the spaces it
  keeps; the rows drawn are byte for byte the same (#48554, #PENDING).
