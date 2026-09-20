(* The absorb gate of a librarian pass (RFC-librarian-absorb-gate): the cut
   into statements, and which absorptions the gate lets through. The model is
   a table here; the entry point installs the client. *)

module Gate = Masc.Keeper_librarian_absorb_gate
module T = Masc.Typesafeai_types
module Types = Masc.Keeper_memory_os_types

let fact claim : Types.fact =
  Types.observed
    ~claim
    ~category:Types.Fact
    ~now:(Time_compat.now ())
    ~origin:{ kind = Types.Authored; trace_id = "" }
;;

let id = Types.memory_id

(* --- Statements: the reference cut is scripts/librarian/statements.py, the
   scorer of issue #37079. Both it and this module are held to one golden,
   test/fixtures/librarian_statements_golden.json: the script's --check
   rule (test/dune) proves the script still writes it, and this test proves
   the OCaml cut reads every input to the same statements. Neither side's
   output is the other's expected value. --- *)

let golden_path = "fixtures/librarian_statements_golden.json"

let test_statements_match_the_golden () =
  let entries =
    match Yojson.Safe.from_file golden_path with
    | `List entries -> entries
    | _ -> Alcotest.fail "the golden is a list"
  in
  Alcotest.(check bool) "the golden is not empty" true (entries <> []);
  List.iteri
    (fun i entry ->
       let input = Yojson.Safe.Util.(entry |> member "input" |> to_string) in
       let expected =
         Yojson.Safe.Util.(entry |> member "expected" |> to_list |> List.map to_string)
       in
       Alcotest.(check (list string))
         (Printf.sprintf "golden entry %d cuts the same in OCaml" i)
         expected
         (Gate.statements input))
    entries
;;

(* --- Judgment --- *)

(* An evaluator that answers each statement from [noul_of], and counts the
   requests and the statements it was asked. *)
let table ~noul_of =
  let requests = ref 0 in
  let asked = ref [] in
  let evaluate ~state:_ ~questions =
    incr requests;
    let answers =
      List.map
        (fun (qid, question) ->
           match question with
           | T.Noul { T.instructions; _ } ->
             let statement =
               let prefix = "Statement:\n" in
               let at =
                 let rec find i =
                   if i + String.length prefix > String.length instructions
                   then failwith "no statement in the question"
                   else if String.sub instructions i (String.length prefix) = prefix
                   then i + String.length prefix
                   else find (i + 1)
                 in
                 find 0
               in
               String.sub instructions at (String.length instructions - at)
             in
             asked := statement :: !asked;
             qid, T.Noul_answer { T.noul = noul_of statement }
           | T.Choice _ | T.Score _ -> failwith "the gate asks noul questions only")
        questions
    in
    Ok { T.model = "jev-test"; answers; usage = None }
  in
  evaluate, requests, asked
;;

let sources = [ "the alpha service deploys every tuesday at nine in the morning";
                "the beta service ships on fridays and pages the operator on failure" ]
let merged = fact "alpha deploys tuesdays at nine; beta ships fridays and pages the operator"

let absorbed_into claim facts : Types.absorbed_statement list =
  List.map (fun (source : Types.fact) -> { Types.absorbed = id source; into = id claim }) facts
;;

let judged = function
  | Gate.Judged judged -> judged
  | Gate.Open { reason; _ } -> Alcotest.fail ("gate open: " ^ reason)
;;

let test_every_statement_conveyed_absorbs_as_answered () =
  let facts = List.map fact sources in
  let absorbed = absorbed_into merged facts in
  let evaluate, requests, _ = table ~noul_of:(fun _ -> 0.9) in
  let j = judged (Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed) in
  Alcotest.(check int) "both absorptions go through" 2 (List.length j.absorbed);
  Alcotest.(check int) "none kept current" 0 (List.length j.left);
  Alcotest.(check int) "both counted as conveyed" 2 (List.length j.conveyed);
  Alcotest.(check int) "one request for the one absorbing claim" 1 !requests;
  Alcotest.(check int) "the same is reported" 1 j.requests
;;

let test_a_statement_not_conveyed_keeps_its_memory_current () =
  let facts = List.map fact sources in
  let absorbed = absorbed_into merged facts in
  let contains haystack needle =
    let n = String.length needle in
    let rec at i =
      i + n <= String.length haystack
      && (String.sub haystack i n = needle || at (i + 1))
    in
    at 0
  in
  let evaluate, _, _ =
    table ~noul_of:(fun statement ->
      (* The claim says nothing about paging the operator. *)
      if contains statement "pages the operator" then 0.2 else 0.95)
  in
  let j = judged (Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed) in
  Alcotest.(check (list string))
    "only the alpha memory is absorbed"
    [ id (List.nth facts 0) ]
    (List.map (fun (s : Types.absorbed_statement) -> s.absorbed) j.absorbed);
  (match j.left with
   | [ verdict ] ->
     Alcotest.(check string) "the beta memory stays current" (id (List.nth facts 1)) verdict.memory_id;
     Alcotest.(check string) "named with the claim it did not go into" (id merged) verdict.into;
     Alcotest.(check bool) "with at least one statement not conveyed" true (verdict.not_conveyed >= 1)
   | _ -> Alcotest.fail "expected one memory kept current")
;;

let test_the_boundary_is_inclusive () =
  let facts = [ fact (List.hd sources) ] in
  let absorbed = absorbed_into merged facts in
  let evaluate, _, _ = table ~noul_of:(fun _ -> Gate.conveyed_boundary) in
  let j = judged (Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed) in
  Alcotest.(check int) "exactly the boundary is conveyed" 1 (List.length j.absorbed)
;;

let test_the_model_not_answering_applies_the_answer () =
  let facts = List.map fact sources in
  let absorbed = absorbed_into merged facts in
  let evaluate ~state:_ ~questions:_ = Error "HTTP 529" in
  (match Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed with
   | Gate.Open { reason; absorbed = applied; _ } ->
     Alcotest.(check string) "the reason is carried" "HTTP 529" reason;
     Alcotest.(check int) "and every absorption is still applied" 2 (List.length applied)
   | Gate.Judged _ -> Alcotest.fail "expected the gate to stay open");
  let missing ~state:_ ~questions:_ = Ok { T.model = "jev-test"; answers = []; usage = None } in
  match Gate.judge ~evaluate:missing ~facts ~new_claims:[ merged ] ~absorbed with
  | Gate.Open _ -> ()
  | Gate.Judged _ -> Alcotest.fail "an answer without the questions is not a judgment"
;;

let test_an_absorption_the_pass_cannot_place_goes_through_unjudged () =
  let facts = [ fact (List.hd sources) ] in
  let stranger = fact "a memory the pass did not carry" in
  let absorbed = absorbed_into merged (facts @ [ stranger ]) in
  let evaluate, _, asked = table ~noul_of:(fun _ -> 0.0) in
  let j = judged (Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed) in
  Alcotest.(check (list string))
    "the stranger goes through, the judged memory is kept current"
    [ id stranger ]
    (List.map (fun (s : Types.absorbed_statement) -> s.absorbed) j.absorbed);
  Alcotest.(check int) "reported as unjudged" 1 (List.length j.unjudged);
  Alcotest.(check bool) "the stranger's text was never asked about" true
    (not (List.exists (fun s -> s = "a memory the pass did not carry") !asked))
;;

let test_statements_are_asked_in_bounded_requests () =
  let many =
    fact
      (String.concat " "
         (List.init 40 (fun i ->
            Printf.sprintf "statement number %d is long enough to stand on its own here." i)))
  in
  let facts = List.init 5 (fun i -> fact (Printf.sprintf "%s copy %d" many.Types.claim i)) in
  let absorbed = absorbed_into merged facts in
  let evaluate, requests, asked = table ~noul_of:(fun _ -> 1.0) in
  let j = judged (Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed) in
  let statements = List.length !asked in
  Alcotest.(check int) "every memory's statements were asked"
    (List.fold_left (fun n (source : Types.fact) ->
       n + List.length (Gate.statements source.claim)) 0 facts) statements;
  Alcotest.(check int) "in requests of at most the bound"
    ((statements + Gate.questions_per_request - 1) / Gate.questions_per_request)
    !requests;
  Alcotest.(check int) "all absorbed" 5 (List.length j.absorbed)
;;

let test_a_missing_seventeenth_statement_keeps_the_whole_memory () =
  let prefix =
    List.init 16 (fun i ->
      Printf.sprintf "The service numbered %d deploys every Tuesday morning." i)
  in
  let exception_statement = "Emergency releases require the operator's explicit approval." in
  let source = fact (String.concat " " (prefix @ [ exception_statement ])) in
  let claim = fact (String.concat " " prefix) in
  let evaluate, _, asked =
    table ~noul_of:(fun statement ->
      if String.equal statement exception_statement then 0.0 else 1.0)
  in
  let j =
    judged
      (Gate.judge ~evaluate ~facts:[ source ] ~new_claims:[ claim ]
         ~absorbed:(absorbed_into claim [ source ]))
  in
  Alcotest.(check int) "all seventeen statements were judged" 17 (List.length !asked);
  Alcotest.(check int) "the original is not absorbed" 0 (List.length j.absorbed);
  Alcotest.(check (list string)) "the complete original remains current"
    [ id source ] (List.map (fun (v : Gate.source_verdict) -> v.memory_id) j.left)
;;

type runtime_case = Judged_run | Disabled_run | Http_failure | Memory_write_failure

let runtime_case_name = function
  | Judged_run -> "judged"
  | Disabled_run -> "disabled"
  | Http_failure -> "http-failure"
  | Memory_write_failure -> "memory-write-failure"
;;

let run_runtime_evidence ?fixture_dir () =
  let module Librarian = Masc.Keeper_librarian in
  let module Current = Masc.Keeper_memory_os_current in
  let module Absorbed = Masc.Keeper_memory_absorbed in
  let module Runs = Masc.Exact_lane_run_registry in
  let module Projection = Server_standalone_lane_projection in
  let module Fixture = Exact_output_fixture in
  let require = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let member = Yojson.Safe.Util.member in
  let string value = Yojson.Safe.Util.to_string value in
  let check_json label expected actual =
    Alcotest.(check string) label
      (Yojson.Safe.to_string expected) (Yojson.Safe.to_string actual)
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
  @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let base_path = Filename.temp_dir "librarian-absorb-gate-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  let registry_path = Filename.concat base_path Runs.storage_filename in
  let registry = Runs.create ~path:registry_path () in
  (match Runs.install_global registry with
   | Ok () -> ()
   | Error Runs.Already_installed -> Alcotest.fail "fixture registry already installed");
  let root = match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root | None -> Sys.getcwd () in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Masc.Prompt_defaults.init ();
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  List.iter (fun scenario ->
    let case_name = runtime_case_name scenario in
    let a = fact (List.nth sources 0) in
    let b = fact (List.nth sources 1) in
    let untouched = fact "The unrelated service retains its own deployment instructions." in
    let keeper_id = "absorb-gate-" ^ case_name in
    let source : Current.source = { kind = Current.Librarian; trace_id = "fixture" } in
    let seeded =
      Current.replace ~keepers_dir ~keeper_id ~expected_revision:None
        ~now:100. ~source ~facts:[ a; b; untouched ] () |> require
    in
    let input : Librarian.input =
      { turn_ref = Ids.Turn_ref.make ~trace_id:"fixture" ~absolute_turn:1
      ; goal_context = Librarian.No_task
      ; keeper_instructions = "Keep the service deployment instructions."
      ; current = Some { Librarian.facts = seeded.facts }
      ; working_context = Masc.Keeper_librarian_context.empty
      ; messages = []; tool_observations = []; counterpart_observations = []
      }
    in
    let tokens = List.mapi (fun i f -> id f, Printf.sprintf "m%d" (i + 1)) seeded.facts in
    let claim = "The alpha service deploys every Tuesday at nine in the morning." in
    let claims =
      [ `Assoc [ "claim", `String claim; "category", `String "fact"
               ; "absorbs", `List [ `String (List.assoc (id a) tokens)
                                   ; `String (List.assoc (id b) tokens) ] ] ]
    in
    (* A valid unabsorbing claim makes exact_output exceed the TUI preview.
       The gate evidence must remain ahead of that original model output. *)
    let claims = match scenario with
      | Judged_run -> claims @
          [ `Assoc [ "claim", `String (String.make 70000 'x' ^ "EXACT_OUTPUT_TAIL")
                   ; "category", `String "fact" ] ]
      | Disabled_run | Http_failure | Memory_write_failure -> claims
    in
    let answer = `Assoc
      [ "new_claims", `List claims; "dropped", `List []; "working_contexts", `List [] ] in
    let selection = match Librarian.selection_of_json_result ~now:200. input answer with
      | Ok selection -> selection
      | Error error -> Alcotest.fail (Librarian.parse_error_to_string error)
    in
    Alcotest.(check bool) "the answer projection already removed the originals" false
      (List.exists (fun f -> String.equal (id f) (id a) || String.equal (id f) (id b))
         selection.facts);
    let librarian = Fixture.start_server ~sw ~net ~clock
      (Fixture.Reply (Fixture.openai_response answer)) in
    let jev_response = Yojson.Safe.to_string
      (`Assoc [ "model", `String "jev-fixture"
              ; "answers", `Assoc
                  [ "s0_0", `Assoc [ "type", `String "noul"; "noul", `Float 1.0 ]
                  ; "s1_0", `Assoc [ "type", `String "noul"; "noul", `Float 0.0 ] ] ]) in
    let current_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
    let saved_path = current_path ^ ".preserved" in
    let jev_requests = ref [] in
    let handler _conn _request body =
      let raw = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
      jev_requests := raw :: !jev_requests;
      (match scenario with
       | Memory_write_failure ->
         Unix.rename current_path saved_path;
         Unix.mkdir current_path 0o700
       | Judged_run | Disabled_run | Http_failure -> ());
      match scenario with
      | Http_failure -> Cohttp_eio.Server.respond_string
          ~status:`Service_unavailable ~body:"fixture unavailable" ()
      | Judged_run | Disabled_run | Memory_write_failure ->
        Cohttp_eio.Server.respond_string ~status:`OK ~body:jev_response ()
    in
    let socket = Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
    let port = match Eio.Net.listening_addr socket with
      | `Tcp (_, port) -> port
      | _ -> Alcotest.fail "JEV fixture has no TCP address" in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Cohttp_eio.Server.run socket (Cohttp_eio.Server.make ~callback:handler ())
        ~on_error:(fun exn -> Alcotest.fail (Printexc.to_string exn)));
    let jev_uri = Printf.sprintf "http://127.0.0.1:%d" port in
    let resolver = Fixture.resolver_snapshot ~source:"absorb-gate-fixture"
      [ { Fixture.id = "librarian-absorb-fixture"; base_url = librarian.base_url } ] in
    (match Runtime_exact_output_registry.publish
      ~lanes:[ { Runtime_schema.id = "librarian_exact"
               ; slot_ids = [ "librarian-absorb-fixture" ]; cli_slot_ids = [] } ] resolver with
     | Ok _ -> ()
     | Error error -> Alcotest.fail
         (Runtime_exact_output_registry.publication_error_to_string error));
    Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "synthetic-jev-key") (fun () ->
      Masc_test_deps.with_process_env "MASC_TYPESAFEAI_ENABLED" (Some "true") (fun () ->
      Masc_test_deps.with_process_env "MASC_TYPESAFEAI_ABSORB_GATE_ENABLED"
        (Some (if scenario = Disabled_run then "false" else "true")) (fun () ->
        Masc_test_deps.with_process_env "MASC_TYPESAFEAI_ENDPOINT" (Some jev_uri) (fun () ->
          Masc.Keeper_librarian_runtime.run_best_effort
            ~trigger:Masc.Keeper_librarian_runtime.Queue_changed
            ~base_path ~keepers_dir ~keeper_id ~expected_revision:(Some seeded.revision) input))));
    Alcotest.(check int) "real Librarian request" 1 (Fixture.post_count librarian);
    Alcotest.(check int) "JEV request count"
      (if scenario = Disabled_run then 0 else 1) (List.length !jev_requests);
    let run = match List.filter (fun (run : Runs.run) -> run.actor = keeper_id)
        (Runs.list_runs registry) with
      | [ run ] -> Runs.get registry ~run_id:run.run_id |> Option.get
      | _ -> Alcotest.fail "expected one actual Librarian run" in
    Alcotest.(check string) "Memory result remains distinct from JEV result"
      (if scenario = Memory_write_failure then "failed" else "succeeded")
      (Runs.status_label run.status);
    let original = Runs.run_to_yojson run in
    (match scenario with
     | Memory_write_failure ->
       Alcotest.(check string) "the actual storage exception reaches run detail"
         "Librarian raised: Sys_error(\"Is a directory\")"
         (member "detail" original |> string)
     | Judged_run | Disabled_run | Http_failure -> ());
    let replayed = Runs.get (Runs.replay registry_path) ~run_id:run.run_id |> Option.get in
    check_json "the full execution evidence survives disk replay"
      original (Runs.run_to_yojson replayed);
    let output = member "output" original in
    (match output with
     | `Assoc (("absorb_gate", _) :: _) -> ()
     | _ -> Alcotest.fail "absorb_gate evidence must precede exact_output");
    let gate = member "absorb_gate" output in
    let expected_status = match scenario with
      | Judged_run | Memory_write_failure -> "judged"
      | Disabled_run -> "skipped"
      | Http_failure -> "open" in
    Alcotest.(check string) "gate status" expected_status (member "status" gate |> string);
    (match scenario with
     | Disabled_run ->
       Alcotest.(check string) "disabled is explicitly skipped" "not_enabled"
         (member "reason" gate |> string);
       check_json "no invented evaluations" `Null (member "evaluations" gate)
     | Judged_run | Http_failure | Memory_write_failure ->
       let evaluation = match member "evaluations" gate with
         | `List [ evaluation ] -> evaluation
         | _ -> Alcotest.fail "expected the one actual JEV evaluation" in
       let raw = List.hd !jev_requests in
       let sent = Yojson.Safe.from_string raw in
       let request = member "request" evaluation in
       List.iter (fun key -> check_json ("actual JEV request " ^ key)
         (member key sent) (member key request)) [ "state"; "questions" ];
       (match scenario with
        | Http_failure ->
          let reason = Printf.sprintf "typesafeai: HTTP 503 returned by %s: fixture unavailable" jev_uri in
          Alcotest.(check string) "original HTTP failure" reason (member "reason" gate |> string);
          Alcotest.(check string) "evaluation failure" "failed" (member "status" evaluation |> string);
          Alcotest.(check string) "same evaluation failure" reason (member "reason" evaluation |> string);
          List.iter (fun key -> check_json ("failure does not invent " ^ key)
            `Null (member key evaluation)) [ "model"; "answers"; "request_body_sha256" ]
        | Judged_run | Memory_write_failure ->
          Alcotest.(check string) "answered evaluation" "answered" (member "status" evaluation |> string);
          Alcotest.(check string) "actual answer model" "jev-fixture" (member "model" evaluation |> string);
          Alcotest.(check string) "actual destination" jev_uri (member "destination_uri" evaluation |> string);
          Alcotest.(check string) "actual HTTP request digest"
            Digestif.SHA256.(digest_string raw |> to_hex)
            (member "request_body_sha256" evaluation |> string);
          List.iter (fun (qid, expected) ->
            Alcotest.(check (float 0.)) ("raw probability " ^ qid) expected
              (member qid (member "answers" evaluation) |> Yojson.Safe.Util.to_float))
            [ "s0_0", 1.0; "s1_0", 0.0 ]
        | Disabled_run -> Alcotest.fail "disabled scenario cannot evaluate"));
    (match scenario with
     | Memory_write_failure ->
       Unix.rmdir current_path;
       Unix.rename saved_path current_path
     | Judged_run | Disabled_run | Http_failure -> ());
    let stored = match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require with
      | Some snapshot -> snapshot
      | None -> Alcotest.fail "current snapshot is missing" in
    let expected_facts = match scenario with
      | Judged_run -> b :: untouched :: selection.new_claims
      | Disabled_run | Http_failure -> untouched :: selection.new_claims
      | Memory_write_failure -> seeded.facts in
    Alcotest.(check (list string)) "correct originals remain current"
      (List.sort String.compare (List.map id expected_facts))
      (List.sort String.compare (List.map id stored.facts));
    let records = Absorbed.read ~keepers_dir ~keeper_id |> require in
    let records = List.map (fun (_, result) -> match result with
      | Ok record -> record
      | Error error -> Alcotest.fail (Absorbed.read_error_to_string error)) records in
    let archived = match scenario with
      | Judged_run -> [ a.claim ]
      | Disabled_run | Http_failure -> [ a.claim; b.claim ]
      | Memory_write_failure -> [] in
    Alcotest.(check (list string)) "only applied originals are archived"
      (List.sort String.compare archived)
      (List.sort String.compare (List.map (fun (r : Absorbed.record) -> r.fact.claim) records));
    Option.iter (fun directory ->
      let detail = match Projection.For_testing.run_detail_json_with
        ~run_id:replayed.run_id ~exact_runs:[ replayed ]
        ~verification_runs:[] ~goal_verification_runs:[] with
        | Projection.Detail_found detail -> detail
        | Detail_not_found | Detail_ambiguous -> Alcotest.fail "replayed run has no HTTP detail" in
      let page = Projection.For_testing.recent_run_page_json_with
        ~limit:1 ~before:None ~lane:(Some "librarian_exact") ~run_kind:None
        ~exact_runs:[ replayed ] ~verification_runs:[] ~goal_verification_runs:[] |> require in
      Yojson.Safe.to_file (Filename.concat directory (case_name ^ ".json"))
        (`Assoc [ "scenario", `String case_name; "detail", detail; "page", page ])) fixture_dir)
    [ Judged_run; Disabled_run; Http_failure; Memory_write_failure ]
