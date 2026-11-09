open Alcotest
open Masc
module Context = Keeper_librarian_context

let source reference text : Context.source = {reference; content = `String text}
let events = List.init 20 (fun i -> source (Printf.sprintf "event:campaign:%d" i) "continue campaign")
let question = source "chat:question:revision1" "Where are we now?"
let pocket sources context next_steps : Context.pocket = {id = "test:" ^ String.concat ":" sources; merge_contexts = []; sources; context; next_steps; completeness = Context.Current}
let input sources previous : Context.input = {sources; previous; unavailable = []; execution_basis = Some "test-progress"}
let ok = function Ok value -> value | Error detail -> fail detail
let expect_error = function Error _ -> () | Ok _ -> fail "expected rejection"
let with_store f =
  Masc_test_deps.ensure_rng_initialized ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let dir = Filename.temp_dir "librarian-context" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree dir);
  f dir

(* A fake model groups repeated notifications while retaining the direct
   question's separate unresolved answer obligation in the same context. *)
let fake_model sources =
  Context.pockets_to_json
    [pocket (List.mapi (fun i _ -> Printf.sprintf "s%d" (i + 1)) sources)
       "Campaign is in progress; the user is asking for current progress."
       ["Answer the user's progress question"; "Continue the campaign once"]]

let rendered_json inp =
  let rendered = Option.get (ok (Context.render inp)) in
  let start = String.index rendered '[' in
  Yojson.Safe.from_string (String.sub rendered start (String.length rendered - start))

let test_repeated_events_and_chat () =
  let sources = events @ [question] in
  let pockets = ok (Context.select (input sources None) (fake_model sources)) in
  check int "one context for twenty notifications and one question" 1 (List.length pockets);
  check int "all source identities survive" 21 (List.length (List.hd pockets).sources);
  check int "question and continuation preserved" 2 (List.length (List.hd pockets).next_steps);
  let previous : Context.snapshot = {generation = "test-generation"; revision = 1; execution_basis = Some "test-progress"; sources; pockets} in
  let open Yojson.Safe.Util in
  let visible = rendered_json (input events (Some previous)) |> to_list |> List.hd in
  check bool "mixed context remains visible but requires revalidation" true
    (visible |> member "requires_source_revalidation" |> to_bool);
  check bool "unobserved chat cannot become executable advice" true
    (visible |> member "next_steps" = `Null);
  let current = rendered_json (input sources (Some previous)) |> to_list |> List.hd in
  check int "fresh sources expose suggestions" 2 (current |> member "next_steps" |> to_list |> List.length);
  let changed = source "chat:question:revision2" "Stop the campaign" in
  let changed_render = rendered_json (input (events @ [changed]) (Some previous)) |> to_list |> List.hd in
  check bool "changed source invalidates old suggestions" true
    (changed_render |> member "next_steps" = `Null);
  check int "raw arrivals are unchanged by render" 21 (List.length sources)

let test_partial_observation_and_cas () = with_store @@ fun keepers_dir ->
  let keeper_id = "test" in
  let initial_sources = [List.hd events; question] in
  let initial_pockets = List.map (fun (s : Context.source) ->
    pocket [s.reference] "An unresolved context" ["Review original source"]) initial_sources in
  let first = ok (Context.commit ~keepers_dir ~keeper_id ~expected_version:None
    ~sources:initial_sources initial_pockets) in
  let replacement = [pocket [question.reference] "Question awaits answer" ["Answer"]] in
  let second = ok (Context.commit ~keepers_dir ~keeper_id ~expected_version:(Some (Context.version first))
    ~sources:[question] replacement) in
  check int "unknown event observation preserves old pocket" 2 (List.length second.pockets);
  expect_error (Context.commit ~keepers_dir ~keeper_id ~expected_version:(Some (Context.version first))
    ~sources:[] []);
  let after_rejected = ok (Context.read ~keepers_dir ~keeper_id) |> Option.get in
  check int "stale CAS leaves latest snapshot intact" second.revision after_rejected.revision;
  let third = ok (Context.commit ~observed_sources:[question] ~keepers_dir ~keeper_id
    ~expected_version:(Some (Context.version second)) ~sources:[] []) in
  check int "authoritative settled event observation prunes derived history" 1 (List.length third.pockets);
  let unknown : Context.input = {sources = []; previous = Some third; unavailable = ["store unavailable"]; execution_basis = None} in
  check bool "unknown observation still exposes historical context" true (Option.is_some (ok (Context.render unknown)));
  let fourth = ok (Context.commit ~keepers_dir ~keeper_id ~expected_version:(Some (Context.version third))
    ~sources:unknown.sources []) in
  check int "unknown empty observation does not erase pockets" 1 (List.length fourth.pockets)

let test_partial_group_keeps_coverage () = with_store @@ fun keepers_dir ->
  let keeper_id = "partial-group" in
  let a = source "a" "first campaign event" in
  let b = source "b" "second campaign event" in
  let c = source "c" "new user question" in
  let original = ok (Context.commit ~keepers_dir ~keeper_id ~expected_version:None
    ~sources:[a; b] [pocket [a.reference; b.reference] "Campaign" ["Continue"]]) in
  let apply previous sources =
    let snapshot = ok (Context.commit ~observed_sources:[a; b; c] ~keepers_dir ~keeper_id
      ~expected_version:(Some (Context.version previous)) ~sources
      [pocket (List.map (fun (s : Context.source) -> s.reference) sources)
        "Reorganized context" ["Revalidate then act"]]) in
    check (list string) "partial batches never discard covered sources" ["a"; "b"; "c"]
      (List.map (fun (s : Context.source) -> s.reference) snapshot.sources |> List.sort String.compare);
    let remainders = List.filter (fun (p : Context.pocket) ->
      p.completeness = Context.Needs_reconsideration) snapshot.pockets in
    check int "one host-derived remainder retained" 1 (List.length remainders);
    List.iter (fun (p : Context.pocket) ->
      check int "remainder has no actionable advice" 0 (List.length p.next_steps)) remainders;
    let persisted = ok (Context.read ~keepers_dir ~keeper_id) |> Option.get in
    check bool "typed completeness survives persistence" true (snapshot = persisted);
    snapshot in
  let second = apply original [c; a] in
  let third = apply second [b; c] in
  let fourth = apply third [a; b] in
  ignore (apply fourth [c; a]);
  let open Yojson.Safe.Util in
  let rendered = rendered_json (input [a; b; c] (Some fourth)) |> to_list in
  let historical = List.find (fun json -> member "completeness" json = `String "needs_reconsideration") rendered in
  check bool "current refs cannot activate partial-context advice" true
    (member "next_steps" historical = `Null)

let test_duplicate_and_missing_source_rejected () =
  expect_error (Context.pockets_of_json ~sources:[question; question]
    (Context.pockets_to_json [pocket [question.reference; question.reference] "duplicate" []]));
  expect_error (Context.select (input (events @ [question]) None)
    (fake_model events));
  expect_error (Context.select (input [question] None)
    (Context.pockets_to_json [pocket ["s1"; "s1"] "duplicate alias" []]))

let test_queue_wakes_coalesce_without_waiting_for_librarian () =
  Masc_test_deps.ensure_rng_initialized ();
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keepers_dir = Filename.temp_dir "librarian-flood" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree keepers_dir);
  Eio_context.with_test_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock @@ fun () ->
  Keeper_memory_lane.init ~sw;
  let started, start = Eio.Promise.create () in
  let release, release_first = Eio.Promise.create () in
  let finished, finish = Eio.Promise.create () in
  let original = ref [List.hd events] in
  let calls = ref 0 in
  let organize () =
    incr calls;
    let sources = !original in
    if !calls = 1 then (Eio.Promise.resolve start (); Eio.Promise.await release);
    let previous = ok (Context.read ~keepers_dir ~keeper_id:"flood") in
    let selected = ok (Context.select (input sources previous) (fake_model sources)) in
    ignore (ok (Context.commit ~keepers_dir ~keeper_id:"flood"
      ~expected_version:(Option.map Context.version previous)
      ~sources selected));
    if !calls = 2 then Eio.Promise.resolve finish ()
  in
  Keeper_librarian_queue_signal.install (fun ~base_path ~keeper_name ->
    ignore (Keeper_memory_lane.submit ~base_path ~keeper_name organize));
  Eio.Switch.on_release sw (fun () -> Keeper_librarian_queue_signal.install
    (fun ~base_path:_ ~keeper_name:_ -> ()));
  let signal () = Keeper_librarian_queue_signal.changed ~base_path:keepers_dir ~keeper_name:"flood" in
  signal ();
  Eio.Promise.await started;
  List.iter (fun event -> original := !original @ [event]; signal ()) (List.tl events @ [question]);
  check int "all input accepted while first model is blocked" 21 (List.length !original);
  Eio.Promise.resolve release_first ();
  Eio.Time.with_timeout_exn env#clock 2.0 (fun () -> Eio.Promise.await finished);
  check int "one active plus one latest pass" 2 !calls;
  let snapshot = ok (Context.read ~keepers_dir ~keeper_id:"flood") |> Option.get in
  check int "latest pass sees entire accumulated input" 21 (List.length snapshot.sources);
  check int "repeated notifications become one context" 1 (List.length snapshot.pockets)

let test_pending_snapshot_includes_running_question_without_claiming () = with_store @@ fun directory ->
  let module Store = Keeper_chat_operation_store in
  let module Operation = Keeper_chat_operation in
  let store_ok = function Ok value -> value | Error error -> fail (Store.error_to_string error) in
  let path = Filename.concat directory "operations.sqlite3" in
  let store = Store.open_or_create ~path |> store_ok in
  Fun.protect ~finally:(fun () -> ignore (Store.close store)) (fun () ->
    let id name = Operation.Operation_id.of_string name |> ok in
    let submit name = Store.submit store ~now:1.0 ~operation_id:(id name)
      ~source:(`Assoc ["kind", `String "dashboard"])
      ~input:(`Assoc ["message", `String name]) |> store_ok |> ignore in
    submit "completed";
    ignore (Store.claim_next store ~now:2.0 |> store_ok);
    Store.succeed_running store ~now:3.0 ~operation_id:(id "completed") ~outcome_ref:"answer" |> store_ok |> ignore;
    submit "running-question";
    ignore (Store.claim_next store ~now:4.0 |> store_ok);
    submit "queued-question";
    let snapshot = Store.inspect_pending_inputs ~path |> store_ok |> Option.get in
    check (list string) "read-only snapshot excludes terminal history but retains active questions"
      ["running-question"; "queued-question"]
      (List.map (fun (op : Operation.t) -> Operation.Operation_id.to_string op.operation_id) snapshot);
    let inventory = Store.inventory store |> store_ok in
    check int "observation does not claim queued input" 1 inventory.queued_count;
    check (option string) "observation does not change running identity" (Some "running-question")
      (Option.map Operation.Operation_id.to_string inventory.running_operation_id))

let test_incremental_campaign_merges_existing_context () = with_store @@ fun keepers_dir ->
  let keeper_id = "incremental-campaign" in
  let selected = ok (Context.select (input events None) (fake_model events)) in
  let first = ok (Context.commit ~keepers_dir ~keeper_id ~expected_version:None
      ~sources:events selected) in
  let identity = (List.hd first.pockets).id in
  let append previous i =
    let arrival = source (Printf.sprintf "event:campaign:%d" i) "continue campaign" in
    let inp = input [arrival] (Some previous) in
    let open Yojson.Safe.Util in
    let catalogue = Context.prompt_json inp |> member "previous" |> to_list in
    check int "disjoint new source still sees prior context" 1 (List.length catalogue);
    check string "prior context can be addressed without replaying old sources" "c1"
      (List.hd catalogue |> member "context_id" |> to_string);
    let proposal = {(pocket ["s1"] "Campaign continues; retain unresolved progress question" ["Continue once"])
      with merge_contexts = ["c1"]} in
    let selected = ok (Context.select inp (Context.pockets_to_json [proposal])) in
    let observed_sources = previous.Context.sources @ [arrival] in
    let next = ok (Context.commit ~observed_sources ~keepers_dir ~keeper_id
        ~expected_version:(Some (Context.version previous)) ~sources:[arrival] selected) in
    check int "recurring arrivals do not create a pocket queue" 1 (List.length next.pockets);
    check string "same context identity retained" identity (List.hd next.pockets).id;
    check (list string) "every original arrival retained exactly once"
      (List.map (fun (s : Context.source) -> s.reference) observed_sources |> List.sort String.compare)
      ((List.hd next.pockets).sources |> List.sort String.compare);
    next in
  (* Compare as sets because newly selected references precede inherited ones. *)
  let second = append first 20 in
  let third = append second 21 in
  check int "two incremental passes retain all twenty-two arrivals" 22 (List.length third.sources)

let test_source_reassignment_does_not_collide_with_merged_identity () = with_store @@ fun keepers_dir ->
  let keeper_id = "split-source" in
  let a = source "event:a" "original question" in
  let b = source "event:b" "continuation" in
  let first = ok (Context.commit ~keepers_dir ~keeper_id ~expected_version:None
    ~sources:[a] [pocket [a.reference] "Original context" []]) in
  let old_id = (List.hd first.pockets).id in
  let continuation = {(pocket ["s2"] "Continuing context" []) with merge_contexts = ["c1"]} in
  let proposal = Context.pockets_to_json
    [continuation; pocket ["s1"] "Reassigned question" ["Answer separately"]] in
  let selected = ok (Context.select (input [a; b] (Some first)) proposal) in
  check int "both valid source groups survive selection" 2 (List.length selected);
  check string "explicit continuation retains its identity" old_id (List.hd selected).id;
  check bool "reassigned source has a different identity" true
    ((List.nth selected 1).id <> old_id);
  let next = ok (Context.commit ~keepers_dir ~keeper_id
    ~expected_version:(Some (Context.version first)) ~observed_sources:[a; b]
    ~sources:[a; b] selected) in
  check (list string) "selection and publication agree on identities"
    (List.map (fun (p : Context.pocket) -> p.id) selected)
    (List.map (fun (p : Context.pocket) -> p.id) next.pockets);
  check bool "published split can be read back without quarantine" true
    (ok (Context.read ~keepers_dir ~keeper_id) = Some next)

let test_split_source_does_not_collide_with_untouched_context () = with_store @@ fun keepers_dir ->
  let keeper_id = "split-untouched" in
  let a = source "event:a" "original question" in
  let b = source "event:b" "continuation" in
  let first = ok (Context.commit ~keepers_dir ~keeper_id ~expected_version:None
    ~sources:[a] [pocket [a.reference] "Original context" []]) in
  let selected = ok (Context.select (input [b] (Some first))
    (Context.pockets_to_json
      [{(pocket ["s1"] "Both questions" []) with merge_contexts = ["c1"]}])) in
  let grown = ok (Context.commit ~keepers_dir ~keeper_id
    ~expected_version:(Some (Context.version first)) ~observed_sources:[a; b]
    ~sources:[b] selected) in
  let split = ok (Context.select (input [a] (Some grown))
    (Context.pockets_to_json [pocket ["s1"] "Separate question" []])) in
  let next = ok (Context.commit ~keepers_dir ~keeper_id
    ~expected_version:(Some (Context.version grown)) ~observed_sources:[a; b]
    ~sources:[a] split) in
  check int "new group and untouched remainder both survive" 2 (List.length next.pockets);
  check bool "untouched group preserves its identity with remaining source" true
    (List.exists (fun (p : Context.pocket) ->
      p.id = (List.hd first.pockets).id && p.sources = [b.reference]) next.pockets);
  check bool "split snapshot remains readable" true
    (ok (Context.read ~keepers_dir ~keeper_id) = Some next);
  expect_error (Context.commit ~keepers_dir ~keeper_id
    ~expected_version:(Some (Context.version grown)) ~sources:[a] split)

let test_unrelated_prior_contexts_need_no_empty_source_output () = with_store @@ fun keepers_dir ->
  let keeper_id = "one-new-two-prior" in
  let a = source "event:a" "first pending task" in
  let b = source "event:b" "second pending task" in
  let previous = ok (Context.commit ~keepers_dir ~keeper_id ~expected_version:None
    ~sources:[a; b]
    [pocket [a.reference] "First task" []; pocket [b.reference] "Second task" []]) in
  let selected = ok (Context.select (input [question] (Some previous))
    (Context.pockets_to_json [pocket ["s1"] "New question" ["Answer"]])) in
  let next = ok (Context.commit ~keepers_dir ~keeper_id
    ~expected_version:(Some (Context.version previous))
    ~observed_sources:[a; b; question] ~sources:[question] selected) in
  check int "the host retains two prior contexts beside the new one" 3 (List.length next.pockets);
  List.iter (fun (prior : Context.pocket) ->
    check bool "omitting an unrelated prior context keeps its identity and content" true
      (List.exists (fun (p : Context.pocket) ->
        p.id = prior.id && p.sources = prior.sources && p.context = prior.context) next.pockets)) previous.pockets;
  check bool "the same complete snapshot survives reading it back" true
    (ok (Context.read ~keepers_dir ~keeper_id) = Some next)

let test_invalid_merge_targets () =
  let a = source "event:a" "campaign" in
  let prior : Context.snapshot = {generation = "test"; revision = 1; execution_basis = None;
    sources = [a]; pockets = [pocket [a.reference] "Campaign" []]} in
  let proposal targets refs = {(pocket refs "Campaign" []) with merge_contexts = targets} in
  expect_error (Context.select (input [question] (Some prior))
      (Context.pockets_to_json [proposal ["c99"] ["s1"]]));
  expect_error (Context.select (input [question] (Some prior))
      (Context.pockets_to_json [proposal ["c1"; "c1"] ["s1"]]));
  let b = source "event:b" "another signal" in
  expect_error (Context.select (input [question; b] (Some prior))
      (Context.pockets_to_json [proposal ["c1"] ["s1"]; proposal ["c1"] ["s2"]]))

let test_execution_progress_invalidates_unchanged_sources () = with_store @@ fun keepers_dir ->
  let previous = ok (Context.commit ~keepers_dir ~keeper_id:"progress"
      ~expected_version:None ~execution_basis:"test-progress" ~sources:[question]
      [pocket [question.reference] "Deployment requested" ["Deploy"]]) in
  let open Yojson.Safe.Util in
  let visible inp = rendered_json inp |> to_list |> List.hd |> member "next_steps" in
  check bool "matching progress exposes suggestion" true
    (visible (input [question] (Some previous)) = `List [`String "Deploy"]);
  let progressed = {(input [question] (Some previous)) with execution_basis = Some "tool-completed"} in
  check bool "completed tool invalidates advice despite unchanged queue identity" true
    (visible progressed = `Null);
  check bool "unavailable progress cannot authorize repeated action" true
    (visible {progressed with execution_basis = None} = `Null)

let test_corrupt_snapshot_rebuild_rejects_old_generation () = with_store @@ fun keepers_dir ->
  let keeper_id = "corrupt" in
  let proposals = [pocket [question.reference] "Question awaits answer" ["Answer"]] in
  let first = ok (Context.commit ~keepers_dir ~keeper_id ~expected_version:None
      ~sources:[question] proposals) in
  let file = Context.path ~keepers_dir ~keeper_id in
  let invalid = "{invalid-derived-context" in
  ok (Fs_compat.save_file_atomic file invalid);
  expect_error (Context.read ~keepers_dir ~keeper_id);
  check bool "background capture quarantines invalid derived bytes" true
    (ok (Context.read_for_update ~keepers_dir ~keeper_id) = None);
  let quarantine = file ^ ".invalid-" ^ Agent_core_sha256.(digest_string invalid |> to_hex) in
  check string "exact corrupt evidence preserved" invalid
    (In_channel.with_open_bin quarantine In_channel.input_all);
  let rebuilt = ok (Context.commit ~keepers_dir ~keeper_id ~expected_version:None
      ~sources:[question] proposals) in
  check int "rebuilt snapshot starts at same numeric revision" first.revision rebuilt.revision;
  check bool "recovery assigns a fresh generation" true (first.generation <> rebuilt.generation);
  expect_error (Context.commit ~keepers_dir ~keeper_id
      ~expected_version:(Some (Context.version first)) ~sources:[question] proposals);
  check bool "late old-generation result cannot overwrite recovered context" true
    (ok (Context.read ~keepers_dir ~keeper_id) = Some rebuilt)

let test_new_basis_cannot_launder_untouched_advice () = with_store @@ fun keepers_dir ->
  let keeper_id = "basis-isolation" in
  let a = source "chat:deployment" "Deploy the application" in
  let b = source "chat:status" "How is the campaign going?" in
  let first = ok (Context.commit ~keepers_dir ~keeper_id ~expected_version:None
      ~execution_basis:"before-deployment" ~sources:[a]
      [pocket [a.reference] "Deployment requested" ["Deploy"]]) in
  let old_id = (List.hd first.pockets).id in
  let second = ok (Context.commit ~keepers_dir ~keeper_id
      ~expected_version:(Some (Context.version first)) ~execution_basis:"after-deployment"
      ~observed_sources:[a; b] ~sources:[b]
      [pocket [b.reference] "Campaign status requested" ["Answer campaign question"]]) in
  let open Yojson.Safe.Util in
  let visible = rendered_json {(input [a; b] (Some second))
      with execution_basis = Some "after-deployment"} |> to_list in
  let old = List.find (fun json -> member "context_id" json = `String old_id) visible in
  check bool "organizing another pocket cannot reactivate stale deployment advice" true
    (member "next_steps" old = `List []);
  let fresh = List.find (fun json -> member "context_id" json <> `String old_id) visible in
  check bool "freshly organized context keeps its validated suggestion" true
    (member "next_steps" fresh = `List [`String "Answer campaign question"]);
  check int "both source obligations remain recorded" 2 (List.length second.sources)

let test_exact_source_retraction_preserves_and_reconsiders () =
  with_store @@ fun keepers_dir ->
  let keeper_id = "source-retraction" in
  let a = source "event:a" "first signal" in
  let b = source "event:b" "second signal" in
  let c = source "chat:c" "settled question" in
  let d = source "event:d" "unaffected signal" in
  let mixed = pocket [a.reference; b.reference] "Mixed situation" ["Act once"] in
  let removed = pocket [c.reference] "Settled question" ["Answer"] in
  let unaffected = pocket [d.reference] "Unrelated situation" ["Continue"] in
  let first =
    ok
      (Context.commit
         ~keepers_dir
         ~keeper_id
         ~expected_version:None
         ~execution_basis:"same-progress"
         ~sources:[a; b; c; d]
         [mixed; removed; unaffected])
  in
  let persisted_mixed =
    List.find
      (fun (value : Context.pocket) ->
         List.mem a.reference value.sources && List.mem b.reference value.sources)
      first.pockets
  in
  let persisted_unaffected =
    List.find
      (fun (value : Context.pocket) -> value.sources = [d.reference])
      first.pockets
  in
  let first_snapshot_sha256 =
    match Context.read_with_snapshot_sha256 ~keepers_dir ~keeper_id with
    | Ok (Some (snapshot, snapshot_sha256)) ->
      check bool "hash observation matches first snapshot" true
        (snapshot = first);
      snapshot_sha256
    | Ok None | Error _ -> fail "first working-context hash is unavailable"
  in
  let second =
    match
      Context.retract_sources
        ~keepers_dir
        ~keeper_id
        ~expected_version:(Context.version first)
        ~expected_snapshot_sha256:first_snapshot_sha256
        ~source_references:[b.reference; c.reference]
    with
    | Ok snapshot -> snapshot
    | Error _ -> fail "exact source retraction was rejected"
  in
  check string "generation is preserved" first.generation second.generation;
  check int "one atomic retraction advances one revision" 2 second.revision;
  check (list string) "only exact source references are removed"
    [a.reference; d.reference]
    (List.map (fun (value : Context.source) -> value.reference) second.sources);
  check int "fully removed pocket disappears" 2 (List.length second.pockets);
  let shrunk =
    List.find
      (fun (value : Context.pocket) -> value.id = persisted_mixed.id)
      second.pockets
  in
  check (list string) "partially affected pocket retains unaffected source"
    [a.reference] shrunk.sources;
  check bool "partially affected pocket requires reconsideration" true
    (shrunk.completeness = Context.Needs_reconsideration);
  check (list string) "stale advice is cleared" [] shrunk.next_steps;
  check bool "unaffected pocket is byte-for-byte preserved" true
    (List.exists
       (fun (value : Context.pocket) -> value = persisted_unaffected)
       second.pockets);
  check bool "persisted snapshot equals the receipt" true
    (ok (Context.read ~keepers_dir ~keeper_id) = Some second);
  let second_snapshot_sha256 =
    match Context.read_with_snapshot_sha256 ~keepers_dir ~keeper_id with
    | Ok (Some (snapshot, snapshot_sha256)) ->
      check bool "hash observation matches second snapshot" true
        (snapshot = second);
      snapshot_sha256
    | Ok None | Error _ -> fail "second working-context hash is unavailable"
  in
  check string "context receipt hash matches exact stored bytes"
    second_snapshot_sha256
    (Context.snapshot_sha256 second);
  (match
     Context.retract_sources
       ~keepers_dir
       ~keeper_id
       ~expected_version:(Context.version first)
       ~expected_snapshot_sha256:first_snapshot_sha256
       ~source_references:[a.reference]
   with
   | Error (Context.Retract_snapshot_conflict _) -> ()
   | Error _ | Ok _ -> fail "stale version did not fail closed");
  (match
     Context.retract_sources
       ~keepers_dir
       ~keeper_id
       ~expected_version:(Context.version second)
       ~expected_snapshot_sha256:(String.make 64 '0')
       ~source_references:[a.reference]
   with
   | Error
       (Context.Retract_snapshot_conflict
          { observed_snapshot_sha256 = Some observed; _ }) ->
     check string "context conflict reports the locked snapshot hash"
       second_snapshot_sha256 observed
   | Error _ | Ok _ -> fail "wrong context hash did not fail closed");
  (match
     Context.retract_sources
       ~keepers_dir
       ~keeper_id
       ~expected_version:(Context.version second)
       ~expected_snapshot_sha256:second_snapshot_sha256
       ~source_references:["event:not-present"]
   with
   | Error (Context.Retract_source_not_found _) -> ()
   | Error _ | Ok _ -> fail "unknown source did not fail closed");
  check bool "failed source plans leave the snapshot intact" true
    (ok (Context.read ~keepers_dir ~keeper_id) = Some second)

(* A capture that could not read the chat store leaves history the pass
   cannot confirm settled, so the stored references stay different from the
   pending ones. The queue pass compares against what it was shown instead,
   so the same capture makes no second model call. *)
let test_unchanged_capture_needs_no_second_queue_pass () = with_store @@ fun keepers_dir ->
  let module Queue = Keeper_librarian_queue_refresh.For_testing in
  let keeper_name = "unchanged-capture" in
  let settled = source "event:settled" "an event the Keeper already handled" in
  let a = source "event:a" "campaign" in
  let first = ok (Context.commit ~keepers_dir ~keeper_id:keeper_name ~expected_version:None
      ~sources:[settled] [pocket [settled.reference] "Handled event" []]) in
  let captured : Context.input =
    {sources = [a]; previous = Some first; unavailable = ["chat store not yet available"];
     execution_basis = None} in
  let needed inp = Queue.context_pass_needed ~keepers_dir ~keeper_name inp in
  check bool "a new pending input needs a pass" true (needed captured);
  let committed = ok (Context.commit ~keepers_dir ~keeper_id:keeper_name
      ~expected_version:(Some (Context.version first)) ~sources:[a]
      [pocket [a.reference] "Campaign" ["Continue"]]) in
  check (list string) "the snapshot keeps history it could not confirm settled"
    ["event:a"; "event:settled"]
    (List.map (fun (s : Context.source) -> s.reference) committed.sources |> List.sort String.compare);
  let recaptured = {captured with previous = Some committed} in
  check bool "stored references alone make the same capture look changed" true (needed recaptured);
  Queue.remember_context_pass ~keepers_dir ~keeper_name captured (Context.version committed);
  check bool "the same capture makes no second model call" false (needed recaptured);
  check bool "a new pending input still needs a pass" true
    (needed {recaptured with sources = [a; question]});
  check bool "a store readable again needs a pass to settle history" true
    (needed {recaptured with unavailable = []});
  let other = ok (Context.commit ~keepers_dir ~keeper_id:keeper_name
      ~expected_version:(Some (Context.version committed)) ~sources:[a]
      [pocket [a.reference] "Campaign" ["Continue"]]) in
  check bool "another writer's version falls back to the stored references" true
    (needed {recaptured with previous = Some other})

let test_capture_rechecks_direct_readers_and_retained_context () = with_store @@ fun base_path ->
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:None : string);
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Fun.protect ~finally:(fun () ->
    Keeper_registry.For_testing.clear ();
    Board_dispatch.reset_for_test ();
    Board.reset_global_for_test ()) @@ fun () ->
  let recipient_lookup = Recipient_lookup.make (fun candidate ->
    Ok (Result.to_option (Board.Agent_id.parse
      (Recipient_lookup.Candidate.to_string candidate)))) in
  ignore (Result.get_ok (Board_dispatch.init_jsonl ~base_path ~recipient_lookup ()));
  let author = "direct-author" and reader = "direct-reader" and outsider = "outsider" in
  let create visibility title content =
    match Board_dispatch.create_post ~author ~title ~content
      ~post_kind:Board.Human_post ~visibility () with
    | Ok post -> post
    | Error error -> fail (Board.Post_publication_failure.to_string error) in
  let direct_body = "@direct-reader DIRECT_BODY_ONLY" in
  let direct = create Board.Direct "DIRECT_TITLE_ONLY" direct_body in
  let direct_id = Board.Post_id.to_string direct.id in
  let comment = match Board_dispatch.add_comment ~post_id:direct_id ~author
      ~content:"DIRECT_COMMENT_ONLY" () with
    | Ok comment -> comment | Error error -> fail (Board.show_board_error error) in
  let public = create Board.Public "PUBLIC_TITLE_ONLY" "PUBLIC_BODY_ONLY" in
  let mixed_public = create Board.Public "MIXED_PUBLIC_TITLE" "MIXED_PUBLIC_BODY" in
  let pending_public = create Board.Public "PENDING_TITLE_ONLY" "PENDING_BODY_ONLY" in
  let board (post : Board.post) kind content : Keeper_event_queue.board_stimulus =
    {kind; author; title = post.title; content; hearth = None;
     updated_at = Some post.created_at; audience = Audience_targets [reader]} in
  let event (post : Board.post) payload : Keeper_event_queue.stimulus =
    {post_id = Board.Post_id.to_string post.id; urgency = Normal;
     arrived_at = post.created_at; payload} in
  let direct_signal = event direct (Board_signal (board direct Post_created direct_body)) in
  let comment_signal = event direct (Board_signal
      (board direct (Comment_added {comment_id = Board.Comment_id.to_string comment.id;
        parent_id = None}) "DIRECT_COMMENT_ONLY")) in
  let attention = event direct (Board_attention {candidate_id = "retained-direct-candidate";
      signal = board direct (Post_updated {content_updated_at = direct.created_at +. 1.})
        "DIRECT_ATTENTION_BODY_ONLY"}) in
  let raw_pending = event pending_public (Board_routing_pending
      (board pending_public Post_created "PENDING_BODY_ONLY")) in
  let public_signal = event public (Board_signal (board public Post_created "PUBLIC_BODY_ONLY")) in
  let mixed_signal = event mixed_public
      (Board_signal (board mixed_public Post_created "MIXED_PUBLIC_BODY")) in
  let stimuli = [direct_signal; comment_signal; attention; raw_pending; public_signal; mixed_signal] in
  let queue = List.fold_left Keeper_event_queue.enqueue Keeper_event_queue.empty stimuli in
  let keepers_dir = Filename.concat base_path "retained-contexts" in
  let config_keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Fs_compat.mkdir_p config_keepers_dir;
  let write_targets keeper_name targets =
    Out_channel.with_open_text (Filename.concat config_keepers_dir (keeper_name ^ ".toml"))
      (fun channel -> Printf.fprintf channel
        "[keeper]\ninstructions = \"Read authorized Board evidence.\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nmention_targets = [%s]\n"
        (String.concat ", " (List.map (Printf.sprintf "%S") targets))) in
  List.iter (fun keeper_name ->
    let meta = Masc_test_deps.meta_of_json_fixture
        (`Assoc ["name", `String keeper_name; "trace_id", `String ("trace-" ^ keeper_name)]) |> ok in
    Keeper_meta_store.replace_snapshot config meta |> ok;
    write_targets keeper_name [];
    ignore (Keeper_registry.For_testing.register ~base_path keeper_name meta);
    check bool "capture identity has a real effective metadata source" true
      (Keeper_meta_store.read_effective_meta config keeper_name |> ok |> Option.is_some);
    Keeper_event_queue_persistence.persist ~base_path ~keeper_name queue;
    let selections = Keeper_registry_event_queue.pending_selections_result ~base_path keeper_name |> ok in
    check int "all six original queue sources are durable" 6 (List.length selections);
    let sources = List.map Context.source_of_event selections in
    let source_for stimulus =
      let selection = List.find (fun (selection : Keeper_event_queue_state.pending_selection) ->
        Keeper_event_queue.stimulus_identity_equal stimulus selection.source) selections in
      Context.source_of_event selection in
    let direct_source = source_for direct_signal and comment_source = source_for comment_signal in
    let attention_source = source_for attention and pending_source = source_for raw_pending in
    let public_source = source_for public_signal and mixed_source = source_for mixed_signal in
    let pockets =
      [pocket [direct_source.reference; mixed_source.reference] "MIXED_CONTEXT_ONLY" ["MIXED_ADVICE_ONLY"];
       pocket [comment_source.reference] "PRIVATE_COMMENT_CONTEXT_ONLY" ["PRIVATE_COMMENT_ADVICE_ONLY"];
       pocket [attention_source.reference] "DIRECT_ATTENTION_CONTEXT_ONLY" [];
       pocket [pending_source.reference] "PENDING_CONTEXT_ONLY" [];
       pocket [public_source.reference] "PUBLIC_CONTEXT_ONLY" ["PUBLIC_ADVICE_ONLY"]] in
    let stored = Context.commit ~keepers_dir ~keeper_id:keeper_name ~expected_version:None
        ~sources pockets |> ok in
    let path = Context.path ~keepers_dir ~keeper_id:keeper_name in
    let before = Fs_compat.load_file path in
    let capture () = Keeper_librarian_context_io.capture ~base_path ~keepers_dir ~keeper_name in
    let captured = capture () in
    let authorized = keeper_name <> outsider in
    let expected_sources = if authorized then 4 else 2 in
    check int "capture rechecks actual stored Direct readership" expected_sources
      (List.length captured.sources);
    let previous = Option.get captured.previous in
    check int "retained raw sources use the same authorization guard" expected_sources
      (List.length previous.sources);
    check int "a mixed private context is withheld in full for an outsider"
      (if authorized then 3 else 1) (List.length previous.pockets);
    let rec strings = function
      | `String value -> [value]
      | `List values -> List.concat_map strings values
      | `Assoc fields -> List.concat_map (fun (_, value) -> strings value) fields
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ -> [] in
    let prompt_strings = strings (Context.prompt_json captured) in
    List.iter (fun value -> check bool "raw pending/discoverable Direct data never enters the prompt"
      false (List.mem value prompt_strings))
      ["PENDING_TITLE_ONLY"; "PENDING_BODY_ONLY"; "PENDING_CONTEXT_ONLY";
       "DIRECT_ATTENTION_BODY_ONLY"; "DIRECT_ATTENTION_CONTEXT_ONLY"];
    List.iter (fun value -> check bool "Direct source and mixed summary follow the actual reader"
      authorized (List.mem value prompt_strings))
      ["DIRECT_TITLE_ONLY"; direct_body; "DIRECT_COMMENT_ONLY";
       "MIXED_CONTEXT_ONLY"; "MIXED_ADVICE_ONLY"; "PRIVATE_COMMENT_CONTEXT_ONLY"];
    check bool "unrelated public history remains useful" true
      (List.mem "PUBLIC_CONTEXT_ONLY" prompt_strings && List.mem "PUBLIC_BODY_ONLY" prompt_strings);
    check string "capture does not delete or rewrite the retained snapshot" before (Fs_compat.load_file path);
    check bool "stored private source/pocket data remains intact" true
      ((Context.read ~keepers_dir ~keeper_id:keeper_name |> ok) = Some stored);
    check int "capture does not acknowledge or remove original queue work" 6
      (Keeper_registry_event_queue.pending_selections_result ~base_path keeper_name |> ok |> List.length);
    if keeper_name = outsider then (
      write_targets keeper_name [reader];
      check int "a newly resolved reader alias permits the same Direct sources" 4
        (List.length (capture ()).sources);
      write_targets keeper_name [];
      check int "alias removal immediately withdraws model-side Direct access" 2
        (List.length (capture ()).sources);
      check string "identity changes do not erase retained evidence" before (Fs_compat.load_file path)))
    [author; reader; outsider]

let () =
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  run "Librarian working contexts"
  ["scenarios", [
    test_case "capture rechecks Direct readership and retained mixed contexts" `Quick test_capture_rechecks_direct_readers_and_retained_context;
    test_case "source reassignment preserves distinct context identities" `Quick test_source_reassignment_does_not_collide_with_merged_identity;
    test_case "split source does not collide with an untouched context" `Quick test_split_source_does_not_collide_with_untouched_context;
    test_case "exact source retraction is atomic and preserves unaffected pockets" `Quick test_exact_source_retraction_preserves_and_reconsiders;
    test_case "one new source preserves two unrelated prior contexts" `Quick test_unrelated_prior_contexts_need_no_empty_source_output;
    test_case "new execution basis cannot launder untouched advice" `Quick test_new_basis_cannot_launder_untouched_advice;
    test_case "incremental campaign retains one context" `Quick test_incremental_campaign_merges_existing_context;
    test_case "unknown and reused merge targets rejected" `Quick test_invalid_merge_targets;
    test_case "execution progress invalidates unchanged-source advice" `Quick test_execution_progress_invalidates_unchanged_sources;
    test_case "corrupt snapshot rebuild rejects old generation" `Quick test_corrupt_snapshot_rebuild_rejects_old_generation;
    test_case "read-only input snapshot preserves execution ownership" `Quick test_pending_snapshot_includes_running_question_without_claiming;
    test_case "queue wake flood does not wait for librarian" `Quick test_queue_wakes_coalesce_without_waiting_for_librarian;
    test_case "repeated events and direct question" `Quick test_repeated_events_and_chat;
    test_case "partial observation, source settlement and stale CAS" `Quick test_partial_observation_and_cas;
    test_case "partial groups preserve coverage without oscillation" `Quick test_partial_group_keeps_coverage;
    test_case "ambiguous or missing references rejected" `Quick test_duplicate_and_missing_source_rejected;
    test_case "unchanged capture needs no second queue pass" `Quick test_unchanged_capture_needs_no_second_queue_pass]]
