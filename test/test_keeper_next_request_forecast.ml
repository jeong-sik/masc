(* The forecast runs the turn's own composition forward. These cases pin
   the arithmetic on a synthetic history so the numbers are checkable by
   hand: a seeded front carries everything from it, a front whose atom is
   gone or opens with another message is dropped, and without a front
   everything goes. The
   assembly cases pin the order the request carries its parts. *)

open Masc

let message role text : Agent_core.Types.message =
  { role; content = [ Agent_core.Types.Text text ]; name = None; tool_call_id = None; metadata = [] }

(* One user/assistant exchange per index, each side [n] bytes of text. *)
let history ~exchanges ~text_bytes =
  List.concat_map
    (fun index ->
      let text = String.make text_bytes (Char.chr (Char.code 'a' + (index mod 26))) in
      [ message Agent_core.Types.User text; message Agent_core.Types.Assistant text ])
    (List.init exchanges Fun.id)

(* One measurer for the whole walk, as the projection uses one: a measurer
   owns a buffer, so one per message would cost more than the strings the
   measurer exists to avoid. *)
let atom_bytes messages =
  let measure = Keeper_context_core.message_measurer () in
  List.fold_left (fun sum m -> sum + measure m) 0 messages

(* A front measured on [messages]: its index and the message that opens it. *)
let seed ~messages first_atom : Keeper_carried_front.seed =
  match Runtime_model_input_tail_window.atom_opening_digest messages first_atom with
  | Some front_digest -> { first_atom; front_digest; source = Keeper_carried_front.Ledger }
  | None -> Alcotest.fail "the seed's own history has the atom"

let carry ?front ?counted_tokens messages =
  Keeper_next_request_forecast.carry
    ~measure:(Keeper_context_core.message_measurer ())
    ~front
    ~counted_tokens
    messages

let carried (c : Keeper_next_request_forecast.carried) = c

(* Ten exchanges are twenty atoms: each [User] and [Assistant] message opens
   one, and only [Tool] joins the assistant that issued it — the counting
   [Runtime_model_input_tail_window.annotate] pins. A front at atom 6 carries
   the last fourteen. *)
let test_a_seeded_front_carries_everything_from_it () =
  let messages = history ~exchanges:10 ~text_bytes:100 in
  let c = carried (carry ~front:(seed ~messages 6) ~counted_tokens:9_000 messages) in
  Alcotest.(check int) "front" 6 c.first_atom;
  Alcotest.(check int) "fourteen atoms" 14 c.kept_atoms;
  Alcotest.(check bool) "its bytes are a proper part of the history" true
    (c.transmitted_bytes > 0 && c.transmitted_bytes < atom_bytes messages);
  Alcotest.(check bool) "the origin is the seed's" true
    (c.origin = Keeper_carried_front.Carried Keeper_carried_front.Ledger);
  Alcotest.(check (option int)) "the count rides along" (Some 9_000) c.counted_tokens;
  Alcotest.(check (option int)) "atom 6 is a user message, so no preamble rides" None
    c.preamble_bytes

(* Atom 7 is an assistant message. A conversation cannot open on one, so
   the range prepends the constant preamble and counts it in the bytes. *)
let test_a_range_opening_on_an_assistant_measures_its_preamble () =
  let messages = history ~exchanges:10 ~text_bytes:100 in
  let c = carried (carry ~front:(seed ~messages 7) messages) in
  Alcotest.(check int) "thirteen atoms" 13 c.kept_atoms;
  match c.preamble_bytes with
  | None -> Alcotest.fail "a preamble rides when the oldest carried atom is an assistant's"
  | Some preamble ->
    Alcotest.(check bool) "measured, not counted as zero" true (preamble > 0);
    Alcotest.(check int) "the transmitted bytes are the preamble and the carried atoms"
      (preamble + atom_bytes (List.filteri (fun index _ -> index >= 7) messages))
      c.transmitted_bytes

(* The front was measured at atom 3,100 of a longer history; a purge left ten.
   The position names nothing here, so the request starts over without a
   front. *)
let test_a_front_the_history_shrank_under_is_dropped () =
  let messages = history ~exchanges:5 ~text_bytes:100 in
  let long = history ~exchanges:1_600 ~text_bytes:1 in
  let c = carried (carry ~front:(seed ~messages:long 3_100) ~counted_tokens:91_000 messages) in
  Alcotest.(check int) "from the first atom" 0 c.first_atom;
  Alcotest.(check int) "all ten" 10 c.kept_atoms;
  Alcotest.(check bool) "the origin says no front" true
    (c.origin = Keeper_carried_front.Whole_history);
  Alcotest.(check (option int)) "and no count rides along" None c.counted_tokens

(* The history still has atom 6, but it opens with another message: atoms
   before the front were removed. The count is irrelevant; the position does
   not hold. *)
let test_a_front_that_opens_with_another_message_is_dropped () =
  let messages = history ~exchanges:10 ~text_bytes:100 in
  let measured_on = history ~exchanges:10 ~text_bytes:50 in
  let c = carried (carry ~front:(seed ~messages:measured_on 6) ~counted_tokens:9_000 messages) in
  Alcotest.(check int) "from the first atom" 0 c.first_atom;
  Alcotest.(check int) "all twenty" 20 c.kept_atoms;
  Alcotest.(check bool) "the origin says no front" true
    (c.origin = Keeper_carried_front.Whole_history)

