let null = `Null
module Proof_store = Masc_mcp_cdal_runtime.Proof_store

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

let file_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false
;;

let stat_mtime path =
  try Some (Unix.stat path).Unix.st_mtime with
  | Unix.Unix_error _ | Sys_error _ -> None
;;

let max_float_opt a b =
  match a, b with
  | None, None -> None
  | Some value, None | None, Some value -> Some value
  | Some left, Some right -> Some (max left right)
;;

let max_child_mtime ?(limit = 32) dir =
  if not (is_dir dir)
  then None
  else (
    let entries =
      try Sys.readdir dir with
      | Sys_error _ -> [||]
    in
    let latest = ref None in
    let scan_len = min limit (Array.length entries) in
    for i = 0 to scan_len - 1 do
      latest := max_float_opt !latest (stat_mtime (Filename.concat dir entries.(i)))
    done;
    !latest)
;;

let proof_run_dir config ~run_id = Filename.concat (Proof_store.proofs_dir config) run_id
let proof_traces_dir config ~run_id = Filename.concat (proof_run_dir config ~run_id) "tool_traces"
let proof_evidence_dir config ~run_id = Filename.concat (proof_run_dir config ~run_id) "evidence"
let proof_contract_path config ~run_id = Filename.concat (proof_run_dir config ~run_id) "contract.json"

let run_latest_mtime config ~run_id =
  let run_dir = proof_run_dir config ~run_id in
  let traces_dir = proof_traces_dir config ~run_id in
  let evidence_dir = proof_evidence_dir config ~run_id in
  [ stat_mtime run_dir
  ; stat_mtime (Proof_store.manifest_path config ~run_id)
  ; stat_mtime (proof_contract_path config ~run_id)
  ; stat_mtime traces_dir
  ; max_child_mtime traces_dir
  ; stat_mtime evidence_dir
  ; max_child_mtime evidence_dir
  ]
  |> List.fold_left max_float_opt None
;;

let take n xs =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: rest -> loop (remaining - 1) (x :: acc) rest
  in
  loop n [] xs
;;

let proof_root_default () = Proof_store.default_config.root

let proof_root_candidates configured_root =
  let maybe_base_path =
    env_non_empty "MASC_BASE_PATH"
    |> Option.map (fun base_path -> Filename.concat base_path ".oas")
  in
  let maybe_me_root =
    env_non_empty "ME_ROOT" |> Option.map (fun root -> Filename.concat root ".oas")
  in
  [ maybe_base_path; maybe_me_root ]
  |> List.filter_map Fun.id
  |> List.filter (fun root -> not (String.equal root configured_root))
  |> List.sort_uniq String.compare
;;

let proof_completeness_json
      ~now
      ?(scan_limit = 200)
      ?(stale_incomplete_grace_seconds = 300.0)
      config
  =
  let proofs_dir = Proof_store.proofs_dir config in
  if not (is_dir proofs_dir)
  then
    `Assoc
      [ "scan_limit", `Int scan_limit
      ; "run_dirs_scanned", `Int 0
      ; "completed_run_dirs", `Int 0
      ; "incomplete_run_dirs", `Int 0
      ; "stale_incomplete_run_dirs", `Int 0
      ; "missing_manifest_run_dirs", `Int 0
      ; "missing_contract_run_dirs", `Int 0
      ; "stale_incomplete_grace_seconds", `Float stale_incomplete_grace_seconds
      ; "sample_stale_incomplete_run_ids", `List []
      ]
  else (
    let run_ids =
      try Sys.readdir proofs_dir |> Array.to_list with
      | Sys_error _ -> []
    in
    let run_infos =
      run_ids
      |> List.filter (fun run_id -> is_dir (proof_run_dir config ~run_id))
      |> List.filter_map (fun run_id ->
        match run_latest_mtime config ~run_id with
        | None -> None
        | Some mtime -> Some (run_id, mtime))
      |> List.sort (fun (_a_id, a_mtime) (_b_id, b_mtime) ->
        Float.compare b_mtime a_mtime)
      |> take scan_limit
    in
    let completed = ref 0 in
    let incomplete = ref 0 in
    let stale_incomplete = ref 0 in
    let missing_manifest = ref 0 in
    let missing_contract = ref 0 in
    let stale_samples = ref [] in
    List.iter
      (fun (run_id, mtime) ->
         let has_manifest = file_exists (Proof_store.manifest_path config ~run_id) in
         let has_contract = file_exists (proof_contract_path config ~run_id) in
         if has_manifest && has_contract
         then incr completed
         else (
           incr incomplete;
           if not has_manifest then incr missing_manifest;
           if not has_contract then incr missing_contract;
           let run_age_seconds = max 0.0 (now -. mtime) in
           if run_age_seconds > stale_incomplete_grace_seconds
           then (
             incr stale_incomplete;
             if List.length !stale_samples < 5 then stale_samples := run_id :: !stale_samples)))
      run_infos;
    `Assoc
      [ "scan_limit", `Int scan_limit
      ; "run_dirs_scanned", `Int (List.length run_infos)
      ; "completed_run_dirs", `Int !completed
      ; "incomplete_run_dirs", `Int !incomplete
      ; "stale_incomplete_run_dirs", `Int !stale_incomplete
      ; "missing_manifest_run_dirs", `Int !missing_manifest
      ; "missing_contract_run_dirs", `Int !missing_contract
      ; "stale_incomplete_grace_seconds", `Float stale_incomplete_grace_seconds
      ; ( "sample_stale_incomplete_run_ids"
        , `List (List.rev_map (fun run_id -> `String run_id) !stale_samples) )
      ])
