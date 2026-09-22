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
  | Gate.Failed { reason; _ } -> Alcotest.fail ("judgment failed: " ^ reason)
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

let test_the_model_not_answering_keeps_the_sources () =
  let facts = List.map fact sources in
  let absorbed = absorbed_into merged facts in
  let evaluate ~state:_ ~questions:_ = Error "HTTP 529" in
  (match Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed with
   | Gate.Failed { reason; absorbed = applied; _ } ->
     Alcotest.(check string) "the reason is carried" "HTTP 529" reason;
     Alcotest.(check int) "unconfirmed sources stay current" 0 (List.length applied)
   | Gate.Judged _ -> Alcotest.fail "expected failed judgment");
  let missing ~state:_ ~questions:_ = Ok { T.model = "jev-test"; answers = []; usage = None } in
  match Gate.judge ~evaluate:missing ~facts ~new_claims:[ merged ] ~absorbed with
  | Gate.Failed _ -> ()
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

type runtime_case =
  | Judged_run | Gate_disabled_run | Lane_disabled_run | Missing_key_run | Excluded_run
  | Http_failure | Invalid_json_run | Invalid_response_run | Nonfinite_response_run | Duplicate_response_run | Nonutf8_response_run
  | Invalid_answer_run | Memory_write_failure

let runtime_case_name = function
  | Judged_run -> "judged"
  | Gate_disabled_run -> "disabled"
  | Excluded_run -> "excluded"
  | Lane_disabled_run -> "lane-disabled"
  | Missing_key_run -> "missing-key"
  | Http_failure -> "http-failure"
  | Invalid_json_run -> "invalid-json"
  | Invalid_response_run -> "invalid-response"
  | Nonfinite_response_run -> "nonfinite-response"
  | Duplicate_response_run -> "duplicate-response"
  | Nonutf8_response_run -> "nonutf8-response"
  | Invalid_answer_run -> "invalid-answer"
  | Memory_write_failure -> "memory-write-failure"
;;

let invalid_response_body = function
  | Invalid_json_run -> Some "not JSON: \"fixture\"\nsecond line"
  | Invalid_response_run -> Some {|{"model":"malformed-fixture","answers":[]}|}
  | Nonfinite_response_run -> Some {|{"model":"nonfinite-fixture","answers":{"s0_0":{"type":"noul","noul":NaN},"s1_0":{"type":"noul","noul":0.0}}}|}
  | Duplicate_response_run -> Some {|{"model":"duplicate-fixture","answers":{"s0_0":{"type":"noul","noul":1.0},"s0_0":{"type":"noul","noul":0.0}}}|}
  | Nonutf8_response_run -> Some ("{\"model\":\"binary-" ^ String.make 1 (Char.chr 255) ^ "\",\"answers\":{}}")
  | Judged_run | Gate_disabled_run | Excluded_run | Lane_disabled_run | Missing_key_run
  | Http_failure | Invalid_answer_run | Memory_write_failure -> None
;;

