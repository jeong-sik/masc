### Performance

- The waiting-age list under the Keeper workspace rail's second `작업 대기열`
  section and under `오래 기다린 순서` on the Monitor lane panel mounts only
  the rows near its scroll position instead of every server row, and scrolls
  inside its own box as tall as the lane strip's list instead of growing the
  rail by one bar per waiting row. It keys its rows and hands keyboard focus
  back to the list the way the lane strip's list does. Browser find reaches
  only the mounted rows of a list longer than 40 rows (#PENDING).

### Fixed

- The waiting-age list forgets its open row once the list no longer has that
  row's place, so the row that later takes the place starts closed. Selecting
  another Keeper on the Monitor lane panel starts that Keeper's list at its
  first row with nothing open; the list kept the previous Keeper's scroll
  position and open place (#PENDING).
