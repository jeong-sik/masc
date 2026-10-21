(** RFC-0225 §3.2: stale AGENT_CORE checkpoint writes are a disk-SSOT no-op.

    Two writers for the same session are last-writer-wins on disk; the
    2026-06-10 voice incident had a stale lane (turn_count=1324) clobber
    the conversation the newer lane had just saved (turn_count=1355).
    [Keeper_checkpoint_store.save_agent_core_classified] skips a save whose [turn_count] is older
    than the canonical checkpoint observed inside the save transaction, without
    turning that watermark hit into keeper lifecycle failure.

    The canonical file is read whole under the stable session lock for every
    admission decision and hashed against the reference the candidate claims to
    advance; a file whose hash differs is then parsed, because the refusal
    names the reference that file now carries. No process-local cache,
    fingerprint, or sidecar may substitute for reading those bytes. The
    canonical file is written in compact JSON. *)

open Alcotest
open Masc

(* What the operator's window currently says. The store takes the window as an
   argument -- it is reachable from a raw Domain, where reading a setting
   raises -- so every caller names it. These cases are not about the window and
   pass what production passes. *)
let history_retained () =
  Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained

let () =
  Server_startup_state.mark_state_ready ()
  |> Result.get_ok

let temp_dir () =
  let root = Filename.temp_file "test_ckpt_stale_guard_" "" in
  Unix.unlink root;
  Unix.mkdir root 0o755;
  let session_dir = Filename.concat root "session" in
  Unix.mkdir session_dir 0o755;
  session_dir

let ensure_fs env = Fs_compat.set_fs (Eio.Stdenv.fs env)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm (Filename.dirname dir) with _ -> ()

let make_checkpoint ~session_id ~turn_count ~marker =
  let messages = [
    Agent_core.Types.{ role = User; content = [Text "hello"]; name = None;
                      tool_call_id = None; metadata = [] };
    Agent_core.Types.{ role = Assistant; content = [Text marker]; name = None;
                      tool_call_id = None; metadata = [] };
  ] in
  Agent_core.Checkpoint.{
    version = checkpoint_version;
    session_id;
    agent_name = "test-agent";
    model = "test-model";
    system_prompt = None;
    messages;
    usage = Agent_core.Types.empty_usage;
    turn_count;
    created_at = 1000.0;
    tools = [];
    tool_choice = None;
    disable_parallel_tool_use = false;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    reasoning_effort = None;
    enable_thinking = None;
    preserve_thinking = None;
    response_format = Agent_core.Types.Off;
    cache_system_prompt = false;

    context = Agent_core.Context.create_sync ();
    pending_input = None; mcp_sessions = [];
    working_context = None;
  }

let save_ok ~session_dir ckpt label =
  match Keeper_checkpoint_store.save_agent_core_classified
    ~history_retained:(history_retained ()) ~session_dir ckpt with
  | Ok _ -> ()
  | Error e -> fail (label ^ " unexpectedly failed: " ^ e)

(* Three writers reach this store. Only one ran the structural check first --
   the mid-run sink and finalize assemble a checkpoint directly and called the
   store straight -- so a history with an orphan tool result was admitted by
   the two hottest paths and reloaded later (#25561). The check now lives at
   the boundary all three pass through. *)
let checkpoint_with_orphan_tool_result ~session_id =
  let messages =
    [ Agent_core.Types.
        { role = User
        ; content = [ Text "hello" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      (* A result for a tool call that was never requested. *)
    ; Agent_core.Types.
        { role = Tool
        ; content = [ ToolResult { tool_use_id = "tu-never-requested"; content = "x"; outcome = Tool_succeeded; json = None; content_blocks = None } ]
        ; name = None
        ; tool_call_id = Some "tu-never-requested"
        ; metadata = []
        }
    ]
  in
  { (make_checkpoint ~session_id ~turn_count:1 ~marker:"orphan") with
    Agent_core.Checkpoint.messages
  }
;;

let test_structurally_invalid_checkpoint_is_refused_at_the_store () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "structural-guard" in
  match
    Keeper_checkpoint_store.save_agent_core_classified
      ~history_retained:(history_retained ())
      ~session_dir
      (checkpoint_with_orphan_tool_result ~session_id:sid)
  with
  | Ok _ -> fail "a checkpoint with an orphan tool result must not be saved"
  | Error message ->
    check
      bool
      "the refusal names the structural contract"
      true
      (let needle = "structurally invalid" in
       let n = String.length needle in
       let rec at i =
         i + n <= String.length message
         && (String.equal (String.sub message i n) needle || at (i + 1))
       in
       at 0);
    (* Nothing was written: a refused checkpoint must not leave a partial file
       the next load would read. *)
    let path =
      Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid
    in
    check bool "no checkpoint file was created" false (Sys.file_exists path)
;;

(* #31677: a provider-authored tool_use input with a duplicate object key
   survives parsing (Yojson keeps both entries) and then refuses canonical
   encoding at the sink. Before the recovery copy, that refusal repeated at
   the same stage of every later turn — one degenerate generation bricked
   the keeper until restart. *)
let checkpoint_with_unencodable_tool_use ~session_id =
  let messages =
    [ Agent_core.Types.
        { role = User
        ; content = [ Text "run it" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
    ; Agent_core.Types.
        { role = Assistant
        ; content =
            [ ToolUse
                { id = "call-1"
                ; name = "Execute"
                ; input = `Assoc [ ("cmd", `String "a"); ("cmd", `String "b") ]
                }
            ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
    ]
  in
  { (make_checkpoint ~session_id ~turn_count:1 ~marker:"poisoned") with
    Agent_core.Checkpoint.messages
  }
;;

let test_unencodable_payload_is_recovered_at_the_sink () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "sink-recovery" in
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid in
  match
    Keeper_checkpoint_store.save_agent_core_classified
      ~history_retained:(history_retained ())
      ~session_dir
      (checkpoint_with_unencodable_tool_use ~session_id:sid)
  with
  | Error message -> fail ("the sink should have stored the recovery copy: " ^ message)
  | Ok _ ->
    check bool "the recovery copy was written" true (Sys.file_exists path);
    let bytes = Fs_compat.load_file path in
    (match Agent_core.Checkpoint.of_string bytes with
     | Ok loaded ->
       (* The call itself survives; only the unencodable args became empty. *)
       (match loaded.Agent_core.Checkpoint.messages with
        | _ :: { Agent_core.Types.content = [ ToolUse { id; input; _ } ]; _ } :: _ ->
          check string "the tool call id survives" "call-1" id;
          check bool "the duplicate-key input became an empty object" true
            (input = `Assoc [])
        | messages -> failf "expected the poisoned assistant message, got %d" (List.length messages))
     | Error error ->
       fail ("the stored recovery copy must decode: " ^ Agent_core.Error.to_string error))
;;

(* 한 파일의 저장은 저장소가 그 파일에 둔 encoding memo 하나를 같이 쓴다. 저장마다
   같은 레코드 뒤에 메시지가 붙고, 마지막 저장은 복구가 필요한 payload 를 붙인다. 매번
   canonical 파일은 memo 없이 인코딩한 바이트와 같아야 한다. *)
let test_stage_saves_sharing_one_memo_write_canonical_bytes () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "stage-saves-memo" in
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid in
  let append (cp : Agent_core.Checkpoint.t) ~turn_count messages =
    { cp with Agent_core.Checkpoint.turn_count; messages = cp.messages @ messages }
  in
  let text role body : Agent_core.Types.message =
    { role; content = [ Agent_core.Types.Text body ]; name = None; tool_call_id = None; metadata = [] }
  in
  let first = make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"stage one" in
  let second = append first ~turn_count:2 [ text Agent_core.Types.User "stage two" ] in
  let third = append second ~turn_count:3 [ text Agent_core.Types.Assistant "stage three" ] in
  let poisoned =
    append
      third
      ~turn_count:4
      (checkpoint_with_unencodable_tool_use ~session_id:sid).Agent_core.Checkpoint.messages
  in
  let save label (cp : Agent_core.Checkpoint.t) expected =
    match
      Keeper_checkpoint_store.save_agent_core_classified
        ~history_retained:(history_retained ())
        ~session_dir
        cp
    with
    | Error message -> fail (label ^ ": " ^ message)
    | Ok _ -> check string label (Agent_core.Checkpoint.to_string expected) (Fs_compat.load_file path)
  in
  save "first stage" first first;
  save "second stage" second second;
  save "third stage" third third;
  match Agent_core.Checkpoint.drop_unencodable_json poisoned with
  | None -> fail "the poisoned checkpoint has a droppable payload"
  | Some recovered -> save "a save that needs the recovery copy" poisoned recovered
;;

let test_valid_checkpoint_still_saves () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "structural-guard-ok" in
  save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"ok") "valid save";
  let path =
    Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid
  in
  check bool "a valid checkpoint is written" true (Sys.file_exists path)
;;

let test_run_context_binds_generation_before_agent_core_checkpoint () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Eio.Switch.on_release sw (fun () -> cleanup_dir base_dir);
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String "generation-context" ])
    with
    | Ok meta -> meta
    | Error detail -> fail ("meta fixture failed: " ^ detail)
  in
  let shared_context = Agent_core.Context.create () in
  let run_context =
    Keeper_run_context.prepare_run_context
      ~config:(Workspace.default_config base_dir)
      ~meta
      ~profile_defaults:Keeper_types_profile_defaults.empty_keeper_profile_defaults
      ~base_dir
      ~runtime_id:"unconfigured-test-runtime"
      ~shared_context
      ()
    |> function
    | Ok context -> context
    | Error (Keeper_run_context.Checkpoint_unread error) ->
      fail (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
    | Error (Keeper_run_context.Constitution_unreadable error) ->
      fail (World_constitution_store.read_error_to_string error)
    | Error (Keeper_run_context.Prompt_unrenderable detail) ->
      fail ("unexpected prompt failure: " ^ detail)
  in
  check bool "caller-owned context remains the AGENT_CORE context" true
    (run_context.shared_context == shared_context);
  let agent =
    Agent_core.Agent.create
      ~net:(Eio.Stdenv.net env)
      ~config:(Agent_core.Types.default_config ~model:"test-model")
      ~context:run_context.shared_context
      ()
  in
  let (_ : Agent_core.Checkpoint.t) = Agent_core.Agent.checkpoint agent in
  ()

let test_forward_equal_and_stale () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let sid = "sess-guard" in
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:5 ~marker:"v5") "fresh save";
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:6 ~marker:"v6") "forward save";
    (* Equal turn_count: idempotent re-save (e.g. sanitized retry). *)
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:6 ~marker:"v6b") "equal save";
    (* Stale write must be a nonfatal no-op and must not touch disk. *)
    (match
       Keeper_checkpoint_store.save_agent_core_classified
         ~history_retained:(history_retained ()) ~session_dir
         (make_checkpoint ~session_id:sid ~turn_count:4 ~marker:"v4-stale")
     with
     | Ok (Keeper_checkpoint_store.Stale_noop
              { incoming_turn_count; known_turn_count }) ->
       check int "stale incoming turn_count" 4 incoming_turn_count;
       check int "known turn_count is preserved" 6 known_turn_count
     | Ok (Keeper_checkpoint_store.Saved _) ->
       fail "stale save advanced the checkpoint"
     | Error e -> fail ("stale save returned lifecycle failure: " ^ e));
    match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:sid with
    | Ok on_disk ->
      check int "disk keeps the newest turn_count" 6
        on_disk.Agent_core.Checkpoint.turn_count
    | Error _ -> fail "load after rejection failed")

(* The canonical checkpoint file is the only durable admission watermark
   (RFC-0225 §3.2). *)
let test_disk_is_the_watermark_ssot () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let sid = "sess-cold" in
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:8 ~marker:"v8") "seed save";
    (match
       Keeper_checkpoint_store.save_agent_core_classified
         ~history_retained:(history_retained ()) ~session_dir
         (make_checkpoint ~session_id:sid ~turn_count:3 ~marker:"v3-stale")
     with
     | Ok (Keeper_checkpoint_store.Stale_noop
              { incoming_turn_count; known_turn_count }) ->
       check int "cold stale incoming turn_count" 3 incoming_turn_count;
       check int "cold known turn_count backfilled from disk" 8 known_turn_count
     | Ok (Keeper_checkpoint_store.Saved _) ->
       fail "stale save advanced after cold start"
    | Error e -> fail ("cold stale save returned lifecycle failure: " ^ e));
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:9 ~marker:"v9")
      "forward save from disk SSOT")

let test_externally_replaced_canonical_is_the_watermark () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-external-write" in
    let canonical_path =
      Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id
    in
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:5 ~marker:"v5")
      "seed save";
    Fs_compat.save_file canonical_path
      (make_checkpoint ~session_id ~turn_count:9 ~marker:"external-v9"
       |> Agent_core.Checkpoint.to_string);
    match
      Keeper_checkpoint_store.save_agent_core_classified
        ~history_retained:(history_retained ()) ~session_dir
        (make_checkpoint ~session_id ~turn_count:7 ~marker:"stale-v7")
    with
    | Ok
        (Keeper_checkpoint_store.Stale_noop
           { incoming_turn_count; known_turn_count }) ->
      check int "external replacement makes turn 7 stale" 7 incoming_turn_count;
      check int "canonical replacement is the known watermark" 9 known_turn_count
    | Ok (Keeper_checkpoint_store.Saved _) ->
      fail "stale save ignored an externally replaced canonical checkpoint"
    | Error error -> fail ("external replacement classification failed: " ^ error))

(* A version bump leaves the old canonical on disk: the load refuses it and the
   keeper starts fresh, and nothing deletes the file. The save has to replace
   it, or every turn after the bump fails the same way and the keeper cannot
   checkpoint again until someone removes it by hand. A canonical from a
   *later* version is the opposite case and still refuses. *)
