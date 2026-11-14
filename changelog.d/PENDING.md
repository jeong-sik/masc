### Fixed

- A dashboard list built on `VirtualList` keeps its rows when the item count
  moves between 40 and 41. The list used one DOM tree up to 40 items and
  another above it, so crossing the count rebuilt every row and dropped the
  keyboard focus inside it. Both counts now share one tree, the list follows
  the scroll position at every count, and it stores measured row heights
  unrounded, so a row on screen stays where it was (#PENDING).
- The Tools inventory draws only the tools near the scroll position. Its
  `VirtualList` read the scroll position from its own root, which does not
  scroll there, and drew every tool. The caller now names the element that
  scrolls (`scrollBox`), and the list reads the position from it (#PENDING).
- The claimable backlog on the Work screen scrolls to its last row above 40
  tasks. The windowed list sat in a flex column that shrank the reserved
  height to the visible box, so a jump to the end stopped short. Row spacing
  is the same 4px at every count; above 40 the rows had none (#PENDING).
