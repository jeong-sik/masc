let null = `Null

let float_opt_to_json = function
  | None -> null
  | Some value -> `Float value
;;

let time_opt_to_json = function
  | None -> null
  | Some value -> `String (Masc_domain.iso8601_of_unix_seconds value)
;;

let env_non_empty key =
  match Sys.getenv_opt key with
  | Some value ->
    let value = String.trim value in
    if String.equal value "" then None else Some value
  | None -> None
;;

let is_dir path =
  try Sys.is_directory path with
  | Sys_error _ -> false
;;

let stat_mtime_if_dir path =
  if is_dir path then Some (Unix.stat path).Unix.st_mtime else None
;;

let status_of_latest ~stale_age_seconds ~exists ~age_seconds =
  if not exists
  then "missing"
  else
    match age_seconds with
    | None -> "missing"
    | Some age when age > stale_age_seconds -> "dormant"
    | Some _ -> "active"
;;

let age_seconds ~now = function
  | None -> None
  | Some ts -> Some (max 0.0 (now -. ts))
;;

let proof_root_default () = Masc_mcp_cdal_runtime.Proof_store.default_config.root

let proof_root_candidates configured_root =
  let maybe_home =
    env_non_empty "HOME" |> Option.map (fun home -> Filename.concat home ".oas")
  in
  [ maybe_home ]
  |> List.filter_map Fun.id
  |> List.filter (fun root -> not (String.equal root configured_root))
  |> List.sort_uniq String.compare
;;

let proof_store_root_json ~now ~stale_age_seconds root =
  let proofs_dir = Filename.concat root "proofs" in
  let latest_mtime = stat_mtime_if_dir proofs_dir in
  let age_seconds = age_seconds ~now latest_mtime in
  let exists = is_dir proofs_dir in
  let status = status_of_latest ~stale_age_seconds ~exists ~age_seconds in
  `Assoc
    [ "root", `String root
    ; "proofs_dir", `String proofs_dir
    ; "exists", `Bool exists
    ; "latest_activity_at", time_opt_to_json latest_mtime
    ; "latest_activity_unix", float_opt_to_json latest_mtime
    ; "age_seconds", float_opt_to_json age_seconds
    ; "status", `String status
    ]
;;

let assoc_string key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> Some value
     | _ -> None)
  | _ -> None
;;

let has_task_scope json = Option.is_some (assoc_string "_task_id" json)

let task_scope_json ?base_dir ?(recent_limit = Env_config_runtime.Cdal.verdict_lookup_limit ()) ()
  =
  let ledger = Cdal_verdict_gate.ledger_health_report ?base_dir () in
  let store = Dated_jsonl.create ~base_dir:ledger.base_dir () in
  try
    let recent = Dated_jsonl.read_recent store recent_limit in
    let recent_rows = List.length recent in
    let task_id_rows = List.fold_left (fun n row -> if has_task_scope row then n + 1 else n) 0 recent in
    let status =
      if recent_rows = 0
      then "missing_ledger"
      else if task_id_rows = 0
      then "missing_task_scope"
      else "present"
    in
    `Assoc
      [ "status", `String status
      ; "recent_limit", `Int recent_limit
      ; "recent_rows", `Int recent_rows
      ; "task_id_rows", `Int task_id_rows
      ; "missing_task_scope", `Bool (recent_rows > 0 && task_id_rows = 0)
      ]
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    `Assoc
      [ "status", `String "error"
      ; "recent_limit", `Int recent_limit
      ; "recent_rows", `Int 0
      ; "task_id_rows", `Int 0
      ; "missing_task_scope", `Bool false
      ; "error", `String (Printexc.to_string exn)
      ]
;;

let ledger_json ?base_dir ~now ~stale_age_seconds () =
  let report = Cdal_verdict_gate.ledger_health_report ?base_dir () in
  let exists = report.Cdal_verdict_gate.total_files > 0 in
  let status =
    status_of_latest ~stale_age_seconds ~exists ~age_seconds:report.age_seconds
  in
  `Assoc
    [ "base_dir", `String report.base_dir
    ; "total_files", `Int report.total_files
    ; "latest_mtime", float_opt_to_json report.latest_mtime
    ; "latest_at", time_opt_to_json report.latest_mtime
    ; "age_seconds", float_opt_to_json report.age_seconds
    ; "status", `String status
    ; "stale_age_seconds", `Float stale_age_seconds
    ; "checked_at", `String (Masc_domain.iso8601_of_unix_seconds now)
    ]
;;

let json_string_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> Some value
     | _ -> None)
  | _ -> None
;;

let writer_status ~ledger_status ~task_scope_status =
  match ledger_status, task_scope_status with
  | "missing", _ -> "missing"
  | "dormant", _ -> "dormant"
  | _, "missing_task_scope" -> "missing_task_scope"
  | "active", "present" -> "active"
  | _, "error" -> "error"
  | _ -> "unknown"
;;

let proof_path_drift configured_json alternate_json =
  let configured_status = json_string_field "status" configured_json in
  let configured_inactive =
    match configured_status with
    | Some ("missing" | "dormant") -> true
    | _ -> false
  in
  configured_inactive
  &&
  match alternate_json with
  | `List roots ->
    List.exists
      (fun json ->
         match json_string_field "status" json with
         | Some ("active" | "dormant") -> true
         | _ -> false)
      roots
  | _ -> false
;;

let snapshot_json ?base_dir ?proof_root ?(now = Time_compat.now ())
    ?(stale_age_seconds = Cdal_verdict_gate.stale_age_seconds_default)
    ?recent_limit () =
  let ledger = ledger_json ?base_dir ~now ~stale_age_seconds () in
  let task_scope = task_scope_json ?base_dir ?recent_limit () in
  let configured_root = Option.value proof_root ~default:(proof_root_default ()) in
  let configured_proof = proof_store_root_json ~now ~stale_age_seconds configured_root in
  let alternate_proofs =
    `List
      (List.map
         (proof_store_root_json ~now ~stale_age_seconds)
         (proof_root_candidates configured_root))
  in
  let ledger_status = Option.value ~default:"unknown" (json_string_field "status" ledger) in
  let task_scope_status =
    Option.value ~default:"unknown" (json_string_field "status" task_scope)
  in
  let writer_status = writer_status ~ledger_status ~task_scope_status in
  `Assoc
    [ "writer_status", `String writer_status
    ; "operator_action_required", `Bool (not (String.equal writer_status "active"))
    ; "verdict_ledger", ledger
    ; "task_scope", task_scope
    ; "proof_store", configured_proof
    ; "alternate_proof_stores", alternate_proofs
    ; "proof_store_path_drift", `Bool (proof_path_drift configured_proof alternate_proofs)
    ]
;;
