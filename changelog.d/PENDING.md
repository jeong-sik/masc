### Fixed

- Hiding the post list with `z` on an open Board post draws its comments
  under the post, as wide as the terminal. From 120 columns the wider pane
  used to put them beside the post with 40 cells plus half the excess, so on
  a 140-column terminal `z` narrowed the comments from the split's 106 cells
  to 52. With the post list shown, the comments still sit beside the post
  once its pane holds both columns (#40134, #PENDING).
