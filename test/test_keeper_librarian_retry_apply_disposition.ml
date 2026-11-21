open Alcotest

module Librarian = Masc.Keeper_librarian
module Runtime = Masc.Keeper_librarian_runtime
module Memory = Masc.Keeper_memory_os_types
module Post_turn_memory = Masc.Keeper_agent_run_post_turn_memory
module Keeper_chat_store = Masc.Keeper_chat_store
module Keeper_counterpart_observation = Masc.Keeper_counterpart_observation
module Events = Masc.Keeper_memory_os_events
module Tool_memory = Masc.Keeper_tool_memory_runtime
module Current = Masc.Keeper_memory_os_current

(* Render tests resolve the real repo templates so template <-> code
   variable drift fails here instead of as a live [Prompt_render_failed]
   (same pattern as test_keeper_prompt_metrics). *)
let () = Masc.Prompt_defaults.init ()

let fact ~claim : Memory.fact =
  Memory.observed ~claim ~category:Memory.Fact ~now:1_000_000.
    ~origin:{ kind = Memory.Authored; trace_id = "" }
;;

let current_a = fact ~claim:"keep A"
let current_b = fact ~claim:"drop B"
let current_a_id = Memory.memory_id current_a
let current_b_id = Memory.memory_id current_b

(* Spelled nowhere else in the fixture, so its count in a rendered prompt is
   the count of the host-data slot. *)
let librarian_subject_keeper = "librarian-subject-keeper"

let input () : Librarian.input =
  { turn_ref =
      Ids.Turn_ref.make
        ~trace_id:"trace-selection"
        ~absolute_turn:7
  ; historical_task_contexts = []; goal_context = Masc.Keeper_librarian.No_task
  ; keeper_id = Masc_test_deps.keeper_id_fixture librarian_subject_keeper
  ; keeper_instructions = "You are the retry-test keeper."
  ; current =
      Some
        { Librarian.facts = [ current_a; current_b ] }
  ; messages =
      [ Agent_core.Types.make_message
          ~role:Agent_core.Types.User
          [ Agent_core.Types.Text "new conversation" ]
      ]
  ; tool_observations =
      [ { Librarian.tool_name = "keeper_artifact_read"
        ; outcome = Librarian.Succeeded
        }
      ; { Librarian.tool_name = "tool_execute"
        ; outcome = Librarian.Failed
        }
      ; { Librarian.tool_name = "unclassified_tool"
        ; outcome = Librarian.Unknown
        }
      ]
  ; working_context = Masc.Keeper_librarian_context.empty
  ; counterpart_observations = []
  }
;;

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let superseding_claim ?(claim = "B, corrected") supersedes () =
  `Assoc
    [ Librarian.wire_field_claim, `String claim
    ; Librarian.wire_field_category, `String "fact"
    ; Librarian.wire_field_supersedes, supersedes
    ]
;;

let absorbing_claim ?(claim = "A and B, together") absorbs () =
  `Assoc
    [ Librarian.wire_field_claim, `String claim
    ; Librarian.wire_field_category, `String "fact"
    ; Librarian.wire_field_absorbs, absorbs
    ]
;;

let dropped_json ?(reason = "superseded by newer state") id =
  `Assoc
    [ Librarian.wire_field_memory_id, `String id
    ; Librarian.wire_field_reason, `String reason
    ]
;;

(* Defaults retire B and leave A unmentioned, which is the shape the contract
   now asks for: name what changes. Model output speaks in surrogate
   identities: [m1] is current_a, [m2] is current_b; the parser maps them back
   to real identities. *)
let selection_json
      ?(new_claims = [])
      ?(dropped = [ dropped_json "m2" ])
      ()
  =
  `Assoc
    [ "working_contexts", `List []
    ; Librarian.wire_field_new_claims, `List new_claims
    ; Librarian.wire_field_dropped, `List dropped
    ]
;;

let parse json =
  Librarian.selection_of_json_result ~now:2_000_000. (input ()) json
;;

(* The librarian may name the Board post a claim was read from. The name is
   typed into the fact's basis; a claim without it is a transcript
   observation, and a name the Board's own grammar rejects fails the claim
   like any other malformed field. *)
let board_claim ?comment_id ~post_id claim =
  `Assoc
    ([ Librarian.wire_field_claim, `String claim
     ; Librarian.wire_field_category, `String "lesson"
     ; Memory.wire_field_board_post_id, `String post_id
     ]
     @ (match comment_id with
        | None -> []
        | Some comment_id -> [ Memory.wire_field_board_comment_id, `String comment_id ]))
;;

(* Nothing touches A during the pass, and the answer restated A and absorbed B
   into it. B leaves with its row pointing into A, and A is there once. *)
