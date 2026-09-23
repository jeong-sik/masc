open Masc
module Context = Keeper_librarian_context
module Runtime = Keeper_librarian_runtime
module Current = Keeper_memory_os_current
module Types = Keeper_memory_os_types
module Runs = Exact_lane_run_registry
module Fixture = Exact_output_fixture
module Chat = Keeper_chat_operation_store

exception Cancel_after_context
let require = function Ok value -> value | Error detail -> Alcotest.fail detail
let chat_ok result = result |> Result.map_error Chat.error_to_string |> require
let member = Yojson.Safe.Util.member
let text = Yojson.Safe.Util.to_string
let check_json label expected actual =
  Alcotest.(check string) label (Yojson.Safe.to_string expected) (Yojson.Safe.to_string actual)
let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = sub || at (i + 1)) in
  at 0

type scenario = Faithful | Rejected | Uncertain | Missing | Invalid | Http_failure
  | Excluded | Stale | Cancel_absorb | Cancel_review | Context_only | Conversation_queue
let name = function Faithful -> "faithful" | Rejected -> "needs-revision"
  | Uncertain -> "insufficient" | Missing -> "missing-answer" | Invalid -> "invalid-answer"
  | Http_failure -> "http-failure" | Excluded -> "excluded" | Stale -> "stale"
  | Cancel_absorb -> "cancel-after-context" | Cancel_review -> "cancel-review"
  | Context_only -> "context-only" | Conversation_queue -> "conversation-queue"
let verdict = function Rejected -> "needs_revision" | Uncertain -> "insufficient_evidence"
  | _ -> "faithful"
let pocket sources context : Context.pocket =
  {id = "fixture"; sources; context; next_steps = ["Read the original request"];
   merge_contexts = []; completeness = Context.Current}

