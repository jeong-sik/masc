open Masc_mcp

module Board = Masc_mcp.Board
module Board_dispatch = Masc_mcp.Board_dispatch
module Room = Masc_mcp.Room
module Keeper_types = Masc_mcp.Keeper_types
module WO = Masc_mcp.Keeper_world_observation
module UT = Masc_mcp.Keeper_unified_turn

let () = Mirage_crypto_rng_unix.use_default ()

let bool_env_default_false name =
  match Sys.getenv_opt name with
  | Some ("1" | "true" | "TRUE" | "yes" | "YES" | "on" | "ON") -> true
  | _ -> false

let keep_tmp = bool_env_default_false "MASC_KEEPER_ROOM_SIGNAL_EVAL_KEEP_TMP"

let has_prompt_root path =
  Sys.file_exists
    (Filename.concat path "config/prompts/keeper.unified.system.md")

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
      let rec ascend path =
        if has_prompt_root path then path
        else
          let parent = Filename.dirname path in
          if String.equal parent path then Sys.getcwd () else ascend parent
      in
      ascend (Sys.getcwd ())

let init_prompts () =
  let prompts_dir = Filename.concat (repo_root ()) "config/prompts" in
  Prompt_registry.set_markdown_dir prompts_dir;
  Prompt_defaults.init ()

let temp_counter = ref 0

let temp_dir prefix =
  incr temp_counter;
  let dir = Filename.temp_file (Printf.sprintf "%s_%d_" prefix !temp_counter) "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some prev -> Unix.putenv key prev
      | None -> Unix.putenv key "")
    f

let with_eval_env ~base_dir f =
  with_env "MASC_BASE_PATH" base_dir @@ fun () ->
  with_env "MASC_STORAGE_TYPE" "filesystem" @@ fun () ->
  with_env "MASC_POSTGRES_URL" "" @@ fun () ->
  with_env "DATABASE_URL" "" @@ fun () ->
  with_env "SUPABASE_DB_URL" "" @@ fun () ->
  with_env "SB_PG_URL" "" @@ fun () ->
  with_env "MASC_KEEPER_ROOM_SIGNAL_PROMPT_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_UNIFIED_MAX_TURNS" "3" @@ fun () ->
  with_env "MASC_KEEPER_UNIFIED_MAX_TOKENS" "1024" @@ fun () ->
  with_env "MASC_KEEPER_UNIFIED_TEMP" "0.2" f

type fixture =
  | Contested_blockage
  | Operator_desire_stagnation

let fixture_name = function
  | Contested_blockage -> "contested_blockage"
  | Operator_desire_stagnation -> "operator_desire_stagnation"

let fixture_keeper_token = function
  | Contested_blockage -> "cb"
  | Operator_desire_stagnation -> "ods"

let keeper_name fixture run_index =
  Printf.sprintf "eval-%s-%d" (fixture_keeper_token fixture) run_index

let create_post ~author ~title ~content ?hearth ?thread_id () =
  match
    Board_dispatch.create_post ~author ~title ~content ?hearth ?thread_id
      ~post_kind:Board.Human_post ()
  with
  | Ok post -> post
  | Error err ->
      failwith
        (Printf.sprintf "create_post failed: %s" (Board.show_board_error err))

let add_comment ~post_id ~author ~content () =
  match Board_dispatch.add_comment ~post_id ~author ~content () with
  | Ok _ -> ()
  | Error err ->
      failwith
        (Printf.sprintf "add_comment failed: %s" (Board.show_board_error err))

let populate_fixture fixture =
  match fixture with
  | Contested_blockage ->
      let root =
        create_post ~author:"admin-keeper" ~title:"RBAC blockage"
          ~content:
            "All masc_* tools tested return unregistered_masc_tool. \
             Operator intervention needed. keeper_* tools function normally."
          ~hearth:"ops" ()
      in
      add_comment
        ~post_id:(Board.Post_id.to_string root.id)
        ~author:"keeper-a"
        ~content:
          "This contradicts the uniform block hypothesis. Access may be per-agent."
        ()
  | Operator_desire_stagnation ->
      ignore
        (create_post ~author:"idle-observer" ~title:"Idle room"
           ~content:
             "No active tasks. backlog empty. idle and available for new work."
           ~hearth:"ops" ());
      ignore
        (create_post ~author:"ops-observer" ~title:"Need operator guidance"
           ~content:
             "We need operator guidance to seed new tasks. This is not something we can self-service."
           ~hearth:"ops" ())

