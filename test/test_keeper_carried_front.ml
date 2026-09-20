(** Tests for {!Keeper_carried_front} (RFC keeper-context-window-in-tokens
    §10.4): where the carried range starts when no ledger holds the pair. *)

module Front = Masc.Keeper_carried_front
module Ledger = Masc.Keeper_model_input_ledger
module Window = Runtime_model_input_tail_window
module Types = Agent_core.Types

open Alcotest

(* The digest a record written by a turn whose front was atom [atom] carries;
   the records below are never checked against a history. *)
let recorded_digest atom =
  Digestif.SHA256.digest_string (Printf.sprintf "front-%d" atom)
  |> Digestif.SHA256.to_hex

let record
      ?(runtime = "glm")
      ?(wire_runtime = None)
      ?(finish = Some "completed")
      ?(response_observed = true)
      ?response_runtime
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
           { Turn_record.transmitted_atoms
           ; total_atoms
           ; measurement = Turn_record.Wire_shape
           ; front_atom_digest = recorded_digest (total_atoms - transmitted_atoms)
           })
        window
  ; response_observed_model_input =
      (match response_observed, window with
       | true, Some (transmitted_atoms, total_atoms) ->
         Some
           { runtime_profile = Option.value response_runtime ~default:runtime
           ; window =
               { Turn_record.transmitted_atoms
               ; total_atoms
               ; measurement = Turn_record.Wire_shape
               ; front_atom_digest =
                   recorded_digest (total_atoms - transmitted_atoms)
               }
           }
       | true, None | false, _ -> None)
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

(* A stand-in for the catalog: [read_seed] puts the question to
   {!Front.composer_of_runtime}, pinned below on its own. *)
let composer = function
  | "claude_code" -> Front.Hands_over_its_own_list
  | "gone" -> Front.Not_materialized
  | _ -> Front.Composes_from_the_history
;;

let of_records = Front.of_records ~trace_id:"trace-1" ~composer

let source =
  testable
    (fun fmt s -> Format.pp_print_string fmt (Front.source_to_string s))
    ( = )
;;

(* The lane walked glm, kimi, deepseek over one history. The newest completed
   record seeds the front whichever runtime measured it: a position in the
   checkpoint history is the same position on every runtime. *)
let test_the_newest_completed_record_on_the_trace_seeds_the_front () =
  let records =
    [ record ~turn:10 ~runtime:"glm" (Some (30, 100))
    ; record ~turn:12 ~runtime:"deepseek" (Some (25, 110))
    ; record ~turn:11 ~runtime:"kimi" (Some (40, 105))
    ]
  in
  let first_atom, src = seed (of_records records) in
  check int "total minus transmitted of turn 12" 85 first_atom;
  check source "names its turn" (Front.Turn_record { turn = 12 }) src;
  check string "and the message that record says opened it" (recorded_digest 85)
    (Option.get (of_records records)).front_digest
;;

let test_another_sessions_record_is_another_history () =
  let records =
    [ record ~turn:10 (Some (30, 100)); record ~turn:12 ~trace:"trace-2" (Some (5, 500)) ]
  in
  check int "the newer record belongs to another session" 70
    (fst (seed (of_records records)));
  check int "and is the one that session reads" 495
    (fst (seed (Front.of_records ~trace_id:"trace-2" ~composer records)))
;;

(* An official client cuts the same history, so its record names a position
   here and is read. A runtime the catalog no longer has could have counted
   anything, so its record is not; a record with no window says nothing. *)
let test_an_official_clients_record_is_read_and_an_unmaterialized_one_is_not () =
  let records =
    [ record ~turn:10 (Some (30, 100))
    ; record ~turn:13 ~runtime:"claude_code" (Some (5, 120))
    ; record ~turn:14 None
    ; record ~turn:15 ~runtime:"gone" (Some (5, 130))
    ]
  in
  let first_atom, src = seed (of_records records) in
  check int "the official client's turn 13 is the newest read" 115 first_atom;
  check source "turn 13" (Front.Turn_record { turn = 13 }) src
;;

(* The newest attempted range received no response. It must not replace the
   older response-observed range after the process loses its warm ledger. *)