let with_canonical_at_version ~session_dir ~session_id ~version =
  let canonical_path =
    Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id
  in
  let json =
    make_checkpoint ~session_id ~turn_count:9 ~marker:"before-the-bump"
    |> Agent_core.Checkpoint.to_json
  in
  let rewritten =
    match json with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             if String.equal key "version" then key, `Int version else key, value)
           fields)
    | other -> other
  in
  Fs_compat.save_file canonical_path (Yojson.Safe.to_string rewritten);
  canonical_path

let test_superseded_canonical_is_replaced () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-superseded" in
    let canonical_path =
      with_canonical_at_version ~session_dir ~session_id
        ~version:(Agent_core.Checkpoint.checkpoint_version - 1)
    in
    (match
       Keeper_checkpoint_store.save_agent_core_classified
         ~history_retained:(history_retained ()) ~session_dir
         (make_checkpoint ~session_id ~turn_count:1 ~marker:"after-the-bump")
     with
     | Ok (Keeper_checkpoint_store.Saved _) -> ()
     | Ok (Keeper_checkpoint_store.Stale_noop _) ->
       fail "a superseded canonical was treated as a newer watermark"
     | Error error ->
       fail ("a superseded canonical blocked the save: " ^ error));
    match
      Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id
    with
    | Ok reloaded ->
      check int "the replacement carries the current version"
        Agent_core.Checkpoint.checkpoint_version reloaded.version;
      check int "the replacement is this turn's checkpoint" 1 reloaded.turn_count
    | Error error ->
      ignore canonical_path;
      fail
        ("the replacement did not load back: "
         ^ Keeper_checkpoint_store.checkpoint_load_error_to_string error))

let test_newer_canonical_is_not_replaced () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-newer" in
    let canonical_path =
      with_canonical_at_version ~session_dir ~session_id
        ~version:(Agent_core.Checkpoint.checkpoint_version + 1)
    in
    let before = Fs_compat.load_file canonical_path in
    (match
       Keeper_checkpoint_store.save_agent_core_classified
         ~history_retained:(history_retained ()) ~session_dir
         (make_checkpoint ~session_id ~turn_count:1 ~marker:"older-binary")
     with
     | Ok _ -> fail "an older binary overwrote a newer canonical"
     | Error _ -> ());
    check bool "the newer canonical is untouched" true
      (String.equal before (Fs_compat.load_file canonical_path)))

let with_run_checkpoint f =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
  @@ fun () ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) @@ fun () ->
  let meta =
    match Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "read-error-context" ]) with
    | Ok meta -> meta
    | Error detail -> fail detail
  in
  let session_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let session_dir = Filename.concat base_dir session_id in
  Fs_compat.mkdir_p session_dir;
  let checkpoint = make_checkpoint ~session_id ~turn_count:1 ~marker:"saved memory" in
  save_ok ~session_dir checkpoint "seed young Keeper history";
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id in
  let config = Workspace.default_config base_dir in
  let prepare ?checkpoint () =
    Keeper_run_context.prepare_run_context ~config ~meta
      ~profile_defaults:Keeper_types_profile_defaults.empty_keeper_profile_defaults
      ~base_dir ~runtime_id:"unconfigured-test-runtime" ?checkpoint ()
  in
  f ~config ~meta ~base_dir ~session_dir ~checkpoint ~path ~prepare
;;

let prepare_error_to_string = function
  | Keeper_run_context.Checkpoint_unread error ->
    Keeper_checkpoint_store.checkpoint_load_error_to_string error
  | Keeper_run_context.Constitution_unreadable error ->
    World_constitution_store.read_error_to_string error
  | Keeper_run_context.Prompt_unrenderable detail -> detail
;;

(* Raw file edits can break an already registered slot. The override API
   refuses these values before they reach the turn, so the fixture edits an
   isolated keeper.md after first preparing successfully. It never changes
   the override table, and restores the original directory after the case. *)
let test_unrenderable_prompt_refuses_preparation_typed ~key ~body ~worldview () =
  with_run_checkpoint
  @@ fun ~config ~meta ~base_dir ~session_dir:_ ~checkpoint ~path ~prepare ->
  let original_dir =
    match Prompt_registry.get_markdown_dir () with
    | Some dir -> dir
    | None -> fail "the prompt refusal fixture needs the shipped prompt directory"
  in
  let original_overrides = Prompt_registry.override_entries () in
  let prompt_dir = Filename.concat base_dir "prompt-fixture" in
  Fs_compat.mkdir_p prompt_dir;
  let prompt_path = Filename.concat prompt_dir "keeper.md" in
  let valid_body = "Shared Keeper fixture contract" in
  let valid_worldview = "World fixture contract" in
  let write body worldview =
    Fs_compat.save_file prompt_path
      (Printf.sprintf
         {|---
description: Keeper refusal fixture
---
%s

### worldview
%s

### identity (vars: keeper_name)
<identity>{{keeper_name}}</identity>

### workspace (vars: workspace_root)
<workspace>{{workspace_root}}</workspace>

### tags.system_open
<system>

### tags.system_close
</system>

### tags.instructions_open
<instructions>

### tags.instructions_close
</instructions>
|}
         body worldview)
  in
  let require_prepared () =
    match prepare () with
    | Error error -> fail (prepare_error_to_string error)
    | Ok ctx ->
      check int "preparation retains the saved turn count" 1 ctx.start_turn_count;
      check bool "preparation retains the saved messages" true
        (Keeper_context_runtime.messages_of_context ctx.ctx_work = checkpoint.messages);
      ctx
  in
  write valid_body valid_worldview;
  Fun.protect
    ~finally:(fun () -> Prompt_registry.set_markdown_dir original_dir)
    (fun () ->
      Prompt_registry.set_markdown_dir prompt_dir;
      ignore (require_prepared ());
      let original_checkpoint = Fs_compat.load_file path in
      write body worldview;
      let resolved = Prompt_registry.resolve_prompt key in
      check (option string) "the edited file is not shadowed by an override"
        None resolved.override_value;
      let detail =
        match prepare () with
        | Ok _ -> fail "preparation admitted an unrenderable prompt"
        | Error (Keeper_run_context.Prompt_unrenderable detail) ->
          check bool "the refusal names the edited slot" true
            (String_util.contains_substring detail key);
          detail
        | Error error -> fail ("wrong refusal: " ^ prepare_error_to_string error)
      in
      let prompt_built = ref false in
      let settlement =
        Keeper_agent_run.run_turn ~approval_admission:Keeper_approval_origin.Unavailable ~config ~meta ~base_dir
          ~publication_recovery:
            { Keeper_publication_recovery_availability.provider =
                Keeper_publication_recovery_availability.non_runtime_provider
            ; keeper_name = meta.name }
          ~profile_defaults:Keeper_types_profile_defaults.empty_keeper_profile_defaults
          ~turn_ctx_cell:(Keeper_tool_call_log.create_turn_ctx_cell ())
          ~max_context:4096
          ~build_turn_prompt:(fun ~base_system_prompt:_ ~messages:_ ->
            prompt_built := true;
            fail "an invalid shared prompt reached model prompt construction")
          ~user_message:"continue the saved work"
          ~input_speaker:(Keeper_input_speaker.Person Keeper_input_speaker.Owner)
          ~turn_kind:Turn_record.Direct
          ~skill_snapshot:(Skill_catalog_snapshot.config_unreadable ~detail:"unused fixture")
          ~task_skill_selection:(Ok Keeper_task_skill_turn.empty)
          ~runtime_id:"unconfigured-test-runtime" ()
      in
      (match settlement.Keeper_agent_run.result with
       | Error (Agent_core.Error.Config (InvalidConfig { field; detail = reported })) ->
         check string "typed prompt refusal" "keeper.prompt" field;
         check string "the diagnosed cause survives" detail reported
       | Error error -> fail (Agent_core.Error.to_string error)
       | Ok _ -> fail "an unrenderable prompt allowed a turn");
      check bool "no model prompt or dispatch was reached" false !prompt_built;
      check string "refusal preserves saved checkpoint bytes" original_checkpoint
        (Fs_compat.load_file path);
      write valid_body valid_worldview;
      let resumed = require_prepared () in
      check bool "the next preparation reads the repaired primary slot" true
        (String_util.contains_substring resumed.base_system_prompt valid_body);
      check string "repair preparation also preserves checkpoint bytes"
        original_checkpoint (Fs_compat.load_file path));
  check (option string) "the prompt directory is restored" (Some original_dir)
    (Prompt_registry.get_markdown_dir ());
  check bool "other prompt overrides are untouched" true
    (original_overrides = Prompt_registry.override_entries ())
;;

(* The same young Keeper has a valid history before and after a failed read.
   A rejected owned-file read models a temporary filesystem fault without
   relying on process privileges or a race. The production turn entrypoint
   must return before building a prompt or reaching a checkpoint writer. *)
let test_checkpoint_read_error_stops_turn ~io_failure () =
  with_run_checkpoint
  @@ fun ~config ~meta ~base_dir ~session_dir ~checkpoint ~path ~prepare ->
  let original = Fs_compat.load_file path in
  let held = path ^ ".held" in
  if io_failure then (
    Unix.rename path held;
    Unix.symlink held path)
  else Fs_compat.save_file path "{ unreadable checkpoint";
  let unread_bytes = Fs_compat.load_file path in
  let expected_error =
    match Keeper_checkpoint_store.load_agent_core ~session_dir
      ~session_id:checkpoint.session_id with
    | Error (Keeper_checkpoint_store.Io_error _ as error) when io_failure -> error
    | Error (Keeper_checkpoint_store.Parse_error _ as error) when not io_failure -> error
    | Error error -> fail (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
    | Ok _ -> fail "fixture did not cause a checkpoint read error"
  in
  let prompt_built = ref false in
  let result =
    Keeper_agent_run.run_turn ~approval_admission:Keeper_approval_origin.Unavailable ~config ~meta ~base_dir
      ~publication_recovery:
        { Keeper_publication_recovery_availability.provider =
            Keeper_publication_recovery_availability.non_runtime_provider
        ; keeper_name = meta.name }
      ~profile_defaults:Keeper_types_profile_defaults.empty_keeper_profile_defaults
      ~turn_ctx_cell:(Keeper_tool_call_log.create_turn_ctx_cell ())
      ~max_context:4096
      ~build_turn_prompt:(fun ~base_system_prompt:_ ~messages:_ ->
        prompt_built := true;
        fail "a failed checkpoint read reached prompt construction")
      ~user_message:"continue the saved work"
      ~input_speaker:(Keeper_input_speaker.Person Keeper_input_speaker.Owner)
      ~turn_kind:Turn_record.Direct
      ~skill_snapshot:(Skill_catalog_snapshot.config_unreadable ~detail:"unused fixture")
      ~task_skill_selection:(Ok Keeper_task_skill_turn.empty)
      ~runtime_id:"unconfigured-test-runtime" ()
  in
  let result = result.Keeper_agent_run.result in
  (match result with
   | Error (Agent_core.Error.Io (FileOpFailed { op; path = failed_path; detail })) ->
     check string "the failed operation is a checkpoint load" "load checkpoint" op;
     check string "the failure names the canonical file" path failed_path;
     check string "the store's diagnosed cause survives"
       (Keeper_checkpoint_store.checkpoint_load_error_to_string expected_error) detail
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok _ -> fail "an unreadable checkpoint allowed a turn");
  check bool "no prompt or model turn ran" false !prompt_built;
  check string "the failed turn did not overwrite the saved file" unread_bytes
    (Fs_compat.load_file path);
  if io_failure then (Unix.unlink path; Unix.rename held path)
  else Fs_compat.save_file path original;
  match prepare () with
  | Error error -> fail (prepare_error_to_string error)
  | Ok ctx ->
    check int "the next tick resumes the original turn count" 1 ctx.start_turn_count;
    check bool "the next tick keeps the original messages" true
      (Keeper_context_runtime.messages_of_context ctx.ctx_work = checkpoint.messages)
;;

(* #38354. A constitution ledger that exists but cannot be read stops the turn
   on the same not-dispatched path as an unreadable checkpoint: no prompt is
   built, so none is sent without the world's articles. Nothing is recorded
   against the ledger, so the next tick after it reads again prepares
   normally, with the articles in its prompt. *)
let test_unreadable_constitution_stops_turn_and_the_next_tick_resumes () =
  with_run_checkpoint
  @@ fun ~config ~meta ~base_dir ~session_dir:_ ~checkpoint:_ ~path:_ ~prepare ->
  let base_path = config.Workspace.base_path in
  let ledger = World_constitution_store.ledger_path ~base_path in
  Fs_compat.mkdir_p ledger;
  let prompt_built = ref false in
  let settlement =
    Keeper_agent_run.run_turn ~approval_admission:Keeper_approval_origin.Unavailable ~config ~meta ~base_dir
      ~publication_recovery:
        { Keeper_publication_recovery_availability.provider =
            Keeper_publication_recovery_availability.non_runtime_provider
        ; keeper_name = meta.name }
      ~profile_defaults:Keeper_types_profile_defaults.empty_keeper_profile_defaults
      ~turn_ctx_cell:(Keeper_tool_call_log.create_turn_ctx_cell ())
      ~max_context:4096
      ~build_turn_prompt:(fun ~base_system_prompt:_ ~messages:_ ->
        prompt_built := true;
        fail "an unreadable constitution reached prompt construction")
      ~user_message:"continue the saved work"
      ~input_speaker:(Keeper_input_speaker.Person Keeper_input_speaker.Owner)
      ~turn_kind:Turn_record.Direct
      ~skill_snapshot:(Skill_catalog_snapshot.config_unreadable ~detail:"unused fixture")
      ~task_skill_selection:(Ok Keeper_task_skill_turn.empty)
      ~runtime_id:"unconfigured-test-runtime" ()
  in
  (match settlement.Keeper_agent_run.result with
   | Error (Agent_core.Error.Io (FileOpFailed { op; path = failed_path; detail = _ })) ->
     check string "the failed operation is the constitution read"
       "load constitution ledger" op;
     check string "the failure names the ledger" ledger failed_path
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok _ -> fail "an unreadable constitution allowed a turn");
  check bool "no prompt or model turn ran" false !prompt_built;
  Unix.rmdir ledger;
  let article = "open before you record" in
  let written =
    match
      World_constitution_types.make
        ~id:(World_constitution_types.Article_id.generate ())
        ~text:article ~author:meta.name ~at:0.0 ~evidence:[]
    with
    | Ok written -> written
    | Error invalid -> fail (World_constitution_types.invalid_to_string invalid)
  in
  (match
     World_constitution_store.append_at ~base_path ~expected_end_offset:0
       (World_constitution_types.Added written)
   with
   | Ok () -> ()
   | Error error -> fail (World_constitution_store.append_error_to_string error));
  let carries text =
    let n = String.length text and m = String.length article in
    let rec scan i =
      i + m <= n && (String.equal (String.sub text i m) article || scan (i + 1))
    in
    scan 0
  in
  match prepare () with
  | Error error -> fail (prepare_error_to_string error)
  | Ok ctx ->
    check bool "the next tick's prompt carries the article" true
      (carries ctx.base_system_prompt)
;;

(* #38354: an autonomous turn sends the base prompt the run context built, not
   a second render. Whatever the caller's callback returns lands in the
   dynamic context only. *)
let test_autonomous_turn_sends_the_run_context_base_prompt () =
  with_run_checkpoint
  @@ fun ~config ~meta ~base_dir:_ ~session_dir:_ ~checkpoint:_ ~path:_ ~prepare ->
  match prepare () with
  | Error error -> fail (prepare_error_to_string error)
  | Ok ctx ->
    let world_state = "## Current World State\nfixture frame" in
    let prompt_ctx =
      Keeper_run_prompt.build_turn_context ~ctx
        ~build_turn_prompt:(fun ~base_system_prompt:_ ~messages:_ ->
          { Keeper_agent_prompt_metrics.dynamic_context = world_state
          ; dynamic_context_for_tools = None })
        ~user_message:"Continue."
        ~input_metadata:
          (Keeper_input_speaker.metadata
             (Keeper_input_speaker.Host_prompt
                (Keeper_input_speaker.Autonomous_wake { answered_asks = [] })))
        ~config ~meta
        ~turn_ref:
          (Ids.Turn_ref.make
             ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
             ~absolute_turn:2)
        ~history_user_source:"autonomous"
        ~user_turn_record:Keeper_run_prompt.Skip_already_checkpointed_user_turn
        ~start_turn_count:ctx.start_turn_count
    in
    check string "the request's system prompt is the run context's base prompt"
      ctx.base_system_prompt prompt_ctx.Keeper_run_prompt.turn_system_prompt;
    check string "the callback's text rides the dynamic context"
      world_state prompt_ctx.Keeper_run_prompt.dynamic_context
;;

let test_unreadable_path_is_not_an_absent_checkpoint () =
  with_run_checkpoint
  @@ fun ~config:_ ~meta:_ ~base_dir:_ ~session_dir:_ ~checkpoint:_ ~path ~prepare ->
  let held = path ^ ".held" in
  Unix.rename path held;
  Unix.symlink (path ^ ".missing") path;
  (match prepare () with
   | Error (Keeper_run_context.Checkpoint_unread (Keeper_checkpoint_store.Io_error _)) -> ()
   | Error error -> fail (prepare_error_to_string error)
   | Ok _ -> fail "a failed path lookup was treated as an absent checkpoint");
  check bool "the unreadable canonical path was not replaced" true
    ((Unix.lstat path).Unix.st_kind = Unix.S_LNK);
  Unix.unlink path;
  Unix.rename held path
;;

let test_superseded_context_can_start_fresh () =
  with_run_checkpoint
  @@ fun ~config:_ ~meta:_ ~base_dir:_ ~session_dir ~checkpoint ~path ~prepare ->
  let (_ : string) = with_canonical_at_version ~session_dir
      ~session_id:checkpoint.session_id
      ~version:(Agent_core.Checkpoint.checkpoint_version - 1) in
  let original = Fs_compat.load_file path in
  match prepare () with
  | Error error -> fail (prepare_error_to_string error)
  | Ok ctx ->
    check int "the deliberate version cut starts fresh" 0 ctx.start_turn_count;
    check bool "restart evidence follows the first accepted save" true
      (ctx.saved_history = Keeper_run_context.Saved_history_superseded);
    check string "preparation alone does not replace the old checkpoint" original
      (Fs_compat.load_file path)
;;

let test_admitted_checkpoint_is_the_run_history_source () =
  with_run_checkpoint
  @@ fun ~config:_ ~meta:_ ~base_dir:_ ~session_dir:_ ~checkpoint ~path ~prepare ->
  Fs_compat.save_file path "{ unreadable checkpoint";
  match prepare ~checkpoint () with
  | Error error -> fail (prepare_error_to_string error)
  | Ok ctx ->
    check int "the admitted continuation retains its turn count" 1 ctx.start_turn_count;
    check bool "the admitted continuation supplies its full history" true
      (Keeper_context_runtime.messages_of_context ctx.ctx_work = checkpoint.messages);
    check string "preparation does not write the canonical file" "{ unreadable checkpoint"
      (Fs_compat.load_file path)
;;

(* The AGENT_CORE per-turn pipeline builds checkpoints with an empty session_id (the
   AGENT_CORE agent carries no session field). The keeper sink stamps a validated,
   non-empty trace_id before persisting; the store fails loud on an empty
   session_id rather than letting the non-Eio fallback silently write
   "<session_dir>/.json" and drop the checkpoint. *)
let test_empty_session_id_rejected () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    (match
       Keeper_checkpoint_store.save_agent_core_classified
         ~history_retained:(history_retained ()) ~session_dir
         (make_checkpoint ~session_id:"" ~turn_count:1 ~marker:"empty")
     with
     | Ok _ -> fail "checkpoint store accepted an empty session_id"
     | Error msg ->
       let expected =
         match Keeper_id.Trace_id.of_string "" with
         | Ok _ -> fail "Trace_id parser accepted an empty identifier"
         | Error reason -> reason
       in
       check string "error is the typed trace-id rejection" expected msg);
    (* The silent non-Eio fallback would have written "<session_dir>/.json". *)
    check bool "no orphan .json written for empty session_id" false
      (Sys.file_exists (Filename.concat session_dir ".json"));
    (* A stamped, non-empty session_id persists and round-trips. *)
    save_ok ~session_dir
      (make_checkpoint ~session_id:"trace-1-0000a" ~turn_count:1 ~marker:"stamped")
      "stamped save";
    match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:"trace-1-0000a" with
    | Ok on_disk ->
      check string "round-trips the stamped session_id" "trace-1-0000a"
        on_disk.Agent_core.Checkpoint.session_id
    | Error _ -> fail "load after stamped save failed")

(* Issue #25077 item 1: [canonical_session_location] is the containment
   boundary shared by the lock file, the history archive, and every
   checkpoint path. A leaf that is not one real path segment (".." / ".")
   must be refused before any filesystem side effect, and a symlink leaf
   must be refused before the lock is derived: either would relocate
   lock/checkpoint writes outside the session root that the
   [Keeper_fs] ownership containment protects on the write chain. *)
let test_session_leaf_containment () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  let base = Filename.dirname session_dir in
  let target = Filename.concat base "elsewhere" in
  let link = Filename.concat base "session-link" in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.unlink link with Unix.Unix_error _ -> ());
      cleanup_dir target;
      cleanup_dir session_dir)
    (fun () ->
      let reject label dir =
        match
          Keeper_checkpoint_store.with_session_lock ~session_dir:dir
            (fun _ -> ())
        with
        | Ok () -> fail (label ^ ": escaping session_dir was accepted")
        | Error _ -> ()
      in
      (* Exact typed rejection for the ".." leaf pins the boundary error. *)
      (match
         Keeper_checkpoint_store.with_session_lock
           ~session_dir:(Filename.concat base Filename.parent_dir_name)
           (fun _ -> ())
       with
       | Ok () -> fail "'..' leaf: escaping session_dir was accepted"
       | Error msg ->
         check string "'..' leaf is the typed leaf rejection"
           (Printf.sprintf
              "checkpoint session directory rejected: leaf %S of %S is not \
               a real path segment"
              Filename.parent_dir_name
              (Filename.concat base Filename.parent_dir_name))
           msg);
      reject "'.' leaf" (Filename.concat base Filename.current_dir_name);
      reject "NUL leaf" (Filename.concat base "abc\000def");
      (* A symlink leaf would redirect every checkpoint and lock write
         through its target. *)
      Unix.mkdir target 0o755;
      Unix.symlink target link;
      reject "symlink leaf" link;
      (* The genuine session directory still passes the same boundary. *)
      match
        Keeper_checkpoint_store.with_session_lock ~session_dir (fun _ -> ())
      with
      | Ok () -> ()
      | Error e -> fail ("real session leaf rejected: " ^ e))

(* Issue #25077: history snapshot ids arrive verbatim from the dashboard
   HTTP surface. A non-segment id must never reach the filesystem — delete
   reports it [refused], load reports [Not_found] — and a file outside the
   session directory must stay unreachable through either entry point. *)
let test_history_snapshot_id_containment () =
  let session_dir = temp_dir () in
  let outside = Filename.concat (Filename.dirname session_dir) "victim.json" in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.unlink outside with Unix.Unix_error _ -> ());
      cleanup_dir session_dir)
    (fun () ->
      Fs_compat.save_file outside "outside-session";
      let escape = "../victim.json" in
      (match
         Keeper_checkpoint_store.delete_agent_core_history_files ~session_dir
           ~snapshot_ids:[ escape ]
       with
       | [ Keeper_checkpoint_store.History_refused refused ] ->
         check string "escaping id is reported refused" escape refused
       | results ->
         fail (Printf.sprintf "unexpected delete outcome count: %d" (List.length results)));
      check bool "file outside the session dir survives" true
        (Sys.file_exists outside);
      match
        Keeper_checkpoint_store.load_agent_core_history_file ~session_dir
          ~snapshot_id:escape
      with
      | Error Keeper_checkpoint_store.Not_found -> ()
      | Ok _ -> fail "escaping snapshot_id load succeeded"
      | Error _ ->
        fail "escaping snapshot_id load returned a non-Not_found error")

let test_invalid_existing_checkpoint_fails_closed () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-corrupt" in
    let path =
      Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id
    in
    let corrupt = "{not-a-checkpoint" in
    Fs_compat.save_file path corrupt;
    (match
       Keeper_checkpoint_store.save_agent_core_classified
         ~history_retained:(history_retained ())
         ~session_dir
         (make_checkpoint ~session_id ~turn_count:9 ~marker:"must-not-write")
     with
     | Error _ -> ()
     | Ok _ -> fail "corrupt existing checkpoint was treated as a cold store");
    check string "corrupt canonical bytes remain untouched" corrupt
      (Fs_compat.load_file path);
    let mismatched =
      make_checkpoint ~session_id:"another-session" ~turn_count:10
        ~marker:"wrong-identity"
      |> Agent_core.Checkpoint.to_string
    in
    Fs_compat.save_file path mismatched;
    (match
       Keeper_checkpoint_store.save_agent_core_classified
         ~history_retained:(history_retained ())
         ~session_dir
         (make_checkpoint ~session_id ~turn_count:11 ~marker:"must-not-replace")
     with
     | Error _ -> ()
     | Ok _ -> fail "mismatched checkpoint identity was overwritten");
    check string "mismatched canonical bytes remain untouched" mismatched
      (Fs_compat.load_file path))

let test_multi_domain_writers_leave_max_turn_on_disk () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-domains" in
    save_ok
      ~session_dir
      (make_checkpoint ~session_id ~turn_count:0 ~marker:"seed")
      "seed save";
    let turns = [ 4; 1; 8; 3; 7; 2; 9; 6; 5 ] in
    let writer_count = List.length turns in
    let ready = Atomic.make 0 in
    let start = Atomic.make false in
    (* Read here, not inside the writer: the writers are raw Domains. *)
    let history_retained = history_retained () in
    let writer turn_count =
      Atomic.incr ready;
      while not (Atomic.get start) do
        Domain.cpu_relax ()
      done;
      Keeper_checkpoint_store.save_agent_core_classified ~history_retained
        ~session_dir
        (make_checkpoint
           ~session_id
           ~turn_count
           ~marker:(Printf.sprintf "v%d" turn_count))
    in
    let domains = List.map (fun turn -> Domain.spawn (fun () -> writer turn)) turns in
    while Atomic.get ready <> writer_count do
      Domain.cpu_relax ()
    done;
    Atomic.set start true;
    List.iter
      (fun domain ->
        match Domain.join domain with
        | Ok _ -> ()
        | Error error -> fail ("concurrent checkpoint save failed: " ^ error))
      domains;
    let expected = List.fold_left max min_int turns in
    match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id with
    | Error _ -> fail "load after concurrent saves failed"
    | Ok checkpoint ->
      check int "canonical disk retains the maximum turn" expected
        checkpoint.Agent_core.Checkpoint.turn_count)

(* The canonical checkpoint file is written compact (Yojson.Safe.to_string),
   not pretty-printed, to cut idle-CPU serialization cost. The read path is a
   JSON parser and is format-agnostic; this test asserts the on-disk bytes are
   actually single-line and that the round-trip through the compact encoding
   is lossless for session identity, turn_count, and message content. *)
let test_canonical_checkpoint_is_written_compact () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let sid = "sess-compact" in
    let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid in
    save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:7 ~marker:"compact-marker")
      "compact save";
    let raw = Fs_compat.load_file path in
    check bool "canonical checkpoint bytes are single-line (compact, not pretty)"
      true
      (not (String.contains raw '\n'));
    match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:sid with
    | Error _ -> fail "load after compact save failed"
    | Ok on_disk ->
      check string "session_id round-trips through compact encoding" sid
        on_disk.Agent_core.Checkpoint.session_id;
      check int "turn_count round-trips through compact encoding" 7
        on_disk.Agent_core.Checkpoint.turn_count;
      let marker_present =
        List.exists
          (fun (msg : Agent_core.Types.message) ->
             String.equal (Agent_core.Types.text_of_message msg) "compact-marker")
          on_disk.Agent_core.Checkpoint.messages
      in
      check bool "message content round-trips through compact encoding" true
        marker_present)

let test_ready_runtime_raw_domain_save () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  Executor_pool_ref.For_testing.with_pool
    (Domain_pool.executor_pool pool)
  @@ fun () ->
  Eio_guard.enable ();
  Fun.protect ~finally:Eio_guard.disable @@ fun () ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) @@ fun () ->
  let session_id = "raw-domain-ready" in
  let session_dir = Filename.concat base_dir "new-session" in
  (* Read here and passed in: the store takes the window as an argument
     instead of reading it. *)
  let history_retained = history_retained () in
  let result =
    Domain.spawn (fun () ->
      Keeper_checkpoint_store.save_agent_core_classified ~history_retained ~session_dir
        (make_checkpoint ~session_id ~turn_count:11 ~marker:"raw-domain"))
    |> Domain.join
  in
  (match result with
   | Ok (Keeper_checkpoint_store.Saved _) -> ()
   | Ok (Keeper_checkpoint_store.Stale_noop _) -> fail "new raw-domain save was stale"
   | Error detail -> fail ("ready-state raw-domain save failed: " ^ detail));
  check bool "save retains create-first session contract" true
    (Sys.file_exists session_dir);
  check bool "stable lock is outside removable session subtree" true
    (Sys.file_exists (session_dir ^ ".checkpoint.lock"));
  match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id with
  | Error _ -> fail "raw-domain checkpoint did not round-trip"
  | Ok checkpoint -> check int "raw-domain turn persisted" 11 checkpoint.turn_count

let with_recorded_backtraces f =
  let was_recording = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace was_recording)
    f
;;

let with_exact_source_fixture ~session_id f =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:8 ~marker:"source")
      "exact source seed save";
    let source_ref =
      match
        Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
      with
      | Ok (_, reference) -> reference
      | Error _ -> fail "exact source load failed"
    in
    f ~session_dir ~source_ref)
;;

(* The source check reads the canonical file and hashes it. A file the
   canonical summary already describes is not parsed again: the decode this
   replaces allocated 26 GB in fifty minutes on a live server, over files of
   13-109 MB, and a save repeats it every turn.

   The budget is measured here rather than guessed: the save is compared
   against what decoding the same file costs in this process. If the save
   parsed too, the two would be the same order. *)
let parse_share_of_a_save = 4.0

let chatty_checkpoint ~session_id ~turn_count ~marker ~messages =
  let base = make_checkpoint ~session_id ~turn_count ~marker in
  { base with Agent_core.Checkpoint.messages }
;;

let many_short_messages count =
  List.init count (fun index ->
    Agent_core.Types.
      { role = Assistant
      ; content = [ Text (Printf.sprintf "%d %s" index (String.make 60 'x')) ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      })
;;

let allocated_minor_words f =
  let before = Gc.minor_words () in
  f ();
  Gc.minor_words () -. before
;;

let test_a_summarised_source_is_hashed_and_not_parsed () =
  let session_id = "sess-cas-hash-only" in
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    save_ok ~session_dir
      (chatty_checkpoint ~session_id ~turn_count:8 ~marker:"source"
         ~messages:(many_short_messages 8_000))
      "hash-only seed save";
    let source_ref =
      match
        Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
      with
      | Ok (_, reference) -> reference
      | Error _ -> fail "hash-only source load failed"
    in
    let source_path = Filename.concat session_dir (session_id ^ ".json") in
    let source_bytes = (Unix.stat source_path).Unix.st_size in
    let source = Fs_compat.load_file source_path in
    let parse_words =
      allocated_minor_words (fun () ->
        match Agent_core.Checkpoint.of_string source with
        | Ok _ -> ()
        | Error _ -> fail "the source could not be decoded")
    in
    (* A parse of this file has to cost enough for the comparison below to mean
       something: the fixture is 8,000 short messages, whose parse allocates
       about 0.75 minor words per byte. *)
    check bool
      (Printf.sprintf "a parse of %d bytes allocated %.0f words" source_bytes parse_words)
      true
      (parse_words > 100_000.0);
    let candidate = make_checkpoint ~session_id ~turn_count:9 ~marker:"candidate" in
    let installation = ref None in
    let save_words =
      allocated_minor_words (fun () ->
        installation
        := Some
             (Keeper_checkpoint_store.save_agent_core_if_source
                ~session_dir
                ~expected_source_ref:source_ref
                candidate))
    in
    (match !installation with
     | Some (Keeper_checkpoint_store.Installed _) -> ()
     | Some (Keeper_checkpoint_store.Not_installed _) | None ->
       fail "the candidate was refused against its own source");
    check bool
      (Printf.sprintf "the save allocated %.0f words against a parse's %.0f"
         save_words parse_words)
      true
      (save_words *. parse_share_of_a_save < parse_words))
;;

let test_exact_source_cas_allows_one_equal_turn_writer () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-exact-cas" in
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:8 ~marker:"source")
      "CAS seed save";
    let source_ref =
      match
        Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
      with
      | Ok (_, reference) -> reference
      | Error _ -> fail "CAS source load failed"
    in
    let left_observed = Atomic.make 0 in
    let right_observed = Atomic.make 0 in
    let left_ref = Atomic.make None in
    let right_ref = Atomic.make None in
    let writer marker observed observed_ref =
      Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_observer
        ~on_checkpoint_commit_observer:(fun installed_ref ->
          Atomic.incr observed;
          Atomic.set observed_ref (Some installed_ref))
        ~session_dir
        ~expected_source_ref:source_ref
        (make_checkpoint ~session_id ~turn_count:8 ~marker)
    in
    let left =
      Domain.spawn (fun () -> "left", writer "left" left_observed left_ref)
    in
    let right =
      Domain.spawn (fun () -> "right", writer "right" right_observed right_ref)
    in
    let committed, changed =
      [ Domain.join left; Domain.join right ]
      |> List.fold_left
           (fun (committed, changed) (marker, outcome) ->
             match outcome with
             | Keeper_checkpoint_store.Installed installed ->
               (marker, installed) :: committed, changed
             | Keeper_checkpoint_store.Not_installed
                 { cause = Keeper_checkpoint_store.Source_changed _; _ } ->
               committed, changed + 1
             | Keeper_checkpoint_store.Not_installed _ ->
               fail "CAS writer returned an unexpected error")
           ([], 0)
    in
    check int "exactly one writer commits" 1 (List.length committed);
    check int "the competing source is rejected" 1 changed;
    check int
      "competing observer is emitted once for the winner"
      1
      (Atomic.get left_observed + Atomic.get right_observed);
    match committed,
      Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
    with
    | [ (winner, committed_ref) ], Ok (checkpoint, disk_ref) ->
      let winner_observed, loser_observed, winner_ref =
        if String.equal winner "left"
        then Atomic.get left_observed, Atomic.get right_observed, Atomic.get left_ref
        else Atomic.get right_observed, Atomic.get left_observed, Atomic.get right_ref
      in
      check int "winning writer observer count" 1 winner_observed;
      check int "stale writer observer count" 0 loser_observed;
      check bool "committed ref identifies installed canonical bytes" true
        (Keeper_checkpoint_ref.equal committed_ref.installed_ref disk_ref);
      check bool
        "observer receives the exact installed ref"
        true
        (match winner_ref with
         | Some observed_ref ->
           Keeper_checkpoint_ref.equal observed_ref committed_ref.installed_ref
         | None -> false);
      check bool "installed payload belongs to the winning writer" true
        (List.exists
           (fun (message : Agent_core.Types.message) ->
             String.equal (Agent_core.Types.text_of_message message) winner)
           checkpoint.messages)
    | _ -> fail "CAS winner did not round-trip")

let test_exact_source_cas_updates_canonical_watermark () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-cas-watermark" in
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:8 ~marker:"source")
      "CAS watermark seed save";
    let source_ref =
      match
        Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
      with
      | Ok (_, reference) -> reference
      | Error _ -> fail "CAS watermark source load failed"
    in
    let release_failure =
      { File_lock_eio.lock_path = session_dir ^ ".checkpoint.lock"
      ; phase = File_lock_eio.Release_process_lock
      ; cause =
          { File_lock_eio.error = Unix.EIO
          ; operation = "injected_release"
          ; argument = session_dir
          }
      ; cleanup_failure = None
      }
    in
    let observer_count = ref 0 in
    (match
       Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_release_failure
         ~release_failure
         ~on_checkpoint_commit_observer:(fun _ -> incr observer_count)
         ~session_dir
         ~expected_source_ref:source_ref
         (make_checkpoint ~session_id ~turn_count:9 ~marker:"target")
     with
     | Keeper_checkpoint_store.Installed installed ->
       check int "release-failure observer remains at-most-once" 1 !observer_count;
       check bool
         "release failure remains auxiliary to installed"
         true
         (List.exists
            (function
              | Keeper_checkpoint_store.Release_process_lock_failed error ->
                error = release_failure
              | _ -> false)
            installed.auxiliary)
       ;
       let disk_ref =
         match
           Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
         with
         | Ok (_, reference) -> reference
         | Error _ -> fail "release-failure installed checkpoint was not readable"
       in
       check bool
         "release failure preserves the exact installed ref"
         true
         (Keeper_checkpoint_ref.equal installed.installed_ref disk_ref)
     | Keeper_checkpoint_store.Not_installed _ ->
       fail "release failure downgraded the installed checkpoint");
    match
      Keeper_checkpoint_store.save_agent_core_classified
        ~history_retained:(history_retained ()) ~session_dir
        (make_checkpoint ~session_id ~turn_count:8 ~marker:"stale!")
    with
    | Ok
        (Keeper_checkpoint_store.Stale_noop
           { incoming_turn_count; known_turn_count }) ->
      check int "colliding stale input turn" 8 incoming_turn_count;
      check int "CAS candidate remains the admission watermark" 9
        known_turn_count
    | Ok (Keeper_checkpoint_store.Saved _) ->
      fail "stale save ignored the canonical checkpoint installed by CAS"
    | Error error -> fail ("post-CAS stale classification failed: " ^ error))

let test_post_rename_durability_unknown_is_installed () =
  let session_id = "sess-cas-post-rename" in
  with_exact_source_fixture ~session_id (fun ~session_dir ~source_ref ->
    let candidate =
      make_checkpoint ~session_id ~turn_count:9 ~marker:"post-rename"
    in
    let durability_error =
      { Keeper_fs.renamed = true
      ; stage = Keeper_fs.Parent_directory_fsync_after_rename
      ; failure =
          Keeper_fs.Operation_failed "injected post-rename durability failure"
      }
    in
    match
      Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_writer
        ~write_checkpoint_bytes:
          (fun ~on_durable_commit:_ ~ownership_root:_ ~path ~bytes ->
             Fs_compat.save_file path bytes;
             Error durability_error)
        ~on_checkpoint_commit_observer:(fun _ -> ())
        ~session_dir
        ~expected_source_ref:source_ref
        candidate
    with
    | Keeper_checkpoint_store.Not_installed _ ->
      fail "post-rename durability uncertainty became Not_installed"
    | Keeper_checkpoint_store.Installed installed ->
      (match installed.auxiliary with
       | [ Keeper_checkpoint_store.Commit_durability_unknown error ] ->
         check bool
           "post-rename durability cause is preserved"
           true
           (error = durability_error)
       | _ -> fail "post-rename durability auxiliary was not preserved");
      let disk_ref =
        match
          Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
        with
        | Ok (_, reference) -> reference
        | Error _ -> fail "post-rename candidate was not externally installed"
      in
      check bool
        "post-rename outcome carries the exact installed ref"
        true
        (Keeper_checkpoint_ref.equal installed.installed_ref disk_ref);
      match
        Keeper_checkpoint_store.save_agent_core_if_source
          ~session_dir
          ~expected_source_ref:source_ref
          candidate
      with
      | Keeper_checkpoint_store.Not_installed
          { cause = Keeper_checkpoint_store.Source_changed actual; _ } ->
        check bool
          "same-process retry is fenced by the installed ref"
          true
          (Keeper_checkpoint_ref.equal actual installed.installed_ref)
      | Keeper_checkpoint_store.Installed _ ->
        fail "post-rename candidate was installed twice"
      | Keeper_checkpoint_store.Not_installed _ ->
        fail "post-rename retry failed without exact source evidence")
;;

let test_pre_rename_write_failure_is_not_installed_and_retryable () =
  let session_id = "sess-cas-pre-rename" in
  with_exact_source_fixture ~session_id (fun ~session_dir ~source_ref ->
    let candidate =
      make_checkpoint ~session_id ~turn_count:9 ~marker:"pre-rename"
    in
    let write_error =
      { Keeper_fs.renamed = false
      ; stage = Keeper_fs.Payload_write
      ; failure = Keeper_fs.Operation_failed "injected pre-rename write failure"
      }
    in
    let observer_count = ref 0 in
    match
      Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_writer
        ~write_checkpoint_bytes:
          (fun ~on_durable_commit:_ ~ownership_root:_ ~path:_ ~bytes:_ ->
             Error write_error)
        ~on_checkpoint_commit_observer:(fun _ -> incr observer_count)
        ~session_dir
        ~expected_source_ref:source_ref
        candidate
    with
    | Keeper_checkpoint_store.Installed _ ->
      fail "pre-rename write failure became Installed"
    | Keeper_checkpoint_store.Not_installed
        { cause = Keeper_checkpoint_store.Commit_not_installed error; _ } ->
      check bool
        "pre-rename write failure preserves its exact cause"
        true
        (error = write_error);
      check int "pre-rename failure emits no commit observer" 0 !observer_count;
      (match
         Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
       with
       | Ok (_, disk_ref) ->
         check bool
           "pre-rename failure leaves the canonical ref unchanged"
           true
           (Keeper_checkpoint_ref.equal source_ref disk_ref)
       | Error _ -> fail "pre-rename failure removed the canonical checkpoint");
      (match
         Keeper_checkpoint_store.save_agent_core_if_source
           ~session_dir
           ~expected_source_ref:source_ref
           candidate
       with
       | Keeper_checkpoint_store.Installed installed ->
         check bool
           "pre-rename failure remains retryable from the same source"
           false
           (Keeper_checkpoint_ref.equal source_ref installed.installed_ref)
       | Keeper_checkpoint_store.Not_installed _ ->
         fail "pre-rename failure consumed the exact-source retry")
    | Keeper_checkpoint_store.Not_installed _ ->
      fail "pre-rename write failure lost its Commit_not_installed cause")
;;

let test_release_failure_preserves_not_installed_cause () =
  let session_id = "sess-cas-not-installed-release" in
  with_exact_source_fixture ~session_id (fun ~session_dir ~source_ref ->
    let advanced =
      match
        Keeper_checkpoint_store.save_agent_core_if_source
          ~session_dir
          ~expected_source_ref:source_ref
          (make_checkpoint ~session_id ~turn_count:9 ~marker:"advanced")
      with
      | Keeper_checkpoint_store.Installed installed -> installed.installed_ref
      | Keeper_checkpoint_store.Not_installed _ ->
        fail "failed to advance the source before release-failure proof"
    in
    let release_failure =
      { File_lock_eio.lock_path = session_dir ^ ".checkpoint.lock"
      ; phase = File_lock_eio.Release_process_lock
      ; cause =
          { File_lock_eio.error = Unix.EIO
          ; operation = "injected_release_after_not_installed"
          ; argument = session_dir
          }
      ; cleanup_failure = None
      }
    in
    let observer_count = ref 0 in
    match
      Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_release_failure
        ~release_failure
        ~on_checkpoint_commit_observer:(fun _ -> incr observer_count)
        ~session_dir
        ~expected_source_ref:source_ref
        (make_checkpoint ~session_id ~turn_count:10 ~marker:"stale-source")
    with
    | Keeper_checkpoint_store.Installed _ ->
      fail "release failure changed a source mismatch into Installed"
    | Keeper_checkpoint_store.Not_installed outcome ->
      (match outcome.cause with
       | Keeper_checkpoint_store.Source_changed actual ->
         check bool
           "Not_installed retains the exact changed source"
           true
           (Keeper_checkpoint_ref.equal actual advanced)
       | _ -> fail "release failure replaced the original non-install cause");
      check int "non-install path emits no commit observer" 0 !observer_count;
      match outcome.auxiliary with
      | [ Keeper_checkpoint_store.Release_process_lock_failed error ] ->
        check bool
          "Not_installed retains the release failure"
          true
          (error = release_failure)
      | _ -> fail "Not_installed release failure was not preserved")
;;

let test_acquire_failure_prevents_lock_body () =
  let session_id = "sess-cas-acquire-failure" in
  with_exact_source_fixture ~session_id (fun ~session_dir ~source_ref ->
    let acquire_failure =
      { File_lock_eio.lock_path = session_dir ^ ".checkpoint.lock"
      ; phase = File_lock_eio.Open_lock_file
      ; cause =
          { File_lock_eio.error = Unix.EACCES
          ; operation = "injected_open_before_body"
          ; argument = session_dir
          }
      ; cleanup_failure = None
      }
    in
    let observer_count = ref 0 in
    match
      Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_acquire_failure
        ~acquire_failure
        ~on_checkpoint_commit_observer:(fun _ -> incr observer_count)
        ~session_dir
        ~expected_source_ref:source_ref
        (make_checkpoint ~session_id ~turn_count:9 ~marker:"not-admitted")
    with
    | Keeper_checkpoint_store.Installed _ ->
      fail "lock acquisition failure admitted the checkpoint body"
    | Keeper_checkpoint_store.Not_installed outcome ->
      check int "acquire failure runs no commit observer" 0 !observer_count;
      check bool "acquire failure has no release auxiliary" true
        (outcome.auxiliary = []);
      match outcome.cause with
      | Keeper_checkpoint_store.Source_unavailable
          (Keeper_checkpoint_store.Ref_lock_failed detail) ->
        check bool
          "acquire failure preserves its exact lock cause"
          true
          (Astring.String.is_infix ~affix:"injected_open_before_body" detail)
      | _ -> fail "acquire failure changed its non-install cause")
;;

let test_commit_observer_failure_is_installed () =
  let session_id = "sess-cas-observer-failure" in
  with_exact_source_fixture ~session_id (fun ~session_dir ~source_ref ->
    let outcome =
      with_recorded_backtraces (fun () ->
        Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_observer
          ~on_checkpoint_commit_observer:(fun _ ->
            failwith "injected commit observer failure")
          ~session_dir
          ~expected_source_ref:source_ref
          (make_checkpoint ~session_id ~turn_count:9 ~marker:"observer-failure"))
    in
    match outcome with
    | Keeper_checkpoint_store.Not_installed _ ->
      fail "commit observer failure downgraded the installed checkpoint"
    | Keeper_checkpoint_store.Installed installed ->
      match installed.auxiliary with
      | [ Keeper_checkpoint_store.Commit_observer_failed
            (Failure detail, backtrace) ] ->
        check string
          "commit observer failure cause"
          "injected commit observer failure"
          detail;
        check bool
          "commit observer failure preserves its raw backtrace"
          true
          (Printexc.raw_backtrace_length backtrace > 0)
      | _ -> fail "commit observer failure was not preserved as auxiliary")
;;

let test_post_commit_unwind_is_installed () =
  let session_id = "sess-cas-post-commit-unwind" in
  with_exact_source_fixture ~session_id (fun ~session_dir ~source_ref ->
    let outcome =
      with_recorded_backtraces (fun () ->
        Keeper_checkpoint_store.For_testing.save_agent_core_if_source_with_post_commit_unwind
          ~post_commit_unwind:(fun () ->
            failwith "injected post-commit unwind")
          ~on_checkpoint_commit_observer:(fun _ -> ())
          ~session_dir
          ~expected_source_ref:source_ref
          (make_checkpoint ~session_id ~turn_count:9 ~marker:"post-commit-unwind"))
    in
    match outcome with
    | Keeper_checkpoint_store.Not_installed _ ->
      fail "post-commit unwind downgraded the installed checkpoint"
    | Keeper_checkpoint_store.Installed installed ->
      match installed.auxiliary with
      | [ Keeper_checkpoint_store.Post_commit_unwind_interrupted
            (Failure detail, backtrace) ] ->
        check string
          "post-commit unwind cause"
          "injected post-commit unwind"
          detail;
        check bool
          "post-commit unwind preserves its raw backtrace"
          true
          (Printexc.raw_backtrace_length backtrace > 0)
      | _ -> fail "post-commit unwind was not preserved as auxiliary")
;;

let test_exact_snapshot_preserves_locked_canonical_bytes () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) (fun () ->
    let session_id = "sess-exact-snapshot" in
    save_ok ~session_dir
      (make_checkpoint ~session_id ~turn_count:4 ~marker:"exact")
      "exact snapshot seed";
    let canonical_path = Filename.concat session_dir (session_id ^ ".json") in
    let expected_bytes =
      Fs_compat.load_file canonical_path
      |> Yojson.Safe.from_string
      |> Yojson.Safe.pretty_to_string
    in
    Fs_compat.save_file canonical_path expected_bytes;
    match
      Keeper_checkpoint_store.load_agent_core_exact_snapshot
        ~session_dir
        ~session_id
    with
    | Error _ -> fail "exact snapshot load failed"
    | Ok snapshot ->
      check string "canonical bytes are not re-encoded" expected_bytes
        (Keeper_checkpoint_store.exact_snapshot_canonical_bytes snapshot);
      let reference =
        Keeper_checkpoint_store.exact_snapshot_reference snapshot
      in
      let expected_session_id =
        Result.get_ok (Keeper_id.Trace_id.of_string session_id)
      in
      match
        Keeper_checkpoint_store.exact_snapshot_of_canonical_bytes
          ~expected_session_id
          expected_bytes
      with
      | Ok decoded ->
        check bool "pure decode derives the same exact ref" true
          (Keeper_checkpoint_ref.equal reference
             (Keeper_checkpoint_store.exact_snapshot_reference decoded))
      | Error _ -> fail "exact snapshot bytes did not decode")

let test_exact_snapshot_callback_serializes_checkpoint_writer () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let session_id = "sess-exact-callback" in
  save_ok ~session_dir
    (make_checkpoint ~session_id ~turn_count:4 ~marker:"captured")
    "exact callback seed";
  let canonical_path = Filename.concat session_dir (session_id ^ ".json") in
  let captured_bytes = Fs_compat.load_file canonical_path in
  let result = Keeper_checkpoint_store.with_agent_core_exact_snapshot
    ~session_dir ~session_id (fun snapshot ->
      check string "callback receives exact captured bytes" captured_bytes
        (Keeper_checkpoint_store.exact_snapshot_canonical_bytes snapshot);
      let writer_done = Eio.Fiber.fork_promise ~sw (fun () ->
        save_ok ~session_dir
          (make_checkpoint ~session_id ~turn_count:5 ~marker:"following")
          "writer following exact callback") in
      let lock_path = Unix.realpath session_dir ^ ".checkpoint.lock" in
      Eio.Fiber.first
        (fun () ->
          while File_lock_eio.For_testing.holders_and_waiters ~lock_path < 2 do
            Eio.Fiber.yield ()
          done)
        (fun () ->
          Eio.Promise.await_exn writer_done;
          fail "checkpoint writer completed while the exact callback held its source");
      check string "waiting writer has not changed the source" captured_bytes
        (Fs_compat.load_file canonical_path);
      Error "callback declined publication", writer_done) in
  let writer_done = match result with
   | Ok (Error detail, writer_done) ->
     check string "callback refusal remains separate from source errors"
       "callback declined publication" detail;
     writer_done
   | Ok (Ok _, _) -> fail "callback refusal was replaced by success"
   | Error error ->
     fail (Keeper_checkpoint_store.checkpoint_ref_load_error_to_string error) in
  Eio.Promise.await_exn writer_done;
  match Keeper_checkpoint_store.load_agent_core_exact_snapshot ~session_dir ~session_id with
  | Error error ->
    fail (Keeper_checkpoint_store.checkpoint_ref_load_error_to_string error)
  | Ok snapshot ->
    check int "writer proceeds after the callback releases the source" 5
      (Keeper_checkpoint_store.exact_snapshot_checkpoint snapshot).turn_count
;;

let test_exact_snapshot_callback_refuses_missing_and_propagates_cancellation () =
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let session_id = "sess-exact-callback-cancel" in
  let called = ref false in
  (match Keeper_checkpoint_store.with_agent_core_exact_snapshot
     ~session_dir ~session_id (fun _ -> called := true) with
   | Error Keeper_checkpoint_store.Ref_not_found -> ()
   | Error (Keeper_checkpoint_store.Ref_read_failed _
           | Ref_identity_invalid _ | Ref_session_mismatch _ | Ref_lock_failed _) ->
     fail "missing source returned a different error"
   | Ok () -> fail "missing source ran the exact snapshot callback");
  check bool "missing source never invokes the callback" false !called;
  save_ok ~session_dir
    (make_checkpoint ~session_id ~turn_count:1 ~marker:"before-cancel")
    "cancel callback seed";
  let cancellation = Eio.Cancel.Cancelled (Failure "cancel exact source callback") in
  (match Keeper_checkpoint_store.with_agent_core_exact_snapshot
     ~session_dir ~session_id (fun _ -> raise cancellation) with
   | Ok _ -> fail "callback cancellation returned success"
   | Error _ -> fail "callback cancellation became a source error"
   | exception Eio.Cancel.Cancelled cause ->
     check bool "callback cancellation keeps its cause" true
       (cause = Failure "cancel exact source callback"));
  save_ok ~session_dir
    (make_checkpoint ~session_id ~turn_count:2 ~marker:"after-cancel")
    "writer after callback cancellation"
;;

(* A save hashes the candidate bytes and its source check hashes the file on
   disk. Both hashes run in the pool job that encodes or decodes the same
   bytes. This drives the store from a fiber through a real one-domain pool,
   so the pooled path is the one under test, and expects every reference to be
   the SHA-256 of the file on disk at that moment. The seed file is rewritten
   pretty-printed first, so a reference taken over re-encoded bytes instead of
   the bytes on disk would not match. *)
let test_pooled_saves_and_loads_derive_the_digest_of_the_file () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  Eio_guard.enable ();
  Fun.protect ~finally:Eio_guard.disable @@ fun () ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let session_id = "sess-pooled-digest" in
  let digest_on_disk () =
    Filename.concat session_dir (session_id ^ ".json")
    |> Fs_compat.load_file
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  in
  save_ok ~session_dir
    (make_checkpoint ~session_id ~turn_count:3 ~marker:"seed")
    "pooled seed save";
  let canonical_path = Filename.concat session_dir (session_id ^ ".json") in
  Fs_compat.load_file canonical_path
  |> Yojson.Safe.from_string
  |> Yojson.Safe.pretty_to_string
  |> Fs_compat.save_file canonical_path;
  let source =
    match
      Keeper_checkpoint_store.load_agent_core_exact_snapshot ~session_dir ~session_id
    with
    | Ok snapshot -> Keeper_checkpoint_store.exact_snapshot_reference snapshot
    | Error _ -> fail "pooled exact snapshot load failed"
  in
  check string "a pooled load derives the digest of the file" (digest_on_disk ())
    source.Keeper_checkpoint_ref.sha256;
  (match
     Keeper_checkpoint_store.save_agent_core_if_source ~session_dir
       ~expected_source_ref:source
       (make_checkpoint ~session_id ~turn_count:4 ~marker:"next")
   with
   | Keeper_checkpoint_store.Installed installed ->
     check string "the installed ref is the digest of the bytes written"
       (digest_on_disk ()) installed.installed_ref.sha256
   | Keeper_checkpoint_store.Not_installed _ -> fail "pooled source-checked save was refused");
  match
    Keeper_checkpoint_store.save_agent_core_if_source ~session_dir
      ~expected_source_ref:source
      (make_checkpoint ~session_id ~turn_count:5 ~marker:"late")
  with
  | Keeper_checkpoint_store.Not_installed
      { cause = Keeper_checkpoint_store.Source_changed moved; _ } ->
    check string "the refusal names the digest now on disk" (digest_on_disk ())
      moved.sha256
  | Keeper_checkpoint_store.Not_installed _ | Keeper_checkpoint_store.Installed _ ->
    fail "a save against a moved source was not refused as changed"

(* RFC main-domain-scheduler-latency §8 P4b. After a save, the store answers
   the save watermark and the message count from its canonical summary while
   the file on disk is the one it wrote. The file is made unreadable to show
   that neither answer reads it. *)
let test_byte_count_from_summary_without_reading () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "byte-count-no-read" in
  save_ok
    ~session_dir
    (make_checkpoint ~session_id:sid ~turn_count:3 ~marker:"three")
    "save turn 3";
  let path =
    Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid
  in
  let on_disk = (Unix.stat path).Unix.st_size in
  Unix.chmod path 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod path 0o644) @@ fun () ->
  (match Keeper_checkpoint_store.canonical_byte_count ~session_dir ~session_id:sid with
   | Ok (Some bytes) -> check int "byte count is the file's size" on_disk bytes
   | Ok None -> fail "byte count reported no checkpoint"
   | Error _ -> fail "byte count read the unreadable file");
  match Keeper_checkpoint_store.canonical_byte_count ~session_dir ~session_id:"absent" with
  | Ok None -> ()
  | Ok (Some _) -> fail "an absent session reported bytes"
  | Error _ -> fail "an absent session is not a store error"
;;

let test_summary_answers_watermark_and_count_without_reading () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "summary-no-read" in
  save_ok
    ~session_dir
    (make_checkpoint ~session_id:sid ~turn_count:3 ~marker:"three")
    "save turn 3";
  let path =
    Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid
  in
  Unix.chmod path 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod path 0o644) @@ fun () ->
  (match
     Keeper_checkpoint_store.canonical_message_count ~session_dir ~session_id:sid
   with
   | Ok (Some count) -> check int "message count from the summary" 2 count
   | Ok None -> fail "summary reported no checkpoint"
   | Error _ -> fail "message count read the unreadable file");
  match
    Keeper_checkpoint_store.save_agent_core_classified
      ~history_retained:(history_retained ())
      ~session_dir
      (make_checkpoint ~session_id:sid ~turn_count:2 ~marker:"stale")
  with
  | Ok
      (Keeper_checkpoint_store.Stale_noop
         { incoming_turn_count = 2; known_turn_count = 3 }) -> ()
  | Ok (Keeper_checkpoint_store.Stale_noop _) ->
    fail "stale verdict carried other turn counts"
  | Ok (Keeper_checkpoint_store.Saved _) -> fail "a stale turn was saved"
  | Error e -> fail ("watermark read the unreadable file: " ^ e)
;;

(* A save reaches the canonical through the session root's resolved path. A
   reader handed the root's symlinked spelling finds the summary that save
   published, without reading the file. *)
let test_summary_found_through_a_symlinked_session_root () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let real_session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir real_session_dir) @@ fun () ->
  let real_root = Filename.dirname real_session_dir in
  let linked_root = real_root ^ "-link" in
  Unix.symlink real_root linked_root;
  Fun.protect ~finally:(fun () -> Unix.unlink linked_root) @@ fun () ->
  let session_dir = Filename.concat linked_root (Filename.basename real_session_dir) in
  let sid = "summary-through-link" in
  save_ok
    ~session_dir
    (make_checkpoint ~session_id:sid ~turn_count:3 ~marker:"three")
    "save turn 3";
  let path =
    Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid
  in
  Unix.chmod path 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod path 0o644) @@ fun () ->
  match Keeper_checkpoint_store.canonical_message_count ~session_dir ~session_id:sid with
  | Ok (Some count) -> check int "message count from the summary" 2 count
  | Ok None -> fail "summary reported no checkpoint"
  | Error _ -> fail "message count read the unreadable file through the link"
;;

(* A canonical file replaced behind the store (another process, an operator)
   is a new inode, so the summary no longer matches and the next answer
   parses the file; a removed file answers as no checkpoint. *)
(* The canonical read goes through the owned-file reader: a canonical path
   that is a symbolic link out of the session's ownership chain is refused
   as an I/O error instead of being followed. *)
let test_checkpoint_read_refuses_a_symlinked_canonical_file () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "symlinked-canonical" in
  save_ok
    ~session_dir
    (make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"one")
    "save turn 1";
  (match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:sid with
   | Ok checkpoint -> check int "regular canonical file loads" 1 checkpoint.turn_count
   | Error error ->
     failf "regular canonical file failed: %s"
       (Keeper_checkpoint_store.checkpoint_load_error_to_string error));
  let path =
    Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid
  in
  let outside = Filename.temp_file "ckpt_outside_" ".json" in
  Fun.protect ~finally:(fun () -> try Sys.remove outside with Sys_error _ -> ()) @@ fun () ->
  Out_channel.with_open_bin outside (fun channel ->
    output_string channel (In_channel.with_open_bin path In_channel.input_all));
  Sys.remove path;
  Unix.symlink outside path;
  match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:sid with
  | Error (Keeper_checkpoint_store.Io_error _) -> ()
  | Error error ->
    failf "symlinked canonical file refused with the wrong class: %s"
      (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
  | Ok _ -> fail "symlinked canonical file was followed"

(* RFC main-domain-scheduler-latency §8 P4b step 2. After a save, a load
   answers from the decode of the bytes that save wrote and does not read the
   file. The answer is the file's decode, not the value that was saved: the
   wire does not carry [ToolResult.json]. *)
let checkpoint_with_parsed_tool_result ~session_id ~turn_count =
  let open Agent_core.Types in
  let message role content = { role; content; name = None; tool_call_id = None; metadata = [] } in
  { (make_checkpoint ~session_id ~turn_count ~marker:"done") with
    Agent_core.Checkpoint.messages =
      [ message User [ Text "count the rows" ]
      ; message Assistant [ ToolUse { id = "t1"; name = "search"; input = `Assoc [] } ]
      ; message
          Tool
          [ ToolResult
              { tool_use_id = "t1"
              ; content = "{\"rows\":3}"
              ; outcome = Tool_succeeded
              ; json = Some (`Assoc [ "rows", `Int 3 ])
              ; content_blocks = None
              }
          ]
      ; message Assistant [ Text "three rows" ]
      ]
  }
