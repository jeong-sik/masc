type t =
  | List_unread
  | List_loading
  | List_failed of string
  | List_empty of string option
  | Rows_ready of string option

let of_rows reason = function
  | [] -> List_empty reason
  | _ :: _ -> Rows_ready reason

let of_listing = function
  | Masc_tui_fetched.Absent -> List_unread
  | Loading -> List_loading
  | Failed reason -> List_failed reason
  | Ready rows -> of_rows None rows
  | Stale (rows, reason) -> of_rows (Some reason) rows

let of_inventory ~rows ~reason ~reading =
  match rows, reason with
  | Some rows, reason -> of_rows reason rows
  | None, Some reason -> List_failed reason
  | None, None -> if reading then List_loading else List_unread
