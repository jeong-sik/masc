(* Keeper_context_layers — pure ordered-fold of the keeper world-state user
   message. These tests pin the two properties the typed fold replaces an
   imperative buffer to guarantee: a single declared render order, and that the
   assembled body is exactly the in-order concatenation of the present layers
   (a [None] layer contributes nothing). *)

open Alcotest
module L = Masc.Keeper_context_layers

(* The full constructor set, listed independently of [L.ordered] so a drift
   between the two is observable here rather than silently dropping a section. *)
let all_layers =
  [
    L.Active_goals;
    L.Direct_input_source;
    L.Goal_observations;
    L.Goals_awaiting_proof;
    L.Current_task;
    L.Approval_authority;
    L.Connected_surfaces;
    L.Namespace_state;
    L.Workspace_memory;
    L.Wiki;
    L.Lane_updates;
    L.Autonomous_trigger;
    L.Scheduled_automation;
    L.Completion_authority;
    L.Task_cancellations;
    L.Pending_mentions;
    L.Own_board_posts;
    L.Board_activity;
    L.Own_recent_actions;
    L.Recent_work;
    L.Fleet_messages;
  ]

let test_ordered_is_complete_permutation () =
  check int "ordered length matches constructor count" (List.length all_layers)
    (List.length L.ordered);
  List.iter
    (fun id ->
      check bool
        (Printf.sprintf "ordered contains layer at index %d" (L.order_index id))
        true
        (List.mem id L.ordered))
    all_layers

let test_order_index_matches_position () =
  List.iteri
    (fun i id ->
      check int
        (Printf.sprintf "order_index agrees with position %d" i)
        i (L.order_index id))
    L.ordered

let test_order_index_is_injective () =
  let indices = List.map L.order_index all_layers in
  let sorted = List.sort_uniq compare indices in
  check int "order_index distinct across all layers"
    (List.length all_layers) (List.length sorted)

let test_assemble_concatenates_present_in_order () =
  (* Render a label for three layers spread across the order (positions 0, 4, 9)
     and nothing for the rest; assemble must yield them in ordered order. *)
  let content_of = function
    | L.Active_goals -> Some "A"
    | L.Autonomous_trigger -> Some "T"
    | L.Board_activity -> Some "B"
    | _ -> None
  in
  check string "present layers concatenated in ordered order" "ATB"
    (L.text (L.assemble ~content_of))

let test_assemble_empty_when_all_absent () =
  check string "no layers -> empty body" "" (L.text (L.assemble ~content_of:(fun _ -> None)))

let test_assemble_all_present_follows_ordered () =
  (* Each layer renders its own order index; the result must read 0..n-1.
     The expectation counts [all_layers], which is maintained by hand
     independently of [L.ordered], so a layer missing from either list still
     fails here — and adding a layer no longer means hand-editing a literal. *)
  let content_of id = Some (string_of_int (L.order_index id)) in
  let expected =
    List.init (List.length all_layers) string_of_int |> String.concat ""
  in
  check string "every layer present -> indices in order" expected
    (L.text (L.assemble ~content_of))

