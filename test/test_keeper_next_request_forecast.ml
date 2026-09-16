(* The forecast runs the turn's own composition forward. These cases pin
   the arithmetic on a synthetic history so the numbers are checkable by
   hand: a seeded front carries everything from it, a front the history
   shrank under is dropped, and without a front everything goes. *)

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

let seed ~atom_count first_atom : Keeper_carried_front.seed =
  { first_atom; atom_count; source = Keeper_carried_front.Ledger }

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
  let c = carried (carry ~front:(seed ~atom_count:10 6) ~counted_tokens:9_000 messages) in
  Alcotest.(check int) "front" 6 c.first_atom;
  Alcotest.(check int) "fourteen atoms" 14 c.kept_atoms;
  Alcotest.(check bool) "its bytes are a proper part of the history" true
    (c.transmitted_bytes > 0 && c.transmitted_bytes < atom_bytes messages);
  Alcotest.(check bool) "the origin is the seed's" true
    (c.origin = Keeper_carried_front.Carried Keeper_carried_front.Ledger);
  Alcotest.(check (option int)) "the count rides along" (Some 9_000) c.counted_tokens

(* The front was measured against 3,395 atoms; a purge left ten. The position
   names nothing here, so the request starts over without a front. *)
let test_a_front_the_history_shrank_under_is_dropped () =
  let messages = history ~exchanges:5 ~text_bytes:100 in
  let c = carried (carry ~front:(seed ~atom_count:3_395 3_100) ~counted_tokens:91_000 messages) in
  Alcotest.(check int) "from the first atom" 0 c.first_atom;
  Alcotest.(check int) "all ten" 10 c.kept_atoms;
  Alcotest.(check bool) "the origin says no front" true
    (c.origin = Keeper_carried_front.Whole_history);
  Alcotest.(check (option int)) "and no count rides along" None c.counted_tokens

let test_without_a_front_everything_goes () =
  let messages = history ~exchanges:5 ~text_bytes:100 in
  let c = carried (carry messages) in
  Alcotest.(check int) "from the first atom" 0 c.first_atom;
  Alcotest.(check int) "all ten" 10 c.kept_atoms;
  Alcotest.(check bool) "the origin says so" true
    (c.origin = Keeper_carried_front.Whole_history)

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

let test_a_first_round_composition_yields_the_fixed_and_pinned_parts () =
  let composition = Keeper_next_request_forecast.read_composition first_round_composition in
  Alcotest.(check int) "schemas + instructions are the fixed parts" 82_410
    composition.Keeper_next_request_forecast.fixed_bytes;
  Alcotest.(check (option int)) "recall + dynamic context are pinned; messages are neither"
    (Some 159_710) composition.Keeper_next_request_forecast.first_round_pinned_bytes

let test_a_post_tool_composition_says_nothing_about_the_pinned_blocks () =
  let composition = Keeper_next_request_forecast.read_composition post_tool_composition in
  Alcotest.(check int) "the fixed parts still read; the schemas ride every round" 82_410
    composition.Keeper_next_request_forecast.fixed_bytes;
  Alcotest.(check (option int)) "no first-round block, no pinned figure" None
    composition.Keeper_next_request_forecast.first_round_pinned_bytes

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

let first = Keeper_next_request_forecast.read_composition first_round_composition
let post = Keeper_next_request_forecast.read_composition post_tool_composition
let select = Keeper_next_request_forecast.select_parts ~runtime_id:glm

let test_the_fixed_parts_come_from_the_newest_turn_and_the_pinned_from_the_newest_first_round () =
  (* Turn 3647 loaded more schemas than 3646 did; the next request carries
     the newest surface with the pinned blocks the last first round had. *)
  let readings =
    [ reading 3646 first
    ; reading 3647 { Keeper_next_request_forecast.fixed_bytes = 94_928; first_round_pinned_bytes = None }
    ; reading 3648 post
    ]
  in
  match select ~records_read:13 readings with
  | Error _ -> Alcotest.fail "a first round among the records yields parts"
  | Ok parts ->
    Alcotest.(check int) "the fixed parts are the newest turn's" 3648
      parts.Keeper_next_request_forecast.reserved_turn;
    Alcotest.(check int) "at its bytes" 82_410 parts.Keeper_next_request_forecast.reserved_bytes;
    Alcotest.(check int) "the pinned blocks are the newest first round's" 3646
      parts.Keeper_next_request_forecast.pinned_turn;
    Alcotest.(check string) "on this lane" glm parts.Keeper_next_request_forecast.pinned_runtime_id;
    Alcotest.(check int) "at its bytes" 159_710 parts.Keeper_next_request_forecast.pinned_bytes

let test_the_pinned_blocks_may_come_from_another_lane_or_an_errored_turn () =
  (* analyst on 2026-09-16: every completed glm turn was post-tool; the
     first rounds on record were claude_code's and glm's errored ones. The
     schemas stay glm's, from its newest completed turn. *)
  let readings =
    [ reading 4030 ~runtime_id:claude first
    ; reading 4031 ~completed:false first
    ; reading 4032 post
    ; reading 4033 ~runtime_id:claude { Keeper_next_request_forecast.fixed_bytes = 194_254; first_round_pinned_bytes = Some 140_706 }
    ; reading 4034 ~completed:false { Keeper_next_request_forecast.fixed_bytes = 90_000; first_round_pinned_bytes = None }
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

let () =
  Alcotest.run "keeper_next_request_forecast"
    [ ( "parts"
      , [ Alcotest.test_case "a first-round composition yields the fixed and pinned parts"
            `Quick test_a_first_round_composition_yields_the_fixed_and_pinned_parts
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
        ; Alcotest.test_case "a front the history shrank under is dropped" `Quick
            test_a_front_the_history_shrank_under_is_dropped
        ; Alcotest.test_case "without a front everything goes" `Quick
            test_without_a_front_everything_goes
        ] )
    ]