;;

let test_selection_gate_and_store_keep_the_unconveyed_original () =
  run_runtime_evidence ()
;;

(* A noul is a probability. A value outside [0, 1] is a response-shape
   failure, and the gate opens rather than reading 2.0 as "conveyed". *)
let test_a_noul_outside_the_unit_interval_opens_the_gate () =
  let facts = [ fact (List.hd sources) ] in
  let absorbed = absorbed_into merged facts in
  let evaluate, _, _ = table ~noul_of:(fun _ -> 2.0) in
  match Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed with
  | Gate.Open _ -> ()
  | Gate.Judged _ -> Alcotest.fail "2.0 is not a probability"
;;

(* A verdict reached before a later request fails stays reached: the source
   a completed answer showed not conveyed is kept current, the source the
   failure left unresolved is applied as answered. *)
let test_a_rejection_completed_before_a_later_failure_is_kept () =
  let first = fact (List.nth sources 0) in
  let second = fact (List.nth sources 1) in
  let other = fact "gamma restarts nightly and keeps its logs for a week" in
  let absorbed = absorbed_into merged [ first ] @ absorbed_into other [ second ] in
  let calls = ref 0 in
  let evaluate ~state:_ ~questions =
    incr calls;
    if !calls = 1
    then
      Ok
        { T.model = "jev-test"
        ; usage = None
        ; answers = List.map (fun (qid, _) -> qid, T.Noul_answer { T.noul = 0.0 }) questions
        }
    else Error "HTTP 529"
  in
  match
    Gate.judge ~evaluate ~facts:[ first; second ] ~new_claims:[ merged; other ] ~absorbed
  with
  | Gate.Open { absorbed = applied; left; _ } ->
    Alcotest.(check (list string)) "the rejected source stays current"
      [ id first ]
      (List.map (fun (v : Gate.source_verdict) -> v.memory_id) left);
    Alcotest.(check (list string)) "the unresolved source is applied as answered"
      [ id second ]
      (List.map (fun (s : Types.absorbed_statement) -> s.absorbed) applied)
  | Gate.Judged _ -> Alcotest.fail "expected the gate to stay open"
