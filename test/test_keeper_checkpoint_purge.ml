(* Deterministic offline checkpoint purge. These tests pin the
   rule contract, and above all that a purge keeps every atom and the last one
   byte-exact: four stores count in atoms, and a purge that renumbered them
   left goo-yang-bong sending its whole 16 MB history on every turn
   (2026-09-22). *)

module Purge = Masc.Keeper_checkpoint_purge
module Types = Agent_core.Types
module Keeper_transcript_unit = Masc.Keeper_transcript_unit
module Writer = Masc.Keeper_turn_log_writer

let text_message role text : Types.message =
  { origin = Llm_provider.Types.Conversation;  role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }

let block_message role content : Types.message =
  { origin = Llm_provider.Types.Conversation;  role; content; name = None; tool_call_id = None; metadata = [] }

let tool_use id : Types.content_block =
  Types.ToolUse { id; name = "test_tool"; input = `Assoc [ "id", `String id ] }

let tool_result ?(content = "raw tool output") id : Types.content_block =
  Types.ToolResult
    { tool_use_id = id
    ; content
    ; outcome = Types.Tool_succeeded
    ; json = Some (`Assoc [ "ok", `Bool true ])
    ; content_blocks = None
    }

let cycle id =
  [ block_message Types.Assistant [ tool_use id ]
  ; { (block_message Types.Tool [ tool_result id ]) with tool_call_id = Some id }
  ]

let tool_error_result ?(content = "raw tool error") id : Types.content_block =
  Types.ToolResult
    { tool_use_id = id
    ; content
    ; outcome =
        Types.Tool_failed
          { failure_kind = Types.Recoverable_tool_error; error_class = None }
    ; json = Some (`Assoc [ "error", `String "boom" ])
    ; content_blocks = None
    }

let error_cycle id =
  [ block_message Types.Assistant [ tool_use id ]
  ; { (block_message Types.Tool [ tool_error_result id ]) with tool_call_id = Some id }
  ]

let unsigned_thinking text : Types.content_block =
  Types.Thinking { content = text; signature = None }

let signed_thinking text : Types.content_block =
  Types.Thinking { content = text; signature = Some "sig" }

(* Trailing distinct filler so the interesting prefix sits outside the
   protected tail without disabling the tail protection itself. *)
let filler n =
  List.init n (fun i -> text_message Types.User (Printf.sprintf "filler-%d" i))

let no_tail_config = { Purge.default_config with keep_recent_messages = 0 }

