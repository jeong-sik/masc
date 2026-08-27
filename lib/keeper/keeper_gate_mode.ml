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
  | Ok Auto_judge ->
    (match Hitl_summary_worker.snapshot_topology_readiness () with
     | Ok () ->
       `Assoc
         [ "mode", `String (to_string Auto_judge)
         ; "configured", `Bool (Sys.file_exists (path ~base_path))
         ; "state", `String "ready"
         ]
     | Error detail ->
       `Assoc
         [ "mode", `String (to_string Auto_judge)
         ; "configured", `Bool (Sys.file_exists (path ~base_path))
         ; "state", `String "unavailable"
         ; "read_error", `String detail
         ])
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

(* Strictness, and only for resolving an override against the workspace. A
   keeper an operator singled out is one they want held to a higher bar, so
   the override is taken when it asks for more and ignored when it asks for
   less. Loosening one keeper below the workspace is a different feature and
   a wider blast radius: it would also let a keeper be the only one in
   auto_judge, which the workspace-wide drains do not look for, and its
   approvals would queue with nothing sweeping them. *)
let strictness = function
  | Always_allow -> 0
  | Auto_judge -> 1
  | Manual -> 2
;;

let stricter a b = if strictness a >= strictness b then a else b

(* Its own change record rather than reusing the workspace one: [current] is
   an option here because clearing an override is a real outcome, and there
   is no workspace read to have failed. *)
type keeper_change =
  { keeper_previous : t option
  ; keeper_current : t option
  ; keeper_actor : string
  ; keeper_changed_at : string
  }

type keeper_override =
  { keeper_name : string
  ; mode : t
  ; actor : string
  ; changed_at : string
  }

let keeper_override_json o =
  `Assoc
    [ "keeper_name", `String o.keeper_name
    ; "mode", `String (to_string o.mode)
    ; "updated_by", `String o.actor
    ; "updated_at", `String o.changed_at
    ]
;;

let keeper_override_of_json = function
  | `Assoc fields ->
    let string_field key =
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | Some _ | None ->
        Error (Printf.sprintf "keeper Gate mode override is missing %s" key)
    in
    (match string_field "keeper_name" with
     | Error detail -> Error detail
     | Ok keeper_name ->
       (match List.assoc_opt "mode" fields with
        | None -> Error "keeper Gate mode override is missing mode"
        | Some mode ->
          (match parse_json mode with
           | Error detail -> Error detail
           | Ok mode ->
             let or_unknown = function Ok value -> value | Error _ -> "" in
             Ok
               { keeper_name
               ; mode
               ; actor = or_unknown (string_field "updated_by")
               ; changed_at = or_unknown (string_field "updated_at")
               })))
  | _ -> Error "keeper Gate mode override must be an object"
;;

(* An unreadable override file is an error rather than an empty list. Reading
   it as "nobody was singled out" would answer with the workspace mode, which
   is the looser one -- a file that cannot be read must not be the quiet way
   back to it. *)
let keeper_overrides ~base_path =
  let file = Keeper_gate_path.keeper_modes ~base_path in
  if not (Sys.file_exists file)
  then Ok []
  else
    match Safe_ops.read_json_file_safe file with
    | Error detail ->
      Error (Printf.sprintf "keeper Gate mode overrides read failed: %s" detail)
    | Ok (`List rows) ->
      List.fold_left
        (fun acc row ->
          match acc, keeper_override_of_json row with
          | Error detail, _ -> Error detail
          | Ok _, Error detail -> Error detail
          | Ok kept, Ok parsed -> Ok (parsed :: kept))
        (Ok []) rows
      |> Result.map List.rev
    | Ok _ -> Error "keeper Gate mode overrides must be a list"
;;

let keeper_override ~base_path ~keeper_name =
  match keeper_overrides ~base_path with
  | Error detail -> Error detail
  | Ok rows ->
    Ok
      (List.find_opt
         (fun o -> String.equal o.keeper_name keeper_name)
         rows)
;;

let resolve ~base_path ~keeper_name =
  match read ~base_path with
  | Error detail -> Error detail
  | Ok workspace ->
    (match keeper_override ~base_path ~keeper_name with
     | Error detail -> Error detail
     | Ok None -> Ok workspace
     | Ok (Some o) -> Ok (stricter workspace o.mode))
;;

let set_for_keeper (config : Workspace.config) ~actor ~keeper_name mode =
  let base_path = config.base_path in
  match keeper_overrides ~base_path with
  | Error detail -> Error detail
  | Ok rows ->
    let previous =
      List.find_opt (fun o -> String.equal o.keeper_name keeper_name) rows
      |> Option.map (fun o -> o.mode)
    in
    let changed_at = Masc_domain.now_iso () in
    let without =
      List.filter (fun o -> not (String.equal o.keeper_name keeper_name)) rows
    in
    (* Removing rather than storing a synonym for "no opinion": the file is
       then also the list of keepers an operator has actually singled out,
       and a screen showing it does not have to filter. *)
    let rows =
      match mode with
      | None -> without
      | Some mode -> without @ [ { keeper_name; mode; actor; changed_at } ]
    in
    let dir = Keeper_gate_path.dir ~base_path in
    Fs_compat.mkdir_p dir;
    (match
       Fs_compat.save_file_atomic
         (Keeper_gate_path.keeper_modes ~base_path)
         (Yojson.Safe.pretty_to_string
            (`List (List.map keeper_override_json rows)))
     with
     | Error detail ->
       Error (Printf.sprintf "keeper Gate mode override write failed: %s" detail)
     | Ok () ->
       Audit_log.log_action config ~agent_id:actor
         ~action:(Audit_log.Custom "keeper_gate_mode_set_for_keeper")
         ~details:
           (`Assoc
              [ "keeper_name", `String keeper_name
              ; ( "previous_mode"
                , match previous with
                  | Some value -> `String (to_string value)
                  | None -> `Null )
              ; ( "mode"
                , match mode with
                  | Some value -> `String (to_string value)
                  | None -> `Null )
              ; "changed_at", `String changed_at
              ; "actor", `String actor
              ])
         ~outcome:Audit_log.Success ();
       Ok
         { keeper_previous = previous
         ; keeper_current = mode
         ; keeper_actor = actor
         ; keeper_changed_at = changed_at
         })
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

let keeper_change_json change =
  `Assoc
    [ "ok", `Bool true
    ; ( "previous_mode"
      , match change.keeper_previous with
        | Some previous -> `String (to_string previous)
        | None -> `Null )
    ; ( "mode"
      , match change.keeper_current with
        | Some mode -> `String (to_string mode)
        | None -> `Null )
    ; "actor", `String change.keeper_actor
    ; "changed_at", `String change.keeper_changed_at
    ]
;;
