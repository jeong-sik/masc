(* The absorb-gate counters (RFC-0517 §2.2) move once for each finished
   judgment. The runtime run counts itself. A captured continuation counts
   nothing: its owner stores the terminal and then calls [count_judgment]
   (test_keeper_librarian_addon_owner covers that owner). A reader's replay
   of a retained judgment counts nothing. Synthetic answers; they say nothing
   about judgment quality. *)

module Gate = Masc.Keeper_librarian_absorb_gate
module Metric_store = Masc.Otel_metric_store
module T = Masc.Typesafeai_types
module Types = Masc.Keeper_memory_os_types
module F = Exact_output_fixture
module J = Yojson.Safe.Util

let fact claim : Types.fact =
  Types.observed ~claim ~category:Types.Fact ~now:(Time_compat.now ())
    ~origin:{ kind = Types.Authored; trace_id = "" }
;;

let absorb (source : Types.fact) (claim : Types.fact) : Types.absorbed_statement =
  { Types.absorbed = Types.memory_id source; into = Types.memory_id claim }
;;

(* One judgment that reaches every forward outcome and every reverse verdict.
   [kept] is conveyed into its claim. [context] and [lossy] are left: the claim
   [copied] says nothing [context] does not (a copy), and [extended] says more
   than [lossy]. The pass never read [never_read], so its absorption is
   unjudged; [oversized] fits no request, so its absorption is unjudgeable.
   Neither claim of those two has a source to ask the reverse question of. *)
let kept = fact "the alpha service deploys every tuesday at nine in the morning"
let context = fact "the beta service ships on fridays and pages the operator on failure"
let lossy = fact "the gamma queue drains every hour and alerts the engineer on call"
let oversized = fact ("the delta archive keeps every record " ^ String.make Gate.request_bytes_limit 'd')
let never_read = fact "the epsilon cache was never read by this pass"
let kept_claim = fact "alpha deploys every tuesday at nine in the morning"
let copied = fact "beta ships on fridays and pages the operator on failure"
let extended = fact "gamma drains every hour, alerts on call and now retries twice"
let orphan = fact "epsilon cache entries expire after one full day"
let large = fact "the delta archive keeps every record for a full year"
let facts = [ kept; context; lossy; oversized ]
let new_claims = [ kept_claim; copied; extended; orphan; large ]

let absorbed =
  [ absorb kept kept_claim
  ; absorb context copied
  ; absorb lossy extended
  ; absorb never_read orphan
  ; absorb oversized large
  ]
;;

let cited_observations : Gate.cited_observations =
  List.map (fun claim -> Types.memory_id claim, []) new_claims
;;

let forward_choice source =
  match
    List.find_opt
      (fun ((fact : Types.fact), _) -> String.equal fact.claim source)
      [ kept, "mergeable"; context, "different_context"; lossy, "loses_knowledge" ]
  with
  | Some (_, choice) -> choice
  | None -> Alcotest.failf "the forward question named an unexpected source: %s" source
;;

let reverse_noul sources =
  if String.equal sources context.claim
  then 1.0
  else if String.equal sources lossy.claim
  then 0.0
  else Alcotest.failf "the reverse question named unexpected sources: %s" sources
;;

let choice_answer choice =
  T.Choice_answer
    { T.choice
    ; probabilities =
        List.map
          (fun option -> option, if String.equal option choice then 1. else 0.)
          [ "mergeable"; "different_context"; "loses_knowledge"; "uncertain" ]
    ; confidence = 1.
    }
;;

(* The fixture endpoint: each forward question by the source it names, each
   reverse question by the sources' text the request carries as its state. *)
let answer _index body =
  let request = Yojson.Safe.from_string body in
  let state = J.member "state" request in
  let answers =
    List.map
      (fun (question_id, question) ->
         let answer =
           match J.member "type" question |> J.to_string with
           | "choice" -> choice_answer (forward_choice (J.member "source_memory" state |> J.to_string))
           | "noul" -> T.Noul_answer { T.noul = reverse_noul (J.to_string state) }
           | kind -> Alcotest.failf "the gate asked a %s question" kind
         in
         question_id, T.answer_to_yojson answer)
      (J.member "questions" request |> J.to_assoc)
  in
  `OK, Yojson.Safe.to_string (`Assoc [ "model", `String "metrics-fixture"; "answers", `Assoc answers ])
;;

let source_cells =
  List.concat_map
    (fun outcome ->
       List.map
         (fun decision -> outcome ^ "/" ^ decision, [ "outcome", outcome; "decision", decision ])
         [ "mergeable"; "different_context"; "loses_knowledge"; "uncertain"; "none" ])
    [ "conveyed"; "left"; "unjudged"; "unjudgeable" ]
;;

let verdict_cells =
  List.map (fun verdict -> verdict, [ "verdict", verdict ]) [ "copy"; "carries_new_statement"; "not_judged" ]
;;