let test_without_a_front_everything_goes () =
  let messages = history ~exchanges:5 ~text_bytes:100 in
  let c = carried (carry messages) in
  Alcotest.(check int) "from the first atom" 0 c.first_atom;
  Alcotest.(check int) "all ten" 10 c.kept_atoms;
  Alcotest.(check bool) "the origin says so" true
    (c.origin = Keeper_carried_front.Whole_history)

(* The real forecast entrypoint reads a persisted meta, checkpoint and turn
   store. A recent-row limit for byte-composition readings must not also
   limit the search for the last response-observed front. The synthetic
   runtime is never called; the test observes only the forecast's range. *)
let test_forecast_reads_an_observed_front_beyond_unobserved_rows () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let previous_fs = Fs_compat.get_fs_opt () in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    match previous_fs with
    | Some fs -> Fs_compat.set_fs fs
    | None -> Fs_compat.clear_fs ());
  let base_path = Masc_test_deps.setup_test_workspace () in
  Eio.Switch.on_release sw (fun () -> Masc_test_deps.cleanup_test_workspace base_path);
  let config = Workspace.default_config base_path in
  let config_path = Filename.concat base_path "runtime.toml" in
  Out_channel.with_open_bin config_path (fun output ->
    output_string output
      {|[runtime]
default = "forecast.seed"
[providers.forecast]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"
[models.seed]
api-name = "forecast-test-model"
max-context = 8192
tools-support = true
streaming = false
[forecast.seed]
max-concurrent = 1
|});
  (match Runtime.init_default ~config_path with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String "forecast-cold-entry" ])
    with
    | Ok meta -> meta
    | Error detail -> Alcotest.fail detail
  in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let persisted = history ~exchanges:5 ~text_bytes:100 in
  let checkpoint : Agent_core.Checkpoint.t =
    { version = Agent_core.Checkpoint.checkpoint_version
    ; session_id = trace_id
    ; agent_name = meta.name
    ; model = "forecast-test-model"
    ; system_prompt = None
    ; messages = persisted
    ; usage = Agent_core.Types.empty_usage
    ; turn_count = 1
    ; created_at = 0.
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
    ; mcp_sessions = []
    ; working_context = None
    }
  in
  let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
  (match
     Keeper_checkpoint_store.save_agent_core_classified ~session_dir ~history_retained:0
       checkpoint
   with
   | Ok _ -> ()
   | Error detail -> Alcotest.fail detail);
  let store = Keeper_types_support.keeper_turn_record_store config meta.name in
  Eio.Switch.on_release sw (fun () -> Dated_jsonl.prepare_for_directory_removal store);
  let _, total_atoms = Runtime_model_input_tail_window.annotate persisted in
  let window : Turn_record.model_input_window =
    { transmitted_atoms = total_atoms - 8
    ; total_atoms
    ; measurement = Turn_record.Wire_shape
    ; front_atom_digest = (seed ~messages:persisted 8).front_digest
    }
  in
  let write_record ~turn response_observed_model_input =
    Keeper_turn_record_writer.write
      ~config ~keeper_name:meta.name ~agent_name:meta.name ~turn_kind:Turn_record.Direct
      ~trace_id ~absolute_turn:turn ~runtime_profile:"forecast.seed"
      ~selected_model:None ~finish_reason:None ~context_window:None
      ~price_input_per_million:None ~price_output_per_million:None
      ~request_latency_ms:None ~ttfrc_ms:None ~request_wire_observation:None
      ~model_input_window:(Some window) ~response_observed_model_input
      ~raw_trace_run_ref:None
      ~sampling:{ temperature = None; top_p = None; max_tokens = None; enable_thinking = None }
      ~usage:
        { input_tokens = None
        ; output_tokens = None
        ; cache_creation_input_tokens = None
        ; cache_read_input_tokens = None
        ; scope = Runtime_usage_scope.Usage_scope_unavailable
        }
      ~execution_ids:[] ~blocks:[] ~input_components:None ~tool_surface_ref:None ()
  in
  write_record ~turn:1 (Some { Turn_record.runtime_profile = "forecast.seed"; window });
  (* The former seed reader stopped after 200 rows, even when none carried
     a response observation. This is the regression boundary, not a new cap. *)
  let unobserved_rows = 200 in
  for index = 1 to unobserved_rows do
    write_record ~turn:(index + 1) None
  done;
  Alcotest.(check int) "all turn records were appended"
    (unobserved_rows + 1) (Dated_jsonl.count_entries store);
  match Keeper_next_request_forecast.forecast ~config ~keeper_name:meta.name with
  | Error detail -> Alcotest.fail detail
  | Ok forecast ->
    Alcotest.(check int) "the forecast loaded the persisted checkpoint" 10
      forecast.checkpoint_messages;
    (match forecast.candidates with
     | [ candidate ] ->
       Alcotest.(check string) "the configured runtime was resolved" "forecast.seed"
         candidate.runtime_id;
       (match candidate.carried with
        | None -> Alcotest.fail "the materialized Agent Core runtime must have a range"
        | Some carried ->
          Alcotest.(check int) "the older observed front survives the recent-row limit" 8
            carried.first_atom;
          Alcotest.(check int) "two retained atoms plus the forecast wake" 3 carried.kept_atoms;
          Alcotest.(check bool) "the range names the observed turn" true
            (carried.origin =
             Keeper_carried_front.Carried (Keeper_carried_front.Turn_record { turn = 1 })))
     | _ -> Alcotest.fail "one configured runtime must produce one forecast candidate")

