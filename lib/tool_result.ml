(** Structured tool result type for MASC *)

type t = {
  success : bool;
  data : Yojson.Safe.t;
  tool_name : string;
  duration_ms : float;
}

let wrap ~tool_name ~start_time (success, message) =
  let end_time = Time_compat.now () in
  let duration_ms = (end_time -. start_time) *. 1000.0 in
  let data =
    match Yojson.Safe.from_string message with
    | json -> json
    | exception Yojson.Json_error _ -> `String message
  in
  { success; data; tool_name; duration_ms }

let to_json t =
  `Assoc
    [ ("success", `Bool t.success)
    ; ("data", t.data)
    ; ("tool_name", `String t.tool_name)
    ; ("duration_ms", `Float t.duration_ms)
    ]

let to_legacy t =
  let message =
    match t.data with
    | `String s -> s
    | json -> Yojson.Safe.to_string json
  in
  (t.success, message)
