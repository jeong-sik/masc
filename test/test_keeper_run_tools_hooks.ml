open Alcotest
open Repo_manager_types

let () = Mirage_crypto_rng_unix.use_default ()

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path
;;

let with_temp_base_path f =
  let dir = Filename.temp_file "keeper-run-tools-hooks-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Unix.mkdir (Filename.concat dir ".masc") 0o755;
  Unix.mkdir (Filename.concat (Filename.concat dir ".masc") "config") 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let sample_repo =
  { id = "masc"
  ; name = "masc"
  ; url = "https://github.com/jeong-sik/masc.git"
  ; local_path = "repos/masc"
  ; aliases = []
  ; default_branch = "main"
  ; keepers = []
  ; status = Active
  ; auto_sync = false
  ; sync_interval = 300
  ; created_at = 1L
  ; updated_at = 1L
  }
;;

let make_meta ?(sandbox_profile = Keeper_types_profile_sandbox.Remote_ssh) name =
  let json =
    `Assoc
      [ "name", `String name
      ; "trace_id", `String ("trace-" ^ name)
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  (* [sandbox_profile] is not a persisted meta field — it comes from the
     keeper's TOML profile — so the fixture JSON cannot carry it, and passing
     it there is rejected as outside the current schema. Set it on the record
     the fixture returns instead. Before this, the parameter was accepted and
     dropped: a case asking for [Docker] got a Local keeper, and
     [keeper_observation_host_path_of_visible_path] returns early for
     non-Docker profiles, so the container->host mapping the Docker case is
     named for never ran. *)
  | Ok m -> { m with Masc.Keeper_meta_contract.sandbox_profile }
  | Error e -> Alcotest.fail e
;;

(* #23469: relative tool paths anchor at the keeper's playground sandbox
   root, mirroring the file tools' own resolution; absolute paths pass
   through. masc#28582: a pathless call answers [None] — it names no
   document, and standing the project root in for one is what let a
   coordination tool's observation claim a file it never touched. *)
let sandbox_root = "/sandbox/tester"

let observed_path_opt fields =
  Masc.Keeper_run_tools_hooks.observation_file_path_from_tool_input
    ~sandbox_root
    (`Assoc fields)
;;

let observed_path fields =
  match observed_path_opt fields with
  | Some path -> path
  | None -> Alcotest.fail "expected the tool input to name a file"
;;

let test_explicit_cwd_scopes_relative_file_path () =
  check
    string
    "cwd/file_path"
    "/sandbox/tester/repos/masc/lib/foo.ml"
    (observed_path
       [ "file_path", `String "lib/foo.ml"; "cwd", `String "repos/masc" ])
;;

(* #28533 dropped "scratch" from the sandbox-rooted prefix list, in the same
   change that removed the tool-schema sentence teaching it: no code ever
   created that directory, so the only paths shaped like it were ones a model
   invented from the sentence. A [scratch/…] path is therefore an ordinary
   relative path now and anchors at the typed [cwd] like any other. "repos"
   deliberately stays in that list. *)
let test_scratch_path_anchors_at_cwd_like_any_relative_path () =
  check
    string
    "scratch/file_path"
    "/sandbox/tester/repos/masc/scratch/notes.md"
    (observed_path
       [ "file_path", `String "scratch/notes.md"; "cwd", `String "repos/masc" ])
;;

let test_sandbox_rooted_file_path_ignores_cwd () =
  check
    string
    "sandbox-rooted"
    "/sandbox/tester/repos/masc/lib/foo.ml"
    (observed_path
       [ "file_path", `String "repos/masc/lib/foo.ml"
       ; "cwd", `String "repos/other"
       ])
;;

let test_absolute_path_ignores_cwd () =
  check
    string
    "absolute"
    "/workspace/masc/lib/foo.ml"
    (observed_path
       [ "path", `String "/workspace/masc/lib/foo.ml"
       ; "cwd", `String "repos/other"
       ])
;;

let test_absolute_cwd_scopes_relative_file_path () =
  check
    string
    "absolute cwd"
    "/abs/work/lib/foo.ml"
    (observed_path
       [ "file_path", `String "lib/foo.ml"; "cwd", `String "/abs/work" ])
;;

