type autonomous_activation =
  { ok : bool
  ; autoboot_enabled : bool
  ; proactive_enabled : bool
  ; paused : bool
  ; blocker : string option
  ; hint : string option
  }

type work_discovery_activation =
  { ok : bool
  ; work_discovery_enabled : bool option
  ; current_task_id : string option
  ; blocker : string option
  ; hint : string option
  }

type t =
  { ok : bool
  ; ready_for_unclaimed_backlog : bool
  ; autonomous_activation : autonomous_activation
  ; work_discovery_activation : work_discovery_activation
  }

let current_task_id_opt (meta : Keeper_types.keeper_meta) =
  Option.map Keeper_id.Task_id.to_string meta.current_task_id
;;

let autonomous_blocker (meta : Keeper_types.keeper_meta) =
  if meta.paused then Some "paused"
  else if not meta.autoboot_enabled then Some "autoboot_disabled"
  else if not meta.proactive.enabled then Some "proactive_disabled"
  else None
;;

let autonomous_hint = function
  | None -> None
  | Some "paused" ->
    Some "resume keeper before expecting autonomous keepalive or PR fan-out"
  | Some "autoboot_disabled" ->
    Some "set autoboot_enabled=true before expecting autonomous keepalive or PR fan-out"
  | Some "proactive_disabled" ->
    Some "set proactive_enabled=true before expecting scheduled autonomous work"
  | Some reason -> Some ("activation blocked: " ^ reason)
;;

let autonomous_activation (meta : Keeper_types.keeper_meta) =
  let blocker = autonomous_blocker meta in
  { ok = Option.is_none blocker
  ; autoboot_enabled = meta.autoboot_enabled
  ; proactive_enabled = meta.proactive.enabled
  ; paused = meta.paused
  ; blocker
  ; hint = autonomous_hint blocker
  }
;;

let work_discovery_blocker (meta : Keeper_types.keeper_meta) =
  match meta.work_discovery_enabled, meta.current_task_id with
  | Some false, None -> Some "work_discovery_disabled"
  | _ -> None
;;

let work_discovery_hint = function
  | None -> None
  | Some "work_discovery_disabled" ->
    Some
      "set work_discovery_enabled=true or assign current_task_id before expecting \
       backlog claim/PR upload fan-out"
  | Some reason -> Some ("work discovery blocked: " ^ reason)
;;

let work_discovery_activation (meta : Keeper_types.keeper_meta) =
  let blocker = work_discovery_blocker meta in
  { ok = Option.is_none blocker
  ; work_discovery_enabled = meta.work_discovery_enabled
  ; current_task_id = current_task_id_opt meta
  ; blocker
  ; hint = work_discovery_hint blocker
  }
;;

let of_meta meta =
  let autonomous_activation = autonomous_activation meta in
  let work_discovery_activation = work_discovery_activation meta in
  let ok = autonomous_activation.ok && work_discovery_activation.ok in
  { ok
  ; ready_for_unclaimed_backlog = ok
  ; autonomous_activation
  ; work_discovery_activation
  }
;;

let ready_for_unclaimed_backlog meta = (of_meta meta).ready_for_unclaimed_backlog

let autonomous_check_value (activation : autonomous_activation) =
  match activation.blocker with
  | None -> "ok"
  | Some blocker -> blocker
;;

let work_discovery_check_value (activation : work_discovery_activation) =
  match activation.blocker with
  | None -> "ok"
  | Some blocker -> blocker
;;

let autonomous_activation_to_yojson (activation : autonomous_activation) =
  `Assoc
    [ "ok", `Bool activation.ok
    ; "autoboot_enabled", `Bool activation.autoboot_enabled
    ; "proactive_enabled", `Bool activation.proactive_enabled
    ; "paused", `Bool activation.paused
    ; "blocker", Json_util.string_opt_to_json activation.blocker
    ; "hint", Json_util.string_opt_to_json activation.hint
    ]
;;

let work_discovery_activation_to_yojson (activation : work_discovery_activation) =
  `Assoc
    [ "ok", `Bool activation.ok
    ; "work_discovery_enabled",
      Json_util.bool_opt_to_json activation.work_discovery_enabled
    ; "current_task_id", Json_util.string_opt_to_json activation.current_task_id
    ; "blocker", Json_util.string_opt_to_json activation.blocker
    ; "hint", Json_util.string_opt_to_json activation.hint
    ]
;;

let to_yojson readiness =
  `Assoc
    [ "ok", `Bool readiness.ok
    ; "ready_for_unclaimed_backlog", `Bool readiness.ready_for_unclaimed_backlog
    ; ( "autonomous_activation"
      , autonomous_activation_to_yojson readiness.autonomous_activation )
    ; ( "work_discovery_activation"
      , work_discovery_activation_to_yojson readiness.work_discovery_activation )
    ]
;;