;;

(* The same inside one source: a statement not conveyed in an answered
   request keeps the source current when the next request fails. *)
let test_a_rejection_in_an_answered_request_survives_the_next_failing () =
  let long =
    fact
      (String.concat " "
         (List.init (Gate.questions_per_request + 1) (fun i ->
            Printf.sprintf "statement number %d is long enough to stand alone." i)))
  in
  let absorbed = absorbed_into merged [ long ] in
  let calls = ref 0 in
  let evaluate ~state:_ ~questions =
    incr calls;
    if !calls = 1
    then
      Ok
        { T.model = "jev-test"
        ; usage = None
        ; answers =
            List.mapi
              (fun k (qid, _) -> qid, T.Noul_answer { T.noul = (if k = 0 then 0.0 else 1.0) })
              questions
        }
    else Error "HTTP 529"
  in
  Alcotest.(check int) "the source cuts into more than one request"
    (Gate.questions_per_request + 1)
    (List.length (Gate.statements long.claim));
  match Gate.judge ~evaluate ~facts:[ long ] ~new_claims:[ merged ] ~absorbed with
  | Gate.Open { absorbed = applied; left; _ } ->
    Alcotest.(check int) "two requests were attempted" 2 !calls;
    Alcotest.(check (list string)) "the source stays current"
      [ id long ]
      (List.map (fun (v : Gate.source_verdict) -> v.memory_id) left);
    Alcotest.(check int) "nothing is applied" 0 (List.length applied)
  | Gate.Judged _ -> Alcotest.fail "expected the gate to stay open"
