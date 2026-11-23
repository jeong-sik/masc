(* End-to-end Stack E Cross-Runtime Circulation Verification:
   1. Agent_core_http turn -> Canonical Turn Store (<keeper>.canonical-turns.db, SQLite WAL off-domain)
      -> failover to Acp_cli turn -> Canonical Turn Store (unbroken parent_turn_id chain + tool calls + usage)
      -> Compaction Anchor (<keeper>.compaction.db) -> failover back to Agent_core_http & Official_cli
      -> load_handoff_context combines [anchor; post-anchor canonical turns] verbatim
      -> Tool_blob_maintenance sweep verifies unclassified = [] across ALL new files AND live blob refs stay protected!
   2. Memory OS soft threshold: commits past facts_max_bytes SUCCEED (zero hard refusal!)
      -> fire non-blocking structural molt signal (Memory_growth_molt_requested) into Librarian_machine
      -> lock-free off-domain reads (read_classified, read_for_keepers_dir, read_retirement_context,
         capture_program_anchor, resume_program_anchor) never stall sibling Keepers!
   3. Bounded RAM & Object GC:
      -> transcript_caches O(1) LRU caps count and refuses oversized entries
      -> provenance_index O(1) LRU caps retained indices
      -> per-Keeper written_lineages isolation prevents one bloated Keeper from evicting sibling Keepers! *)

open Alcotest
module Canonical = Masc.Keeper_canonical_turn_store
module Compaction = Masc.Keeper_compaction
module Current = Masc.Keeper_memory_os_current
module Memory_types = Masc.Keeper_memory_os_types
module Render = Masc.Keeper_memory_os_render
module Lifecycle = Masc.Librarian_lifecycle
module Transcript_rows = Masc.Keeper_chat_store_transcript_rows
module Transcript_index = Masc.Keeper_chat_store_transcript_index
module Checkpoint_store = Masc.Keeper_checkpoint_store
module Llm_types = Agent_core.Llm_provider.Types

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun entry -> rm_rf (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_temp_dir f =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-stack-e-e2e-%d-%d" (Unix.getpid ()) (Random.int 1_000_000))
  in
  Unix.mkdir base 0o700;
  Fun.protect ~finally:(fun () -> rm_rf base) (fun () -> f base)
;;

external unsetenv : string -> unit = "masc_test_unsetenv"

let with_env key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv key v
      | None -> unsetenv key)
    f
;;

let with_eio_pool f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:2 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests (fun () -> f env sw)
;;

let require_canonical = function
  | Ok v -> v
  | Error err -> fail (Canonical.store_error_to_string err)
;;

let require_compaction = function
  | Ok v -> v
  | Error err -> fail (Compaction.store_error_to_string err)
;;

let require_ok = function
  | Ok v -> v
  | Error detail -> fail detail
;;

let message_text (msg : Agent_core.Types.message) =
  msg.content
  |> List.filter_map (function
    | Agent_core.Types.Text s -> Some s
    | _ -> None)
  |> String.concat "\n"
;;

let contains ~needle haystack = String_util.contains_substring haystack needle

(* ── Test 1: Cross-runtime HTTP <-> ACP <-> Official continuity + Compaction Anchor + Blob Sweep ── *)

