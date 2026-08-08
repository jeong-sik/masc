(** [Workspace.init] writes [root-state.json] for a fresh workspace.

    [Workspace_bootstrap.default_workspace_state] declares that record, and
    [ensure_workspace_bootstrap] uses it. [init] carried its own copy of the
    same twelve fields, so changing a default — [search_strategy_default] is
    one — moved the initial state only for whichever entry point happened to
    run on a fresh workspace. Nothing in the type system connected the two.

    This pins what [init] writes against the declared default. A re-inlined
    copy that drifts in any field fails here.

    One workspace per executable: [Workspace] pins [MASC_BASE_PATH] for the
    running test binary and logs "Ignoring test MASC_BASE_PATH override" for a
    second one, so a two-workspace comparison reads the wrong tree. *)

open Alcotest

module Q = Masc.Workspace

let rec rm path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun e -> rm (Filename.concat path e)) (Sys.readdir path);
      Sys.rmdir path)
    else Sys.remove path
;;

(* [started_at] is a wall-clock stamp taken at each call; every other field is
   a declared default and must agree. *)
let without_started_at = function
  | `Assoc fields -> `Assoc (List.filter (fun (k, _) -> k <> "started_at") fields)
  | other -> other
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "root-state-parity-%d" (Unix.getpid ()))
  in
  rm dir;
  Unix.mkdir dir 0o755;
  Unix.putenv "MASC_BASE_PATH" dir;
  let config = Q.default_config dir in
  Fun.protect
    ~finally:(fun () ->
      let (_ : string) = Q.reset config in
      rm dir)
    (fun () -> f config)
;;

let test_init_writes_the_declared_default_state () =
  with_workspace (fun config ->
    let (_ : string) = Q.init config ~agent_name:None in
    let written =
      without_started_at (Workspace_utils.read_json_root config (Q.root_state_path config))
    in
    let declared =
      without_started_at
        (Masc_domain.workspace_state_to_yojson (Q.default_workspace_state config))
    in
    (* An empty read would make the comparison below vacuous. The serializer
       drops fields left at their default, so the written object carries fewer
       keys than the record has fields. *)
    (match written with
     | `Assoc fields when List.length fields >= 4 -> ()
     | other -> fail ("root-state.json read back as: " ^ Yojson.Safe.to_string other));
    check
      string
      "init writes default_workspace_state"
      (Yojson.Safe.to_string declared)
      (Yojson.Safe.to_string written))
;;

let () =
  run
    "workspace_root_state_parity"
    [ ( "root state"
      , [ test_case
            "init writes the declared default state"
            `Quick
            test_init_writes_the_declared_default_state
        ] )
    ]
;;