let test_a_restated_memory_still_current_takes_its_absorptions () =
  let keepers_dir = Filename.temp_dir "librarian-restated-kept-" "" in
  Fun.protect ~finally:(fun () -> rm_rf keepers_dir) (fun () ->
    let keeper_id = "kept" in
    let require = function Ok value -> value | Error detail -> fail detail in
    ignore
      (Current.replace ~keepers_dir ~keeper_id ~expected_revision:None ~now:100.
         ~source:{ kind = Current.Explicit_write; trace_id = "trace-seed" }
         ~facts:[ current_a; current_b ] ()
       |> require
       : Current.t);
    let selection =
      match
        parse
          (selection_json
             ~dropped:[]
             ~new_claims:[ absorbing_claim ~claim:"keep A" (`List [ `String "m2" ]) () ]
             ())
      with
      | Ok selection -> selection
      | Error error -> fail (Librarian.parse_error_to_string error)
    in
    let committed =
      Current.apply_disposition ~pass:Masc.Keeper_memory_commit_pass.Durable ~keepers_dir ~keeper_id ~now:200.
        ~source:{ kind = Current.Librarian; trace_id = "trace-selection" }
        ~dropped_statements:selection.dropped ~absorbed:selection.absorbed ~revisions:selection.revisions
        ~new_claims:selection.new_claims
        ()
      |> require
    in
    let pairs statements =
      List.map
        (fun (statement : Masc.Keeper_memory_os_types.absorbed_statement) ->
           statement.absorbed ^ "->" ^ statement.into)
        statements
    in
    check (list string) "the commit reports B absorbed into A"
      [ current_b_id ^ "->" ^ current_a_id ]
      (pairs committed.absorbed_applied);
    check (list string) "and nothing left unapplied" [] (pairs committed.absorbed_not_applied);
    let committed = committed.snapshot in
    check (list string) "A once, B absorbed"
      [ current_a_id ]
      (List.map Memory.memory_id committed.facts);
    match Masc.Keeper_memory_absorbed.read ~keepers_dir ~keeper_id with
    | Error detail -> fail detail
    | Ok [ (_, Ok (record : Masc.Keeper_memory_absorbed.record)) ] ->
      check string "the row is B's" current_b_id record.memory_id;
      check string "the row points into A" current_a_id record.into
    | Ok lines -> failf "expected one absorbed row, read %d lines" (List.length lines))
;;

