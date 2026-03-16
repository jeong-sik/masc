let iso_of_unix unix_ts =
  let tm = Unix.gmtime unix_ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let parse_iso_opt = function
  | Some raw when String.trim raw <> "" -> (
      try Some (Types.parse_iso8601 raw) with Failure _ -> None)
  | _ -> None

let trim_to_option text =
  let trimmed = String.trim text in
  if trimmed = "" then None else Some trimmed

let dedup_strings (xs : string list) : string list =
  let seen = Hashtbl.create (List.length xs) in
  List.filter
    (fun x ->
      if Hashtbl.mem seen x then false
      else (
        Hashtbl.add seen x ();
        true))
    xs

let string_list_of_json json =
  match json with
  | `List items ->
      items
      |> List.filter_map (function
             | `String value -> trim_to_option value
             | _ -> None)
  | _ -> []