;;

let parsed_tool_result_json (cp : Agent_core.Checkpoint.t) =
  List.find_map
    (fun (m : Agent_core.Types.message) ->
       List.find_map
         (function
           | Agent_core.Types.ToolResult { json; _ } -> Some json
           | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
           | Agent_core.Types.RedactedThinking _ | Agent_core.Types.ToolUse _
           | Agent_core.Types.Image _ | Agent_core.Types.Document _
           | Agent_core.Types.Audio _ | Agent_core.Types.ReasoningDetails _ -> None)
         m.content)
    cp.messages
;;

(* A Keeper turn's checkpoint names the runtime the turn ran on, and Keepers on
   one runtime share that name. The store learns the Keeper from the save. *)
let shared_runtime_agent_name = "agent_core-test-runtime"
let kept_keeper = "lineage-test-keeper"

let save_kept_ok ~keeper_name ~session_dir (ckpt : Agent_core.Checkpoint.t) label =
  match
    Keeper_checkpoint_store.save_agent_core_for_keeper ~keeper_name
      ~history_retained:(history_retained ()) ~session_dir
      { ckpt with agent_name = shared_runtime_agent_name }
  with
  | Ok _ -> ()
  | Error e -> fail (label ^ " unexpectedly failed: " ^ e)
;;

