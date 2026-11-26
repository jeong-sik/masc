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

let read confined ~(window : Keeper_tool_read_window.read_line_window) ~returned_lines =
  let lines =
    if returned_lines <= 0
    then None
    else (
      match
        Keeper_file_change_evidence.line_range
          ~start_line:window.start_line
          ~end_line:(window.start_line + returned_lines - 1)
      with
      | Ok range -> Some range
      (* [of_args] makes [start_line >= 1] and [returned_lines > 0] here, so
         the range is 1-based and ordered. *)
      | Error _ -> assert false)
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