(* The keeper retracts A while the pass runs, and the answer restated A and
   absorbed B into it. The keeper's removal stands: A is not brought back, the
   absorption into A is not applied, and B stays current with no absorbed row
   (#38186). *)
let test_a_restated_memory_retracted_during_the_pass_stays_retracted_and_keeps_its_sources () =
  let keepers_dir = Filename.temp_dir "librarian-restated-race-" "" in
  Fun.protect ~finally:(fun () -> rm_rf keepers_dir) (fun () ->
    let keeper_id = "race" in
    let require = function Ok value -> value | Error detail -> fail detail in
    let seeded =
      Current.replace ~keepers_dir ~keeper_id ~expected_revision:None ~now:100.
        ~source:{ kind = Current.Explicit_write; trace_id = "trace-seed" }
        ~facts:[ current_a; current_b ] ()
      |> require
    in
    let selection =
      match
        parse
          (selection_json
             ~dropped:[]
             ~new_claims:[ absorbing_claim ~claim:"keep A" (`List [ `String "m2" ]) () ]
             ())
      with
      | Ok selection -> selection
      | Error error -> fail (Librarian.parse_error_to_string error)
    in
    ignore
      (Current.replace ~keepers_dir ~keeper_id
         ~expected_revision:(Some seeded.revision) ~now:150.
         ~source:{ kind = Current.Explicit_write; trace_id = "trace-retract" }
         ~facts:[ current_b ] ()
       |> require
       : Current.t);
    let committed =
      Current.apply_disposition ~pass:Masc.Keeper_memory_commit_pass.Durable ~keepers_dir ~keeper_id ~now:200.
        ~source:{ kind = Current.Librarian; trace_id = "trace-selection" }
        ~dropped_statements:selection.dropped ~absorbed:selection.absorbed ~revisions:selection.revisions
        ~new_claims:selection.new_claims
        ()
      |> require
    in
    let pairs statements =
      List.map
        (fun (statement : Masc.Keeper_memory_os_types.absorbed_statement) ->
           statement.absorbed ^ "->" ^ statement.into)
        statements
    in
    (* The run record reads these lists; a record that said B went into A
       while B is still current would be wrong. *)
    check (list string) "the commit reports no absorption applied" []
      (pairs committed.absorbed_applied);
    check (list string) "and B into A as not applied"
      [ current_b_id ^ "->" ^ current_a_id ]
      (pairs committed.absorbed_not_applied);
    let committed = committed.snapshot in
    check (list string) "A stays retracted and B stays current"
      [ current_b_id ]
      (List.map Memory.memory_id committed.facts);
    match Masc.Keeper_memory_absorbed.read ~keepers_dir ~keeper_id with
    | Error detail -> fail detail
    | Ok [] -> ()
    | Ok lines -> failf "expected no absorbed row, read %d lines" (List.length lines))
;;

(* One Librarian round with the keeper acting during its provider turn: seed A
   and B, read [answer] against that snapshot, let the keeper replace the facts
   with [keeper_facts] or supersede one with [keeper_supersede], then commit
   the answer. The revisions come back as the journal records them: the
   commit's own row is their only record (#37433). *)
let librarian_round
      ~name
      ~answer
      ?keeper_facts
      ?keeper_supersede
      ?(inspect = fun ~keepers_dir:_ ~keeper_id:_ -> ())
      ()
  =
  let keepers_dir = Filename.temp_dir ("librarian-" ^ name ^ "-") "" in
  Fun.protect ~finally:(fun () -> rm_rf keepers_dir) (fun () ->
    let keeper_id = name in
    let require = function Ok value -> value | Error detail -> fail detail in
    let seeded =
      Current.replace ~keepers_dir ~keeper_id ~expected_revision:None ~now:100.
        ~source:{ kind = Current.Explicit_write; trace_id = "trace-seed" }
        ~facts:[ current_a; current_b ] ()
      |> require
    in
    let selection =
      match parse answer with
      | Ok selection -> selection
      | Error error -> fail (Librarian.parse_error_to_string error)
    in
    Option.iter
      (fun facts ->
         ignore
           (Current.replace ~keepers_dir ~keeper_id
              ~expected_revision:(Some seeded.revision) ~now:150.
              ~source:{ kind = Current.Explicit_write; trace_id = "trace-keeper" }
              ~facts ()
            |> require
            : Current.t))
      keeper_facts;
    Option.iter
      (fun (superseded_memory_id, successor) ->
         match
           Current.supersede_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
             ~keepers_dir ~keeper_id ~now:150.
             ~source:{ kind = Current.Explicit_write; trace_id = "trace-keeper" }
             ~superseded_memory_id successor
         with
         | Ok _ -> ()
         | Error _ -> fail "the keeper's supersede did not commit")
      keeper_supersede;
    let disposition =
      Current.apply_disposition ~pass:Masc.Keeper_memory_commit_pass.Durable ~keepers_dir ~keeper_id ~now:200.
        ~source:{ kind = Current.Librarian; trace_id = "trace-selection" }
        ~dropped_statements:selection.dropped ~absorbed:selection.absorbed
        ~revisions:selection.revisions ~new_claims:selection.new_claims
        ()
      |> require
    in
    let revisions =
      match Current.read_commit_lineage ~keepers_dir ~keeper_id with
      | Ok lineage -> lineage.Current.revisions
      | Error detail -> fail detail
    in
    let absorbed_rows =
      match Masc.Keeper_memory_absorbed.read ~keepers_dir ~keeper_id with
      | Error detail -> fail detail
      | Ok lines -> List.length lines
    in
    inspect ~keepers_dir ~keeper_id;
    selection, disposition, revisions, absorbed_rows)
;;

let readable_journal_tail ~keepers_dir ~keeper_id ~limit =
  match Current.read_journal_tail ~keepers_dir ~keeper_id ~limit with
  | Ok rows -> rows
  | Error detail -> failwith ("memory journal unreadable: " ^ detail)
;;

(* The drops the newest journal line names, which must be a committed
   Librarian pass that states its drops. *)
let journaled_drop_ids ~keepers_dir ~keeper_id =
  match readable_journal_tail ~keepers_dir ~keeper_id ~limit:1 with
  | [ Ok
        (Current.Journal_committed
           { source = { kind = Current.Librarian; _ }; dropped = Some statements; _ })
    ] ->
    List.map (fun (statement : Memory.dropped_statement) -> statement.memory_id) statements
  | [ Ok (Current.Journal_committed _) ] ->
    fail "the newest journal line is not a Librarian pass that states its drops"
  | [ Ok (Current.Journal_failed _ | Current.Journal_quarantined _) ] ->
    fail "the newest journal line is not a committed pass"
  | [ Error detail ] -> fail ("the newest journal line does not decode: " ^ detail)
  | [] | _ :: _ :: _ -> fail "expected exactly one journal line"
;;

let successors_of identity (revisions : Memory.revision list) =
  List.filter_map
    (fun (revision : Memory.revision) ->
       if String.equal revision.superseded identity
       then Some revision.superseded_by
       else None)
    revisions
;;

let revision_pairs (revisions : Memory.revision list) =
  List.map
    (fun (revision : Memory.revision) -> revision.superseded ^ "->" ^ revision.superseded_by)
    revisions
;;

let ids facts = List.map Memory.memory_id facts

let the_one_new_claim (selection : Librarian.selection) =
  match selection.new_claims with
  | [ claim ] -> Memory.memory_id claim
  | claims -> failf "expected one new claim, parsed %d" (List.length claims)
;;

let superseding_b = selection_json ~new_claims:[ superseding_claim (`String "m2") () ] ()

(* Control: nothing touches B during the pass, so the answer's successor of B
   is stored and B gets that one journal revision link. *)
let test_a_supersede_of_a_memory_still_current_is_stored () =
  let selection, disposition, revisions, _ =
    librarian_round ~name:"supersede-kept" ~answer:superseding_b
      ~inspect:(fun ~keepers_dir ~keeper_id ->
        check (list string) "the journal names B, which the commit dropped"
          [ current_b_id ] (journaled_drop_ids ~keepers_dir ~keeper_id))
      ()
  in
  let successor = the_one_new_claim selection in
  check (list string) "A stays and B's successor is stored"
    [ current_a_id; successor ] (ids disposition.snapshot.facts);
  check (list string) "every claim stored" [] (ids disposition.claims_not_applied);
  check (list string) "the revision is carried out"
    [ current_b_id ^ "->" ^ successor ] (revision_pairs disposition.revisions_applied);
  check (list string) "B has one successor" [ successor ] (successors_of current_b_id revisions)
;;

(* #37433: a cancellation delivered to the commit callback, after the snapshot
   is replaced, used to skip the sidecar append that came after the commit and
   lose the revision. The revision is the commit's own journal row now: the
   prepared publication carries it, and the lineage read recovers it. *)
let test_a_revision_survives_a_cancellation_after_the_commit () =
  let keepers_dir = Filename.temp_dir "librarian-revision-cancel-" "" in
  Fun.protect ~finally:(fun () -> rm_rf keepers_dir) (fun () ->
    let keeper_id = "revision-cancel" in
    let require = function Ok value -> value | Error detail -> fail detail in
    ignore
      (Current.replace ~keepers_dir ~keeper_id ~expected_revision:None ~now:100.
         ~source:{ kind = Current.Explicit_write; trace_id = "trace-seed" }
         ~facts:[ current_a; current_b ] ()
       |> require
       : Current.t);
    let successor = fact ~claim:"B, as the librarian restated it" in
    let successor_id = Memory.memory_id successor in
    (match
       Current.apply_disposition ~pass:Masc.Keeper_memory_commit_pass.Durable
         ~on_committed:(fun _ ->
           raise (Eio.Cancel.Cancelled (Failure "cancelled after the commit")))
         ~dropped_statements:[ { Memory.memory_id = current_b_id; reason = "restated" } ]
         ~keepers_dir ~keeper_id ~now:200.
         ~source:{ kind = Current.Librarian; trace_id = "trace-selection" }
         ~absorbed:[]
         ~revisions:[ { Memory.superseded = current_b_id; superseded_by = successor_id } ]
         ~new_claims:[ successor ] ()
     with
     | Ok _ | Error _ -> fail "the commit callback's cancellation was swallowed"
     | exception Eio.Cancel.Cancelled _ -> ());
    let lineage = Current.read_commit_lineage ~keepers_dir ~keeper_id |> require in
    check (list string) "the journal holds the revision the cut-off commit applied"
      [ current_b_id ^ "->" ^ successor_id ] (revision_pairs lineage.Current.revisions);
    match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require with
    | Some snapshot ->
      check (list string) "the snapshot holds the successor, not B"
        [ current_a_id; successor_id ] (ids snapshot.facts)
    | None -> fail "the committed snapshot is missing")
;;

(* The keeper supersedes B with a successor of its own while the pass runs,
   and the answer supersedes B too. The keeper's successor stands: the answer's
   is not stored and B keeps the one revision link the keeper's commit wrote. *)
let test_a_supersede_of_a_memory_the_keeper_superseded_during_the_pass_is_not_stored () =
  let keeper_successor = fact ~claim:"B, as the keeper corrected it" in
  let keeper_successor_id = Memory.memory_id keeper_successor in
  let selection, disposition, revisions, _ =
    librarian_round ~name:"supersede-superseded" ~answer:superseding_b
      ~keeper_supersede:(current_b_id, keeper_successor)
      ~inspect:(fun ~keepers_dir ~keeper_id ->
        check (list string) "the journal leaves B to the keeper's own revision" []
          (journaled_drop_ids ~keepers_dir ~keeper_id))
      ()
  in
  let successor = the_one_new_claim selection in
  check (list string) "the answer did supersede B"
    [ current_b_id ^ "->" ^ successor ] (revision_pairs selection.revisions);
  check (list string) "only the keeper's successor is current"
    [ current_a_id; keeper_successor_id ] (ids disposition.snapshot.facts);
  check (list string) "the answer's successor is reported as not stored"
    [ successor ] (ids disposition.claims_not_applied);
  check (list string) "no revision carried out" [] (revision_pairs disposition.revisions_applied);
  check (list string) "B has one successor, the keeper's"
    [ keeper_successor_id ] (successors_of current_b_id revisions)
;;

(* The keeper retracts B while the pass runs, and the answer supersedes B. The
   retraction stands: the successor is not stored and B gets no revision link. *)
let test_a_supersede_of_a_memory_the_keeper_retracted_during_the_pass_is_not_stored () =
  let selection, disposition, revisions, _ =
    librarian_round ~name:"supersede-retracted" ~answer:superseding_b
      ~keeper_facts:[ current_a ]
      ~inspect:(fun ~keepers_dir ~keeper_id ->
        check (list string) "the journal leaves B to the keeper's retraction" []
          (journaled_drop_ids ~keepers_dir ~keeper_id))
      ()
  in
  let successor = the_one_new_claim selection in
  check (list string) "only A is current" [ current_a_id ] (ids disposition.snapshot.facts);
  check (list string) "the successor is reported as not stored"
    [ successor ] (ids disposition.claims_not_applied);
  check (list string) "no revision carried out" [] (revision_pairs disposition.revisions_applied);
  check (list string) "B has no successor" [] (successors_of current_b_id revisions)
;;

(* The keeper retracts B while the pass runs, and the answer merges A and B
   into C. C would carry B's retracted content, so it is not stored; with no
   target, A's absorption into C is not applied either and A stays. *)
let test_a_claim_absorbing_a_memory_the_keeper_retracted_during_the_pass_is_not_stored () =
  let selection, disposition, _, absorbed_rows =
    librarian_round ~name:"absorb-retracted"
      ~answer:
        (selection_json ~dropped:[]
           ~new_claims:[ absorbing_claim (`List [ `String "m1"; `String "m2" ]) () ]
           ())
      ~keeper_facts:[ current_a ]
      ()
  in
  let merged = the_one_new_claim selection in
  check (list string) "A stays and C is not stored" [ current_a_id ] (ids disposition.snapshot.facts);
  check (list string) "C is reported as not stored" [ merged ] (ids disposition.claims_not_applied);
  check int "no absorption applied" 0 (List.length disposition.absorbed_applied);
  check int "both absorptions reported as not applied" 2
    (List.length disposition.absorbed_not_applied);
  check int "no absorbed row" 0 absorbed_rows
;;

(* The answer's C supersedes A and absorbs B, and the keeper retracts B during
   the pass. C is not stored, so A, which left only for C, stays current. *)
let test_a_memory_whose_only_successor_is_not_stored_stays_current () =
  let selection, disposition, revisions, _ =
    librarian_round ~name:"successor-refused"
      ~answer:
        (selection_json ~dropped:[ dropped_json "m1" ]
           ~new_claims:
             [ `Assoc
                 [ Librarian.wire_field_claim, `String "A, restated with B"
                 ; Librarian.wire_field_category, `String "fact"
                 ; Librarian.wire_field_supersedes, `String "m1"
                 ; Librarian.wire_field_absorbs, `List [ `String "m2" ]
                 ]
             ]
           ())
      ~keeper_facts:[ current_a ]
      ~inspect:(fun ~keepers_dir ~keeper_id ->
        check (list string) "the journal does not say A was dropped" []
          (journaled_drop_ids ~keepers_dir ~keeper_id))
      ()
  in
  let successor = the_one_new_claim selection in
  check (list string) "the answer did supersede A"
    [ current_a_id ^ "->" ^ successor ] (revision_pairs selection.revisions);
  check (list string) "A stays current" [ current_a_id ] (ids disposition.snapshot.facts);
  check (list string) "C is reported as not stored" [ successor ] (ids disposition.claims_not_applied);
  check (list string) "A has no successor" [] (successors_of current_a_id revisions)
