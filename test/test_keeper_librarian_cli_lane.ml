open Alcotest

(* CLI lane-slot fallback for librarian_exact (RFC cli-runtimes-as-lane-slots):
   the classified exact-output pass walks the declared cli slots only after
   the catalog reports provider exhaustion, applies the same selection
   contract to the cli answer, and abandons the fallback on a domain-invalid
   one. The runtime table is the fusion panel fixture (command /usr/bin/true)
   so [is_official_client] admits the cli ids without spawning a client. *)

module Librarian = Masc.Keeper_librarian
module Runtime = Masc.Keeper_librarian_runtime
module Memory = Masc.Keeper_memory_os_types
module Fixture = Exact_output_fixture
module Ids = Ids

let has_prompt_root root =
  Sys.file_exists (Filename.concat root "config/prompts/librarian.md")
;;

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
    let rec ascend path =
      if has_prompt_root path
      then path
      else (
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent)
    in
    ascend (Sys.getcwd ())
;;

let () =
  let prompts_dir = Filename.concat (repo_root ()) "config/prompts" in
  Prompt_registry.set_markdown_dir prompts_dir;
  Masc.Prompt_defaults.init ()
;;

let fact ~claim : Memory.fact =
  Memory.observed ~claim ~category:Memory.Fact ~now:1_000_000.
    ~origin:{ kind = Memory.Authored; trace_id = "" }
;;

let current_a = fact ~claim:"keep A"
let current_b = fact ~claim:"drop B"

let input () : Librarian.input =
  { turn_ref = Ids.Turn_ref.make ~trace_id:"trace-cli-lane" ~absolute_turn:7
  ; keeper_instructions = "You are the cli-lane keeper."
  ; current = Some { Librarian.facts = [ current_a; current_b ] }
  ; messages =
      [ Agent_core.Types.make_message
          ~role:Agent_core.Types.User
          [ Agent_core.Types.Text "new conversation" ]
      ]
  ; tool_observations = []
  ; counterpart_observations = []
  }
;;

(* Surrogate identities: m1 = current_a (retained), m2 = current_b (dropped)
   — the totality contract the parser enforces for this input. *)
let valid_selection_json =
  `Assoc
    [ Librarian.wire_field_retained_memory_ids, `List [ `String "m1" ]
    ; Librarian.wire_field_new_claims, `List []
    ; ( Librarian.wire_field_dropped
      , `List
          [ `Assoc
              [ Librarian.wire_field_memory_id, `String "m2"
              ; Librarian.wire_field_reason, `String "superseded by newer state"
              ]
          ] )
    ]
;;

let publish_unreachable_lane ~cli_slot_ids ~source =
  ignore
    (Fixture.publish_registry
       ~cli_slot_ids
       ~lane_id:"librarian_exact"
       ~slot_ids:[ "librarian-cli-unreachable" ]
       (Fixture.resolver_snapshot
          ~source
          [ { Fixture.id = "librarian-cli-unreachable"
            ; base_url = "http://127.0.0.1:1"
            }
          ])
      : Runtime_exact_output_registry.t)
;;

let execute ~net ~clock ~base_path ~runner =
  let selected_input = input () in
  match Runtime.messages_for_librarian selected_input with
  | Error detail -> failf "librarian render failed: %s" detail
  | Ok messages ->
    Runtime.For_testing.execute_exact_output_classified
      ~cli_runner:runner
      ~clock
      ~net
      ~base_path
      ~keeper_id:"librarian-cli-test"
      ~selected_input
      ~messages
      ~render_at:(fun _ -> Ok messages)
      ()
;;

let with_eio f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
  @@ fun () ->
  let base_path = Filename.temp_dir "librarian-cli-lane" "" in
  f ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) ~base_path
;;

let test_cli_slot_answers_after_catalog_exhaustion () =
  with_eio
  @@ fun ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes
  @@ fun () ->
  publish_unreachable_lane
    ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
    ~source:"librarian cli fallback";
  let seen = ref None in
  let runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt =
    seen := Some runtime_id;
    check bool
      "the cli prompt is the fitted librarian prompt"
      true
      (String.length prompt > 0);
    Ok (Yojson.Safe.to_string valid_selection_json)
  in
  match execute ~net ~clock ~base_path ~runner with
  | Error error ->
    failf
      "the cli slot must answer: %s"
      (Runtime.For_testing.classified_error_detail error)
  | Ok ((_selection, output), selected_slot, _fitted) ->
    check (option string)
      "the declared cli slot ran"
      (Some Fixture.cli_primary_runtime)
      !seen;
    check string
      "the answering slot is the cli runtime id"
      Fixture.cli_primary_runtime
      selected_slot;
    check bool
      "the accepted output is the cli answer"
      true
      (Yojson.Safe.equal output valid_selection_json)
;;

let test_domain_invalid_cli_answer_keeps_the_terminal () =
  with_eio
  @@ fun ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes
  @@ fun () ->
  publish_unreachable_lane
    ~cli_slot_ids:[ Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime ]
    ~source:"librarian cli invalid";
  let attempts = ref [] in
  let runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    attempts := !attempts @ [ runtime_id ];
    Ok "{}" (* valid JSON, invalid selection domain *)
  in
  (match execute ~net ~clock ~base_path ~runner with
   | Ok _ -> fail "a domain-invalid cli answer must not be accepted"
   | Error error ->
     check bool
       "the catalog terminal survives the failed fallback"
       true
       (Astring.String.is_infix
          ~affix:"exact execution failed"
          (Runtime.For_testing.classified_error_detail error)));
  check
    (list string)
    "only the first cli slot ran — the walk returns the first JSON answer \
     and domain validation does not re-enter it"
    [ Fixture.cli_primary_runtime ]
    !attempts
;;

let () =
  run
    "keeper_librarian_cli_lane"
    [ ( "cli lane slots"
      , [ test_case
            "a cli slot answers after catalog exhaustion"
            `Quick
            test_cli_slot_answers_after_catalog_exhaustion
        ; test_case
            "a domain-invalid cli answer keeps the terminal"
            `Quick
            test_domain_invalid_cli_answer_keeps_the_terminal
        ] )
    ]
;;
