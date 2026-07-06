(** Pause-status projection for workspace/tool surfaces. *)

let keeper_name_discovery_read_error_json error =
  `Assoc [ "source", `String "keeper_names_result"; "error", `String error ]

let keeper_meta_read_error_json (name, error) =
  `Assoc
    [
      "source", `String "read_meta";
      "name", `String name;
      "error", `String error;
    ]

let keeper_pause_status_json config =
  let names, keeper_names_known, keeper_name_discovery_read_errors =
    match Keeper_meta_store.keeper_names_result config with
    | Ok names -> (names, true, [])
    | Error error ->
      ([], false, [ keeper_name_discovery_read_error_json error ])
  in
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
           | Some _ | None -> by_phase
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
  `Assoc
    [ "paused", `Bool (paused_names <> [])
    ; "keeper_names_known", `Bool keeper_names_known
    ; "paused_count", `Int (List.length paused_names)
    ; "paused_names", `List (List.map (fun name -> `String name) paused_names)
    ; "meta_paused_count", `Int (List.length meta_paused_names)
    ; "phase_paused_count", `Int (List.length phase_paused_names)
    ; ( "keeper_name_discovery_read_error_count"
      , `Int (List.length keeper_name_discovery_read_errors) )
    ; ( "keeper_name_discovery_read_errors"
      , `List keeper_name_discovery_read_errors )
    ; ( "read_errors"
      , `List
          (keeper_name_discovery_read_errors
           @ List.rev_map keeper_meta_read_error_json read_errors_rev) )
    ]
;;
