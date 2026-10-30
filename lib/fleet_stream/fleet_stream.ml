let schema_version = 1
let stream_path = "/api/v1/stream/fleet"

module Revision = struct
  type t = int

  let first = 1
  let next revision = revision + 1
  let is_next ~after revision = Int.equal revision (after + 1)
  let of_int n = if n >= 1 then Some n else None
  let to_int revision = revision
  let equal = Int.equal
end

module Names = struct
  type t = string list

  let empty = []
  let of_list names = List.sort_uniq String.compare names

  let rec strictly_increasing = function
    | [] | [ _ ] -> true
    | first :: (second :: _ as rest) ->
      String.compare first second < 0 && strictly_increasing rest
  ;;

  let of_canonical_list names =
    if strictly_increasing names then Some names else None
  ;;

  let to_list names = names
  let length = List.length
  let mem name names = List.exists (String.equal name) names
  let equal = List.equal String.equal
end

type fleet =
  { fs_status : Keeper_fleet_grade.t
  ; fs_blocker : Keeper_fleet_blocker.t option
  ; fs_operator_action_required : bool
  ; fs_bootable_count : int
  ; fs_running_count : int
  ; fs_executable_count : int
  ; fs_failing_count : int
  ; fs_recovering_count : int
  ; fs_turn_configuration_error_count : int
  ; fs_official_client_recovery_required_count : int
  ; fs_paused_count : int
  ; fs_target_reaction_capacity : int
  ; fs_reaction_capacity_shortfall : int
  ; fs_bootable_names : Names.t
  ; fs_running_names : Names.t
  ; fs_executable_names : Names.t
  ; fs_turn_configuration_error_names : Names.t
  ; fs_official_client_recovery_required_names : Names.t
  ; fs_active_task_owner_without_fiber_count : int
  ; fs_completion_authority_pending_count : int
  ; fs_active_task_owner_scan_error_count : int
  }

type degraded_reason =
  | Scan_timed_out
  | Scan_failed

type degradation =
  { since : float
  ; reason : degraded_reason
  }

type event =
  | Unavailable_snapshot of
      { revision : Revision.t
      ; degradation : degradation
      }
  | Snapshot of
      { revision : Revision.t
      ; measured_at : float
      ; fleet : fleet
      ; degraded : degradation option
      }
  | Changed of
      { revision : Revision.t
      ; measured_at : float
      ; fleet : fleet
      }
  | Degraded of
      { revision : Revision.t
      ; degradation : degradation
      }

let equal_fleet (left : fleet) (right : fleet) = left = right

let revision_of_event = function
  | Unavailable_snapshot { revision; _ } | Snapshot { revision; _ }
  | Changed { revision; _ } | Degraded { revision; _ } ->
    revision
;;

type decode_error =
  | Not_an_object of { at : string }
  | Missing_field of { at : string; field : string }
  | Unknown_field of { at : string; field : string }
  | Duplicate_field of { at : string; field : string }
  | Wrong_type of { at : string; field : string; expected : string }
  | Out_of_range of { at : string; field : string }
  | Unknown_word of { at : string; field : string; word : string }
  | Not_canonical of { at : string; field : string }
  | Unknown_event of string
  | Schema_mismatch of { expected : int; received : int }

let decode_error_to_string = function
  | Not_an_object { at } -> Printf.sprintf "%s is not an object" at
  | Missing_field { at; field } -> Printf.sprintf "%s has no field %s" at field
  | Unknown_field { at; field } ->
    Printf.sprintf "%s has a field this build does not know: %s" at field
  | Duplicate_field { at; field } ->
    Printf.sprintf "%s names the field %s twice" at field
  | Wrong_type { at; field; expected } ->
    Printf.sprintf "%s.%s is not %s" at field expected
  | Out_of_range { at; field } -> Printf.sprintf "%s.%s is out of range" at field
  | Unknown_word { at; field; word } ->
    Printf.sprintf "%s.%s names no variant this build knows: %s" at field word
  | Not_canonical { at; field } ->
    Printf.sprintf "%s.%s is not sorted without duplicates" at field
  | Unknown_event name -> Printf.sprintf "unknown event %s" name
  | Schema_mismatch { expected; received } ->
    Printf.sprintf "schema %d is not the schema %d this build reads" received expected
;;

