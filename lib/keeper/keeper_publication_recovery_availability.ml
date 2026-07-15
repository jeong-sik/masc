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

type public_category =
  | Public_registry_initializing
  | Public_registry_unavailable
  | Public_registry_initialization_crashed
  | Public_non_runtime
  | Public_lane_invalid_owner
  | Public_lane_reconciliation_blocked
  | Public_lane_store_failed

let constant availability () = availability
let non_runtime_provider = constant Non_runtime

let lane_public_category error =
  match Fs_compat.publication_recovery_lane_open_error_kind error with
  | Fs_compat.Publication_recovery_invalid_owner -> Public_lane_invalid_owner
  | Fs_compat.Publication_recovery_reconciliation_blocked ->
    Public_lane_reconciliation_blocked
  | Fs_compat.Publication_recovery_store_failed -> Public_lane_store_failed
;;

let public_category = function
  | Runtime_initializing -> Public_registry_initializing
  | Runtime_registry_unavailable _ -> Public_registry_unavailable
  | Runtime_initialization_crashed _ ->
    Public_registry_initialization_crashed
  | Runtime_non_runtime -> Public_non_runtime
  | Lane_unavailable error -> lane_public_category error
;;

let public_category_to_string = function
  | Public_registry_initializing -> "registry_initializing"
  | Public_registry_unavailable -> "registry_unavailable"
  | Public_registry_initialization_crashed ->
    "registry_initialization_crashed"
  | Public_non_runtime -> "non_runtime"
  | Public_lane_invalid_owner -> "lane_invalid_owner"
  | Public_lane_reconciliation_blocked -> "lane_reconciliation_blocked"
  | Public_lane_store_failed -> "lane_store_failed"
;;

let public_category_detail = function
  | Public_registry_initializing ->
    "publication recovery registry is still initializing"
  | Public_registry_unavailable ->
    "publication recovery registry is unavailable"
  | Public_registry_initialization_crashed ->
    "publication recovery registry initialization crashed"
  | Public_non_runtime ->
    "publication recovery is unavailable outside the runtime"
  | Public_lane_invalid_owner -> "publication recovery lane owner is invalid"
  | Public_lane_reconciliation_blocked ->
    "publication recovery lane is blocked by reconciliation"
  | Public_lane_store_failed ->
    "publication recovery lane store is unavailable"
;;

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
     | Error error ->
       let category = lane_public_category error in
       Log.Keeper.error
         ~keeper_name:publication_recovery.keeper_name
         "publication recovery lane acquisition failed category=%s evidence=%s"
         (public_category_to_string category)
         (Fs_compat.publication_recovery_lane_open_error_to_string error);
       Error (Lane_unavailable error))
;;

let unavailable_to_string unavailable =
  public_category unavailable |> public_category_detail
;;

let unavailable_to_yojson unavailable =
  let state =
    match unavailable with
    | Runtime_initializing -> "initializing"
    | Runtime_registry_unavailable _ -> "registry_unavailable"
    | Runtime_initialization_crashed _ -> "initialization_crashed"
    | Runtime_non_runtime -> "non_runtime"
    | Lane_unavailable _ -> "lane_unavailable"
  in
  let category = public_category unavailable in
  `Assoc
    [ "error", `String "publication_recovery_unavailable"
    ; "failure_class", `String "runtime_failure"
    ; "state", `String state
    ; "category", `String (public_category_to_string category)
    ; "detail", `String (public_category_detail category)
    ; "write_executed", `Bool false
    ; "keeper_active", `Bool true
    ]
;;