let test_an_unanswered_record_does_not_seed_the_front () =
  let records =
    [ record ~turn:10 (Some (30, 100))
    ; record ~turn:12 ~finish:None ~response_observed:false (Some (5, 110))
    ]
  in
  let first_atom, src = seed (of_records records) in
  check int "the last response-observed front survives" 70 first_atom;
  check source "turn 10 supplied the response" (Front.Turn_record { turn = 10 }) src
;;

let test_a_later_unanswered_attempt_does_not_replace_the_same_turns_response () =
  let attempted = record ~turn:12 ~finish:None (Some (5, 110)) in
  let record =
    { attempted with
      Turn_record.response_observed_model_input =
        Some
          { runtime_profile = "deepseek"
          ; window =
              { transmitted_atoms = 30
              ; total_atoms = 100
              ; measurement = Wire_shape
              ; front_atom_digest = recorded_digest 70
              }
          }
    }
  in
  let first_atom, src = seed (of_records [ record ]) in
  check int "the answered request starts at atom 70" 70 first_atom;
  check source "the response belongs to this failed turn"
    (Front.Turn_record { turn = 12 }) src
;;

let test_restart_rows_restore_only_a_response_observed_front () =
  let rows =
    [ Turn_record.to_json (record ~turn:10 (Some (30, 100)))
    ; Turn_record.to_json
        (record
           ~turn:12
           ~finish:None
           ~response_observed:false
           (Some (5, 110)))
    ]
  in
  let read = Front.seed_read_of_rows ~composer ~trace_id:"trace-1" rows in
  let first_atom, src = seed read.Front.seed in
  check int "restart restores the answered range" 70 first_atom;
  check source "the refused latest row is skipped"
    (Front.Turn_record { turn = 10 }) src;
  check bool "both current rows decoded" true
    (Option.is_none read.Front.unreadable)
;;

(* A response-observed range remains valid even when the whole turn later
   failed and therefore wrote no finish reason. *)
let test_a_response_observed_failed_turn_seeds_the_front () =
  let records =
    [ record ~turn:12 (Some (40, 110))
    ; record ~turn:13 ~finish:None (Some (40, 115))
    ]
  in
  let _, src = seed (of_records records) in
  check source "turn 13 received a response" (Front.Turn_record { turn = 13 }) src
;;

(* The record's runtime names the runtime that was asked; the wire
   observation names the one that measured. The history question is put to
   the latter. *)
let test_the_joined_observation_names_the_runtime () =
  let records =
    [ record ~turn:10 ~runtime:"glm" ~wire_runtime:(Some "deepseek")
        ~response_runtime:"gone" (Some (30, 100)) ]
  in
  check bool "response runtime left the catalog: skipped" true
    (Option.is_none (of_records records));
  let records =
    [ record ~turn:10 ~runtime:"gone" ~wire_runtime:(Some "gone")
        ~response_runtime:"deepseek" (Some (30, 100)) ]
  in
  check int "deepseek answered: read" 70 (fst (seed (of_records records)))
;;

let test_no_record_means_no_seed () =
  check bool "empty" true (Option.is_none (of_records []))
;;

let composer_t =
  testable (fun fmt c -> Format.pp_print_string fmt (Front.composer_to_string c)) ( = )
;;

(* Every execution kind answers, and a runtime the catalog does not
   materialize answers that it is unknown rather than either. *)
let test_the_composer_is_read_from_the_execution_kind () =
  let agent_core =
    Runtime_execution.Agent_core
      (Agent_core.Llm_provider.Provider_config.make
         ~kind:Agent_core.Llm_provider.Provider_config.OpenAI_compat
         ~model_id:"model-a"
         ~base_url:"https://provider.example"
         ())
  in
  check composer_t "agent core composes from the history" Front.Composes_from_the_history
    (Front.composer_of_execution agent_core);
  check composer_t "claude code hands over its own list" Front.Hands_over_its_own_list
    (Front.composer_of_execution
       (Runtime_execution.Claude_code { cli_path = "claude"; model = None; timeout_s = 1. }));
  check composer_t "codex hands over its own list" Front.Hands_over_its_own_list
    (Front.composer_of_execution
       (Runtime_execution.Codex_app_server { cli_path = "codex"; model = None; timeout_s = 1. }));
  check composer_t "antigravity hands over its own list" Front.Hands_over_its_own_list
    (Front.composer_of_execution
       (Runtime_execution.Antigravity_cli
          { cli_path = "antigravity"
          ; model = "m"
          ; agent = None
          ; effort = None
          ; oauth_source = "env"
          ; timeout_s = 1.
          ; add_dirs = []
          }));
  check composer_t "not in the catalog" Front.Not_materialized (Front.composer_of_runtime None)