let runtime_skip_reason = function
  | Gate_disabled_run -> Some "absorb_gate_disabled"
  | Excluded_run -> Some "keeper_excluded"
  | Lane_disabled_run -> Some "lane_disabled"
  | Missing_key_run -> Some "no_armed_destination"
  | Judged_run | Http_failure | Invalid_json_run | Invalid_response_run | Nonfinite_response_run | Duplicate_response_run | Nonutf8_response_run
  | Invalid_answer_run | Memory_write_failure -> None
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
      | Gate_disabled_run | Excluded_run | Lane_disabled_run | Missing_key_run | Http_failure | Invalid_json_run | Invalid_response_run | Nonfinite_response_run | Duplicate_response_run | Nonutf8_response_run
  | Invalid_answer_run | Memory_write_failure -> claims
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
    let returned_answers =
      [ "s0_0", (if scenario = Invalid_answer_run
          then `Assoc [ "type", `String "choice"; "choice", `String "yes"
             ; "probabilities", `Assoc [ "yes", `Float 0.7; "no", `Float 0.3 ]
             ; "confidence", `Float 0.8 ]
          else `Assoc [ "type", `String "noul"; "noul", `Float 1.0 ])
      ; "s1_0", `Assoc [ "type", `String "noul"; "noul", `Float 0.0 ] ] in
    let jev_response = Yojson.Safe.to_string
      (`Assoc [ "model", `String "jev-fixture"
              ; "answers", `Assoc returned_answers ]) in
    let current_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
    let saved_path = current_path ^ ".preserved" in
    let jev_requests = ref [] in
    let jev_targets = ref [] in
    let observed_storage_error = ref None in
    let handler _conn request body =
      jev_targets := Cohttp.Request.uri request :: !jev_targets;
      let raw = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
      jev_requests := raw :: !jev_requests;
      (match scenario with
       | Memory_write_failure ->
         Unix.rename current_path saved_path;
         Unix.mkdir current_path 0o700;
         (* Observe the same reader/path the Memory writer will use. The
            filesystem's Sys_error text differs between Linux and macOS. *)
         (try
            ignore (Fs_compat.load_file_opt current_path : string option);
            Alcotest.fail "the directory must fail the Memory file read"
          with Sys_error _ as exn ->
            observed_storage_error := Some (Printexc.to_string exn))
       | Judged_run | Gate_disabled_run | Excluded_run | Lane_disabled_run | Missing_key_run | Http_failure | Invalid_json_run | Invalid_response_run | Nonfinite_response_run | Duplicate_response_run | Nonutf8_response_run | Invalid_answer_run -> ());
      match scenario with
      | Http_failure -> Cohttp_eio.Server.respond_string
          ~status:`Service_unavailable ~body:"fixture unavailable" ()
      | Invalid_json_run | Invalid_response_run | Nonfinite_response_run | Duplicate_response_run | Nonutf8_response_run ->
        Cohttp_eio.Server.respond_string ~status:`OK
          ~body:(Option.get (invalid_response_body scenario)) ()
      | Judged_run | Gate_disabled_run | Excluded_run | Lane_disabled_run | Missing_key_run | Invalid_answer_run | Memory_write_failure ->
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
    let displayed_jev_uri = Printf.sprintf "http://127.0.0.1:%d/evaluate" port in
    let jev_uri = Printf.sprintf
      "http://fixture-user:fixture-password@127.0.0.1:%d/evaluate?access=fixture-query#fixture-fragment"
      port in
    let resolver = Fixture.resolver_snapshot ~source:"absorb-gate-fixture"
      [ { Fixture.id = "librarian-absorb-fixture"; base_url = librarian.base_url } ] in
    (match Runtime_exact_output_registry.publish
      ~lanes:[ { Runtime_schema.id = "librarian_exact"
               ; slot_ids = [ "librarian-absorb-fixture" ]; cli_slot_ids = [] } ] resolver with
     | Ok _ -> ()
     | Error error -> Alcotest.fail
         (Runtime_exact_output_registry.publication_error_to_string error));
    let requested_model = "configured-request-fixture" in
    Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY"
      (if scenario = Missing_key_run then None else Some "synthetic-jev-key") (fun () ->
      Masc_test_deps.with_typesafeai_policy
        { Runtime_schema.default_typesafeai with
          lane_enabled = scenario <> Lane_disabled_run
        ; destinations =
            ( { Runtime_schema.endpoint = jev_uri; model = requested_model; api_key_env = "TYPESAFEAI_API_KEY" }
            , [] )
        ; absorb_gate = scenario <> Gate_disabled_run
        ; excluded_keepers = (if scenario = Excluded_run then [ keeper_id ] else [])
        }
        (fun () ->
          Masc.Keeper_librarian_runtime.run_best_effort
            ~trigger:Masc.Keeper_librarian_runtime.Queue_changed
            ~base_path ~keepers_dir ~keeper_id ~expected_revision:(Some seeded.revision) input));
    Alcotest.(check int) "real Librarian request" 1 (Fixture.post_count librarian);
    Alcotest.(check int) "JEV request count"
      (if Option.is_some (runtime_skip_reason scenario) then 0 else 1) (List.length !jev_requests);
    let run = match List.filter (fun (run : Runs.run) -> run.actor = keeper_id)
        (Runs.list_runs registry) with
      | [ run ] -> Runs.get registry ~run_id:run.run_id |> Option.get
      | _ -> Alcotest.fail "expected one actual Librarian run" in
    Alcotest.(check string) "Memory result remains distinct from JEV result"
      (if scenario = Memory_write_failure then "failed" else "succeeded")
      (Runs.status_label run.status);
    let original = Runs.run_to_yojson run in
    let encoded = Yojson.Safe.to_string ~std:true original in
    Alcotest.(check bool) "the complete durable report is valid UTF-8" true
      (String_util.is_valid_utf8 encoded);
    List.iter (fun secret ->
      Alcotest.(check bool) "configured URL credentials are absent from durable output" false
        (String_util.contains_substring encoded secret))
      [ "fixture-user"; "fixture-password"; "fixture-query"; "fixture-fragment" ];
    List.iter (fun target ->
      Alcotest.(check string) "outbound endpoint path remains unchanged" "/evaluate" (Uri.path target);
      Alcotest.(check (option string)) "outbound endpoint query remains unchanged"
        (Some "fixture-query") (Uri.get_query_param target "access")) !jev_targets;
    (match scenario with
     | Memory_write_failure ->
       let expected = match !observed_storage_error with
         | Some error -> "Librarian raised: " ^ error
         | None -> Alcotest.fail "the storage failure was not observed" in
       Alcotest.(check string) "the actual storage exception reaches run detail"
         expected
         (member "detail" original |> string)
     | Judged_run | Gate_disabled_run | Excluded_run | Lane_disabled_run | Missing_key_run | Http_failure | Invalid_json_run | Invalid_response_run | Nonfinite_response_run | Duplicate_response_run | Nonutf8_response_run | Invalid_answer_run -> ());
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
      | Gate_disabled_run | Excluded_run | Lane_disabled_run | Missing_key_run -> "skipped"
      | Http_failure | Invalid_json_run | Invalid_response_run | Nonfinite_response_run | Duplicate_response_run | Nonutf8_response_run | Invalid_answer_run -> "failed" in
    Alcotest.(check string) "gate status" expected_status (member "status" gate |> string);
    (match scenario with
     | Gate_disabled_run | Excluded_run | Lane_disabled_run | Missing_key_run ->
       Alcotest.(check string) "the actual unavailability is retained"
         (Option.get (runtime_skip_reason scenario)) (member "reason" gate |> string);
       check_json "a skipped gate has no applied boundary" `Null
         (member "conveyed_boundary" gate);
       check_json "no invented evaluations" `Null (member "evaluations" gate)
     | Judged_run | Http_failure | Invalid_json_run | Invalid_response_run | Nonfinite_response_run | Duplicate_response_run | Nonutf8_response_run
  | Invalid_answer_run | Memory_write_failure ->
       Alcotest.(check (float 0.)) "the gate records the applied probability boundary"
         Gate.conveyed_boundary
         (member "conveyed_boundary" gate |> Yojson.Safe.Util.to_float);
       let evaluation = match member "evaluations" gate with
         | `List [ evaluation ] -> evaluation
         | _ -> Alcotest.fail "expected the one actual JEV evaluation" in
       let raw = List.hd !jev_requests in
       let sent = Yojson.Safe.from_string raw in
       let request = member "request" evaluation in
       let asked = match member "destinations" request |> Yojson.Safe.Util.to_list with
         | [ destination ] -> destination
         | destinations -> Alcotest.failf "one destination, %d listed" (List.length destinations) in
       Alcotest.(check string) "endpoint observation omits userinfo/query/fragment" displayed_jev_uri
         (member "destination_uri" asked |> string);
       check_json "actual JEV request model" (member "model" sent) (member "model" asked);
       List.iter (fun key -> check_json ("actual JEV request " ^ key)
         (member key sent) (member key request)) [ "state"; "questions" ];
       Alcotest.(check string) "the configured request model was sent" requested_model
         (member "model" sent |> string);
       (match scenario with
        | Http_failure ->
          let reason = Printf.sprintf "typesafeai: HTTP 503 returned by %s: fixture unavailable" displayed_jev_uri in
          Alcotest.(check string) "original HTTP failure" reason (member "reason" gate |> string);
          Alcotest.(check string) "evaluation failure" "failed" (member "status" evaluation |> string);
          Alcotest.(check string) "same evaluation failure" reason (member "reason" evaluation |> string);
          let failure = member "failure" evaluation in
          Alcotest.(check string) "the walk records every destination asked" "every_destination_refused"
            (member "kind" failure |> string);
          let refusal = match member "attempts" failure |> Yojson.Safe.Util.to_list with
            | [ attempt ] -> member "refusal" attempt
            | attempts -> Alcotest.failf "one destination, %d attempts" (List.length attempts) in
          Alcotest.(check int) "actual HTTP failure status" 503 (member "status" refusal |> Yojson.Safe.Util.to_int);
          Alcotest.(check string) "actual HTTP failure body" "fixture unavailable" (member "body" refusal |> string);
          List.iter (fun key -> check_json ("failure does not invent " ^ key)
            `Null (member key evaluation)) [ "model"; "answers"; "request_body_sha256" ]
        | Invalid_json_run | Invalid_response_run | Nonfinite_response_run | Duplicate_response_run | Nonutf8_response_run ->
          Alcotest.(check string) "a rejected HTTP response is a failed evaluation" "failed"
            (member "status" evaluation |> string);
          let refusal = match member "failure" evaluation |> member "attempts" |> Yojson.Safe.Util.to_list with
            | [ attempt ] -> member "refusal" attempt
            | attempts -> Alcotest.failf "one destination, %d attempts" (List.length attempts) in
          Alcotest.(check string) "HTTP and transport failures remain distinct" "http_response"
            (member "kind" refusal |> string);
          Alcotest.(check int) "actual successful HTTP status survives decoding failure" 200
            (member "status" refusal |> Yojson.Safe.Util.to_int);
          let original_body = Option.get (invalid_response_body scenario) in
          let body = member "body" refusal in
          let restored = match body with
            | `String body -> body
            | body ->
              Alcotest.(check string) "binary evidence is explicitly encoded" "base64"
                (member "encoding" body |> string);
              Alcotest.(check int) "binary evidence records its original length"
                (String.length original_body)
                (member "total_bytes" body |> Yojson.Safe.Util.to_int);
              Base64.decode_exn (member "content" body |> string)
          in
          Alcotest.(check string) "the exact returned body survives durable replay"
            original_body restored;
          Alcotest.(check string) "failure destination is retained for all consumers"
            displayed_jev_uri (member "destination_uri" refusal |> string);
          Alcotest.(check bool) "typed failure diagnostic is retained" true
            (String.length (member "detail" refusal |> string) > 0);
          List.iter (fun key -> check_json ("decode failure does not invent " ^ key)
            `Null (member key evaluation)) [ "model"; "answers"; "request_body_sha256" ]
        | Invalid_answer_run ->
          Alcotest.(check string) "gate rejection is not transport failure" "invalid_answer"
            (member "status" evaluation |> string);
          check_json "every typed returned answer survives durable replay"
            (`Assoc returned_answers) (member "returned_answers" evaluation);
          check_json "no validated score map for an invalid response" `Null
            (member "answers" evaluation)
        | Judged_run | Memory_write_failure ->
          Alcotest.(check string) "answered evaluation" "answered" (member "status" evaluation |> string);
          Alcotest.(check string) "actual answer model" "jev-fixture" (member "model" evaluation |> string);
          Alcotest.(check string) "destination observation is sanitized" displayed_jev_uri (member "destination_uri" evaluation |> string);
          Alcotest.(check string) "actual HTTP request digest"
            Digestif.SHA256.(digest_string raw |> to_hex)
            (member "request_body_sha256" evaluation |> string);
          List.iter (fun (qid, expected) ->
            Alcotest.(check (float 0.)) ("raw probability " ^ qid) expected
              (member qid (member "answers" evaluation) |> Yojson.Safe.Util.to_float))
            [ "s0_0", 1.0; "s1_0", 0.0 ]
        | Gate_disabled_run | Excluded_run | Lane_disabled_run | Missing_key_run -> Alcotest.fail "disabled scenario cannot evaluate"));
    (match scenario with
     | Memory_write_failure ->
       Unix.rmdir current_path;
       Unix.rename saved_path current_path
     | Judged_run | Gate_disabled_run | Excluded_run | Lane_disabled_run | Missing_key_run | Http_failure | Invalid_json_run | Invalid_response_run | Nonfinite_response_run | Duplicate_response_run | Nonutf8_response_run | Invalid_answer_run -> ());
    let stored = match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require with
      | Some snapshot -> snapshot
      | None -> Alcotest.fail "current snapshot is missing" in
    let expected_facts = match scenario with
      | Judged_run -> b :: untouched :: selection.new_claims
      | Gate_disabled_run | Excluded_run | Lane_disabled_run | Missing_key_run -> untouched :: selection.new_claims
      | Http_failure | Invalid_json_run | Invalid_response_run | Nonfinite_response_run | Duplicate_response_run | Nonutf8_response_run | Invalid_answer_run -> seeded.facts @ selection.new_claims
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
      | Gate_disabled_run | Excluded_run | Lane_disabled_run | Missing_key_run -> [ a.claim; b.claim ]
      | Http_failure | Invalid_json_run | Invalid_response_run | Nonfinite_response_run | Duplicate_response_run | Nonutf8_response_run | Invalid_answer_run -> []
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
    [ Judged_run; Gate_disabled_run; Lane_disabled_run; Missing_key_run; Excluded_run
    ; Http_failure; Invalid_json_run; Invalid_response_run; Nonfinite_response_run
    ; Duplicate_response_run; Nonutf8_response_run
    ; Invalid_answer_run; Memory_write_failure ]
