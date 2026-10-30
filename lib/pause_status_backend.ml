(** Pause-status projection for workspace/tool surfaces. *)

type keeper_pause_status =
  | Workspace_not_initialized
  | Census of
      { paused_names : string list
      ; read_errors : (string * string) list
      }

let keeper_pause_census config =
  let open Result.Syntax in
  (* The census raises when the roster path cannot even be ensured (e.g.
     occupied by a file); that failure is an [Error] here, like the
     fleet-health projections do, instead of escaping the caller. *)
  let names_result =
    try Keeper_meta_store.keeper_names_result config with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  in
  let* names = names_result in
  let read_errors_rev, paused_by_meta_rev, paused_by_phase_rev =
    List.fold_left
      (fun (errs, by_meta, by_phase) name ->
         let by_meta, errs =
           match Keeper_meta_store.read_meta config name with
           | Ok (Some meta) when meta.paused -> meta.name :: by_meta, errs
           | Ok _ -> by_meta, errs
           | Error err -> by_meta, (name, err) :: errs
         in
         let by_phase =
           match Keeper_registry.get_phase ~base_path:config.base_path name with
           | Some Keeper_state_machine.Paused -> name :: by_phase
           | Some (Keeper_state_machine.Offline) | None | Some (Keeper_state_machine.Running)
           | Some (Keeper_state_machine.Failing) | Some (Keeper_state_machine.Draining)
           | Some (Keeper_state_machine.Stopped) | Some (Keeper_state_machine.Crashed)
           | Some (Keeper_state_machine.Restarting) -> by_phase
         in
         errs, by_meta, by_phase)
      ([], [], [])
      names
  in
  let meta_paused_names = List.rev paused_by_meta_rev in
  let phase_paused_names = List.rev paused_by_phase_rev in
  let paused_names =
    Keeper_types_profile_toml_normalizers.dedupe_keep_order
      (meta_paused_names @ phase_paused_names)
  in
  Ok (Census { paused_names; read_errors = List.rev read_errors_rev })
;;

let keeper_pause_status config =
  if not (Workspace.is_initialized config)
  then Ok Workspace_not_initialized
  else keeper_pause_census config
;;

let keeper_pause_status_to_json status =
  let paused, paused_count, paused_names, read_errors =
    match status with
    | Workspace_not_initialized -> `Null, `Null, [], []
    | Census { paused_names; read_errors } ->
      ( `Bool (paused_names <> [])
      , `Int (List.length paused_names)
      , paused_names
      , read_errors )
  in
  `Assoc
    [ "paused", paused
    ; "paused_count", paused_count
    ; "paused_names", `List (List.map (fun name -> `String name) paused_names)
    ; ( "read_errors"
      , `List
          (List.map
             (fun (name, error) ->
                `Assoc [ "name", `String name; "error", `String error ])
             read_errors) )
    ]
;;
