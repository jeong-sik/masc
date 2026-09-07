(* The wire vocabulary a persisted provider timeout is read back through.

   A record rehydrated from disk has no typed error left, only its code
   string, and [classify_provider_runtime_error_record] turns that string into
   the phase the runtime acts on. The mapping is twenty-eight labels across
   two copy-pasted lists -- nine idle states and eleven phases with eight
   aliases -- and the suite named two of them.

   A crossed pair does not fail anything: it reports one timeout as another,
   which is a wrong reason on an operator's screen and a wrong bucket in the
   metric. So every label is written out here, and the aliases are checked to
   land where their canonical label lands rather than merely somewhere. *)

open Masc
module KPB = Keeper_provider_runtime_boundary

let timeout_prefix = "provider_error_timeout:"
let network_prefix = "provider_error_network:timeout:"

let phase_of code =
  match KPB.classify_provider_runtime_error_record ~code ~detail:"" () with
  | KPB.Provider_timeout { phase; _ } -> phase
  | KPB.Not_provider_runtime_failure ->
      Alcotest.failf "%S was not read as a provider timeout at all" code

let idle_labels =
  [ "awaiting_first_event", KPB.Awaiting_first_event
  ; "awaiting_first_delta", KPB.Awaiting_first_delta
  ; "streaming_answer", KPB.Streaming_answer
  ; "streaming_thinking", KPB.Streaming_thinking
  ; "streaming_tool_call", KPB.Streaming_tool_call
  ; "streaming_heartbeat", KPB.Streaming_heartbeat
  ; "streaming_substrate", KPB.Streaming_substrate
  ; "streaming_done", KPB.Streaming_done
  ; "streaming_unknown", KPB.Streaming_unknown
  ]

let canonical_phases =
  [ "first_token", KPB.First_token
  ; "http_operation", KPB.Http_operation
  ; "non_streaming_body", KPB.Non_streaming_body
  ; "stream_body", KPB.Stream_body
  ; "stream_idle", KPB.Stream_idle KPB.Streaming_unknown
  ; "provider_step", KPB.Provider_step
  ; "cli_stdout_idle", KPB.Cli_stdout_idle
  ; "caller_budget", KPB.Caller_budget
  ; "wall_clock", KPB.Wall_clock
  ; "capacity_backpressure", KPB.Capacity_backpressure
  ; "unknown_timeout", KPB.Unknown_timeout
  ]

(* Written as alias -> canonical rather than alias -> phase. A test that named
   the phase again would keep passing after the canonical label moved, with
   the alias left pointing at where the phase used to be. *)
let aliases =
  [ "no_first_token", "first_token"
  ; "time_to_first_token", "first_token"
  ; "ttft", "first_token"
  ; "wall_clock_timeout", "wall_clock"
  ; "wall_exceeded", "wall_clock"
  ; "max_execution_time", "wall_clock"
  ; "client_capacity", "capacity_backpressure"
  ; "client_capacity_full", "capacity_backpressure"
  ]

let test_every_idle_label_keeps_its_own_state () =
  List.iter
    (fun (label, state) ->
      Alcotest.(check bool)
        (label ^ " reads back as its own idle state")
        true
        (phase_of (timeout_prefix ^ "stream_idle:" ^ label)
         = Some (KPB.Stream_idle state)))
    idle_labels

let test_every_phase_label_keeps_its_own_phase () =
  List.iter
    (fun (label, phase) ->
      Alcotest.(check bool)
        (label ^ " reads back as its own phase")
        true
        (phase_of (timeout_prefix ^ label) = Some phase))
    canonical_phases

let test_each_alias_lands_where_its_canonical_label_lands () =
  List.iter
    (fun (alias, canonical) ->
      Alcotest.(check bool)
        (alias ^ " lands where " ^ canonical ^ " lands")
        true
        (phase_of (timeout_prefix ^ alias)
         = phase_of (timeout_prefix ^ canonical)))
    aliases

(* Two wire prefixes carry the same vocabulary. A label recognized under one
   and not the other is a timeout that reads as phaseless depending on which
   producer wrote it. *)
let test_both_wire_prefixes_read_the_same_label () =
  List.iter
    (fun (label, phase) ->
      Alcotest.(check bool)
        (label ^ " reads the same under the network prefix")
        true
        (phase_of (network_prefix ^ label) = Some phase))
    canonical_phases

(* A label this build does not know is a timeout with no phase, not a wrong
   phase. The distinction is the whole point of the option: a reader that gets
   [None] says it cannot tell, and one that gets a phase acts on it. *)
let test_an_unknown_label_has_no_phase_rather_than_a_wrong_one () =
  Alcotest.(check bool)
    "an unknown label is a timeout"
    true
    (match
       KPB.classify_provider_runtime_error_record
         ~code:(timeout_prefix ^ "a_phase_this_build_does_not_know")
         ~detail:""
         ()
     with
     | KPB.Provider_timeout { phase = None; _ } -> true
     | KPB.Provider_timeout _ | KPB.Not_provider_runtime_failure -> false)

let test_a_code_that_is_not_a_timeout_is_not_read_as_one () =
  List.iter
    (fun code ->
      Alcotest.(check bool)
        (code ^ " is not a provider timeout")
        true
        (match
           KPB.classify_provider_runtime_error_record ~code ~detail:"" ()
         with
         | KPB.Not_provider_runtime_failure -> true
         | KPB.Provider_timeout _ -> false))
    [ "provider_error_refused"; "provider_error_network:reset"; "" ]

let () =
  Alcotest.run
    "keeper_provider_timeout_labels"
    [ ( "vocabulary"
      , [ Alcotest.test_case "every idle label keeps its own state" `Quick
            test_every_idle_label_keeps_its_own_state
        ; Alcotest.test_case "every phase label keeps its own phase" `Quick
            test_every_phase_label_keeps_its_own_phase
        ; Alcotest.test_case "each alias lands where its canonical label lands"
            `Quick test_each_alias_lands_where_its_canonical_label_lands
        ; Alcotest.test_case "both wire prefixes read the same label" `Quick
            test_both_wire_prefixes_read_the_same_label
        ; Alcotest.test_case "an unknown label has no phase" `Quick
            test_an_unknown_label_has_no_phase_rather_than_a_wrong_one
        ; Alcotest.test_case "a code that is not a timeout is not read as one"
            `Quick test_a_code_that_is_not_a_timeout_is_not_read_as_one
        ] )
    ]
