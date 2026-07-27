(** Canonical durable Goal event producer. *)

let path config =
  Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl"
;;

let emit config ~goal_id ~event_type ~payload =
  Fs_compat.append_jsonl
    (path config)
    (`Assoc
       [ "ts", `String (Masc_domain.now_iso ())
       ; "goal_id", `String goal_id
       ; "event_type", `String event_type
       ; "payload", payload
       ])
;;

let emit_phase config ~goal_id ~phase ~actor =
  emit
    config
    ~goal_id
    ~event_type:"goal_phase"
    ~payload:
      (`Assoc
         [ "phase", Goal_phase.to_yojson phase
         ; "actor", `String actor
         ])
;;

type ensure_outcome =
  | Emitted
  | Already_present

let phase_event_matches ~goal_id ~phase ~actor ~goal_updated_at json =
  match json with
  | `Assoc _ ->
      let payload =
        Option.value
          ~default:`Null
          (Json_util.assoc_member_opt "payload" json)
      in
      Json_util.get_string json "goal_id" = Some goal_id
      && Json_util.get_string json "event_type" = Some "goal_phase"
      && Json_util.get_string payload "phase" = Some (Goal_phase.to_string phase)
      && Json_util.get_string payload "actor" = Some actor
      && Json_util.get_string payload "goal_updated_at" = Some goal_updated_at
  | `List _ | `String _ | `Float _ | `Int _ | `Intlit _ | `Bool _ | `Null ->
      false
;;

let ensure_phase config ~goal_id ~phase ~actor ~goal_updated_at =
  let event_path = path config in
  Workspace_utils.with_file_lock config event_path (fun () ->
    let present =
      if not (Sys.file_exists event_path)
      then false
      else
        Fs_compat.fold_jsonl_lines
          ~init:false
          ~f:(fun present ~line_no:_ json ->
            present
            || phase_event_matches
                 ~goal_id
                 ~phase
                 ~actor
                 ~goal_updated_at
                 json)
          event_path
    in
    if present
    then Already_present
    else (
      emit
        config
        ~goal_id
        ~event_type:"goal_phase"
        ~payload:
          (`Assoc
             [ "phase", Goal_phase.to_yojson phase
             ; "actor", `String actor
             ; "goal_updated_at", `String goal_updated_at
             ]);
      Emitted))
;;
