(* RFC-0506: 유령 스킬 감지 — a Skill activated recently whose package is
   gone from every catalog source is recorded, never blocked or restored. *)

type ghost =
  { skill_name : string
  ; source_id : string
  ; last_activated_at : string
  ; expected_source_path : string
  }

let window_seconds = 7. *. 24. *. 3600.
let event_type = "skill_missing_on_disk"

let event_json ghost ~ts_unix =
  `Assoc
    [ ("type", `String event_type)
    ; ("ts_unix", `Float ts_unix)
    ; ("skill_name", `String ghost.skill_name)
    ; ("source_id", `String ghost.source_id)
    ; ("last_activated_at", `String ghost.last_activated_at)
    ; ("expected_source_path", `String ghost.expected_source_path)
    ]
;;

(* ---- pure projection ---- *)

let activation_in_window ~now activated_at =
  match Time_codec.parse_rfc3339 activated_at with
  | Error _ -> true
  | Ok activated_unix -> now -. activated_unix <= window_seconds
;;

let newer_than candidate best =
  match Time_codec.parse_rfc3339 candidate with
  | Error _ -> true
  | Ok candidate_unix -> (
      match Time_codec.parse_rfc3339 best with
      | Error _ -> true
      | Ok best_unix -> Float.compare candidate_unix best_unix > 0)
;;

let present_names (snapshot : Skill_catalog_snapshot.t) =
  let names = Hashtbl.create 16 in
  List.iter
    (fun (entry : Skill_catalog_snapshot.entry) ->
       Hashtbl.replace names
         (Skill_reference.identity_package_id_to_string entry.identity)
         ())
    (Skill_catalog_snapshot.effective_entries snapshot);
  fun name -> Hashtbl.mem names name
;;

let unresolved_path ~source_id ~skill_name =
  Printf.sprintf "unresolved-source:%s/%s" source_id skill_name
;;

let expected_source_path (snapshot : Skill_catalog_snapshot.t) ~skill_name ~source_id =
  let scanned =
    List.find_opt
      (fun (scan : Skill_catalog_snapshot.source_scan) ->
         String.equal
           (Skill_source_config.source_id_to_string scan.source.source.id)
           source_id)
      (Skill_catalog_snapshot.sources snapshot)
  in
  match scanned with
  | None -> unresolved_path ~source_id ~skill_name
  | Some scan ->
    (match scan.observation with
     | Source_ready { resolved_path; _ }
     | Source_missing { resolved_path }
     | Source_not_directory { resolved_path; _ }
     | Source_unavailable { resolved_path; _ } ->
       Filename.concat (Filename.concat resolved_path skill_name) "SKILL.md"
     | Source_unresolved _ -> unresolved_path ~source_id ~skill_name)
;;

let ghosts ~now ~snapshot ~activations =
  let is_present = present_names snapshot in
  let latest : (string, string * string) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (identity, activated_at) ->
       let skill_name = Skill_reference.identity_package_id_to_string identity in
       if (not (is_present skill_name)) && activation_in_window ~now activated_at
       then (
         let source_id = Skill_reference.identity_source_id_to_string identity in
         match Hashtbl.find_opt latest skill_name with
         | Some (_, best) when not (newer_than activated_at best) -> ()
         | Some _ | None ->
           Hashtbl.replace latest skill_name (source_id, activated_at)))
    activations;
  Hashtbl.fold
    (fun skill_name (source_id, last_activated_at) acc ->
       { skill_name
       ; source_id
       ; last_activated_at
       ; expected_source_path = expected_source_path snapshot ~skill_name ~source_id
       }
       :: acc)
    latest []
  |> List.sort (fun a b -> String.compare a.skill_name b.skill_name)
;;

(* ---- runtime scan and recording ---- *)

let scan_activations (config : Workspace.config) =
  (Keeper_skill_activation_discovery.scan config ~init:[]
     ~observe:(fun acc ~trace_id:_ ledger ->
        acc
        @ List.map
            (fun (activation : Keeper_skill_activation_ledger.activation) ->
               (activation.identity, activation.activated_at))
            (Keeper_skill_activation_ledger.activations ledger)))
    .value
;;

let string_field fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | Some _ | None -> None
;;

(* The retained workspace audit is the observation authority. Count matching
   rows, not the unrelated actions written after this observation. *)
let ghost_was_recorded (config : Workspace.config) ghost =
  let keep (entry : Audit_log.audit_entry) =
    String.equal entry.agent_id "skill-catalog"
    && entry.action = Audit_log.Custom event_type
    && entry.outcome = Audit_log.Success
    &&
    match entry.details with
    | `Assoc fields ->
      string_field fields "skill_name" = Some ghost.skill_name
      && string_field fields "source_id" = Some ghost.source_id
      && string_field fields "last_activated_at" = Some ghost.last_activated_at
    | _ -> false
  in
  match Audit_log.read_entries_matching ~n:1 ~keep config with
  | [] -> false
  | _ :: _ -> true
;;

let broadcast_event ~base_path ghost =
  match
    Sse.broadcast_to
      (Sse.Runtime_observers (Sse.runtime_authority_exn ~base_path))
      (event_json ghost ~ts_unix:(Time_compat.now ()))
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Log.Server.warn "skill_missing_on_disk: event broadcast failed: %s"
      (Printexc.to_string exn)
;;

let record_ghost ~base_path ~config ghost =
  Log.Server.warn
    "skill_missing_on_disk: skill=%s source=%s last_activated_at=%s expected_source_path=%s"
    ghost.skill_name ghost.source_id ghost.last_activated_at ghost.expected_source_path;
  (match
     Audit_log.log_action config
       ~agent_id:"skill-catalog"
       ~action:(Audit_log.Custom event_type)
       ~details:
         (`Assoc
            [ ("skill_name", `String ghost.skill_name)
            ; ("source_id", `String ghost.source_id)
            ; ("last_activated_at", `String ghost.last_activated_at)
            ; ("expected_source_path", `String ghost.expected_source_path)
            ])
       ~outcome:Audit_log.Success
       ()
   with
   | () -> ()
   | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
   | exception exn ->
     Log.Server.warn "skill_missing_on_disk: audit row failed: %s"
       (Printexc.to_string exn));
  broadcast_event ~base_path ghost
;;

let record_fresh_ghosts ~base_path ~config found =
  match found with
  | [] -> []
  | _ :: _ ->
    let masc_dir = Workspace.masc_dir config in
    Fs_compat.mkdir_p masc_dir;
    let lock_path =
      Filename.concat (Unix.realpath masc_dir) (event_type ^ ".lock")
    in
    match
      File_lock_eio.with_durable_lock_observed ~lock_path (fun () ->
        List.filter
          (fun ghost ->
             match
               if ghost_was_recorded config ghost then false
               else (
                 record_ghost ~base_path ~config ghost;
                 true)
             with
             | fresh -> fresh
             | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
             | exception exn ->
               Log.Server.warn
                 "skill_missing_on_disk: recording one ghost failed: %s"
                 (Printexc.to_string exn);
               false)
          found)
    with
    | File_lock_eio.Lock_not_acquired error ->
      Log.Server.warn "skill_missing_on_disk: observation lock failed: %s"
        (File_lock_eio.durable_lock_error_to_string error);
      []
    | File_lock_eio.Body_completed { value; release_error } ->
      Option.iter
        (fun error ->
           Log.Server.warn "skill_missing_on_disk: observation lock release failed: %s"
             (File_lock_eio.durable_lock_error_to_string error))
        release_error;
      value
;;

let detect_and_record ~base_path ~snapshot =
  match
    let config = Workspace.default_config base_path in
    let activations = scan_activations config in
    let found = ghosts ~now:(Time_compat.now ()) ~snapshot ~activations in
    record_fresh_ghosts ~base_path ~config found
  with
  | ghosts -> ghosts
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Log.Server.warn "skill_missing_on_disk: detection failed: %s"
      (Printexc.to_string exn);
    []
;;