;;

let test_selection_gate_and_store_keep_the_unconveyed_original () =
  run_runtime_evidence ()
;;

(* A noul is a probability. A value outside [0, 1] is a response-shape
   failure; it cannot authorize absorption by reading 2.0 as "conveyed". *)
let test_a_noul_outside_the_unit_interval_keeps_the_source () =
  let facts = [ fact (List.hd sources) ] in
  let absorbed = absorbed_into merged facts in
  let evaluate, _, _ = table ~noul_of:(fun _ -> 2.0) in
  match Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed with
  | Gate.Failed _ -> ()
  | Gate.Judged _ -> Alcotest.fail "2.0 is not a probability"
;;

(* A verdict reached before a later request fails stays reached: the source
   a completed answer showed not conveyed is kept current, the source the
   failure left unresolved also stays current. *)
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
  | Gate.Failed { absorbed = applied; left; _ } ->
    Alcotest.(check (list string)) "the rejected source stays current"
      [ id first ]
      (List.map (fun (v : Gate.source_verdict) -> v.memory_id) left);
    Alcotest.(check (list string)) "the unresolved source also stays current"
      []
      (List.map (fun (s : Types.absorbed_statement) -> s.absorbed) applied)
  | Gate.Judged _ -> Alcotest.fail "expected failed judgment"