let load_or_fail ~session_dir ~session_id label =
  match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id with
  | Ok checkpoint -> checkpoint
  | Error error ->
    failf "%s: %s" label (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
;;

let test_load_after_a_save_answers_from_the_written_bytes () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "written-value" in
  let saved = checkpoint_with_parsed_tool_result ~session_id:sid ~turn_count:1 in
  save_kept_ok ~keeper_name:kept_keeper ~session_dir saved "save turn 1";
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid in
  let decoded_file =
    match Agent_core.Checkpoint.of_string (Fs_compat.load_file path) with
    | Ok checkpoint -> checkpoint
    | Error error -> fail (Agent_core.Error.to_string error)
  in
  Unix.chmod path 0o000;
  let first, second =
    Fun.protect ~finally:(fun () -> Unix.chmod path 0o644) @@ fun () ->
    ( load_or_fail ~session_dir ~session_id:sid "first load of an unreadable file"
    , load_or_fail ~session_dir ~session_id:sid "second load of an unreadable file" )
  in
  check bool "the saved value carried the parsed json" true
    (parsed_tool_result_json saved = Some (Some (`Assoc [ "rows", `Int 3 ])));
  check bool "the load gives the file's decode, json dropped" true
    (parsed_tool_result_json first = Some None);
  check bool "its messages equal the file's decode" true
    (first.messages = decoded_file.messages);
  check string "it encodes to the file's bytes" (Fs_compat.load_file path)
    (Agent_core.Checkpoint.to_string first);
  check bool "both loads hand out the same records" true (first.messages == second.messages);
  check bool "each load gets its own context" true (first.context != second.context)