(* The wire names. Encoding and decoding both read them from here. *)
module Key = struct
  let event = "event"
  let schema = "schema"
  let revision = "revision"
  let measured_at = "measured_at"
  let since = "since"
  let degraded = "degraded"
  let reason = "reason"
  let fleet = "fleet"
  let status = "status"
  let blocker = "blocker"
  let operator_action_required = "operator_action_required"
  let bootable_count = "bootable_count"
  let running_count = "running_count"
  let executable_count = "executable_count"
  let failing_count = "failing_count"
  let recovering_count = "recovering_count"
  let turn_configuration_error_count = "turn_configuration_error_count"

  let official_client_recovery_required_count =
    "official_client_recovery_required_count"
  ;;

  let paused_count = "paused_count"
  let target_reaction_capacity = "target_reaction_capacity"
  let reaction_capacity_shortfall = "reaction_capacity_shortfall"
  let bootable_names = "bootable_names"
  let running_names = "running_names"
  let executable_names = "executable_names"
  let turn_configuration_error_names = "turn_configuration_error_names"

  let official_client_recovery_required_names =
    "official_client_recovery_required_names"
  ;;

  let active_task_owner_without_fiber_count =
    "active_task_owner_without_fiber_count"
  ;;

  let completion_authority_pending_count = "completion_authority_pending_count"
  let active_task_owner_scan_error_count = "active_task_owner_scan_error_count"
end

module Event_name = struct
  let snapshot = "snapshot"
  let unavailable_snapshot = "unavailable_snapshot"
  let changed = "changed"
  let degraded = "degraded"
end

let degraded_reasons = [ Scan_timed_out; Scan_failed ]

let degraded_reason_to_word = function
  | Scan_timed_out -> "scan_timed_out"
  | Scan_failed -> "scan_failed"
;;

let degraded_reason_of_word word =
  List.find_opt
    (fun reason -> String.equal (degraded_reason_to_word reason) word)
    degraded_reasons
;;

let names_to_json names : Yojson.Safe.t =
  `List (List.map (fun name -> `String name) (Names.to_list names))
;;

let fleet_to_json (fleet : fleet) : Yojson.Safe.t =
  `Assoc
    [ Key.status, `String (Keeper_fleet_grade.wire_name fleet.fs_status)
    ; ( Key.blocker
      , (match fleet.fs_blocker with
         | None -> `Null
         | Some blocker -> `String (Keeper_fleet_blocker.wire_name blocker)) )
    ; Key.operator_action_required, `Bool fleet.fs_operator_action_required
    ; Key.bootable_count, `Int fleet.fs_bootable_count
    ; Key.running_count, `Int fleet.fs_running_count
    ; Key.executable_count, `Int fleet.fs_executable_count
    ; Key.failing_count, `Int fleet.fs_failing_count
    ; Key.recovering_count, `Int fleet.fs_recovering_count
    ; Key.turn_configuration_error_count, `Int fleet.fs_turn_configuration_error_count
    ; ( Key.official_client_recovery_required_count
      , `Int fleet.fs_official_client_recovery_required_count )
    ; Key.paused_count, `Int fleet.fs_paused_count
    ; Key.target_reaction_capacity, `Int fleet.fs_target_reaction_capacity
    ; Key.reaction_capacity_shortfall, `Int fleet.fs_reaction_capacity_shortfall
    ; Key.bootable_names, names_to_json fleet.fs_bootable_names
    ; Key.running_names, names_to_json fleet.fs_running_names
    ; Key.executable_names, names_to_json fleet.fs_executable_names
    ; ( Key.turn_configuration_error_names
      , names_to_json fleet.fs_turn_configuration_error_names )
    ; ( Key.official_client_recovery_required_names
      , names_to_json fleet.fs_official_client_recovery_required_names )
    ; ( Key.active_task_owner_without_fiber_count
      , `Int fleet.fs_active_task_owner_without_fiber_count )
    ; ( Key.completion_authority_pending_count
      , `Int fleet.fs_completion_authority_pending_count )
    ; ( Key.active_task_owner_scan_error_count
      , `Int fleet.fs_active_task_owner_scan_error_count )
    ]
;;

let degradation_fields { since; reason } : (string * Yojson.Safe.t) list =
  [ Key.since, `Float since; Key.reason, `String (degraded_reason_to_word reason) ]
;;