;;

(* A claim over the state bound cannot be asked about at all: every memory
   it absorbs stays current, and nothing is sent. *)
let test_a_claim_over_the_state_bound_keeps_all_its_absorptions_current () =
  let wide = fact (String.make (Gate.state_bytes_limit + 1) 'x') in
  let facts = List.map fact sources in
  let absorbed = absorbed_into wide facts in
  let evaluate, requests, _asked = table ~noul_of:(fun _ -> 1.0) in
  let j = judged (Gate.judge ~evaluate ~facts ~new_claims:[ wide ] ~absorbed) in
  Alcotest.(check int) "nothing is absorbed" 0 (List.length j.absorbed);
  Alcotest.(check int) "every memory is reported as too large to judge"
    (List.length sources) (List.length j.unjudgeable);
  Alcotest.(check int) "no request was made" 0 !requests
;;

(* An oversized memory stays current even when the model fails on another
   memory's request: what cannot be judged is decided before asking. *)
let test_an_oversized_memory_stays_current_when_another_request_fails () =
  let huge = fact (String.make (Gate.request_bytes_limit + 1) 'x') in
  let small = fact (List.hd sources) in
  let absorbed = absorbed_into merged [ huge; small ] in
  let evaluate ~state:_ ~questions:_ = Error "HTTP 529" in
  match Gate.judge ~evaluate ~facts:[ huge; small ] ~new_claims:[ merged ] ~absorbed with
  | Gate.Open { absorbed = applied; _ } ->
    Alcotest.(check (list string)) "only the small memory's absorption is applied"
      [ id small ]
      (List.map (fun (s : Types.absorbed_statement) -> s.absorbed) applied)
  | Gate.Judged _ -> Alcotest.fail "expected the gate to stay open"
;;

(* A statement that does not fit a request cannot be judged; its memory
   stays current instead of being absorbed on a refusal the gate can predict. *)
let test_a_statement_too_large_to_judge_keeps_its_memory_current () =
  let huge = fact (String.make (Gate.request_bytes_limit + 1) 'x') in
  let small = fact (List.hd sources) in
  let facts = [ huge; small ] in
  let absorbed = absorbed_into merged facts in
  let evaluate, requests, asked = table ~noul_of:(fun _ -> 1.0) in
  let j = judged (Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed) in
  Alcotest.(check (list string)) "only the small memory is absorbed"
    [ id small ]
    (List.map (fun (s : Types.absorbed_statement) -> s.absorbed) j.absorbed);
  Alcotest.(check (list string)) "the huge one is reported as too large to judge"
    [ id huge ]
    (List.map (fun (s : Types.absorbed_statement) -> s.absorbed) j.unjudgeable);
  Alcotest.(check int) "one request, for the small memory" 1 !requests;
  Alcotest.(check bool) "the huge statement was never sent" true
    (not (List.exists (fun s -> String.length s > Gate.request_bytes_limit) !asked))
;;

let () =
  if Array.length Sys.argv = 3 && String.equal Sys.argv.(1) "--emit-tui-fixtures"
  then run_runtime_evidence ~fixture_dir:Sys.argv.(2) ()
  else Alcotest.run
    "keeper_librarian_absorb_gate"
    [ ( "statements"
      , [ Alcotest.test_case "the cut matches the golden" `Quick test_statements_match_the_golden ] )
    ; ( "judgment"
      , [ Alcotest.test_case "every statement conveyed absorbs as answered" `Quick
            test_every_statement_conveyed_absorbs_as_answered
        ; Alcotest.test_case "a statement not conveyed keeps its memory current" `Quick
            test_a_statement_not_conveyed_keeps_its_memory_current
        ; Alcotest.test_case "the boundary is inclusive" `Quick test_the_boundary_is_inclusive
        ; Alcotest.test_case "the model not answering applies the answer" `Quick
            test_the_model_not_answering_applies_the_answer
        ; Alcotest.test_case "an absorption the pass cannot place goes through unjudged" `Quick
            test_an_absorption_the_pass_cannot_place_goes_through_unjudged
        ; Alcotest.test_case "statements are asked in bounded requests" `Quick
            test_statements_are_asked_in_bounded_requests
        ; Alcotest.test_case "a noul outside the unit interval opens the gate" `Quick
            test_a_noul_outside_the_unit_interval_opens_the_gate
        ; Alcotest.test_case "a statement too large to judge keeps its memory current" `Quick
            test_a_statement_too_large_to_judge_keeps_its_memory_current
        ; Alcotest.test_case "an oversized memory stays current when another request fails" `Quick
            test_an_oversized_memory_stays_current_when_another_request_fails
        ; Alcotest.test_case "a claim over the state bound keeps all its absorptions current" `Quick
            test_a_claim_over_the_state_bound_keeps_all_its_absorptions_current
        ; Alcotest.test_case "a rejection completed before a later failure is kept" `Quick
            test_a_rejection_completed_before_a_later_failure_is_kept
        ; Alcotest.test_case "a rejection in an answered request survives the next failing" `Quick
            test_a_rejection_in_an_answered_request_survives_the_next_failing
        ; Alcotest.test_case "a missing seventeenth statement keeps the original" `Quick
            test_a_missing_seventeenth_statement_keeps_the_whole_memory
        ; Alcotest.test_case "selection gate and store preserve the original" `Quick
            test_selection_gate_and_store_keep_the_unconveyed_original
        ] )
    ]
;;
