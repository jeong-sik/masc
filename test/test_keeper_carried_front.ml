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

let of_records = Front.of_records ~trace_id:"trace-1"

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
    (fst (seed (Front.of_records ~trace_id:"trace-2" records)))
;;

(* A turn that skipped no atom names no front: its opening atom is
   the oldest one because nothing was skipped. The Codex lane hands its list
   over whole every turn, so reading its record as a seed would send the next
   official-client start back to the oldest atom, which is #37123 again
   (#37350). The narrower front from the turn before it stands. *)
let test_a_record_with_no_skipped_atom_does_not_unseat_a_carried_front () =
  let records =
    [ record ~turn:20 ~runtime:"claude_code" (Some (40, 1000))
    ; record ~turn:21 ~runtime:"codex" (Some (1010, 1010))
    ]
  in
  let first_atom, src = seed (of_records records) in
  check int "the carried front of turn 20 stands" 960 first_atom;
  check source "and names that turn" (Front.Turn_record { turn = 20 }) src
;;

(* Alone, such a record seeds nothing. Carrying its oldest atom and carrying
   everything are the same range, so there is nothing for a seed to say. *)
let test_a_record_with_no_skipped_atom_alone_seeds_nothing () =
  check
    bool
    "a record that skipped no atom gives no seed"
    true
    (Option.is_none (of_records [ record ~turn:21 ~runtime:"codex" (Some (1010, 1010)) ]))
;;

(* A recorded response remains a fact after its runtime leaves the current
   catalog. A row without a response window still says nothing about a seed. *)
let test_a_response_survives_its_runtime_leaving_the_catalog () =
  let records =
    [ record ~turn:10 (Some (30, 100))
    ; record ~turn:13 ~runtime:"claude_code" (Some (5, 120))
    ; record ~turn:14 None
    ; record ~turn:15 ~runtime:"gone" (Some (5, 130))
    ]
  in
  let first_atom, src = seed (of_records records) in
  check int "the removed runtime's response is still the newest observed range" 125 first_atom;
  check source "turn 15" (Front.Turn_record { turn = 15 }) src
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
  let read = Front.seed_read_of_rows ~trace_id:"trace-1" rows in
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

(* The response keeps its own runtime/window pair. Neither the final attempt
   nor today's catalog can rewrite what that response observed. *)
let test_the_joined_observation_names_the_runtime () =
  let records =
    [ record ~turn:10 ~runtime:"glm" ~wire_runtime:(Some "deepseek")
        ~response_runtime:"gone" (Some (30, 100)) ]
  in
  let read =
    Front.seed_read_of_rows ~trace_id:"trace-1"
      (List.map Turn_record.to_json records)
  in
  check bool "the current response record decodes" true (Option.is_none read.unreadable);
  check int "the response remains a seed after its runtime leaves the catalog" 70
    (fst (seed read.seed));
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

(* A response observed by a runtime that later leaves the catalog was still
   measured over this trace's checkpoint history. Selection keeps the record;
   the exact atom index and opening-message digest then prove that its axis is
   the current history's before the seed is used. *)
let test_a_removed_runtimes_response_names_the_current_history () =
  let history = exchanges 6 in
  let digest_at = Window.atom_opening_digest history in
  let front_digest =
    match digest_at 8 with Some digest -> digest | None -> fail "fixture atom missing"
  in
  let recorded = record ~runtime:"gone" ~turn:15 (Some (4, 12)) in
  let recorded =
    match recorded.Turn_record.response_observed_model_input with
    | None -> fail "the fixture response has no observed window"
    | Some observation ->
      { recorded with
        Turn_record.response_observed_model_input =
          Some
            { observation with
              window = { observation.window with front_atom_digest = front_digest }
            }
      }
  in
  let selected = Option.get (of_records [ recorded ]) in
  check kept_or_dropped "the removed runtime's exact position still opens this history"
    (Ok selected)
    (Front.for_history ~digest_at selected)
;;

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
  let read = Front.seed_read_of_rows ~trace_id:"trace-1" rows in
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
         (Front.seed_read_of_rows ~trace_id:"trace-1" [ current ]).Front.unreadable)
;;

let with_turn_record_store f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let previous_fs = Fs_compat.get_fs_opt () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.on_release sw (fun () ->
    match previous_fs with
    | Some fs -> Fs_compat.set_fs fs
    | None -> Fs_compat.clear_fs ());
  let base_path = Masc_test_deps.setup_test_workspace () in
  Eio.Switch.on_release sw (fun () -> Masc_test_deps.cleanup_test_workspace base_path);
  let config = Masc.Workspace.default_config base_path in
  let store = Masc.Keeper_types_support.keeper_turn_record_store config "alpha" in
  Eio.Switch.on_release sw (fun () -> Dated_jsonl.prepare_for_directory_removal store);
  f config store
;;

(* A retained response can be older than every row in the reader's former
   200-row window. Exercise the production store reader, rather than passing
   an already selected list to [seed_read_of_rows]. The observed front is
   inside persisted history and still holds when the next turn appends input. *)
let test_read_seed_keeps_a_response_beyond_unobserved_rows () =
  with_turn_record_store @@ fun config store ->
  let persisted = exchanges 5 in
  let _, total_atoms = Window.annotate persisted in
  check int "ten persisted atoms" 10 total_atoms;
  let window : Turn_record.model_input_window =
    { transmitted_atoms = total_atoms - 8
    ; total_atoms
    ; measurement = Turn_record.Wire_shape
    ; front_atom_digest = (seed_at persisted 8).front_digest
    }
  in
  let observed =
    { (record ~turn:1 None) with
      model_input_window = Some window
    ; response_observed_model_input = Some { runtime_profile = "glm"; window }
    }
  in
  let observed_json = Turn_record.to_json observed in
  Dated_jsonl.append store observed_json;
  let unobserved_rows = 200 in
  for index = 1 to unobserved_rows do
    let unobserved =
      { (record ~turn:(index + 1) ~finish:None ~response_observed:false None) with
        model_input_window = Some window
      }
    in
    Dated_jsonl.append store (Turn_record.to_json unobserved)
  done;
  let stored_rows = Dated_jsonl.read_recent store (unobserved_rows + 1) in
  check int "all rows are still stored" (unobserved_rows + 1) (List.length stored_rows);
  check bool "the observed row was not pruned" true
    (List.exists (Yojson.Safe.equal observed_json) stored_rows);
  let read = Front.read_seed ~config ~keeper_name:"alpha" ~trace_id:"trace-1" in
  check bool "every visited record decodes" true (Option.is_none read.Front.unreadable);
  check (option int) "the retained response supplies front 8" (Some 8)
    (Option.map (fun (front : Front.seed) -> front.first_atom) read.Front.seed);
  let front = Option.get read.Front.seed in
  check string "the front names the same persisted atom" window.front_atom_digest
    front.front_digest;
  check source "the observed turn supplies the seed" (Front.Turn_record { turn = 1 })
    front.source;
  let next_tick = persisted @ [ text_message Types.User "next tick" ] in
  check kept_or_dropped "the front still holds on the next tick" (Ok front)
    (Front.for_history ~digest_at:(Window.atom_opening_digest next_tick) front);
  let carried =
    Masc.Keeper_next_request_forecast.carry
      ~measure:(Masc.Keeper_context_core.message_measurer ())
      ~continuity:(Some Masc.Keeper_turn_driver_try_provider.without_snapshot)
      ~accepted:None ~front:read.Front.seed
      ~turn_start:(Front.Turn_boundary { end_atom = 0 })
      ~counted_tokens:None
      next_tick
  in
  check int "the next request retains the observed front" 8 carried.first_atom;
  check int "two retained atoms plus the next tick" 3 carried.kept_atoms
;;

let test_read_seed_uses_the_last_response_when_a_retry_reuses_the_turn () =
  with_turn_record_store @@ fun config store ->
  let records =
    [ (* The previous trace is older than this generation. A newer foreign
         trace would be the boundary and make reading [trace-1] invalid. *)
      record ~turn:9 ~trace:"another-trace" (Some (1, 100))
    ; record ~turn:10 ~finish:None (Some (30, 100))
    ; record ~turn:10 (Some (15, 100))
    ; record ~turn:10 ~finish:None ~response_observed:false (Some (5, 100))
    ]
  in
  List.iter (fun row -> Dated_jsonl.append store (Turn_record.to_json row)) records;
  let read = Front.read_seed ~config ~keeper_name:"alpha" ~trace_id:"trace-1" in
  check int "the latest response on this trace supplies front 85" 85
    (fst (seed read.Front.seed));
  check int "the chronological row reader resolves the same turn the same way" 85
    (fst (seed (of_records records)))
;;

let test_read_seed_counts_only_unreadable_rows_visited_before_the_response () =
  with_turn_record_store @@ fun config store ->
  let current = Turn_record.to_json (record ~turn:10 (Some (30, 100))) in
  let without key =
    match current with
    | `Assoc fields -> `Assoc (List.remove_assoc key fields)
    | other -> other
  in
  let older_refusal = without "front_atom_digest" in
  List.iter (Dated_jsonl.append store)
    [ `Null; current; older_refusal; without "keeper" ];
  let read = Front.read_seed ~config ~keeper_name:"alpha" ~trace_id:"trace-1" in
  check int "unreadable rows do not hide the response" 70
    (fst (seed read.Front.seed));
  match read.Front.unreadable, Turn_record.of_json older_refusal with
  | Some unreadable, Error reason ->
    check int "only the two newer unreadable rows were visited" 2 unreadable.count;
    check string "the oldest visited decoder refusal is retained" reason
      unreadable.first_reason
  | _ -> fail "the two invalid records must be counted"
;;

let test_read_seed_stops_at_history_restart () =
  with_turn_record_store @@ fun config store ->
  Dated_jsonl.append store
    (Turn_record.to_json (record ~turn:1 (Some (30, 100))));
  Masc.Keeper_turn_boundaries.append
    ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
    ~keeper_id:"alpha"
    { recorded_at = 1.
    ; event =
        Masc.Keeper_turn_boundaries.Turn_ended
          { turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:1
          ; history_at_start = Masc.Keeper_turn_boundaries.Continued_history
          ; position = Masc.Keeper_turn_boundaries.Stale_noop
          }
    }
  |> Result.get_ok;
  Masc.Keeper_turn_boundaries.append
    ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
    ~keeper_id:"alpha"
    { recorded_at = 2.
    ; event = Masc.Keeper_turn_boundaries.History_restarted { trace_id = "trace-1" }
    }
  |> Result.get_ok;
  Dated_jsonl.append store
    (Turn_record.to_json
       (record ~turn:2 ~finish:None ~response_observed:false None));
  let read = Front.read_seed ~config ~keeper_name:"alpha" ~trace_id:"trace-1" in
  check bool "the pre-clear response is not a seed" true (Option.is_none read.Front.seed)
;;

let test_read_seed_stops_at_previous_trace () =
  with_turn_record_store @@ fun config store ->
  Dated_jsonl.append store `Null;
  Dated_jsonl.append store
    (Turn_record.to_json (record ~trace:"trace-0" ~turn:9 (Some (30, 100))));
  Dated_jsonl.append store
    (Turn_record.to_json
       (record ~turn:10 ~finish:None ~response_observed:false None));
  let read = Front.read_seed ~config ~keeper_name:"alpha" ~trace_id:"trace-1" in
  check bool "the prior trace does not supply a seed" true (Option.is_none read.Front.seed);
  check bool "rows older than the trace boundary are not decoded" true
    (Option.is_none read.Front.unreadable)
;;

let test_read_seed_keeps_boundary_errors_out_of_the_record_count () =
  with_turn_record_store @@ fun config store ->
  Dated_jsonl.append store
    (Turn_record.to_json (record ~turn:1 (Some (30, 100))));
  let path =
    Masc.Keeper_turn_boundaries.path_for_keepers_dir
      ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
      ~keeper_id:"alpha"
  in
  Fs_compat.mkdir_p (Filename.dirname path);
  let output = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output "{not-json\n");
  let read = Front.read_seed ~config ~keeper_name:"alpha" ~trace_id:"trace-1" in
  check bool "an unknown boundary admits no seed" true (Option.is_none read.Front.seed);
  check bool "no TurnRecord was counted unreadable" true
    (Option.is_none read.Front.unreadable);
  check bool "the boundary failure has its own channel" true
    (Option.is_some read.Front.boundary_error)
;;

(* [since_seq] is exclusive and the ring's first entry carries seq 0. *)
let ring_cursor () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.Log.Ring.seq
  | [] -> -1
;;

(* The WARN lines one report writes on [keeper]'s log, oldest first. *)
let warnings_reported ~keeper read =
  let cursor = ring_cursor () in
  Front.warn_seed_read_failures ~keeper_name:keeper ~runtime_id:"glm" read;
  Log.Ring.recent ~since_seq:cursor ~order:`Oldest_first ()
  |> List.filter (fun (entry : Log.Ring.entry) ->
    Option.equal String.equal entry.Log.Ring.keeper_name (Some keeper)
    && String.equal entry.Log.Ring.module_name "Keeper"
    && (match entry.Log.Ring.level with
        | Log.Warn -> true
        | Log.Debug | Log.Info | Log.Error -> false))
;;

let test_a_seed_read_reports_each_failure_once () =
  let unreadable = Some { Front.count = 2; first_reason = "fixture row" } in
  let boundary_error = Some "turn boundary line 3: fixture" in
  check int "a clean read writes nothing" 0
    (List.length (warnings_reported ~keeper:"warn-clean" Front.no_seed_read));
  check int "a seed alone writes nothing" 0
    (List.length
       (warnings_reported ~keeper:"warn-seed"
          { Front.no_seed_read with
            Front.seed =
              Some
                { Front.first_atom = 3
                ; front_digest = recorded_digest 3
                ; source = Front.Ledger
                }
          }));
  check int "unreadable records write one line" 1
    (List.length
       (warnings_reported ~keeper:"warn-unreadable" { Front.no_seed_read with Front.unreadable }));
  (match
     warnings_reported ~keeper:"warn-boundary" { Front.no_seed_read with Front.boundary_error }
   with
   | [ entry ] ->
     check bool "the boundary line carries the store's detail" true
       (Astring.String.is_infix ~affix:"turn boundary line 3: fixture" entry.Log.Ring.message);
     check bool "and the runtime whose request it started" true
       (Astring.String.is_infix ~affix:"glm" entry.Log.Ring.message)
   | other -> failf "expected one boundary line, got %d" (List.length other));
  check int "both failures write a line each" 2
    (List.length
       (warnings_reported ~keeper:"warn-both"
          { Front.no_seed_read with Front.unreadable; boundary_error }))
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
  check string "turn start" "turn_start" (kind (Front.Turn_start { end_atom = 12 }));
  check int "and the turn start names its atom" 12
    Yojson.Safe.Util.(Front.origin_to_json (Front.Turn_start { end_atom = 12 }) |> member "end_atom" |> to_int);
  let unknown = Front.Turn_start_unknown { reason = "boundary read failed: fixture" } in
  check string "unknown turn start" "turn_start_unknown" (kind unknown);
  check string "and the unknown turn start names its reason" "boundary read failed: fixture"
    Yojson.Safe.Util.(Front.origin_to_json unknown |> member "reason" |> to_string)
;;

let () =
  run
    "keeper_carried_front"
    [ ( "of_records"
      , [ test_case "newest completed record on the trace" `Quick
            test_the_newest_completed_record_on_the_trace_seeds_the_front
        ; test_case "a record skipping no atom does not unseat a front"
            `Quick
            test_a_record_with_no_skipped_atom_does_not_unseat_a_carried_front
        ; test_case "a record skipping no atom alone seeds nothing" `Quick
            test_a_record_with_no_skipped_atom_alone_seeds_nothing
        ; test_case "a response survives runtime removal" `Quick
            test_a_response_survives_its_runtime_leaving_the_catalog
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
        ; test_case "stored response survives a window of unobserved rows" `Quick
            test_read_seed_keeps_a_response_beyond_unobserved_rows
        ; test_case "a retry reusing the turn keeps the latest stored response" `Quick
            test_read_seed_uses_the_last_response_when_a_retry_reuses_the_turn
        ; test_case "only visited unreadable rows are counted" `Quick
            test_read_seed_counts_only_unreadable_rows_visited_before_the_response
        ; test_case "history restart fences older responses" `Quick
            test_read_seed_stops_at_history_restart
        ; test_case "previous trace fences older retained rows" `Quick
            test_read_seed_stops_at_previous_trace
        ; test_case "boundary errors are not TurnRecord errors" `Quick
            test_read_seed_keeps_boundary_errors_out_of_the_record_count
        ; test_case "a seed read reports each failure once" `Quick
            test_a_seed_read_reports_each_failure_once
        ] )
    ; ( "front"
      , [ test_case "of_ledger" `Quick test_of_ledger_reads_the_last_request_front
        ; test_case "a removed runtime's response names the current history" `Quick
            test_a_removed_runtimes_response_names_the_current_history
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