(* Every cell of [metric] for [keeper] that holds a count, as "cell count". *)
let moved metric keeper cells =
  List.filter_map
    (fun (cell, labels) ->
       let value =
         Metric_store.metric_value_or_zero (Keeper_metrics.to_string metric) ~labels:(("keeper", keeper) :: labels) ()
       in
       if Float.equal value 0. then None else Some (Printf.sprintf "%s %g" cell value))
    cells
;;

let check_moved ~what keeper ~sources ~copy_checks =
  Alcotest.(check (list string)) (what ^ ": sources by outcome and choice") sources
    (moved Keeper_metrics.LibrarianAbsorbSources keeper source_cells);
  Alcotest.(check (list string)) (what ^ ": copy checks by verdict") copy_checks
    (moved Keeper_metrics.LibrarianAbsorbCopyChecks keeper verdict_cells)
;;

let one_judgment_sources =
  [ "conveyed/mergeable 1"
  ; "left/different_context 1"
  ; "left/loses_knowledge 1"
  ; "unjudged/none 1"
  ; "unjudgeable/none 1"
  ]
;;

let one_judgment_checks = [ "copy 1"; "carries_new_statement 1"; "not_judged 2" ]

let require_replay = function
  | Ok result -> result
  | Error error -> Alcotest.fail (Gate.replay_error_to_string error)
;;

let test_each_path_counts_its_judgment_once () =
  let runtime_keeper = "absorb-metrics-runtime"
  and captured_keeper = "absorb-metrics-captured" in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env
  and clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "synthetic-jev-key") @@ fun () ->
  let server = F.start_server ~sw ~net ~clock (F.Reply_with answer) in
  Masc_test_deps.with_typesafeai_policy
    { Runtime_schema.default_typesafeai with
      absorb_gate = true
    ; destinations =
        ( { Runtime_schema.endpoint = server.base_url
          ; model = "metrics-model"
          ; api_key_env = "TYPESAFEAI_API_KEY"
          }
        , [] )
    }
  @@ fun () ->
  (match
     Gate.run ~clock ~keeper_id:runtime_keeper ~cited_observations ~facts ~new_claims ~superseding:[] ~absorbed ()
   with
   | Gate.Evaluated _ -> ()
   | Gate.Skipped _ -> Alcotest.fail "the runtime run must judge its absorptions");
  check_moved ~what:"the runtime run" runtime_keeper ~sources:one_judgment_sources
    ~copy_checks:one_judgment_checks;
  check_moved ~what:"the captured Keeper before its run" captured_keeper ~sources:[] ~copy_checks:[];
  let live = Gate.resolve ~keeper_id:captured_keeper in
  let guidance =
    match Gate.guidance_of_authority live with
    | Ok guidance -> guidance
    | Error detail -> Alcotest.fail detail
  in
  let authority = Gate.replay_authority live in
  let transcript = ref [] in
  let captured =
    Gate.continue_captured ~request_clock:(fun () -> Ok clock) ~guidance ~keeper_id:captured_keeper ~authority
      ~live_authority:(Some live) ~evaluations:[]
      ~before_evaluate:(fun ~direction ~destinations ~state ~questions ->
        Gate.evaluation_request_to_yojson ~direction ~destinations ~state ~questions)
      ~after_evaluate:(fun ~evaluation_id evaluation ->
        transcript :=
          !transcript
          @ [ { Gate.request = evaluation_id; returned = Some (Gate.evaluation_evidence_to_yojson evaluation) } ])
      ~on_evaluation_aborted:(fun ~evaluation_id:_ _ -> Alcotest.fail "no captured request should abort")
      ~cited_observations ~facts ~new_claims ~superseding:[] ~absorbed ()
    |> require_replay
  in
  check_moved ~what:"the captured continuation before its terminal is stored" captured_keeper ~sources:[]
    ~copy_checks:[];
  Gate.count_judgment ~keeper_id:captured_keeper captured;
  check_moved ~what:"the captured judgment once its owner counts it" captured_keeper
    ~sources:one_judgment_sources ~copy_checks:one_judgment_checks;
  check_moved ~what:"the runtime Keeper after the captured run" runtime_keeper ~sources:one_judgment_sources
    ~copy_checks:one_judgment_checks;
  Alcotest.(check int) "each path asked three forward and two reverse questions" 10 (F.post_count server);
  let replayed =
    Gate.restore ~guidance ~authority ~cited_observations ~facts ~new_claims ~superseding:[] ~absorbed
      ~evaluations:!transcript
    |> require_replay
  in
  Alcotest.(check string) "the replay rederives the captured judgment"
    (Gate.run_result_to_yojson captured |> Yojson.Safe.to_string)
    (Gate.run_result_to_yojson replayed |> Yojson.Safe.to_string);
  check_moved ~what:"the captured Keeper after a replay" captured_keeper ~sources:one_judgment_sources
    ~copy_checks:one_judgment_checks;
  Alcotest.(check int) "the replay asked nothing" 10 (F.post_count server)
;;

let () =
  Alcotest.run "keeper_librarian_absorb_gate_metrics"
    [ ( "counters"
      , [ Alcotest.test_case "a judgment counts once on each gate path" `Quick
            test_each_path_counts_its_judgment_once
        ] )
    ]
;;
