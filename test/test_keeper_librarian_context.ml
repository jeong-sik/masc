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
  let rendered = Option.get (Context.render inp) in
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
  check bool "unknown observation still exposes historical context" true (Option.is_some (Context.render unknown));
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
  let quarantine = file ^ ".invalid-" ^ Digestif.SHA256.(digest_string invalid |> to_hex) in
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

let () = run "Librarian working contexts"
  ["scenarios", [
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
    test_case "ambiguous or missing references rejected" `Quick test_duplicate_and_missing_source_rejected]]