;;

(* Another writer replaces the file with the same bytes: a new inode. The kept
   value no longer names the file, so the load reads it again. *)
let test_load_reads_a_file_replaced_behind_the_written_value () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "written-value-replaced" in
  save_kept_ok ~keeper_name:kept_keeper ~session_dir (checkpoint_with_parsed_tool_result ~session_id:sid ~turn_count:1)
    "save turn 1";
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid in
  let kept = load_or_fail ~session_dir ~session_id:sid "load the kept value" in
  (match Fs_compat.save_file_atomic path (Fs_compat.load_file path) with
   | Ok () -> ()
   | Error detail -> fail ("replace the file: " ^ detail));
  let reread = load_or_fail ~session_dir ~session_id:sid "load the replaced file" in
  check bool "the replaced file was decoded again" true (reread.messages != kept.messages);
  check bool "to the same value" true (reread.messages = kept.messages);
  Unix.chmod path 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod path 0o644) @@ fun () ->
  match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:sid with
  | Ok _ -> fail "a value was kept for a file this process did not write"
  | Error _ -> ()
;;

(* A workspace keeps every trace under one session root, as
   [<root>/<trace>/<trace>.json]; [temp_dir] gives [<root>/session]. *)
let sibling_session_dir session_dir name =
  let dir = Filename.concat (Filename.dirname session_dir) name in
  Unix.mkdir dir 0o755;
  dir