;;

let ledger_with ~first_atom ~atom_count ends : Ledger.t =
  { prefix_digest = "f"
  ; total_tokens = Some 10
  ; measured_end_atom = Some atom_count
  ; measured_demote_before = Some 0
  ; blocks = []
  ; last =
      { prefix_digest = "f"
      ; first_atom
      ; atom_count
      ; ends
      ; tail_bytes = 0
      ; turn_context = false
      ; demote_before = 0
      }
  ; last_usage = None
  }
;;

let test_of_ledger_reads_the_last_request_front () =
  let ledger =
    ledger_with
      ~first_atom:7
      ~atom_count:20
      (Ledger.Carried_atoms { front_digest = "seven"; end_digest = "nineteen" })
  in
  let first_atom, src = seed (Front.of_ledger ledger) in
  check int "the ledger's front" 7 first_atom;
  check source "ledger" Front.Ledger src;
  check string "named by the digest the ledger recorded for it" "seven"
    (Option.get (Front.of_ledger ledger)).front_digest;
  check bool "a ledger whose last request carried no atom names no front" true
    (Option.is_none
       (Front.of_ledger (ledger_with ~first_atom:0 ~atom_count:0 Ledger.No_atom_carried)))
;;

let text_message role text : Types.message =
  { role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }
;;

(* [exchanges n] is [2n] atoms: a user message and an assistant reply each. *)
let exchanges n =
  List.concat_map
    (fun i ->
       [ text_message Types.User (Printf.sprintf "ask %d" i)
       ; text_message Types.Assistant (Printf.sprintf "answer %d" i)
       ])
    (List.init n Fun.id)
;;

let seed_at history first_atom : Front.seed =
  match Window.atom_opening_digest history first_atom with
  | Some front_digest -> { first_atom; front_digest; source = Front.Ledger }
  | None -> fail "the seed's own history has the atom"
;;

let dropped =
  testable
    (fun fmt d -> Format.pp_print_string fmt (Front.dropped_front_to_string d))
    ( = )
;;

let kept_or_dropped = result (of_pp (fun fmt (s : Front.seed) -> Format.pp_print_int fmt s.first_atom)) dropped

(* 2026-09-17, msx-retro-mania: the attempt that measured the front added one
   atom it never saved, so the next turn's history was one atom shorter than
   the one the front was measured on. The front's atom opens with the same
   message in both, and the position holds. *)
let test_a_history_one_unsaved_atom_shorter_keeps_the_front () =
  let measured_on = exchanges 6 in
  let s = seed_at measured_on 8 in
  let next_turn = List.filteri (fun index _ -> index < 11) measured_on in
  check kept_or_dropped "the same message at atom 8" (Ok s)
    (Front.for_history ~digest_at:(Window.atom_opening_digest next_turn) s)
;;

(* A purge before the front pulls every later atom one index back: the index
   now opens with another message. A purge that took the front's own atom
   along with everything after it leaves no atom at the index. *)
let test_a_purge_drops_the_front_with_its_reason () =
  let measured_on = exchanges 6 in
  let s = seed_at measured_on 8 in
  let purged_before = List.filteri (fun index _ -> index <> 2) measured_on in
  check kept_or_dropped "another message at atom 8" (Error Front.Front_message_differs)
    (Front.for_history ~digest_at:(Window.atom_opening_digest purged_before) s);
  let cut_short = List.filteri (fun index _ -> index < 8) measured_on in
  check kept_or_dropped "no atom 8" (Error Front.Front_atom_missing)
    (Front.for_history ~digest_at:(Window.atom_opening_digest cut_short) s)
;;