;;

let test_a_conveyed_verdict_survives_a_later_failure () =
  let first = fact (List.nth sources 0) in
  let second = fact (List.nth sources 1) in
  let other = fact "gamma restarts nightly and keeps its logs for a week" in
  let absorbed = absorbed_into merged [ first ] @ absorbed_into other [ second ] in
  let calls = ref 0 in
  let evaluate ~state:_ ~questions =
    incr calls;
    if !calls = 1 then
      Ok { T.model = "jev-test"; usage = None
         ; answers = List.map (fun (qid, _) -> qid, T.Noul_answer { T.noul = 1.0 }) questions }
    else Error "HTTP 529"
  in
  let outcome = Gate.judge ~evaluate ~facts:[ first; second ]
      ~new_claims:[ merged; other ] ~absorbed in
  let run = Gate.Evaluated { outcome; evaluations = [] } in
  Alcotest.(check (list string)) "only completed positive absorptions apply"
    [ id first ]
    (List.map (fun (s : Types.absorbed_statement) -> s.absorbed) (Gate.absorbed_of_run run));
  let report = Gate.run_result_to_yojson run in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "the failed second request remains observable" "failed"
    (member "status" report |> to_string);
  let conveyed = match member "conveyed" report with
    | `List verdicts -> List.map (fun verdict -> member "memory_id" verdict |> to_string) verdicts
    | _ -> Alcotest.fail "failed report lost the completed positive verdict" in
  Alcotest.(check (list string)) "only the completed positive verdict is reported"
    [ id first ] conveyed
;;

let test_failure_preserves_unjudged_from_unvisited_groups () =
  let source = fact (List.hd sources) in
  let missing_source : Types.absorbed_statement = { absorbed = "absent-source"; into = id merged } in
  let missing_claim : Types.absorbed_statement = { absorbed = id source; into = "absent-claim" } in
  let absorbed = absorbed_into merged [ source ] @ [ missing_source; missing_claim ] in
  let outcome = Gate.judge ~evaluate:(fun ~state:_ ~questions:_ -> Error "HTTP 503")
      ~facts:[ source ] ~new_claims:[ merged ] ~absorbed in
  let run = Gate.Evaluated { outcome; evaluations = [] } in
  Alcotest.(check int) "all unconfirmed sources remain current" 0
    (List.length (Gate.absorbed_of_run run));
  let report = Gate.run_result_to_yojson run in
  let open Yojson.Safe.Util in
  let actual = match member "unjudged" report with
    | `List values -> List.map (fun value ->
        member "absorbed" value |> to_string, member "into" value |> to_string) values
    | _ -> Alcotest.fail "failed report lost classified unjudged absorptions" in
  Alcotest.(check (list (pair string string)))
    "classified missing source and later missing claim are distinct from request failure"
    [ missing_source.absorbed, missing_source.into; missing_claim.absorbed, missing_claim.into ] actual
;;

let with_gate_http_fixture f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
  @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "synthetic-jev-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    { Runtime_schema.default_typesafeai with absorb_gate = true } @@ fun () ->
  f ~sw ~net ~clock
;;

let test_transport_diagnostics_preserve_cause_without_configured_credentials () =
  let module Client = Masc.Typesafeai_client in
  let endpoint =
    "http://fixture-user:fixture-password@example.test/evaluate?access=fixture-query#fixture-fragment"
  in
  let normalized = Uri.of_string endpoint |> Uri.to_string in
  let displayed = "http://example.test/evaluate" in
  let api_key = "plain-api-key-without-a-known-secret-prefix" in
  List.iter (fun cause ->
    let detail = Printf.sprintf "%s url=%s normalized=%s key=%s"
        cause endpoint normalized api_key in
    let failure = Client.For_testing.transport_failure ~endpoint ~api_key detail in
    let rendered = Client.refusal_to_string failure in
    Alcotest.(check string) "diagnostic cause and safe destination remain"
      (Printf.sprintf "typesafeai: transport failure: %s url=%s normalized=%s key=[REDACTED]"
         cause displayed displayed) rendered;
    let json = Client.refusal_to_yojson failure in
    let open Yojson.Safe.Util in
    Alcotest.(check string) "transport failure has its own type" "transport"
      (member "kind" json |> to_string);
    Alcotest.(check bool) "a transport failure has no HTTP response"
      true (member "body" json = `Null && member "status" json = `Null);
    ignore (Yojson.Safe.to_string ~std:true json : string))
    [ "DNS lookup failed"; "connect ECONNREFUSED"; "request timeout" ]
;;