let test_bare_relative_path_anchors_at_sandbox_root () =
  check
    string
    "bare relative"
    "/sandbox/tester/lib/solo.ml"
    (observed_path [ "file_path", `String "lib/solo.ml" ])
;;

let test_blank_path_falls_back_to_file_path () =
  check
    string
    "blank path fallback"
    "/sandbox/tester/repos/masc/lib/foo.ml"
    (observed_path
       [ "path", `String " "
       ; "file_path", `String "repos/masc/lib/foo.ml"
       ])
;;

let test_path_priority_matches_ide_helper () =
  check
    string
    "path wins"
    "/sandbox/tester/repos/masc/lib/from-path.ml"
    (observed_path
       [ "path", `String "repos/masc/lib/from-path.ml"
       ; "file_path", `String "repos/masc/lib/from-file-path.ml"
       ])
;;

let test_nested_arguments_path_is_observed () =
  check
    string
    "nested arguments path"
    "/sandbox/tester/repos/masc/lib/nested.ml"
    (observed_path
       [ ( "arguments"
         , `Assoc [ "path", `String "repos/masc/lib/nested.ml" ] )
       ])
;;

let test_nested_arguments_relative_path_uses_cwd () =
  check
    string
    "nested arguments cwd"
    "/sandbox/tester/repos/masc/lib/nested.ml"
    (observed_path
       [ ( "arguments"
         , `Assoc [ "file_path", `String "lib/nested.ml" ] )
       ; "cwd", `String "repos/masc"
       ])
;;

let test_paths_list_uses_first_string_path () =
  check
    string
    "paths list"
    "/sandbox/tester/repos/masc/lib/a.ml"
    (observed_path
       [ ( "paths"
         , `List
             [ `String "repos/masc/lib/a.ml"
             ; `String "repos/masc/lib/b.ml"
             ] )
       ])
;;

let test_files_list_uses_first_object_file_path () =
  check
    string
    "files object file_path"
    "/sandbox/tester/repos/masc/lib/from-file-object.ml"
    (observed_path
       [ ( "files"
         , `List
             [ `Assoc
                 [ "file_path"
                 , `String "repos/masc/lib/from-file-object.ml"
                 ]
             ] )
       ])
;;

let test_missing_path_falls_back_to_base_path () =
  (* A tool call that names no file has no document to attribute. It used to
     answer the project root, which the observation then stored as the edited
     file. *)
  check (option string) "pathless call names no document" None (observed_path_opt [])
;;

let with_partition_fixture ?sandbox_profile f =
  with_temp_base_path (fun base_path ->
    (match Repo_store.save_all ~base_path [ sample_repo ] with
     | Ok () -> ()
     | Error msg -> fail ("repo save failed: " ^ msg));
    let config = Masc.Workspace.default_config (Filename.concat base_path ".masc") in
    let meta =
      match sandbox_profile with
      | Some sandbox_profile -> make_meta ~sandbox_profile "tester"
      | None -> make_meta "tester"
    in
    f ~config ~meta)
;;

let resolve_attribution ?tool_name ~config ~meta fields =
  Masc.Keeper_run_tools_hooks.observation_attribution_for_tool_input
    ?tool_name
    ~config
    ~meta
    (`Assoc fields)
;;

let addressed_or_fail = function
  | Agent_observation.File (Agent_observation.Addressed { address; _ }) -> address
  | Agent_observation.File (Agent_observation.Unaddressed { reason; _ }) ->
    fail
      ("expected an addressed fact, got Unaddressed "
       ^ Agent_observation.Unattributed.reason_to_string reason)
  | Agent_observation.Pathless -> fail "expected an addressed fact, got Pathless"
;;

(* The keeper's playground clone of a registered repo resolves to the
   repo's address via the structural playground parse — the #23469
   regression this case pins: before the sandbox anchor, this input
   re-anchored at the server base path and only matched because the
   same repo happened to be registered at [repos/masc] there. *)
(* A coordination tool names no file: the observation is a keeper-timeline
   fact with no document. The helper used to answer the project root here,
   which the consumer then stored as the edited file — a broadcast claiming
   a document it never touched (masc#28582). *)
let test_partition_resolution_leaves_pathless_calls_without_a_document () =
  with_partition_fixture (fun ~config ~meta ->
    match resolve_attribution ~config ~meta [ "message", `String "fixing: CI" ] with
    | Agent_observation.Pathless -> ()
    | Agent_observation.File _ ->
      fail "a pathless call must not carry a file attribution")
;;

let test_partition_resolution_uses_project_root_for_masc_base_path () =
  with_partition_fixture (fun ~config ~meta ->
    let address =
      addressed_or_fail
        (resolve_attribution
           ~config
           ~meta
           [ "cwd", `String "repos/masc"; "path", `String "lib/foo.ml" ])
    in
    check
      string
      "slug"
      "github.com_jeong-sik_masc"
      (Agent_observation.Code_address.codebase address);
    check
      string
      "repo-relative path"
      "lib/foo.ml"
      (Agent_observation.Code_address.path address))
;;

let test_annotate_uses_input_code_address_without_sandbox_resolution () =
  with_partition_fixture (fun ~config ~meta ->
    let address =
      addressed_or_fail
        (resolve_attribution
           ~tool_name:"keeper_ide_annotate"
           ~config
           ~meta
           [ "codebase", `String "github.com_jeong-sik_masc"
           ; "file_path", `String "lib/annotated.ml"
           ])
    in
    check string "annotation codebase" "github.com_jeong-sik_masc"
      (Agent_observation.Code_address.codebase address);
    check string "annotation repo-relative path" "lib/annotated.ml"
      (Agent_observation.Code_address.path address))
;;

let test_partition_unregistered_playground_repo_fails_with_repo_id () =
  with_partition_fixture (fun ~config ~meta ->
    match
      resolve_attribution ~config ~meta [ "path", `String "repos/ghost/lib/foo.ml" ]
    with
    | Agent_observation.File
        (Agent_observation.Unaddressed
           { reason = Agent_observation.Unattributed.Unregistered_repo_id repo_id
           ; attempted_path
           }) ->
      check string "repo id" "ghost" repo_id;
      check
        bool
        "attempted path preserved for forensics"
        true
        (String.length attempted_path > 0)
    | _ ->
      fail "expected Unaddressed Unregistered_repo_id for unregistered playground repo")
;;

let test_partition_docker_visible_path_maps_to_playground_repo () =
  with_partition_fixture
    ~sandbox_profile:Keeper_types_profile_sandbox.Docker
    (fun ~config ~meta ->
       let container_repo_path =
         Filename.concat
           (Masc.Keeper_sandbox.container_root meta.name)
           "repos/masc/lib/docker.ml"
       in
       let address =
         addressed_or_fail
           (resolve_attribution ~config ~meta [ "path", `String container_repo_path ])
       in
       check
         string
         "slug"
         "github.com_jeong-sik_masc"
         (Agent_observation.Code_address.codebase address);
       check
         string
         "repo-relative path"
         "lib/docker.ml"
         (Agent_observation.Code_address.path address))
;;

(* A bare relative path outside the [repos/<id>/] lane is a real
   playground-local file, not a repo file — it must fail attribution with
   the typed reason instead of borrowing whichever repository overlaps
   the server base path. *)