;;

(* The answer restates A word for word and says it supersedes B, and the
   keeper retracts A during the pass. A is not brought back, so B has no
   successor in the next snapshot and stays current with no revision link. *)
let test_a_memory_superseded_by_a_restatement_the_keeper_retracted_stays_current () =
  let selection, disposition, revisions, _ =
    librarian_round ~name:"restated-successor-retracted"
      ~answer:(selection_json ~new_claims:[ superseding_claim ~claim:"keep A" (`String "m2") () ] ())
      ~keeper_facts:[ current_b ]
      ~inspect:(fun ~keepers_dir ~keeper_id ->
        check (list string) "the journal does not say B was dropped" []
          (journaled_drop_ids ~keepers_dir ~keeper_id))
      ()
  in
  check (list string) "the answer did supersede B with A"
    [ current_b_id ^ "->" ^ current_a_id ] (revision_pairs selection.revisions);
  check (list string) "B stays current and A stays retracted"
    [ current_b_id ] (ids disposition.snapshot.facts);
  check (list string) "no revision carried out" [] (revision_pairs disposition.revisions_applied);
  check (list string) "B has no successor" [] (successors_of current_b_id revisions)
;;

let user_text_of_messages messages =
  messages
  |> List.filter_map (fun (m : Llm_provider.Types.message) ->
    if m.role = Agent_core.Types.User
    then
      Some
        (m.content
         |> List.filter_map (function
           | Llm_provider.Types.Text s -> Some s
           | Llm_provider.Types.ToolResult _ | Llm_provider.Types.ToolReference _ | Llm_provider.Types.ToolUse _
           | Llm_provider.Types.Thinking _ | Llm_provider.Types.ReasoningDetails _
           | Llm_provider.Types.RedactedThinking _ | Llm_provider.Types.Image _
           | Llm_provider.Types.Document _ | Llm_provider.Types.Audio _ -> None)
         |> String.concat "\n")
    else None)
  |> String.concat "\n"
;;

let test_keeper_memory_io_offload_fallback_and_domain_safety env () =
  Eio.Switch.run (fun sw ->
    let previous = Domain_pool_ref.get () in
    Eio.Switch.on_release sw (fun () ->
      match previous with
      | None -> Domain_pool_ref.clear_for_tests ()
      | Some pool -> Domain_pool_ref.set pool);
    let base_dir = Filename.temp_dir "librarian-io-offload" "" in
    let keepers_dir = Filename.concat base_dir "keepers" in
    let keeper_id = "io-offload-keeper" in
    Unix.mkdir keepers_dir 0o755;
    Fun.protect
      ~finally:(fun () -> rm_rf base_dir)
      (fun () ->
        (* 1. Absent pool runs inline on caller domain *)
        Domain_pool_ref.clear_for_tests ();
        let caller_dom = (Domain.self () :> int) in
        let inline_dom =
          Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () -> (Domain.self () :> int))
        in
        check int "inline fallback on caller domain" caller_dom inline_dom;

        (* Write a chat message so counterpart observations can read it *)
        Keeper_chat_store.append_user_message
          ~base_dir
          ~keeper_name:keeper_id
          ~content:"Offload verification message"
          ~speaker:
            { Keeper_chat_store.speaker_id = Some "offload-speaker"
            ; speaker_name = Some "Offload test actor"
            ; speaker_authority = Keeper_chat_store.External
            }
          ~conversation_id:"test-convo-1"
          ~external_message_id:"ext-msg-1"
          ();

        (* Legacy unattributed rows must stay excluded on both execution paths. *)
        Keeper_chat_store.append_user_message
          ~base_dir
          ~keeper_name:keeper_id
          ~content:"Unattributed row is not counterpart evidence"
          ();
        let check_speaker label observations =
          check (list (option string)) label [ Some "offload-speaker" ]
            (List.map
               (fun (observation : Masc.Keeper_counterpart_observation.t) ->
                 observation.user_id)
               observations)
        in
        let inline_observations =
          Post_turn_memory.For_testing.counterpart_observations_before_offloaded
            ~base_dir
            ~keeper_name:keeper_id
            ~before:(Time_compat.now () +. 1.)
        in
        check int "inline reads counterpart observations" 1 (List.length inline_observations);
        check_speaker "inline preserves speaker identity" inline_observations;

        (* 2. Install shared domain pool and verify off-main offload *)
        let dm = Eio.Stdenv.domain_mgr env in
        let pool = Domain_pool.create ~sw ~domain_count:1 dm in
        Domain_pool_ref.set pool;

        let offloaded_dom =
          Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () -> (Domain.self () :> int))
        in
        check bool "pool submit runs off main domain" true (offloaded_dom <> caller_dom);

        (* counterpart_observations_before runs through Domain_pool_ref.submit_io_or_inline *)
        let offloaded_observations =
          Post_turn_memory.For_testing.counterpart_observations_before_offloaded
            ~base_dir
            ~keeper_name:keeper_id
            ~before:(Time_compat.now () +. 1.)
        in
        check int "offloaded reads counterpart observations" 1 (List.length offloaded_observations);
        check_speaker "offloaded preserves speaker identity" offloaded_observations;

        (* Populate an initial snapshot to test read_current_facts and record_failure with snapshot present *)
        let fact_initial = fact ~claim:"Offloaded fact 1" in
        let _ =
          Current.apply_disposition ~pass:Masc.Keeper_memory_commit_pass.Durable ~revisions:[]
            ~keepers_dir
            ~keeper_id
            ~now:1_000_000.
            ~source:{ kind = Current.Librarian; trace_id = "trace-init" }
            ~absorbed:[]
            ~new_claims:[ fact_initial ]
            ()
        in

        (* Tool_memory.For_testing.read_current_facts reads and parses the snapshot off-main *)
        let facts_result =
          Tool_memory.For_testing.read_current_facts ~keepers_dir ~keeper_id
        in
        check bool "facts read returns Ok" true (Result.is_ok facts_result);
        let facts = Result.get_ok facts_result in
        check int "one fact read from snapshot" 1 (List.length facts);

        (* Runtime.For_testing.record_failure writes to journal off-main (with snapshot_present = true) *)
        Runtime.For_testing.record_failure
          ~keepers_dir
          ~keeper_id
          ~trace_id:"trace-failure-offload"
          ~kind:Current.Exact_execution_failure
          ~detail:"Testing off-main failure journal write";

        let journal_path =
          Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id
        in
        check bool "journal file written off-main" true (Sys.file_exists journal_path);
        let journal_content = In_channel.with_open_text journal_path In_channel.input_all in
        check bool "journal records failure entry" true
          (String_util.contains_substring journal_content "Testing off-main failure journal write");
        check bool "journal records snapshot_present = true" true
          (String_util.contains_substring journal_content "\"snapshot_present\":true");

        (* Keeper_memory_os_events.append_all writes events off-main *)
        let events_to_append : Events.event list =
          [ { recorded_at = 1_000_000.
            ; memory_id = Memory.memory_id fact_initial
            ; trace_id = "trace-event-offload"
            ; kind = Events.Retrieved { query = "offloaded fact" }
            }
          ]
        in
        let append_errors =
          Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
            Events.append_all ~keepers_dir ~keeper_id events_to_append)
        in
        check (list string) "no append errors" []
          (List.map Events.append_error_to_string append_errors);
        let read_events =
          match Events.read ~keepers_dir ~keeper_id with
          | Ok rows -> rows
          | Error error -> fail (Events.file_read_error_to_string error)
        in
        check int "one event read from sidecar" 1 (List.length read_events);

        Domain_pool_ref.clear_for_tests ()))
;;

let test_current_provenance_survives_store_prompt_and_decisions () =
  let keepers_dir = Filename.temp_dir "librarian-current-provenance-" "" in
  Fun.protect ~finally:(fun () -> rm_rf keepers_dir) (fun () ->
    let keeper_id = "provenance" in
    let require = function Ok value -> value | Error detail -> fail detail in
    let board =
      match Memory.board_ref_of_ids ~post_id:"p-0123456789abcdef0123456789abcdef"
              ~comment_id:(Some "c-0123456789abcdef0123456789abcdef") with
      | Ok board -> board
      | Error error -> fail (Memory.wire_error_to_string error)
    in
    let primary = { (fact ~claim:"primary approval") with first_seen = 10.; last_seen = 20. } in
    let secondary = fact ~claim:"secondary approval" in
    let emergency =
      { (fact ~claim:"emergency approval") with
        first_seen = 100.; last_seen = 200.
      ; origin = { kind = Memory.Authored; trace_id = "trace-explicit" }
      ; basis = Memory.Observed (Memory.Board board) }
    in
    let conclusion =
      Memory.derived ~claim:"deployment has a supported approval"
        ~category:Memory.Validated_approach ~now:300.
        ~origin:{ kind = Memory.Injected; trace_id = "trace-derived" }
        ~derivations:
          [ { rule_id = Memory.memory_id primary; premise_ids = [Memory.memory_id primary] }
          ; { rule_id = "secondary"; premise_ids = [Memory.memory_id secondary] }
          ; { rule_id = "emergency"; premise_ids = [Memory.memory_id emergency] }
          ; { rule_id = "confirmed-emergency"; premise_ids = [Memory.memory_id emergency] } ]
      |> require
    in
    let temporary =
      { (fact ~claim:"temporary queue notice") with
        first_seen = 250.; last_seen = 250.
      ; origin = { kind = Memory.Injected; trace_id = "trace-notice" } }
    in
    let seeded = Current.replace ~keepers_dir ~keeper_id ~expected_revision:None
        ~now:300. ~source:{ kind = Current.Explicit_write; trace_id = "trace-seed" }
        ~facts:[primary; secondary; emergency; conclusion; temporary] () |> require in
    ignore (Current.replace ~keepers_dir ~keeper_id
      ~expected_revision:(Some seeded.revision) ~now:400.
      ~source:{ kind = Current.Explicit_write; trace_id = "trace-retract" }
      ~facts:[emergency; conclusion; temporary] () |> require : Current.t);
    let read () =
      match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require with
      | Some snapshot -> snapshot
      | None -> fail "current snapshot disappeared"
    in
    let stored = read () in
    let inp = { (input ()) with current = Some { Librarian.facts = stored.facts } } in
    let report_input_size scenario facts =
      let measured = { inp with current = Some { Librarian.facts } } in
      let current_memory = List.assoc "current_memory" (Librarian.prompt_variables ~source_lines:[] measured) in
      let rendered = match Runtime.messages_for_librarian ~source_lines:[] measured with
        | Ok messages -> user_text_of_messages messages
        | Error detail -> fail detail
      in
      Printf.printf "%s\n%!"
        (Yojson.Safe.to_string (`Assoc
           [ "scenario", `String scenario; "fact_count", `Int (List.length facts)
           ; "current_memory_bytes", `Int (String.length current_memory)
           ; "rendered_user_bytes", `Int (String.length rendered) ]))
    in
    report_input_size "one_transcript" [fact ~claim:"Service uses port 8080."];
    report_input_size "one_board" [emergency];
    report_input_size "stored_alternative_proofs" stored.facts;
    report_input_size "one_hundred_transcripts"
      (List.init 100 (fun index -> fact ~claim:(Printf.sprintf "Service %d uses port 8080." index)));
    let rows input =
      List.assoc "current_memory" (Librarian.prompt_variables ~source_lines:[] input)
      |> Yojson.Safe.from_string |> Yojson.Safe.Util.member "facts"
      |> Yojson.Safe.Util.to_list
    in
    let row_for claim rows =
      List.find (fun row ->
        Yojson.Safe.Util.(row |> member "fact" |> member "claim" |> to_string) = claim) rows
    in
    let check_projection input expected_premise =
      let rows = rows input in
      let emergency_row = row_for emergency.claim rows in
      let details = Yojson.Safe.Util.member "fact" emergency_row in
      check bool "origin kind reaches prompt without the opaque trace id" true
        (Yojson.Safe.Util.member "origin" details = `Assoc ["kind", `String "authored"]);
      let fields = Yojson.Safe.Util.to_assoc details in
      check bool "both write times reach the prompt" true
        (List.mem_assoc "first_seen" fields && List.mem_assoc "last_seen" fields);
      check bool "Board source ids remain available for new claim provenance" true
        (Yojson.Safe.Util.member "basis" details = Memory.basis_to_json emergency.basis);
      let source = Yojson.Safe.Util.(details |> member "basis" |> member "board") in
      let post_id = Yojson.Safe.Util.(source |> member "post_id" |> to_string) in
      let comment_id = Yojson.Safe.Util.(source |> member "comment_id" |> to_string) in
      let answer = selection_json ~dropped:[]
          ~new_claims:[board_claim ~post_id ~comment_id "approval source supports this new claim"] () in
      (match Librarian.selection_of_json_result ~now:450. input answer with
       | Ok { new_claims = [claim]; _ } ->
         check bool "projected Board ids pass the existing new-claim contract" true
           (claim.basis = emergency.basis)
       | Ok _ -> fail "expected exactly one new Board claim"
       | Error error -> fail (Librarian.parse_error_to_string error));
      let derived = row_for conclusion.claim rows |> Yojson.Safe.Util.member "fact" in
      check bool "Librarian origin is preserved too" true
        (Yojson.Safe.Util.member "origin" derived
         = `Assoc ["kind", `String "injected"]);
      let basis = Yojson.Safe.Util.member "basis" derived in
      check string "derived basis remains typed" "derived"
        Yojson.Safe.Util.(basis |> member "kind" |> to_string);
      let proofs = Yojson.Safe.Util.(basis |> member "derivations" |> to_list) in
      check int "only identical premise paths are combined" 3 (List.length proofs);
      check int "distinct missing premise paths remain separate arrays" 2
        (List.length (List.filter ((=) (`List [`Null])) proofs));
      check int "different rules with the same current premise share one array" 1
        (List.length (List.filter ((=) (`List [`String expected_premise])) proofs));
      let current_memory = List.assoc "current_memory" (Librarian.prompt_variables ~source_lines:[] input) in
      (match Runtime.messages_for_librarian ~source_lines:[] input with
       | Error detail -> fail detail
       | Ok messages ->
         let rendered = user_text_of_messages messages in
         check bool "actual model-input renderer carries the same metadata JSON" true
           (String_util.contains_substring rendered current_memory);
         List.iter (fun fact ->
           check bool "memory identities remain absent from model input" false
             (String_util.contains_substring rendered (Memory.memory_id fact)))
           [primary; secondary; emergency; conclusion; temporary]);
      let temporary_row = row_for temporary.claim rows in
      check bool "transcript basis remains explicit" true
        (Yojson.Safe.Util.(temporary_row |> member "fact" |> member "basis")
         = `Assoc ["kind", `String "observed"]);
      Yojson.Safe.Util.(temporary_row |> member "memory_id" |> to_string)
    in
    let _ = check_projection inp "m1" in
    let reordered = { inp with current = Some { Librarian.facts = List.rev stored.facts } } in
    let dropped_token = check_projection reordered "m3" in
    check string "reordered fact has its new surrogate" "m1" dropped_token;
    let commit input answer now =
      let selection =
        match Librarian.selection_of_json_result ~now input answer with
        | Ok selection -> selection
        | Error error -> fail (Librarian.parse_error_to_string error)
      in
      Current.apply_disposition ~pass:Masc.Keeper_memory_commit_pass.Durable ~revisions:[] ~keepers_dir ~keeper_id ~now
        ~source:{ kind = Current.Librarian; trace_id = "trace-selection" }
        ~dropped_statements:selection.dropped ~absorbed:selection.absorbed
        ~new_claims:selection.new_claims () |> require
      |> fun (d : Current.disposition) -> d.snapshot
    in
    let committed = commit reordered
        (selection_json ~dropped:[dropped_json ~reason:"temporary notice is no longer useful" dropped_token] ())
        500. in
    check (list string) "the selected short id retires only its current fact"
      [emergency.claim; conclusion.claim] (List.map (fun (fact : Memory.fact) -> fact.claim) committed.facts);
    let expected = List.map Memory.fact_to_json [emergency; conclusion] in
    check bool "input projection does not alter retained store provenance" true
      (List.map Memory.fact_to_json committed.facts = expected);
    List.iter (fun now ->
      let current = read () in
      let next_input = { inp with current = Some { Librarian.facts = current.facts } } in
      let next = commit next_input (selection_json ~dropped:[] ()) now in
      check bool "later unchanged decisions preserve all stored provenance" true
        (List.map Memory.fact_to_json next.facts = expected)) [600.; 700.])
