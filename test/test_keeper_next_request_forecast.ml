(* The forecast runs the turn's own cut forward. These cases pin the
   arithmetic on a synthetic history so the numbers are checkable by hand:
   the capacity minus the prompt's fixed parts is what the history may fill,
   the newest atom is never dropped, and a runtime with no density yet gets
   the smallest request that carries the turn. *)

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

let measured ~capacity_bytes =
  Keeper_context_window.Measured
    { window_tokens = 1000
    ; density = { input_tokens = 1000; measured_bytes = capacity_bytes }
    ; capacity_bytes
    }

let atom_bytes messages =
  List.fold_left (fun sum m -> sum + Keeper_next_request_forecast.measure m) 0 messages

let test_the_fixed_parts_come_off_the_capacity_first () =
  let messages = history ~exchanges:100 ~text_bytes:100 in
  let per_atom = atom_bytes (history ~exchanges:1 ~text_bytes:100) / 2 in
  let total_atoms = 200 in
  (* Room for 90 atoms after the prompt's fixed parts. The cut drops atoms
     in multiples of 60 so the transmitted prefix stays byte-identical while
     the conversation grows: dropping 60 leaves 140, too many; dropping 120
     leaves 80, which fits. So 80 travel. *)
  let capacity_bytes = (90 * per_atom) + 5_000 + 7_000 in
  match
    Keeper_next_request_forecast.cut_history
      ~measure:Keeper_next_request_forecast.measure
      ~capacity:(measured ~capacity_bytes)
      ~reserved_bytes:5_000
      ~pinned_bytes:7_000
      messages
  with
  | Keeper_next_request_forecast.Cut { kept_atoms; fit; _ } ->
    Alcotest.(check int) "eighty of two hundred atoms fit under the fixed parts" 80 kept_atoms;
    Alcotest.(check bool) "and the request is within the window" true
      (match fit with
       | Runtime_model_input_tail_window.Within_target -> true
       | Runtime_model_input_tail_window.Overrun _ -> false);
    Alcotest.(check bool) "the history was larger than that" true (total_atoms > kept_atoms)
  | Keeper_next_request_forecast.Newest_atom_only _ ->
    Alcotest.fail "a measured capacity cuts, it does not fall to the newest atom"

let test_fixed_parts_above_the_capacity_keep_the_newest_atom () =
  let messages = history ~exchanges:5 ~text_bytes:100 in
  match
    Keeper_next_request_forecast.cut_history
      ~measure:Keeper_next_request_forecast.measure
      ~capacity:(measured ~capacity_bytes:1_000)
      ~reserved_bytes:800
      ~pinned_bytes:800
      messages
  with
  | Keeper_next_request_forecast.Cut { kept_atoms; fit; _ } ->
    Alcotest.(check int) "the newest atom still travels" 1 kept_atoms;
    Alcotest.(check bool) "and the overrun names the fixed parts" true
      (match fit with
       | Runtime_model_input_tail_window.Overrun
           { cause = Runtime_model_input_tail_window.Fixed_parts_exceed_target; _ } -> true
       | Runtime_model_input_tail_window.Overrun
           { cause = Runtime_model_input_tail_window.Newest_atom_exceeds_target; _ }
       | Runtime_model_input_tail_window.Within_target -> false)
  | Keeper_next_request_forecast.Newest_atom_only _ ->
    Alcotest.fail "a measured capacity reports an overrun, not an unmeasured floor"

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
    (List.map
       (fun (id, _) -> Prompt_block_id.to_string id)
       composition.Keeper_next_request_forecast.pinned_blocks)

let test_a_post_tool_composition_says_nothing_about_the_pinned_blocks () =
  let composition = Keeper_next_request_forecast.read_composition post_tool_composition in
  Alcotest.(check int) "the fixed parts still read; the schemas ride every round" 82_410
    composition.Keeper_next_request_forecast.fixed_bytes;
  Alcotest.(check (option int)) "no first-round block, no pinned figure" None
    composition.Keeper_next_request_forecast.first_round_pinned_bytes;
  Alcotest.(check int) "and no block list" 0
    (List.length composition.Keeper_next_request_forecast.pinned_blocks)

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
   tool array's; the block list is empty, which the assembly tests do not
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
  let cut =
    Keeper_next_request_forecast.Cut
      { kept_atoms = 7
      ; transmitted_bytes = 57_100
      ; preamble_bytes = None
      ; fit = Runtime_model_input_tail_window.Within_target
      }
  in
  let slots =
    Keeper_next_request_forecast.assembly ~wake_bytes:191 ~history_atoms:4319 parts_for_assembly cut
  in
  Alcotest.(check (list string)) "the order the request carries them"
    [ "system_prompt"; "tools"; "history"; "wake_line"; "system_context" ]
    (slot_names slots);
  (match slots with
   | [ Keeper_next_request_forecast.System_prompt { bytes = prompt }
     ; Keeper_next_request_forecast.Tools { bytes = tools }
     ; Keeper_next_request_forecast.History { atoms; of_atoms; bytes = history }
     ; Keeper_next_request_forecast.Wake_line { bytes = wake }
     ; Keeper_next_request_forecast.System_context { bytes = context; blocks }
     ] ->
     Alcotest.(check int) "the system prompt is the instructions" 10_832 prompt;
     Alcotest.(check int) "the tools are the schemas" 71_578 tools;
     Alcotest.(check int) "the wake line is one of the kept atoms, so six remain" 6 atoms;
     Alcotest.(check int) "of the checkpoint's atoms without the wake line" 4318 of_atoms;
     Alcotest.(check int) "history bytes are the transmitted bytes less the wake line" 56_909
       history;
     Alcotest.(check int) "the wake line as the cut's encoder counts it" 191 wake;
     Alcotest.(check int) "the context is the pinned total" 157_541 context;
     Alcotest.(check int) "with its blocks in assembly order" 4 (List.length blocks)
   | _ -> Alcotest.fail "five slots without a preamble")