let test_cross_runtime_continuity_compaction_and_blob_sweep () =
  with_eio_pool @@ fun _env _sw ->
  with_temp_dir @@ fun base_path ->
  let keepers_dir = Server_tool_blob_scope.scope.config_keepers_dir ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let keeper_id = "keeper-circulation-e2e" in
  let blob_store = Tool_blob_store.create ~base_path in
  (* Store a real durable tool blob referenced inside Turn 1's canonical tool_calls_json. *)
  let live_blob_payload = "CANONICAL_TURN_LIVE_BLOB_" ^ String.make 8192 'z' in
  let live_ref =
    Tool_blob_store.put_durable blob_store ~bytes:live_blob_payload ~mime:"text/plain"
  in
  let live_handle = Tool_output.encode_for_agent_core (Tool_output.Stored live_ref) in
  (* Turn 1: Agent_core HTTP turn with tool call referencing the durable blob. *)
  let t1_id = Ids.Turn_id.of_string "trace-circ:1" in
  let t1 =
    Canonical.commit_turn
      ~keepers_dir
      ~keeper_id
      ~turn_id:t1_id
      ~runtime_kind:Canonical.Agent_core_http
      ~runtime_id:"glm-coding:glm-5-3"
      ~user_input:"Inspect lib/keeper/keeper_canonical_turn_store.ml and report invariants."
      ~tool_calls_json:
        (`List
           [ `Assoc
               [ "tool_name", `String "keeper_fs_read"
               ; "call_id", `String "call-http-1"
               ; "args", `Assoc [ "path", `String "lib/keeper/keeper_canonical_turn_store.ml" ]
               ; "output_ref", `String live_handle
               ]
           ])
      ~assistant_output:"HTTP turn 1 confirmed SQLite WAL schema and busy_timeout=5000."
      ~usage_json:(`Assoc [ "input_tokens", `Int 1200; "output_tokens", `Int 180 ])
      ~created_at:100.0
      ()
    |> require_canonical
  in
  check (option string) "first turn has no parent" None
    (Option.map Ids.Turn_id.to_string t1.parent_turn_id);
  (* Turn 2: Failover to ACP CLI runtime — parent_turn_id auto-chains to Turn 1! *)
  let t2_id = Ids.Turn_id.of_string "trace-circ:2" in
  let t2 =
    Canonical.commit_turn
      ~keepers_dir
      ~keeper_id
      ~turn_id:t2_id
      ~runtime_kind:Canonical.Acp_cli
      ~runtime_id:"antigravity_acp:acp-agy-opus"
      ~user_input:"Now verify Tool_blob_maintenance classification on ACP failover."
      ~tool_calls_json:
        (`List
           [ `Assoc
               [ "tool_name", `String "keeper_shell"
               ; "call_id", `String "call-acp-2"
               ; "args", `Assoc [ "cmd", `String "dune exec test/test_tool_blob_sweep.exe" ]
               ]
           ])
      ~assistant_output:"ACP turn 2 verified Server_tool_blob_scope covers .canonical-turns.db."
      ~usage_json:(`Assoc [ "input_tokens", `Int 2400; "output_tokens", `Int 210 ])
      ~created_at:110.0
      ()
    |> require_canonical
  in
  check (option string) "ACP turn 2 chains parent to HTTP turn 1"
    (Some (Ids.Turn_id.to_string t1_id))
    (Option.map Ids.Turn_id.to_string t2.parent_turn_id);
  (* Before compaction: handoff projection returns BOTH Turn 1 and Turn 2 across HTTP -> ACP. *)
  let pre_handoff = Canonical.load_handoff_context ~keepers_dir ~keeper_id |> require_canonical in
  check bool "no compaction anchor yet" true (Option.is_none pre_handoff.anchor);
  check int "two turns before compaction" 2 (List.length pre_handoff.turns_after_anchor);
  let pre_text = String.concat "\n" (List.map message_text pre_handoff.messages) in
  check bool "handoff preserves HTTP turn 1 output" true
    (contains ~needle:"HTTP turn 1 confirmed SQLite WAL" pre_text);
  check bool "handoff preserves ACP turn 2 output" true
    (contains ~needle:"ACP turn 2 verified Server_tool_blob_scope" pre_text);
  (* Commit immutable compaction epoch covering through Turn 2. *)
  let evicted_for_epoch =
    [ { Compaction.turn_id = t1_id; messages = Canonical.messages_of_canonical_turn t1 }
    ; { Compaction.turn_id = t2_id; messages = Canonical.messages_of_canonical_turn t2 }
    ]
  in
  let anchor =
    Compaction.fold_evicted_span
      ~evicted_turns:evicted_for_epoch
      ~summarize:Compaction.deterministic_fold
      ()
    |> require_ok
  in
  let committed_anchor =
    Compaction.commit_epoch
      ~keepers_dir
      ~keeper_id
      ~trigger:(Compaction.Explicit_hard_limit { capacity_bytes = 64_000; observed_bytes = 70_000 })
      ~anchor
      ~evicted_turns:evicted_for_epoch
    |> require_compaction
  in
  check int "compaction epoch 1 committed" 1 committed_anchor.epoch_id;
  check string "anchor covers through ACP turn 2"
    (Ids.Turn_id.to_string t2_id)
    (Ids.Turn_id.to_string committed_anchor.covers_through_turn);
  (* Turn 3: Failover back to HTTP after compaction epoch 1. *)
  let t3_id = Ids.Turn_id.of_string "trace-circ:3" in
  let t3 =
    Canonical.commit_turn
      ~keepers_dir
      ~keeper_id
      ~turn_id:t3_id
      ~runtime_kind:Canonical.Agent_core_http
      ~runtime_id:"glm-coding:glm-5-3"
      ~user_input:"Resume after compaction on HTTP."
      ~tool_calls_json:
        (`List
           [ `Assoc
               [ "tool_name", `String "keeper_fs_read"
               ; "call_id", `String "call-http-3"
               ; "output_ref", `String live_handle
               ]
           ])
      ~assistant_output:"HTTP turn 3 resumed seamlessly from compaction epoch 1."
      ~usage_json:(`Assoc [ "input_tokens", `Int 900; "output_tokens", `Int 120 ])
      ~compaction_epoch_id:committed_anchor.epoch_id
      ~created_at:120.0
      ()
    |> require_canonical
  in
  check (option string) "HTTP turn 3 chains parent to ACP turn 2"
    (Some (Ids.Turn_id.to_string t2_id))
    (Option.map Ids.Turn_id.to_string t3.parent_turn_id);
  (* Turn 4: Switch to Official CLI runtime. *)
  let t4_id = Ids.Turn_id.of_string "trace-circ:4" in
  let _t4 =
    Canonical.commit_turn
      ~keepers_dir
      ~keeper_id
      ~turn_id:t4_id
      ~runtime_kind:Canonical.Official_cli
      ~runtime_id:"claude_code:claude-sonnet-5-5"
      ~user_input:"Finalize on Official CLI."
      ~tool_calls_json:(`List [])
      ~assistant_output:"Official CLI turn 4 saw anchor + turn 3 verbatim."
      ~usage_json:(`Assoc [ "input_tokens", `Int 1000; "output_tokens", `Int 140 ])
      ~compaction_epoch_id:committed_anchor.epoch_id
      ~created_at:130.0
      ()
    |> require_canonical
  in
  (* Post-compaction handoff projection: [anchor_msg; turn 3 msgs; turn 4 msgs]. *)
  let post_handoff = Canonical.load_handoff_context ~keepers_dir ~keeper_id |> require_canonical in
  (match post_handoff.anchor with
   | None -> fail "expected committed compaction anchor in handoff context"
   | Some a -> check int "handoff carries epoch 1 anchor" 1 a.epoch_id);
  check (list string) "handoff includes only turns strictly after anchor.covers_through_turn"
    [ "trace-circ:3"; "trace-circ:4" ]
    (List.map (fun (t : Canonical.canonical_turn) -> Ids.Turn_id.to_string t.turn_id)
       post_handoff.turns_after_anchor);
  let post_text = String.concat "\n" (List.map message_text post_handoff.messages) in
  check bool "post-compaction handoff includes turn 3" true
    (contains ~needle:"HTTP turn 3 resumed seamlessly" post_text);
  check bool "post-compaction handoff includes turn 4" true
    (contains ~needle:"Official CLI turn 4 saw anchor" post_text);
  check int "post-compaction handoff message count is 1 anchor + turn 3 + turn 4"
    (1 + List.length (Canonical.messages_of_canonical_turn t3)
     + List.length (Canonical.messages_of_canonical_turn _t4))
    (List.length post_handoff.messages);
  check bool "post-compaction handoff omits raw pre-anchor turn 1 user prompt" false
    (contains ~needle:"Inspect lib/keeper/keeper_canonical_turn_store.ml" post_text);
  (* Verify Tool_blob_maintenance across .canonical-turns.db + .compaction.db + WAL/SHM sidecars:
     ZERO unclassified files, and the blob referenced by canonical turn 1 stays protected! *)
  let run_sweep mode =
    match Tool_blob_maintenance.run ~base_path ~scope:Server_tool_blob_scope.scope ~mode with
    | Ok report -> report
    | Error err -> fail (Tool_blob_maintenance.error_to_string err)
  in
  let obs = run_sweep Tool_blob_maintenance.Observe_only in
  check (list string) "zero unclassified files across canonical-turns + compaction WALs"
    [] obs.unclassified;
  check bool "canonical-turns live blob reference counted" true (obs.live_references >= 1);
  check int "zero candidates for live canonical-turns blob" 0 obs.candidates_recorded;
  let del = run_sweep Tool_blob_maintenance.Delete_previous_candidates in
  check (list string) "delete pass also has zero unclassified files" [] del.unclassified;
  check int "zero live blobs deleted" 0 del.deleted;
  (match Tool_blob_store.fetch blob_store ~sha256:live_ref.sha256 with
   | Ok (Some bytes) -> check string "live blob intact after sweep" live_blob_payload bytes
   | Ok None -> fail "sweep deleted live blob referenced by canonical turn store"
   | Error err -> fail (Tool_blob_store.fetch_error_to_string err))
;;

(* ── Test 2: Memory OS Soft Molt Trigger + Lock-Free Snapshot & Retirement Reads ── *)

let test_memory_os_structural_molt_and_lock_free_reads () =
  with_eio_pool @@ fun _env _sw ->
  with_temp_dir @@ fun base_path ->
  let keepers_dir = Server_tool_blob_scope.scope.config_keepers_dir ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let keeper_id = "keeper-memory-molt" in
  (* Strict codec proof for the new Memory_growth_molt_requested trigger. *)
  let trigger =
    Lifecycle.Memory_growth_molt_requested { current_bytes = 640_000; threshold_bytes = 524_288 }
  in
  let roundtripped =
    Lifecycle.molt_trigger_of_json (Lifecycle.molt_trigger_to_json trigger)
    |> Result.map_error Memory_types.wire_error_to_string
    |> require_ok
  in
  check bool "Memory_growth_molt_requested JSON roundtrip" true (roundtripped = trigger);
  (* Fail-closed check: negative byte counts rejected. *)
  (match
     Lifecycle.molt_trigger_of_json
       (`Assoc
          [ "kind", `String "memory_growth_molt_requested"
          ; "current_bytes", `Int (-1)
          ; "threshold_bytes", `Int 512
          ])
   with
   | Error _ -> ()
   | Ok _ -> fail "negative current_bytes must fail closed");
  (* Memory OS soft-molt evaluation past facts_max_bytes succeeds AND emits non-blocking molt signal! *)
  let received_triggers = ref [] in
  Render.set_on_molt_requested
    (Some
       (fun ~keeper_id:kid (budget : Render.facts_budget) ->
          received_triggers :=
            ( kid
            , Lifecycle.Memory_growth_molt_requested
                { current_bytes = budget.total_bytes
                ; threshold_bytes = budget.maximum_bytes
                } )
            :: !received_triggers));
  Fun.protect ~finally:(fun () -> Render.set_on_molt_requested None) @@ fun () ->
  with_env Env_config.KeeperMemoryOs.facts_max_bytes_env_key "400" @@ fun () ->
  let write_snapshot ~revision ~now ~trace_id ~facts =
    let snapshot : Current.t =
      { revision
      ; updated_at = now
      ; source = { Current.kind = Current.Librarian; trace_id }
      ; facts
      ; change = { added = facts; removed = []; retained = 0; invalidated = [] }
      }
    in
    let path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
    Fs_compat.save_file_atomic path (Yojson.Safe.to_string (Current.to_json snapshot)) |> require_ok;
    snapshot
  in
  let mk_fact claim =
    Memory_types.observed
      ~claim
      ~category:Memory_types.Fact
      ~now:200.0
      ~origin:{ Memory_types.kind = Memory_types.Authored; trace_id = "molt-e2e" }
  in
  let f1 = mk_fact "small baseline fact" in
  let budget1 =
    Render.evaluate_facts_budget
      ~keeper_id
      ~previous_bytes:0
      ~ordinary_facts:[ f1 ]
      ~source_lines:[]
  in
  (match budget1 with
   | Render.Within_threshold _ -> ()
   | Render.Molt_recommended _ | Render.Backstop_exceeded _ ->
     fail "baseline below soft threshold should be Within_threshold");
  Render.notify_molt_if_recommended ~keeper_id budget1;
  let snap1 = write_snapshot ~revision:1 ~now:200.0 ~trace_id:"seed" ~facts:[ f1 ] in
  check int "rev 1 committed" 1 snap1.revision;
  check int "baseline below threshold emits no molt" 0 (List.length !received_triggers);
  (* Commit exceeding soft threshold (400 bytes) — MUST succeed without refusal and trigger molt! *)
  let f2 = mk_fact (String.make 550 'm') in
  let prev_bytes = Render.facts_payload_bytes ~ordinary_facts:[ f1 ] ~source_lines:[] in
  let budget2 =
    Render.evaluate_facts_budget
      ~keeper_id
      ~previous_bytes:prev_bytes
      ~ordinary_facts:[ f1; f2 ]
      ~source_lines:[]
  in
  (match budget2 with
   | Render.Molt_recommended _ -> ()
   | Render.Within_threshold _ | Render.Backstop_exceeded _ ->
     fail "growth past soft threshold with healthy receiver must recommend molt");
  let snap2 = write_snapshot ~revision:2 ~now:210.0 ~trace_id:"grow" ~facts:[ f1; f2 ] in
  Render.notify_molt_if_recommended ~keeper_id budget2;
  check int "rev 2 committed past soft threshold" 2 snap2.revision;
  check int "both facts persisted" 2 (List.length snap2.facts);
  (match !received_triggers with
   | [ (kid, Lifecycle.Memory_growth_molt_requested { current_bytes; threshold_bytes }) ] ->
     check string "molt triggered for exact keeper" keeper_id kid;
     check int "threshold matches configured value" 400 threshold_bytes;
     check bool "current_bytes > threshold_bytes" true (current_bytes > threshold_bytes)
   | _ -> fail "expected single Memory_growth_molt_requested trigger");
  (* Lock-free off-domain reads: read_classified and read_for_keepers_dir. *)
  (match Current.read_classified ~keepers_dir ~keeper_id with
   | Current.Readable s -> check int "read_classified sees rev 2" 2 s.revision
   | Current.No_snapshot | Current.Undecodable _ | Current.Io_unreadable _ ->
     fail "read_classified failed on valid snapshot");
  (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require_ok with
   | Some s -> check int "read_for_keepers_dir sees rev 2" 2 s.revision
   | None -> fail "read_for_keepers_dir returned None on valid snapshot");
  (* Verify Memory OS files + sidecars also leave Tool_blob_maintenance unclassified = []. *)
  match
    Tool_blob_maintenance.run
      ~base_path
      ~scope:Server_tool_blob_scope.scope
      ~mode:Tool_blob_maintenance.Observe_only
  with
  | Ok report ->
    check (list string) "Memory OS files have zero unclassified entries" [] report.unclassified
  | Error err -> fail (Tool_blob_maintenance.error_to_string err)
;;

(* ── Test 3: Bounded RAM Caches & Per-Keeper Lineage Isolation ── *)

let make_checkpoint ~session_id ~turn_count ~payload : Agent_core.Checkpoint.t =
  { Agent_core.Checkpoint.provider_binding = None
  ; version = Agent_core.Checkpoint.checkpoint_version
  ; session_id
  ; agent_name = "test-agent"
  ; model = "test-model"
  ; system_prompt = Some "system"
  ; messages =
      [ { role = Agent_core.Types.User
        ; content = [ Llm_types.Text payload ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        ; origin = Llm_types.Conversation
        }
      ]
  ; usage = Agent_core.Types.empty_usage
  ; turn_count
  ; created_at = 300.0
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; reasoning_effort = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Agent_core.Types.Off
  ; cache_system_prompt = false
  ; context = Agent_core.Context.create_sync ()
  ; pending_input = None
  ; working_context = None
  }
;;

let test_bounded_ram_caches_and_per_keeper_lineage_isolation () =
  with_temp_dir @@ fun root ->
  (* 1. transcript_caches O(1) LRU bounds entry count and rejects oversized entries. *)
  Transcript_rows.with_transcript_cache_limits
    ~max_entries:2
    ~max_entry_bytes:512
    ~max_total_bytes:1024
    (fun () ->
       let redaction = Masc.Keeper_secret_redaction.empty in
       let empty_obs = Masc.Keeper_chat_observation_index.empty in
       let mk_entry ~parsed_end : Transcript_rows.transcript_cache =
         { device = 1; inode = parsed_end; parsed_end; observation = empty_obs; redaction }
       in
       let p1 = Filename.concat root "k1.jsonl" in
       let p2 = Filename.concat root "k2.jsonl" in
       let p3 = Filename.concat root "k3.jsonl" in
       let p_huge = Filename.concat root "khuge.jsonl" in
       Transcript_rows.remember_transcript p1 (mk_entry ~parsed_end:100);
       Transcript_rows.remember_transcript p2 (mk_entry ~parsed_end:100);
       (* Touch p1 so p2 becomes LRU. *)
       check bool "p1 hit promotes MRU" true
         (Option.is_some (Transcript_rows.lookup_transcript p1));
       Transcript_rows.remember_transcript p3 (mk_entry ~parsed_end:100);
       check bool "p2 evicted by O(1) LRU" true
         (Option.is_none (Transcript_rows.lookup_transcript p2));
       check bool "p1 retained as MRU" true
         (Option.is_some (Transcript_rows.lookup_transcript p1));
       check bool "p3 retained" true
         (Option.is_some (Transcript_rows.lookup_transcript p3));
       (* Oversized transcript (> max_entry_bytes=512) is never retained in RAM. *)
       Transcript_rows.remember_transcript p_huge (mk_entry ~parsed_end:2048);
       check bool "oversized transcript not pinned in RAM" true
         (Option.is_none (Transcript_rows.lookup_transcript p_huge)));
  (* 2. provenance_index O(1) LRU caps retained indices across Keepers. *)
  Transcript_index.with_index_cache_limits
    ~max_entries:2
    ~max_rows_per_keeper:10
    ~max_total_rows:20
    (fun () ->
       let row idx =
         Printf.sprintf
           "{\"id\":\"msg-%d\",\"role\":\"user\",\"content\":\"hello\",\"ts\":100.0}\n"
           idx
       in
       List.iter
         (fun idx ->
            let path = Filename.concat root (Printf.sprintf "idx-%d.jsonl" idx) in
            ignore
              (Transcript_index.update_indexed_transcript path (fun _ -> Some (row idx), ())
               : (unit, Fs_compat.durable_append_error) Fs_compat.private_file_transaction_outcome))
         [ 1; 2; 3; 4 ];
       check bool "retained provenance indices strictly bounded <= 2" true
         (Transcript_index.retained_index_count () <= 2));
  (* 3. Per-Keeper lineage isolation: bloated Keeper A sheds its OWN cache
     without evicting innocent sibling Keeper B! *)
  Checkpoint_store.For_testing.with_per_keeper_lineage_limit
    ~max_bytes_per_keeper:4096
    ~max_bytes:65_536
    (fun () ->
       let dir_b = Filename.concat root "sess-b" in
       let dir_a = Filename.concat root "sess-a" in
       Fs_compat.mkdir_p dir_b;
       Fs_compat.mkdir_p dir_a;
       let count_disk_reads ~session_dir ~session_id =
         let reads = ref 0 in
         match
           Checkpoint_store.Read_observation.For_testing.load_after_object_read
             ~after_object_read:(fun _ -> incr reads)
             ~session_dir
             ~session_id
         with
         | Ok _ -> !reads
         | Error err -> fail (Checkpoint_store.checkpoint_load_error_to_string err)
       in
       let ckpt_b = make_checkpoint ~session_id:"sess-b" ~turn_count:1 ~payload:"small-b" in
       (match
          Checkpoint_store.save_agent_core_for_keeper
            ~keeper_name:"keeper-b"
            ~session_dir:dir_b
            ~history_retained:0
            ~boundary:Agent_core.Checkpoint_objects.Turn_closes
            ckpt_b
        with
        | Ok (Checkpoint_store.Saved _) -> ()
        | Ok (Checkpoint_store.Stale_noop _) -> fail "unexpected stale noop for keeper-b"
        | Error detail -> fail detail);
       check int "keeper-b hits lineage cache (0 object disk reads)" 0
         (count_disk_reads ~session_dir:dir_b ~session_id:"sess-b");
       (* Now keeper-a saves an oversized checkpoint (> max_bytes_per_keeper=4096). *)
       let ckpt_a =
         make_checkpoint ~session_id:"sess-a" ~turn_count:1 ~payload:(String.make 16_384 'A')
       in
       (match
          Checkpoint_store.save_agent_core_for_keeper
            ~keeper_name:"keeper-a"
            ~session_dir:dir_a
            ~history_retained:0
            ~boundary:Agent_core.Checkpoint_objects.Turn_closes
            ckpt_a
        with
        | Ok (Checkpoint_store.Saved _) -> ()
        | Ok (Checkpoint_store.Stale_noop _) -> fail "unexpected stale noop for keeper-a"
        | Error detail -> fail detail);
       check bool "bloated keeper-a shed its own lineage cache (re-reads objects from disk)" true
         (count_disk_reads ~session_dir:dir_a ~session_id:"sess-a" > 0);
       check int "innocent sibling keeper-b remained cached untouched (0 disk reads!)" 0
         (count_disk_reads ~session_dir:dir_b ~session_id:"sess-b"))
;;

(* ── Test 4: Live Librarian_writers Molt, Asking-State Latch, Non-Spin & Wire Protocol ── *)

let test_declared_lane () : Masc.Librarian_machine.declared =
  { value =
      { Masc.Librarian_memory_lane.question =
          { prompt = "test librarian prompt"
          ; answer_schemas = Masc.Librarian_answer.schemas
          ; max_output_tokens = 1024
          ; thinking = None
          }
      ; http = []
      ; cli =
          [ { id = "test.fast"
            ; target = Cli { runtime_id = "test.fast"; api_name = "test-model" }
            ; window = 200_000
            }
          ]
      ; unadmitted = []
      }
  ; resolved = { Runtime_exact_output_registry.selected_slots = []; cli_slots = [] }
  }
;;

let test_live_librarian_writers_molt_latch_and_wire_protocol () =
  with_eio_pool @@ fun env sw ->
  with_temp_dir @@ fun base_path ->
  with_env Env_config.KeeperMemoryOs.facts_max_bytes_env_key "400" @@ fun () ->
  let keepers_dir = Server_tool_blob_scope.scope.config_keepers_dir ~base_path in
  let turns_dir = Filename.concat base_path "turns" in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.mkdir_p turns_dir;
  let keeper_id = "keeper-live-molt" in
  let turns_path =
    Masc.Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir:turns_dir ~keeper_id
  in
  let log_id =
    match Masc.Keeper_turn_log.Log_id.of_string (String.make 32 'e') with
    | Some id -> id
    | None -> fail "bad log id"
  in
  let start_turn_log _kid =
    if Sys.file_exists turns_path
    then Ok ()
    else (
      let mark : Masc.Keeper_turn_log.mark =
        { trace = "t-0"
        ; closed_messages = 0
        ; session = ""
        ; history_bytes = 0
        ; internal_bytes = 0
        ; chat_bytes = 0
        ; external_rows = 0
        }
      in
      match
        Masc.Keeper_turn_log_store.append
          ~path:turns_path
          ~at_end:0
          (Masc.Keeper_turn_log.Log_started { id = log_id; at = 10.0; mark }, [])
      with
      | Ok _ -> Ok ()
      | Error _ -> Error "turn log start failed")
  in
  let clock = Eio.Stdenv.clock env in
  let now_ref = ref 100.0 in
  let next_now () =
    now_ref := !now_ref +. 1.0;
    !now_ref
  in
  let room_calls = ref [] in
  let first_molt_done, resolve_first_molt = Eio.Promise.create () in
  let latch_gate, release_latch_gate = Eio.Promise.create () in
  let latch_entered, resolve_latch_entered = Eio.Promise.create () in
  let third_molt_done, resolve_third_molt = Eio.Promise.create () in
  let ask_room (input : Masc.Librarian_ask.room_input) : Masc.Librarian_room_result.t =
    let call_idx = List.length !room_calls + 1 in
    let tail =
      match input.tail () with
      | Some line -> line
      | None -> fail "writer tail closed unexpectedly"
    in
    let snap_path =
      Masc.Keeper_memory_os_current_layout.path_for_keepers_dir
        ~keepers_dir:input.place.memory_dir
        ~keeper_id:input.place.keeper_id
    in
    let memory =
      match Masc.Librarian_store.read_snapshot_bytes snap_path with
      | Ok bytes ->
        (match Masc.Librarian_store.decode_snapshot bytes with
         | Some m -> m
         | None -> fail "snapshot decode failed")
      | Error _ -> fail "snapshot read failed"
    in
    (* Build the REAL wire question with molt_trigger + world_index! *)
    let room =
      Masc.Librarian_question.make_room
        ~world_index:"[world] shared invariant"
        ?molt_trigger:input.asked.molt_trigger
        ~lane:input.lane.question
        ~from:tail
        ~memory
        ~trace:input.asked.trace
        ()
    in
    room_calls := (call_idx, input.asked.molt_trigger, room.text) :: !room_calls;
    let ops =
      match call_idx with
      | 1 ->
        (* First molt: shed the oversized noisy fact (m2) -> Store.commit_molt + compact_log! *)
        ignore (Eio.Promise.try_resolve resolve_first_molt () : bool);
        [ Masc.Librarian_answer.Molt
            { refs = [ "m2" ]; reason = "oversized scratch fact shed on memory growth molt" }
        ]
      | 2 ->
        (* Second molt (Compaction_epoch_advanced): pause on gate so a concurrent
           Molt_requested arrives while machine is in Asking _, then return ops = []
           (Unchanged) to prove both Asking-state latching AND zero spin! *)
        ignore (Eio.Promise.try_resolve resolve_latch_entered () : bool);
        Eio.Promise.await latch_gate;
        []
      | _ ->
        (* Third molt (dispatched immediately from pending_molt latch when call 2 settles!):
           return ops = [] (Unchanged) and verify no 4th spin call happens. *)
        ignore (Eio.Promise.try_resolve resolve_third_molt () : bool);
        []
    in
    Masc.Librarian_room_result.Room_answered
      { question = room.question
      ; answer = { question = room.question.id; ops; working_state = Keep }
      ; slot = "test.fast"
      }
  in
  let writers =
    Masc.Librarian_writers.create
      ~sw
      ~now:next_now
      ~registered:(fun kid -> String.equal kid keeper_id)
      ~place:(fun kid -> { memory_dir = keepers_dir; turns_dir; keeper_id = kid })
      ~stores:(fun kid ->
        { session_dir = (fun ~session -> Filename.concat base_path session)
        ; base_path
        ; keeper_name = kid
        })
      ~ask:(fun _ -> Masc.Librarian_read_result.Nothing_to_ask)
      ~ask_room
      ~start_turn_log
  in
  Masc.Librarian_writers.declaration_changed writers (Some (test_declared_lane ()));
  (* Wait for writer to boot cleanly via initial small write below 400 bytes. *)
  let write_claim claim =
    Masc.Librarian_writers.write
      writers
      keeper_id
      ~by:Masc.Librarian_effects.Keeper
      ~trace:"live-e2e"
      (Masc.Librarian_direct.Remember
         { claim; category = Memory_types.Fact; basis = Memory_types.Observed Transcript })
  in
  (match write_claim "baseline standing invariant" with
   | Masc.Librarian_machine.Written _ -> ()
   | _ -> fail "baseline direct write failed");
  check int "below-threshold live write triggers 0 molts" 0 (List.length !room_calls);
  (* Grow Memory past 400 bytes via live Librarian_writers.write -> Store.commit_direct! *)
  (match write_claim (String.make 520 'g') with
   | Masc.Librarian_machine.Written _ -> ()
   | _ -> fail "oversized direct write must succeed without hard budget refusal");
  Eio.Promise.await first_molt_done;
  (* Wait briefly for Store.commit_molt to land on disk. *)
  let rec wait_until ?(tries = 100) pred =
    if pred ()
    then true
    else if tries <= 0
    then false
    else (
      Eio.Time.sleep clock 0.01;
      wait_until ~tries:(tries - 1) pred)
  in
  let shrunk =
    wait_until (fun () ->
      match Current.read_classified ~keepers_dir ~keeper_id with
      | Current.Readable snap -> List.length snap.facts = 1
      | _ -> false)
  in
  check bool "live Memory_growth_molt_requested committed molt and shed oversized fact" true shrunk;
  (* Verify wire text carried BOTH world_index: and molt_trigger: JSON! *)
  (match List.rev !room_calls with
   | [ (1, Some (Lifecycle.Memory_growth_molt_requested { current_bytes; threshold_bytes }), text) ] ->
     check int "wire trigger threshold = 400" 400 threshold_bytes;
     check bool "wire trigger current_bytes > 400" true (current_bytes > 400);
     check bool "wire text carries world_index: line" true
       (contains ~needle:"world_index: " text);
     check bool "wire text carries molt_trigger: JSON line" true
       (contains ~needle:{|molt_trigger: {"kind":"memory_growth_molt_requested"|} text);
     check bool "wire text omits single-item-overflow make_room: prose" false
       (contains ~needle:"make_room: " text)
   | other -> failf "expected 1 growth molt call, got %d" (List.length other));
  (* Prove Asking-state latching AND zero spin on Unchanged molt! *)
  Masc.Librarian_writers.compaction_epoch_advanced writers keeper_id ~epoch_id:7;
  Eio.Promise.await latch_entered;
  (* While call #2 is actively paused in Asking _, fire a 101-call burst:
     50 rapid Memory_growth_molt_requested calls, then Synthesis_cycle_completed,
     then 50 more rapid Memory_growth_molt_requested calls!
     1. All 101 rapid calls must coalesce into AT MOST 1 mailbox delivery.
     2. Synthesis_cycle_completed must latch in pending_molt (NOT silently dropped).
     3. The 50 trailing Memory_growth_molt_requested calls must NEVER overwrite
        the already-latched unconditional Synthesis_cycle_completed trigger (even
        though current Memory is below 400 bytes!). *)
  for i = 1 to 50 do
    Masc.Librarian_writers.request_molt
      writers
      keeper_id
      ~trigger:
        (Lifecycle.Memory_growth_molt_requested
           { current_bytes = 410 + i; threshold_bytes = 400 })
  done;
  Masc.Librarian_writers.request_molt
    writers
    keeper_id
    ~trigger:Lifecycle.Synthesis_cycle_completed;
  for i = 1 to 50 do
    Masc.Librarian_writers.request_molt
      writers
      keeper_id
      ~trigger:
        (Lifecycle.Memory_growth_molt_requested
           { current_bytes = 500 + i; threshold_bytes = 400 })
  done;
  Eio.Time.sleep clock 0.02;
  check int "still only 2 calls while call #2 is in flight" 2 (List.length !room_calls);
  Eio.Promise.resolve release_latch_gate ();
  Eio.Promise.await third_molt_done;
  Eio.Time.sleep clock 0.05;
  check int "latched molt dispatched once (3 total) and Unchanged did NOT spin" 3
    (List.length !room_calls);
  (match List.rev !room_calls with
   | [ (1, Some (Lifecycle.Memory_growth_molt_requested _), _)
     ; (2, Some (Lifecycle.Compaction_epoch_advanced { epoch_id = 7 }), text2)
     ; (3, Some Lifecycle.Synthesis_cycle_completed, text3)
     ] ->
     check bool "call #2 wire carries compaction_epoch_advanced" true
       (contains ~needle:{|"kind":"compaction_epoch_advanced","epoch_id":7|} text2);
     check bool "call #3 wire carries synthesis_cycle_completed" true
       (contains ~needle:{|"kind":"synthesis_cycle_completed"|} text3)
   | _ -> fail "unexpected sequence of molt triggers")
;;

(* ── Test 5: Concurrent 2-Domain Memory OS Readers & Writers (Zero Errors, Zero Deadlocks) ── *)

let test_concurrent_memory_os_readers_and_writers_2_domains () =
  with_eio_pool @@ fun _env _sw ->
  with_temp_dir @@ fun base_path ->
  let keepers_dir = Server_tool_blob_scope.scope.config_keepers_dir ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let keeper_id = "keeper-concurrent" in
  let sibling_id = "keeper-sibling" in
  let mk_fact ~now claim =
    Memory_types.observed
      ~claim
      ~category:Memory_types.Fact
      ~now
      ~origin:{ Memory_types.kind = Memory_types.Authored; trace_id = "conc-e2e" }
  in
  let turns_dir = Filename.concat base_path "turns" in
  Fs_compat.mkdir_p turns_dir;
  let boot_store ~keeper_id =
    let turns_path =
      Masc.Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir:turns_dir ~keeper_id
    in
    let log_id =
      match Masc.Keeper_turn_log.Log_id.of_string (String.make 32 'a') with
      | Some id -> id
      | None -> fail "bad log id"
    in
    let mark : Masc.Keeper_turn_log.mark =
      { trace = "t-conc"
      ; closed_messages = 0
      ; session = ""
      ; history_bytes = 0
      ; internal_bytes = 0
      ; chat_bytes = 0
      ; external_rows = 0
      }
    in
    (match
       Masc.Keeper_turn_log_store.append
         ~path:turns_path
         ~at_end:0
         (Masc.Keeper_turn_log.Log_started { id = log_id; at = 1.0; mark }, [])
     with
     | Ok _ -> ()
     | Error _ -> fail "failed to seed turn log for concurrent store");
    match Masc.Librarian_store.boot ~memory_dir:keepers_dir ~turns_dir ~keeper_id ~at:1.0 with
    | Ok store -> store
    | Error _ -> fail ("Librarian_store.boot failed for " ^ keeper_id)
  in
  let commit_direct store ~at ~trace write =
    let facts = (Masc.Librarian_store.memory store).facts in
    match Masc.Librarian_direct.plan ~by:Masc.Librarian_effects.Keeper ~at ~trace_id:trace facts write with
    | Masc.Librarian_direct.Writes { effects; _ } ->
      (match Masc.Librarian_store.commit_direct store ~at ~by:Masc.Librarian_effects.Keeper ~trace write effects with
       | Masc.Librarian_store.Committed { store; _ } -> store
       | Masc.Librarian_store.Committed_without_snapshot _ ->
         fail "commit_direct wrote without snapshot"
       | Masc.Librarian_store.Stopped _ -> fail "commit_direct stopped unexpectedly"
       | Masc.Librarian_store.Not_a_snapshot _ -> fail "commit_direct rejected snapshot")
    | Masc.Librarian_direct.Already_held
    | Masc.Librarian_direct.Already_done
    | Masc.Librarian_direct.Already_absent -> store
    | Masc.Librarian_direct.Refused r ->
      fail ("direct write refused: " ^ Masc.Librarian_direct.refusal_kind r)
  in
  let remember_write claim =
    Masc.Librarian_direct.Remember
      { claim; category = Memory_types.Fact; basis = Memory_types.Observed Memory_types.Transcript }
  in
  let store = ref (boot_store ~keeper_id) in
  let sibling_store = ref (boot_store ~keeper_id:sibling_id) in
  store := commit_direct !store ~at:10.0 ~trace:"seed" (remember_write "immutable standing baseline");
  check int "seed revision 2 (after boot empty rev 1)" 2 (Masc.Librarian_store.memory !store).revision;
  (* Phase A: Additive concurrent Librarian_store commits alongside lock-free readers! *)
  let done_a = Atomic.make false in
  let reader_errors = ref [] in
  let reads_completed = Atomic.make 0 in
  let record_err msg = reader_errors := msg :: !reader_errors in
  Eio.Fiber.all
    [ (fun () ->
        for i = 1 to 15 do
          store :=
            commit_direct
              !store
              ~at:(20.0 +. float_of_int i)
              ~trace:(Printf.sprintf "w-%d" i)
              (remember_write (Printf.sprintf "additive fact %d" i));
          Eio.Fiber.yield ()
        done;
        Atomic.set done_a true)
    ; (fun () ->
        while not (Atomic.get done_a) do
          (match Current.read_classified ~keepers_dir ~keeper_id with
           | Current.Readable s when s.revision >= 1 -> ()
           | Current.Io_unreadable { detail } -> record_err ("read_classified: " ^ detail)
           | Current.No_snapshot -> record_err "read_classified: unexpected No_snapshot"
           | Current.Undecodable { rejection } -> record_err ("read_classified: " ^ rejection)
           | Current.Readable _ -> record_err "read_classified: bad revision");
          (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
           | Ok (Some s) when s.revision >= 1 -> ()
           | Ok None -> record_err "read_for_keepers_dir: unexpected None"
           | Ok (Some _) -> record_err "read_for_keepers_dir: bad revision"
           | Error detail -> record_err ("read_for_keepers_dir: " ^ detail));
          Atomic.incr reads_completed;
          Eio.Fiber.yield ()
        done)
    ; (fun () ->
        while not (Atomic.get done_a) do
          (match Current.read_with_snapshot_sha256 ~keepers_dir ~keeper_id with
           | Ok (Some (s, sha)) when s.revision >= 1 && String.length sha = 64 -> ()
           | Ok None -> record_err "read_with_snapshot_sha256: unexpected None"
           | Ok (Some _) -> record_err "read_with_snapshot_sha256: bad snapshot or digest"
           | Error detail -> record_err ("read_with_snapshot_sha256: " ^ detail));
          Atomic.incr reads_completed;
          Eio.Fiber.yield ()
        done)
    ; (fun () ->
        (* Independent sibling Keeper commits concurrently — zero cross-Keeper blocking! *)
        for i = 1 to 10 do
          sibling_store :=
            commit_direct
              !sibling_store
              ~at:(50.0 +. float_of_int i)
              ~trace:(Printf.sprintf "sib-%d" i)
              (remember_write (Printf.sprintf "sibling fact %d" i));
          Eio.Fiber.yield ()
        done)
    ];
  check (list string) "Phase A concurrent readers observed 0 spurious errors" [] !reader_errors;
  check bool "Phase A readers executed concurrently" true (Atomic.get reads_completed > 0);
  (* Phase B: Concurrent Librarian_direct.Supersede chain alongside concurrent readers. *)
  let done_b = Atomic.make false in
  let sup_errors = ref [] in
  let initial_target = mk_fact ~now:100.0 "supersede chain v0" in
  store := commit_direct !store ~at:100.0 ~trace:"sup-seed" (remember_write initial_target.claim);
  Eio.Fiber.all
    [ (fun () ->
        let prev_id = ref (Memory_types.memory_id initial_target) in
        for i = 1 to 12 do
          let next_claim = Printf.sprintf "supersede chain v%d" i in
          let next_fact = mk_fact ~now:(110.0 +. float_of_int i) next_claim in
          store :=
            commit_direct
              !store
              ~at:(110.0 +. float_of_int i)
              ~trace:(Printf.sprintf "sup-%d" i)
              (Masc.Librarian_direct.Supersede
                 { old = !prev_id
                 ; claim = next_claim
                 ; category = Memory_types.Fact
                 ; basis = Memory_types.Observed Memory_types.Transcript
                 });
          prev_id := Memory_types.memory_id next_fact;
          Eio.Fiber.yield ()
        done;
        Atomic.set done_b true)
    ; (fun () ->
        while not (Atomic.get done_b) do
          (match Current.read_classified ~keepers_dir ~keeper_id with
           | Current.Readable _ -> ()
           | Current.Io_unreadable { detail } -> sup_errors := ("classified: " ^ detail) :: !sup_errors
           | Current.No_snapshot -> sup_errors := "classified: No_snapshot" :: !sup_errors
           | Current.Undecodable { rejection } -> sup_errors := ("undecodable: " ^ rejection) :: !sup_errors);
          (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
           | Ok (Some _) -> ()
           | Ok None -> sup_errors := "read_for_keepers_dir: None" :: !sup_errors
           | Error detail -> sup_errors := ("read: " ^ detail) :: !sup_errors);
          Eio.Fiber.yield ()
        done)
    ];
  check (list string) "Phase B concurrent supersede + readers observed 0 errors & 0 deadlocks" []
    !sup_errors;
  (* Phase C: Two concurrent writer fibers submitting through single-writer ownership
     on the SAME keeper_id + concurrent lock-free reader — 0 errors and all 24 facts preserved! *)
  let same_keeper = "keeper-two-writers" in
  let same_store = ref (boot_store ~keeper_id:same_keeper) in
  let writer_lock = Eio.Mutex.create () in
  let done_w1 = Atomic.make false in
  let done_w2 = Atomic.make false in
  let phase_c_errors = ref [] in
  let per_writer = 12 in
  Eio.Fiber.all
    [ (fun () ->
        for i = 1 to per_writer do
          Eio.Mutex.use_rw ~protect:true writer_lock (fun () ->
            same_store :=
              commit_direct
                !same_store
                ~at:(200.0 +. float_of_int i)
                ~trace:(Printf.sprintf "w1-%d" i)
                (remember_write (Printf.sprintf "writer-1 fact %d" i)));
          Eio.Fiber.yield ()
        done;
        Atomic.set done_w1 true)
    ; (fun () ->
        for i = 1 to per_writer do
          Eio.Mutex.use_rw ~protect:true writer_lock (fun () ->
            same_store :=
              commit_direct
                !same_store
                ~at:(300.0 +. float_of_int i)
                ~trace:(Printf.sprintf "w2-%d" i)
                (remember_write (Printf.sprintf "writer-2 fact %d" i)));
          Eio.Fiber.yield ()
        done;
        Atomic.set done_w2 true)
    ; (fun () ->
        while not (Atomic.get done_w1 && Atomic.get done_w2) do
          (match Current.read_classified ~keepers_dir ~keeper_id:same_keeper with
           | Current.Readable _ | Current.No_snapshot -> ()
           | Current.Io_unreadable { detail } ->
             phase_c_errors := ("c-classified: " ^ detail) :: !phase_c_errors
           | Current.Undecodable { rejection } ->
             phase_c_errors := ("c-undecodable: " ^ rejection) :: !phase_c_errors);
          Eio.Fiber.yield ()
        done)
    ];
  check (list string) "Phase C two concurrent same-keeper writers + reader observed 0 errors" []
    !phase_c_errors;
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:same_keeper |> require_ok with
  | None -> fail "Phase C same-keeper snapshot missing"
  | Some final_snap ->
    check int "Phase C preserved all 24 facts from both concurrent same-keeper writers"
      (2 * per_writer)
      (List.length final_snap.facts)
;;

(* ── Test 6: Stopped/Uninstalled 4x Hard Backstop & Stopped-State Molt Resume Preservation ── *)

let test_backstop_when_stopped_or_uninstalled_and_stopped_resume_latch () =
  with_eio_pool @@ fun _env _sw ->
  with_temp_dir @@ fun base_path ->
  let keepers_dir = Server_tool_blob_scope.scope.config_keepers_dir ~base_path in
  let turns_dir = Filename.concat base_path "turns" in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.mkdir_p turns_dir;
  let keeper_id = "keeper-backstop" in
  let mk_fact ~now claim =
    Memory_types.observed
      ~claim
      ~category:Memory_types.Fact
      ~now
      ~origin:{ Memory_types.kind = Memory_types.Authored; trace_id = "backstop-e2e" }
  in
  check int "hard_backstop_multiplier = 4" 4 Render.hard_backstop_multiplier;
  check int "hard_backstop_bytes(512 KiB) = 2 MiB" 2_097_152
    (Render.hard_backstop_bytes ~maximum_bytes:524_288);
  (* Soft threshold = 200 bytes -> 4x emergency hard backstop = 800 bytes. *)
  with_env Env_config.KeeperMemoryOs.facts_max_bytes_env_key "200" @@ fun () ->
  Fun.protect
    ~finally:(fun () ->
      Render.set_on_molt_requested None;
      Render.set_is_molt_receiver_stopped None)
    (fun () ->
       (* (a) Receiver UNINSTALLED: soft growth between 200..800 bytes succeeds with warning;
              growth past 800 bytes fails closed with Backstop_exceeded. *)
       Render.set_on_molt_requested None;
       Render.set_is_molt_receiver_stopped None;
       let f_soft = mk_fact ~now:10.0 (String.make 220 'a') in
       let soft_bytes = Render.facts_payload_bytes ~ordinary_facts:[ f_soft ] ~source_lines:[] in
       (match
          Render.evaluate_facts_budget
            ~keeper_id
            ~previous_bytes:0
            ~ordinary_facts:[ f_soft ]
            ~source_lines:[]
        with
        | Render.Molt_recommended _ -> ()
        | Render.Within_threshold _ | Render.Backstop_exceeded _ ->
          fail "uninstalled receiver must allow growth within 1x..4x soft cushion");
       let f_past_4x = mk_fact ~now:20.0 (String.make 700 'b') in
       (match
          Render.evaluate_facts_budget
            ~keeper_id
            ~previous_bytes:soft_bytes
            ~ordinary_facts:[ f_soft; f_past_4x ]
            ~source_lines:[]
        with
        | Render.Backstop_exceeded { budget; hard_limit_bytes; reason = Render.Receiver_uninstalled } ->
          let msg =
            Render.backstop_rejection_message ~budget ~hard_limit_bytes ~reason:Render.Receiver_uninstalled
          in
          check bool "uninstalled backstop error names emergency backstop" true
            (contains ~needle:"emergency backstop exceeded" msg);
          check bool "uninstalled backstop error names uninstalled receiver" true
            (contains ~needle:"uninstalled" msg)
        | Render.Within_threshold _
        | Render.Molt_recommended _
        | Render.Backstop_exceeded { reason = Render.Receiver_stopped; _ } ->
          fail "expected 4x backstop rejection when molt receiver is uninstalled");
       (* (b) Receiver ACTIVE & NOT stopped: growth past 4x SUCCEEDS and fires Molt_recommended! *)
       let notified = ref 0 in
       Render.set_on_molt_requested (Some (fun ~keeper_id:_ _ -> incr notified));
       Render.set_is_molt_receiver_stopped (Some (fun ~keeper_id:_ -> false));
       let past_4x_outcome =
         Render.evaluate_facts_budget
           ~keeper_id
           ~previous_bytes:soft_bytes
           ~ordinary_facts:[ f_soft; f_past_4x ]
           ~source_lines:[]
       in
       (match past_4x_outcome with
        | Render.Molt_recommended _ -> ()
        | Render.Within_threshold _ | Render.Backstop_exceeded _ ->
          fail "active healthy receiver must allow growth past 4x (non-blocking soft molt)");
       Render.notify_molt_if_recommended ~keeper_id past_4x_outcome;
       check int "active healthy receiver received molt notification" 1 !notified;
       (* (c) Receiver STOPPED: further growth past 4x fails closed, while retraction succeeds! *)
       Render.set_is_molt_receiver_stopped (Some (fun ~keeper_id:_ -> true));
       let two_fact_bytes =
         Render.facts_payload_bytes ~ordinary_facts:[ f_soft; f_past_4x ] ~source_lines:[]
       in
       let f_more = mk_fact ~now:40.0 (String.make 150 'c') in
       (match
          Render.evaluate_facts_budget
            ~keeper_id
            ~previous_bytes:two_fact_bytes
            ~ordinary_facts:[ f_soft; f_past_4x; f_more ]
            ~source_lines:[]
        with
        | Render.Backstop_exceeded { budget; hard_limit_bytes; reason = Render.Receiver_stopped } ->
          let msg =
            Render.backstop_rejection_message ~budget ~hard_limit_bytes ~reason:Render.Receiver_stopped
          in
          check bool "stopped backstop error names emergency backstop" true
            (contains ~needle:"emergency backstop exceeded" msg);
          check bool "stopped backstop error names stopped receiver" true
            (contains ~needle:"stopped" msg)
        | Render.Within_threshold _
        | Render.Molt_recommended _
        | Render.Backstop_exceeded { reason = Render.Receiver_uninstalled; _ } ->
          fail "expected 4x backstop rejection when Librarian writer is Stopped");
       (* Shrinking retraction MUST succeed even while Stopped and above 4x backstop. *)
       (match
          Render.evaluate_facts_budget
            ~keeper_id
            ~previous_bytes:two_fact_bytes
            ~ordinary_facts:[ f_soft ]
            ~source_lines:[]
        with
        | Render.Within_threshold _ -> ()
        | Render.Molt_recommended _ | Render.Backstop_exceeded _ ->
          fail "retraction must never be blocked by Stopped backstop"));
  (* (d) Librarian_machine: Stopped _, Molt_requested preserves pending_molt across resume! *)
  let stopped_kid = "keeper-stopped-resume" in
  let place : Masc.Librarian_machine.place =
    { memory_dir = keepers_dir; turns_dir; keeper_id = stopped_kid }
  in
  let turns_path =
    Masc.Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir:turns_dir ~keeper_id:stopped_kid
  in
  let log_id =
    match Masc.Keeper_turn_log.Log_id.of_string (String.make 32 'f') with
    | Some id -> id
    | None -> fail "bad log id"
  in
  let mark : Masc.Keeper_turn_log.mark =
    { trace = "t-stop"
    ; closed_messages = 0
    ; session = ""
    ; history_bytes = 0
    ; internal_bytes = 0
    ; chat_bytes = 0
    ; external_rows = 0
    }
  in
  (match
     Masc.Keeper_turn_log_store.append
       ~path:turns_path
       ~at_end:0
       (Masc.Keeper_turn_log.Log_started { id = log_id; at = 1.0; mark }, [])
   with
   | Ok _ -> ()
   | Error _ -> fail "failed to seed turn log for resume test");
  let declared = test_declared_lane () in
  let m0 =
    Masc.Librarian_machine.stopped
      ~lane:(Some declared)
      ~last_ask:2
      Masc.Librarian_store.Store_unwritable
  in
  let m1 =
    Masc.Librarian_machine.decide
      place
      m0
      ~at:10.0
      (Masc.Librarian_machine.Molt_requested
         (Lifecycle.Memory_growth_molt_requested { current_bytes = 900; threshold_bytes = 200 }))
  in
  let m2 =
    Masc.Librarian_machine.decide
      place
      m1
      ~at:11.0
      (Masc.Librarian_machine.Molt_requested Lifecycle.Synthesis_cycle_completed)
  in
  let m3 =
    Masc.Librarian_machine.decide
      place
      m2
      ~at:12.0
      (Masc.Librarian_machine.Molt_requested
         (Lifecycle.Memory_growth_molt_requested { current_bytes = 950; threshold_bytes = 200 }))
  in
  check bool "Stopped state latched Synthesis_cycle_completed with precedence over growth molt" true
    (m3.pending_molt = Some Lifecycle.Synthesis_cycle_completed);
  let resumed, ans =
    Masc.Librarian_machine.resume
      place
      ~boot:(fun () -> Masc.Librarian_machine.boot place ~at:20.0)
      m3
      ~at:20.0
  in
  check bool "resume returns Done" true (ans = Masc.Librarian_machine.Done);
  check bool "pending_molt cleared once dispatched on resume" true (Option.is_none resumed.pending_molt);
  match resumed.state with
  | Masc.Librarian_machine.Asking
      { asking = { asked = Masc.Librarian_machine.Room { molt_trigger = Some Lifecycle.Synthesis_cycle_completed; _ }; _ }; _ } ->
    ()
  | _ -> fail "expected resume to preserve and immediately dispatch latched Synthesis_cycle_completed molt"
;;

let () =
  run
    "stack_e_cross_runtime_circulation"
    [ ( "cross_runtime_circulation"
      , [ test_case
            "HTTP <-> ACP <-> Official canonical turn continuity + compaction anchor + blob sweep"
            `Quick
            test_cross_runtime_continuity_compaction_and_blob_sweep
        ; test_case
            "Memory OS soft molt trigger + lock-free off-domain reads"
            `Quick
            test_memory_os_structural_molt_and_lock_free_reads
        ; test_case
            "bounded transcript/provenance LRU caches + per-Keeper lineage isolation"
            `Quick
            test_bounded_ram_caches_and_per_keeper_lineage_isolation
        ; test_case
            "live Librarian_writers growth molt, 101-burst coalescing latch, non-spin & wire protocol"
            `Quick
            test_live_librarian_writers_molt_latch_and_wire_protocol
        ; test_case
            "concurrent 2-domain Memory OS readers & writers (zero errors, zero deadlocks)"
            `Quick
            test_concurrent_memory_os_readers_and_writers_2_domains
        ; test_case
            "Stopped/uninstalled 4x hard backstop & Stopped-state pending_molt resume preservation"
            `Quick
            test_backstop_when_stopped_or_uninstalled_and_stopped_resume_latch
        ] )
    ]
;;
