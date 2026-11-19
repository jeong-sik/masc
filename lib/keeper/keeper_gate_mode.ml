type t =
  | Manual
  | Auto_judge
  | Always_allow

type change =
  { previous : t option
  ; current : t
  ; actor : string
  ; changed_at : string
  ; replaced_read_error : string option
  }

let default = Auto_judge

let to_string = function
  | Manual -> "manual"
  | Auto_judge -> "auto_judge"
  | Always_allow -> "always_allow"
;;

let of_string raw =
  match String.trim raw |> String.lowercase_ascii with
  | "manual" -> Some Manual
  | "auto_judge" -> Some Auto_judge
  | "always_allow" -> Some Always_allow
  | _ -> None
;;

let parse_json = function
  | `String raw ->
    (match of_string raw with
     | Some mode -> Ok mode
     | None -> Error "mode must be one of: manual, auto_judge, always_allow")
  | _ -> Error "mode must be a string"
;;

let path = Keeper_gate_path.mode
let external_path = Keeper_gate_path.external_mode

(* The external-services lane answers one question the workspace lane cannot:
   what happens to a call that leaves for an attached outside service when
   the workspace lane is opened for internal velocity. Measured on
   2026-08-27, 374 of 379 Gate decisions rode workspace Always_allow; a lane
   that inherited that switch would have let the incident's Jira writes
   through with only an audit row. Manual is the default for the same reason
   the approval policy treats silence as "might write". *)
let default_external = Manual

let state_json ~actor ~changed_at mode =
  `Assoc
    [ "mode", `String (to_string mode)
    ; "updated_by", `String actor
    ; "updated_at", `String changed_at
    ]
;;

let mode_of_state_json = function
  | `Assoc fields ->
    (match List.assoc_opt "mode" fields with
     | Some mode -> parse_json mode
     | None -> Error "keeper Gate mode state is missing mode")
  | _ -> Error "keeper Gate mode state must be an object"
;;

let read_lane ~file ~absent =
  if not (Sys.file_exists file)
  then Ok absent
  else
    match Safe_ops.read_json_file_safe file with
    | Ok json -> mode_of_state_json json
    | Error detail -> Error (Printf.sprintf "keeper Gate mode read failed: %s" detail)
;;

let read ~base_path = read_lane ~file:(path ~base_path) ~absent:default

let read_external ~base_path =
  read_lane ~file:(external_path ~base_path) ~absent:default_external
;;

let status_json_lane ~file read_result =
  match read_result with
  | Ok Auto_judge ->
    (match Hitl_summary_worker.snapshot_topology_readiness () with
     | Ok () ->
       `Assoc
         [ "mode", `String (to_string Auto_judge)
         ; "configured", `Bool (Sys.file_exists file)
         ; "state", `String "ready"
         ]
     | Error detail ->
       `Assoc
         [ "mode", `String (to_string Auto_judge)
         ; "configured", `Bool (Sys.file_exists file)
         ; "state", `String "unavailable"
         ; "read_error", `String detail
         ])
  | Ok ((Manual | Always_allow) as mode) ->
    `Assoc
      [ "mode", `String (to_string mode)
      ; "configured", `Bool (Sys.file_exists file)
      ; "state", `String "ready"
      ]
  | Error detail ->
    `Assoc
      [ "mode", `String (to_string Manual)
      ; "configured", `Bool true
      ; "state", `String "invalid"
      ; "read_error", `String detail
      ]
;;

let status_json ~base_path =
  status_json_lane ~file:(path ~base_path) (read ~base_path)
;;

let status_json_external ~base_path =
  status_json_lane ~file:(external_path ~base_path) (read_external ~base_path)
;;

let rec set (config : Workspace.config) ~actor mode =
  set_lane
    config
    ~actor
    ~read_lane:read
    ~file_of_base:path
    ~audit_action:"keeper_gate_mode_set"
    mode

and set_external (config : Workspace.config) ~actor mode =
  set_lane
    config
    ~actor
    ~read_lane:read_external
    ~file_of_base:external_path
    ~audit_action:"keeper_gate_external_mode_set"
    mode

and set_lane
      (config : Workspace.config)
      ~actor
      ~read_lane
      ~file_of_base
      ~audit_action
      mode
  =
  let base_path = config.base_path in
  let previous, replaced_read_error =
    match read_lane ~base_path with
    | Ok previous -> Some previous, None
    | Error detail -> None, Some detail
  in
  let changed_at = Masc_domain.now_iso () in
  let dir = Keeper_gate_path.dir ~base_path in
  Fs_compat.mkdir_p dir;
  let file = file_of_base ~base_path in
  match
    Fs_compat.save_file_atomic
      file
      (Yojson.Safe.pretty_to_string (state_json ~actor ~changed_at mode))
  with
  | Error detail -> Error (Printf.sprintf "keeper Gate mode write failed: %s" detail)
  | Ok () ->
    Audit_log.log_action
      config
      ~agent_id:actor
      ~action:(Audit_log.Custom audit_action)
      ~details:
        (`Assoc
           ([ ( "previous_mode"
              , match previous with
                | Some value -> `String (to_string value)
                | None -> `Null )
            ; "mode", `String (to_string mode)
            ; "changed_at", `String changed_at
            ; "actor", `String actor
            ]
            @
            match replaced_read_error with
            | Some detail -> [ "replaced_read_error", `String detail ]
            | None -> []))
      ~outcome:Audit_log.Success
      ();
    Ok { previous; current = mode; actor; changed_at; replaced_read_error }
;;

let change_json change =
  `Assoc
    ([ "ok", `Bool true
     ; ( "previous_mode"
       , match change.previous with
         | Some previous -> `String (to_string previous)
         | None -> `Null )
     ; "mode", `String (to_string change.current)
     ; "actor", `String change.actor
     ; "changed_at", `String change.changed_at
     ]
     @
     match change.replaced_read_error with
     | Some detail -> [ "replaced_read_error", `String detail ]
     | None -> [])
;;
