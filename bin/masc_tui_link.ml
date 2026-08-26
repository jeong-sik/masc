type kind =
  | Board_post
  | Goal
  | Schedule
  | Task
  | Fusion_run
  | Keeper

let path = function
  | Board_post -> "board"
  | Goal -> "planning"
  | Schedule -> "schedules"
  | Task -> "overview/tasks"
  | Fusion_run -> "fusion"
  | Keeper -> "keepers"

let is_unreserved = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
  | _ -> false

let percent_encode_segment value =
  let buf = Buffer.create (String.length value) in
  String.iter
    (fun byte ->
       if is_unreserved byte then Buffer.add_char buf byte
       else Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code byte)))
    value;
  Buffer.contents buf

let reference kind id =
  Printf.sprintf "masc://%s/%s" (path kind) (percent_encode_segment id)

let osc52_copy text =
  "\027]52;c;" ^ Base64.encode_string text ^ "\007"
