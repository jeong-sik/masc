module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Structured tool result type for MASC *)

type t = {
  success : bool;
  data : Yojson.Safe.t;
  legacy_message : string;
  tool_name : string;
  duration_ms : float;
}

let structured_payload_of_message (message : string) : Yojson.Safe.t option =
  let parse_json raw =
    try Some (Yojson.Safe.from_string raw)
    with Yojson.Json_error _ -> None
  in
  let trimmed = String.trim message in
  let ensure_object = function
    | `Assoc _ as obj -> Some obj
    | `List _ as arr -> Some (`Assoc [ ("items", arr) ])
    | _ -> None
  in
  match parse_json trimmed with
  | Some json -> ensure_object json
  | None ->
      let len = String.length message in
      let rec loop from =
        match String.index_from_opt message from '\n' with
        | None -> None
        | Some newline_idx ->
            let suffix =
              String.sub message (newline_idx + 1) (len - newline_idx - 1)
              |> String.trim
            in
            if String.equal suffix "" then loop (newline_idx + 1)
            else
              match suffix.[0] with
              | '{' | '[' -> (
                  match parse_json suffix with
                  | Some json -> ensure_object json
                  | None -> loop (newline_idx + 1))
              | _ -> loop (newline_idx + 1)
      in
      loop 0

let wrap ~tool_name ~start_time (success, message) =
  let end_time = Time_compat.now () in
  let duration_ms = (end_time -. start_time) *. 1000.0 in
  let data =
    match structured_payload_of_message message with
    | Some json -> json
    | None -> `String message
  in
  { success; data; legacy_message = message; tool_name; duration_ms }

let to_json t =
  `Assoc
    [ ("success", `Bool t.success)
    ; ("data", t.data)
    ; ("tool_name", `String t.tool_name)
    ; ("duration_ms", `Float t.duration_ms)
    ]

let message t = t.legacy_message

let to_legacy_compat t = (t.success, message t)