let test_failure_bodies_omit_configured_credentials () =
  with_gate_http_fixture @@ fun ~sw ~net ~clock ->
  let module Client = Masc.Typesafeai_client in
  let open Yojson.Safe.Util in
  let socket = Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | _ -> Alcotest.fail "fixture has no TCP address" in
  let displayed = Printf.sprintf "http://127.0.0.1:%d/evaluate" port in
  let endpoint = Printf.sprintf
    "http://fixture-user:fixture-password@127.0.0.1:%d/evaluate?access=fixture-query#fixture-fragment" port in
  let api_key = "plain-api-key-without-a-known-secret-prefix" in
  let reply = ref (`Service_unavailable, "") in
  let handler _ request body =
    ignore (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) : string);
    Alcotest.(check (option string)) "the actual request retains its configured authorization"
      (Some ("Bearer " ^ api_key)) (Cohttp.Header.get (Cohttp.Request.headers request) "authorization");
    Alcotest.(check (option string)) "the actual request retains its configured query"
      (Some "fixture-query") (Uri.get_query_param (Cohttp.Request.uri request) "access");
    let status, body = !reply in
    Cohttp_eio.Server.respond_string ~status ~body () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket (Cohttp_eio.Server.make ~callback:handler ())
      ~on_error:(fun exn -> Alcotest.fail (Printexc.to_string exn)));
  List.iter (fun (status, suffix) ->
    reply := status, "gateway echo " ^ api_key ^ " url=" ^ endpoint ^ suffix;
    let destination = { Client.endpoint; model = "gateway-echo-model"; api_key } in
    let failure =
      match Client.evaluate ~clock ~destinations:(destination, []) ~state:`Null ~questions:[] () with
      | Error failure ->
        (match Client.attempts failure with
         | [ attempt ] -> attempt.refusal
         | asked -> Alcotest.failf "one destination, %d attempts" (List.length asked))
      | Ok _ -> Alcotest.fail "the gateway response must remain a typed failure" in
    let expected = "gateway echo [REDACTED] url=" ^ displayed ^ suffix in
    (match failure with
     | Client.Http_response_failure { body; destination_uri; _ } ->
       Alcotest.(check string) "the typed observation already omits known credentials" expected body;
       Alcotest.(check string) "the typed destination is safe" displayed destination_uri
     | Client.Transport_failure detail -> Alcotest.fail detail);
    let json = Client.refusal_to_yojson failure in
    let body = member "body" json in
    let decoded = match body with
      | `String body -> body
      | _ -> Base64.decode_exn (member "content" body |> to_string) in
    Alcotest.(check string) "encoded evidence retains other bytes, including invalid UTF-8"
      expected decoded;
    let encoded = Yojson.Safe.to_string ~std:true json in
    Alcotest.(check bool) "the saved failure is valid UTF-8" true (String_util.is_valid_utf8 encoded))
    [ `Service_unavailable, " service unavailable"
    ; `OK, " invalid JSON"
    ; `OK, String.make 1 (Char.chr 255) ]
;;

(* Two destinations: the first does not answer, the reserve does. The record
   says who answered, which model it was asked for, and who was passed over. *)
let test_run_records_the_destination_passed_over () =
  with_gate_http_fixture @@ fun ~sw ~net ~clock ->
  let module F = Exact_output_fixture in
  let module J = Yojson.Safe.Util in
  let response = {|{"model":"response-model","answers":{"s0_0":{"type":"noul","noul":1.0}}}|} in
  let reserve = F.start_server ~sw ~net ~clock (F.Reply response) in
  let closed = "http://127.0.0.1:9/never-reached" in
  let reserve_key = "MASC_TEST_TYPESAFEAI_RESERVE_KEY" in
  Masc_test_deps.with_process_env reserve_key (Some "synthetic-reserve-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    { (Runtime_typesafeai_policy.current ()) with
      destinations =
        ( { Runtime_schema.endpoint = closed
          ; model = "first-model"
          ; api_key_env = "TYPESAFEAI_API_KEY"
          }
        , [ { Runtime_schema.endpoint = reserve.base_url
            ; model = "reserve-model"
            ; api_key_env = reserve_key
            }
          ] )
    } @@ fun () ->
  let first = fact (List.nth sources 0) in
  let absorbed = absorbed_into merged [ first ] in
  let run = Gate.run ~clock ~keeper_id:"reserve-fixture" ~facts:[ first ]
      ~new_claims:[ merged ] ~absorbed () in
  let report = Gate.run_result_to_yojson run in
  match J.member "evaluations" report |> J.to_list with
  | [ evaluation ] ->
    Alcotest.(check string) "answered by the reserve" reserve.base_url
      (J.member "destination_uri" evaluation |> J.to_string);
    Alcotest.(check string) "with the model the reserve was asked for" "reserve-model"
      (J.member "requested_model" evaluation |> J.to_string);
    (match J.member "passed_over" evaluation |> J.to_list with
     | [ attempt ] ->
       Alcotest.(check string) "the first destination stays on record" closed
         (J.member "destination_uri" attempt |> J.to_string);
       Alcotest.(check string) "as the transport refusal it was" "transport"
         (J.member "refusal" attempt |> J.member "kind" |> J.to_string)
     | attempts -> Alcotest.failf "one passed-over attempt, got %d" (List.length attempts));
    Alcotest.(check int) "both armed destinations are listed as asked" 2
      (J.member "request" evaluation |> J.member "destinations" |> J.to_list |> List.length);
    let sent = List.hd (F.request_bodies reserve) |> Yojson.Safe.from_string in
    Alcotest.(check string) "the reserve read its own model id" "reserve-model"
      (J.member "model" sent |> J.to_string)
  | evaluations -> Alcotest.failf "one evaluation, got %d" (List.length evaluations)
;;

