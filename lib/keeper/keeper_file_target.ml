type t =
  { relative_path : string
  ; lines : Keeper_file_change_evidence.line_range option
  }

let relative_path_of confined = Keeper_alerting_path.confined_relative_path confined

let changed confined (evidence : Keeper_file_change_evidence.t option) =
  let lines =
    match evidence with
    | Some (Keeper_file_change_evidence.Written { new_range }) -> new_range
    | Some (Keeper_file_change_evidence.Edited { occurrences = Some (first :: _); _ }) ->
      first.Keeper_file_change_evidence.new_range
    | Some (Keeper_file_change_evidence.Edited { occurrences = (Some [] | None); _ })
    | None -> None
  in
  { relative_path = relative_path_of confined; lines }
;;

let read confined ~start_line ~returned_lines =
  if returned_lines < 0 then invalid_arg "read file target needs a non-negative line count";
  let lines =
    match returned_lines with
    | 0 ->
      if start_line < 1 then invalid_arg "read file target start must be 1-based";
      None
    | count ->
      (match
         Keeper_file_change_evidence.line_range
           ~start_line
           ~end_line:(start_line + count - 1)
       with
       | Ok range -> Some range
       | Error detail -> invalid_arg ("read file target: " ^ detail))
  in
  { relative_path = relative_path_of confined; lines }
;;

let to_yojson target =
  `Assoc
    ([ "path", `String target.relative_path ]
     @ (match target.lines with
        | Some range -> [ "lines", Keeper_file_change_evidence.line_range_to_yojson range ]
        | None -> []))
;;