let encode : event -> Yojson.Safe.t = function
  | Unavailable_snapshot { revision; degradation } ->
    `Assoc
      ([ Key.event, `String Event_name.unavailable_snapshot
       ; Key.schema, `Int schema_version
       ; Key.revision, `Int (Revision.to_int revision)
       ] @ degradation_fields degradation)
  | Snapshot { revision; measured_at; fleet; degraded } ->
    `Assoc
      [ Key.event, `String Event_name.snapshot
      ; Key.schema, `Int schema_version
      ; Key.revision, `Int (Revision.to_int revision)
      ; Key.measured_at, `Float measured_at
      ; Key.fleet, fleet_to_json fleet
      ; ( Key.degraded
        , (match degraded with
           | None -> `Null
           | Some degradation -> `Assoc (degradation_fields degradation)) )
      ]
  | Changed { revision; measured_at; fleet } ->
    `Assoc
      [ Key.event, `String Event_name.changed
      ; Key.revision, `Int (Revision.to_int revision)
      ; Key.measured_at, `Float measured_at
      ; Key.fleet, fleet_to_json fleet
      ]
  | Degraded { revision; degradation } ->
    `Assoc
      ([ Key.event, `String Event_name.degraded
       ; Key.revision, `Int (Revision.to_int revision)
       ]
       @ degradation_fields degradation)
;;

open Result.Syntax

(* One JSON object read field by field. A field is removed from the table as it
   is read, so [finish] finds exactly the fields nobody asked for. The table
   never leaves one [decode] call. *)
module Fields = struct
  type t =
    { at : string
    ; remaining : (string, Yojson.Safe.t) Hashtbl.t
    }

  let of_json ~at (json : Yojson.Safe.t) =
    match json with
    | `Assoc pairs ->
      let remaining = Hashtbl.create 32 in
      let rec load = function
        | [] -> Ok { at; remaining }
        | (field, value) :: rest ->
          if Hashtbl.mem remaining field
          then Error (Duplicate_field { at; field })
          else (
            Hashtbl.add remaining field value;
            load rest)
      in
      load pairs
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error (Not_an_object { at })
  ;;

  let take t field =
    match Hashtbl.find_opt t.remaining field with
    | None -> Error (Missing_field { at = t.at; field })
    | Some value ->
      Hashtbl.remove t.remaining field;
      Ok value
  ;;

  let wrong_type t field expected = Error (Wrong_type { at = t.at; field; expected })

  let string t field =
    let* value = take t field in
    match value with
    | `String word -> Ok word
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
      wrong_type t field "a string"
  ;;

  let bool t field =
    let* value = take t field in
    match value with
    | `Bool flag -> Ok flag
    | `Null | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
      wrong_type t field "a boolean"
  ;;

  let int t field =
    let* value = take t field in
    match value with
    | `Int n -> Ok n
    | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
      wrong_type t field "an integer"
  ;;

  let count t field =
    let* n = int t field in
    if n >= 0 then Ok n else Error (Out_of_range { at = t.at; field })
  ;;

  let time t field =
    let* value = take t field in
    let in_range seconds =
      if Float.is_finite seconds && seconds >= 0.0
      then Ok seconds
      else Error (Out_of_range { at = t.at; field })
    in
    match value with
    | `Float seconds -> in_range seconds
    | `Int seconds -> in_range (Float.of_int seconds)
    | `Null | `Bool _ | `Intlit _ | `String _ | `Assoc _ | `List _ ->
      wrong_type t field "a number of seconds"
  ;;

  let revision t field =
    let* n = int t field in
    match Revision.of_int n with
    | Some revision -> Ok revision
    | None -> Error (Out_of_range { at = t.at; field })
  ;;

  let word t field of_word =
    let* word = string t field in
    match of_word word with
    | Some value -> Ok value
    | None -> Error (Unknown_word { at = t.at; field; word })
  ;;

  let nullable_word t field of_word =
    let* value = take t field in
    match value with
    | `Null -> Ok None
    | `String word ->
      (match of_word word with
       | Some value -> Ok (Some value)
       | None -> Error (Unknown_word { at = t.at; field; word }))
    | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
      wrong_type t field "a string or null"
  ;;

  let names t field =
    let* value = take t field in
    match value with
    | `List items ->
      let rec strings acc = function
        | [] -> Ok (List.rev acc)
        | `String name :: rest -> strings (name :: acc) rest
        | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) :: _ ->
          wrong_type t field "a list of strings"
      in
      let* listed = strings [] items in
      (match Names.of_canonical_list listed with
       | Some names -> Ok names
       | None -> Error (Not_canonical { at = t.at; field }))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
      wrong_type t field "a list of strings"
  ;;

  let object_field t field =
    let* value = take t field in
    of_json ~at:field value
  ;;

  let nullable_object_field t field =
    let* value = take t field in
    match value with
    | `Null -> Ok None
    | `Assoc _ as json ->
      let* fields = of_json ~at:field json in
      Ok (Some fields)
    | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      wrong_type t field "an object or null"
  ;;

  let finish t =
    let unread = Hashtbl.fold (fun field _ acc -> field :: acc) t.remaining [] in
    match List.sort String.compare unread with
    | [] -> Ok ()
    | field :: _ -> Error (Unknown_field { at = t.at; field })
  ;;
end

let fleet_of_fields fields : (fleet, decode_error) result =
  let* o = Fields.object_field fields Key.fleet in
  let* fs_status = Fields.word o Key.status Keeper_fleet_grade.of_wire_name in
  let* fs_blocker =
    Fields.nullable_word o Key.blocker Keeper_fleet_blocker.of_wire_name
  in
  let* fs_operator_action_required = Fields.bool o Key.operator_action_required in
  let* fs_bootable_count = Fields.count o Key.bootable_count in
  let* fs_running_count = Fields.count o Key.running_count in
  let* fs_executable_count = Fields.count o Key.executable_count in
  let* fs_failing_count = Fields.count o Key.failing_count in
  let* fs_recovering_count = Fields.count o Key.recovering_count in
  let* fs_turn_configuration_error_count =
    Fields.count o Key.turn_configuration_error_count
  in
  let* fs_official_client_recovery_required_count =
    Fields.count o Key.official_client_recovery_required_count
  in
  let* fs_paused_count = Fields.count o Key.paused_count in
  let* fs_target_reaction_capacity = Fields.count o Key.target_reaction_capacity in
  let* fs_reaction_capacity_shortfall =
    Fields.count o Key.reaction_capacity_shortfall
  in
  let* fs_bootable_names = Fields.names o Key.bootable_names in
  let* fs_running_names = Fields.names o Key.running_names in
  let* fs_executable_names = Fields.names o Key.executable_names in
  let* fs_turn_configuration_error_names =
    Fields.names o Key.turn_configuration_error_names
  in
  let* fs_official_client_recovery_required_names =
    Fields.names o Key.official_client_recovery_required_names
  in
  let* fs_active_task_owner_without_fiber_count =
    Fields.count o Key.active_task_owner_without_fiber_count
  in
  let* fs_completion_authority_pending_count =
    Fields.count o Key.completion_authority_pending_count
  in
  let* fs_active_task_owner_scan_error_count =
    Fields.count o Key.active_task_owner_scan_error_count
  in
  let* () = Fields.finish o in
  Ok
    { fs_status
    ; fs_blocker
    ; fs_operator_action_required
    ; fs_bootable_count
    ; fs_running_count
    ; fs_executable_count
    ; fs_failing_count
    ; fs_recovering_count
    ; fs_turn_configuration_error_count
    ; fs_official_client_recovery_required_count
    ; fs_paused_count
    ; fs_target_reaction_capacity
    ; fs_reaction_capacity_shortfall
    ; fs_bootable_names
    ; fs_running_names
    ; fs_executable_names
    ; fs_turn_configuration_error_names
    ; fs_official_client_recovery_required_names
    ; fs_active_task_owner_without_fiber_count
    ; fs_completion_authority_pending_count
    ; fs_active_task_owner_scan_error_count
    }
;;

let degradation_of_fields fields : (degradation, decode_error) result =
  let* since = Fields.time fields Key.since in
  let* reason = Fields.word fields Key.reason degraded_reason_of_word in
  Ok { since; reason }
;;

let decode json =
  let* fields = Fields.of_json ~at:Key.event json in
  let* name = Fields.string fields Key.event in
  if String.equal name Event_name.unavailable_snapshot
  then (
    let* received = Fields.int fields Key.schema in
    if not (Int.equal received schema_version)
    then Error (Schema_mismatch { expected = schema_version; received })
    else (
      let* revision = Fields.revision fields Key.revision in
      let* degradation = degradation_of_fields fields in
      let* () = Fields.finish fields in
      Ok (Unavailable_snapshot { revision; degradation })))
  else if String.equal name Event_name.snapshot
  then (
    let* received = Fields.int fields Key.schema in
    if not (Int.equal received schema_version)
    then Error (Schema_mismatch { expected = schema_version; received })
    else (
      let* revision = Fields.revision fields Key.revision in
      let* measured_at = Fields.time fields Key.measured_at in
      let* fleet = fleet_of_fields fields in
      let* degraded =
        let* nested = Fields.nullable_object_field fields Key.degraded in
        match nested with
        | None -> Ok None
        | Some nested ->
          let* degradation = degradation_of_fields nested in
          let* () = Fields.finish nested in
          Ok (Some degradation)
      in
      let* () = Fields.finish fields in
      Ok (Snapshot { revision; measured_at; fleet; degraded })))
  else if String.equal name Event_name.changed
  then (
    let* revision = Fields.revision fields Key.revision in
    let* measured_at = Fields.time fields Key.measured_at in
    let* fleet = fleet_of_fields fields in
    let* () = Fields.finish fields in
    Ok (Changed { revision; measured_at; fleet }))
  else if String.equal name Event_name.degraded
  then (
    let* revision = Fields.revision fields Key.revision in
    let* degradation = degradation_of_fields fields in
    let* () = Fields.finish fields in
    Ok (Degraded { revision; degradation }))
  else Error (Unknown_event name)
;;
