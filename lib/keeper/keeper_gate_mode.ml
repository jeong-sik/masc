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

let read ~base_path =
  let file = path ~base_path in
  if not (Sys.file_exists file)
  then Ok default
  else
    match Safe_ops.read_json_file_safe file with
    | Ok json -> mode_of_state_json json
    | Error detail -> Error (Printf.sprintf "keeper Gate mode read failed: %s" detail)
;;

let status_json ~base_path =
  match read ~base_path with
  | Ok mode ->
    `Assoc
      [ "mode", `String (to_string mode)
      ; "configured", `Bool (Sys.file_exists (path ~base_path))
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

let set (config : Workspace.config) ~actor mode =
  let base_path = config.base_path in
  let previous, replaced_read_error =
    match read ~base_path with
    | Ok previous -> Some previous, None
    | Error detail -> None, Some detail
  in
  let changed_at = Masc_domain.now_iso () in
  let dir = Keeper_gate_path.dir ~base_path in
  Fs_compat.mkdir_p dir;
  let file = path ~base_path in
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
      ~action:(Audit_log.Custom "keeper_gate_mode_set")
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
