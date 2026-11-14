### Internal

- "Board Pele deadline releases worker" in
  `test_tui_resource_image_admission` waits up to 30 s, not 0.2 s, for its
  fake `open`, which exits 3 by itself. On a busy host that opener could still
  be starting at 0.2 s, get killed, and fail "first opener failure is
  observable". The hung renderer and the hung `xdg-open` still have to be
  killed at their 0.2 s deadline (#47621).
