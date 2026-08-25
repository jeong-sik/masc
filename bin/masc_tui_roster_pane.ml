let threshold_cols = 110
let pane_cols = 30

let shown ~hidden ~cols = (not hidden) && cols >= threshold_cols

let content_cols ~hidden ~cols =
  if shown ~hidden ~cols then cols - pane_cols else cols
