(** Tests for {!Keeper_carried_front} (RFC keeper-context-window-in-tokens
    §10.4): where the carried range starts when no ledger holds the pair. *)

module Front = Masc.Keeper_carried_front

open Alcotest

let record
      ?(runtime = "glm")
      ?(wire_runtime = None)
      ?(finish = Some "completed")
      ?(trace = "trace-1")
      ~turn
      window
  : Turn_record.t
  =
  { execution_ids = []
  ; keeper = "alpha"
  ; agent_name = "alpha-agent"
  ; turn_kind = Turn_record.Direct
  ; trace_id = trace
  ; absolute_turn = turn
  ; turn_ref = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:turn
  ; blocks = []
  ; input_components = None
  ; tool_surface_ref = None
  ; runtime_profile = runtime
  ; selected_model = None
  ; finish_reason = finish
  ; context_window = None
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = None
  ; ttfrc_ms = None
  ; request_wire_observation =
      Option.map
        (fun runtime_profile -> { Turn_record.runtime_profile; body_bytes = 1 })
        wire_runtime
  ; model_input_window =
      Option.map
        (fun (transmitted_atoms, total_atoms) ->
           { Turn_record.transmitted_atoms; total_atoms; measurement = Turn_record.Wire_shape })
        window
  ; raw_trace_run_ref = None
  ; sampling = { temperature = None; top_p = None; max_tokens = None; enable_thinking = None }
  ; usage =
      { input_tokens = None
      ; output_tokens = None
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = None
      ; scope = Runtime_usage_scope.Per_request
      }
  ; ts = 0.
  }
;;

let seed = function
  | Some (s : Front.seed) -> s.first_atom, s.source
  | None -> fail "a seed was expected"
;;

let of_records = Front.of_records ~trace_id:"trace-1"

let source =
  testable
    (fun fmt s -> Format.pp_print_string fmt (Front.source_to_string s))
    ( = )
;;

let test_the_newest_completed_record_on_the_runtime_seeds_the_front () =
  let records =
    [ record ~turn:10 (Some (30, 100))
    ; record ~turn:12 (Some (25, 110))
    ; record ~turn:11 (Some (40, 105))
    ]
  in
  let first_atom, src = seed (of_records ~runtime_id:"glm" records) in
  check int "total minus transmitted of turn 12" 85 first_atom;
  check source "names its turn" (Front.Turn_record { turn = 12 }) src;
  check int "and the history it was measured against" 110
    (Option.get (of_records ~runtime_id:"glm" records)).atom_count
;;

let test_another_sessions_record_is_another_history () =
  let records =
    [ record ~turn:10 (Some (30, 100)); record ~turn:12 ~trace:"trace-2" (Some (5, 500)) ]
  in
  check int "the newer record belongs to another session" 70
    (fst (seed (of_records ~runtime_id:"glm" records)));
  check int "and is the one that session reads" 495
    (fst (seed (Front.of_records ~runtime_id:"glm" ~trace_id:"trace-2" records)))
;;

let test_an_errored_or_other_lane_record_is_skipped () =
  let records =
    [ record ~turn:10 (Some (30, 100))
    ; record ~turn:12 ~finish:None (Some (5, 110))
    ; record ~turn:13 ~runtime:"claude_code" (Some (5, 120))
    ; record ~turn:14 (None)
    ]
  in
  let first_atom, src = seed (of_records ~runtime_id:"glm" records) in
  check int "only turn 10 qualifies" 70 first_atom;
  check source "turn 10" (Front.Turn_record { turn = 10 }) src
;;

let test_the_wire_observation_names_the_runtime_when_present () =
  let records =
    [ record ~turn:10 ~runtime:"glm" ~wire_runtime:(Some "deepseek") (Some (30, 100)) ]
  in
  check bool "read as deepseek's, not glm's" true
    (Option.is_none (of_records ~runtime_id:"glm" records));
  check int "and found under deepseek" 70 (fst (seed (of_records ~runtime_id:"deepseek" records)))
;;

