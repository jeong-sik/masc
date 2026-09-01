open Alcotest
open Masc

module Fixture = Exact_output_fixture
module Librarian = Keeper_librarian
module Memory = Keeper_memory_os_types
module Runtime = Keeper_librarian_runtime

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
    [ Librarian.wire_field_retained_memory_ids, `List []
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
  ; keeper_instructions = "Curate current memory."
  ; current = None
  ; messages =
      [ Agent_core.Types.make_message
          ~role:Agent_core.Types.User
          [ Agent_core.Types.Text "remember the preferred result" ]
      ]
  ; tool_observations = []
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

(* Lane audit W1/W2: the librarian's byte-budget fit. A slot whose
   request-body limit cannot hold the full prompt shrinks the message window
   through render_at; a prompt whose fixed material alone exceeds the limit
   is the typed over-budget setup error instead of a provider round-trip. *)
let test_fit_shrinks_to_slot_budget_and_reports_zero_fit () =
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
  let server =
    Fixture.start_server
      ~sw
      ~net
      ~clock
      (Fixture.Reply (Fixture.openai_response selection_output))
  in
  let snapshot =
    Fixture.resolver_snapshot
      ~source:"librarian-fit-budget"
      ~request_body_limits:[ "librarian-tight", 4096 ]
      [ { Fixture.id = "librarian-tight"; base_url = server.base_url } ]
  in
  (match
     Runtime_exact_output_registry.publish
       ~lanes:
         [ { Runtime_schema.id = "librarian_exact"
           ; slot_ids = [ "librarian-tight" ]
           ; cli_slot_ids = []
           }
         ]
       snapshot
   with
   | Ok _ -> ()
   | Error error ->
     fail (Runtime_exact_output_registry.publication_error_to_string error));
  let selected_slots =
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
  let message text =
    Agent_core.Types.make_message
      ~role:Agent_core.Types.User
      [ Agent_core.Types.Text text ]
  in
  let big = String.make 20_000 'x' in
  let render_at k = Ok [ message (String.make (200 * (k + 1)) 'y') ] in
  (match
     Runtime.fitted_messages
       ~selected_slots
       ~full_messages:[ message big ]
       ~render_at
   with
   | Ok (_, None) -> fail "an oversized prompt reported no shrink"
   | Ok (fitted, Some count) ->
     check bool "shrunk window is non-empty" true (count >= 0);
     check bool "fitted prompt is smaller than the full prompt" true
       (match fitted with
        | [ { Agent_core.Types.content = [ Agent_core.Types.Text text ]; _ } ] ->
          String.length text < String.length big
        | _ -> false)
   | Error error -> fail (Runtime.extraction_error_to_string error));
  match
    Runtime.fitted_messages
      ~selected_slots
      ~full_messages:[ message big ]
      ~render_at:(fun _ -> Ok [ message big ])
  with
  | Ok _ -> fail "a prompt over budget at every window size fitted"
  | Error error ->
    check bool "zero-fit is the typed over-budget error" true
      (Astring.String.is_infix ~affix:"request-body limit"
         (Runtime.extraction_error_to_string error))
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
            "fit shrinks to slot budget and types zero-fit"
            `Quick
            test_fit_shrinks_to_slot_budget_and_reports_zero_fit
        ] )
    ]
;;
