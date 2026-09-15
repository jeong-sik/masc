type owner = { pid : int; driver : string }
type leftover = Stop_recorded_driver of int | Not_the_recorded_driver

let owner_record_path ~masc_root =
  Filename.concat (Filename.concat masc_root "browser-lane") "geckodriver-owner.json"

let owner_to_string { pid; driver } =
  Yojson.Safe.to_string (`Assoc [ "pid", `Int pid; "driver", `String driver ])

let owner_of_string text =
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error detail -> Error detail
  | `Assoc fields ->
    (match List.assoc_opt "pid" fields, List.assoc_opt "driver" fields with
     | Some (`Int pid), Some (`String driver)
       when pid > 0 && not (Filename.is_relative driver) -> Ok { pid; driver }
     | (Some _ | None), (Some _ | None) ->
       Error "driver record needs a positive pid and an absolute driver path")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "driver record is not an object"

let argv ~driver ~port =
  [ driver
  ; "--host"
  ; Masc_network_defaults.masc_http_default_host
  ; "--port"
  ; string_of_int port
  ; "--websocket-port"
  ; "0"
  ]

let leftover owner ~command =
  match command with
  | Some command
    when String.equal command owner.driver
         || String.starts_with ~prefix:(owner.driver ^ " ") command ->
    Stop_recorded_driver owner.pid
  | Some _ | None -> Not_the_recorded_driver