;;

(* A keeper that moves to a new trace saves a new canonical file. Its value
   for the old file is dropped, so one agent holds one history in memory. *)
let test_a_save_under_a_new_trace_drops_the_older_written_value () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let old_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir old_dir) @@ fun () ->
  let new_dir = sibling_session_dir old_dir "new-session" in
  save_kept_ok ~keeper_name:kept_keeper ~session_dir:old_dir
    (make_checkpoint ~session_id:"old-trace" ~turn_count:1 ~marker:"old") "save old trace";
  let kept = load_or_fail ~session_dir:old_dir ~session_id:"old-trace" "load old trace" in
  save_kept_ok ~keeper_name:kept_keeper ~session_dir:new_dir
    (make_checkpoint ~session_id:"new-trace" ~turn_count:1 ~marker:"new") "save new trace";
  let reread = load_or_fail ~session_dir:old_dir ~session_id:"old-trace" "load old trace again" in
  check bool "the old trace is read from disk again" true (reread.messages != kept.messages);
  check bool "the new trace answers from its written value" true
    (let first = load_or_fail ~session_dir:new_dir ~session_id:"new-trace" "load new trace" in
     let second = load_or_fail ~session_dir:new_dir ~session_id:"new-trace" "load new trace again" in
     first.messages == second.messages)
;;

(* The next turn starts from the loaded value and appends. Its records are the
   ones the store's memo already encoded, so the save encodes only the new
   message: no second document of allocation. *)
let messages_in_the_reuse_fixture = 200
let bytes_per_reuse_fixture_message = 20_000
let document_bytes_per_byte_a_reusing_save_may_allocate = 4.0

let test_a_save_after_a_load_encodes_only_the_new_messages () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "written-value-reuse" in
  let text role body : Agent_core.Types.message =
    { role; content = [ Agent_core.Types.Text body ]; name = None; tool_call_id = None; metadata = [] }
  in
  let history =
    List.init messages_in_the_reuse_fixture (fun index ->
      text
        (if index mod 2 = 0 then Agent_core.Types.User else Agent_core.Types.Assistant)
        (String.make bytes_per_reuse_fixture_message 'x' ^ string_of_int index))
  in
  save_kept_ok ~keeper_name:kept_keeper ~session_dir
    { (make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"m") with
      Agent_core.Checkpoint.messages = history }
    "save turn 1";
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid in
  let document_bytes = (Unix.stat path).Unix.st_size in
  let loaded = load_or_fail ~session_dir ~session_id:sid "load turn 1" in
  let next =
    { loaded with
      Agent_core.Checkpoint.turn_count = 2
    ; messages = loaded.messages @ [ text Agent_core.Types.User "turn two" ]
    }
  in
  let before = Gc.allocated_bytes () in
  save_kept_ok ~keeper_name:kept_keeper ~session_dir next "save turn 2";
  let allocated = Gc.allocated_bytes () -. before in
  check string "the save wrote the bytes of to_string" (Agent_core.Checkpoint.to_string next)
    (Fs_compat.load_file path);
  check bool
    (Printf.sprintf "the save allocated %.0f bytes for a %d byte document" allocated document_bytes)
    true
    (allocated *. document_bytes_per_byte_a_reusing_save_may_allocate
     < float_of_int document_bytes)
;;

(* Two Keepers of one workspace each keep their own value: a save of one does
   not drop the other's. *)
let test_two_keepers_keep_their_written_values_side_by_side () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let first_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir first_dir) @@ fun () ->
  let second_dir = sibling_session_dir first_dir "second-keeper" in
  save_kept_ok ~keeper_name:"first-keeper" ~session_dir:first_dir
    (make_checkpoint ~session_id:"first-trace" ~turn_count:1 ~marker:"first") "save first keeper";
  let kept = load_or_fail ~session_dir:first_dir ~session_id:"first-trace" "load first keeper" in
  save_kept_ok ~keeper_name:"second-keeper" ~session_dir:second_dir
    (make_checkpoint ~session_id:"second-trace" ~turn_count:1 ~marker:"second")
    "save second keeper";
  let again = load_or_fail ~session_dir:first_dir ~session_id:"first-trace" "load first keeper again" in
  check bool "the first keeper still answers from its value" true (again.messages == kept.messages)
;;

(* A writer that rewrites the file in place keeps its inode, and here its
   size; the mtime it leaves is what names the change. *)
let test_a_file_rewritten_in_place_is_read_again () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "rewritten-in-place" in
  save_kept_ok ~keeper_name:kept_keeper ~session_dir (make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"in place") "save";
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid in
  let kept = load_or_fail ~session_dir ~session_id:sid "load the kept value" in
  let before = Unix.stat path in
  let bytes = Fs_compat.load_file path in
  let fd = Unix.openfile path [ Unix.O_WRONLY ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    let rec write_from offset =
      if offset < String.length bytes
      then write_from (offset + Unix.write_substring fd bytes offset (String.length bytes - offset))
    in
    write_from 0);
  Unix.utimes path before.Unix.st_atime (before.Unix.st_mtime +. 2.0);
  let after = Unix.stat path in
  check bool "the rewrite kept the inode and the size" true
    (after.Unix.st_ino = before.Unix.st_ino && after.Unix.st_size = before.Unix.st_size);
  let reread = load_or_fail ~session_dir ~session_id:sid "load the rewritten file" in
  check bool "the rewritten file was decoded again" true (reread.messages != kept.messages)
