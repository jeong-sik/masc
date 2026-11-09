type reading =
  | Running
  | Turn_capacity
  | Blocker
  | Proactive_interval

let select ~cells ~lead_cells ~separator_cells readings =
  let rec fit used acc = function
    | [] -> List.rev acc
    | (reading, reading_cells) :: rest ->
        let candidate = used + separator_cells + reading_cells in
        if candidate <= cells then fit candidate (reading :: acc) rest
        else List.rev acc
  in
  fit lead_cells [] readings
