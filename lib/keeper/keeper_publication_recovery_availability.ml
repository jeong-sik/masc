type availability =
  | Initializing
  | Available of Fs_compat.publication_recovery_registry
  | Registry_unavailable of Fs_compat.publication_recovery_registry_error
  | Initialization_crashed of Eio.Exn.with_bt
  | Non_runtime

type provider = unit -> availability

type unavailable =
  | Runtime_initializing
  | Runtime_registry_unavailable of Fs_compat.publication_recovery_registry_error
  | Runtime_initialization_crashed of Eio.Exn.with_bt
  | Runtime_non_runtime
  | Lane_unavailable of Fs_compat.publication_recovery_lane_open_error

type turn_context =
  { provider : provider
  ; keeper_name : string
  }

let constant availability () = availability
let non_runtime_provider = constant Non_runtime

let with_access publication_recovery use =
  match publication_recovery.provider () with
  | Initializing -> Error Runtime_initializing
  | Registry_unavailable error ->
    Error (Runtime_registry_unavailable error)
  | Initialization_crashed error ->
    Error (Runtime_initialization_crashed error)
  | Non_runtime -> Error Runtime_non_runtime
  | Available registry ->
    (match
       Fs_compat.with_publication_recovery_lane
         ~registry
         ~owner:publication_recovery.keeper_name
         use
     with
     | Ok result -> Ok result
     | Error error -> Error (Lane_unavailable error))
;;

let unavailable_to_string = function
  | Runtime_initializing ->
    "publication recovery registry is still initializing"
  | Runtime_registry_unavailable error ->
    Fs_compat.publication_recovery_registry_error_to_string error
  | Runtime_initialization_crashed _ ->
    "publication recovery registry initialization crashed"
  | Runtime_non_runtime ->
    "publication recovery is unavailable outside the runtime"
  | Lane_unavailable error ->
    Fs_compat.publication_recovery_lane_open_error_to_string error
;;

let unavailable_to_yojson unavailable =
  let state, detail =
    match unavailable with
    | Runtime_initializing ->
      "initializing", unavailable_to_string unavailable
    | Runtime_registry_unavailable _ ->
      "registry_unavailable", unavailable_to_string unavailable
    | Runtime_initialization_crashed _ ->
      "initialization_crashed", unavailable_to_string unavailable
    | Runtime_non_runtime ->
      "non_runtime", unavailable_to_string unavailable
    | Lane_unavailable _ ->
      "lane_unavailable", unavailable_to_string unavailable
  in
  `Assoc
    [ "error", `String "publication_recovery_unavailable"
    ; "failure_class", `String "runtime_failure"
    ; "state", `String state
    ; "detail", `String detail
    ; "write_executed", `Bool false
    ; "keeper_active", `Bool true
    ]
;;