let component component bytes : Turn_record.input_component = { component; bytes }

(* lane-smith turn 3646 on 2026-09-16: memory recall and dynamic context
   pinned beside the schemas and instructions, tool results in the history. *)
let first_round_composition =
  [ component Turn_record.Tool_schemas 71_578
  ; component (Turn_record.Prompt_block Prompt_block_id.Keeper_instructions) 10_832
  ; component (Turn_record.Prompt_block Prompt_block_id.Memory_os_recall) 150_000
  ; component (Turn_record.Prompt_block Prompt_block_id.Dynamic_context) 9_710
  ; component Turn_record.Message_user 583
  ; component Turn_record.Message_tool_result 16_090
  ]

(* Turn 3648, the same keeper: a post-tool round keeps only the instructions
   and the schemas of the prompt, so the record shows no pinned block. *)
let post_tool_composition =
  [ component Turn_record.Tool_schemas 71_578
  ; component (Turn_record.Prompt_block Prompt_block_id.Keeper_instructions) 10_832
  ; component Turn_record.Message_user 583
  ; component Turn_record.Message_tool_result 16_090
  ]

let block_names blocks = List.map (fun (id, _) -> Prompt_block_id.to_string id) blocks

let test_a_first_round_composition_yields_the_fixed_and_pinned_parts () =
  let composition = Keeper_next_request_forecast.read_composition first_round_composition in
  Alcotest.(check int) "schemas + instructions are the fixed parts" 82_410
    composition.Keeper_next_request_forecast.fixed_bytes;
  Alcotest.(check int) "the system prompt's share" 10_832
    composition.Keeper_next_request_forecast.instructions_bytes;
  Alcotest.(check int) "the tool array's share" 71_578
    composition.Keeper_next_request_forecast.schemas_bytes;
  Alcotest.(check (option int)) "recall + dynamic context are pinned; messages are neither"
    (Some 159_710) composition.Keeper_next_request_forecast.first_round_pinned_bytes;
  (* The record listed recall before dynamic context; the assembly's order
     is by cache rank, which agrees here and is what decides. *)
  Alcotest.(check (list (pair string int))) "the pinned blocks in assembly order"
    [ "memory_os_recall", 150_000; "dynamic_context", 9_710 ]
    (List.map
       (fun (id, bytes) -> Prompt_block_id.to_string id, bytes)
       composition.Keeper_next_request_forecast.pinned_blocks)

let test_the_pinned_blocks_follow_the_assemblys_cache_order () =
  (* Recorded in producer order (clock first, as producers ran); the
     assembly puts the block that changes least in front. *)
  let composition =
    Keeper_next_request_forecast.read_composition
      [ component (Turn_record.Prompt_block Prompt_block_id.Temporal_summary) 36
      ; component (Turn_record.Prompt_block Prompt_block_id.Dynamic_context) 17_218
      ; component (Turn_record.Prompt_block Prompt_block_id.Memory_os_recall) 139_966
      ; component (Turn_record.Prompt_block Prompt_block_id.Skill_compositions) 321
      ; component (Turn_record.Prompt_block Prompt_block_id.Keeper_instructions) 10_832
      ]
  in
  Alcotest.(check (list string)) "skills, recall, dynamic context, clock"
    [ "skill_compositions"; "memory_os_recall"; "dynamic_context"; "temporal_summary" ]
    (block_names composition.Keeper_next_request_forecast.pinned_blocks)

let test_a_post_tool_composition_says_nothing_about_the_pinned_blocks () =
  let composition = Keeper_next_request_forecast.read_composition post_tool_composition in
  Alcotest.(check int) "the fixed parts still read; the schemas ride every round" 82_410
    composition.Keeper_next_request_forecast.fixed_bytes;
  Alcotest.(check (option int)) "no first-round block, no pinned figure" None
    composition.Keeper_next_request_forecast.first_round_pinned_bytes;
  Alcotest.(check (list string)) "and no block list" []
    (block_names composition.Keeper_next_request_forecast.pinned_blocks)

let test_an_operator_note_alone_is_not_a_first_round () =
  (* The note rides post-tool rounds too, so it cannot mark a first round. *)
  let composition =
    Keeper_next_request_forecast.read_composition
      (component (Turn_record.Prompt_block Prompt_block_id.Operator_note) 200
       :: post_tool_composition)
  in
  Alcotest.(check (option int)) "still the post-tool shape" None
    composition.Keeper_next_request_forecast.first_round_pinned_bytes

let glm = "glm-coding.glm-5.3-flash"
let claude = "claude_code.claude-sonnet-5"

let reading ?(runtime_id = glm) ?(completed = true) turn composition
  : Keeper_next_request_forecast.record_reading =
  { turn; runtime_id; completed; composition }

(* A composition by its totals: schemas only, so the fixed bytes are the
   tool array's; the block list is empty, which the selection tests do not
   read. *)
let composition ?pinned fixed_bytes : Keeper_next_request_forecast.composition =
  { fixed_bytes
  ; instructions_bytes = 0
  ; schemas_bytes = fixed_bytes
  ; first_round_pinned_bytes = pinned
  ; pinned_blocks = []
  }

let first = Keeper_next_request_forecast.read_composition first_round_composition
let post = Keeper_next_request_forecast.read_composition post_tool_composition
let select = Keeper_next_request_forecast.select_parts ~runtime_id:glm

