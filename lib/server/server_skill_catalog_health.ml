(* The [skill_catalog] section of [/health?full=1]. See the .mli. *)

let schema = "masc.skill_catalog.v1"

(* Saving through either editor commits runtime.toml, and the commit
   republishes the Skill snapshot (Server_skill_snapshot_runtime.apply_commit),
   so no restart is needed. *)
let reload_hint =
  "saving runtime.toml with the TUI or dashboard runtime.toml editor reloads \
   the Skill catalog"
;;

let strings values = `List (List.map (fun value -> `String value) values)

let section ?(measured = []) ~status ~config_state ~status_reasons ~operator_action_reasons () =
  `Assoc
    ([ "schema", `String schema
     ; "status", `String (Health_status.to_string status)
     ; "config_state", `String config_state
     ; "operator_action_required", `Bool (operator_action_reasons <> [])
     ; "status_reasons", strings status_reasons
     ; "operator_action_reasons", strings operator_action_reasons
     ]
     @ measured)
;;

(* Every line here needs an answer, so it is both why the grade moved and what
   the operator is asked to do. *)
let needs_operator ?measured ~status ~config_state reasons =
  section
    ?measured
    ~status
    ~config_state
    ~status_reasons:reasons
    ~operator_action_reasons:reasons
    ()
;;

type source_counts =
  { ready : int
  ; missing : int
  ; not_directory : int
  ; unavailable : int
  ; unresolved : int
  }

let source_counts snapshot =
  List.fold_left
    (fun counts (scan : Skill_catalog_snapshot.source_scan) ->
       match scan.observation with
       | Source_ready _ -> { counts with ready = counts.ready + 1 }
       | Source_missing _ -> { counts with missing = counts.missing + 1 }
       | Source_not_directory _ -> { counts with not_directory = counts.not_directory + 1 }
       | Source_unavailable _ -> { counts with unavailable = counts.unavailable + 1 }
       | Source_unresolved _ -> { counts with unresolved = counts.unresolved + 1 })
    { ready = 0; missing = 0; not_directory = 0; unavailable = 0; unresolved = 0 }
    (Skill_catalog_snapshot.sources snapshot)
;;

(* What the published snapshot holds, whatever the grade. A rejected or
   unreadable configuration holds nothing, and the zeros say so. *)
let measured ~config_path snapshot =
  let sources = source_counts snapshot in
  [ "config_path", `String config_path
  ; "skills", `Int (List.length (Skill_catalog_snapshot.entries snapshot))
  ; "rejections", `Int (List.length (Skill_catalog_snapshot.rejections snapshot))
  ; ( "sources"
    , `Assoc
        [ "ready", `Int sources.ready
        ; "missing", `Int sources.missing
        ; "not_directory", `Int sources.not_directory
        ; "unavailable", `Int sources.unavailable
        ; "unresolved", `Int sources.unresolved
        ] )
  ]
;;

(* The same diagnostic text and file the boot WARN and the save-path 400 print
   (Skill_source_config.rejection_message), one line per diagnostic, read from
   the path the snapshot was built from. *)
let rejected_reason ~config_path diagnostic =
  Printf.sprintf
    "%s. Keepers see no Skills until it is fixed; %s."
    (Skill_source_config.rejection_message ~config_path [ diagnostic ])
    reload_hint
;;

let of_published ~config_path snapshot =
  let measured = measured ~config_path snapshot in
  match Skill_catalog_snapshot.config_state snapshot with
  | Configured _ ->
    section
      ~measured
      ~status:Health_status.Ok
      ~config_state:"configured"
      ~status_reasons:[]
      ~operator_action_reasons:[]
      ()
  | Config_rejected { diagnostics; _ } ->
    diagnostics
    |> List.map (rejected_reason ~config_path)
    |> needs_operator ~measured ~status:Health_status.Degraded ~config_state:"rejected"
  | Config_unreadable { detail } ->
    needs_operator
      ~measured
      ~status:Health_status.Degraded
      ~config_state:"unreadable"
      [ Printf.sprintf
          "Skill configuration unreadable, so Keepers see no Skills: %s (file: %s). \
           Check runtime.toml; %s."
          detail
          config_path
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
    ()
;;

let to_yojson = function
  | Ok (Server_skill_snapshot_runtime.Ready { snapshot; config_path }) ->
    of_published ~config_path snapshot
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

let placeholder ?error ~component_timed_out ~status () =
  let error_fields =
    match error with
    | Some error -> [ "error", `String error ]
    | None -> []
  in
  `Assoc
    ([ "schema", `String schema
     ; "status", `String status
     ; "config_state", `String "not_measured"
     ; "operator_action_required", `Bool false
     ; "status_reasons", `List []
     ; "operator_action_reasons", `List []
     ; "component_timed_out", `Bool component_timed_out
     ]
     @ error_fields)
;;
