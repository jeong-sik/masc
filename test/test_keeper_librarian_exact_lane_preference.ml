open Alcotest
open Masc

module Fixture = Exact_output_fixture
module Librarian = Keeper_librarian
module Memory = Keeper_memory_os_types
module Runtime = Keeper_librarian_runtime

let contains ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec scan index =
    if index + n > h
    then false
    else String.equal (String.sub haystack index n) needle || scan (index + 1)
  in
  n = 0 || scan 0
;;

let ordinary_requirement =
  Agent_core.Exact_output.make_output_requirement
    ~schema:Keeper_structured_output_schema.librarian_current_output_schema
    ~minimum_guarantee:Agent_core.Exact_output.Json_syntax
;;

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_temp_base prefix f =
  let base_path = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
;;

let prompt_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> Filename.concat root "config/prompts"
  | None -> Filename.concat (Sys.getcwd ()) "config/prompts"
;;

let selection_output =
  `Assoc
    [ "working_contexts", `List []
    ; ( Librarian.wire_field_new_claims
      , `List
          [ `Assoc
              [ Librarian.wire_field_claim
                , `String "preferred librarian committed"
              ; Librarian.wire_field_category, `String "fact"
              ]
          ] )
    ; Librarian.wire_field_dropped, `List []
    ]
;;

let input () : Librarian.input =
  { turn_ref = Ids.Turn_ref.make ~trace_id:"trace-librarian-preference" ~absolute_turn:1
  ; goal_context = Masc.Keeper_librarian.No_task
  ; keeper_instructions = "Curate current memory."
  ; current = None
  ; messages =
      [ Agent_core.Types.make_message
          ~role:Agent_core.Types.User
          [ Agent_core.Types.Text "remember the preferred result" ]
      ]
  ; tool_observations = []
  ; working_context = Masc.Keeper_librarian_context.empty
  ; counterpart_observations = []
  }
;;

let test_keeper_preference_reorders_the_librarian_lane () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env
    ~net
    ~clock
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
  @@ fun () ->
  with_temp_base "librarian-per-keeper-preference" @@ fun base_path ->
  Prompt_registry.clear ();
  Prompt_registry.set_markdown_dir (prompt_root ());
  Prompt_defaults.init ();
  let first =
    Fixture.start_server
      ~sw
      ~net
      ~clock
      (Fixture.Reply (Fixture.openai_response selection_output))
  in
  let preferred =
    Fixture.start_server
      ~sw
      ~net
      ~clock
      (Fixture.Reply (Fixture.openai_response selection_output))
  in
  let snapshot =
    Fixture.resolver_snapshot
      ~source:"librarian-per-keeper-preference"
      [ { Fixture.id = "librarian-default"; base_url = first.base_url }
      ; { Fixture.id = "librarian-preferred"; base_url = preferred.base_url }
      ]
  in
  (match
     Runtime_exact_output_registry.publish
       ~lanes:
         [ { Runtime_schema.id = "librarian_exact"
           ; slot_ids = [ "librarian-default"; "librarian-preferred" ]
           ; cli_slot_ids = []
           ; max_output_tokens = Some 4_096
           }
         ]
       snapshot
   with
   | Ok _ -> ()
  | Error error ->
    fail
      (Runtime_exact_output_registry.publication_error_to_string error));
  (match
     Keeper_exact_lane_preference.validate_admitted_slot
       ~lane_id:"librarian_exact"
       ~slot_id:"librarian-preferred"
   with
   | Ok () -> ()
   | Error detail -> fail ("admitted preference was refused: " ^ detail));
  (match
     Keeper_exact_lane_preference.validate_admitted_slot
       ~lane_id:"librarian_exact"
       ~slot_id:"librarian-unknown"
   with
   | Error _ -> ()
   | Ok () -> fail "unknown preference passed authoring validation");
  (match
     Keeper_exact_lane_preference.set
       (Workspace.default_config base_path)
       ~actor:"test"
       ~keeper_name:"librarian-preference"
       ~lane_id:"librarian_exact"
       (Some "librarian-preferred")
   with
   | Ok _ -> ()
   | Error detail -> fail detail);
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Runtime.run_best_effort
    ~base_path
    ~keepers_dir
    ~keeper_id:"librarian-preference"
    ~expected_revision:None
    (input ());
  check int "default Librarian slot not called" 0 (Fixture.post_count first);
  check int
    "preferred Librarian slot called once"
    1
    (Fixture.post_count preferred);
  match
    Keeper_memory_os_current.read_for_keepers_dir
      ~keepers_dir
      ~keeper_id:"librarian-preference"
  with
  | Ok (Some snapshot) ->
    check
      (list string)
      "preferred result committed"
      [ "preferred librarian committed" ]
      (List.map (fun (fact : Memory.fact) -> fact.claim) snapshot.facts)
  | Ok None -> fail "preferred Librarian result was not committed"
  | Error detail -> fail detail
;;

(* Working-context organization must survive an independent Memory OS store
   failure. A directory at the snapshot path deterministically rejects the
   memory read/write even when the test runs with elevated filesystem access. *)
let test_context_commits_when_memory_store_fails () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env
    ~net
    ~clock
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
  @@ fun () ->
  with_temp_base "librarian-independent-context" @@ fun base_path ->
  Prompt_registry.clear ();
  Prompt_registry.set_markdown_dir (prompt_root ());
  Prompt_defaults.init ();
  let keeper_id = "librarian-independent-context" in
  let keepers_dir = Filename.concat base_path "keepers" in
  Unix.mkdir keepers_dir 0o700;
  let memory_path =
    Keeper_memory_os_current.path_for_keepers_dir ~keepers_dir ~keeper_id
  in
  Unix.mkdir memory_path 0o700;
  let blocker = Filename.concat memory_path "not-a-memory-snapshot" in
  Out_channel.with_open_bin blocker (fun channel ->
    output_string channel "preserve the invalid path fixture");
  let output =
    match selection_output with
    | `Assoc fields ->
      `Assoc
        (("working_contexts",
          `List [ `Assoc
            [ "merge_contexts", `List []
            ; "sources", `List [ `String "s1" ]
            ; "context", `String "The campaign still needs a status check."
            ; "next_steps", `List [ `String "Check the current campaign status." ]
            ] ])
         :: List.remove_assoc "working_contexts" fields)
    | _ -> fail "selection fixture must be an object"
  in
  let server =
    Fixture.start_server ~sw ~net ~clock
      (Fixture.Reply (Fixture.openai_response output))
  in
  let snapshot =
    Fixture.resolver_snapshot
      ~source:"librarian-independent-context"
      [ { Fixture.id = "librarian-context"; base_url = server.base_url } ]
  in
  (match
     Runtime_exact_output_registry.publish
       ~lanes:
         [ { Runtime_schema.id = "librarian_exact"
           ; slot_ids = [ "librarian-context" ]
           ; cli_slot_ids = []
           ; max_output_tokens = Some 4_096
           } ]
       snapshot
   with
   | Ok _ -> ()
   | Error error ->
     fail (Runtime_exact_output_registry.publication_error_to_string error));
  let source : Keeper_librarian_context.source =
    { reference = "event:campaign:immutable-source"
    ; content = `Assoc [ "request", `String "Check the campaign status." ]
    }
  in
  let inp =
    { (input ()) with
      working_context =
        { Keeper_librarian_context.empty with sources = [ source ] }
    }
  in
  Runtime.run_best_effort
    ~base_path ~keepers_dir ~keeper_id ~expected_revision:None inp;
  check int "the exact provider ran" 1 (Fixture.post_count server);
  (match Keeper_librarian_context.read ~keepers_dir ~keeper_id with
   | Ok (Some context) ->
     check (list string) "original queue source remains organized"
       [ source.reference ]
       (Keeper_librarian_context.current_references context);
     check (list string) "the selected context survives memory failure"
       [ "The campaign still needs a status check." ]
       (List.map
          (fun (pocket : Keeper_librarian_context.pocket) -> pocket.context)
          context.pockets)
   | Ok None -> fail "memory failure prevented working-context commit"
   | Error detail -> fail detail);
  check bool "memory snapshot was not written over the invalid path" true
    (Sys.is_directory memory_path && Sys.file_exists blocker);
  let journal =
    Keeper_memory_os_current.read_journal_tail ~keepers_dir ~keeper_id ~limit:10
  in
  check bool "the memory failure is recorded" true
    (List.exists
       (function
         | Ok (Keeper_memory_os_current.Journal_failed _) -> true
         | Ok (Keeper_memory_os_current.Journal_committed _)
         | Ok (Keeper_memory_os_current.Journal_quarantined _)
         | Error _ -> false)
       journal);
  check bool "no successful memory commit is reported" false
    (List.exists
       (function
         | Ok (Keeper_memory_os_current.Journal_committed _) -> true
         | Ok (Keeper_memory_os_current.Journal_failed _)
         | Ok (Keeper_memory_os_current.Journal_quarantined _)
         | Error _ -> false)
       journal)
;;

(* 2026-09-11 regression: a failover slot whose request cannot be projected
   at all -- a structural refusal, not a size -- must not fail the lane's
   pre-flight. The appended openrouter.openrouter-deepseek-v4-flash refused
   projection on every librarian run of that evening and took the healthy
   slots down with it. A model with enable_thinking=true but no thinking
   capability contract is the exact structural refusal (request_serialization_rejected)
   that hit openrouter-deepseek-v4-flash in production. *)
let test_excluded_last_slot_preserves_domain_failure () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env
    ~net
    ~clock
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
  @@ fun () ->
  let first =
    (* A completed but contract-invalid answer advances the exact flow to its
       next candidate. The filtered flow has no next candidate and therefore
       reports the domain rejection; the old wiring entered the structurally
       unusable slot and changed the failure class. *)
    Fixture.start_server ~sw ~net ~clock
      (Fixture.Reply (Fixture.openai_response (`Assoc [])))
  in
  let message text =
    Agent_core.Types.make_message
      ~role:Agent_core.Types.User
      [ Agent_core.Types.Text text ]
  in
  let publish slots =
    let snapshot =
      Fixture.resolver_snapshot
        ~source:"librarian-preflight-exclusion"
        ~enable_thinkings:[ ("librarian-bad", true) ]
        [ { Fixture.id = "librarian-first"; base_url = first.base_url }
        ; { Fixture.id = "librarian-bad"; base_url = first.base_url }
        ]
    in
    (match
       Runtime_exact_output_registry.publish
         ~lanes:
           [ { Runtime_schema.id = "librarian_exact"
             ; slot_ids = slots
             ; cli_slot_ids = []
             ; max_output_tokens = Some 4_096
             } ]
         snapshot
     with
     | Ok _ -> ()
     | Error error ->
       fail (Runtime_exact_output_registry.publication_error_to_string error));
    match Runtime_exact_output_registry.current () with
    | Error error ->
      fail (Runtime_exact_output_registry.publication_error_to_string error)
    | Ok registry ->
      (match
         Runtime_exact_output_registry.resolve_lane registry
           ~lane_id:"librarian_exact"
       with
       | Ok resolved -> resolved.Runtime_exact_output_registry.selected_slots
       | Error error ->
         fail
           (Runtime_exact_output_registry.lane_resolution_error_to_string error))
  in
  let selected_slots =
    publish [ "librarian-first"; "librarian-bad" ]
  in
  (match
     Runtime.preflight_slots ~requirement:ordinary_requirement ~selected_slots ~messages:[ message "one small prompt" ]
   with
   | Ok preflight ->
     check (list string)
       "only projectable slots remain in execution order"
       [ "librarian-first" ]
       (List.map
          (fun (slot : Runtime_exact_output_registry.selected_slot) -> slot.slot_id)
          preflight.Runtime.selected_slots);
     (* The slot id the run is without, and what that slot refused. The reason
        is the operator's only account of why a lane is one slot short, so it
        carries the provider config's own sentence, not just the kind. *)
     check (list string)
       "the refused slot is reported, not fatal"
       [ "librarian-bad" ]
       (List.map fst preflight.Runtime.unusable);
     (match preflight.Runtime.unusable with
      | [ (_, reason) ] ->
        check bool
          "the refusal names its kind"
          true
          (String.starts_with
             ~prefix:"wire_admission_rejected:target_request_rejected("
             reason);
        check bool
          "and carries what the config refused"
          true
          (contains ~needle:"masc-exact-fixture-model" reason)
      | unusable ->
        failf "expected one refused slot, got %d" (List.length unusable))
   | Error error ->
     fail (Runtime.extraction_error_to_string error));
  with_temp_base "librarian-preflight-execution" @@ fun base_path ->
  (match
     Runtime.For_testing.execute_exact_output_classified ~continuity:None
       ~clock
       ~net
       ~base_path
       ~keeper_id:"librarian-preflight-execution"
       ~selected_input:(input ())
       ~messages:[ message "one small prompt" ]
       ()
   with
   | Ok ((_selection, _output), selected_slot) ->
     failf "contract-invalid only usable slot unexpectedly answered as %s"
       (Runtime.served_slot_id selected_slot)
   | Error error ->
     check bool "filtered flow reports domain rejection" true
       (Runtime.For_testing.classified_error_kind error
        = Keeper_memory_os_current.Domain_output_invalid);
     check bool "failure retains the domain boundary" true
       (Astring.String.is_prefix
          ~affix:"librarian domain output invalid:"
          (Runtime.For_testing.classified_error_detail error));
     check int "the only usable slot was attempted" 1 (Fixture.post_count first));
  let selected_slots = publish [ "librarian-bad" ] in
  match
    Runtime.preflight_slots ~requirement:ordinary_requirement ~selected_slots ~messages:[ message "one small prompt" ]
  with
  | Ok _ -> fail "a ladder with no projectable slot passed pre-flight"
  | Error error ->
    let text = Runtime.extraction_error_to_string error in
    check bool "the failure names the refusing slot" true
      (Astring.String.is_infix ~affix:"librarian-bad" text);
    check bool "the failure names the refusal reason" true
      (Astring.String.is_infix ~affix:"target_request_rejected" text)
;;

(* The exported empty-ladder verdict, pinned: it reports nothing, exactly as
   the caller that routes an empty slot list to the cli lane expects it to. *)
let test_an_empty_ladder_reports_nothing () =
  let message =
    Agent_core.Types.make_message
      ~role:Agent_core.Types.User
      [ Agent_core.Types.Text "one small prompt" ]
  in
  match Runtime.preflight_slots ~requirement:ordinary_requirement ~selected_slots:[] ~messages:[ message ] with
  | Ok preflight ->
    check int "no selected slots" 0 (List.length preflight.Runtime.selected_slots);
    check (list (pair string string)) "nothing to exclude" [] preflight.Runtime.unusable
  | Error error -> fail (Runtime.extraction_error_to_string error)
;;

let () =
  run
    "Keeper Librarian exact-lane preference"
    [ ( "production adapter"
      , [ test_case
            "Keeper preference selects first slot and commits"
            `Quick
            test_keeper_preference_reorders_the_librarian_lane
        ; test_case
            "working context commits despite Memory OS store failure"
            `Quick
            test_context_commits_when_memory_store_fails
        ; test_case "excluded last slot preserves domain failure" `Quick
            test_excluded_last_slot_preserves_domain_failure
        ; test_case "an empty ladder reports nothing" `Quick
            test_an_empty_ladder_reports_nothing
        ] )
    ]
;;
