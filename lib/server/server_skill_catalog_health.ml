(* The [skill_catalog] section of [/health?full=1]. See the .mli. *)

let schema = "masc.skill_catalog.v1"

(* Saving through either editor commits runtime.toml, and the commit
   republishes the Skill snapshot (Server_skill_snapshot_runtime.apply_commit),
   so no restart is needed. *)
let reload_hint =
  "saving runtime.toml with the TUI or dashboard runtime.toml editor reloads \
   the Skill catalog"
;;

let section ~status ~config_state ~status_reasons ~operator_action_reasons =
  let strings values = `List (List.map (fun value -> `String value) values) in
  `Assoc
    [ "schema", `String schema
    ; "status", `String (Health_status.to_string status)
    ; "config_state", `String config_state
    ; "operator_action_required", `Bool (operator_action_reasons <> [])
    ; "status_reasons", strings status_reasons
    ; "operator_action_reasons", strings operator_action_reasons
    ]
;;

(* Every line here needs an answer, so it is both why the grade moved and what
   the operator is asked to do. *)
let needs_operator ~status ~config_state reasons =
  section ~status ~config_state ~status_reasons:reasons ~operator_action_reasons:reasons
;;

(* The same diagnostic text and file the boot WARN and the save-path 400 print
   (Skill_source_config.rejection_message), one line per diagnostic. The path
   is absent only while no runtime.toml exists, and then nothing has been
   rejected from one; the diagnostic still stands on its own. *)
let rejected_reason ~runtime_config_path diagnostic =
  let what =
    match runtime_config_path with
    | Some config_path -> Skill_source_config.rejection_message ~config_path [ diagnostic ]
    | None -> Skill_source_config.diagnostic_to_string diagnostic
  in
  Printf.sprintf "%s. Keepers see no Skills until it is fixed; %s." what reload_hint
;;

let of_snapshot ~runtime_config_path snapshot =
  match Skill_catalog_snapshot.config_state snapshot with
  | Configured _ ->
    section
      ~status:Health_status.Ok
      ~config_state:"configured"
      ~status_reasons:[]
      ~operator_action_reasons:[]
  | Config_rejected { diagnostics; _ } ->
    diagnostics
    |> List.map (rejected_reason ~runtime_config_path)
    |> needs_operator ~status:Health_status.Degraded ~config_state:"rejected"
  | Config_unreadable { detail } ->
    needs_operator
      ~status:Health_status.Degraded
      ~config_state:"unreadable"
      [ Printf.sprintf
          "Skill configuration unreadable, so Keepers see no Skills: %s. Check \
           runtime.toml; %s."
          detail
          reload_hint
      ]
;;

let not_published ~config_state =
  section
    ~status:Health_status.Snapshot_not_ready
    ~config_state
    ~status_reasons:
      [ "no Skill catalog is published yet; boot publishes one once runtime.toml \
         can be read"
      ]
    ~operator_action_reasons:[]
;;

let to_yojson ~runtime_config_path = function
  | Ok (Server_skill_snapshot_runtime.Ready snapshot) ->
    of_snapshot ~runtime_config_path snapshot
  | Ok Uninitialized -> not_published ~config_state:"uninitialized"
  | Ok Not_registered -> not_published ~config_state:"not_registered"
  | Error error ->
    needs_operator
      ~status:Health_status.Unavailable
      ~config_state:"invalid_workspace"
      [ Printf.sprintf
          "Skill catalog workspace is invalid, so Keepers see no Skills: %s"
          (Server_skill_snapshot_runtime.error_to_string error)
      ]
;;