let test_issued_partition_preserves_occurrences () =
  let open Yojson.Safe.Util in
  let calls = ref [] in
  let repeated = "한글 \"same\"\n\\tail" in
  let rendered = L.assemble ~content_of:(fun layer ->
      calls := layer :: !calls;
      match layer with
      | L.Active_goals | L.Current_task -> Some repeated
      | L.Approval_authority -> Some ""
      | _ -> None)
    |> L.prepend_unattributed World_frame "" in
  let rendered = L.append_unattributed rendered Host_workspace_recall "HOST" in
  check bool "each producer is evaluated once in order" true (List.rev !calls = L.ordered);
  check string "source text is unchanged" (repeated ^ repeated ^ "HOST") (L.text rendered);
  let receipt = L.receipt_to_json rendered in
  let spans = member "spans" receipt |> to_list in
  check int "empty present layers and prefix retain their occurrences" 5 (List.length spans);
  check (list string) "repeated bytes retain distinct typed layer identities"
    ["active_goals"; "current_task"; "approval_authority"]
    (List.filter_map (fun span -> match member "layer" (member "source" span) with
      | `String name -> Some name | _ -> None) spans);
  let cursor = ref 0 in
  List.iter (fun span ->
    let offset = member "offset" span |> to_int in
    let bytes = member "bytes" span |> to_int in
    check int "contiguous actual source offset" !cursor offset;
    let actual = String.sub (L.text rendered) offset bytes in
    check string "actual slice hash" (member "sha256" span |> to_string)
      Agent_core_sha256.(digest_string actual |> to_hex);
    cursor := offset + bytes) spans;
  check int "all bytes accounted for" (String.length (L.text rendered)) !cursor

(* A resumed official-client session records which World State sections it
   holds by these names, so every source must read back as itself. The
   unattributed list is kept by hand here, as [all_layers] is. *)
let test_every_section_name_reads_back () =
  let sources =
    List.map (fun layer -> L.Layer layer) all_layers
    @ List.map (fun reason -> L.Unattributed reason)
        [ L.World_frame; L.Host_workspace_recall; L.Connector_personal_memory; L.Direct_turn; L.Unprojected_input ]
  in
  List.iter
    (fun source ->
      check bool (L.source_name source ^ " reads back") true
        (L.source_of_name (L.source_name source) = Some source))
    sources;
  check int "names are distinct" (List.length sources)
    (List.length (List.sort_uniq compare (List.map L.source_name sources)));
  check bool "an unknown name is refused" true (L.source_of_name "board" = None)

let test_sections_split_the_text_by_source () =
  let rendered =
    L.assemble ~content_of:(function
      | L.Wiki -> Some "WIKI"
      | L.Fleet_messages -> Some "FLEET"
      | _ -> None)
    |> L.prepend_unattributed World_frame "FRAME"
  in
  let rendered = L.append_unattributed rendered Host_workspace_recall "RECALL" in
  check (list (pair string string)) "each span with its source, in order"
    [ "world_frame", "FRAME"; "wiki", "WIKI"; "fleet_messages", "FLEET";
      "host_workspace_recall", "RECALL" ]
    (List.map
       (fun (section : L.section) -> L.source_name section.L.section_source, section.L.section_text)
       (L.sections rendered));
  check string "the sections concatenate to the text" (L.text rendered)
    (String.concat ""
       (List.map (fun (section : L.section) -> section.L.section_text) (L.sections rendered)))

(* A section with rows keeps its exact bytes and hands back its head, rows and
   tail, so a resume can send only the rows a session lacks (#45131). *)
let test_a_section_with_rows_keeps_its_bytes_and_its_rows () =
  let rows = [ "- [turn 1] Read -> ok\n"; "- [turn 2] Execute -> ok\n" ] in
  let rendered =
    L.assemble_prepared ~content_of:(function
      | L.Own_recent_actions ->
        Some (L.prepare_rows ~head:"### Your Recent Actions (2 turns)\n" ~rows ~tail:"\n")
      | L.Wiki -> Some (L.prepare_content "WIKI")
      | _ -> None)
  in
  check string "the text is the head, the rows and the tail"
    ("WIKI" ^ "### Your Recent Actions (2 turns)\n" ^ String.concat "" rows ^ "\n")
    (L.text rendered);
  match L.sections rendered with
  | [ { L.section_rows = L.Whole_section; _ };
      { L.section_source = L.Layer L.Own_recent_actions;
        section_rows = L.Head_and_rows { head; rows = got; tail }; section_text } ] ->
    check string "the head" "### Your Recent Actions (2 turns)\n" head;
    check (list string) "the rows" rows got;
    check string "the tail" "\n" tail;
    check string "the section text joins them" (head ^ String.concat "" got ^ tail) section_text
  | _ -> fail "the wiki is one text and recent actions is a head with rows"

let test_a_section_without_rows_is_one_text () =
  let rendered =
    L.assemble_prepared ~content_of:(function
      | L.Own_recent_actions -> Some (L.prepare_rows ~head:"HEAD" ~rows:[] ~tail:"TAIL")
      | _ -> None)
  in
  match L.sections rendered with
  | [ { L.section_rows = L.Whole_section; section_text; _ } ] ->
    check string "no rows is the head and tail as one text" "HEADTAIL" section_text
  | _ -> fail "a section with no rows is one text"

let test_author_of_layer_partition () =
  let expected_host_state =
    [
      L.Goals_awaiting_proof;
      L.Approval_authority;
      L.Connected_surfaces;
      L.Namespace_state;
      L.Workspace_memory;
      L.Lane_updates;
      L.Autonomous_trigger;
      L.Scheduled_automation;
    ]
  in
  List.iter
    (fun layer ->
      let expected =
        if List.mem layer expected_host_state then L.Host_state else L.Outside_text
      in
      let label = L.source_name (L.Layer layer) ^ " author classification" in
      check bool label true (L.author_of_layer layer = expected))
    all_layers;
  let host_count =
    List.length (List.filter (fun l -> L.author_of_layer l = L.Host_state) all_layers)
  in
  let outside_count =
    List.length (List.filter (fun l -> L.author_of_layer l = L.Outside_text) all_layers)
  in
  check int "exactly 8 Host_state layers" 8 host_count;
  check int "exactly 13 Outside_text layers" 13 outside_count

let test_pending_mentions_and_fleet_messages_resend_on_resume () =
  check bool "Pending_mentions is Sent_when_changed for row-level resume dedup" true
    (L.resend_on_resume (L.Layer L.Pending_mentions) = L.Sent_when_changed);
  check bool "Fleet_messages is Sent_when_changed for row-level resume dedup" true
    (L.resend_on_resume (L.Layer L.Fleet_messages) = L.Sent_when_changed);
  check bool "Board_activity remains Sent_every_resume" true
    (L.resend_on_resume (L.Layer L.Board_activity) = L.Sent_every_resume)

let test_partition_by_author_and_volatile_tail () =
  let rendered =
    L.assemble ~content_of:(function
      | L.Active_goals -> Some "[Goal] ship stack A\n"
      | L.Goals_awaiting_proof -> Some "[Proof] goal-1\n"
      | L.Namespace_state -> Some "[Namespace] open=2\n"
      | L.Board_activity -> Some "[Board] untrusted post\n"
      | L.Direct_input_source | L.Goal_observations | L.Current_task
      | L.Approval_authority | L.Connected_surfaces | L.Workspace_memory
      | L.Wiki | L.Lane_updates | L.Autonomous_trigger | L.Scheduled_automation
      | L.Completion_authority | L.Task_cancellations | L.Pending_mentions
      | L.Own_board_posts | L.Own_recent_actions | L.Recent_work
      | L.Fleet_messages -> None)
  in
  let host, outside = L.partition_by_author rendered in
  check string "Host_state keeps only host layers"
    "[Proof] goal-1\n[Namespace] open=2\n"
    (L.text host);
  check string "Outside_text keeps only untrusted external layers"
    "[Goal] ship stack A\n[Board] untrusted post\n"
    (L.text outside);
  let system =
    Masc.Keeper_turn_system.resend
      ~held:None ~runtime_id:"test" ~current:[] ~articles_at:(fun _ -> Ok None)
      "Base system prompt"
    |> Result.get_ok |> fst
  in
  let assembly =
    Masc.Keeper_run_prompt.assemble_request_context
      ~checkpoint_owner:Runtime_execution.Masc_agent_core
      ~system
      ~post_tool_round:false
      ~previous_assembly:None
      ~dynamic_context_partition:(Some rendered)
      ~existing_extra_system_context:None
      ~blocks:[ Prompt_block_id.Dynamic_context, L.text rendered ]
  in
  check (option string) "Agent Core keeps Active_goals and Goals_awaiting_proof out of system_prompt_override"
    None
    (Masc.Keeper_context_assembly.system_prompt_override ~previous:None assembly);
  let host_ctx, outside_ctx = Masc.Keeper_context_assembly.split_outside_context assembly in
  check bool "host_ctx carries host-owned state" true
    (match host_ctx with
     | Some s -> Astring.String.is_infix ~affix:"[Namespace] open=2" s
                 && Astring.String.is_infix ~affix:"[Proof] goal-1" s
                 && not (Astring.String.is_infix ~affix:"[Board] untrusted post" s)
     | None -> false);
  check bool "outside_ctx carries outside-authored text" true
    (match outside_ctx with
     | Some s -> Astring.String.is_infix ~affix:"[Board] untrusted post" s
                 && Astring.String.is_infix ~affix:"[Goal] ship stack A" s
                 && not (Astring.String.is_infix ~affix:"[Namespace] open=2" s)
     | None -> false)
;;

let test_private_connector_section_can_be_removed_from_capture () =
  let module Assembly = Masc.Keeper_context_assembly in
  let rendered = L.singleton Board_activity "shared activity\n" in
  let rendered = L.append_unattributed rendered Connector_personal_memory "private fact\n" in
  let assemble partition =
    Assembly.assemble ~dynamic_context_partition:(Some partition)
      ~existing_extra_system_context:None ~blocks:[ Dynamic_context, L.text partition ]
  in
  let live = assemble rendered in
  check bool "live request carries scoped text" true (Assembly.has_connector_personal_memory live);
  let capture = Assembly.without_connector_personal_memory live in
  check bool "capture has no scoped section" false (Assembly.has_connector_personal_memory capture);
  check (option string) "capture keeps only shared activity" (Some "shared activity\n")
    capture.extra_system_context
;;

let test_private_connector_requires_request_only_runtime () =
  let api ?previous_response_id kind =
    Llm_provider.Provider_config.make ~kind ~provider_id:"fixture" ~model_id:"fixture"
      ~base_url:"http://127.0.0.1" ?previous_response_id ()
    |> Runtime_account_access.seal_api
    |> fun sealed -> Runtime_execution.Agent_core sealed
  in
  let supports = Runtime_execution.supports_request_only_context in
  check bool "ordinary Agent Core HTTP receives request-local context" true
    (supports (api OpenAI_compat));
  check bool "signed context can be retained in the Anthropic checkpoint" false
    (supports (api Anthropic));
  check bool "a provider-side response chain can retain the carrier" false
    (supports (api ~previous_response_id:"response-fixture" OpenAI_compat))
;;

let () =
  run "keeper_context_layers"
    [
      ( "L5/L6 privilege separation and volatile tail",
        [
          test_case "partition_by_author and split_outside_context keep goals/proofs out of system_prompt_override" `Quick
            test_partition_by_author_and_volatile_tail;
          test_case "private connector section is removed from captures" `Quick
            test_private_connector_section_can_be_removed_from_capture;
          test_case "only request-local runtimes can receive private connector context" `Quick
            test_private_connector_requires_request_only_runtime;
        ] );
      ( "ordering",
        [
          test_case "ordered is a complete permutation" `Quick
            test_ordered_is_complete_permutation;
          test_case "order_index matches ordered position" `Quick
            test_order_index_matches_position;
          test_case "order_index is injective" `Quick
            test_order_index_is_injective;
        ] );
      ( "classification",
        [
          test_case "author_of_layer partitions all 21 layers" `Quick
            test_author_of_layer_partition;
          test_case "pending mentions and fleet messages resend when changed" `Quick
            test_pending_mentions_and_fleet_messages_resend_on_resume;
        ] );
      ( "assemble",
        [
          test_case "issued partition preserves repeated and empty occurrences" `Quick
            test_issued_partition_preserves_occurrences;
          test_case "concatenates present layers in order" `Quick
            test_assemble_concatenates_present_in_order;
          test_case "empty when all absent" `Quick
            test_assemble_empty_when_all_absent;
          test_case "all present follows ordered" `Quick
            test_assemble_all_present_follows_ordered;
          test_case "sections split the text by source" `Quick
            test_sections_split_the_text_by_source;
          test_case "a section with rows keeps its bytes and its rows" `Quick
            test_a_section_with_rows_keeps_its_bytes_and_its_rows;
          test_case "a section without rows is one text" `Quick
            test_a_section_without_rows_is_one_text;
        ] );
      ( "section names",
        [
          test_case "every section name reads back" `Quick
            test_every_section_name_reads_back;
        ] );
    ]