let test_partition_bare_relative_outside_repos_is_unregistered_path () =
  with_partition_fixture (fun ~config ~meta ->
    match resolve_attribution ~config ~meta [ "path", `String "notes/todo.md" ] with
    | Agent_observation.File
        (Agent_observation.Unaddressed
           { reason = Agent_observation.Unattributed.Unregistered_path; _ }) ->
      ()
    | _ -> fail "expected Unaddressed Unregistered_path for playground-local file")
;;

(* --- gate history slice ------------------------------------------------- *)

module Setup = Masc.Keeper_run_tools_setup

let encoded_bytes jsons =
  List.fold_left
    (fun acc json -> acc + String.length (Yojson.Safe.to_string json))
    0
    jsons
;;

let bulky_message index =
  Agent_core.Types.text_message
    Agent_core.Types.Assistant
    (Printf.sprintf "turn %d %s" index (String.make 4096 'x'))
;;

let as_json message = Masc.Keeper_context_core.message_to_json message

let test_gate_causal_initial_is_request_local () =
  let open Yojson.Safe.Util in
  let initial =
    Setup.gate_causal_initial
      ~gate_history:[ `String "recent" ]
      ~gate_history_omitted:4
      ~user_message:"inspect the request"
      ~dynamic_context:"current state"
  in
  check
    (list string)
    "only request-local evidence fields are captured"
    [ "history_messages"; "history_messages_omitted"; "user_message"; "dynamic_context" ]
    (initial |> to_assoc |> List.map fst);
  check string "trigger is preserved" "inspect the request"
    (initial |> member "user_message" |> to_string);
  check string "current state is preserved" "current state"
    (initial |> member "dynamic_context" |> to_string)
;;

let test_gate_history_keeps_newest_within_budget () =
  let messages = List.init 200 bulky_message in
  let kept, omitted = Setup.gate_history_slice messages in
  check bool "slice stays inside the declared budget" true
    (encoded_bytes kept <= Setup.gate_history_budget_bytes);
  check bool "older messages were dropped" true (omitted > 0);
  (* Nothing may vanish unreported: the judge reads [omitted] to know it was
     handed a partial view. *)
  check int "every message is either kept or counted" (List.length messages)
    (List.length kept + omitted);
  check bool "kept slice is not empty" true (kept <> []);
  check
    (of_pp (fun fmt json -> Format.pp_print_string fmt (Yojson.Safe.to_string json)))
    "the newest message survives"
    (as_json (bulky_message 199))
    (List.nth kept (List.length kept - 1))
;;

let test_gate_history_short_history_is_whole () =
  let messages = List.init 3 bulky_message in
  let kept, omitted = Setup.gate_history_slice messages in
  check int "nothing is dropped" 0 omitted;
  check int "every message is kept" (List.length messages) (List.length kept)
;;

let test_gate_history_drops_orphan_tool_result () =
  (* The call is the oldest message and falls outside the window; its result is
     the newest. A retained result with no visible call reads as evidence of
     something the judge never sees happen. *)
  let call =
    Agent_core.Types.make_message
      ~role:Agent_core.Types.Assistant
      [ Agent_core.Types.ToolUse
          { id = "call-outside-window"; name = "masc_status"; input = `Assoc [] }
      ]
  in
  let orphan_result =
    Agent_core.Types.tool_result_msg
      ~tool_use_id:"call-outside-window"
      ~content:"cluster snapshot"
      ()
  in
  let messages = (call :: List.init 40 bulky_message) @ [ orphan_result ] in
  let kept, omitted = Setup.gate_history_slice messages in
  check bool "the orphan result is not retained" false
    (List.exists
       (fun json -> Yojson.Safe.equal json (as_json orphan_result))
       kept);
  check int "the dropped result is reported" (List.length messages)
    (List.length kept + omitted)
;;

(* ── completed_tool_calls: what the judge is handed ────────────────────
   The judge bundle has two evidence axes and #26081 bounded only one, against
   a measured "~41 KB remainder". On 2026-08-09 that remainder was 791,432 B of
   an 860,589 B bundle - 623,999 B of it a single tool [result] - and the judge
   slot refused the prompt with code 1261. The fix is not a smaller slice of the
   old shape but a smaller shape: the judge is asked about a call that has not
   run yet, so a previous tool's payload is not evidence it was ever asked to
   weigh. These cases pin the payload out and keep the ceiling honest. *)

let huge_tool_result index =
  (* Mirrors the live 623,999 B [result] that refused the prompt. *)
  Tool_result.Completed
    { Tool_result.data =
        `Assoc
          [ "index", `Int index
          ; "body", `String (String.make 620_000 'y')
          ]
    ; metadata = None
    ; tool_name = "network_read"
    ; duration_ms = 1.0
    }
;;

let record_calls context count =
  List.iter
    (fun index ->
       Masc.Keeper_gate_causal_context.record_tool_result
         context
         ~operation:"network_read"
         ~input:(`Assoc [ "index", `Int index ])
         (huge_tool_result index))
    (List.init count Fun.id)
;;

let completed_calls_of_snapshot (context : Masc.Keeper_gate_causal_context.t) =
  let open Yojson.Safe.Util in
  let snapshot = (Masc.Keeper_gate_causal_context.snapshot context).snapshot in
  ( snapshot |> member "completed_tool_calls" |> to_list
  , snapshot |> member "completed_tool_calls_omitted" |> to_int )
;;

let encoded_json_bytes items =
  List.fold_left
    (fun total json -> total + String.length (Yojson.Safe.to_string json))
    0
    items
;;

let test_completed_calls_share_the_history_budget () =
  check
    int
    "both evidence axes read one declared budget"
    Masc.Keeper_gate_causal_context.evidence_budget_bytes
    Setup.gate_history_budget_bytes
;;

let test_tool_payload_is_never_rendered () =
  let context =
    Masc.Keeper_gate_causal_context.create ~turn_id:(Some 1) ~initial:(`Assoc [])
  in
  record_calls context 13;
  let kept, omitted = completed_calls_of_snapshot context in
  (* 13 calls each holding a 620 KB payload: on the old shape this was 791,432 B
     and no budget could keep every call. *)
  check int "every call is retained" 13 (List.length kept);
  check int "nothing had to be dropped" 0 omitted;
  check
    bool
    "the whole turn renders in a few KB"
    true
    (encoded_json_bytes kept < 4096);
  let open Yojson.Safe.Util in
  List.iter
    (fun call ->
       check
         (list string)
         "only identity, input and disposition reach the judge"
         [ "operation"; "input"; "disposition" ]
         (call |> to_assoc |> List.map fst))
    kept
;;

let test_disposition_survives_for_every_call () =
  (* [disposition] is the part the judgment turns on once the payload is gone. *)
  let context =
    Masc.Keeper_gate_causal_context.create ~turn_id:(Some 1) ~initial:(`Assoc [])
  in
  Masc.Keeper_gate_causal_context.record_tool_result
    context
    ~operation:"network_read"
    ~input:(`Assoc [ "index", `Int 0 ])
    (huge_tool_result 0);
  Masc.Keeper_gate_causal_context.record_tool_result
    context
    ~operation:"network_read"
    ~input:(`Assoc [ "index", `Int 1 ])
    (Tool_result.Failed
       { Tool_result.class_ = Tool_result.Dependency_unavailable
       ; message = "upstream refused"
       ; data = `Null
       ; metadata = None
       ; tool_name = "network_read"
       ; duration_ms = 1.0
       });
  let kept, _ = completed_calls_of_snapshot context in
  let open Yojson.Safe.Util in
  let dispositions = List.map (fun c -> c |> member "disposition" |> to_string) kept in
  check int "both calls are present" 2 (List.length dispositions);
  check
    bool
    "the failed call is distinguishable from the completed one"
    true
    (List.nth dispositions 0 <> List.nth dispositions 1)
;;

let test_budget_still_bounds_a_large_input () =
  (* The payload is gone but a tool [input] can itself be large, and an axis with
     no declared ceiling is the one that grows until a provider refuses. *)
  let context =
    Masc.Keeper_gate_causal_context.create ~turn_id:(Some 1) ~initial:(`Assoc [])
  in
  let total = 40 in
  List.iter
    (fun index ->
       Masc.Keeper_gate_causal_context.record_tool_result
         context
         ~operation:"network_read"
         ~input:
           (`Assoc
             [ "index", `Int index
             ; "body", `String (String.make 4096 'x')
             ])
         (huge_tool_result index))
    (List.init total Fun.id);
  let kept, omitted = completed_calls_of_snapshot context in
  check
    bool
    "rendered calls stay inside the declared budget"
    true
    (encoded_json_bytes kept
     <= Masc.Keeper_gate_causal_context.evidence_budget_bytes);
  check bool "older calls were dropped" true (omitted > 0);
  (* Nothing may vanish unreported: judge.effect.md tells the judge to read
     [completed_tool_calls_omitted] before treating the list as the whole turn. *)
  check int "every call is either kept or counted" total (List.length kept + omitted);
  let open Yojson.Safe.Util in
  check
    int
    "the newest call survives"
    (total - 1)
    (List.nth kept (List.length kept - 1)
     |> member "input"
     |> member "index"
     |> to_int)
;;

let test_completed_calls_short_list_is_whole () =
  let context =
    Masc.Keeper_gate_causal_context.create ~turn_id:(Some 1) ~initial:(`Assoc [])
  in
  record_calls context 3;
  let kept, omitted = completed_calls_of_snapshot context in
  check int "nothing is dropped" 0 omitted;
  check int "every call is kept" 3 (List.length kept)
;;

let test_concurrent_tool_observers_commit_as_transactions () =
  Eio_main.run @@ fun _env ->
  let serialize =
    Masc.Keeper_run_tools_hooks.create_tool_observer_serialization ()
  in
  let trace = ref [] in
  let record event = trace := event :: !trace in
  let first_entered, resolve_first_entered = Eio.Promise.create () in
  let release_first, resolve_release_first = Eio.Promise.create () in
  let second_attempting, resolve_second_attempting = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      serialize (fun () ->
        record "receipt:first";
        Eio.Promise.resolve resolve_first_entered ();
        Eio.Promise.await release_first;
        record "activity:first"));
    Eio.Promise.await first_entered;
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve resolve_second_attempting ();
      serialize (fun () ->
        record "receipt:second";
        record "activity:second"));
    Eio.Promise.await second_attempting;
    (* Give the second fiber a scheduling turn while the first observer is
       suspended. Without the production serialization boundary this would put
       the second receipt/activity pair inside the first pair. *)
    Eio.Fiber.yield ();
    Eio.Promise.resolve resolve_release_first ());
  check
    (list string)
    "receipt and activity effects share one completion order"
    [ "receipt:first"
    ; "activity:first"
    ; "receipt:second"
    ; "activity:second"
    ]
    (List.rev !trace)