(* The front atom is an assistant message; the tool result that answers it
   arrives after the front was measured and joins the same atom. The
   position is the opening message's, so the seed still holds. *)
let test_a_tool_result_joining_the_front_atom_keeps_the_front () =
  let assistant_call = text_message Types.Assistant "calling a tool" in
  let measured_on = exchanges 2 @ [ assistant_call ] in
  let s = seed_at measured_on 4 in
  let tool_result =
    { (text_message Types.Tool "tool output") with Types.tool_call_id = Some "call-1" }
  in
  let later = measured_on @ [ tool_result; text_message Types.User "next" ] in
  check kept_or_dropped "the tool result does not move the position" (Ok s)
    (Front.for_history ~digest_at:(Window.atom_opening_digest later) s)
;;

(* The rows a seed is read from: one current record, and two rows the decoder
   refuses for different reasons. The seed comes from the one that decodes;
   the two that do not are counted, and the first refusal is the one kept. *)
let test_rows_that_do_not_decode_are_counted_with_the_first_reason () =
  let without key json =
    match json with
    | `Assoc fields -> `Assoc (List.remove_assoc key fields)
    | other -> other
  in
  let current = Turn_record.to_json (record ~turn:10 (Some (30, 100))) in
  let rows =
    [ without "front_atom_digest" (Turn_record.to_json (record ~turn:8 (Some (5, 90))))
    ; current
    ; without "keeper" (Turn_record.to_json (record ~turn:9 (Some (5, 95))))
    ]
  in
  let read = Front.seed_read_of_rows ~composer ~trace_id:"trace-1" rows in
  check int "the seed is the record that decodes" 70
    (fst (seed read.Front.seed));
  match read.Front.unreadable with
  | None -> fail "two rows did not decode and none was counted"
  | Some unreadable ->
    check int "both refused rows are counted" 2 unreadable.Front.count;
    check bool "the first refusal is kept, not the last" true
      (Astring.String.is_infix ~affix:"front_atom_digest" unreadable.Front.first_reason);
    check bool "every row decoding counts nothing" true
      (Option.is_none
         (Front.seed_read_of_rows ~composer ~trace_id:"trace-1" [ current ]).Front.unreadable)
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
  check string "evicted" "evicted_after_refusal"
    (kind (Front.Carried (Front.Evicted_after_refusal { retry = 1 })));
  check string "whole" "whole_history" (kind Front.Whole_history)
;;

let () =
  run
    "keeper_carried_front"
    [ ( "of_records"
      , [ test_case "newest completed record on the trace" `Quick
            test_the_newest_completed_record_on_the_trace_seeds_the_front
        ; test_case "an official client is read, an unmaterialized runtime is not" `Quick
            test_an_official_clients_record_is_read_and_an_unmaterialized_one_is_not
        ; test_case "an unanswered record does not seed" `Quick
            test_an_unanswered_record_does_not_seed_the_front
        ; test_case "same-turn unanswered attempt does not replace response"
            `Quick
            test_a_later_unanswered_attempt_does_not_replace_the_same_turns_response
        ; test_case "restart rows restore only response-observed front" `Quick
            test_restart_rows_restore_only_a_response_observed_front
        ; test_case "a response-observed failed turn seeds" `Quick
            test_a_response_observed_failed_turn_seeds_the_front
        ; test_case "joined observation names the runtime" `Quick
            test_the_joined_observation_names_the_runtime
        ; test_case "no record" `Quick test_no_record_means_no_seed
        ; test_case "another session" `Quick test_another_sessions_record_is_another_history
        ; test_case "composer from the execution kind" `Quick
            test_the_composer_is_read_from_the_execution_kind
        ; test_case "undecodable rows counted with the first reason" `Quick
            test_rows_that_do_not_decode_are_counted_with_the_first_reason
        ] )
    ; ( "front"
      , [ test_case "of_ledger" `Quick test_of_ledger_reads_the_last_request_front
        ; test_case "one unsaved atom shorter keeps the front" `Quick
            test_a_history_one_unsaved_atom_shorter_keeps_the_front
        ; test_case "a purge drops the front with its reason" `Quick
            test_a_purge_drops_the_front_with_its_reason
        ; test_case "a joining tool result keeps the front" `Quick
            test_a_tool_result_joining_the_front_atom_keeps_the_front
        ; test_case "clamp" `Quick test_clamp_keeps_the_front_on_an_atom
        ; test_case "halve" `Quick test_halve_moves_halfway_and_stops_at_one_atom
        ; test_case "origin json" `Quick test_origin_json_names_its_kind
        ] )
    ]
;;