(* A purge with no boundary log, no Librarian working state and no turn log:
   only the history's own end names a message. *)
let purge_plain ~config messages =
  Purge.purge_messages
    ~config
    ~trace_id:"trace-purge-plain"
    ~boundary_lines:[]
    ~continuity:None
    ~named:Writer.No_log
    messages

let purge_checkpoint ~config (checkpoint : Agent_core.Checkpoint.t) =
  Purge.purge
    ~config
    ~trace_id:checkpoint.session_id
    ~boundary_lines:[]
    ~continuity:None
    ~named:Writer.No_log
    checkpoint

let run ?(config = no_tail_config) messages =
  match purge_plain ~config messages with
  | Ok result -> result
  | Error _ -> Alcotest.fail "purge rejected a structurally valid fixture"

let message_texts messages =
  List.map
    (fun (m : Types.message) ->
       String.concat
         "|"
         (List.map
            (function
              | Types.Text t -> t
              | Types.Thinking _ -> "<thinking>"
              | Types.ToolUse { id; _ } -> "use:" ^ id
              | Types.ToolResult { tool_use_id; content; _ } ->
                "result:" ^ tool_use_id ^ ":" ^ content
              | _ -> "<other>")
            m.content))
    messages

(* The shape goo-yang-bong's history had: the same wake cue opening turn after
   turn, and replies that were nothing but unsigned reasoning. Every one of
   them opens an atom, so every one stays. *)
let test_repeated_messages_all_survive () =
  let wake = text_message Types.User "(autonomous wake)" in
  let messages =
    [ wake
    ; text_message Types.Assistant "reply-a"
    ; wake
    ; block_message Types.Assistant [ unsigned_thinking "only reasoning" ]
    ; wake
    ; text_message Types.Assistant "reply-b"
    ; wake
    ; wake
    ]
  in
  let purged, _report = run messages in
  Alcotest.(check (list string))
    "every message survives, in order"
    [ "(autonomous wake)"
    ; "reply-a"
    ; "(autonomous wake)"
    ; "<thinking>"
    ; "(autonomous wake)"
    ; "reply-b"
    ; "(autonomous wake)"
    ; "(autonomous wake)"
    ]
    (message_texts purged)

let test_reasoning_strip_scope () =
  let messages =
    [ block_message Types.Assistant [ unsigned_thinking "t1"; Types.Text "answer" ]
    ; block_message Types.Assistant [ unsigned_thinking "t2" ]
    ; block_message Types.Assistant [ signed_thinking "t3"; Types.Text "signed" ]
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int) "unsigned block stripped beside text" 1
    report.reasoning_blocks_stripped;
  Alcotest.(check (list string))
    "text survives; a reasoning-only reply and signed thinking are untouched"
    [ "answer"; "<thinking>"; "<thinking>|signed" ]
    (message_texts purged)

(* Contract change: R2 used to skip any message carrying a ToolUse, so the
   assistant message that opens a tool cycle kept its unsigned reasoning. On an
   agentic keeper that is almost every assistant message — measured on the
   that checkpoint, 418 of 422 surviving unsigned Thinking blocks (490,370 B,
   41.0% of the file) were held by this rule. Unsigned reasoning carries no
   signature to replay, so the exemption bought nothing. *)
let test_unsigned_reasoning_inside_tool_cycle_is_stripped () =
  (* The trailing turn keeps the cycle out of the last atom, which is always
     returned byte-exact. *)
  let messages =
    [ block_message Types.Assistant [ unsigned_thinking "pre-tool"; tool_use "a" ]
    ; { (block_message Types.Tool [ tool_result "a" ]) with tool_call_id = Some "a" }
    ; text_message Types.User "after"
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int)
    "unsigned reasoning is stripped even beside a tool_use"
    1
    report.reasoning_blocks_stripped;
  Alcotest.(check int) "no message dropped" 3 (List.length purged);
  (match List.hd purged with
   | { Types.content = [ Types.ToolUse { id; _ } ]; _ } ->
     Alcotest.(check string) "the tool_use itself survives" "a" id
   | other ->
     Alcotest.failf
       "expected a lone surviving ToolUse, got %s"
       (Types.show_message other))

(* The safety line the old guard was reaching for, pinned where it belongs:
   per block, by signature — not per message, by "has a tool_use". *)
let test_signed_reasoning_inside_tool_cycle_is_kept () =
  let messages =
    [ block_message Types.Assistant [ signed_thinking "pre-tool"; tool_use "a" ]
    ; { (block_message Types.Tool [ tool_result "a" ]) with tool_call_id = Some "a" }
    ; text_message Types.User "after"
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int)
    "signed reasoning beside a tool_use is untouched"
    0
    report.reasoning_blocks_stripped;
  Alcotest.(check int) "no message dropped" 3 (List.length purged);
  match List.hd purged with
  | { Types.content = [ Types.Thinking { signature = Some _; _ }; Types.ToolUse _ ]; _ } ->
    ()
  | other ->
    Alcotest.failf
      "signed thinking must replay byte-exact, got %s"
      (Types.show_message other)

(* An assistant progress frame can sit inside an already-open tool cycle
   without carrying either anchor. It opens an atom like any assistant
   message, so a frame that is nothing but unsigned reasoning stays whole
   rather than being emptied or removed. *)
let test_thinking_only_interstitial_cycle_message_is_kept () =
  let messages =
    [ block_message Types.Assistant [ tool_use "a" ]
    ; block_message Types.Assistant [ unsigned_thinking "only-thinking" ]
    ; { (block_message Types.Tool [ tool_result "a" ]) with tool_call_id = Some "a" }
    ; text_message Types.User "after"
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int) "nothing to strip without emptying" 0
    report.reasoning_blocks_stripped;
  Alcotest.(check int) "every message kept" 4 (List.length purged);
  Alcotest.(check (list string)) "the interstitial frame is untouched"
    [ "use:a"; "<thinking>"; "result:a:" ^ Purge.cleared_tool_result_content; "after" ]
    (message_texts purged);
  match Masc.Keeper_transcript_unit.validate purged with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "keeping the interstitial broke tool pairing"

let test_tool_result_clear_preserves_pairing () =
  let messages = cycle "a" @ [ text_message Types.User "after" ] in
  let purged, report = run messages in
  Alcotest.(check int) "one result cleared" 1 report.tool_results_cleared;
  (match List.nth purged 1 with
   | { Types.content = [ Types.ToolResult { tool_use_id; content; json; content_blocks; outcome } ]; _ } ->
     Alcotest.(check string) "pairing id kept" "a" tool_use_id;
     Alcotest.(check string)
       "content replaced by the marker"
       Purge.cleared_tool_result_content
       content;
     Alcotest.(check bool) "json dropped" true (Option.is_none json);
     Alcotest.(check bool) "blocks dropped" true (Option.is_none content_blocks);
     (match outcome with
      | Types.Tool_succeeded -> ()
      | _ -> Alcotest.fail "typed outcome must survive the clear")
   | _ -> Alcotest.fail "cleared cycle lost its ToolResult block");
  match Masc.Keeper_transcript_unit.validate purged with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "cleared cycle no longer validates"

let test_error_tool_result_is_never_cleared () =
  (* R3 clears successful payloads only: an error result is feedback and
     lesson evidence, so its payload, json, and outcome all survive. *)
  let messages = error_cycle "a" @ cycle "b" @ [ text_message Types.User "after" ] in
  let purged, report = run messages in
  Alcotest.(check int)
    "only the successful result is cleared"
    1
    report.tool_results_cleared;
  (match List.nth purged 1 with
   | { Types.content = [ Types.ToolResult { content; json; outcome; _ } ]; _ } ->
     Alcotest.(check string) "error payload survives" "raw tool error" content;
     Alcotest.(check bool) "error json untouched" true (Option.is_some json);
     (match outcome with
      | Types.Tool_failed _ -> ()
      | _ -> Alcotest.fail "error outcome must survive the purge")
   | _ -> Alcotest.fail "error cycle lost its ToolResult block");
  let twice, _ = run purged in
  Alcotest.(check (list string))
    "preserved errors make the second purge the identity too"
    (message_texts purged)
    (message_texts twice)

let test_protected_tail_is_byte_exact () =
  let wake = text_message Types.User "(autonomous wake)" in
  let config = { Purge.default_config with keep_recent_messages = 4 } in
  let tail =
    [ wake
    ; wake
    ; wake
    ; block_message Types.Assistant [ unsigned_thinking "tail"; Types.Text "t" ]
    ]
  in
  let messages = filler 3 @ tail in
  let purged, report = run ~config messages in
  Alcotest.(check int) "tail reasoning survives" 0 report.reasoning_blocks_stripped;
  Alcotest.(check int) "nothing dropped" 7 (List.length purged)

let test_cycle_overlapping_protected_tail_is_untouched () =
  let config = { Purge.default_config with keep_recent_messages = 1 } in
  (* The cycle's final message falls inside the protected tail; the whole
     cycle must be exempt from R3. *)
  let messages = [ text_message Types.User "head" ] @ cycle "a" in
  let _purged, report = run ~config messages in
  Alcotest.(check int) "overlapping cycle not cleared" 0 report.tool_results_cleared

let test_purge_is_idempotent () =
  let wake = text_message Types.User "(autonomous wake)" in
  let reply thinking =
    block_message Types.Assistant [ unsigned_thinking thinking; Types.Text "same answer" ]
  in
  let messages =
    [ wake; wake; wake ]
    @ cycle "a"
    @ [ reply "t1"; reply "t2"; reply "t3" ]
    @ [ wake ]
  in
  let once, _ = run messages in
  let twice, second_report = run once in
  Alcotest.(check (list string))
    "second purge is the identity"
    (message_texts once)
    (message_texts twice);
  Alcotest.(check int)
    "no further reasoning"
    0
    second_report.reasoning_blocks_stripped;
  Alcotest.(check int) "no further clears" 0 second_report.tool_results_cleared

(* Purge is the operator's recovery tool and a broken transcript is what it is
   reached for. Refusing left one move: edit the checkpoint JSON by hand, which
   is what 2026-09-01 came down to. The break is dropped rather than preserved,
   because a preserved break returns a transcript that still cannot be saved
   while reporting success. *)
let test_broken_structure_is_recovered_not_refused () =
  let orphan =
    { (block_message Types.Tool [ tool_result "ghost" ]) with
      tool_call_id = Some "ghost"
    }
  in
  match purge_plain ~config:no_tail_config [ orphan ] with
  | Error (Purge.Invalid_input_structure _) ->
    Alcotest.fail "the recovery tool refused the transcript it exists for"
  | Error _ -> Alcotest.fail "orphan tool_result misclassified"
  | Ok (purged, report) ->
    Alcotest.(check int) "the orphan is gone" 0 (List.length purged);
    Alcotest.(check int)
      "and the cost is reported"
      1
      report.Purge.messages_dropped_at_structural_break

(* The output of a recovery must be saveable, which is the whole point: a
   keeper stuck on a break has to be able to checkpoint again afterwards. *)
let test_recovered_output_is_structurally_sound () =
  (* The live shape: a second tool_use opens while the first cycle is still
     unanswered, which is Overlapping_tool_cycle. Two keepers sat on exactly
     this on 2026-09-01. *)
  let messages =
    cycle "a"
    @ cycle "b"
    @ [ block_message Types.Assistant [ tool_use "c1" ]
      ; block_message Types.Assistant [ tool_use "c2" ]
      ; { (block_message Types.Tool [ tool_result "c1" ]) with
          tool_call_id = Some "c1"
        }
      ; { (block_message Types.Tool [ tool_result "c2" ]) with
          tool_call_id = Some "c2"
        }
      ]
  in
  match purge_plain ~config:no_tail_config messages with
  | Error _ -> Alcotest.fail "the split cycle was refused"
  | Ok (purged, report) ->
    Alcotest.(check bool)
      "the survivors validate"
      true
      (Result.is_ok (Keeper_transcript_unit.validate purged));
    Alcotest.(check bool)
      "and something was dropped to get there"
      true
      (report.Purge.messages_dropped_at_structural_break > 0)

(* A sound transcript keeps its open tail: crash recovery depends on it, and
   this is the path every ordinary purge takes. *)
let test_sound_input_drops_nothing_at_a_break () =
  match purge_plain ~config:no_tail_config (cycle "a" @ cycle "b") with
  | Error _ -> Alcotest.fail "a sound transcript was refused"
  | Ok (_, report) ->
    Alcotest.(check int)
      "nothing dropped at a break there is not"
      0
      report.Purge.messages_dropped_at_structural_break

let test_config_bounds_are_enforced () =
  match
    purge_plain
      ~config:{ no_tail_config with keep_recent_messages = -1 }
      [ text_message Types.User "x" ]
  with
  | Error (Purge.Invalid_config _) -> ()
  | _ -> Alcotest.fail "negative keep_recent_messages was accepted"

let checkpoint_fixture () =
    Agent_core.Checkpoint.
      { provider_binding = None; version = checkpoint_version
      ; session_id = "trace-purge-fixture"
      ; agent_name = "purge-fixture"
      ; model = "test-model"
      ; system_prompt = None
      ; messages =
          [ text_message Types.User "(autonomous wake)"
          ; block_message Types.Assistant [ unsigned_thinking "t"; Types.Text "a" ]
          ; text_message Types.User "(autonomous wake)"
          ; block_message Types.Assistant [ tool_use "x" ]
          ; { (block_message Types.Tool [ tool_result "x" ]) with tool_call_id = Some "x" }
          ; text_message Types.User "(autonomous wake)"
          ]
      ; usage = Types.empty_usage
      ; turn_count = 41
      ; created_at = 1_700_000_000.0
      ; tools = []
      ; tool_choice = None
      ; disable_parallel_tool_use = false
      ; temperature = None
      ; top_p = None
      ; top_k = None
      ; min_p = None
      ; enable_thinking = None
      ; preserve_thinking = None
      ; response_format = Types.Off
      ; reasoning_effort = None
      ; cache_system_prompt = false
      ; context = Agent_core.Context.create_sync ()
      ; pending_input = None
      ; working_context = None
      }

let test_checkpoint_fields_pass_through () =
  let checkpoint = checkpoint_fixture () in
  match purge_checkpoint ~config:no_tail_config checkpoint with
  | Error _ -> Alcotest.fail "checkpoint purge failed"
  | Ok (purged, report) ->
    Alcotest.(check int) "no message removed" report.messages_before
      report.messages_after;
    Alcotest.(check bool) "the fixture gives the purge something to change" true
      (report.reasoning_blocks_stripped > 0 && report.tool_results_cleared > 0);
    Alcotest.(check string)
      "session identity unchanged"
      checkpoint.session_id
      purged.Agent_core.Checkpoint.session_id;
    Alcotest.(check int)
      "turn watermark unchanged"
      checkpoint.turn_count
      purged.Agent_core.Checkpoint.turn_count

let fixture_trace = (checkpoint_fixture ()).Agent_core.Checkpoint.session_id

let rec workspace_contents dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.sort String.compare
  |> List.concat_map (fun name ->
    let path = Filename.concat dir name in
    if Sys.is_directory path then
      (path, None) :: workspace_contents path
    else [ path, Some (In_channel.with_open_bin path In_channel.input_all) ])

let test_cli_workspace ?(linked_worktree = false) () =
  Eio_main.run @@ fun env ->
  let owner_root = Filename.temp_dir "checkpoint-purge-cli-" "" |> Unix.realpath in
  (* An apply takes the workspace writer lease before it reads, so even a
     refused apply leaves the lease file. It sits outside the tree the test
     compares, as the machine's lease directory sits outside a workspace. *)
  let lease_root = Filename.temp_dir "checkpoint-purge-cli-lease-" "" |> Unix.realpath in
  let base_path =
    if not linked_worktree then owner_root
    else
      let main_root = Filename.concat owner_root "main" in
      let worktree_root = Filename.concat owner_root "worktree" in
      Unix.mkdir main_root 0o700;
      Unix.mkdir (Filename.concat main_root ".git") 0o700;
      Unix.mkdir worktree_root 0o700;
      Out_channel.with_open_text (Filename.concat worktree_root ".git") (fun output ->
        Printf.fprintf output "gitdir: %s/.git/worktrees/checkpoint-purge\n" main_root);
      worktree_root
  in
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.remove_tree owner_root;
      Fs_compat.remove_tree lease_root)
    (fun () ->
      Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
      let config = Masc.Workspace.default_config base_path in
      let checkpoint = checkpoint_fixture () in
      let session_dir = Masc.Keeper_fs.keeper_session_dir config checkpoint.session_id in
      let runtime_root = Masc.Workspace.masc_dir config in
      let checkpoint_path =
        Masc.Keeper_checkpoint_store.agent_core_checkpoint_path
          ~session_dir ~session_id:checkpoint.session_id
      in
      (match Masc.Keeper_checkpoint_store.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes
        ~session_dir ~history_retained:0 checkpoint with
       | Ok (Masc.Keeper_checkpoint_store.Saved _) -> ()
       | Ok (Masc.Keeper_checkpoint_store.Stale_noop _) ->
           Alcotest.fail "fixture checkpoint was not saved"
       | Error detail -> Alcotest.failf "fixture checkpoint: %s" detail);
      let original = In_channel.with_open_bin checkpoint_path In_channel.input_all in
      (* The keeper is not the checkpoint's [agent_name]: that field holds the
         agent-core agent's name (the runtime id on a live keeper). The CLI
         finds the keeper's Librarian files by the name the operator passes,
         and its meta names the trace (#37770). *)
      let keeper_name = "purge-cli-keeper" in
      (match
         Masc.Keeper_meta_store.replace_snapshot config
           (match
              Masc_test_deps.meta_of_json_fixture
                (`Assoc [ "name", `String keeper_name; "trace_id", `String checkpoint.session_id ])
            with
            | Ok meta -> meta
            | Error detail -> Alcotest.failf "keeper meta fixture: %s" detail)
       with
       | Ok () -> ()
       | Error detail -> Alcotest.failf "keeper meta: %s" detail);
      let before = workspace_contents owner_root in
      let run_cli
            ?(from_cwd = false) ?(exit_code = 0) ?(reports_checkpoint = true)
            ?(identity = [ "--keeper"; keeper_name ]) args =
        let runtime_base_path =
          Masc.Workspace.runtime_base_path (Masc.Workspace.Explicit base_path)
        in
        let executable =
          Sys.getenv "MASC_TEST_CHECKPOINT_PURGE_EXE"
          |> Config_dir_resolver.absolute_path
        in
        let child_env =
          [ "HOME=" ^ owner_root
          ; "XDG_CONFIG_HOME=" ^ owner_root
          ; "MASC_BASE_PATH_LEASE_DIR=" ^ lease_root
          ]
          @ (if from_cwd then [] else [ "MASC_BASE_PATH=" ^ runtime_base_path ])
        in
        let output =
          Eio.Process.parse_out
            ~cwd:Eio.Path.(Eio.Stdenv.fs env / base_path)
            ~env:(Array.of_list child_env)
            ~is_success:(Int.equal exit_code)
            (Eio.Stdenv.process_mgr env) Eio.Buf_read.take_all
            ([ executable ] @ identity @ [ "--keep-recent"; "0" ] @ args)
        in
        Alcotest.(check bool) "CLI reports the producer checkpoint" reports_checkpoint
          (List.mem ("checkpoint: " ^ checkpoint_path)
             (String.split_on_char '\n' output));
        print_string output;
        output
      in
      let run_cli ?from_cwd ?exit_code ?reports_checkpoint ?identity args =
        let (_ : string) = run_cli ?from_cwd ?exit_code ?reports_checkpoint ?identity args in
        ()
      in
      (* The keeper names the trace; a trace argument only cross-checks it. *)
      run_cli ~exit_code:1 ~reports_checkpoint:false
        ~identity:[ "--trace"; checkpoint.session_id ] [ "--base"; base_path ];
      run_cli ~exit_code:1 ~reports_checkpoint:false
        ~identity:[ "--keeper"; "no-such-keeper" ] [ "--base"; base_path ];
      run_cli ~exit_code:1 ~reports_checkpoint:false
        ~identity:[ "--keeper"; keeper_name; "--trace"; "trace-of-another-keeper" ]
        [ "--base"; base_path ];
      run_cli ~identity:[ "--keeper"; keeper_name; "--trace"; checkpoint.session_id ]
        [ "--base"; base_path ];
      Alcotest.(check (list (pair string (option string))))
        "refused and cross-checked runs leave the workspace unchanged"
        before (workspace_contents owner_root);
      run_cli [ "--base"; base_path ];
      Alcotest.(check (list (pair string (option string))))
        "dry-run leaves all workspace files and directories unchanged"
        before (workspace_contents owner_root);
      run_cli [];
      Alcotest.(check (list (pair string (option string))))
        "MASC_BASE_PATH dry-run uses the same workspace without writes"
        before (workspace_contents owner_root);
      run_cli ~from_cwd:true [];
      Alcotest.(check (list (pair string (option string))))
        "no base or recorded default uses current workspace without writes"
        before (workspace_contents owner_root);
      (* An archive entry of the checkpoint before the purge names the
         content the purge removes; the apply deletes it. *)
      let archived =
        Masc.Keeper_checkpoint_store.agent_core_history_snapshot_id_of_checkpoint
          { checkpoint with created_at = checkpoint.created_at -. 60. }
      in
      Out_channel.with_open_bin (Filename.concat session_dir archived) (fun channel ->
        output_string channel original);
      Alcotest.(check (list string)) "the archive entry is there before the apply" [ archived ]
        (Masc.Keeper_checkpoint_store.list_agent_core_history_files ~session_dir);
      run_cli [ "--base"; base_path; "--apply" ];
      Alcotest.(check (list string)) "the apply leaves no history archive entry" []
        (Masc.Keeper_checkpoint_store.list_agent_core_history_files ~session_dir);
      let backup_dirs =
        Sys.readdir runtime_root |> Array.to_list
        |> List.filter (String.starts_with
             ~prefix:("backups-checkpoint-purge-" ^ checkpoint.session_id ^ "-"))
      in
      let backup_dir = match backup_dirs with
        | [ name ] -> Filename.concat runtime_root name
        | names -> Alcotest.failf "expected one backup in runtime root, got %d"
                     (List.length names)
      in
      let backup = Filename.concat backup_dir (checkpoint.session_id ^ ".json") in
      Alcotest.(check string) "backup preserves every original byte" original
        (In_channel.with_open_bin backup In_channel.input_all);
      (match Masc.Keeper_checkpoint_store.load_agent_core
        ~session_dir ~session_id:checkpoint.session_id with
       | Error _ -> Alcotest.fail "applied checkpoint is not readable"
       | Ok purged ->
           Alcotest.(check int) "actual CLI keeps every message"
             (List.length checkpoint.messages) (List.length purged.messages);
           Alcotest.(check bool) "and rewrote something" true
             (Agent_core.Checkpoint.to_string purged
              <> Agent_core.Checkpoint.to_string checkpoint);
           Alcotest.(check int) "apply preserves turn watermark" checkpoint.turn_count
             purged.turn_count;
           Alcotest.(check string) "apply preserves session identity" checkpoint.session_id
             purged.session_id);
      Alcotest.(check bool) "a keeper with no turn log is purged without starting one" false
        (Sys.file_exists
           (Masc.Keeper_turn_log_store.path_for_keepers_dir
              ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
              ~keeper_id:keeper_name)))

(* RFC librarian-call-only-proposes §5.2, §5.6 at the CLI: a recovery closes
   the open messages, writes the Keeper's turn log line, then installs. A line
   that is not written leaves the history whole. *)
let test_cli_recovery_writes_the_turn_log_line () =
  Eio_main.run
  @@ fun env ->
  let owner_root = Filename.temp_dir "checkpoint-purge-recovery-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree owner_root)
  @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None
  @@ fun () ->
  let config = Masc.Workspace.default_config owner_root in
  let keeper_name = "purge-cli-recovery" in
  let trace = "trace-purge-recovery" in
  (* Overlapping tool cycles after one sound cycle: Overlapping_tool_cycle. *)
  let kept = text_message Types.User "(autonomous wake)" :: cycle "a" in
  let messages =
    kept
    @ [ block_message Types.Assistant [ tool_use "c1" ]
      ; block_message Types.Assistant [ tool_use "c2" ]
      ; { (block_message Types.Tool [ tool_result "c1" ]) with tool_call_id = Some "c1" }
      ; { (block_message Types.Tool [ tool_result "c2" ]) with tool_call_id = Some "c2" }
      ]
  in
  let session_dir = Masc.Keeper_fs.keeper_session_dir config trace in
  let canonical =
    Masc.Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:trace
  in
  (* The normal save refuses the break, so the head is written as a corrupt
     one sits on disk: saved mid-turn, every message open. *)
  ignore
    (Masc_test_deps.write_checkpoint_head ~boundary:Agent_core.Checkpoint_objects.Turn_continues
       ~session_dir ~path:canonical
       { (checkpoint_fixture ()) with Agent_core.Checkpoint.session_id = trace; messages }
     : string);
  (match
     Masc_test_deps.meta_of_json_fixture
       (`Assoc [ "name", `String keeper_name; "trace_id", `String trace ])
   with
   | Error detail -> Alcotest.failf "keeper meta fixture: %s" detail
   | Ok meta ->
     (match Masc.Keeper_meta_store.replace_snapshot config meta with
      | Ok () -> ()
      | Error detail -> Alcotest.failf "keeper meta: %s" detail));
  let keepers_dir = Masc.Workspace.keepers_runtime_dir config in
  (match
     Masc.Keeper_turn_log_recorder.record ~at:1.0
       ~new_log_id:(Masc.Keeper_turn_log.Log_id.fresh ())
       { keepers_dir
       ; base_path = config.Masc.Workspace.base_path
       ; keeper_name
       ; session_dir
       ; session_id = trace
       }
       Masc.Keeper_turn_log_writer.Process_start
   with
   | Ok (Masc.Keeper_turn_log_recorder.Appended _) -> ()
   | Ok Nothing_to_append -> Alcotest.fail "the log had started already"
   | Error error -> Alcotest.fail (Masc.Keeper_turn_log_recorder.not_recorded_to_string error));
  let log_path = Masc.Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name in
  let log_text () =
    String.split_on_char '\n' (Fs_compat.load_file log_path)
    |> List.filter (fun row -> not (String.equal row ""))
    |> List.map (fun row ->
      match Masc.Keeper_turn_log_codec.of_json (Yojson.Safe.from_string row) with
      | Ok (Log_started { mark; _ }) -> Printf.sprintf "started at %d" mark.closed_messages
      | Ok (Reset { cause = Announced Recovered; before; after; closed_before; _ }) ->
        Printf.sprintf "reset recovered %d to %d, naming %d" before.closed_messages
          after.closed_messages
          (List.fold_left
             (fun count (slice : Masc.Keeper_turn_log.slice) -> count + slice.take)
             0 closed_before)
      | Ok (Opened _ | Closed _ | Reset _) -> "another line"
      | Error error -> Alcotest.fail (Masc.Keeper_memory_os_types.wire_error_to_string error))
    |> String.concat "\n"
  in
  let head () =
    match Masc.Keeper_turn_log_head.read ~session_dir ~session_id:trace with
    | Ok head -> head
    | Error error ->
      Alcotest.fail (Masc.Keeper_checkpoint_store_session.checkpoint_load_error_to_string error)
  in
  let backups () =
    Sys.readdir (Masc.Workspace.masc_dir config)
    |> Array.to_list
    |> List.filter (String.starts_with ~prefix:("backups-checkpoint-purge-" ^ trace ^ "-"))
  in
  let apply ~exit_code =
    let runtime_base_path =
      Masc.Workspace.runtime_base_path (Masc.Workspace.Explicit owner_root)
    in
    let output =
      Eio.Process.parse_out
        ~cwd:Eio.Path.(Eio.Stdenv.fs env / owner_root)
        ~env:
          [| "HOME=" ^ owner_root
           ; "XDG_CONFIG_HOME=" ^ owner_root
           ; "MASC_BASE_PATH_LEASE_DIR=" ^ owner_root
           ; "MASC_BASE_PATH=" ^ runtime_base_path
          |]
        ~is_success:(Int.equal exit_code)
        (Eio.Stdenv.process_mgr env) Eio.Buf_read.take_all
        [ Sys.getenv "MASC_TEST_CHECKPOINT_PURGE_EXE" |> Config_dir_resolver.absolute_path
        ; "--keeper"; keeper_name; "--keep-recent"; "0"; "--base"; owner_root; "--apply"
        ]
    in
    print_string output
  in
  let started = Fs_compat.load_file log_path in
  Fs_compat.save_file log_path (started ^ "not a line\n");
  apply ~exit_code:1;
  Alcotest.(check int) "a turn log it cannot read leaves every message"
    (List.length messages)
    ((head ()).closed_messages + (head ()).open_messages);
  Alcotest.(check (list string)) "and backs nothing up" [] (backups ());
  Fs_compat.save_file log_path started;
  apply ~exit_code:0;
  Alcotest.(check string) "the line names every message, the open ones too"
    (Printf.sprintf "started at 0\nreset recovered %d to %d, naming %d" (List.length messages)
       (List.length kept) (List.length messages))
    (log_text ());
  Alcotest.(check int) "the head ends where the line says" (List.length kept)
    (head ()).closed_messages;
  Alcotest.(check int) "with nothing open" 0 (head ()).open_messages;
  Alcotest.(check int) "the source was backed up" 1 (List.length (backups ()))
;;

let purge_with ?(named = Writer.No_log) ~boundary_lines ~continuity messages =
  match
    Purge.purge_messages
      ~config:no_tail_config
      ~trace_id:fixture_trace
      ~boundary_lines
      ~continuity
      ~named
      messages
  with
  | Ok result -> result
  | Error error -> Alcotest.fail (Purge.purge_error_to_string error)
;;

(* A recovery drops the broken tail, so the last atom it keeps is the last
   one it returns, not the one the input ended on. *)
let test_recovery_keeps_the_last_atom_it_returns () =
  let last_kept =
    block_message Types.Assistant [ unsigned_thinking "before the break"; Types.Text "kept" ]
  in
  let messages =
    [ text_message Types.User "q"
    ; block_message Types.Assistant [ unsigned_thinking "earlier"; Types.Text "a" ]
    ; text_message Types.User "(autonomous wake)"
    ; last_kept
    ; block_message Types.Assistant [ tool_use "c1" ]
    ; block_message Types.Assistant [ tool_use "c2" ]
    ; { (block_message Types.Tool [ tool_result "c1" ]) with tool_call_id = Some "c1" }
    ; { (block_message Types.Tool [ tool_result "c2" ]) with tool_call_id = Some "c2" }
    ]
  in
  match purge_plain ~config:no_tail_config messages with
  | Error error -> Alcotest.fail (Purge.purge_error_to_string error)
  | Ok (purged, report) ->
    Alcotest.(check bool) "the break was dropped" true
      (report.messages_dropped_at_structural_break > 0);
    Alcotest.(check string) "the last atom it returns opens exactly as before"
      (Types.show_message last_kept)
      (Types.show_message (List.nth purged (List.length purged - 1)));
    Alcotest.(check int) "the earlier reply is still stripped" 1
      report.reasoning_blocks_stripped
;;

(* A second tool_use opens while the first is unanswered: the break a
   recovery drops, and everything after it. *)
let overlapping_cycles () =
  [ block_message Types.Assistant [ tool_use "c1" ]
  ; block_message Types.Assistant [ tool_use "c2" ]
  ; { (block_message Types.Tool [ tool_result "c1" ]) with tool_call_id = Some "c1" }
  ; { (block_message Types.Tool [ tool_result "c2" ]) with tool_call_id = Some "c2" }
  ]
;;

(* RFC librarian-call-only-proposes §5.6. A Keeper's Memory writer reads the
   messages past the last unit's mark from the head, so a purge that drops
   nothing leaves them byte-exact and rewrites only the ones below it. *)
let test_a_purge_rewrites_only_what_the_turn_log_named () =
  let turn reasoning tool_id reply =
    [ text_message Types.User "(autonomous wake)"
    ; block_message Types.Assistant [ unsigned_thinking reasoning; tool_use tool_id ]
    ; { (block_message Types.Tool [ tool_result tool_id ]) with tool_call_id = Some tool_id }
    ; block_message Types.Assistant [ Types.Text reply ]
    ]
  in
  let named_turn = turn "read" "a" "one" in
  let unread_turn = turn "not read yet" "b" "two" in
  let messages = named_turn @ unread_turn in
  let purge named = purge_with ~named ~boundary_lines:[] ~continuity:None messages in
  let shown messages = List.map Types.show_message messages in
  let purged, report = purge (Writer.Named_below (List.length named_turn)) in
  Alcotest.(check (list string)) "the turn past the mark goes out as it is"
    (shown unread_turn)
    (shown (List.filteri (fun index _ -> index >= List.length named_turn) purged));
  Alcotest.(check (pair int int)) "and the named turn is purged" (1, 1)
    (report.reasoning_blocks_stripped, report.tool_results_cleared);
  let at_the_start, _ = purge (Writer.Named_below 0) in
  Alcotest.(check (list string)) "a mark at the head's start keeps every message"
    (shown messages) (shown at_the_start);
  let _, without_a_log = purge Writer.No_log in
  Alcotest.(check (pair int int)) "with no turn log both turns are purged" (2, 2)
    (without_a_log.reasoning_blocks_stripped, without_a_log.tool_results_cleared)
;;

(* A recovery's [Reset] line names everything the head holds before the tail
   goes, so the mark holds nothing back: the history a recovery keeps is
   purged as a history with no turn log is. *)
let test_a_recovery_rewrites_past_the_mark () =
  let messages =
    [ text_message Types.User "q1"
    ; block_message Types.Assistant [ unsigned_thinking "t1"; Types.Text "a1" ]
    ; text_message Types.User "q2"
    ; block_message Types.Assistant [ Types.Text "a2" ]
    ]
    @ overlapping_cycles ()
  in
  let recovered, report =
    purge_with ~named:(Writer.Named_below 0) ~boundary_lines:[] ~continuity:None messages
  in
  Alcotest.(check int) "the break is dropped" (List.length (overlapping_cycles ()))
    report.messages_dropped_at_structural_break;
  Alcotest.(check int) "what it keeps ends where the break began" 4 (List.length recovered);
  Alcotest.(check int) "and the reply below the mark is stripped" 1
    report.reasoning_blocks_stripped
;;

(* The protected tail is the last [keep_recent_messages] messages of the
   history the recovery returns, not of the input it cut. *)
let test_recovery_protects_the_tail_of_what_it_returns () =
  let reply_in_the_tail =
    block_message Types.Assistant [ unsigned_thinking "t1"; Types.Text "a1" ]
  in
  let messages =
    [ text_message Types.User "q1"
    ; reply_in_the_tail
    ; text_message Types.User "q2"
    ; block_message Types.Assistant [ Types.Text "a2" ]
    ]
    @ overlapping_cycles ()
  in
  match purge_plain ~config:{ no_tail_config with keep_recent_messages = 3 } messages with
  | Error error -> Alcotest.fail (Purge.purge_error_to_string error)
  | Ok (purged, report) ->
    Alcotest.(check string) "the reply inside the tail is byte-exact"
      (Types.show_message reply_in_the_tail)
      (Types.show_message (List.nth purged 1));
    Alcotest.(check int) "nothing in the returned tail is stripped" 0
      report.Purge.reasoning_blocks_stripped
;;

let test_purge_rebases_repetition_history_on_resume () =
  let module Judged = Masc.Keeper_repetition_judged in
  let checkpoint = checkpoint_fixture () in
  let checkpoint = { checkpoint with
    messages = [text_message Types.User "first"] @ cycle "kept"
      @ [text_message Types.User "broken"] @ overlapping_cycles () } in
  let original : Judged.t =
    { history_generation = Judged.Initial; history_pairs = 3
    ; ledger_frontier = Keeper_tool_call_index.empty_frontier } in
  Judged.record checkpoint.context original;
  let live = Agent_core.Context.copy checkpoint.context in
  let purged = match purge_checkpoint ~config:no_tail_config checkpoint with
    | Ok (purged, report) ->
      Alcotest.(check bool) "recovery actually shortened history" true
        (report.messages_dropped_at_structural_break > 0);
      purged
    | Error error -> Alcotest.fail (Purge.purge_error_to_string error) in
  let restored = match Agent_core.Checkpoint.of_string (Agent_core.Checkpoint.to_string purged) with
    | Ok checkpoint -> checkpoint
    | Error error -> Alcotest.fail (Agent_core.Error.to_string error) in
  let boundary = match Judged.restore ~source:restored.context ~target:live with
    | Ok boundary -> boundary
    | Error error -> Alcotest.fail (Judged.error_to_string error) in
  Alcotest.(check int) "old live count cannot hide rewritten pairs" 0 boundary.history_pairs;
  Alcotest.(check bool) "rewrite generation survives serialization" true
    (match boundary.history_generation with Judged.Rewritten _ -> true | Initial -> false);
  Alcotest.(check bool) "preview never changed the source context" true
    (Judged.read checkpoint.context = Ok original);
  (* History rewrite coordinates still round-trip for explicit history-clear
     and checkpoint-purge ownership; they no longer gate provider dispatch. *)
  Judged.record live { boundary with history_pairs = 2 };
  let next = match Judged.restore ~source:restored.context ~target:live with
    | Ok boundary -> boundary
    | Error error -> Alcotest.fail (Judged.error_to_string error) in
  Alcotest.(check int) "same generation preserves live judged progress" 2 next.history_pairs
;;

let () =
  Alcotest.run
    "keeper checkpoint purge"
    [ ( "repetition resume", [ Alcotest.test_case "purge carries the new history generation"
          `Quick test_purge_rebases_repetition_history_on_resume ] )
    ; ( "atoms"
      , [ Alcotest.test_case
            "repeated messages all survive"
            `Quick
            test_repeated_messages_all_survive
        ; Alcotest.test_case
            "recovery keeps the last atom it returns"
            `Quick
            test_recovery_keeps_the_last_atom_it_returns
        ; Alcotest.test_case
            "recovery protects the tail of what it returns"
            `Quick
            test_recovery_protects_the_tail_of_what_it_returns
        ] )
    ; ( "rules"
      , [ Alcotest.test_case "reasoning strip scope" `Quick test_reasoning_strip_scope
        ; Alcotest.test_case
            "unsigned reasoning inside a tool cycle is stripped"
            `Quick
            test_unsigned_reasoning_inside_tool_cycle_is_stripped
        ; Alcotest.test_case
            "signed reasoning inside a tool cycle is kept"
            `Quick
            test_signed_reasoning_inside_tool_cycle_is_kept
        ; Alcotest.test_case
            "a thinking-only interstitial cycle message is kept"
            `Quick
            test_thinking_only_interstitial_cycle_message_is_kept
        ; Alcotest.test_case
            "tool result clear preserves pairing"
            `Quick
            test_tool_result_clear_preserves_pairing
        ; Alcotest.test_case
            "error tool result is never cleared"
            `Quick
            test_error_tool_result_is_never_cleared
        ] )
    ; ( "boundaries"
      , [ Alcotest.test_case
            "protected tail is byte exact"
            `Quick
            test_protected_tail_is_byte_exact
        ; Alcotest.test_case
            "cycle overlapping the tail is untouched"
            `Quick
            test_cycle_overlapping_protected_tail_is_untouched
        ; Alcotest.test_case "purge is idempotent" `Quick test_purge_is_idempotent
        ; Alcotest.test_case
            "broken structure is recovered, not refused"
            `Quick
            test_broken_structure_is_recovered_not_refused
        ; Alcotest.test_case
            "recovered output is structurally sound"
            `Quick
            test_recovered_output_is_structurally_sound
        ; Alcotest.test_case
            "sound input drops nothing at a break"
            `Quick
            test_sound_input_drops_nothing_at_a_break
        ; Alcotest.test_case
            "config bounds are enforced"
            `Quick
            test_config_bounds_are_enforced
        ; Alcotest.test_case
            "checkpoint fields pass through"
            `Quick
            test_checkpoint_fields_pass_through
        ] )
    ; ( "turn log (RFC librarian-call-only-proposes §5.6)"
      , [ Alcotest.test_case
            "a purge rewrites only what the turn log named"
            `Quick
            test_a_purge_rewrites_only_what_the_turn_log_named
        ; Alcotest.test_case
            "a recovery rewrites past the mark"
            `Quick
            test_a_recovery_rewrites_past_the_mark
        ] )
    ; ( "cli"
      , [ Alcotest.test_case "workspace dry-run and apply" `Quick
            (fun () -> test_cli_workspace ())
        ; Alcotest.test_case "linked worktree: shared runtime dry-run and apply" `Quick
            (fun () -> test_cli_workspace ~linked_worktree:true ())
        ; Alcotest.test_case "a recovery writes the turn log line" `Quick
            test_cli_recovery_writes_the_turn_log_line
        ] )
    ]