;;

let test_failed_tool_observer_releases_next_completion () =
  Eio_main.run @@ fun _env ->
  let serialize =
    Masc.Keeper_run_tools_hooks.create_tool_observer_serialization ()
  in
  (match serialize (fun () -> raise Exit) with
   | () -> fail "failed observer unexpectedly returned"
   | exception Exit -> ());
  let observed = ref false in
  serialize (fun () -> observed := true);
  check bool "a reported observer failure does not poison later receipts" true !observed
;;


(* A call refused before the handler runs used to leave only a counter. The
   keeper's own history showed nothing, so it repeated the same malformed call
   every turn. An executed failure must still be written once, not twice:
   [post_tool_use] already records that one. *)
let rejected_rows_for ?on_tool_result_ready ~stage () =
  with_temp_base_path @@ fun base_path ->
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_execution_join.For_testing.clear ();
      Masc.Keeper_tool_call_log.reset_for_testing ())
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Masc.Keeper_tool_call_log.init ~base_path ();
       let config = Masc.Workspace.default_config base_path in
       let meta_ref = ref (make_meta "rejection-keeper") in
       let turn_ctx_cell = Masc.Keeper_tool_call_log.create_turn_ctx_cell () in
       let hooks =
         Masc.Keeper_hooks_agent_core.make_hooks
           ~config ~meta_ref ~turn_ctx_cell 
           ~trace_id:"rejection-trace" ~keeper_turn_id:1
           ~on_after_turn_ordinal:ignore ?on_tool_result_ready ()
       in
       let hook =
         match hooks.Agent_core.Hooks.post_tool_use_failure with
         | Some hook -> hook
         | None -> fail "post_tool_use_failure hook is not installed"
       in
       let invocation =
         Agent_core.Tool_contract.Invocation.create
           ~tool_use_id:"call-1" ~turn:1
           ~completion:Agent_core.Tool_contract.Continue_after_success
           ~schedule:
             { planned_index = 0
             ; batch_index = 0
             ; batch_size = 1
             ; execution_mode = Agent_core.Tool_contract.Serial
             }
       in
       let _ =
         hook
           (Agent_core.Hooks.PostToolUseFailure
              { invocation
              ; tool_name = "keeper_broadcast"
              ; input = `Assoc []
              ; stage
              ; duration_ms = 1.0
              ; error = {|"message": MISSING (required: string)|}
              })
       in
       Masc.Keeper_tool_call_log.flush_now ();
       Masc.Keeper_tool_call_log.read_recent ~keeper_name:"rejection-keeper" ())
;;

let test_a_rejected_call_leaves_a_row () =
  let rows =
    rejected_rows_for ~stage:Agent_core.Hooks.Validation_before_execution ()
  in
  check int "exactly one row" 1 (List.length rows);
  match rows with
  | [ row ] ->
    let field name =
      match Json_util.assoc_member_opt name row with
      | Some (`String s) -> s
      | Some (`Bool b) -> string_of_bool b
      | Some other -> Yojson.Safe.to_string other
      | None -> "<absent>"
    in
    check string "the tool that refused" "keeper_broadcast" (field "tool");
    check string "recorded as a failure" "false" (field "success");
    check bool "the argument object it was refused for" true
      (String.length (field "input") > 0);
    check bool "the refusal text" true
      (let out = field "output" in
       String.length out > 0
       && (try ignore (Str.search_forward (Str.regexp_string "MISSING") out 0); true
           with Not_found -> false))
  | _ -> fail "expected exactly one row"
;;

let test_an_executed_failure_is_not_written_twice () =
  let rows = rejected_rows_for ~stage:Agent_core.Hooks.Execution () in
  check int "post_tool_use owns that row, this hook adds none" 0 (List.length rows)
;;

let test_validation_rejection_notifies_after_exact_log_commit () =
  let observed = ref None in
  let rows =
    rejected_rows_for
      ~stage:Agent_core.Hooks.Validation_before_execution
      ~on_tool_result_ready:
        (fun ~tool_call_id ~turn ~planned_index ~execution_id ->
           observed :=
             Some
               ( tool_call_id
               , turn
               , planned_index
               , Ids.Execution_id.to_string execution_id ))
      ()
  in
  match rows, !observed with
  | [ row ], Some (tool_call_id, turn, planned_index, execution_id) ->
    check string "callback provider id" "call-1" tool_call_id;
    check int "callback turn" 1 turn;
    check int "callback planned index" 0 planned_index;
    check (option string) "callback id equals committed log id"
      (Some execution_id)
      (Safe_ops.json_string_opt "execution_id" row)
  | rows, _ ->
    failf
      "expected one committed validation row and one callback, got rows=%d"
      (List.length rows)
;;

let test_production_post_tool_hook_cancellation_releases_next_completion () =
  with_temp_base_path @@ fun base_path ->
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_execution_join.For_testing.clear ();
      Masc.Keeper_tool_call_log.reset_for_testing ())
    (fun () ->
       Eio_main.run @@ fun env ->
       Masc.Keeper_tool_call_log.init ~base_path ();
       let config = Masc.Workspace.default_config base_path in
       let meta_ref = ref (make_meta "cancelled-observer") in
       let turn_ctx_cell = Masc.Keeper_tool_call_log.create_turn_ctx_cell () in
       let serialize =
         Masc.Keeper_run_tools_hooks.create_tool_observer_serialization ()
       in
       let first_entered, resolve_first_entered = Eio.Promise.create () in
       let release_first, resolve_release_first = Eio.Promise.create () in
       let first_body_completed = ref false in
       let second_observed = ref false in
       let observation_count = ref 0 in
       let hooks =
         Masc.Keeper_hooks_agent_core.make_hooks
           ~config
           ~meta_ref
           ~turn_ctx_cell
           ~trace_id:"cancelled-observer-trace"
           ~keeper_turn_id:1
           ~on_after_turn_ordinal:ignore
           ~on_tool_executed:
             (fun
               ~tool_name:_ ~input:_ ~output_text:_ ~success:_ ~duration_ms:_
               ~provider:_ ~typed_outcome:_ ->
               serialize (fun () ->
                 incr observation_count;
                 if !observation_count = 1
                 then begin
                   Eio.Promise.resolve resolve_first_entered ();
                   Eio.Promise.await release_first;
                   first_body_completed := true
                 end
                 else
                   second_observed := true))
           ()
       in
       let post_tool_use =
         match hooks.Agent_core.Hooks.post_tool_use with
         | Some hook -> hook
         | None -> fail "production Keeper hooks omitted post_tool_use"
       in
       let event planned_index =
         let invocation =
           Agent_core.Tool_contract.Invocation.create
             ~tool_use_id:("cancel-observer-" ^ string_of_int planned_index)
             ~turn:1
             ~completion:Agent_core.Tool_contract.Continue_after_success
             ~schedule:
               { planned_index
               ; batch_index = 0
               ; batch_size = 1
               ; execution_mode = Agent_core.Tool_contract.Serial
               }
         in
         Agent_core.Hooks.PostToolUse
           { invocation
           ; tool_name = "keeper_time_now"
           ; input = `Assoc []
           ; output = Ok { Agent_core.Types.content = "ok"; _meta = None }
           ; result_bytes = 2
           ; duration_ms = 1.0
           }
       in
       let worker_done, resolve_worker_done = Eio.Promise.create () in
       let cancellation_ready, resolve_cancellation_ready = Eio.Promise.create () in
       Eio.Switch.run @@ fun sw ->
       Eio.Fiber.fork ~sw (fun () ->
         Eio.Cancel.sub @@ fun cancellation ->
         Eio.Promise.resolve resolve_cancellation_ready cancellation;
         let outcome =
           match post_tool_use (event 0) with
           | _ -> `Returned
           | exception Eio.Cancel.Cancelled _ -> `Cancelled
         in
         Eio.Promise.resolve resolve_worker_done outcome);
       let cancellation = Eio.Promise.await cancellation_ready in
       Eio.Promise.await first_entered;
       Eio.Cancel.cancel cancellation (Failure "cancel production observer");
       (* Give the cancelled worker a scheduling turn before releasing the
          synthetic blocker. A cancellation-masked observer reaches the line
          after [await]; a cancellable observer unwinds through the mutex
          finalizer without completing the body. *)
       Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
       Eio.Promise.resolve resolve_release_first ();
       (match Eio.Promise.await worker_done with
        | `Cancelled -> ()
        | `Returned -> fail "production post-tool hook swallowed cancellation");
       check bool
         "cancellation preempts the observation body"
         false
         !first_body_completed;
       (match post_tool_use (event 1) with
        | Agent_core.Hooks.Continue -> ()
        | _ -> fail "later production post-tool hook did not continue");
       check bool
         "cancelled observer releases the mutex for the next production hook"
         true
         !second_observed)
