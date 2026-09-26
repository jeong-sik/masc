type 'mark t = No_screen | Stable of 'mark | Running of 'mark

let map f = function
  | No_screen -> No_screen
  | Stable mark -> Stable (f mark)
  | Running mark -> Running (f mark)
