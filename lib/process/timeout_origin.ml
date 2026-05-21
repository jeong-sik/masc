type t =
  | Slot_wait
  | Spawn
  | Command
  | Llm_response
  | Dashboard_refresh
  | Health_probe
  | Other of string

let standard =
  [ Slot_wait; Spawn; Command; Llm_response; Dashboard_refresh; Health_probe ]
;;

let process_origins = [ Slot_wait; Spawn; Command ]

let is_process_origin = function
  | Slot_wait | Spawn | Command -> true
  | Llm_response | Dashboard_refresh | Health_probe | Other _ -> false
;;

let sanitize_other_label raw =
  let raw = String.lowercase_ascii (String.trim raw) in
  let max_len = 64 in
  let len = min (String.length raw) max_len in
  let buf = Buffer.create len in
  for i = 0 to len - 1 do
    match raw.[i] with
    | 'a' .. 'z'
    | '0' .. '9'
    | '_' -> Buffer.add_char buf raw.[i]
    | '-' | ' ' | ':' | '/' | '.' -> Buffer.add_char buf '_'
    | _ -> ()
  done;
  match Buffer.contents buf with
  | "" -> "other"
  | label -> "other_" ^ label
;;

let to_label = function
  | Slot_wait -> "slot_wait"
  | Spawn -> "spawn"
  | Command -> "command"
  | Llm_response -> "llm_response"
  | Dashboard_refresh -> "dashboard_refresh"
  | Health_probe -> "health_probe"
  | Other label -> sanitize_other_label label
;;
