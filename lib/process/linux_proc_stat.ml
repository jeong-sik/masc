let parse line =
  match String.rindex_opt line ')' with
  | None -> None
  | Some close ->
    let after = String.sub line (close + 1) (String.length line - close - 1) in
    Some (List.filter (fun field -> field <> "") (String.split_on_char ' ' (String.trim after)))

let read pid =
  match In_channel.with_open_bin (Printf.sprintf "/proc/%d/stat" pid) In_channel.input_all with
  | exception Sys_error _ -> None
  | line -> parse line