let test_run_uses_one_destination_and_model_snapshot () =
  with_gate_http_fixture @@ fun ~sw ~net ~clock ->
  let module F = Exact_output_fixture in
  let response = {|{"model":"response-model","answers":{"s0_0":{"type":"noul","noul":1.0}}}|} in
  let alternate = F.start_server ~sw ~net ~clock (F.Reply response) in
  let initial = F.start_server ~sw ~net ~clock
      ~on_request_before_reply:(fun () ->
        (* A new table published mid-run must not move the run's requests. *)
        Runtime_typesafeai_policy.publish
          { (Runtime_typesafeai_policy.current ()) with
            destinations =
              ( { Runtime_schema.endpoint = alternate.base_url
                ; model = "changed-after-first-request"
                ; api_key_env = "TYPESAFEAI_API_KEY"
                }
              , [] )
          })
      (F.Reply response) in
  let configured_endpoint = initial.base_url ^ "?access=fixture-query#fixture-fragment" in
  Masc_test_deps.with_typesafeai_policy
    { (Runtime_typesafeai_policy.current ()) with
      destinations =
        ( { Runtime_schema.endpoint = configured_endpoint
          ; model = "initial-request-model"
          ; api_key_env = "TYPESAFEAI_API_KEY"
          }
        , [] )
    } @@ fun () ->
  let first = fact (List.nth sources 0) in
  let second = fact (List.nth sources 1) in
  let other = fact "beta ships on fridays and pages the operator" in
  let absorbed = absorbed_into merged [ first ] @ absorbed_into other [ second ] in
  let observations = ref [] in
  let run = Gate.run ~clock ~keeper_id:"snapshot-fixture" ~facts:[ first; second ]
      ~observe:(fun observation -> observations := observation :: !observations)
      ~new_claims:[ merged; other ] ~absorbed () in
  (match run with
   | Gate.Skipped _ -> Alcotest.fail "expected evaluations"
   | Gate.Evaluated { evaluations; _ } ->
     List.iter (fun (evaluation : Gate.evaluation) ->
       match evaluation.destinations with
       | [ asked ] ->
         Alcotest.(check string) "typed evaluation has an observation endpoint"
           initial.base_url asked.destination_uri
       | asked -> Alcotest.failf "one destination, %d listed" (List.length asked)) evaluations);
  let report = Gate.run_result_to_yojson run in
  (match List.rev !observations with
   | [ Gate.Incomplete [ first ]; Gate.Incomplete [ again; second ]; Gate.Complete final ] ->
     Alcotest.(check string) "first completed response is retained in the next snapshot"
       (Yojson.Safe.to_string first.state) (Yojson.Safe.to_string again.state);
     Alcotest.(check (list string)) "completed requests stay in dispatch order"
       [ merged.claim; other.claim ]
       (List.map (fun (e : Gate.evaluation) -> Yojson.Safe.Util.to_string e.state) [ first; second ]);
     Alcotest.(check string) "final observation is the actual unchanged result"
       (Yojson.Safe.to_string report) (Gate.run_result_to_yojson final |> Yojson.Safe.to_string)
   | _ -> Alcotest.fail "expected two incremental observations and one final result");
  Alcotest.(check int) "both requests use the endpoint captured before dispatch" 2 (F.post_count initial);
  Alcotest.(check int) "the later configuration is not used by this run" 0 (F.post_count alternate);
  let open Yojson.Safe.Util in
  List.iter (fun raw ->
    Alcotest.(check string) "every transmitted model is the initial snapshot"
      "initial-request-model" (Yojson.Safe.from_string raw |> member "model" |> to_string))
    (F.request_bodies initial);
  List.iter (fun evaluation ->
    let asked = match member "request" evaluation |> member "destinations" |> to_list with
      | [ destination ] -> destination
      | destinations -> Alcotest.failf "one destination, %d listed" (List.length destinations) in
    Alcotest.(check string) "reported endpoint is the transmitted snapshot" initial.base_url
      (member "destination_uri" asked |> to_string);
    Alcotest.(check string) "reported model is the transmitted snapshot" "initial-request-model"
      (member "model" asked |> to_string))
    (member "evaluations" report |> to_list)
;;

exception Cancel_gate_fixture

let test_cancelled_next_request_keeps_the_completed_observation () =
  with_gate_http_fixture @@ fun ~sw ~net ~clock ->
  let module F = Exact_output_fixture in
  let second_started, resolve_second_started = Eio.Promise.create () in
  let release_second, resolve_release_second = Eio.Promise.create () in
  (* Assertion failures also release the held handler; normal completion may
     already have released it. *)
  Eio.Switch.on_release sw (fun () ->
    ignore (Eio.Promise.try_resolve resolve_release_second ()));
  let calls = ref 0 in
  let response = {|{"model":"response-model","answers":{"s0_0":{"type":"noul","noul":0.9}}}|} in
  let server = F.start_server ~sw ~net ~clock
      ~on_request_before_reply:(fun () ->
        incr calls;
        if !calls = 2 then begin
          Eio.Promise.resolve resolve_second_started ();
          Eio.Promise.await release_second
        end)
      (F.Reply response) in
  Masc_test_deps.with_typesafeai_policy
    { (Runtime_typesafeai_policy.current ()) with
      destinations =
        ( { Runtime_schema.endpoint = server.base_url; model = "request-model"; api_key_env = "TYPESAFEAI_API_KEY" }
        , [] )
    } @@ fun () ->
  let first = fact (List.nth sources 0) in
  let second = fact (List.nth sources 1) in
  let other = fact "beta ships on fridays and pages the operator" in
  let observed = ref [] in
  let raised_by_gate = ref false in
  let returned = ref false in
  let context, resolve_context = Eio.Promise.create () in
  let finished, resolve_finished = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    (try
       Eio.Cancel.sub (fun cancellation ->
         Eio.Promise.resolve resolve_context cancellation;
         match Gate.run ~clock ~keeper_id:"cancel-observation-fixture"
             ~observe:(fun observation -> observed := observation :: !observed)
             ~facts:[ first; second ] ~new_claims:[ merged; other ]
             ~absorbed:(absorbed_into merged [ first ] @ absorbed_into other [ second ]) () with
         | _ -> returned := true
         | exception (Eio.Cancel.Cancelled Cancel_gate_fixture as exn) ->
           raised_by_gate := true;
           raise exn)
     with Eio.Cancel.Cancelled Cancel_gate_fixture -> ());
    Eio.Promise.resolve resolve_finished ());
  let await label promise =
    F.await_within_fixture_budget ~clock ~failure:label promise in
  let cancellation = await "gate cancellation context" context in
  await "second HTTP request started" second_started;
  Eio.Cancel.cancel cancellation Cancel_gate_fixture;
  await "cancelled gate finished" finished;
  Eio.Promise.resolve resolve_release_second ();
  Alcotest.(check bool) "Gate.run itself propagates the original cancellation" true !raised_by_gate;
  Alcotest.(check bool) "cancellation is not turned into a returned disposition" false !returned;
  Alcotest.(check int) "the second request reached HTTP before cancellation" 2 (F.post_count server);
  match List.rev !observed with
  | [ Gate.Incomplete [ evaluation ] as observation ] ->
    let sent = List.hd (F.request_bodies server) in
    let asked = match evaluation.destinations with
      | [ asked ] -> asked
      | asked -> Alcotest.failf "one destination, %d listed" (List.length asked) in
    Alcotest.(check string) "completed request destination remains inspectable"
      server.base_url asked.destination_uri;
    Alcotest.(check string) "completed request model remains inspectable"
      "request-model" asked.model;
    let request = T.request_to_yojson ~model:asked.model
        ~state:evaluation.state ~questions:evaluation.questions in
    Alcotest.(check string) "the completed request context is the HTTP body"
      (Yojson.Safe.from_string sent |> Yojson.Safe.to_string) (Yojson.Safe.to_string request);
    (match evaluation.result with
     | Ok evaluated ->
       Alcotest.(check string) "completed response hash identifies the sent bytes"
         Digestif.SHA256.(digest_string sent |> to_hex) evaluated.request_body_sha256;
       (match evaluated.response.answers with
        | [ "s0_0", T.Noul_answer { noul } ] ->
          Alcotest.(check (float 0.)) "raw completed Noul survives cancellation" 0.9 noul
        | _ -> Alcotest.fail "completed typed response was lost")
     | Error failure -> Alcotest.fail (Masc.Typesafeai_client.failure_to_string failure));
    let report = Gate.observation_to_yojson observation in
    let open Yojson.Safe.Util in
    Alcotest.(check string) "the report is explicitly incomplete" "incomplete"
      (member "status" report |> to_string);
    Alcotest.(check int) "no response is invented for the cancelled request" 1
      (member "evaluations" report |> to_list |> List.length);
    List.iter (fun field ->
      Alcotest.(check bool) ("no final " ^ field) true (member field report = `Null))
      [ "applied_absorptions"; "conveyed"; "left"; "conveyed_boundary" ]
  | _ -> Alcotest.fail "cancellation must leave one incomplete snapshot and no Complete"
;;

let test_skipped_run_publishes_its_completed_observation () =
  let observed = ref [] in
  let run = Gate.run ~keeper_id:"empty-observation-fixture" ~facts:[] ~new_claims:[]
      ~absorbed:[] ~observe:(fun value -> observed := value :: !observed) () in
  match !observed with
  | [ Gate.Complete result ] ->
    Alcotest.(check string) "a skipped run is complete, not an interrupted evaluation"
      (Gate.run_result_to_yojson run |> Yojson.Safe.to_string)
      (Gate.observation_to_yojson (Gate.Complete result) |> Yojson.Safe.to_string)
  | _ -> Alcotest.fail "skipped run did not publish exactly one completed observation"
;;

(* A keeper named in [typesafeai].excluded_keepers: the run is skipped by
   that name, every absorption is applied as answered, and nothing is sent,
   whatever the key says. *)
let test_an_excluded_keeper_is_applied_as_answered_without_a_request () =
  let facts = List.map fact sources in
  let absorbed = absorbed_into merged facts in
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "synthetic-jev-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    { Runtime_schema.default_typesafeai with
      destinations =
        ( { Runtime_schema.typesafe_destination with endpoint = "http://127.0.0.1:9/never-reached" }
        , [] )
    ; absorb_gate = true
    ; excluded_keepers = [ "kept-home" ]
    } @@ fun () ->
  match Gate.run ~keeper_id:"kept-home" ~facts ~new_claims:[ merged ] ~absorbed () with
  | Gate.Skipped { reason = Gate.Unavailable Masc.Typesafeai_config.Keeper_excluded; absorbed = applied } ->
    Alcotest.(check int) "every absorption is applied" (List.length absorbed) (List.length applied)
  | Gate.Skipped { reason = Gate.No_absorptions | Gate.Unavailable _; _ } ->
    Alcotest.fail "the run was skipped for a reason other than the exclusion"
  | Gate.Evaluated _ -> Alcotest.fail "an excluded keeper's memories were sent"
;;

let test_rejected_response_retains_every_typed_answer () =
  with_gate_http_fixture @@ fun ~sw ~net ~clock ->
  let module F = Exact_output_fixture in
  let noul value = `Assoc [ "type", `String "noul"; "noul", `Float value ] in
  let choice = `Assoc [ "type", `String "choice"; "choice", `String "yes"
    ; "probabilities", `Assoc [ "yes", `Float 0.7; "no", `Float 0.3 ]
    ; "confidence", `Float 0.8 ] in
  let score = `Assoc [ "type", `String "score"; "score", `Float 1.25
    ; "probabilities", `Assoc [ "2", `Float 0.25; "1", `Float 0.75 ]
    ; "confidence", `Float 0.5 ] in
  let cases =
    [ "missing ID", `Assoc [ "s0_0", noul 0.9; "extra", score ]
    ; "wrong type", `Assoc [ "s0_0", choice; "s1_0", noul 0.6 ]
    ; "out of range", `Assoc [ "s0_0", noul 1.2; "s1_0", noul 0.6 ] ] in
  let server = F.start_server ~sw ~net ~clock (F.Replies
    (List.map (fun (_, answers) -> Yojson.Safe.to_string
       (`Assoc [ "model", `String "invalid-response-model"; "answers", answers ])) cases)) in
  Masc_test_deps.with_typesafeai_policy
    { (Runtime_typesafeai_policy.current ()) with
      destinations = ({ Runtime_schema.typesafe_destination with endpoint = server.base_url }, []) }
  @@ fun () ->
  let facts = List.map fact sources in
  List.iter (fun (label, expected) ->
    let run = Gate.run ~clock ~keeper_id:"invalid-answer-fixture" ~facts
        ~new_claims:[ merged ] ~absorbed:(absorbed_into merged facts) () in
    Alcotest.(check int) "invalid responses cannot authorize absorption" 0
      (List.length (Gate.absorbed_of_run run));
    let open Yojson.Safe.Util in
    let report = Gate.run_result_to_yojson run in
    Alcotest.(check string) (label ^ " fails judgment") "failed" (member "status" report |> to_string);
    let evaluation = member "evaluations" report |> to_list |> List.hd in
    Alcotest.(check string) (label ^ " is explicitly invalid") "invalid_answer"
      (member "status" evaluation |> to_string);
    Alcotest.(check string) (label ^ " retains all returned typed answers")
      (Yojson.Safe.to_string expected)
      (member "returned_answers" evaluation |> Yojson.Safe.to_string);
    Alcotest.(check bool) "invalid answers are not presented as validated scores" true
      (member "answers" evaluation = `Null)) cases
;;

(* The same inside one source: a statement not conveyed in an answered
   request keeps the source current when the next request fails. *)
let test_partial_source_before_failure ~first_rejected () =
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
              (fun k (qid, _) -> qid, T.Noul_answer { T.noul = (if first_rejected && k = 0 then 0.0 else 1.0) })
              questions
        }
    else Error "HTTP 529"
  in
  Alcotest.(check int) "the source cuts into more than one request"
    (Gate.questions_per_request + 1)
    (List.length (Gate.statements long.claim));
  match Gate.judge ~evaluate ~facts:[ long ] ~new_claims:[ merged ] ~absorbed with
  | Gate.Failed { absorbed = applied; left; _ } ->
    Alcotest.(check int) "two requests were attempted" 2 !calls;
    Alcotest.(check (list string)) "only completed negative evidence is reported"
      (if first_rejected then [ id long ] else [])
      (List.map (fun (v : Gate.source_verdict) -> v.memory_id) left);
    Alcotest.(check int) "nothing is applied" 0 (List.length applied)
  | Gate.Judged _ -> Alcotest.fail "expected failed judgment"
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
  | Gate.Failed { absorbed = applied; _ } ->
    Alcotest.(check (list string)) "neither oversized nor unconfirmed memory is absorbed"
      []
      (List.map (fun (s : Types.absorbed_statement) -> s.absorbed) applied)
  | Gate.Judged _ -> Alcotest.fail "expected failed judgment"
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
        ; Alcotest.test_case "the model not answering preserves the originals" `Quick
            test_the_model_not_answering_keeps_the_sources
        ; Alcotest.test_case "an absorption the pass cannot place goes through unjudged" `Quick
            test_an_absorption_the_pass_cannot_place_goes_through_unjudged
        ; Alcotest.test_case "statements are asked in bounded requests" `Quick
            test_statements_are_asked_in_bounded_requests
        ; Alcotest.test_case "a noul outside the unit interval keeps the source" `Quick
            test_a_noul_outside_the_unit_interval_keeps_the_source
        ; Alcotest.test_case "a statement too large to judge keeps its memory current" `Quick
            test_a_statement_too_large_to_judge_keeps_its_memory_current
        ; Alcotest.test_case "an oversized memory stays current when another request fails" `Quick
            test_an_oversized_memory_stays_current_when_another_request_fails
        ; Alcotest.test_case "a claim over the state bound keeps all its absorptions current" `Quick
            test_a_claim_over_the_state_bound_keeps_all_its_absorptions_current
        ; Alcotest.test_case "a rejection completed before a later failure is kept" `Quick
            test_a_rejection_completed_before_a_later_failure_is_kept
        ; Alcotest.test_case "a conveyed verdict survives a later failure" `Quick
            test_a_conveyed_verdict_survives_a_later_failure
        ; Alcotest.test_case "failure retains unjudged from unvisited groups" `Quick
            test_failure_preserves_unjudged_from_unvisited_groups
        ; Alcotest.test_case "one run uses one endpoint and model snapshot" `Quick
            test_run_uses_one_destination_and_model_snapshot
        ; Alcotest.test_case "a run records the destination passed over" `Quick
            test_run_records_the_destination_passed_over
        ; Alcotest.test_case "cancelled next request retains its completed observation" `Quick
            test_cancelled_next_request_keeps_the_completed_observation
        ; Alcotest.test_case "skipped run publishes its completed observation" `Quick
            test_skipped_run_publishes_its_completed_observation
        ; Alcotest.test_case "an excluded keeper is applied as answered without a request" `Quick
            test_an_excluded_keeper_is_applied_as_answered_without_a_request
        ; Alcotest.test_case "transport diagnostics retain cause without credentials" `Quick
            test_transport_diagnostics_preserve_cause_without_configured_credentials
        ; Alcotest.test_case "failure bodies omit configured credentials" `Quick
            test_failure_bodies_omit_configured_credentials
        ; Alcotest.test_case "invalid responses retain all typed answers" `Quick
            test_rejected_response_retains_every_typed_answer
        ; Alcotest.test_case "a rejection in an answered request survives the next failing" `Quick
            (test_partial_source_before_failure ~first_rejected:true)
        ; Alcotest.test_case "partly conveyed source stays current after next request fails" `Quick
            (test_partial_source_before_failure ~first_rejected:false)
        ; Alcotest.test_case "a missing seventeenth statement keeps the original" `Quick
            test_a_missing_seventeenth_statement_keeps_the_whole_memory
        ; Alcotest.test_case "selection gate and store preserve the original" `Quick
            test_selection_gate_and_store_keep_the_unconveyed_original
        ] )
    ]
;;
