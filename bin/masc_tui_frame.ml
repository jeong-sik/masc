let border_cells = 2
let padding_cells = 2
let chrome_rows = 5
let rule_width ~cols = max 0 (cols - border_cells)
let inner_width ~cols = max 0 (cols - border_cells - padding_cells)
let content_height ~rows = max 1 (rows - chrome_rows)