let test_case ~base_path ~registry ?fixture_dir scenario () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let keeper_id = "context-review-" ^ name scenario in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let chat_path = Chat.path_for_keeper ~keepers_runtime_dir:keepers_dir ~keeper_name:keeper_id in
  Fs_compat.mkdir_p (Filename.dirname chat_path);
  let chat = Chat.open_or_create ~path:chat_path |> chat_ok in
  Fun.protect ~finally:(fun () -> ignore (Chat.close chat)) @@ fun () ->
  let submit id content =
    let operation_id = Keeper_chat_operation.Operation_id.of_string id |> require in
    let operation = match Chat.submit chat ~now:100. ~operation_id
      ~source:(`Assoc ["kind", `String "synthetic-user"])
      ~input:(`Assoc ["message", `String content]) |> chat_ok with
      | Chat.Accepted operation | Existing operation -> operation in
    operation, Context.source_of_chat operation
  in
  let a, sa = submit "prior-a" "Do not publish the draft without my approval." in
  let b, sb = submit "prior-b" "Keep the deployment task separate." in
  let c, sc = submit "current-c" "Tell me the draft's progress; approval remains pending." in
  let first = Context.commit ~keepers_dir ~keeper_id ~expected_version:None
      ~execution_basis:"earlier-progress" ~sources:[sa; sb]
      [pocket [sa.reference; sb.reference] "Draft approval and deployment remain unresolved"] |> require in
  (* A real partial update leaves the remaining prior pocket needing reconsideration. *)
  let previous = Context.commit ~keepers_dir ~keeper_id
      ~expected_version:(Some (Context.version first)) ~execution_basis:"earlier-progress"
      ~sources:[sb] [pocket [sb.reference] "Deployment is separate"] |> require in
  let merged = List.find (fun (p : Context.pocket) -> p.completeness = Context.Needs_reconsideration)
      previous.pockets in
  let alias = List.mapi (fun i (p : Context.pocket) -> p.id, Printf.sprintf "c%d" (i + 1)) previous.pockets
      |> List.assoc merged.id in
  let context_path = Context.path ~keepers_dir ~keeper_id in
  let prior_bytes = Fs_compat.load_file context_path in
  let fact = Types.observed ~claim:"The draft requires approval before publication."
      ~category:Types.Fact ~now:100. ~origin:{kind = Types.Authored; trace_id = keeper_id} in
  let seeded = Current.replace ~keepers_dir ~keeper_id ~expected_revision:None ~now:100.
      ~source:{kind = Current.Librarian; trace_id = keeper_id} ~facts:[fact] () |> require in
  let seeded = if scenario = Context_only then
      Current.apply_disposition ~keepers_dir ~keeper_id ~now:101.
        ~source:{kind = Current.Librarian; trace_id = keeper_id}
        ~official_range_id:{receipt_scope = keepers_dir; after_boundary_line = 0;
          turns = [1, Ids.Turn_ref.make ~trace_id:keeper_id ~absolute_turn:1]}
        ~absorbed:[] ~new_claims:[] () |> require
    else seeded in
  let memory_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let memory_before = Fs_compat.load_file memory_path in
  let working_context : Context.input =
    {sources = [sc]; previous = Some previous; unavailable = ["prior inputs outside this selected batch"];
     execution_basis = Some "current-progress"} in
  let input : Keeper_librarian.input =
    {turn_ref = Ids.Turn_ref.make ~trace_id:keeper_id ~absolute_turn:1;
     goal_context = Keeper_librarian.No_task; keeper_instructions = "Preserve pending approval.";
     current = Some {facts = seeded.facts}; working_context;
     messages = (if scenario = Conversation_queue then
       [Agent_core.Types.make_message ~role:Agent_core.Types.User
          [Agent_core.Types.Text "Replace the outdated publication note."]] else []);
     tool_observations = []; counterpart_observations = []} in
  let proposal = `Assoc ["merge_contexts", `List [`String alias]; "sources", `List [`String "s1"];
    "context", `String (if scenario = Rejected then "The user approved publication." else "The user asks for progress; publication still needs approval.");
    "next_steps", `List [`String "Answer progress without publishing"]] in
  let claims = if scenario = Cancel_absorb then
      [`Assoc ["claim", `String "Publication of the draft needs prior approval.";
        "category", `String "fact"; "absorbs", `List [`String "m1"]]] else [] in
  let dropped = if scenario = Conversation_queue then
    [`Assoc ["memory_id", `String "m1"; "reason", `String "The note is outdated."]] else [] in
  (* A Context-only pass asks for the working contexts alone, so its answer
     has no Memory field to carry. *)
  let answer = if scenario = Context_only then `Assoc ["working_contexts", `List [proposal]]
    else `Assoc ["new_claims", `List claims; "dropped", `List dropped;
      "working_contexts", `List [proposal]] in
  let librarian = Fixture.start_server ~sw ~net ~clock
      (Fixture.Reply (Fixture.openai_response answer)) in
  let requests = ref [] in
  let changed_snapshot = ref None in
  let blocked, signal_blocked = Eio.Promise.create () in
  let handler _ request body =
    let raw = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let json = Yojson.Safe.from_string raw in
    requests := json :: !requests;
    let is_context = member "meaning_preservation" (member "questions" json) <> `Null in
    if (not is_context && scenario = Cancel_absorb)
       || (is_context && scenario = Cancel_review) then (
      Eio.Promise.resolve signal_blocked ();
      Eio.Fiber.await_cancel ());
    if scenario = Stale then
      changed_snapshot := Some (Context.commit ~keepers_dir ~keeper_id
        ~expected_version:(Some (Context.version previous)) ~sources:[] [] |> require);
    let choice = verdict scenario in
    let response = `Assoc ["model", `String "jev-context-fixture";
      "answers", `Assoc (if scenario = Missing then [] else
        ["meaning_preservation", (if scenario = Invalid then
          `Assoc ["type", `String "noul"; "noul", `Float 0.8]
        else `Assoc ["type", `String "choice"; "choice", `String choice;
          "probabilities", `Assoc (List.map (fun label -> label, `Float (if label = choice then 1. else 0.))
            ["faithful"; "needs_revision"; "insufficient_evidence"]); "confidence", `Float 1.])])] in
    ignore request;
    Cohttp_eio.Server.respond_string
      ~status:(if scenario = Http_failure then `Service_unavailable else `OK)
      ~body:(if scenario = Http_failure then "synthetic outage" else Yojson.Safe.to_string response) ()
  in
  let socket = Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with `Tcp (_, port) -> port | _ -> assert false in
  Eio.Fiber.fork_daemon ~sw (fun () -> Cohttp_eio.Server.run socket
    (Cohttp_eio.Server.make ~callback:handler ()) ~on_error:(fun exn -> raise exn));
  let resolver = Fixture.resolver_snapshot ~source:"context-review-fixture"
      [{Fixture.id = "context-librarian"; base_url = librarian.base_url}] in
  (match Runtime_exact_output_registry.publish ~lanes:[{Runtime_schema.id = "librarian_exact";
      slot_ids = ["context-librarian"]; cli_slot_ids = []; max_output_tokens = Some 4_096}] resolver with
   | Ok _ -> () | Error error -> Alcotest.fail (Runtime_exact_output_registry.publication_error_to_string error));
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "synthetic-context-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled = true;
      destinations =
        ( { Runtime_schema.endpoint = Printf.sprintf "http://127.0.0.1:%d/evaluate" port
          ; model = "requested-context-fixture"
          ; api_key_env = "TYPESAFEAI_API_KEY"
          }
        , [] );
      context_review = true; absorb_gate = true;
      excluded_keepers = if scenario = Excluded then [keeper_id] else []} @@ fun () ->
  let receipt_path = Current.durable_range_receipt_path ~keepers_dir ~keeper_id in
  let journal_path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let receipt_before = Fs_compat.load_file_opt receipt_path in
  let journal_before = Fs_compat.load_file_opt journal_path in
  let run () = Runtime.run_best_effort
      ~write_scope:(if scenario = Context_only then Runtime.Context_only else Runtime.Context_and_memory)
      ~base_path ~keepers_dir ~keeper_id ~expected_revision:(Some seeded.revision) input in
  if scenario = Cancel_absorb || scenario = Cancel_review then (
    let scope, publish_scope = Eio.Promise.create () in
    let worker = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc ->
      Eio.Promise.resolve publish_scope cc; run ())) in
    let await failure = Fixture.await_within_fixture_budget ~clock ~failure in
    let cc = await "runtime did not enter cancellation scope" scope in
    await "the selected JEV request did not start" blocked;
    Eio.Cancel.cancel cc Cancel_after_context;
    match await "cancelled runtime did not return" worker with
    | Error (Eio.Cancel.Cancelled Cancel_after_context) -> ()
    | Error exn -> Alcotest.fail (Printexc.to_string exn)
    | Ok () -> Alcotest.fail "runtime swallowed cancellation")
  else run ();
  Alcotest.(check int) "one actual Librarian request" 1 (Fixture.post_count librarian);
  Alcotest.(check int) "one batch judgement; absorb only in cancellation case"
    (if scenario = Excluded then 0 else if scenario = Cancel_absorb then 2 else 1)
    (List.length !requests);
  List.iter (fun original ->
    match Chat.get chat original.Keeper_chat_operation.operation_id |> chat_ok with
    | Some current -> check_json "raw intake remains queued with identical input and identity"
        (Keeper_chat_operation.to_json original) (Keeper_chat_operation.to_json current)
    | None -> Alcotest.fail "original queued chat disappeared") [a; b; c];
  let after = Context.read ~keepers_dir ~keeper_id |> require |> Option.get in
  if scenario = Rejected || scenario = Cancel_review then
    Alcotest.(check string) "unpublished batch leaves prior Context byte-for-byte unchanged"
      prior_bytes (Fs_compat.load_file context_path)
  else if scenario = Stale then
    Alcotest.(check bool) "stale proposal cannot overwrite concurrent Context" true
      (Some after = !changed_snapshot)
  else (
    Alcotest.(check int) "accepted or unassessed batch commits once" (previous.revision + 1) after.revision;
    Alcotest.(check bool) "new source enters the organized snapshot" true
      (List.exists (fun (s : Context.source) -> s.reference = sc.reference) after.sources));
  if scenario = Cancel_absorb || scenario = Cancel_review || scenario = Context_only then
    Alcotest.(check string) "Context commit is independent of uncommitted Memory"
      memory_before (Fs_compat.load_file memory_path);
  if scenario = Context_only then (
    List.iter (fun body ->
      Alcotest.(check bool) "Context-only request asks for no Memory judgment" false
        (contains ~sub:Keeper_librarian.wire_field_new_claims body))
      (Fixture.request_bodies librarian);
    Alcotest.(check (option string)) "Context-only preserves Memory journal" journal_before
      (Fs_compat.load_file_opt journal_path);
    Alcotest.(check (option string)) "Context-only preserves Memory receipt" receipt_before
      (Fs_compat.load_file_opt receipt_path));
  if scenario = Conversation_queue then (
    let current = Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require |> Option.get in
    Alcotest.(check int) "queue-triggered conversation still commits Memory" (seeded.revision + 1) current.revision;
    Alcotest.(check int) "conversation evidence applies its disposition" 0 (List.length current.facts));
  let run = match List.filter (fun (r : Runs.run) -> r.actor = keeper_id) (Runs.list_runs registry) with
    | [run] -> Runs.get registry ~run_id:run.run_id |> Option.get
    | _ -> Alcotest.fail "expected one run" in
  let output = match run.status with Runs.Completed {output; _} -> output
    | _ -> Alcotest.fail "runtime did not persist terminal evidence" in
  if scenario = Context_only then (
    Alcotest.(check string) "explicit Context-only result" "skipped_context_only"
      (member "memory_write" output |> text);
    check_json "no absorb pass was run" `Null (member "absorb_gate" output));
  let review = member "context_review" output and write = member "context_write" output in
  Alcotest.(check string) "publication outcome is explicit"
    (if scenario = Cancel_review then "not_attempted" else if scenario = Rejected then "withheld" else if scenario = Stale then "failed" else "committed")
    (member "status" write |> text);
  Alcotest.(check string) "review failures never claim preservation"
    (match scenario with Cancel_review -> "incomplete" | Excluded -> "skipped" | Missing | Invalid -> "invalid_answer"
     | Http_failure -> "failed" | _ -> "judged") (member "status" review |> text);
  Alcotest.(check string) "cancellation remains distinct from Context commit"
    (if scenario = Cancel_absorb || scenario = Cancel_review then "cancelled" else "succeeded") (Runs.status_label run.status);
  if scenario <> Excluded then (
    let request = List.find (fun json -> member "meaning_preservation" (member "questions" json) <> `Null) !requests in
    let state = member "state" request in
    let prior = member "merged_previous" state |> Yojson.Safe.Util.to_list |> List.hd in
    Alcotest.(check string) "judge sees prior derived incompleteness"
      "needs_reconsideration" (member "completeness" prior |> text);
    let prior_source = member "sources" prior |> Yojson.Safe.Util.to_list |> List.hd in
    check_json "judge receives exact prior raw source, not just summary" sa.content (member "content" prior_source);
    let selected = member "selected_sources" state |> Yojson.Safe.Util.to_list |> List.hd in
    check_json "judge receives current raw request" sc.content (member "content" selected));
  let replayed = Runs.replay (Filename.concat base_path Runs.storage_filename) in
  let replayed_run = Runs.get replayed ~run_id:run.run_id |> Option.get in
  check_json "Context review and write survive durable registry replay"
    (Runs.run_to_yojson run) (Runs.run_to_yojson replayed_run);
  let module Projection = Server_standalone_lane_projection in
    let detail = match Projection.For_testing.run_detail_json_with ~run_id:run.run_id
      ~exact_runs:[replayed_run] ~verification_runs:[] ~goal_verification_runs:[] with
      | Projection.Detail_found detail -> detail | _ -> Alcotest.fail "missing run detail" in
    let page = Projection.For_testing.recent_run_page_json_with ~limit:1 ~before:None
      ~lane:(Some "librarian_exact") ~run_kind:None ~exact_runs:[replayed_run]
      ~verification_runs:[] ~goal_verification_runs:[] |> require in
    let fixture = `Assoc ["scenario", `String (name scenario); "detail", detail; "page", page] in
    Printf.printf "CONTEXT_REVIEW_FIXTURE %s\n%!" (Yojson.Safe.to_string fixture);
    Option.iter (fun directory ->
      Yojson.Safe.to_file (Filename.concat directory (name scenario ^ ".json")) fixture) fixture_dir

let () =
  Masc_test_deps.ensure_rng_initialized ();
  let base_path = Filename.temp_dir "context-review-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let registry = Runs.create ~path:(Filename.concat base_path Runs.storage_filename) () in
  (match Runs.install_global registry with Ok () -> () | Error _ -> Alcotest.fail "registry already installed");
  let root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Prompt_defaults.init ();
  let cases = [Faithful; Rejected; Uncertain; Missing; Invalid; Http_failure; Excluded; Stale; Cancel_absorb; Cancel_review] in
  if Array.length Sys.argv = 3 && Sys.argv.(1) = "--emit-tui-fixtures" then
    List.iter (fun scenario -> test_case ~base_path ~registry ~fixture_dir:Sys.argv.(2) scenario ()) cases
  else Alcotest.run "Librarian Context review"
    ["real runtime", List.map (fun scenario -> Alcotest.test_case (name scenario) `Quick
      (test_case ~base_path ~registry scenario)) (cases @ [Context_only; Conversation_queue])]
