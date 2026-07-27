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
