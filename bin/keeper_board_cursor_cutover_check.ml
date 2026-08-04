open Masc
open Cmdliner

let metadata_issue_json keeper_name detail =
  `Assoc
    [ "kind", `String "keeper_metadata_unreadable"
    ; "keeper_name", `String keeper_name
    ; "detail", `String detail
    ]
;;

let cursor_issue_json = function
  | Keeper_reaction_ledger.Board_cursor_missing { keeper_name } ->
    `Assoc
      [ "kind", `String "board_cursor_missing"
      ; "keeper_name", `String keeper_name
      ]
  | Keeper_reaction_ledger.Board_cursor_unreadable { keeper_name; error } ->
    `Assoc
      [ "kind", `String "board_cursor_unreadable"
      ; "keeper_name", `String keeper_name
      ; ( "detail"
        , `String (Keeper_reaction_ledger.board_cursor_restore_error_to_string error) )
      ]
;;

let print_result ~status ~base_path ~keeper_count ~ready_count ~issues =
  Yojson.Safe.pretty_to_channel
    stdout
    (`Assoc
       [ "schema", `String "keeper.board_cursor_cutover.v1"
       ; "status", `String status
       ; "base_path", `String base_path
       ; "storage_generation", `String Keeper_reaction_ledger.storage_generation
       ; "keeper_count", `Int keeper_count
       ; "ready_count", `Int ready_count
       ; "issues", `List issues
       ]);
  output_char stdout '\n';
  flush stdout
;;

let validate_metadata config keeper_names =
  List.filter_map
    (fun keeper_name ->
       match Keeper_meta_store.read_meta config keeper_name with
       | Ok (Some _) -> None
       | Ok None -> Some (metadata_issue_json keeper_name "metadata disappeared during audit")
       | Error detail -> Some (metadata_issue_json keeper_name detail))
    keeper_names
;;

let main base_path =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let workspace_config = Workspace.default_config base_path in
  match Keeper_meta_store.keeper_names_result workspace_config with
  | Error detail ->
    print_result
      ~status:"fail"
      ~base_path
      ~keeper_count:0
      ~ready_count:0
      ~issues:
        [ `Assoc
            [ "kind", `String "keeper_metadata_discovery_failed"
            ; "detail", `String detail
            ]
        ];
    exit 2
  | Ok keeper_names ->
    let metadata_issues = validate_metadata workspace_config keeper_names in
    let report =
      Keeper_reaction_ledger.board_cursor_cutover_report ~base_path ~keeper_names
    in
    let issues = metadata_issues @ List.map cursor_issue_json report.issues in
    let ready = List.is_empty issues in
    print_result
      ~status:(if ready then "pass" else "fail")
      ~base_path
      ~keeper_count:report.keeper_count
      ~ready_count:report.ready_count
      ~issues;
    if not ready then exit 2
;;

let base_path_conv =
  let parse value =
    let value = String.trim value in
    if String.equal value ""
    then Error (`Msg "base path must be non-empty")
    else Ok value
  in
  Arg.conv (parse, Format.pp_print_string)
;;

let base_path_arg =
  Arg.(required & opt (some base_path_conv) None & info [ "base-path" ] ~docv:"PATH")
;;

let command =
  Cmd.v
    (Cmd.info
       "masc-keeper-board-cursor-cutover-check"
       ~doc:"Check current-generation Keeper Board cursor readiness")
    Term.(const main $ base_path_arg)
;;

let () = exit (Cmd.eval command)
