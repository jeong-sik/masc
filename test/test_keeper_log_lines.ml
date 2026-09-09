(* The two highest-volume keeper lines, asserted as text. A lane without
   llama-server timings leaves prompt/decode tok/s and the cache counters out
   instead of writing [-] four times per turn; a successful tool call carries
   no failure fields; the thinking counters ride only on a turn that had
   blocks (2026-09-09). *)

open Keeper_hooks_agent_core_types

let contains ~needle hay =
  let n = String.length needle and h = String.length hay in
  let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
  n = 0 || go 0
;;

let check_contains what ~needle hay =
  Alcotest.(check bool) (what ^ ": contains " ^ needle) true (contains ~needle hay)
;;

let check_absent what ~needle hay =
  Alcotest.(check bool) (what ^ ": no " ^ needle) false (contains ~needle hay)
;;

let no_thinking : thinking_log_summary =
  { thinking_present = false
  ; thinking_blocks = 0
  ; thinking_chars = 0
  ; redacted_thinking_blocks = 0
  ; thinking_kind = "none"
  }
;;

(* A glm turn as the 2026-09-09 boot log showed it: a window, wall tok/s and
   latency, nothing from llama-server timings. *)
let glm_turn : turn_log_fields =
  { turn = 5638
  ; total_turns = 3205
  ; runtime_lane = "glm-coding.glm-5.3"
  ; tokens = 73211
  ; context_window = Some 1_000_000
  ; wall_tok_s = Some 1419.3
  ; prompt_tok_s = None
  ; decode_tok_s = None
  ; cache_n = None
  ; prompt_n = None
  ; latency_ms = Some 5415
  ; thinking = no_thinking
  }
;;

let test_a_lane_without_timings_leaves_them_out () =
  Alcotest.(check string)
    "exact line"
    "turn=5638 total_turns=3205 runtime_lane=glm-coding.glm-5.3 tokens=73211 \
     context_window=1000000 wall_tok_s=1419.3 latency_ms=5415 thinking_kind=none"
    (turn_log_line glm_turn)
;;

let test_llama_timings_are_rendered_when_present () =
  let line =
    turn_log_line
      { glm_turn with
        prompt_tok_s = Some 12.34
      ; decode_tok_s = Some 45.67
      ; cache_n = Some 878
      ; prompt_n = Some 29
      }
  in
  check_contains "timings" ~needle:"prompt_tok_s=12.3 decode_tok_s=45.7 cache_n=878 prompt_n=29" line
;;

let test_an_absent_window_and_latency_are_left_out () =
  let line = turn_log_line { glm_turn with context_window = None; latency_ms = None } in
  check_absent "window" ~needle:"context_window=" line;
  check_absent "latency" ~needle:"latency_ms=" line;
  check_contains "the rest stays" ~needle:"tokens=73211 wall_tok_s=1419.3 thinking_kind=none" line
;;

let test_thinking_counters_ride_only_on_a_thinking_turn () =
  let line =
    turn_log_line
      { glm_turn with
        thinking =
          { thinking_present = true
          ; thinking_blocks = 1
          ; thinking_chars = 209
          ; redacted_thinking_blocks = 0
          ; thinking_kind = "thinking"
          }
      }
  in
  check_contains "counters" ~needle:"thinking_kind=thinking thinking_blocks=1 thinking_chars=209" line;
  check_absent "zero redacted" ~needle:"redacted_thinking_blocks" line;
  check_absent "no counters without thinking" ~needle:"thinking_blocks" (turn_log_line glm_turn)
;;

let test_redacted_count_appears_only_when_non_zero () =
  let line =
    turn_log_line
      { glm_turn with
        thinking =
          { thinking_present = true
          ; thinking_blocks = 0
          ; thinking_chars = 0
          ; redacted_thinking_blocks = 2
          ; thinking_kind = "redacted"
          }
      }
  in
  check_contains "redacted" ~needle:"thinking_kind=redacted thinking_blocks=0 thinking_chars=0 redacted_thinking_blocks=2" line
;;

let test_a_successful_built_in_call_carries_no_failure_fields () =
  Alcotest.(check string)
    "exact line"
    "keeper:geek-scout tool_call tool=WebSearch params=[includeContent,limit,query] \
     input_shape=[includeContent=bool,limit=int,query=string:41] outcome=ok out_len=23844"
    (tool_call_log_line ~keeper_name:"geek-scout"
       ({ tool = "WebSearch"
       ; source = None
       ; params = "includeContent,limit,query"
       ; input_shape = "includeContent=bool,limit=int,query=string:41"
       ; outcome = "ok"
       ; out_len = 23844
       ; failed_params = None
       ; error_preview = None
       } : tool_call_log_fields))
;;

let test_a_failed_file_backed_call_carries_source_and_arguments () =
  let line =
    tool_call_log_line ~keeper_name:"msx-retro-mania"
      ({ tool = "masc_msx_step"
      ; source = Some "tools/masc_msx_step.toml"
      ; params = "frames"
      ; input_shape = "frames=int"
      ; outcome = "error"
      ; out_len = 252
      ; failed_params = Some {|{"frames":300}|}
      ; error_preview = Some "no MSX machine is loaded: call masc_msx_load first"
      } : tool_call_log_fields)
  in
  check_contains "source" ~needle:"tool=masc_msx_step source=tools/masc_msx_step.toml params=[frames]" line;
  check_contains "arguments" ~needle:{|outcome=error out_len=252 failed_params={"frames":300} error_preview=no MSX machine is loaded|} line
;;

let () =
  Alcotest.run
    "keeper_log_lines"
    [ ( "turn"
      , [ Alcotest.test_case "a lane without timings leaves them out" `Quick
            test_a_lane_without_timings_leaves_them_out
        ; Alcotest.test_case "llama timings are rendered when present" `Quick
            test_llama_timings_are_rendered_when_present
        ; Alcotest.test_case "an absent window and latency are left out" `Quick
            test_an_absent_window_and_latency_are_left_out
        ; Alcotest.test_case "thinking counters ride only on a thinking turn" `Quick
            test_thinking_counters_ride_only_on_a_thinking_turn
        ; Alcotest.test_case "redacted count appears only when non-zero" `Quick
            test_redacted_count_appears_only_when_non_zero
        ] )
    ; ( "tool_call"
      , [ Alcotest.test_case "a successful built-in call carries no failure fields" `Quick
            test_a_successful_built_in_call_carries_no_failure_fields
        ; Alcotest.test_case "a failed file-backed call carries source and arguments" `Quick
            test_a_failed_file_backed_call_carries_source_and_arguments
        ] )
    ]
;;