;;

(* Another writer renames its own checkpoint over the canonical right after
   this save's rename, before the save has finished. The save keeps its value
   under the identity of the file it wrote, so the next load does not match
   the other writer's file and reads it. *)
let test_a_file_renamed_over_a_save_right_after_its_rename_is_read () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "renamed-over-a-save" in
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid in
  let foreign_bytes =
    Agent_core.Checkpoint.to_string
      { (make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"the other writer") with
        agent_name = shared_runtime_agent_name }
  in
  let replaced = ref false in
  let replace_the_path () =
    let foreign = path ^ ".foreign" in
    Out_channel.with_open_bin foreign (fun oc -> output_string oc foreign_bytes);
    Unix.rename foreign path;
    replaced := true
  in
  (match
     Keeper_checkpoint_store.For_testing.save_agent_core_for_keeper_with_before_stage
       ~before_stage:(function
         | Keeper_fs.Parent_directory_fsync_after_rename when not !replaced -> replace_the_path ()
         | _ -> ())
       ~keeper_name:kept_keeper ~history_retained:(history_retained ()) ~session_dir
       { (make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"this save") with
         agent_name = shared_runtime_agent_name }
   with
   | Ok _ -> ()
   | Error e -> fail ("save: " ^ e));
  check bool "the other writer replaced the path during the save" true !replaced;
  let loaded = load_or_fail ~session_dir ~session_id:sid "load after the replacement" in
  check (list string) "the load holds the other writer's file"
    [ "hello"; "the other writer" ]
    (List.map Agent_core.Types.text_of_message loaded.messages)
;;

(* The saving side keeps changing its context after the save. A load must give
   what the file holds, not that table. *)
let test_a_load_does_not_see_context_changes_made_after_the_save () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "context-after-save" in
  let saved = make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"context" in
  Agent_core.Context.set saved.context "turn_note" (`String "at save");
  save_kept_ok ~keeper_name:kept_keeper ~session_dir saved "save";
  Agent_core.Context.set saved.context "turn_note" (`String "after save");
  let loaded = load_or_fail ~session_dir ~session_id:sid "load" in
  check bool "the load holds the context as saved" true
    (Agent_core.Context.get loaded.context "turn_note" = Some (`String "at save"))
;;

let unreadable_load_refused ~session_dir ~session_id ~path label =
  Unix.chmod path 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod path 0o644) @@ fun () ->
  match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id with
  | Ok _ -> fail label
  | Error _ -> ()
;;

(* After a restart the turn reads the file. Its load keeps what it read, so
   the next load answers without a read and the turn's save encodes only the
   new message. A read-only load keeps nothing. [forget_written_lineages]
   stands in for the restart. *)
let test_a_load_for_save_keeps_what_it_read () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "read-for-save" in
  let text role body : Agent_core.Types.message =
    { role; content = [ Agent_core.Types.Text body ]; name = None; tool_call_id = None; metadata = [] }
  in
  let history =
    List.init messages_in_the_reuse_fixture (fun index ->
      text
        (if index mod 2 = 0 then Agent_core.Types.User else Agent_core.Types.Assistant)
        (String.make bytes_per_reuse_fixture_message 'x' ^ string_of_int index))
  in
  save_kept_ok ~keeper_name:kept_keeper ~session_dir
    { (make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"m") with
      Agent_core.Checkpoint.messages = history }
    "save turn 1";
  Keeper_checkpoint_store.forget_written_lineages
    ~session_root:(Filename.dirname session_dir) ~keeper_name:kept_keeper;
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid in
  ignore (load_or_fail ~session_dir ~session_id:sid "read-only load" : Agent_core.Checkpoint.t);
  unreadable_load_refused ~session_dir ~session_id:sid ~path
    "a read-only load kept what it read";
  let read =
    match Keeper_checkpoint_store.load_agent_core_for_save ~keeper_name:kept_keeper ~session_dir ~session_id:sid with
    | Ok checkpoint -> checkpoint
    | Error error -> fail (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
  in
  Unix.chmod path 0o000;
  let again =
    Fun.protect ~finally:(fun () -> Unix.chmod path 0o644) @@ fun () ->
    load_or_fail ~session_dir ~session_id:sid "load of an unreadable file after a load for save"
  in
  check bool "the next load answers from what was read" true (again.messages == read.messages);
  let document_bytes = (Unix.stat path).Unix.st_size in
  let next =
    { read with
      Agent_core.Checkpoint.turn_count = 2
    ; messages = read.messages @ [ text Agent_core.Types.User "turn two" ]
    }
  in
  let before = Gc.allocated_bytes () in
  save_kept_ok ~keeper_name:kept_keeper ~session_dir next "save turn 2";
  let allocated = Gc.allocated_bytes () -. before in
  check string "the save wrote the bytes of to_string" (Agent_core.Checkpoint.to_string next)
    (Fs_compat.load_file path);
  check bool
    (Printf.sprintf "the save allocated %.0f bytes for a %d byte document" allocated document_bytes)
    true
    (allocated *. document_bytes_per_byte_a_reusing_save_may_allocate
     < float_of_int document_bytes)
;;

let keeper_meta_fixture keeper_name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String keeper_name; "activation_mode", `String "manual" ])
  with
  | Ok meta -> meta
  | Error detail -> fail ("keeper meta fixture failed: " ^ detail)
;;

(* The registry's unregistration drops the Keeper's kept value. *)
let test_unregistering_a_keeper_drops_its_written_value () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let scratch = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir scratch) @@ fun () ->
  let base_path = Unix.realpath scratch in
  let name = "lineage-keeper" in
  let trace = "lineage-trace" in
  let session_dir =
    Filename.concat (Keeper_fs.session_store_path_for_base_path base_path) trace
  in
  save_kept_ok ~keeper_name:name ~session_dir
    (make_checkpoint ~session_id:trace ~turn_count:1 ~marker:"registered")
    "save";
  let entry =
    match Keeper_registry.register_offline_if_admitted ~base_path name (keeper_meta_fixture name) with
    | Ok entry -> entry
    | Error (_ : Keeper_registry.registration_error) -> fail "registration refused"
  in
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:trace in
  Unix.chmod path 0o000;
  let registered =
    Fun.protect ~finally:(fun () -> Unix.chmod path 0o644) @@ fun () ->
    Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace
  in
  check bool "a registered keeper's value answers without a read" true (Result.is_ok registered);
  (match Keeper_registry.unregister_exact entry with
   | Keeper_registry.Exact_unregistered -> ()
   | Keeper_registry.Exact_entry_missing | Keeper_registry.Exact_entry_replaced
   | Keeper_registry.Exact_unregister_lifecycle_reserved _ -> fail "unregistration refused");
  unreadable_load_refused ~session_dir ~session_id:trace ~path
    "the unregistered keeper's value was still kept"
;;

(* A session store that does not resolve at the unregistration still loses the
   Keeper's kept value. The store is moved away for the unregistration and
   back after it; a rename keeps the file's identity, so a value left behind
   would answer the load. *)
let test_unregistering_a_keeper_whose_session_store_moved_drops_its_written_value () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let scratch = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir scratch) @@ fun () ->
  let base_path = Unix.realpath scratch in
  let name = "moved-store-keeper" in
  let trace = "moved-store-trace" in
  let session_store = Keeper_fs.session_store_path_for_base_path base_path in
  let session_dir = Filename.concat session_store trace in
  save_kept_ok ~keeper_name:name ~session_dir
    (make_checkpoint ~session_id:trace ~turn_count:1 ~marker:"registered")
    "save";
  let entry =
    match Keeper_registry.register_offline_if_admitted ~base_path name (keeper_meta_fixture name) with
    | Ok entry -> entry
    | Error (_ : Keeper_registry.registration_error) -> fail "registration refused"
  in
  let moved = session_store ^ ".moved" in
  Unix.rename session_store moved;
  (match Keeper_registry.unregister_exact entry with
   | Keeper_registry.Exact_unregistered -> ()
   | Keeper_registry.Exact_entry_missing | Keeper_registry.Exact_entry_replaced
   | Keeper_registry.Exact_unregister_lifecycle_reserved _ -> fail "unregistration refused");
  Unix.rename moved session_store;
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:trace in
  unreadable_load_refused ~session_dir ~session_id:trace ~path
    "the unregistered keeper's value was still kept"
;;

(* A save by a tool or a test keeps nothing: the next load reads the file. *)
let test_a_plain_save_keeps_no_written_value () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "plain-save" in
  save_ok ~session_dir (make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"plain") "save";
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid in
  unreadable_load_refused ~session_dir ~session_id:sid ~path "a plain save kept its value"
;;

(* One Keeper name in two workspaces is two Keepers. *)
let test_one_keeper_name_in_two_workspaces_keeps_both_values () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let first_dir = temp_dir () in
  let second_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir first_dir; cleanup_dir second_dir) @@ fun () ->
  save_kept_ok ~keeper_name:kept_keeper ~session_dir:first_dir
    (make_checkpoint ~session_id:"first-workspace-trace" ~turn_count:1 ~marker:"first") "save first";
  let kept =
    load_or_fail ~session_dir:first_dir ~session_id:"first-workspace-trace" "load first"
  in
  save_kept_ok ~keeper_name:kept_keeper ~session_dir:second_dir
    (make_checkpoint ~session_id:"second-workspace-trace" ~turn_count:1 ~marker:"second")
    "save second";
  let again =
    load_or_fail ~session_dir:first_dir ~session_id:"first-workspace-trace" "load first again"
  in
  check bool "the first workspace's keeper still answers from its value" true
    (again.messages == kept.messages)
;;

let test_summary_follows_a_checkpoint_replaced_behind_it () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let sid = "summary-replaced" in
  save_ok
    ~session_dir
    (make_checkpoint ~session_id:sid ~turn_count:1 ~marker:"one")
    "save turn 1";
  let path =
    Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:sid
  in
  let replacement =
    let base = make_checkpoint ~session_id:sid ~turn_count:5 ~marker:"five" in
    { base with
      messages =
        base.messages
        @ [ Agent_core.Types.
              { role = User
              ; content = [ Text "again" ]
              ; name = None
              ; tool_call_id = None
              ; metadata = []
              }
          ]
    }
  in
  let staged = path ^ ".replacement" in
  Out_channel.with_open_bin staged (fun channel ->
    output_string
      channel
      (Yojson.Safe.to_string (Agent_core.Checkpoint.to_json replacement)));
  Sys.rename staged path;
  (match
     Keeper_checkpoint_store.canonical_message_count ~session_dir ~session_id:sid
   with
   | Ok (Some count) -> check int "message count of the replacement" 3 count
   | Ok None -> fail "replacement reported no checkpoint"
   | Error _ -> fail "replacement could not be read");
  (match
     Keeper_checkpoint_store.save_agent_core_classified
       ~history_retained:(history_retained ())
       ~session_dir
       (make_checkpoint ~session_id:sid ~turn_count:4 ~marker:"four")
   with
   | Ok
       (Keeper_checkpoint_store.Stale_noop
          { incoming_turn_count = 4; known_turn_count = 5 }) -> ()
   | Ok (Keeper_checkpoint_store.Stale_noop _) ->
     fail "stale verdict carried other turn counts"
   | Ok (Keeper_checkpoint_store.Saved _) ->
     fail "the watermark still answered from the old summary"
   | Error e -> fail ("save failed: " ^ e));
  Sys.remove path;
  match
    Keeper_checkpoint_store.canonical_message_count ~session_dir ~session_id:sid
  with
  | Ok None -> ()
  | Ok (Some _) -> fail "a removed checkpoint still answered from the summary"
  | Error _ -> fail "a removed checkpoint was reported as an error"
;;

let test_history_link_keeps_transaction_until_cancelled_job_finishes () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  let clock = Eio.Stdenv.clock env in
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let session_id = "history-cancel" in
  let checkpoint turn_count = make_checkpoint ~session_id ~turn_count ~marker:(string_of_int turn_count) in
  save_ok ~session_dir (checkpoint 1) "seed";
  let canonical = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id in
  let history = Keeper_checkpoint_store.agent_core_history_path ~session_dir
    ~snapshot_id:(Keeper_checkpoint_store.agent_core_history_snapshot_id_of_checkpoint (checkpoint 1)) in
  let turn path =
    match Agent_core.Checkpoint.of_string (Fs_compat.load_file path) with
    | Ok checkpoint -> checkpoint.turn_count
    | Error _ -> fail "checkpoint bytes were corrupted"
  in
  let caller_thread = Thread.id (Thread.self ()) in
  let entered = Atomic.make false in
  let observed_thread = Atomic.make None in
  let mutex = Mutex.create () in
  let condition = Condition.create () in
  let released = ref false in
  let release () =
    Mutex.lock mutex;
    released := true;
    Condition.broadcast condition;
    Mutex.unlock mutex
  in
  let before_link () =
    if Atomic.compare_and_set entered false true then (
      Atomic.set observed_thread (Some (Thread.id (Thread.self ())));
      if Thread.id (Thread.self ()) = caller_thread then
        fail "history link blocked the caller thread";
      Mutex.lock mutex;
      Fun.protect ~finally:(fun () -> Mutex.unlock mutex) (fun () ->
        while not !released do Condition.wait condition mutex done))
  in
  let context, context_u = Eio.Promise.create () in
  let first_done, first_done_u = Eio.Promise.create () in
  let next_done, next_done_u = Eio.Promise.create () in
  Keeper_checkpoint_store.For_testing.with_before_history_link before_link @@ fun () ->
  Fun.protect ~finally:release @@ fun () ->
  Eio.Fiber.fork ~sw (fun () ->
    let result = try
      Eio.Cancel.sub (fun cc ->
        Eio.Promise.resolve context_u cc;
        save_ok ~session_dir (checkpoint 2) "cancelled writer");
      Ok ()
    with Eio.Cancel.Cancelled _ -> Ok () | exn -> Error exn in
    Eio.Promise.resolve first_done_u result);
  Eio.Time.with_timeout_exn clock 2. (fun () ->
    while Option.is_none (Atomic.get observed_thread) do Eio.Time.sleep clock 0.001 done);
  check bool "history link runs on another system thread" true
    (Option.get (Atomic.get observed_thread) <> caller_thread);
  check int "canonical commit precedes history link" 2 (turn canonical);
  check int "previous history still exists while replacement pauses" 1 (turn history);
  Eio.Cancel.cancel (Eio.Promise.await context) (Failure "cancel history writer");
  Eio.Fiber.fork ~sw (fun () ->
    let result = try save_ok ~session_dir (checkpoint 3) "next writer"; Ok ()
      with exn -> Error exn in
    Eio.Promise.resolve next_done_u result);
  Eio.Time.sleep clock 0.01;
  check bool "cancelled writer waits for accepted link job" false (Eio.Promise.is_resolved first_done);
  check bool "next writer cannot leave transaction early" false (Eio.Promise.is_resolved next_done);
  check int "next writer cannot replace canonical during accepted link" 2 (turn canonical);
  release ();
  List.iter (fun promise ->
    match Eio.Time.with_timeout_exn clock 2. (fun () -> Eio.Promise.await promise) with
    | Ok () -> () | Error exn -> raise exn) [ first_done; next_done ];
  check int "next writer persists after lock release" 3 (turn canonical);
  check int "history follows the serialized next writer" 3 (turn history);
  check int "history remains a hardlink to committed bytes"
    (Unix.stat canonical).Unix.st_ino (Unix.stat history).Unix.st_ino