let test_a_prepended_preamble_takes_its_slot_before_the_history () =
  let cut =
    Keeper_next_request_forecast.Cut
      { kept_atoms = 3
      ; transmitted_bytes = 10_000
      ; preamble_bytes = Some 260
      ; fit = Runtime_model_input_tail_window.Within_target
      }
  in
  let slots =
    Keeper_next_request_forecast.assembly ~wake_bytes:191 ~history_atoms:100 parts_for_assembly cut
  in
  Alcotest.(check (list string)) "the preamble rides between the tools and the history"
    [ "system_prompt"; "tools"; "preamble"; "history"; "wake_line"; "system_context" ]
    (slot_names slots);
  (match List.nth slots 3 with
   | Keeper_next_request_forecast.History { bytes; atoms; _ } ->
     Alcotest.(check int) "history bytes exclude the preamble and the wake line" 9_549 bytes;
     Alcotest.(check int) "two atoms beside the wake line" 2 atoms
   | _ -> Alcotest.fail "the fourth slot is the history")

let test_no_density_leaves_an_empty_history_slot () =
  let slots =
    Keeper_next_request_forecast.assembly ~wake_bytes:191 ~history_atoms:100 parts_for_assembly
      (Keeper_next_request_forecast.Newest_atom_only { transmitted_bytes = 191 })
  in
  match List.nth slots 2 with
  | Keeper_next_request_forecast.History { atoms; bytes; of_atoms } ->
    Alcotest.(check int) "no history atoms travel" 0 atoms;
    Alcotest.(check int) "no history bytes" 0 bytes;
    Alcotest.(check int) "of the checkpoint's" 99 of_atoms
  | _ -> Alcotest.fail "the third slot is the history when no preamble rides"

let test_no_density_sends_the_newest_atom_only () =
  let messages = history ~exchanges:5 ~text_bytes:100 in
  match
    Keeper_next_request_forecast.cut_history
      ~measure:Keeper_next_request_forecast.measure
      ~capacity:(Keeper_context_window.Unmeasured { window_tokens = 85_000 })
      ~reserved_bytes:5_000
      ~pinned_bytes:7_000
      messages
  with
  | Keeper_next_request_forecast.Newest_atom_only { transmitted_bytes } ->
    Alcotest.(check bool) "the floor carries the newest atom's bytes" true
      (transmitted_bytes > 0 && transmitted_bytes < atom_bytes messages)
  | Keeper_next_request_forecast.Cut _ ->
    Alcotest.fail "an unmeasured runtime has no capacity to cut against"

let () =
  Alcotest.run "keeper_next_request_forecast"
    [ ( "parts"
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
    ; ( "assembly"
      , [ Alcotest.test_case "the assembly travels prompt, tools, history, wake, then context"
            `Quick test_the_assembly_travels_prompt_tools_history_wake_then_context
        ; Alcotest.test_case "a prepended preamble takes its slot before the history" `Quick
            test_a_prepended_preamble_takes_its_slot_before_the_history
        ; Alcotest.test_case "no density leaves an empty history slot" `Quick
            test_no_density_leaves_an_empty_history_slot
        ] )
    ; ( "cut"
      , [ Alcotest.test_case "the fixed parts come off the capacity first" `Quick
            test_the_fixed_parts_come_off_the_capacity_first
        ; Alcotest.test_case "fixed parts above the capacity keep the newest atom" `Quick
            test_fixed_parts_above_the_capacity_keep_the_newest_atom
        ; Alcotest.test_case "no density sends the newest atom only" `Quick
            test_no_density_sends_the_newest_atom_only
        ] )
    ]
