(** Pause-status projection for workspace/tool surfaces. *)

let keeper_pause_status_json config =
  let names = Keeper_meta_store.keeper_names config in
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
    ; "paused_count", `Int (List.length paused_names)
    ; "paused_names", `List (List.map (fun name -> `String name) paused_names)
    ; "meta_paused_count", `Int (List.length meta_paused_names)
    ; "phase_paused_count", `Int (List.length phase_paused_names)
    ; ( "read_errors"
      , `List
          (List.rev_map
             (fun (name, error) ->
                `Assoc [ "name", `String name; "error", `String error ])
             read_errors_rev) )
    ]
;;