let test_no_record_means_no_seed () =
  check bool "empty" true (Option.is_none (of_records ~runtime_id:"glm" []))
;;

let test_of_ledger_reads_the_last_request_front () =
  let ledger : Masc.Keeper_model_input_ledger.t =
    { prefix_digest = "f"
    ; total_tokens = Some 10
    ; measured_end_atom = Some 20
    ; blocks = []
    ; last = { prefix_digest = "f"; first_atom = 7; atom_count = 20; tail_bytes = 0 }
    ; last_usage = None
    }
  in
  let first_atom, src = seed (Some (Front.of_ledger ledger)) in
  check int "the ledger's front" 7 first_atom;
  check source "ledger" Front.Ledger src;
  check int "measured against the last request's history" 20 (Front.of_ledger ledger).atom_count
;;

let test_for_history_drops_a_front_the_history_shrank_under () =
  let s : Front.seed = { first_atom = 3_100; atom_count = 3_395; source = Front.Ledger } in
  check bool "the same history keeps it" true (Front.for_history ~atom_count:3_395 s = Some s);
  check bool "a longer history keeps it" true (Front.for_history ~atom_count:3_400 s = Some s);
  check bool "a purged history drops it" true (Front.for_history ~atom_count:2_000 s = None)
;;

let test_clamp_keeps_the_front_on_an_atom () =
  check int "below zero" 0 (Front.clamp ~atom_count:5 (-2));
  check int "past the newest" 4 (Front.clamp ~atom_count:5 9);
  check int "inside" 3 (Front.clamp ~atom_count:5 3);
  check int "empty history" 0 (Front.clamp ~atom_count:0 3)
;;

let test_halve_moves_halfway_and_stops_at_one_atom () =
  check (option int) "10 of 20 carried: halfway is 15" (Some 15) (Front.halve ~first_atom:10 ~atom_count:20);
  check (option int) "three carried" (Some 18) (Front.halve ~first_atom:17 ~atom_count:20);
  check (option int) "two carried: one" (Some 19) (Front.halve ~first_atom:18 ~atom_count:20);
  check (option int) "one carried cannot shrink" None (Front.halve ~first_atom:19 ~atom_count:20);
  check (option int) "a front past the newest is one atom too" None (Front.halve ~first_atom:40 ~atom_count:20)
;;

let test_origin_json_names_its_kind () =
  let kind origin =
    Yojson.Safe.Util.(Front.origin_to_json origin |> member "kind" |> to_string)
  in
  check string "ledger" "ledger" (kind (Front.Carried Front.Ledger));
  check string "turn record" "turn_record" (kind (Front.Carried (Front.Turn_record { turn = 3 })));
  check string "halved" "halved_after_refusal"
    (kind (Front.Carried (Front.Halved_after_refusal { retry = 1 })));
  check string "cap" "fit_to_request_cap" (kind Front.Fit_to_request_cap);
  check string "whole" "whole_history" (kind Front.Whole_history)
;;

let () =
  run
    "keeper_carried_front"
    [ ( "of_records"
      , [ test_case "newest completed record on the runtime" `Quick
            test_the_newest_completed_record_on_the_runtime_seeds_the_front
        ; test_case "errored or other lane skipped" `Quick test_an_errored_or_other_lane_record_is_skipped
        ; test_case "wire observation names the runtime" `Quick
            test_the_wire_observation_names_the_runtime_when_present
        ; test_case "no record" `Quick test_no_record_means_no_seed
        ; test_case "another session" `Quick test_another_sessions_record_is_another_history
        ] )
    ; ( "front"
      , [ test_case "of_ledger" `Quick test_of_ledger_reads_the_last_request_front
        ; test_case "for_history" `Quick test_for_history_drops_a_front_the_history_shrank_under
        ; test_case "clamp" `Quick test_clamp_keeps_the_front_on_an_atom
        ; test_case "halve" `Quick test_halve_moves_halfway_and_stops_at_one_atom
        ; test_case "origin json" `Quick test_origin_json_names_its_kind
        ] )
    ]
;;
