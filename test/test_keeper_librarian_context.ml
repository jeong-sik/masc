open Alcotest
open Masc
module Context = Keeper_librarian_context

let source reference text : Context.source = {reference; content = `String text}
let events = List.init 20 (fun i -> source (Printf.sprintf "event:campaign:%d" i) "continue campaign")
let question = source "chat:question:revision1" "Where are we now?"
let pocket sources context next_steps : Context.pocket = {sources; context; next_steps; completeness = Context.Current}
let input sources previous : Context.input = {sources; previous; unavailable = []}
let ok = function Ok value -> value | Error detail -> fail detail
let expect_error = function Error _ -> () | Ok _ -> fail "expected rejection"
let with_store f =
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
  let previous : Context.snapshot = {revision = 1; sources; pockets} in
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
  let first = ok (Context.commit ~keepers_dir ~keeper_id ~expected_revision:None
    ~sources:initial_sources initial_pockets) in
  let replacement = [pocket [question.reference] "Question awaits answer" ["Answer"]] in
  let second = ok (Context.commit ~keepers_dir ~keeper_id ~expected_revision:(Some first.revision)
    ~sources:[question] replacement) in
  check int "unknown event observation preserves old pocket" 2 (List.length second.pockets);
  expect_error (Context.commit ~keepers_dir ~keeper_id ~expected_revision:(Some first.revision)
    ~sources:[] []);
  let after_rejected = ok (Context.read ~keepers_dir ~keeper_id) |> Option.get in
  check int "stale CAS leaves latest snapshot intact" second.revision after_rejected.revision;
  let third = ok (Context.commit ~observed_sources:[question] ~keepers_dir ~keeper_id
    ~expected_revision:(Some second.revision) ~sources:[] []) in
  check int "authoritative settled event observation prunes derived history" 1 (List.length third.pockets);
  let unknown : Context.input = {sources = []; previous = Some third; unavailable = ["store unavailable"]} in
  check bool "unknown observation still exposes historical context" true (Option.is_some (Context.render unknown));
  let fourth = ok (Context.commit ~keepers_dir ~keeper_id ~expected_revision:(Some third.revision)
    ~sources:unknown.sources []) in
  check int "unknown empty observation does not erase pockets" 1 (List.length fourth.pockets)

let test_partial_group_keeps_coverage () = with_store @@ fun keepers_dir ->
  let keeper_id = "partial-group" in
  let a = source "a" "first campaign event" in
  let b = source "b" "second campaign event" in
  let c = source "c" "new user question" in
  let original = ok (Context.commit ~keepers_dir ~keeper_id ~expected_revision:None
    ~sources:[a; b] [pocket [a.reference; b.reference] "Campaign" ["Continue"]]) in
  let apply previous sources =
    let snapshot = ok (Context.commit ~observed_sources:[a; b; c] ~keepers_dir ~keeper_id
      ~expected_revision:(Some previous.Context.revision) ~sources
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

let test_oversized_source_does_not_block_followers () =
  let oversized = source "event:oversized" (String.make 4096 'x') in
  let small = source "chat:small" "Where are we?" in
  let selected = ok (Keeper_librarian_runtime.For_testing.select_source_subset
      ~sources:[oversized; small]
      ~fits:(fun sources -> Ok (String.length
        (Yojson.Safe.to_string (Context.prompt_json (input sources None))) < 1024))) in
  check (list string) "unfit first source cannot starve later question"
    [small.reference] (List.map (fun (s : Context.source) -> s.reference) selected);
  check int "original source list remains intact" 2 (List.length [oversized; small])

let test_queue_wakes_coalesce_without_waiting_for_librarian () =
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
      ~expected_revision:(Option.map (fun (s : Context.snapshot) -> s.revision) previous)
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

let test_fit_reconsiders_remainder_without_splitting_current () =
  let a = source "event:current" "current context" in
  let b = source "event:remainder" "unorganized remainder" in
  let previous : Context.snapshot =
    {revision = 1; sources = [a; b]; pockets =
      [pocket [a.reference] "already organized" ["continue"];
       {(pocket [b.reference] "split context" []) with completeness = Context.Needs_reconsideration}]} in
  let inp : Keeper_librarian.input =
    {turn_ref = Ids.Turn_ref.make ~trace_id:"reconsider" ~absolute_turn:1;
     goal_context = No_task; keeper_instructions = "test"; current = None;
     working_context = input [a; b] (Some previous); messages = [];
     tool_observations = []; counterpart_observations = []} in
  let fitted = Keeper_librarian_runtime.fit_input ~count:1 inp in
  check (list string) "remainder selected without splitting complete context" [b.reference]
    (List.map (fun (s : Context.source) -> s.reference) fitted.working_context.sources);
  check (list string) "coverage does not imply completed organization" [a.reference]
    (Context.current_references previous)

let () = run "Librarian working contexts"
  ["scenarios", [
    test_case "reconsideration advances without regrouping complete sources" `Quick test_fit_reconsiders_remainder_without_splitting_current;
    test_case "read-only input snapshot preserves execution ownership" `Quick test_pending_snapshot_includes_running_question_without_claiming;
    test_case "oversized source does not block later inputs" `Quick test_oversized_source_does_not_block_followers;
    test_case "queue wake flood does not wait for librarian" `Quick test_queue_wakes_coalesce_without_waiting_for_librarian;
    test_case "repeated events and direct question" `Quick test_repeated_events_and_chat;
    test_case "partial observation, source settlement and stale CAS" `Quick test_partial_observation_and_cas;
    test_case "partial groups preserve coverage without oscillation" `Quick test_partial_group_keeps_coverage;
    test_case "ambiguous or missing references rejected" `Quick test_duplicate_and_missing_source_rejected]]