let make_keeper_meta keeper_name =
  let json =
    `Assoc
      [
        ("name", `String keeper_name);
        ("trace_id", `String (keeper_name ^ "-trace"));
        ("goal", `String "Evaluate keeper room-signal guard behavior");
      ]
  in
  match Keeper_types.meta_of_json json with
  | Error err -> Error ("meta_of_json failed: " ^ err)
  | Ok meta ->
      Ok
        {
          meta with
          room_signal_prompt_enabled = true;
          proactive = { meta.proactive with enabled = false };
          tool_access =
            Keeper_types.Preset
              {
                preset = Keeper_types.Minimal;
                also_allow =
                  [
                    "keeper_board_list";
                    "keeper_board_get";
                    "keeper_board_post";
                    "keeper_board_comment";
                    "keeper_task_claim";
                  ];
              };
          tool_denylist = [];
        }

let write_keeper_meta config keeper_name =
  match make_keeper_meta keeper_name with
  | Error err -> Error err
  | Ok meta -> (
      Keeper_types.mkdir_p (Keeper_types.keeper_session_dir config (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
      match Keeper_types.write_meta ~force:true config meta with
      | Ok () ->
          ignore
            (Keeper_registry.register ~base_path:config.base_path meta.name meta);
          Ok meta
      | Error err -> Error err)

let read_latest_decision_json config keeper_name =
  let path = Keeper_types.keeper_decision_log_path config keeper_name in
  if not (Sys.file_exists path) then
    Error (Printf.sprintf "missing decision log: %s" path)
  else
    let ic = open_in path in
    let rec loop last =
      match input_line ic with
      | line -> loop (Some line)
      | exception End_of_file ->
          close_in_noerr ic;
          (match last with
           | Some line -> Ok (Yojson.Safe.from_string line)
           | None -> Error (Printf.sprintf "empty decision log: %s" path))
    in
    loop None

let string_list_member_opt key json =
  let open Yojson.Safe.Util in
  let rec collect acc = function
    | [] -> Some (List.rev acc)
    | `String value :: rest -> collect (value :: acc) rest
    | _ -> None
  in
  match json |> member key with
  | `List items -> collect [] items
  | _ -> None

let string_member_opt key json =
  match Yojson.Safe.Util.member key json with
  | `String value -> Some value
  | _ -> None

let index_of_first tool_names targets =
  let target_set = List.sort_uniq String.compare targets in
  tool_names
  |> List.mapi (fun index tool_name -> (index, tool_name))
  |> List.find_map (fun (index, tool_name) ->
         if List.mem tool_name target_set then Some index else None)

type run_report = {
  fixture : string;
  run_index : int;
  temp_dir : string;
  model_used : string option;
  primary_salience : string option;
  tools_used : string list;
  response_preview : string option;
  pass : bool;
  failure_reason : string option;
}

let run_report_to_json (report : run_report) =
  `Assoc
    [
      ("fixture", `String report.fixture);
      ("run_index", `Int report.run_index);
      ("temp_dir", `String report.temp_dir);
      ( "model_used",
        match report.model_used with Some value -> `String value | None -> `Null );
      ( "primary_salience",
        match report.primary_salience with
        | Some value -> `String value
        | None -> `Null );
      ("tools_used", `List (List.map (fun tool_name -> `String tool_name) report.tools_used));
      ( "response_preview",
        match report.response_preview with
        | Some value -> `String value
        | None -> `Null );
      ("pass", `Bool report.pass);
      ( "failure_reason",
        match report.failure_reason with
        | Some value -> `String value
        | None -> `Null );
    ]

let evaluate_tools tools_used =
  let board_read_tools = [ "keeper_board_get"; "keeper_board_list" ] in
  let gated_action_tools = [ "keeper_board_post"; "keeper_task_claim" ] in
  match index_of_first tools_used gated_action_tools with
  | None -> (true, None)
  | Some action_index -> (
      match index_of_first tools_used board_read_tools with
      | Some read_index when read_index < action_index -> (true, None)
      | _ ->
          ( false,
            Some
              "keeper used board_post/task_claim without a prior keeper_board_get/list read" ))

let failure_report ~fixture ~run_index ~base_dir ?model_used ?primary_salience reason
    =
  {
    fixture = fixture_name fixture;
    run_index;
    temp_dir = base_dir;
    model_used;
    primary_salience;
    tools_used = [];
    response_preview = None;
    pass = false;
    failure_reason = Some reason;
  }

let evaluate_run env fixture run_index =
  let base_dir =
    temp_dir (Printf.sprintf "keeper_room_signal_eval_%s_%d" (fixture_name fixture) run_index)
  in
  let finally () =
    if not keep_tmp then cleanup_dir base_dir
  in
  Fun.protect ~finally (fun () ->
      try
        with_eval_env ~base_dir @@ fun () ->
        Board.reset_global_for_test ();
        Board_dispatch.reset_for_test ();
        Board_dispatch.init_jsonl ();
        let config = Room.default_config base_dir in
        ignore (Room.init config ~agent_name:(Some "room-signal-evaluator"));
        populate_fixture fixture;
        let keeper_name = keeper_name fixture run_index in
        match write_keeper_meta config keeper_name with
        | Error err -> failure_report ~fixture ~run_index ~base_dir err
        | Ok meta ->
            Eio.Switch.run @@ fun sw ->
            Eio_context.with_test_env
              ~net:(Eio.Stdenv.net env)
              ~clock:(Eio.Stdenv.clock env)
              ~mono_clock:(Eio.Stdenv.mono_clock env)
              ~sw
              (fun () ->
                let observation =
                  WO.observe ~pending_board_events:(Some []) ~config ~meta
                in
                let observation =
                  { observation with worktree_change_summary = None }
                in
                let primary_salience =
                  observation.room_signal_interpretation
                  |> Option.map (fun (interpretation : Meta_cognition.interpretation) ->
                         Meta_cognition.salience_to_string interpretation.primary_salience)
                in
                match
                  UT.run_unified_turn ~config ~meta ~observation
                    ~generation:meta.runtime.generation ()
                with
                | Error err ->
                    failure_report ~fixture ~run_index ~base_dir ?primary_salience
                      (Oas.Error.to_string err)
                | Ok updated_meta -> (
                    match read_latest_decision_json config keeper_name with
                    | Error err ->
                        failure_report ~fixture ~run_index ~base_dir
                          ?model_used:(Some updated_meta.runtime.usage.last_model_used)
                          ?primary_salience err
                    | Ok decision_json -> (
                        match string_list_member_opt "tools_used" decision_json with
                        | None ->
                            failure_report ~fixture ~run_index ~base_dir
                              ?model_used:(Some updated_meta.runtime.usage.last_model_used)
                              ?primary_salience
                              "decision log missing valid tools_used list"
                        | Some tools_used ->
                            let pass, failure_reason = evaluate_tools tools_used in
                            {
                              fixture = fixture_name fixture;
                              run_index;
                              temp_dir = base_dir;
                              model_used = Some updated_meta.runtime.usage.last_model_used;
                              primary_salience;
                              tools_used;
                              response_preview =
                                string_member_opt "response_preview" decision_json;
                              pass;
                              failure_reason;
                            })))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          failure_report ~fixture ~run_index ~base_dir
            (Printf.sprintf "unexpected exception: %s" (Printexc.to_string exn)))

let print_report report =
  let tools_text =
    match report.tools_used with
    | [] -> "(none)"
    | tools -> String.concat ", " tools
  in
  Printf.printf "[%s run %d] primary=%s model=%s pass=%b\n"
    report.fixture report.run_index
    (Option.value ~default:"unknown" report.primary_salience)
    (Option.value ~default:"unknown" report.model_used)
    report.pass;
  Printf.printf "  tools_used: %s\n" tools_text;
  (match report.response_preview with
   | Some preview -> Printf.printf "  response_preview: %s\n" preview
   | None -> ());
  (match report.failure_reason with
   | Some reason -> Printf.printf "  failure: %s\n" reason
   | None -> ());
  if keep_tmp then Printf.printf "  temp_dir: %s\n" report.temp_dir

let () =
  init_prompts ();
  let reports =
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    [ Contested_blockage; Operator_desire_stagnation ]
    |> List.concat_map (fun fixture ->
           [ 1; 2; 3 ] |> List.map (evaluate_run env fixture))
  in
  List.iter print_report reports;
  let failed =
    List.filter_map
      (fun report ->
        if report.pass then None
        else Some (Printf.sprintf "%s#%d" report.fixture report.run_index))
      reports
  in
  Printf.printf "\n%s\n"
    (Yojson.Safe.pretty_to_string
       (`Assoc
         [
           ("runs", `List (List.map run_report_to_json reports));
           ("failed", `List (List.map (fun item -> `String item) failed));
           ("pass", `Bool (failed = []));
         ]));
  if failed <> [] then exit 1