;;

let () =
  Eio_main.run @@ fun env ->
  run
    "keeper_librarian_current_selection_apply_disposition"
    [ ( "selection"
      , [ test_case "a restated memory still current takes its absorptions" `Quick
            test_a_restated_memory_still_current_takes_its_absorptions
        ; test_case "a restated memory retracted during the pass stays retracted and keeps its sources" `Quick
            test_a_restated_memory_retracted_during_the_pass_stays_retracted_and_keeps_its_sources
        ; test_case "a supersede of a memory still current is stored" `Quick
            test_a_supersede_of_a_memory_still_current_is_stored
        ; test_case "a revision survives a cancellation after the commit" `Quick
            test_a_revision_survives_a_cancellation_after_the_commit
        ; test_case "a supersede of a memory the keeper superseded during the pass is not stored" `Quick
            test_a_supersede_of_a_memory_the_keeper_superseded_during_the_pass_is_not_stored
        ; test_case "a supersede of a memory the keeper retracted during the pass is not stored" `Quick
            test_a_supersede_of_a_memory_the_keeper_retracted_during_the_pass_is_not_stored
        ; test_case "a claim absorbing a memory the keeper retracted during the pass is not stored" `Quick
            test_a_claim_absorbing_a_memory_the_keeper_retracted_during_the_pass_is_not_stored
        ; test_case "a memory whose only successor is not stored stays current" `Quick
            test_a_memory_whose_only_successor_is_not_stored_stays_current
        ; test_case "a memory superseded by a restatement the keeper retracted stays current" `Quick
            test_a_memory_superseded_by_a_restatement_the_keeper_retracted_stays_current
        ; test_case "current provenance survives store prompt and decisions" `Quick
            test_current_provenance_survives_store_prompt_and_decisions
        ] )
    ; ( "domain_offload"
      , [ test_case
            "memory io offload fallback and domain safety"
            `Quick
            (test_keeper_memory_io_offload_fallback_and_domain_safety env)
        ] )
    ]
;;