;;

(* The post-tool-round predicate is the position of the last message, not
   containment over history: an old Tool message earlier in the conversation
   must not read as "this round follows tool execution" — that misread
   suppressed the world state on the first round of ordinary turns
   (one keeper's turn 15, 2026-08-24). *)
let message role content : Agent_core.Types.message =
  { role; content = [ Agent_core.Types.Text content ]; name = None
  ; tool_call_id = None; metadata = []
  }

let test_ends_with_tool_results_is_positional () =
  let user = message Agent_core.Types.User "ask" in
  let assistant = message Agent_core.Types.Assistant "plan" in
  let tool = message Agent_core.Types.Tool "result" in
  check bool "empty history is not post-tool" false
    (Masc.Keeper_run_prompt.ends_with_tool_results []);
  check bool "a turn's first round ends with the user" false
    (Masc.Keeper_run_prompt.ends_with_tool_results [ user ]);
  check bool "a round after tool execution ends with the tool" true
    (Masc.Keeper_run_prompt.ends_with_tool_results [ user; assistant; tool ]);
  check bool "an old tool message before a new user turn does not count" false
    (Masc.Keeper_run_prompt.ends_with_tool_results [ user; assistant; tool; user ])

(* The filter that drops the world state on later rounds must not fire on a
   turn that has injected nothing yet. A keeper whose previous turn ended on a
   tool result replays that shape into its next turn's first round, which is
   what silenced 39 of 108 turns on 2026-08-25. *)
let test_first_round_survives_a_replayed_tool_tail () =
  let user = message Agent_core.Types.User "ask" in
  let assistant = message Agent_core.Types.Assistant "plan" in
  let tool = message Agent_core.Types.Tool "result" in
  let replayed = [ user; assistant; tool ] in
  check
    bool
    "a first round is not a later round, whatever the history ends with"
    false
    (Masc.Keeper_run_prompt.is_later_round_of_this_turn
       ~injected_this_turn:false
       replayed);
  check
    bool
    "a round after this turn injected is a later round"
    true
    (Masc.Keeper_run_prompt.is_later_round_of_this_turn
       ~injected_this_turn:true
       replayed);
  check
    bool
    "a history that does not end on a tool is never a later round"
    false
    (Masc.Keeper_run_prompt.is_later_round_of_this_turn
       ~injected_this_turn:true
       [ user ])


let test_trailing_tool_results_keep_exact_receipts () =
  let tool_message : Agent_core.Types.message =
    { role = Agent_core.Types.Tool
    ; content =
        [ Agent_core.Types.ToolResult
            { tool_use_id = "call-skill"
            ; content = "body"
            ; outcome = Agent_core.Llm_provider.Types.Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ; Agent_core.Types.ToolResult
            { tool_use_id = "call-other"
            ; content = "other"
            ; outcome = Agent_core.Llm_provider.Types.Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let receipts =
    Masc.Keeper_run_tools_hooks.trailing_tool_result_receipts [ tool_message ]
  in
  check
    (list (pair string int))
    "exact trailing ids and bytes"
    [ "call-skill", 4; "call-other", 5 ]
    (List.map
       (fun (receipt : Masc.Keeper_skill_activation_ledger.tool_result_receipt) ->
          receipt.tool_use_id, receipt.content_bytes)
       receipts);
  check
    (list string)
    "a later non-tool message means no provider-bound tool result"
    []
    (List.map
       (fun (receipt : Masc.Keeper_skill_activation_ledger.tool_result_receipt) ->
          receipt.tool_use_id)
       (Masc.Keeper_run_tools_hooks.trailing_tool_result_receipts
       [ tool_message; Agent_core.Types.user_msg "later" ])
    )
;;

let wire_receipt tool_use_id =
  Masc.Keeper_skill_activation_ledger.
    { tool_use_id
    ; content_bytes = 4
    ; content_sha256 = Digestif.SHA256.(digest_string "body" |> to_hex)
    }
;;

let test_skill_delivery_requires_serialization_and_success_response () =
  let module State = Masc.Keeper_run_tools_hooks.Skill_delivery_state in
  let state = State.create () in
  let observations = ref [] in
  let observe (staged : State.staged) =
    observations := staged.runtime_id :: !observations;
    List.map
      (fun (receipt : Masc.Keeper_skill_activation_ledger.tool_result_receipt) ->
         receipt.tool_use_id)
      staged.tool_results
  in
  State.begin_turn state;
  State.commit_model_response state ~agent_core_turn:1 ~observe;
  check (list string) "serialization failure has no delivery" [] !observations;
  State.stage state ~runtime_id:"runtime-failed" ~agent_core_turn:1
    [ wire_receipt "call-skill" ];
  State.begin_turn state;
  State.commit_model_response state ~agent_core_turn:1 ~observe;
  check (list string) "failed response clears staged delivery" [] !observations;
  State.stage state ~runtime_id:"runtime-success" ~agent_core_turn:2
    [ wire_receipt "call-skill" ];
  State.commit_model_response state ~agent_core_turn:2 ~observe;
  check (list string) "successful response commits staged runtime"
    [ "runtime-success" ] !observations;
  check (list string) "successful response activates exact id"
    [ "call-skill" ] (State.active state);
  State.stage state ~runtime_id:"runtime-error" ~agent_core_turn:3
    [ wire_receipt "call-skill" ];
  State.commit_model_response state ~agent_core_turn:3 ~observe:(fun _ -> []);
  check (list string) "failed observer leaves no stale active id"
    [] (State.active state)
;;

let test_first_round_cross_turn_replay_stays_inactive () =
  let module State = Masc.Keeper_run_tools_hooks.Skill_delivery_state in
  let state = State.create () in
  let observer_calls = ref 0 in
  State.begin_turn state;
  State.stage state ~runtime_id:"runtime-next-turn" ~agent_core_turn:1
    [ wire_receipt "call-from-previous-turn" ];
  State.commit_model_response state ~agent_core_turn:1
    ~observe:(fun _staged ->
      incr observer_calls;
      (* The durable ledger observer filters this exact id because its
         activation Turn_ref belongs to the preceding outer turn. *)
      []);
  check int "first response reaches the delivery observer" 1 !observer_calls;
  check (list string) "replayed result activates no Skill id" []
    (State.active state)
;;

let test_runtime_attempt_clears_previous_runtime_delivery () =
  let module State = Masc.Keeper_run_tools_hooks.Skill_delivery_state in
  let state = State.create () in
  State.stage state ~runtime_id:"runtime-a" ~agent_core_turn:1
    [ wire_receipt "call-skill" ];
  State.commit_model_response state ~agent_core_turn:1
    ~observe:(fun staged ->
      List.map
        (fun (receipt : Masc.Keeper_skill_activation_ledger.tool_result_receipt) ->
           receipt.tool_use_id)
        staged.tool_results);
  check (list string) "runtime A activates its delivered Skill"
    [ "call-skill" ] (State.active state);
  State.stage state ~runtime_id:"runtime-a" ~agent_core_turn:2
    [ wire_receipt "pending-a" ];
  State.begin_runtime_attempt state;
  check (list string) "runtime B inherits no active Skill" [] (State.active state);
  let observed = ref false in
  State.commit_model_response state ~agent_core_turn:2
    ~observe:(fun _ -> observed := true; [ "pending-a" ]);
  check bool "runtime B inherits no pending delivery" false !observed
;;

(* ── adopt_projection_meta: projection adoption keeps the TOML profile ──

   #31178 drift, observer site. The registry projection is durable keeper
   JSON: it cannot carry the TOML-owned fields, so its decoder fills
   [sandbox_profile] with a placeholder (docker as of #32078). Adopting the
   projection whole is what dispatched a microvm keeper's Execute to the
   host docker daemon (lane-smith, 2026-09-01). The post-tool observer
   re-applies the TOML the turn was admitted with. Docker below stands in
   for whatever the decoder placeholder is: the assertion is about which
   side wins, not about the placeholder's value. *)

let drift_defaults sandbox =
  { Keeper_types_profile.empty_keeper_profile_defaults with
    manifest_path = Some "keepers/drift.toml"
  ; sandbox_profile = sandbox
  }
;;

let profile_label =
  Keeper_types_profile_sandbox.sandbox_profile_to_string
;;

let test_projection_adoption_keeps_admitted_toml_profile () =
  let admitted =
    make_meta ~sandbox_profile:Keeper_types_profile_sandbox.Micro_vm "drift"
  in
  let projection =
    make_meta ~sandbox_profile:Keeper_types_profile_sandbox.Docker "drift"
  in
  let adopted =
    Masc.Keeper_run_tools_hooks.adopt_projection_meta
      ~profile_defaults:
        (drift_defaults (Some Keeper_types_profile_sandbox.Micro_vm))
      ~admitted ~projection
  in
  check string "adopted keeps the TOML microvm profile"
    (profile_label Keeper_types_profile_sandbox.Micro_vm)
    (profile_label adopted.sandbox_profile)
;;

let test_projection_adoption_without_a_toml_profile_keeps_admitted () =
  let admitted =
    make_meta ~sandbox_profile:Keeper_types_profile_sandbox.Micro_vm "drift"
  in
  let projection =
    make_meta ~sandbox_profile:Keeper_types_profile_sandbox.Docker "drift"
  in
  let adopted =
    Masc.Keeper_run_tools_hooks.adopt_projection_meta
      ~profile_defaults:(drift_defaults None)
      ~admitted ~projection
  in
  check string "keeps the admitted profile when the TOML declares none"
    (profile_label Keeper_types_profile_sandbox.Micro_vm)
    (profile_label adopted.sandbox_profile)
;;

let test_projection_adoption_follows_the_toml_when_it_declares_docker () =
  let admitted =
    make_meta ~sandbox_profile:Keeper_types_profile_sandbox.Micro_vm "drift"
  in
  let projection =
    make_meta ~sandbox_profile:Keeper_types_profile_sandbox.Docker "drift"
  in
  let adopted =
    Masc.Keeper_run_tools_hooks.adopt_projection_meta
      ~profile_defaults:(drift_defaults (Some Keeper_types_profile_sandbox.Docker))
      ~admitted ~projection
  in
  check string "follows the TOML profile when it declares docker"
    (profile_label Keeper_types_profile_sandbox.Docker)
    (profile_label adopted.sandbox_profile)
;;

let test_projection_adoption_preserves_durable_projection_fields () =
  let admitted =
    make_meta ~sandbox_profile:Keeper_types_profile_sandbox.Micro_vm "drift"
  in
  (* paused and the usage counters are durable projection fields: the
     overlay must carry them through. Without this pin, "re-apply the TOML"
     could silently widen into "always keep the admitted meta" and every
     case above would still pass while the observer stopped reflecting
     the projection at all. *)
  let projection =
    let base =
      make_meta ~sandbox_profile:Keeper_types_profile_sandbox.Docker "drift"
    in
    { base with
      Masc.Keeper_meta_contract.paused = true
    ; Masc.Keeper_meta_contract.runtime =
        { base.runtime with
          usage =
            { base.runtime.usage with last_total_tokens = 12345 }
        }
    }
  in
  let adopted =
    Masc.Keeper_run_tools_hooks.adopt_projection_meta
      ~profile_defaults:
        (drift_defaults (Some Keeper_types_profile_sandbox.Micro_vm))
      ~admitted ~projection
  in
  check bool "adopted keeps the projection's paused flag" true
    adopted.paused;
  check int "adopted keeps the projection's usage counters" 12345
    adopted.runtime.usage.last_total_tokens
;;

let () =
  run
    "keeper_run_tools_hooks"
    [ ( "post_tool_round"
      , [ test_case
            "the predicate is positional, not containment"
            `Quick
            test_ends_with_tool_results_is_positional
        ; test_case
            "a first round survives a replayed tool tail"
            `Quick
            test_first_round_survives_a_replayed_tool_tail
        ] )
    ; ( "observation_file_path"
      , [ test_case
            "explicit cwd scopes relative file_path"
            `Quick
            test_explicit_cwd_scopes_relative_file_path
        ; test_case
            "scratch path anchors at cwd like any relative path"
            `Quick
            test_scratch_path_anchors_at_cwd_like_any_relative_path
        ; test_case
            "sandbox-rooted file_path ignores cwd"
            `Quick
            test_sandbox_rooted_file_path_ignores_cwd
        ; test_case "absolute path ignores cwd" `Quick test_absolute_path_ignores_cwd
        ; test_case
            "absolute cwd scopes relative file_path"
            `Quick
            test_absolute_cwd_scopes_relative_file_path
        ; test_case
            "bare relative path anchors at sandbox root"
            `Quick
            test_bare_relative_path_anchors_at_sandbox_root
        ; test_case "blank path falls back to file_path" `Quick
            test_blank_path_falls_back_to_file_path
        ; test_case "path priority matches IDE helper" `Quick
            test_path_priority_matches_ide_helper
        ; test_case "nested arguments path is observed" `Quick
            test_nested_arguments_path_is_observed
        ; test_case "nested arguments relative path uses cwd" `Quick
            test_nested_arguments_relative_path_uses_cwd
        ; test_case "paths list uses first string path" `Quick
            test_paths_list_uses_first_string_path
        ; test_case "files list uses first object file_path" `Quick
            test_files_list_uses_first_object_file_path
        ; test_case "missing path falls back to base_path" `Quick
            test_missing_path_falls_back_to_base_path
        ] )
    ; ( "gate_history_slice"
      , [ test_case "captures only request-local causal fields" `Quick
            test_gate_causal_initial_is_request_local
        ; test_case "keeps the newest messages within the budget" `Quick
            test_gate_history_keeps_newest_within_budget
        ; test_case "short history is passed through whole" `Quick
            test_gate_history_short_history_is_whole
        ; test_case "drops a tool result whose call fell outside" `Quick
            test_gate_history_drops_orphan_tool_result
        ] )
    ; ( "completed_tool_calls_evidence"
      , [ test_case "tool payloads never reach the judge" `Quick
            test_tool_payload_is_never_rendered
        ; test_case "disposition survives for every call" `Quick
            test_disposition_survives_for_every_call
        ; test_case "both evidence axes share one budget" `Quick
            test_completed_calls_share_the_history_budget
        ; test_case "the budget still bounds a large input" `Quick
            test_budget_still_bounds_a_large_input
        ; test_case "short call list is passed through whole" `Quick
            test_completed_calls_short_list_is_whole
        ] )
    ; ( "observation_partition"
      , [ test_case
            "pathless call names no document"
            `Quick
            test_partition_resolution_leaves_pathless_calls_without_a_document
        ; test_case
            "uses project root when config base is .masc"
            `Quick
            test_partition_resolution_uses_project_root_for_masc_base_path
        ; test_case
            "annotate uses its input code address"
            `Quick
            test_annotate_uses_input_code_address_without_sandbox_resolution
        ; test_case
            "unregistered playground repo fails with its repo id"
            `Quick
            test_partition_unregistered_playground_repo_fails_with_repo_id
        ; test_case
            "Docker visible absolute path maps to playground repo"
            `Quick
            test_partition_docker_visible_path_maps_to_playground_repo
        ; test_case
            "bare relative outside repos lane is an unregistered path"
            `Quick
            test_partition_bare_relative_outside_repos_is_unregistered_path
        ] )
    ; ( "concurrent_tool_observer"
      , [ test_case
            "commits receipt and activity as one transaction"
            `Quick
            test_concurrent_tool_observers_commit_as_transactions
        ; test_case
            "releases the next completion after a reported failure"
            `Quick
            test_failed_tool_observer_releases_next_completion
        ; test_case
            "production hook cancellation releases the next completion"
            `Quick
            test_production_post_tool_hook_cancellation_releases_next_completion
        ] )
    ; ( "rejected_tool_calls"
      , [ test_case
            "a call refused before execution leaves a row"
            `Quick
            test_a_rejected_call_leaves_a_row
        ; test_case
            "an executed failure is not written twice"
            `Quick
            test_an_executed_failure_is_not_written_twice
        ; test_case
            "validation callback follows exact log commit"
            `Quick
            test_validation_rejection_notifies_after_exact_log_commit
        ] )
    ; ( "Skill delivery observation"
      , [ test_case
            "keeps exact trailing ToolResult ids"
            `Quick
            test_trailing_tool_results_keep_exact_receipts
        ; test_case
            "requires serialization and successful response"
            `Quick
            test_skill_delivery_requires_serialization_and_success_response
        ; test_case
            "first-round cross-turn replay stays inactive"
            `Quick
            test_first_round_cross_turn_replay_stays_inactive
        ; test_case
            "runtime failover clears previous delivery"
            `Quick
            test_runtime_attempt_clears_previous_runtime_delivery
        ] )
    ; ( "projection adoption"
      , [ test_case
            "keeps the admitted TOML profile over the decoder placeholder"
            `Quick
            test_projection_adoption_keeps_admitted_toml_profile
        ; test_case
            "keeps the admitted profile when the TOML declares none"
            `Quick
            test_projection_adoption_without_a_toml_profile_keeps_admitted
        ; test_case
            "follows the TOML profile when it declares docker"
            `Quick
            test_projection_adoption_follows_the_toml_when_it_declares_docker
        ; test_case
            "keeps the projection's durable fields while re-applying the TOML"
            `Quick
            test_projection_adoption_preserves_durable_projection_fields
        ] )
    ]
;;