let test_the_fixed_parts_come_from_the_newest_turn_and_the_pinned_from_the_newest_first_round () =
  (* Turn 3647 loaded more schemas than 3646 did; the next request carries
     the newest surface with the pinned blocks the last first round had. *)
  let readings =
    [ reading 3646 first
    ; reading 3647 (composition 94_928)
    ; reading 3648 post
    ]
  in
  match select ~records_read:13 readings with
  | Error _ -> Alcotest.fail "a first round among the records yields parts"
  | Ok parts ->
    Alcotest.(check int) "the fixed parts are the newest turn's" 3648
      parts.Keeper_next_request_forecast.reserved_turn;
    Alcotest.(check int) "at its bytes" 82_410 parts.Keeper_next_request_forecast.reserved_bytes;
    Alcotest.(check int) "split into the system prompt" 10_832
      parts.Keeper_next_request_forecast.instructions_bytes;
    Alcotest.(check int) "and the tool array" 71_578
      parts.Keeper_next_request_forecast.schemas_bytes;
    Alcotest.(check int) "the pinned blocks are the newest first round's" 3646
      parts.Keeper_next_request_forecast.pinned_turn;
    Alcotest.(check string) "on this lane" glm parts.Keeper_next_request_forecast.pinned_runtime_id;
    Alcotest.(check int) "at its bytes" 159_710 parts.Keeper_next_request_forecast.pinned_bytes;
    Alcotest.(check (list string)) "with that round's blocks"
      [ "memory_os_recall"; "dynamic_context" ]
      (block_names parts.Keeper_next_request_forecast.pinned_blocks)

