(** MASC Agent Transport — protocol selection for MASC workspace. *)

type t =
  | Http
  | Grpc
  | Ws
  | Local

let env_name = "MASC_AGENT_TRANSPORT"
let default = Local
let description = "Agent transport (http|grpc|ws|local)"

let accepted_values =
  [ "http", Http; "grpc", Grpc; "ws", Ws; "local", Local ]

let of_env_value raw =
  match List.assoc_opt raw accepted_values with
  | Some transport -> transport
  | None ->
    raise
      (Env_config_core.Config_error
         (Printf.sprintf
            "malformed env %s=%S (expected %s)"
            env_name
            raw
            (accepted_values |> List.map fst |> String.concat "|")))
;;

type resolution =
  { value : t
  ; source : Env_config_snapshot_core.effective_source
  }

let resolve_env () =
  match Sys.getenv_opt env_name with
  | None ->
    { value = default; source = Env_config_snapshot_core.Default }
  | Some raw ->
    { value = of_env_value raw; source = Env_config_snapshot_core.Environment }
;;

let configured = Atomic.make None

let rec configure_from_env () =
  match Atomic.get configured with
  | Some resolution -> resolution.value
  | None ->
    let resolution = resolve_env () in
    if Atomic.compare_and_set configured None (Some resolution)
    then resolution.value
    else configure_from_env ()
;;

let effective_resolution () =
  match Atomic.get configured with
  | Some resolution -> resolution
  | None -> resolve_env ()
;;

let from_env () = (effective_resolution ()).value

let to_string = function
  | Http -> "http"
  | Grpc -> "grpc"
  | Ws -> "ws"
  | Local -> "local"
;;

let snapshot_entry =
  Env_config_snapshot_collector.effective_entry
    ~default:(to_string default)
    ~read:(fun () ->
      let resolution = effective_resolution () in
      to_string resolution.value, resolution.source)
    env_name
    description
;;