;;

let json_int_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Int value) -> Some value
     | _ -> None)
  | _ -> None
;;

let has_stale_incomplete_runs completeness =
  match json_int_field "stale_incomplete_run_dirs" completeness with
  | Some count -> count > 0
  | None -> false
;;

let proof_store_root_json
      ~now
      ~stale_age_seconds
      ?proof_scan_limit
      ?stale_incomplete_run_seconds
      root
  =
  let config : Proof_store.config = { root } in
  let proofs_dir = Proof_store.proofs_dir config in
  let latest_mtime = stat_mtime_if_dir proofs_dir in
  let age_seconds = age_seconds ~now latest_mtime in
  let exists = is_dir proofs_dir in
  let completeness =
    proof_completeness_json
      ~now
      ?scan_limit:proof_scan_limit
      ?stale_incomplete_grace_seconds:stale_incomplete_run_seconds
      config
  in
  let status =
    if has_stale_incomplete_runs completeness
    then "stale_incomplete_runs"
    else status_of_latest ~stale_age_seconds ~exists ~age_seconds
  in
  `Assoc
    [ "root", `String root
    ; "proofs_dir", `String proofs_dir
    ; "exists", `Bool exists
    ; "latest_activity_at", time_opt_to_json latest_mtime
    ; "latest_activity_unix", float_opt_to_json latest_mtime
    ; "age_seconds", float_opt_to_json age_seconds
    ; "status", `String status
    ; "completeness", completeness
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
      else if task_id_rows < recent_rows
      then "partial_task_scope"
      else "present"
    in
    let missing_task_scope_rows = recent_rows - task_id_rows in
    `Assoc
      [ "status", `String status
      ; "recent_limit", `Int recent_limit
      ; "recent_rows", `Int recent_rows
      ; "task_id_rows", `Int task_id_rows
      ; "missing_task_scope_rows", `Int missing_task_scope_rows
      ; "missing_task_scope", `Bool (recent_rows > 0 && missing_task_scope_rows > 0)
      ; "partial_task_scope", `Bool (task_id_rows > 0 && missing_task_scope_rows > 0)
      ]
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Tool_args.error_assoc
      [ "recent_limit", `Int recent_limit
      ; "recent_rows", `Int 0
      ; "task_id_rows", `Int 0
      ; "missing_task_scope_rows", `Int 0
      ; "missing_task_scope", `Bool false
      ; "partial_task_scope", `Bool false
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

let writer_status ~ledger_status ~task_scope_status ~proof_store_status =
  match ledger_status, task_scope_status, proof_store_status with
  | "missing", _, _ -> "missing"
  | "dormant", _, _ -> "dormant"
  | _, _, "missing" -> "proof_store_missing"
  | _, _, "stale_incomplete_runs" -> "proof_store_incomplete"
  | _, "missing_task_scope", _ -> "missing_task_scope"
  | _, "partial_task_scope", _ -> "partial_task_scope"
  | "active", "present", ("active" | "dormant") -> "active"
  | _, "error", _ -> "error"
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
    ?recent_limit ?proof_scan_limit ?stale_incomplete_run_seconds () =
  let ledger = ledger_json ?base_dir ~now ~stale_age_seconds () in
  let task_scope = task_scope_json ?base_dir ?recent_limit () in
  let configured_root = Option.value proof_root ~default:(proof_root_default ()) in
  let configured_proof =
    proof_store_root_json
      ~now
      ~stale_age_seconds
      ?proof_scan_limit
      ?stale_incomplete_run_seconds
      configured_root
  in
  let alternate_proofs =
    `List
      (List.map
         (proof_store_root_json
            ~now
            ~stale_age_seconds
            ?proof_scan_limit
            ?stale_incomplete_run_seconds)
         (proof_root_candidates configured_root))
  in
  let ledger_status = Option.value ~default:"unknown" (json_string_field "status" ledger) in
  let task_scope_status =
    Option.value ~default:"unknown" (json_string_field "status" task_scope)
  in
  let proof_store_status =
    Option.value ~default:"unknown" (json_string_field "status" configured_proof)
  in
  let writer_status = writer_status ~ledger_status ~task_scope_status ~proof_store_status in
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