let test_the_pinned_blocks_may_come_from_another_lane_or_an_errored_turn () =
  (* analyst on 2026-09-16: every completed glm turn was post-tool; the
     first rounds on record were claude_code's and glm's errored ones. The
     schemas stay glm's, from its newest completed turn. *)
  let readings =
    [ reading 4030 ~runtime_id:claude first
    ; reading 4031 ~completed:false first
    ; reading 4032 post
    ; reading 4033 ~runtime_id:claude (composition ~pinned:140_706 194_254)
    ; reading 4034 ~completed:false (composition 90_000)
    ]
  in
  match select ~records_read:200 readings with
  | Error _ -> Alcotest.fail "a first round on another lane yields the pinned figure"
  | Ok parts ->
    Alcotest.(check int) "the fixed parts are the newest completed glm turn's" 4032
      parts.Keeper_next_request_forecast.reserved_turn;
    Alcotest.(check int) "not the errored one's, not claude_code's" 82_410
      parts.Keeper_next_request_forecast.reserved_bytes;
    Alcotest.(check int) "the pinned blocks are the newest first round's, whichever lane" 4033
      parts.Keeper_next_request_forecast.pinned_turn;
    Alcotest.(check string) "and that lane is named" claude
      parts.Keeper_next_request_forecast.pinned_runtime_id;
    Alcotest.(check int) "at its bytes" 140_706 parts.Keeper_next_request_forecast.pinned_bytes

let test_an_errored_turn_never_supplies_the_fixed_parts () =
  (* Only the errored record is on this lane; its composition may be another
     lane's, so nothing is read for R. *)
  match select ~records_read:200 [ reading 4031 ~completed:false first; reading 4033 ~runtime_id:claude first ] with
  | Error (Keeper_next_request_forecast.No_composition_on_runtime { records_read }) ->
    Alcotest.(check int) "how many records were read" 200 records_read
  | Error (Keeper_next_request_forecast.No_first_round_composition _) | Ok _ ->
    Alcotest.fail "an errored record's composition is not this lane's"

let test_only_post_tool_compositions_are_refused_naming_the_newest_turn () =
  match select ~records_read:200 [ reading 3647 post; reading 3648 post; reading 3649 ~runtime_id:claude post ] with
  | Error (Keeper_next_request_forecast.No_first_round_composition { records_read; newest_turn }) ->
    Alcotest.(check int) "how many records were read" 200 records_read;
    Alcotest.(check int) "and the newest completed turn on this lane" 3648 newest_turn
  | Error (Keeper_next_request_forecast.No_composition_on_runtime _) ->
    Alcotest.fail "compositions were present"
  | Ok _ -> Alcotest.fail "a post-tool shape never yields pinned bytes"

let test_no_composition_is_refused_with_the_count_read () =
  match select ~records_read:5 [] with
  | Error (Keeper_next_request_forecast.No_composition_on_runtime { records_read }) ->
    Alcotest.(check int) "how many records were read" 5 records_read
  | Error (Keeper_next_request_forecast.No_first_round_composition _) | Ok _ ->
    Alcotest.fail "nothing to read is its own refusal"

(* The claim is that measuring does not build what it measures, so the check
   is that the allocation does not grow with the bytes measured. A budget
   stated per byte measured looked like the same thing and is not: it falls as
   the fixture grows, so it says more about the fixture than the code. Measured
   over the same histories at 1x and 4x the message size, per-message-distinct
   content, each message measured twice as the projection measures it:

     measurer writing into a reused buffer     512,176 -> 512,176   1.0x
     memoizing the string builder            1,833,576 -> 5,721,432  3.1x
     building the string                     3,465,776 -> 11,260,976 3.2x

   Both rejected alternatives grow with the history; this one does not. The
   fixture gives every message distinct content on purpose -- with shared
   bodies a memo hits, and the memoized string builder comes in under any
   ratio budget while still allocating the history again on real input. *)
(* The larger size is past the measurer's initial buffer, so that walk grows
   its buffer once. That growth belongs to neither measured window -- the
   warm-up below takes it -- and a fixture that stayed under the initial size
   would never exercise the path at all. *)
let fixture_messages = 100
let fixture_message_bytes = 20_000
let fixture_growth = 4
let measurer_initial_buffer_bytes = 65_536
let allocation_allowed_to_grow_by = 2.0

let measure_history_allocation ~text_bytes =
  let messages =
    List.init fixture_messages (fun index ->
      message
        (if index mod 2 = 0 then Agent_core.Types.User else Agent_core.Types.Assistant)
        (Printf.sprintf "%d " index ^ String.make text_bytes (Char.chr (65 + (index mod 26)))))
  in
  let measure = Keeper_context_core.message_measurer () in
  (* Warm the buffer: whatever growth this size needs is paid here. *)
  List.iter (fun m -> ignore (measure m : int)) messages;
  let before = Gc.allocated_bytes () in
  let measured =
    List.fold_left (fun sum m -> sum + measure m) 0 messages
    + List.fold_left (fun sum m -> sum + measure m) 0 messages
  in
  (measured, Gc.allocated_bytes () -. before)

let test_measuring_does_not_allocate_what_it_measures () =
  Alcotest.(check bool)
    "the larger fixture crosses the measurer's initial buffer"
    true
    (fixture_message_bytes * fixture_growth > measurer_initial_buffer_bytes);
  let small_bytes, small_allocated = measure_history_allocation ~text_bytes:fixture_message_bytes in
  let large_bytes, large_allocated =
    measure_history_allocation ~text_bytes:(fixture_message_bytes * fixture_growth)
  in
  Printf.printf
    "\n  %d bytes -> %.0f allocated; %d bytes -> %.0f allocated (%.2fx for %.2fx the bytes)\n%!"
    small_bytes small_allocated large_bytes large_allocated
    (large_allocated /. small_allocated)
    (float_of_int large_bytes /. float_of_int small_bytes);
  Alcotest.(check bool)
    (Printf.sprintf "%.2fx more bytes measured allocated %.2fx more"
       (float_of_int large_bytes /. float_of_int small_bytes)
       (large_allocated /. small_allocated))
    true
    (large_allocated <= small_allocated *. allocation_allowed_to_grow_by)
(* lane-smith at turn 3660: the fixed parts from that turn, the pinned
   blocks from the last first round, in the assembly's order. *)
let parts_for_assembly : Keeper_next_request_forecast.measured_parts =
  { reserved_turn = 3660
  ; reserved_bytes = 82_410
  ; instructions_bytes = 10_832
  ; schemas_bytes = 71_578
  ; pinned_turn = 3651
  ; pinned_runtime_id = glm
  ; pinned_bytes = 157_541
  ; pinned_blocks =
      [ Prompt_block_id.Skill_compositions, 321
      ; Prompt_block_id.Memory_os_recall, 139_966
      ; Prompt_block_id.Dynamic_context, 17_218
      ; Prompt_block_id.Temporal_summary, 36
      ]
  }

(* A carried range by its totals; where it starts does not enter the layout. *)
let range ?preamble_bytes ~kept_atoms transmitted_bytes : Keeper_next_request_forecast.carried =
  { first_atom = 0
  ; kept_atoms
  ; transmitted_bytes
  ; preamble_bytes
  ; origin = Keeper_carried_front.Whole_history
  ; counted_tokens = None
  }

let slot_names slots =
  List.map
    (function
      | Keeper_next_request_forecast.System_prompt _ -> "system_prompt"
      | Keeper_next_request_forecast.Tools _ -> "tools"
      | Keeper_next_request_forecast.Preamble _ -> "preamble"
      | Keeper_next_request_forecast.History _ -> "history"
      | Keeper_next_request_forecast.Wake_line _ -> "wake_line"
      | Keeper_next_request_forecast.System_context _ -> "system_context")
    slots

let test_the_assembly_travels_prompt_tools_history_wake_then_context () =
  let slots =
    Keeper_next_request_forecast.assembly ~wake_bytes:191 ~history_atoms:4319 parts_for_assembly
      (range ~kept_atoms:7 57_100)
  in
  Alcotest.(check (list string)) "the order the request carries them"
    [ "system_prompt"; "tools"; "history"; "wake_line"; "system_context" ]
    (slot_names slots);
  match slots with
  | [ Keeper_next_request_forecast.System_prompt { bytes = prompt }
    ; Keeper_next_request_forecast.Tools { bytes = tools }
    ; Keeper_next_request_forecast.History { atoms; of_atoms; bytes = history }
    ; Keeper_next_request_forecast.Wake_line { bytes = wake }
    ; Keeper_next_request_forecast.System_context { bytes = context; blocks }
    ] ->
    Alcotest.(check int) "the system prompt is the instructions" 10_832 prompt;
    Alcotest.(check int) "the tools are the schemas" 71_578 tools;
    Alcotest.(check int) "the wake line is the newest carried atom, so six remain" 6 atoms;
    Alcotest.(check int) "of the checkpoint's atoms without the wake line" 4318 of_atoms;
    Alcotest.(check int) "history bytes are the transmitted bytes less the wake line" 56_909
      history;
    Alcotest.(check int) "the wake line as the encoder counts it" 191 wake;
    Alcotest.(check int) "the context is the pinned total" 157_541 context;
    Alcotest.(check (list string)) "with its blocks in assembly order"
      [ "skill_compositions"; "memory_os_recall"; "dynamic_context"; "temporal_summary" ]
      (block_names blocks)
  | _ -> Alcotest.fail "five slots without a preamble"

let test_a_prepended_preamble_takes_its_slot_before_the_history () =
  let slots =
    Keeper_next_request_forecast.assembly ~wake_bytes:191 ~history_atoms:100 parts_for_assembly
      (range ~preamble_bytes:260 ~kept_atoms:3 10_000)
  in
  Alcotest.(check (list string)) "the preamble rides between the tools and the history"
    [ "system_prompt"; "tools"; "preamble"; "history"; "wake_line"; "system_context" ]
    (slot_names slots);
  match List.nth slots 3 with
  | Keeper_next_request_forecast.History { bytes; atoms; _ } ->
    Alcotest.(check int) "history bytes exclude the preamble and the wake line" 9_549 bytes;
    Alcotest.(check int) "two atoms beside the wake line" 2 atoms
  | _ -> Alcotest.fail "the fourth slot is the history"

let test_the_newest_atom_alone_leaves_an_empty_history_slot () =
  let slots =
    Keeper_next_request_forecast.assembly ~wake_bytes:191 ~history_atoms:100 parts_for_assembly
      (range ~kept_atoms:1 191)
  in
  match List.nth slots 2 with
  | Keeper_next_request_forecast.History { atoms; bytes; of_atoms } ->
    Alcotest.(check int) "no history atoms travel" 0 atoms;
    Alcotest.(check int) "no history bytes" 0 bytes;
    Alcotest.(check int) "of the checkpoint's" 99 of_atoms
  | _ -> Alcotest.fail "the third slot is the history when no preamble rides"

(* The walk: where each candidate stands in the lane's declaration, and the
   JSON the band reads it from. *)
let test_a_declared_place_is_the_index_in_the_lane () =
  let declared = [ "glm"; "deepseek"; "kimi"; "claude_code" ] in
  Alcotest.(check (option int)) "the head" (Some 0)
    (Keeper_next_request_forecast.declared_at ~declared "glm");
  Alcotest.(check (option int)) "a later candidate" (Some 3)
    (Keeper_next_request_forecast.declared_at ~declared "claude_code");
  Alcotest.(check (option int)) "an id the lane does not declare" None
    (Keeper_next_request_forecast.declared_at ~declared "granite")

let test_the_json_carries_the_walk_and_each_place () =
  let candidate runtime_id place : Keeper_next_request_forecast.candidate =
    { runtime_id
    ; lane = Ok ()
    ; marks = None
    ; parts = Error (Keeper_next_request_forecast.No_composition_on_runtime { records_read = 0 })
    ; history_atoms = 1
    ; carried = None
    ; assembly = None
    ; place
    }
  in
  let forecast : Keeper_next_request_forecast.t =
    { keeper = "analyst"
    ; trace_id = "trace-1"
    ; checkpoint_messages = 1
    ; wake_line_bytes = 131
    ; walk =
        Ok
          { lane_id = "glm"; declared = [ "glm"; "claude_code" ] }
    ; candidates =
        [ candidate "claude_code"
            { walks_at = 0; declared_at = Some 1; rest = Keeper_turn_driver.Path_serving }
        ; candidate "glm"
            { walks_at = 1
            ; declared_at = Some 0
            ; rest =
                Keeper_turn_driver.Path_resting
                  { release_at = 60_000.; walk_promotes_at_release = true }
            }
        ]
    }
  in
  let json = Keeper_next_request_forecast.to_json forecast in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "the schema names the shape" "masc.keeper.next-request-forecast.v5"
    (json |> member "schema" |> to_string);
  Alcotest.(check string) "the lane rides with the walk" "glm"
    (json |> member "walk" |> member "lane_id" |> to_string);
  Alcotest.(check (list string)) "the declaration rides in order" [ "glm"; "claude_code" ]
    (json |> member "walk" |> member "declared" |> to_list |> List.map to_string);
  let places = json |> member "candidates" |> to_list |> List.map (member "place") in
  Alcotest.(check (list int)) "each candidate says where it walks" [ 0; 1 ]
    (List.map (fun place -> place |> member "walks_at" |> to_int) places);
  Alcotest.(check (list string)) "and whether its path rests" [ "serving"; "resting" ]
    (List.map (fun place -> place |> member "rest" |> member "kind" |> to_string) places);
  Alcotest.(check (float 0.)) "with the release when it does" 60_000.
    (List.nth places 1 |> member "rest" |> member "release_at" |> to_number);
  let refused =
    Keeper_next_request_forecast.to_json
      { forecast with walk = Error Keeper_turn_driver.Assignment_missing; candidates = [] }
  in
  Alcotest.(check string) "a refused walk says why"
    "the assignment names no configured lane or runtime"
    (refused |> member "walk" |> member "refusal" |> to_string)

let test_observed_boundary_forecast ~marks ~samples ~expected_step ~expected_front () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let module Ledger = Keeper_model_input_ledger in
  let module Range = Keeper_carried_range in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Model_catalog.global () in
  let base_path = Filename.temp_file "forecast-boundary-" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  let rec remove path =
    if Sys.is_directory path then (
      Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
  in
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    (match catalog_snapshot with
     | None -> Llm_provider.Model_catalog.clear_global ()
     | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    Ledger.Table.For_testing.reset ();
    remove base_path);
  let unwrap = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let write path contents =
    Out_channel.with_open_bin path (fun out -> output_string out contents)
  in
  let keeper_name = "forecast-boundary" and runtime_id = "fixture.sample" in
  let config = Workspace.default_config base_path in
  let catalog_path = Filename.concat base_path "models.toml" in
  write catalog_path
    "[[models]]\nid_prefix = \"forecast-model\"\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 4096\nmax_output_tokens = 128\nsupports_tools = true\n";
  Llm_provider.Model_catalog.load_file catalog_path |> unwrap
  |> Llm_provider.Model_catalog.set_global;
  let config_path = Filename.concat base_path "runtime.toml" in
  let marks_text = match marks with
    | None -> ""
    | Some (marks : Runtime_schema.context_marks) ->
      Printf.sprintf "context-high-water-tokens = %d\ncontext-low-water-tokens = %d\n"
        marks.high_water_tokens marks.low_water_tokens
  in
  write config_path
    ("[runtime]\ndefault = \"fixture.sample\"\n[providers.fixture]\nprotocol = \"openai-compatible-http\"\nendpoint = \"http://127.0.0.1:1/v1\"\n[models.sample]\napi-name = \"forecast-model\"\nmax-context = 4096\n[fixture.sample]\n" ^ marks_text);
  (match Runtime.init_default_degraded_report ~config_path with
   | Ok Runtime.Initialized -> ()
   | Ok (Runtime.Initialized_degraded _) -> Alcotest.fail "fixture runtime must materialize"
   | Error error -> Alcotest.fail (Runtime.strict_init_error_to_string error));
  let meta = Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String keeper_name ]) |> unwrap in
  Keeper_meta_store.replace_snapshot config meta |> unwrap;
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let messages = history ~exchanges:6 ~text_bytes:100 in
  let checkpoint : Agent_core.Checkpoint.t =
    { version = Agent_core.Checkpoint.checkpoint_version; session_id = trace_id
    ; agent_name = keeper_name; model = "forecast-model"; system_prompt = None
    ; messages; usage = Agent_core.Types.empty_usage; turn_count = 1; created_at = 1000.
    ; tools = []; tool_choice = None; disable_parallel_tool_use = false
    ; temperature = None; top_p = None; top_k = None; min_p = None
    ; reasoning_effort = None; enable_thinking = None; preserve_thinking = None
    ; response_format = Agent_core.Types.Off; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync (); mcp_sessions = []; working_context = None }
  in
  let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
  ignore (Keeper_checkpoint_store.save_agent_core_classified
    ~session_dir ~history_retained:0 checkpoint |> unwrap);
  let digest_at = Runtime_model_input_tail_window.atom_opening_digest messages in
  List.iter (fun (atom_count, input_tokens) ->
    let ends = match digest_at 0, digest_at (atom_count - 1) with
      | Some front_digest, Some end_digest when atom_count > 0 ->
        Ledger.Carried_atoms { front_digest; end_digest }
      | _ -> Ledger.No_atom_carried
    in
    let request : Ledger.request =
      { prefix_digest = "same-fixture-prefix"; first_atom = 0; atom_count; ends
      ; tail_bytes = 0; turn_context = false; demote_before = 0 }
    in
    let usage = Option.map (fun input_tokens ->
      { Ledger.input_tokens; cache_read_input_tokens = 0 }) input_tokens in
    ignore (Ledger.Table.observe ~keeper_name ~runtime_id ~session_id:trace_id
      ~digest_at ~request ~usage)) samples;
  let lookup () = match Ledger.Table.lookup ~keeper_name ~runtime_id ~session_id:trace_id with
    | Some ledger -> ledger
    | None -> Alcotest.fail "observed ledger missing"
  in
  let observed = lookup () in
  let step = Option.map (fun marks -> Range.at_turn_boundary ~marks observed) marks in
  Alcotest.(check bool) "fixture reaches the intended existing policy branch" true
    (match expected_step, step with
     | `No_marks, None -> true
     | `Unchanged expected, Some (Range.Unchanged actual) -> expected = actual
     | `Evicted, Some (Range.Evicted { first_atom; _ }) ->
       first_atom = expected_front
     | _ -> false);
  let forecast = Keeper_next_request_forecast.forecast ~config ~keeper_name |> unwrap in
  let json = Keeper_next_request_forecast.to_json forecast in
  (* Feed the actual producer payload to the external TUI regression. *)
  Printf.printf "BOUNDARY_FORECAST %s\n%!" (Yojson.Safe.to_string json);
  Alcotest.(check bool) "forecast preserves the complete observed Table value" true
    (lookup () = observed);
  match forecast.candidates with
  | [ { carried = Some carried; _ } ] ->
    Alcotest.(check (option int)) "last counted stays the actual observation"
      observed.total_tokens carried.counted_tokens;
    Alcotest.(check int) "forecast uses the driver's boundary front" expected_front
      carried.first_atom;
    Alcotest.(check int) "range includes the new wake atom" (13 - expected_front)
      carried.kept_atoms
  | _ -> Alcotest.fail "expected one applicable forecast candidate"

let () =
  Alcotest.run "keeper_next_request_forecast"
    [ ( "boundary"
      , let marks high = Some { Runtime_schema.high_water_tokens = high; low_water_tokens = 600 } in
        (* An initial prefix-only observation then three four-atom blocks,
           each counted at 400 tokens, gives total 1300. The existing policy
           removes two blocks to reach 500, so its front is atom 8. *)
        let samples = [ 0, Some 100; 4, Some 500; 8, Some 900; 12, Some 1300 ] in
        let unchanged reason = `Unchanged reason in
        [ Alcotest.test_case "observed high-water excess forecasts the boundary front" `Quick
            (test_observed_boundary_forecast ~marks:(marks 1200) ~samples
               ~expected_step:`Evicted
               ~expected_front:8)
        ; Alcotest.test_case "no marks preserve the observed front" `Quick
            (test_observed_boundary_forecast ~marks:None ~samples ~expected_step:`No_marks ~expected_front:0)
        ; Alcotest.test_case "below high-water preserves the observed front" `Quick
            (test_observed_boundary_forecast ~marks:(marks 1400) ~samples
               ~expected_step:(unchanged Keeper_carried_range.Within_high_water) ~expected_front:0)
        ; Alcotest.test_case "at high-water preserves the observed front" `Quick
            (test_observed_boundary_forecast ~marks:(marks 1300) ~samples
               ~expected_step:(unchanged Keeper_carried_range.Within_high_water) ~expected_front:0)
        ; Alcotest.test_case "unknown total preserves the observed front" `Quick
            (test_observed_boundary_forecast ~marks:(marks 1200)
               ~samples:(List.map (fun (atoms, _) -> atoms, None) samples)
               ~expected_step:(unchanged Keeper_carried_range.Total_unknown) ~expected_front:0)
        ; Alcotest.test_case "the only block remains despite high-water excess" `Quick
            (test_observed_boundary_forecast ~marks:(marks 1200)
               ~samples:[ 0, Some 100; 12, Some 1300 ]
               ~expected_step:(unchanged Keeper_carried_range.Nothing_evictable) ~expected_front:0)
        ] )
    ; ( "parts"
      , [ Alcotest.test_case "a first-round composition yields the fixed and pinned parts"
            `Quick test_a_first_round_composition_yields_the_fixed_and_pinned_parts
        ; Alcotest.test_case "the pinned blocks follow the assembly's cache order" `Quick
            test_the_pinned_blocks_follow_the_assemblys_cache_order
        ; Alcotest.test_case "a post-tool composition says nothing about the pinned blocks"
            `Quick test_a_post_tool_composition_says_nothing_about_the_pinned_blocks
        ; Alcotest.test_case "an operator note alone is not a first round" `Quick
            test_an_operator_note_alone_is_not_a_first_round
        ; Alcotest.test_case
            "the fixed parts come from the newest turn and the pinned from the newest first round"
            `Quick
            test_the_fixed_parts_come_from_the_newest_turn_and_the_pinned_from_the_newest_first_round
        ; Alcotest.test_case "the pinned blocks may come from another lane or an errored turn"
            `Quick test_the_pinned_blocks_may_come_from_another_lane_or_an_errored_turn
        ; Alcotest.test_case "an errored turn never supplies the fixed parts" `Quick
            test_an_errored_turn_never_supplies_the_fixed_parts
        ; Alcotest.test_case "only post-tool compositions are refused naming the newest turn"
            `Quick test_only_post_tool_compositions_are_refused_naming_the_newest_turn
        ; Alcotest.test_case "no composition is refused with the count read" `Quick
            test_no_composition_is_refused_with_the_count_read
        ] )
    ; ( "measure"
      , [ Alcotest.test_case "measuring does not allocate what it measures" `Quick
            test_measuring_does_not_allocate_what_it_measures
        ] )
    ; ( "carry"
      , [ Alcotest.test_case "a seeded front carries everything from it" `Quick
            test_a_seeded_front_carries_everything_from_it
        ; Alcotest.test_case "a range opening on an assistant measures its preamble" `Quick
            test_a_range_opening_on_an_assistant_measures_its_preamble
        ; Alcotest.test_case "a front the history shrank under is dropped" `Quick
            test_a_front_the_history_shrank_under_is_dropped
        ; Alcotest.test_case "a front that opens with another message is dropped" `Quick
            test_a_front_that_opens_with_another_message_is_dropped
        ; Alcotest.test_case "without a front everything goes" `Quick
            test_without_a_front_everything_goes
        ] )
    ; ( "assembly"
      , [ Alcotest.test_case "the assembly travels prompt, tools, history, wake, then context"
            `Quick test_the_assembly_travels_prompt_tools_history_wake_then_context
        ; Alcotest.test_case "a prepended preamble takes its slot before the history" `Quick
            test_a_prepended_preamble_takes_its_slot_before_the_history
        ; Alcotest.test_case "the newest atom alone leaves an empty history slot" `Quick
            test_the_newest_atom_alone_leaves_an_empty_history_slot
        ] )
    ; ( "walk"
      , [ Alcotest.test_case "a declared place is the index in the lane" `Quick
            test_a_declared_place_is_the_index_in_the_lane
        ; Alcotest.test_case "the JSON carries the walk and each place" `Quick
            test_the_json_carries_the_walk_and_each_place
        ] )
    ; ( "store"
      , [ Alcotest.test_case "forecast finds a response beyond unobserved rows" `Quick
            test_forecast_reads_an_observed_front_beyond_unobserved_rows
        ] )
    ]