(* A busy one-domain pool holds the directory scan until its worker is free.
   This exercises the store entry point rather than only the pool wrapper. *)
let test_history_listing_waits_for_the_shared_pool () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  let previous = Domain_pool_ref.get () in
  Fun.protect ~finally:(fun () ->
    match previous with
    | None -> Domain_pool_ref.clear_for_tests ()
    | Some pool -> Domain_pool_ref.set pool) @@ fun () ->
  Domain_pool_ref.set pool;
  Eio_guard.enable ();
  Fun.protect ~finally:Eio_guard.disable @@ fun () ->
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let clock = Eio.Stdenv.clock env in
  let gate = Mutex.create () in
  Mutex.lock gate;
  let released = ref false in
  let release () =
    if not !released then (released := true; Mutex.unlock gate)
  in
  Fun.protect ~finally:release @@ fun () ->
  let worker_entered = Atomic.make false in
  let busy_done, busy_done_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Domain_pool.submit_cpu pool (fun () ->
      Atomic.set worker_entered true;
      Mutex.lock gate;
      Mutex.unlock gate);
    Eio.Promise.resolve busy_done_u ());
  Eio.Time.with_timeout_exn clock 2. (fun () ->
    while not (Atomic.get worker_entered) do Eio.Time.sleep clock 0.001 done);
  let listing_started, listing_started_u = Eio.Promise.create () in
  let listing_done, listing_done_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Promise.resolve listing_started_u ();
    let files = Keeper_checkpoint_store.list_agent_core_history_files ~session_dir in
    Eio.Promise.resolve listing_done_u files);
  Eio.Promise.await listing_started;
  Eio.Time.sleep clock 0.1;
  check bool "history scan waits for the occupied shared pool" false
    (Eio.Promise.is_resolved listing_done);
  release ();
  Eio.Promise.await busy_done;
  check (list string) "empty session has no history" []
    (Eio.Time.with_timeout_exn clock 2. (fun () -> Eio.Promise.await listing_done))

let test_history_retention_after_syscall_offload () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  let session_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir session_dir) @@ fun () ->
  let retained = (Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained) in
  let checkpoint turn_count =
    { (make_checkpoint ~session_id:"history-retention" ~turn_count ~marker:"history")
      with created_at = 1000. +. float_of_int turn_count }
  in
  for turn = 1 to retained + 2 do save_ok ~session_dir (checkpoint turn) "history save" done;
  let files = Keeper_checkpoint_store.list_agent_core_history_files ~session_dir in
  check int "rolling history retains its exact existing window" retained (List.length files);
  let snapshot turn = Keeper_checkpoint_store.agent_core_history_snapshot_id_of_checkpoint (checkpoint turn) in
  check bool "oldest snapshot was pruned" false (List.mem (snapshot 1) files);
  check bool "second expired snapshot was pruned" false (List.mem (snapshot 2) files);
  check bool "oldest retained snapshot survives" true (List.mem (snapshot 3) files);
  check bool "newest snapshot survives" true (List.mem (snapshot (retained + 2)) files)

(* The window an operator sets has to reach the prune. [save_ok] reads the
   setting the way production does and hands it to the save, so these two
   counts are the whole path: a save that ignored [~history_retained], or a
   prune that clamped it to the shipped default, fails one of them. Both
   directions are checked because a clamp only shows up in one. *)
let widened_history_window = 5
let narrowed_history_window = 1

let test_history_window_follows_the_runtime_setting () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  let session_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Runtime_params.clear Runtime_settings.keeper_checkpoint_history_retained;
      cleanup_dir session_dir)
  @@ fun () ->
  let default_window =
    Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained
  in
  let set_window window =
    match
      Runtime_params.set Runtime_settings.keeper_checkpoint_history_retained window
    with
    | Ok () -> ()
    | Error detail -> fail ("setting the history window failed: " ^ detail)
  in
  let retained_files () =
    List.length (Keeper_checkpoint_store.list_agent_core_history_files ~session_dir)
  in
  let checkpoint turn_count =
    { (make_checkpoint ~session_id:"history-setting" ~turn_count ~marker:"history")
      with created_at = 2000. +. float_of_int turn_count }
  in
  let next_turn = ref 0 in
  let save_one () =
    incr next_turn;
    save_ok ~session_dir (checkpoint !next_turn) "history save"
  in
  set_window widened_history_window;
  for _ = 1 to widened_history_window + 2 do save_one () done;
  check int "a window wider than the default keeps that many"
    widened_history_window (retained_files ());
  set_window narrowed_history_window;
  save_one ();
  check int "narrowing it cuts the history down on the very next save"
    narrowed_history_window (retained_files ());
  Runtime_params.clear Runtime_settings.keeper_checkpoint_history_retained;
  for _ = 1 to default_window + 1 do save_one () done;
  check int "clearing the override puts the default window back"
    default_window (retained_files ())

let () =
  run "Keeper_checkpoint_store checkpoint watermark (RFC-0225 §3.2)"
    [
      ( "checkpoint transaction",
        [
          test_case "history syscall retains transaction through cancellation" `Quick
            test_history_link_keeps_transaction_until_cancelled_job_finishes;
          test_case "history listing waits for the shared pool" `Quick
            test_history_listing_waits_for_the_shared_pool;
          test_case "history syscall retains exact rolling window" `Quick
            test_history_retention_after_syscall_offload;
          test_case "history window follows the runtime setting" `Quick
            test_history_window_follows_the_runtime_setting;
          test_case "run context binds generation before AGENT_CORE checkpoint" `Quick
            test_run_context_binds_generation_before_agent_core_checkpoint;
          test_case "unrenderable fragment refuses the turn and recovers" `Quick
            (test_unrenderable_prompt_refuses_preparation_typed
               ~key:Prompt_names.keeper_worldview
               ~body:"Shared Keeper fixture contract"
               ~worldview:"broken {{unresolved_test_variable}}");
          test_case "unrenderable primary prompt refuses the turn and recovers" `Quick
            (test_unrenderable_prompt_refuses_preparation_typed
               ~key:Prompt_names.keeper
               ~body:"broken {{unresolved_test_variable}}"
               ~worldview:"World fixture contract");
          test_case "empty primary prompt refuses the turn and recovers" `Quick
            (test_unrenderable_prompt_refuses_preparation_typed
               ~key:Prompt_names.keeper ~body:""
               ~worldview:"World fixture contract");
          test_case "checkpoint I/O failure stops the turn and preserves history" `Quick
            (test_checkpoint_read_error_stops_turn ~io_failure:true);
          test_case "checkpoint parse failure stops the turn and preserves history" `Quick
            (test_checkpoint_read_error_stops_turn ~io_failure:false);
          test_case "an unreadable constitution stops the turn and the next tick resumes"
            `Quick test_unreadable_constitution_stops_turn_and_the_next_tick_resumes;
          test_case "an autonomous turn sends the run context's base prompt" `Quick
            test_autonomous_turn_sends_the_run_context_base_prompt;
          test_case "an unreadable path is not an absent checkpoint" `Quick
            test_unreadable_path_is_not_an_absent_checkpoint;
          test_case "a deliberate checkpoint version cut still starts fresh" `Quick
            test_superseded_context_can_start_fresh;
          test_case "an admitted checkpoint is the continuation history source" `Quick
            test_admitted_checkpoint_is_the_run_history_source;
          test_case "forward and equal saves pass, stale save is no-op" `Quick
            test_forward_equal_and_stale;
          test_case "canonical disk is the watermark SSOT" `Quick
            test_disk_is_the_watermark_ssot;
          test_case "external canonical replacement is the watermark" `Quick
            test_externally_replaced_canonical_is_the_watermark;
          test_case "a superseded canonical is replaced, not refused forever" `Quick
            test_superseded_canonical_is_replaced;
          test_case "a newer canonical is not overwritten" `Quick
            test_newer_canonical_is_not_replaced;
          test_case "empty session_id is refused, not silently dropped" `Quick
            test_empty_session_id_rejected;
          test_case "session leaf escapes and symlink leaves are refused" `Quick
            test_session_leaf_containment;
          test_case "history snapshot ids cannot reach outside the session" `Quick
            test_history_snapshot_id_containment;
          test_case "invalid canonical checkpoint fails closed" `Quick
            test_invalid_existing_checkpoint_fails_closed;
          test_case "multi-domain writers leave max turn on disk" `Quick
            test_multi_domain_writers_leave_max_turn_on_disk;
          test_case "ready runtime raw Domain saves through Unix context" `Quick
            test_ready_runtime_raw_domain_save;
          test_case "canonical checkpoint is written compact and round-trips" `Quick
            test_canonical_checkpoint_is_written_compact;
          test_case "exact source CAS permits one equal-turn writer" `Quick
            test_exact_source_cas_allows_one_equal_turn_writer;
          test_case "a summarised source is hashed and not parsed" `Quick
            test_a_summarised_source_is_hashed_and_not_parsed;
          test_case "exact source CAS updates the canonical watermark" `Quick
            test_exact_source_cas_updates_canonical_watermark;
          test_case "release failure preserves Not_installed cause" `Quick
            test_release_failure_preserves_not_installed_cause;
          test_case "acquire failure prevents the lock body" `Quick
            test_acquire_failure_prevents_lock_body;
          test_case "post-rename durability uncertainty stays installed" `Quick
            test_post_rename_durability_unknown_is_installed;
          test_case "pre-rename write failure stays retryable" `Quick
            test_pre_rename_write_failure_is_not_installed_and_retryable;
          test_case "commit observer failure stays installed" `Quick
            test_commit_observer_failure_is_installed;
          test_case "post-commit unwind stays installed" `Quick
            test_post_commit_unwind_is_installed;
          test_case "exact snapshot preserves canonical bytes" `Quick
            test_exact_snapshot_preserves_locked_canonical_bytes;
          test_case "exact callback holds the source until checkpoint publication returns" `Quick
            test_exact_snapshot_callback_serializes_checkpoint_writer;
          test_case "exact callback refuses missing source and propagates cancellation" `Quick
            test_exact_snapshot_callback_refuses_missing_and_propagates_cancellation;
          test_case "pooled saves and loads derive the digest of the file" `Quick
            test_pooled_saves_and_loads_derive_the_digest_of_the_file;
          test_case "structurally invalid checkpoint is refused at the store" `Quick
            test_structurally_invalid_checkpoint_is_refused_at_the_store;
          test_case "a valid checkpoint still saves" `Quick
            test_valid_checkpoint_still_saves;
          test_case "stage saves sharing the store's encoding memo write canonical bytes" `Quick
            test_stage_saves_sharing_one_memo_write_canonical_bytes;
          test_case "an unencodable payload is recovered at the sink" `Quick
            test_unencodable_payload_is_recovered_at_the_sink;
          test_case "summary answers watermark and count without reading" `Quick
            test_summary_answers_watermark_and_count_without_reading;
          test_case "summary found through a symlinked session root" `Quick
            test_summary_found_through_a_symlinked_session_root;
          test_case "byte count comes from the summary without reading" `Quick
            test_byte_count_from_summary_without_reading;
          test_case "summary follows a checkpoint replaced behind it" `Quick
            test_summary_follows_a_checkpoint_replaced_behind_it;
          test_case "canonical read refuses a symlinked file" `Quick
            test_checkpoint_read_refuses_a_symlinked_canonical_file;
          test_case "a load after a save answers from the written bytes" `Quick
            test_load_after_a_save_answers_from_the_written_bytes;
          test_case "a load reads a file replaced behind the written value" `Quick
            test_load_reads_a_file_replaced_behind_the_written_value;
          test_case "a save under a new trace drops the older written value" `Quick
            test_a_save_under_a_new_trace_drops_the_older_written_value;
          test_case "a save after a load encodes only the new messages" `Quick
            test_a_save_after_a_load_encodes_only_the_new_messages;
          test_case "two keepers keep their written values side by side" `Quick
            test_two_keepers_keep_their_written_values_side_by_side;
          test_case "a file rewritten in place is read again" `Quick
            test_a_file_rewritten_in_place_is_read_again;
          test_case "a file renamed over a save right after its rename is read" `Quick
            test_a_file_renamed_over_a_save_right_after_its_rename_is_read;
          test_case "a load does not see context changes made after the save" `Quick
            test_a_load_does_not_see_context_changes_made_after_the_save;
          test_case "a load for save keeps what it read" `Quick
            test_a_load_for_save_keeps_what_it_read;
          test_case "unregistering a keeper drops its written value" `Quick
            test_unregistering_a_keeper_drops_its_written_value;
          test_case "unregistering after its session store moved drops its value" `Quick
            test_unregistering_a_keeper_whose_session_store_moved_drops_its_written_value;
          test_case "a plain save keeps no written value" `Quick
            test_a_plain_save_keeps_no_written_value;
          test_case "one keeper name in two workspaces keeps both values" `Quick
            test_one_keeper_name_in_two_workspaces_keeps_both_values;
        ] );
    ]
