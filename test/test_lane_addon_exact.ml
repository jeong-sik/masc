(** A package's exact-output request is retained before the runner is asked,
    and replayed instead of asked again (RFC operator-quiz §4.3, K1). *)
open Alcotest
module Exact = Masc.Lane_addon_exact

(* These fixtures exercise host publication, not real provider capture. Their
   explicit synthetic CLI success never claims API-only failure coverage. *)
let executed outcome =
  let module Receipt = Masc.Keeper_exact_walk_receipt in
  let declared_cli, dispatched, result = match outcome with
    | Exact.Call_ended (Exact.Answered {slot; _}) -> [slot], [slot], Receipt.Answered slot
    | Exact.Call_ended (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
    | Exact.Call_refused _ -> [], [], Receipt.Not_reached in
  let receipt = match Receipt.make ~declared_http:[] ~excluded_http:[] ~declared_cli
      ~http:(Receipt.http_not_started ~detail:"synthetic host publication fixture")
      ~cli:(Receipt.cli ~visited:dispatched ~dispatched ~failures:[] ~result) with
    | Ok receipt -> receipt | Error detail -> Alcotest.fail detail in
  {Exact.outcome; receipt}
module Store = Masc.Lane_addon_store
module Types = Masc.Lane_addon_types

let authorize_request ~store:_ ~declaration_id:_ ~package:_ _ =
  Ok {Exact.admission_class=Agent_core.Llm_provider.Admission_class.Standard;
      before_dispatch=(fun () -> Ok ()); with_execution=(fun run -> run ()); validate_output=(fun _ -> Ok ())}

let require = function Ok value -> value | Error error -> fail error

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_root f =
  let dir = Filename.temp_file "lane-exact-" ".fixture" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () ->
    Eio_main.run (fun _env -> f (Filename.concat dir "retained")))

let schema =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc [ "question", `Assoc [ "type", `String "string" ] ]
    ; "additionalProperties", `Bool false
    ]

let package : Types.package =
  { id = "operator-quiz"; revision = "1"; title = "Exact fixture"
  ; ui_category = None; contributions = [ Types.Observe ]; command = [ "unused" ]
  ; directory = "/nonexistent"; skills_directory = None; action_tool = None
  ; state_storage = Types.Ephemeral; tool_invocation = Types.Direct; tool_hooks = []; worker_service = Types.Mcp_tools; exported_tools = []; outputs = []
  ; refresh_policy = Types.Every_hint; model_access = Types.Model_disabled
  ; exact_outputs = [ { Types.name = "author"; schema; request_schema=Types.Package_schema_only } ]; operator_asks = false; web_search = false
  ; binding_schema = None; presentation = Masc.Lane_addon_presentation.empty
  ; execution = Types.Container { runtime = Types.Docker; image = "unused"
      ; resources = { cpus = 0.5; memory_bytes = 134217728L; pids = Some 16; max_reply_bytes = 65536 } } }

let declaration_id = "quiz"

let request ?schema ?(output = "author") ?(message = "Write one question.") id =
  require
    (Exact.request_of_json
       (`Assoc
          ([ "kind", `String "exact_output"; "request_id", `String id; "output", `String output
          ; "messages", `List [ `Assoc [ "role", `String "user"; "text", `String message ] ] ]
          @ (match schema with None -> [] | Some schema -> ["schema",schema]))))

let question = `Assoc [ "question", `String "Q?" ]

let answered_with expected = function
  | Exact.Final (Exact.Call_final (Exact.Answered { output; _ })) -> Exact.checked_json output = expected
  | Exact.Final _ | Exact.Not_final _ -> false

(* What the runner does on each resolution, in order. *)
type step =
  | Answer of Yojson.Safe.t
  | Unavailable of Exact.lane_unavailable
  | Refused of Exact.provider_refusal

(* A runner that counts the calls it sends and, on each send, reads what the
   host has retained so far for that request. It passes the generation guard
   before it sends, as a call must. *)
let counting_runner store steps =
  let sends = ref 0 and seen = ref [] in
  let runner ~before_dispatch ~admission_class:_ ~lane_key ~schema:_ ~size_refused:_ (request : Exact.request) =
    match !steps with
    | [] -> fail "the runner was asked more often than the test expected"
    | step :: rest ->
      steps := rest;
      let sent () =
        require (before_dispatch Exact.Generation);
        incr sends;
        seen := (lane_key, Store.load_exact_request store ~declaration_id ~request_id:request.request_id) :: !seen
      in
      (match step with
       | Unavailable reason -> Error reason
       | Refused reason -> Ok (fun ~validate:_ -> sent (); executed (Exact.Call_refused reason))
       | Answer json ->
         Ok
           (fun ~validate ->
              sent ();
              match validate json with
              | Ok output -> executed (Exact.Call_ended (Exact.Answered { output; slot = "s"; usage = None }))
              | Error detail -> executed (Exact.Call_ended (Exact.Invalid_output { detail }))))
  in
  runner, sends, seen

let run_request store runner request = require (Exact.run ~authorize_request ~store ~declaration_id ~package ~runner request)

let attempts store id =
  match require (Store.load_exact_request store ~declaration_id ~request_id:id) with
  | Some json -> Yojson.Safe.Util.(json |> member "attempts" |> to_list)
  | None -> []

let other_process_marker = `Assoc ["started", `String (String.make 32 '0')]
let one_started_marker = function
  | [`Assoc ["started", `String incarnation]] -> String.length incarnation = 32
  | _ -> false
let observe store request = Eio_unix.run_in_systhread (fun () ->
  Exact.observe_retained ~store ~declaration_id ~schema request)
let recover store request = Eio.Cancel.protect (fun () ->
  Eio_unix.run_in_systhread (fun () ->
    Exact.recover_retained ~store ~declaration_id ~schema request)
  |> Result.map_error Exact.describe_recovery_error)

(* The run republishes its record while an observer reads it (#45134). The
   seam republishes a larger record once, after the reader opened the old one
   and before it confirms the path still names that file. *)
let test_republished_record_is_read_again () =
  with_root (fun root ->
    let store = Store.create ~root in
    let request_id = "republished" in
    let first = `Assoc [ "attempts", `List [] ] in
    let newer = `Assoc [ "attempts", `List [ `Null ]; "final", `Assoc [ "kind", `String "answered" ] ] in
    require (Store.save_exact_request store ~declaration_id ~request_id first);
    let republished = ref 0 in
    let sync_file fd =
      Unix.fsync fd;
      if !republished = 0 then begin
        incr republished;
        require (Store.save_exact_request store ~declaration_id ~request_id newer)
      end
    in
    let read =
      Store.For_testing.load_exact_request ~sync_file ~sync_parent:Unix.fsync store ~declaration_id ~request_id
    in
    check int "the record was republished during the first read" 1 !republished;
    check bool "the read returns the newer record instead of an error" true (read = Ok (Some newer)))

let test_retained_before_the_call_and_replayed () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner, sends, seen = counting_runner store (ref [ Answer question ]) in
    check bool "first run answers" true (answered_with question (run_request store runner (request "r1")));
    (match !seen with
     | [ (lane_key, Ok (Some json)) ] ->
       check string "the call runs on the installation's add-on lane" "quiz/author" lane_key;
       check bool "the request was retained with a started attempt before the call" true
         (one_started_marker Yojson.Safe.Util.(json |> member "attempts" |> to_list))
     | _ -> fail "the runner saw no retained request");
    let restarted = Store.create ~root in
    check bool "after a restart the retained result is delivered" true
      (answered_with question (run_request restarted runner (request "r1")));
    check int "and the call is not sent again" 1 !sends)

let test_an_unavailable_lane_sends_nothing_and_survives_a_restart () =
  with_root (fun root ->
    let store = Store.create ~root in
    let steps = ref [ Unavailable Exact.Lane_off; Answer question ] in
    let runner, sends, _ = counting_runner store steps in
    check bool "an off lane does not end the request" true
      (run_request store runner (request "r2") = Exact.Not_final (Exact.Lane_unavailable Exact.Lane_off));
    check int "nothing was sent" 0 !sends;
    check bool "its attempt is retained and not marked as started" true
      (match attempts store "r2" with [ `Assoc _ ] -> true | _ -> false);
    let restarted = Store.create ~root in
    check bool "after a restart the request is tried again, not unknown" true
      (answered_with question (run_request restarted runner (request "r2")));
    check int "both attempts are retained" 2 (List.length (attempts restarted "r2")))

let test_a_provider_refusal_that_may_pass_is_tried_again () =
  with_root (fun root ->
    let store = Store.create ~root in
    let busy = Exact.Provider_unavailable { detail = "429" } in
    let runner, sends, _ = counting_runner store (ref [ Refused busy; Answer question ]) in
    check bool "a rate limit does not end the request" true
      (run_request store runner (request "r8") = Exact.Not_final (Exact.Provider_refused busy));
    check bool "the next run sends again and ends it" true (answered_with question (run_request store runner (request "r8")));
    check int "two sends" 2 !sends;
    check int "two attempts" 2 (List.length (attempts store "r8")))

let test_an_answer_outside_the_schema_is_not_answered () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner, _, _ = counting_runner store (ref [ Answer (`Assoc [ "question", `String "Q?"; "extra", `Int 1 ]) ]) in
    match run_request store runner (request "r9") with
    | Exact.Final (Exact.Call_final (Exact.Invalid_output _)) -> ()
    | _ -> fail "validate must refuse an answer the declared schema does not allow")

let test_a_reused_request_id_is_refused () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner, sends, _ = counting_runner store (ref [ Answer question ]) in
    ignore (run_request store runner (request "r3"));
    check bool "the same id with another body is refused" true
      (run_request store runner (request ~message:"Something else." "r3") = Exact.Final Exact.Request_id_reused);
    check int "without a send" 1 !sends;
    check bool "and the original result stands" true (answered_with question (run_request store runner (request "r3"))))

let test_a_started_attempt_without_outcome_is_unknown () =
  with_root (fun root ->
    let store = Store.create ~root in
    let pending = request "r4" in
    (* What a process that died during the call leaves behind. *)
    require
      (Store.save_exact_request store ~declaration_id ~request_id:"r4"
         (`Assoc
            [ "declaration_id", `String declaration_id; "request_id", `String "r4"
            ; "digest", `String (Exact.digest pending); "request", Exact.request_to_json pending
            ; "attempts", `List [ other_process_marker ]; "final", `Null ]));
    let runner, sends, _ = counting_runner store (ref []) in
    check bool "the host cannot tell whether the provider got it" true
      (run_request store runner pending = Exact.Final Exact.Outcome_unknown);
    check int "so it does not send again" 0 !sends;
    check bool "and the verdict is retained" true (run_request store runner pending = Exact.Final Exact.Outcome_unknown);
    check bool "a different server incarnation is interrupted" true
      (require (observe store pending)=Exact.Retained_terminal (Exact.Retained_unknown Exact.Interrupted));
    check bool "recovery replaces the start with its cause" true
      (attempts store pending.request_id=[Exact.retained_final_to_json (Exact.Retained_unknown Exact.Interrupted)]))

let test_an_exception_ends_the_request_as_unknown () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ = Ok (fun ~validate:_ ->
      require (before_dispatch Exact.Generation);
      failwith "connection reset after send") in
    check bool "an exception is Outcome_unknown" true (run_request store runner (request "r5") = Exact.Final Exact.Outcome_unknown);
    check bool "the host preserves the raised cause" true
      (require (observe store (request "r5"))=Exact.Retained_terminal (Exact.Retained_unknown Exact.Raised));
    match attempts store "r5" with
    | [ attempt ] ->
      check bool "its text stays in the attempt" true
        (Yojson.Safe.Util.(attempt |> member "exception") <> `Null)
    | _ -> fail "one attempt expected")

(* A call that raises before its first generation dispatch sent nothing. The
   run is an Error, the record keeps no attempt, and the next run sends the
   request. A measurement dispatch before the exception does not change that. *)
let test_an_exception_before_the_first_generation_dispatch_is_an_error () =
  List.iter (fun measures -> with_root (fun root ->
    let store = Store.create ~root in
    let original = request "raised-before-dispatch" in
    let raising ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ = Ok (fun ~validate:_ ->
      if measures then require (before_dispatch Exact.Measurement);
      invalid_arg "two settings of one endpoint disagree") in
    check bool "the run fails" true
      (Result.is_error (Exact.run ~authorize_request ~store ~declaration_id ~package ~runner:raising original));
    check bool "the request stays open" true (require (observe store original) = Exact.Retained_open);
    check int "with no attempt" 0 (List.length (attempts store original.request_id));
    let runner, sends, _ = counting_runner store (ref [ Answer question ]) in
    check bool "the next run sends it" true (answered_with question (run_request store runner original));
    check int "once" 1 !sends)) [ false; true ]

let test_an_undeclared_output_is_not_allowed () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner, sends, _ = counting_runner store (ref []) in
    (match run_request store runner (request ~output:"grade" "r6") with
     | Exact.Final (Exact.Not_allowed _) -> ()
     | _ -> fail "an output the manifest does not declare must be not_allowed");
    let restarted = Store.create ~root in
    check bool "a denied id cannot be reused for a permitted output" true
      (run_request restarted runner (request "r6") = Exact.Final Exact.Request_id_reused);
    let allowed = {package with exact_outputs = [{Types.name="grade";schema;request_schema=Types.Package_schema_only}]} in
    check bool "the same denied request retains its final after permission changes" true
      (match require (Exact.run ~authorize_request ~store:restarted ~declaration_id ~package:allowed ~runner (request ~output:"grade" "r6")) with
       | Exact.Final (Exact.Not_allowed _) -> true | _ -> false);
    check int "without a send" 0 !sends)

let test_selection_hides_but_preserves_a_retained_answer () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner, sends, _ = counting_runner store (ref [Answer question]) in
    ignore (run_request store runner (request "selected"));
    let off request = require (Exact.run ~authorize_request ~store ~declaration_id ~package:{package with exact_outputs=[]} ~runner request) in
    check bool "permission does not mask a changed identity" true
      (off (request ~output:"grade" "selected") = Exact.Final Exact.Request_id_reused);
    check bool "disabled output does not disclose the original answer" true
      (match off (request "selected") with Exact.Final (Exact.Not_allowed _) -> true | _ -> false);
    check int "the delivery refusal is retained alongside the original attempt" 2 (List.length (attempts store "selected"));
    let latest () = require (Exact.read_latest_original_execution ~store:(Store.create ~root)
        ~declaration_id ~schema (request "selected")) in
    let expect_original_proof () = match latest () with
      | Exact.Completed_latest {attempt_ordinal=1;execution={outcome=Exact.Call_ended (Exact.Answered _);_}} -> ()
      | Exact.No_completed_latest | Exact.Completed_latest _ -> fail "delivery refusal hid the original proof" in
    expect_original_proof ();
    check bool "a second refusal remains a refusal" true
      (match off (request "selected") with Exact.Final (Exact.Not_allowed _) -> true | _ -> false);
    check int "both delivery refusals remain in the audit" 3 (List.length (attempts store "selected"));
    expect_original_proof ();
    check bool "reenabling replays the original answer" true
      (answered_with question (run_request store runner (request "selected")));
    check int "one provider call across selection changes" 1 !sends)

(* While one run of a request is inside its call, a run of the same request
   through another store value on the same root waits and leaves the record
   alone; the same ids under another root are a different request. *)
let test_a_request_in_flight_is_not_run_twice () =
  with_root (fun root ->
    let entered, enter = Eio.Promise.create () in
    let released, release = Eio.Promise.create () in
    let blocking ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ =
      Ok
        (fun ~validate ->
           require (before_dispatch Exact.Generation);
           Eio.Promise.resolve enter ();
           Eio.Promise.await released;
           match validate question with
           | Ok output -> executed (Exact.Call_ended (Exact.Answered { output; slot = "s"; usage = None }))
           | Error detail -> fail detail)
    in
    let first = ref None and second = ref None and other_root = ref None and during = ref [] in
    Eio.Fiber.both
      (fun () -> first := Some (run_request (Store.create ~root) blocking (request "r7")))
      (fun () ->
        Eio.Promise.await entered;
        let same_root = Store.create ~root in
        let unused, _, _ = counting_runner same_root (ref []) in
        second := Some (run_request same_root unused (request "r7"));
        during := attempts same_root "r7";
        let elsewhere = Store.create ~root:(root ^ "-other") in
        let answering, _, _ = counting_runner elsewhere (ref [ Answer question ]) in
        other_root := Some (run_request elsewhere answering (request "r7"));
        Eio.Promise.resolve release ());
    check bool "the second run waits" true (!second = Some (Exact.Not_final Exact.Attempt_in_progress));
    check bool "and leaves the started attempt alone" true (one_started_marker !during);
    check bool "the first run answers" true (Option.fold ~none:false ~some:(answered_with question) !first);
    check bool "the same ids under another root run" true (Option.fold ~none:false ~some:(answered_with question) !other_root))

let test_a_cancelled_call_leaves_its_attempt_started () =
  with_root (fun root ->
    let store = Store.create ~root in
    let cancelled ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ = Ok (fun ~validate:_ ->
      require (before_dispatch Exact.Generation);
      raise (Eio.Cancel.Cancelled Exit)) in
    (match Exact.run ~authorize_request ~store ~declaration_id ~package ~runner:cancelled (request "r10") with
     | _ -> fail "a cancellation must reach the caller"
     | exception Eio.Cancel.Cancelled _ -> ());
    check bool "the started attempt stays" true (one_started_marker (attempts store "r10"));
    let runner, sends, _ = counting_runner store (ref []) in
    check bool "disabled output refuses delivery of an unresolved attempt" true
      (match require (Exact.run ~authorize_request ~store ~declaration_id ~package:{package with exact_outputs=[]} ~runner (request "r10")) with
       | Exact.Final (Exact.Not_allowed _) -> true | _ -> false);
    check bool "the next run reads it as unknown, so the claim was released" true
      (run_request store runner (request "r10") = Exact.Final Exact.Outcome_unknown);
    check bool "recovery in this process retains cut even after a delivery denial" true
      (require (observe store (request "r10"))=Exact.Retained_terminal (Exact.Retained_unknown Exact.Cut));
    check int "without a send" 0 !sends)

let test_a_retained_answer_is_checked_against_the_schema_declared_now () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner, sends, _ = counting_runner store (ref [ Answer question ]) in
    ignore (run_request store runner (request "r11"));
    let changed =
      { package with
        exact_outputs =
          [ { Types.name = "author"
            ; request_schema=Types.Package_schema_only
            ; schema =
                `Assoc
                  [ "type", `String "object"
                  ; "properties", `Assoc [ "question", `Assoc [ "type", `String "integer" ] ]
                  ; "additionalProperties", `Bool false ] } ] }
    in
    (match require (Exact.run ~authorize_request ~store ~declaration_id ~package:changed ~runner (request "r11")) with
     | Exact.Final (Exact.Call_final (Exact.Invalid_output _)) -> ()
     | _ -> fail "an answer retained under the old schema must not be delivered as answered");
    check int "and the provider is not called again" 1 !sends;
    check bool "the record keeps the answer as it came" true (answered_with question (run_request store runner (request "r11"))))

let test_confirmed_proof_recovers_lost_outcome_publication () =
  with_root (fun root ->
    let store = Store.create ~root in
    let directory = Filename.concat (Filename.concat root "exact-requests") (Store.digest declaration_id) in
    let locking ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ =
      Ok
        (fun ~validate ->
           require (before_dispatch Exact.Generation);
           Unix.chmod directory 0o500;
           match validate question with
           | Ok output -> executed (Exact.Call_ended (Exact.Answered { output; slot = "s"; usage = None }))
           | Error detail -> fail detail)
    in
    let result = Exact.run ~authorize_request ~store ~declaration_id ~package ~runner:locking (request "r12") in
    Unix.chmod directory 0o700;
    check bool "the run reports the failed write" true (Result.is_error result);
    let wire=Option.get (require (Store.load_exact_request store ~declaration_id ~request_id:"r12")) in
    let from_another_process=match wire with
      | `Assoc fields -> `Assoc (("attempts",`List [other_process_marker])::List.remove_assoc "attempts" fields)
      | _ -> fail "original Exact record expected" in
    require (Store.save_exact_request store ~declaration_id ~request_id:"r12" from_another_process);
    check bool "publication recovery refuses another original schema" true
      (Result.is_error (Eio.Cancel.protect (fun () -> Eio_unix.run_in_systhread (fun () ->
        Exact.recover_retained ~store ~declaration_id
          ~schema:(`Assoc ["type",`String "object";"title",`String "another schema"])
          (request "r12")))));
    check bool "owner restores the proven terminal without a worker listing" true
      (match require (recover (Store.create ~root) (request "r12")) with
       | Exact.Retained_terminal (Exact.Retained_call (Exact.Answered {output;_})) ->
           Exact.checked_json output=question
       | Exact.Retained_absent | Retained_open | Retained_terminal _ -> false);
    let runner, sends, _ = counting_runner store (ref []) in
    check bool "the original answer is published without another send" true (answered_with question (run_request store runner (request "r12")));
    check bool "completed proof wins over another process's marker" true
      (match require (observe store (request "r12")) with
       | Exact.Retained_terminal (Exact.Retained_call (Exact.Answered _)) -> true
       | _ -> false);
    check int "without a send" 0 !sends)

let test_v2_proof_recovers_lost_outcome_publication () =
  with_root (fun root ->
    let module Receipt=Masc.Keeper_exact_walk_receipt in
    let store=Store.create ~root in
    let directory=Filename.concat (Filename.concat root "exact-requests") (Store.digest declaration_id) in
    let original=request "v2-publication-recovery" in
    let sent=ref 0 in
    let locking ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ =
      Ok (fun ~validate ->
        require (before_dispatch Exact.Generation);
        incr sent;
        Unix.chmod directory 0o500;
        let output=require (validate question) in
        let cli=Receipt.cli ~visited:["s"] ~dispatched:["s"] ~failures:[] ~result:(Receipt.Answered "s") in
        let receipt=require (Receipt.make_v2 ~declared_http:[] ~excluded_http:[] ~declared_cli:["s"]
          ~http:(Receipt.http_not_started ~detail:"synthetic host publication fixture") ~cli) in
        {Exact.outcome=Exact.Call_ended (Exact.Answered {output;slot="s";usage=None});receipt}) in
    let result=Exact.run ~authorize_request ~store ~declaration_id ~package ~runner:locking original in
    Unix.chmod directory 0o700;
    check bool "outcome index publication failed" true (Result.is_error result);
    (match require (Exact.read_original_execution ~store ~declaration_id ~schema ~attempt_ordinal:1 original) with
     | Exact.Completed_original {receipt;_} ->
       check bool "the confirmed original proof is v2" true (Receipt.response_observations receipt=Some [])
     | Exact.No_completed_original -> fail "the v2 proof did not survive the failed index publication");
    let wire=Option.get (require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id)) in
    let interrupted=match wire with
      | `Assoc fields -> `Assoc (("attempts",`List [other_process_marker])::List.remove_assoc "attempts" fields)
      | _ -> fail "original Exact record expected" in
    require (Store.save_exact_request store ~declaration_id ~request_id:original.request_id interrupted);
    check bool "owner restores the v2 proven terminal without a worker listing" true
      (match require (recover (Store.create ~root) original) with
       | Exact.Retained_terminal (Exact.Retained_call (Exact.Answered {output;_})) ->
           Exact.checked_json output=question
       | Exact.Retained_absent | Retained_open | Retained_terminal _ -> false);
    let unused,sends,_=counting_runner store (ref []) in
    check bool "v2 proof restores the original answer" true (answered_with question (run_request store unused original));
    check int "the original runner was called once" 1 !sent;
    check int "recovery did not call a provider" 0 !sends)

let test_original_consumer_recovers_proof_without_worker_rpc () =
  with_root (fun root ->
    let module Owner=Masc.Lane_addon_tool_request_owner in
    let module Progress=Masc.Lane_addon_request_progress in
    let module Submit=Masc.Lane_addon_submit_once in
    let store=Store.create ~root in
    let original=request "consumer-recovers-proof" in
    let scope="proof-publication-consumer" in
    let owned value=require (Result.map_error Owner.error_to_string value) in
    require (Result.map_error Owner.error_to_string
      (Owner.retain ~store ~scope ~request_id:original.request_id
        ~installation_id:(Owner.installation_id (Owner.Configuration declaration_id))
        ~package_id:package.id ~tool:"derive" ~summary:`Null
        ~request:(Exact.request_to_json original)));
    let retained=Option.get (owned (Owner.load ~store ~scope ~request_id:original.request_id)) in
    let retained=match require (Result.map_error Owner.update_error_to_string
      (Owner.advance ~store ~expected:retained ~event:Progress.Dispatch_intended)) with
      | Owner.Stored record | Already_stored record -> record
      | Unconfirmed detail -> fail detail in
    let runner,sends,_=counting_runner store (ref [Answer question]) in
    ignore (run_request store runner original);
    let wire=Option.get (require (Store.load_exact_request store ~declaration_id
      ~request_id:original.request_id)) in
    let unpublished=match wire with
      | `Assoc fields -> `Assoc (("attempts",`List [other_process_marker])::
          ("final",`Null)::List.remove_assoc "attempts" (List.remove_assoc "final" fields))
      | _ -> fail "original Exact record expected" in
    require (Store.save_exact_request store ~declaration_id
      ~request_id:original.request_id unpublished);
    let calls=ref 0 in
    let result=Submit.resume ~store ~label:"Proven original" ~original:retained
      ~request:original ~schema ~decode_final:(Exact.final_of_json ~schema)
      ~prepare:(fun () -> fail "recovery requested fresh admission")
      ~call:(fun ~arguments:_ -> incr calls; fail "recovery contacted the worker")
      ~terminal:(fun _ final ->
        match Exact.read_latest_original_execution ~store ~declaration_id ~schema original with
        | Error detail -> Error (Submit.Rejected detail)
        | Ok actual -> match actual,final with
        | Exact.Completed_latest {execution={outcome=Exact.Call_ended (Exact.Answered {output;_});_};_},
          Exact.Call_final (Exact.Answered {output=delivered;_})
          when Exact.checked_json output=question && Exact.checked_json delivered=question -> Ok final
        | Exact.No_completed_latest,_ | Exact.Completed_latest _,_ ->
          Error (Submit.Rejected "consumer requires its actual proven answer")) in
    (match result with
     | Ok (Submit.Final (Exact.Call_final (Exact.Answered {output;_}))) ->
       check bool "consumer validates its original answer" true (Exact.checked_json output=question)
     | Error error -> fail (Submit.error_to_string error)
     | Ok (Submit.Awaiting _ | Final _ | Commit_pending _ | Settled _) ->
       fail "consumer did not recover the proven terminal");
    let after=Option.get (owned (Owner.load ~store ~scope ~request_id:original.request_id)) in
    check bool "only the original judgment is retained; no domain ACK is invented" true
      (match Progress.phase after.progress with
       | Progress.Judged _ -> true
       | Captured | Admission_wait _ | Dispatch_pending _ | Committing _ | Commit_unknown _
       | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
    check int "the actual provider ran only for the original" 1 !sends;
    check int "the missing worker was never contacted" 0 !calls)

let test_publication_recovery_preserves_unproven_original () =
  with_root (fun root ->
    let store=Store.create ~root in
    let original=request "unproven-publication" in
    check bool "absent remains absent" true
      (require (recover store original)=Exact.Retained_absent);
    check bool "an absence read creates no store" false (Sys.file_exists root);
    let wire=`Assoc ["declaration_id",`String declaration_id;
      "request_id",`String original.request_id;"digest",`String (Exact.digest original);
      "request",Exact.request_to_json original;"attempts",`List [other_process_marker];"final",`Null] in
    require (Store.save_exact_request store ~declaration_id ~request_id:original.request_id wire);
    check bool "no proof leaves the old start open without inventing interrupted" true
      (require (recover store original)=Exact.Retained_open);
    check bool "the unproven original is unchanged" true
      (require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id)=Some wire))

let original_execution store ?(attempt_ordinal=1) original =
  Exact.read_original_execution ~store ~declaration_id ~schema ~attempt_ordinal original

let proof_address original =
  let tuple values=Yojson.Safe.to_string (`List values) in
  tuple [`String "exact-original-execution";`String declaration_id],
  tuple [`String "original-request";`String original.Exact.request_id;`String (Exact.digest original)]

let test_v1_and_v2_original_proofs_remain_distinct () =
  with_root (fun root ->
    let module Receipt=Masc.Keeper_exact_walk_receipt in
    let store=Store.create ~root in
    let original=request "mixed-version-originals" in
    let busy=Exact.Provider_unavailable {detail="synthetic first refusal"} in
    let first,_,_=counting_runner store (ref [Refused busy]) in
    ignore (run_request store first original);
    let instance_id,request_id=proof_address original in
    let read_link ()=Option.get (require (Store.load_host_result store ~instance_id ~request_id)) in
    let prior=match Yojson.Safe.Util.member "executions" (read_link ()) with
      | `List [one] -> one | _ -> fail "expected one v1 original proof" in
    let runner ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ =
      Ok (fun ~validate ->
        let output=require (validate question) in
        let cli=Receipt.cli ~visited:["s"] ~dispatched:["s"] ~failures:[] ~result:(Receipt.Answered "s") in
        let receipt=require (Receipt.make_v2 ~declared_http:[] ~excluded_http:[] ~declared_cli:["s"]
          ~http:(Receipt.http_not_started ~detail:"synthetic host publication fixture") ~cli) in
        {Exact.outcome=Exact.Call_ended (Exact.Answered {output;slot="s";usage=None});receipt}) in
    check bool "a later v2 fixture publishes the original answer" true
      (answered_with question (run_request store runner original));
    (match Yojson.Safe.Util.member "executions" (read_link ()) with
     | `List [unchanged;newer] ->
       check bool "earlier v1 proof is preserved exactly" true (Yojson.Safe.equal prior unchanged);
       check int "earlier receipt remains version 1" 1
         Yojson.Safe.Util.(unchanged |> member "receipt" |> member "version" |> to_int);
       check int "later receipt uses version 2" 2
         Yojson.Safe.Util.(newer |> member "receipt" |> member "version" |> to_int)
     | _ -> fail "expected both ordered original proofs");
    let reopened=Store.create ~root in
    (match require (original_execution reopened original),require (original_execution reopened ~attempt_ordinal:2 original) with
     | Exact.Completed_original {receipt=old;_},Exact.Completed_original {receipt=newer;_} ->
       check bool "v1 has no invented response observations" true (Receipt.response_observations old=None);
       check bool "v2 keeps its empty synthetic HTTP walk" true (Receipt.response_observations newer=Some [])
     | _ -> fail "mixed original proofs did not reopen");
    let replace field transform = function
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,if key=field then transform value else value) fields)
      | _ -> fail "expected an original proof object" in
    let original_link=read_link () in
    let historical_wrapper=original_link |> replace "executions" (function
      | `List [first;second] -> `List [first
          |> replace "version" (fun _ -> `Float 1.0)
          |> replace "attempt_ordinal" (fun _ -> `Float 1.0)
          |> replace "receipt" (replace "version" (fun _ -> `Float 1.0));second]
      | _ -> fail "expected mixed original proofs") in
    require (Store.save_host_result store ~instance_id ~request_id historical_wrapper);
    check bool "historical v1 wrapper retains its prior canonical reading" true
      (match original_execution reopened original with Ok (Exact.Completed_original _) -> true
       | Ok Exact.No_completed_original | Error _ -> false);
    require (Store.save_host_result store ~instance_id ~request_id original_link);
    let alter_second transform = original_link |> replace "executions" (function
      | `List [first;second] -> `List [first;transform second]
      | _ -> fail "expected mixed original proofs") in
    let unused,sends,_=counting_runner store (ref []) in
    List.iter (fun malformed ->
      require (Store.save_host_result store ~instance_id ~request_id malformed);
      check bool "stored v2 proof rejects a float before wrapper normalization" true
        (Result.is_error (original_execution reopened ~attempt_ordinal:2 original));
      check bool "malformed original proof cannot recover or dispatch" true
        (Result.is_error (Exact.run ~authorize_request ~store:reopened ~declaration_id ~package ~runner:unused original)))
      [alter_second (replace "receipt" (replace "version" (fun _ -> `Float 2.0)));
       alter_second (replace "attempt_ordinal" (fun _ -> `Float 2.0));
       alter_second (replace "version" (fun _ -> `Float 1.0))];
    check int "malformed proof caused no new call" 0 !sends)

let test_original_execution_is_bound_to_one_attempt () =
  with_root (fun root ->
    let store=Store.create ~root in
    let original=request "attempt-proofs" in
    let busy=Exact.Provider_unavailable {detail="synthetic original refusal"} in
    let runner,sends,_=counting_runner store (ref [Refused busy;Answer question]) in
    ignore (run_request store runner original);
    (match require (original_execution (Store.create ~root) original) with
     | Exact.Completed_original {outcome=Exact.Call_refused refusal;_} ->
       check bool "first original refusal is retained" true (refusal=busy)
     | Exact.No_completed_original | Exact.Completed_original _ -> fail "missing first original execution");
    check bool "a future attempt cannot borrow the first proof" true
      (require (original_execution store ~attempt_ordinal:2 original)=Exact.No_completed_original);
    check bool "second trigger can answer" true (answered_with question (run_request store runner original));
    (match require (original_execution store ~attempt_ordinal:2 original) with
     | Exact.Completed_original {outcome=Exact.Call_ended (Exact.Answered {output;_});_} ->
       check bool "second original answer has its own proof" true (Exact.checked_json output=question)
     | Exact.No_completed_original | Exact.Completed_original _ -> fail "missing second original execution");
    check int "only the two explicit triggers send" 2 !sends;
    let changed=request ~message:"different original" original.request_id in
    check bool "read refuses a rebound request" true (Result.is_error (original_execution store changed));
    check bool "read refuses a schema from another original" true
      (Result.is_error (Exact.read_original_execution ~store ~declaration_id ~schema:(`Assoc []) ~attempt_ordinal:2 original));
    check bool "read refuses a zero ordinal" true (Result.is_error (original_execution store ~attempt_ordinal:0 original)))

let test_latest_execution_never_borrows_an_earlier_proof () =
  with_root (fun root ->
    let store=Store.create ~root in
    let original=request "latest-original-proof" in
    let busy=Exact.Provider_unavailable {detail="original refusal"} in
    let runner,sends,_=counting_runner store
      (ref [Refused busy;Unavailable Exact.Lane_off;Answer question]) in
    let latest ()=require (Exact.read_latest_original_execution ~store:(Store.create ~root)
      ~declaration_id ~schema original) in
    check bool "absent original has no latest proof" true (latest ()=Exact.No_completed_latest);
    ignore (run_request store runner original);
    (match latest () with
     | Exact.Completed_latest {attempt_ordinal;execution={outcome=Exact.Call_refused refusal;_}} ->
       check int "actual refusal ordinal" 1 attempt_ordinal;
       check bool "actual original refusal" true (refusal=busy)
     | Exact.No_completed_latest | Exact.Completed_latest _ -> fail "latest refusal is missing");
    let retained=Option.get (require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id)) in
    let started=match retained with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,
          if key="attempts" then (match value with
            | `List entries -> `List (entries @ [`Assoc ["started",`String (String.make 32 'a')]])
            | _ -> fail "expected attempt history") else value) fields)
      | _ -> fail "expected retained original" in
    require (Store.save_exact_request store ~declaration_id ~request_id:original.request_id started);
    check bool "a later started attempt cannot borrow a completed predecessor" true
      (latest ()=Exact.No_completed_latest);
    check bool "publication recovery cannot borrow the earlier proof either" true
      (require (recover store original)=Exact.Retained_open);
    check bool "unproven latest attempt is not rewritten" true
      (require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id)=Some started);
    require (Store.save_exact_request store ~declaration_id ~request_id:original.request_id retained);
    ignore (run_request store runner original);
    check bool "a later unstarted attempt cannot borrow a completed predecessor" true
      (latest ()=Exact.No_completed_latest);
    check bool "the earlier proof remains separately readable" true
      (match require (original_execution store original) with
       | Exact.Completed_original _ -> true | Exact.No_completed_original -> false);
    check bool "a later explicit trigger can answer" true
      (answered_with question (run_request store runner original));
    (match latest () with
     | Exact.Completed_latest {attempt_ordinal;execution={outcome=Exact.Call_ended (Exact.Answered _);_}} ->
       check int "the reader reports the real ordinal including the unsent attempt" 3 attempt_ordinal
     | Exact.No_completed_latest | Exact.Completed_latest _ -> fail "latest answer is missing");
    let off = {package with exact_outputs=[]} in
    (match require (Exact.run ~authorize_request ~store ~declaration_id ~package:off ~runner original) with
     | Exact.Final (Exact.Not_allowed _) -> ()
     | Exact.Final _ | Exact.Not_final _ -> fail "disabled output must refuse delivery");
    (match latest () with
     | Exact.Completed_latest {attempt_ordinal;execution={outcome=Exact.Call_ended (Exact.Answered _);_}} ->
       check int "delivery refusal preserves the original ordinal, including earlier attempts" 3 attempt_ordinal
     | Exact.No_completed_latest | Exact.Completed_latest _ -> fail "the original answer proof was hidden");
    check int "proof reads never dispatch" 2 !sends)

let test_proof_publication_failure_never_exposes_an_answer () =
  with_root (fun root ->
    let store=Store.create ~root in
    let original=request "blocked-proof" in
    let sends=ref 0 in
    let obstruction=Filename.concat root "host-results" in
    let runner ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ = Ok (fun ~validate ->
      incr sends;
      Out_channel.with_open_bin obstruction (fun channel -> output_string channel "not a proof directory");
      let output=require (validate question) in
      executed (Exact.Call_ended (Exact.Answered {output;slot="synthetic";usage=None}))) in
    check bool "failed proof publication is an Error" true
      (Result.is_error (Exact.run ~authorize_request ~store ~declaration_id ~package ~runner original));
    let record=Option.get (require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id)) in
    check bool "answer is not exposed as final before proof confirmation" true
      (Yojson.Safe.Util.member "final" record=`Null);
    Sys.remove obstruction;
    let unused,_,_=counting_runner store (ref []) in
    check bool "missing proof preserves unknown without replay" true
      (run_request store unused original=Exact.Final Exact.Outcome_unknown);
    check bool "proof publication failure in this incarnation retains cut" true
      (require (observe store original)=Exact.Retained_terminal (Exact.Retained_unknown Exact.Cut));
    check bool "an old generic unknown grants no execution proof" true
      (require (original_execution store original)=Exact.No_completed_original);
    check int "the original call ran once" 1 !sends)

let test_malformed_proof_refuses_publication_recovery () =
  let mutate field value json=match json with
    | `Assoc fields -> `Assoc ((field,value)::List.remove_assoc field fields)
    | _ -> fail "expected original proof object" in
  List.iter (fun (label,change) -> with_root (fun root ->
    let store=Store.create ~root in
    let original=request ("malformed-proof-"^label) in
    let directory=Filename.concat (Filename.concat root "exact-requests") (Store.digest declaration_id) in
    let runner ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ = Ok (fun ~validate ->
      require (before_dispatch Exact.Generation);
      let output=require (validate question) in
      Unix.chmod directory 0o500;
      executed (Exact.Call_ended (Exact.Answered {output;slot="synthetic";usage=None}))) in
    let result=Exact.run ~authorize_request ~store ~declaration_id ~package ~runner original in
    Unix.chmod directory 0o700;
    check bool "actual final publication failed" true (Result.is_error result);
    let instance_id,request_id=proof_address original in
    let proof=Option.get (require (Store.load_host_result store ~instance_id ~request_id)) in
    let changed=match proof with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,
          if key="executions" then (match value with `List [one] -> `List [change one]
            | _ -> fail "expected one original attempt") else value) fields)
      | _ -> fail "expected original execution link" in
    require (Store.save_host_result store ~instance_id ~request_id changed);
    check bool "publication-only recovery refuses malformed proof" true
      (Result.is_error (recover store original));
    let unused,_,_=counting_runner store (ref []) in
    check bool "malformed original refuses rather than becoming absence" true
      (Result.is_error (Exact.run ~authorize_request ~store:(Store.create ~root) ~declaration_id ~package ~runner:unused original));
    check bool "trusted original read refuses the malformed evidence" true
      (Result.is_error (original_execution store original));
    let record=Option.get (require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id)) in
    check bool "refusal neither publishes final nor erases started uncertainty" true
      (Yojson.Safe.Util.member "final" record=`Null)))
    ["request",mutate "request_id" (`String "another original");
     "digest",mutate "digest" (`String (String.make 64 '0'));
     "ordinal",mutate "attempt_ordinal" (`Int 2);
     "store",mutate "store_root" (`String "/another-owner");
     "schema",mutate "schema" (`String "invalid schema");
     "extra",(fun json -> match json with `Assoc fields -> `Assoc (("complete",`Bool true)::fields) | _ -> json);
     "receipt",mutate "receipt" (`Assoc ["exhausted",`Bool true])]

let test_recovery_refuses_malformed_earlier_attempt () =
  with_root (fun root ->
    let store=Store.create ~root in
    let original=request "malformed-earlier-attempt" in
    let first,_,_=counting_runner store (ref [Refused (Exact.Provider_unavailable {detail="first original refusal"})]) in
    ignore (run_request store first original);
    let directory=Filename.concat (Filename.concat root "exact-requests") (Store.digest declaration_id) in
    let second ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ = Ok (fun ~validate ->
      require (before_dispatch Exact.Generation);
      let output=require (validate question) in
      Unix.chmod directory 0o500;
      executed (Exact.Call_ended (Exact.Answered {output;slot="second";usage=None}))) in
    let result=Exact.run ~authorize_request ~store ~declaration_id ~package ~runner:second original in
    Unix.chmod directory 0o700;
    check bool "second final publication failed after its proof" true (Result.is_error result);
    let original_wire=Option.get (require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id)) in
    let started=match attempts store original.request_id with
      | [_;started] -> started | _ -> fail "expected earlier refusal followed by the actual started marker" in
    let broken=match original_wire with
      | `Assoc fields -> `Assoc (("attempts",`List [`String "not an original outcome";started])::List.remove_assoc "attempts" fields)
      | _ -> fail "expected original record" in
    require (Store.save_exact_request store ~declaration_id ~request_id:original.request_id broken);
    let unused,_,_=counting_runner store (ref []) in
    check bool "completed second proof cannot bypass malformed prior history" true
      (Result.is_error (Exact.run ~authorize_request ~store ~declaration_id ~package ~runner:unused original));
    check bool "failed recovery preserves the original record bytes" true
      (require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id)=Some broken))

(* A call that waits for a provider admission permit has sent nothing. Cut off
   there, it leaves the request retained with no started attempt, and the next
   run sends it. *)
let test_a_call_cut_off_before_its_dispatch_is_tried_again () =
  with_root (fun root ->
    let store = Store.create ~root in
    let original = request "cut-before-dispatch" in
    let waiting ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ =
      Ok (fun ~validate:_ -> raise (Eio.Cancel.Cancelled Exit)) in
    (match Exact.run ~authorize_request ~store ~declaration_id ~package ~runner:waiting original with
     | _ -> fail "a cancellation must reach the caller"
     | exception Eio.Cancel.Cancelled _ -> ());
    check bool "the request is retained" true (require (observe store original) = Exact.Retained_open);
    check int "with no started attempt" 0 (List.length (attempts store original.request_id));
    let restarted = Store.create ~root in
    let runner, sends, _ = counting_runner restarted (ref [ Answer question ]) in
    check bool "the next run sends it" true (answered_with question (run_request restarted runner original));
    check int "once" 1 !sends;
    check int "and one attempt is retained" 1 (List.length (attempts restarted original.request_id)))

(* The started marker is written inside the first generation guard: not when
   the call is entered, not at a token measurement, and once for a call that
   reaches a second candidate. *)
let test_the_started_marker_is_written_at_the_first_generation_dispatch () =
  with_root (fun root ->
    let store = Store.create ~root in
    let original = request "marker-at-dispatch" in
    let retained () = require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id) in
    let entered = ref None and measured = ref [] and dispatched = ref [] and again = ref [] in
    let runner ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ =
      Ok (fun ~validate ->
        entered := retained ();
        require (before_dispatch Exact.Measurement);
        measured := attempts store original.request_id;
        require (before_dispatch Exact.Generation);
        dispatched := attempts store original.request_id;
        require (before_dispatch Exact.Generation);
        again := attempts store original.request_id;
        let output = require (validate question) in
        executed (Exact.Call_ended (Exact.Answered { output; slot = "s"; usage = None }))) in
    check bool "the call answers" true (answered_with question (run_request store runner original));
    (match !entered with
     | Some json ->
       check int "the request is retained with no attempt when the call is entered" 0
         (List.length Yojson.Safe.Util.(json |> member "attempts" |> to_list))
     | None -> fail "the call was entered before the request was retained");
    check int "a token measurement writes no attempt" 0 (List.length !measured);
    check bool "the first generation dispatch writes the started marker" true (one_started_marker !dispatched);
    check bool "a later dispatch of the same call keeps that marker" true (!again = !dispatched))

(* A call that ends before any generation dispatch, as when no candidate is
   admitted, still retains its attempt and its proof. *)
let test_a_call_that_ends_without_a_dispatch_retains_its_proof () =
  with_root (fun root ->
    let store = Store.create ~root in
    let original = request "ended-without-dispatch" in
    let resting = Exact.Provider_unavailable { detail = "no candidate was admitted" } in
    let undispatched ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ =
      Ok (fun ~validate:_ -> executed (Exact.Call_refused resting)) in
    check bool "the refusal does not end the request" true
      (run_request store undispatched original = Exact.Not_final (Exact.Provider_refused resting));
    check bool "its attempt is retained and not left started" true
      (match attempts store original.request_id with
       | [ `Assoc fields ] -> not (List.mem_assoc "started" fields)
       | _ -> false);
    (match require (original_execution store original) with
     | Exact.Completed_original { outcome = Exact.Call_refused refusal; _ } ->
       check bool "the proof holds the refusal" true (refusal = resting)
     | Exact.Completed_original { outcome = Exact.Call_ended _; _ } | Exact.No_completed_original ->
       fail "the refused call left no proof");
    let runner, sends, _ = counting_runner store (ref [ Answer question ]) in
    check bool "the next run sends it" true (answered_with question (run_request store runner original));
    check int "once" 1 !sends)

(* The host stops a call whose started marker it cannot write. The directory
   refuses the write, so no marker is on disk and nothing was sent: the run is
   an Error, whether the runner returns the stopped walk or raises through
   it. *)
let test_a_marker_that_cannot_be_written_is_an_error () =
  List.iter (fun raises -> with_root (fun root ->
    let store = Store.create ~root in
    let original = request "unwritable-marker" in
    let directory = Filename.concat (Filename.concat root "exact-requests") (Store.digest declaration_id) in
    let sends = ref 0 in
    let stopped ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ =
      Ok (fun ~validate:_ ->
        Unix.chmod directory 0o500;
        match before_dispatch Exact.Generation with
        | Ok () -> incr sends; fail "the guard passed without its marker"
        | Error detail ->
          if raises then failwith detail
          else executed (Exact.Call_refused (Exact.Provider_unavailable { detail }))) in
    let result = Exact.run ~authorize_request ~store ~declaration_id ~package ~runner:stopped original in
    Unix.chmod directory 0o700;
    check bool "the run reports the failed write" true (Result.is_error result);
    check int "nothing was sent" 0 !sends;
    check bool "the request stays open" true (require (observe store original) = Exact.Retained_open);
    check int "with no attempt" 0 (List.length (attempts store original.request_id));
    let runner, later, _ = counting_runner store (ref [ Answer question ]) in
    check bool "the next run sends it" true (answered_with question (run_request store runner original));
    check int "once" 1 !later)) [ false; true ]

(* A call that ended without a generation dispatch writes its marker before
   its proof. When that save reports a failure, the run is an Error: no
   attempt and no proof are written, and the next run sends the request. *)
let test_an_ended_call_whose_marker_cannot_be_written_is_an_error () =
  with_root (fun root ->
    let store = Store.create ~root in
    let original = request "ended-unwritable-marker" in
    let directory = Filename.concat (Filename.concat root "exact-requests") (Store.digest declaration_id) in
    let resting = Exact.Provider_unavailable { detail = "no candidate was admitted" } in
    let undispatched ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ =
      Ok (fun ~validate:_ ->
        Unix.chmod directory 0o500;
        executed (Exact.Call_refused resting)) in
    let result = Exact.run ~authorize_request ~store ~declaration_id ~package ~runner:undispatched original in
    Unix.chmod directory 0o700;
    check bool "the run reports the failed write" true (Result.is_error result);
    check int "no attempt is written" 0 (List.length (attempts store original.request_id));
    check bool "and no proof" true (require (original_execution store original) = Exact.No_completed_original);
    let runner, sends, _ = counting_runner store (ref [ Answer question ]) in
    check bool "the next run sends it" true (answered_with question (run_request store runner original));
    check int "once" 1 !sends)

(* The marker of a call that ended without a generation dispatch is on disk
   before its proof is written, because a proof is read against its started
   attempt. When the proof cannot be written the run is an Error and the
   marker stays, so the next run ends the request as unknown and sends
   nothing. *)
let test_an_ended_call_writes_its_marker_before_its_proof () =
  with_root (fun root ->
    let store = Store.create ~root in
    let original = request "ended-blocked-proof" in
    let obstruction = Filename.concat root "host-results" in
    let resting = Exact.Provider_unavailable { detail = "no candidate was admitted" } in
    let undispatched ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ =
      Ok (fun ~validate:_ ->
        Out_channel.with_open_bin obstruction (fun channel -> output_string channel "not a proof directory");
        executed (Exact.Call_refused resting)) in
    check bool "failed proof publication is an Error" true
      (Result.is_error (Exact.run ~authorize_request ~store ~declaration_id ~package ~runner:undispatched original));
    check bool "the marker was written before the proof" true
      (one_started_marker (attempts store original.request_id));
    Sys.remove obstruction;
    let unused, sends, _ = counting_runner store (ref []) in
    check bool "the next run ends it as unknown" true
      (run_request store unused original = Exact.Final Exact.Outcome_unknown);
    check bool "cut off in this incarnation" true
      (require (observe store original) = Exact.Retained_terminal (Exact.Retained_unknown Exact.Cut));
    check int "and sends nothing" 0 !sends)

let test_orphaned_proof_prevents_another_dispatch () =
  List.iter (fun preceded_by_unavailable -> with_root (fun root ->
    let store=Store.create ~root in
    let original=request "orphaned-original-proof" in
    let steps=if preceded_by_unavailable then [Unavailable Exact.Lane_off;Answer question] else [Answer question] in
    let first,sends,_=counting_runner store (ref steps) in
    if preceded_by_unavailable then ignore (run_request store first original);
    ignore (run_request store first original);
    let path=Filename.concat (Filename.concat (Filename.concat root "exact-requests") (Store.digest declaration_id))
      (Store.digest original.request_id ^ ".json") in
    Sys.remove path;
    check bool "publication-only recovery refuses an orphan proof" true
      (Result.is_error (recover store original));
    let unused,_,_=counting_runner store (ref []) in
    check bool "orphan proof is not permission to run the original again" true
      (Result.is_error (Exact.run ~authorize_request ~store:(Store.create ~root) ~declaration_id ~package ~runner:unused original));
    check bool "trusted read also refuses proof without its original record" true
      (Result.is_error (original_execution store original));
    check int "the completed original was dispatched once" 1 !sends)) [false;true]

let test_recovered_refusal_is_returned_before_a_later_retry () =
  with_root (fun root ->
    let store=Store.create ~root in
    let original=request "lost-refusal-publication" in
    let directory=Filename.concat (Filename.concat root "exact-requests") (Store.digest declaration_id) in
    let busy=Exact.Provider_unavailable {detail="original refusal before publication loss"} in
    let sends=ref 0 in
    let first ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ = Ok (fun ~validate:_ ->
      require (before_dispatch Exact.Generation);
      incr sends;
      Unix.chmod directory 0o500;
      executed (Exact.Call_refused busy)) in
    let result=Exact.run ~authorize_request ~store ~declaration_id ~package ~runner:first original in
    Unix.chmod directory 0o700;
    check bool "original not-final outcome publication failed" true (Result.is_error result);
    let before=require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id) in
    check bool "proven provider refusal does not become a terminal or a new attempt" true
      (require (recover store original)=Exact.Retained_open);
    check bool "publication-only recovery leaves the nonterminal original unchanged" true
      (before=require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id));
    let unused,_,_=counting_runner store (ref []) in
    check bool "recovery returns that original refusal without a new trigger" true
      (run_request store unused original=Exact.Not_final (Exact.Provider_refused busy));
    check int "only the original call ran before recovery" 1 !sends;
    let later,later_sends,_=counting_runner store (ref [Answer question]) in
    check bool "a separate later trigger can run the next attempt" true
      (answered_with question (run_request store later original));
    check int "later trigger starts its own one call" 1 !later_sends;
    (match require (original_execution store original) with
     | Exact.Completed_original {outcome=Exact.Call_refused refusal;_} ->
       check bool "later success does not replace the original refusal proof" true (refusal=busy)
     | Exact.No_completed_original | Exact.Completed_original _ -> fail "lost original refusal proof"))

let test_completed_attempt_cannot_lose_its_final_and_dispatch_again () =
  with_root (fun root ->
    let store=Store.create ~root in
    let original=request "terminal-without-final" in
    let first,sends,_=counting_runner store (ref [Answer question]) in
    ignore (run_request store first original);
    let wire=Option.get (require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id)) in
    let broken=match wire with
      | `Assoc fields -> `Assoc (("final",`Null)::List.remove_assoc "final" fields)
      | _ -> fail "expected original record" in
    require (Store.save_exact_request store ~declaration_id ~request_id:original.request_id broken);
    let unused,_,_=counting_runner store (ref []) in
    check bool "a terminal attempt with a lost final refuses instead of dispatching" true
      (Result.is_error (Exact.run ~authorize_request ~store ~declaration_id ~package ~runner:unused original));
    check bool "original proof read also rejects contradictory final state" true
      (Result.is_error (original_execution store original));
    check int "only the actual original was sent" 1 !sends)

let test_request_decoding_is_strict () =
  List.iter (fun (label, json) ->
      check bool label true (Result.is_error (Exact.request_of_json json)))
    [ "another kind", `Assoc [ "kind", `String "ask"; "request_id", `String "a"; "output", `String "author"; "messages", `List [ `Assoc [ "role", `String "user"; "text", `String "m" ] ] ]
    ; "no message", `Assoc [ "kind", `String "exact_output"; "request_id", `String "a"; "output", `String "author"; "messages", `List [] ]
    ; "a blank id", `Assoc [ "kind", `String "exact_output"; "request_id", `String " "; "output", `String "author"; "messages", `List [ `Assoc [ "role", `String "user"; "text", `String "m" ] ] ]
    ; "an unknown key", `Assoc [ "kind", `String "exact_output"; "request_id", `String "a"; "output", `String "author"; "messages", `List [ `Assoc [ "role", `String "user"; "text", `String "m" ] ]; "images", `List [] ] ]

let test_conversation_is_retained_with_role_identity () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner, sends, _ = counting_runner store (ref [Answer question]) in
    let make role = require (Exact.request_of_json (`Assoc [
      "kind",`String "exact_output";"request_id",`String "history";"output",`String "author";
      "messages",`List [
        `Assoc ["text",`String "Earlier question";"role",`String "user"];
        `Assoc ["text",`String "Earlier response";"role",`String role]]])) in
    let original = make "assistant" in
    check bool "roles survive canonical encoding" true
      (require (Exact.request_of_json (Exact.request_to_json original)) = original);
    check bool "the conversation answers" true (answered_with question (run_request store runner original));
    check bool "relisting reuses the original answer" true
      (answered_with question (run_request store runner original));
    let changed_role = make "user" in
    check bool "a role change changes request identity" true (Exact.digest original <> Exact.digest changed_role);
    check bool "the same id cannot change a prior speaker" true
      (run_request store runner changed_role = Exact.Final Exact.Request_id_reused);
    check int "no additional provider call" 1 !sends)

let test_conversation_rejects_ambiguous_or_unsupported_wire () =
  let fields = ["kind",`String "exact_output";"request_id",`String "wire";"output",`String "author"] in
  let message = `Assoc ["role",`String "user";"text",`String "question"] in
  List.iter (fun (label,value) -> check bool label true
    (Result.is_error (Exact.request_of_json (`Assoc (fields @ ["messages",`List [value]])))))
    ["untyped strings",`String "question";
     "system turn",`Assoc ["role",`String "system";"text",`String "question"];
     "tool turn",`Assoc ["role",`String "tool";"text",`String "question"];
     "extra message field",`Assoc ["role",`String "user";"text",`String "question";"images",`List []];
     "duplicate speaker",`Assoc ["role",`String "user";"role",`String "assistant";"text",`String "question"];
     "duplicate text",`Assoc ["role",`String "user";"text",`String "a";"text",`String "b"];
     "non-text content",`Assoc ["role",`String "user";"text",`List []]];
  check bool "duplicate request fields are refused before identity is computed" true
    (Result.is_error (Exact.request_of_json (`Assoc
      (fields @ ["output",`String "another";"messages",`List [message]]))))

let consumer_schema = `Assoc ["$schema",`String "https://json-schema.org/draft/2020-12/schema";
  "type",`String "object";"required",`List [`String "question"];
  "properties",`Assoc ["question",`Assoc ["anyOf",`List [
    `Assoc ["type",`String "string"];`Assoc ["type",`String "null"]]]]]
let consumer_package = {package with exact_outputs=[{
  Types.name="author";schema;request_schema=Types.Consumer_request_schema}]}
let consumer_run store runner request = require (Exact.run ~authorize_request ~store ~declaration_id
  ~package:consumer_package ~runner request)

let test_request_schema_authority_and_retention () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner,sends,_=counting_runner store (ref [Answer question]) in
    let original=request ~schema:consumer_schema "dynamic" in
    check bool "permitted request answers" true (answered_with question (consumer_run store runner original));
    (match run_request store runner original with
     | Exact.Final (Not_allowed _) -> ()
     | _ -> fail "revoking the grant must refuse retained delivery");
    check bool "restoring the grant restores the original answer" true
      (answered_with question (consumer_run store runner original));
    let different=request ~schema:(`Assoc ["type",`String "object"]) "dynamic" in
    check bool "schema participates in request identity" true
      (consumer_run store runner different=Exact.Final Exact.Request_id_reused);
    check int "no extra provider dispatch" 1 !sends;
    let forbidden=request ~schema:consumer_schema "new-denied" in
    (match run_request store runner forbidden with
     | Exact.Final (Not_allowed _) -> () | _ -> fail "a new request needs a package grant");
    (match consumer_run store runner forbidden with
     | Exact.Final (Not_allowed _) -> () | _ -> fail "a new refusal remains a retained terminal"))

let test_request_schema_is_provider_requirement_not_baseline_replacement () =
  with_root (fun root ->
    let store=Store.create ~root in
    let sent_schema=ref None in
    let runner ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema ~size_refused:_ _request =
      sent_schema:=Some schema;
      Ok (fun ~validate -> match validate (`Assoc ["question",`Null]) with
        | Ok output -> executed (Exact.Call_ended (Answered {output;slot="fixture";usage=None}))
        | Error detail -> executed (Exact.Call_ended (Invalid_output {detail}))) in
    (match consumer_run store runner (request ~schema:consumer_schema "baseline") with
     | Exact.Final (Call_final (Invalid_output _)) -> ()
     | _ -> fail "the baseline string must hold even when the request allows null");
    check bool "the requested dialect goes to the provider" true
      (!sent_schema=Some (require (Masc.Lane_addon_action.canonical consumer_schema)));
    let runner,sends,_=counting_runner store (ref [Answer (`Assoc [])]) in
    (match consumer_run store runner (request ~schema:consumer_schema "required") with
     | Exact.Final (Call_final (Invalid_output _)) -> ()
     | _ -> fail "required request shape applies even when the baseline permits a missing field");
    check int "one call" 1 !sends)

let test_request_schema_canonical_wire () =
  let make schema = `Assoc ["kind",`String "exact_output";"request_id",`String "canonical";
    "output",`String "author";"messages",`List [`Assoc ["role",`String "user";"text",`String "question"]];
    "schema",schema] in
  let ordered=make (`Assoc ["type",`String "object";"required",`List [`String "question"]]) |> Exact.request_of_json |> require in
  let reversed=make (`Assoc ["required",`List [`String "question"];"type",`String "object"]) |> Exact.request_of_json |> require in
  check string "schema object order does not change retained identity" (Exact.digest ordered) (Exact.digest reversed);
  List.iter (fun schema -> check bool "schema must be an unambiguous JSON object" true
    (Result.is_error (Exact.request_of_json (make schema))))
    [`Null;`Bool true;`String "{}";`Assoc ["type",`String "object";"type",`String "string"]]

let test_unknown_is_preserved_before_schema_grant_refusal () =
  with_root (fun root ->
    let store=Store.create ~root in
    let pending=request ~schema:consumer_schema "unknown-schema" in
    require (Store.save_exact_request store ~declaration_id ~request_id:pending.request_id
      (`Assoc ["declaration_id",`String declaration_id;"request_id",`String pending.request_id;
        "digest",`String (Exact.digest pending);"request",Exact.request_to_json pending;
        "attempts",`List [other_process_marker];"final",`Null]));
    let runner,sends,_=counting_runner store (ref []) in
    ignore (run_request store runner pending);
    check bool "grant restoration cannot replay an uncertain call" true
      (consumer_run store runner pending=Exact.Final Exact.Outcome_unknown);
    check int "provider never re-entered" 0 !sends)

let test_observe_missing_and_original_terminal_without_another_call ()=with_root (fun root ->
  let store=Store.create ~root in
  let original=request "readonly-original" in
  check bool "strict missing record stays absent" true (require (observe store original)=Exact.Retained_absent);
  check bool "absence does not create a store" false (Sys.file_exists root);
  let runner,sends,_=counting_runner store (ref [Answer question]) in
  ignore (run_request store runner original);
  let before=require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id) in
  let read store=match require (observe store original) with
    | Exact.Retained_terminal (Exact.Retained_call (Exact.Answered {output;_})) ->
      check bool "original answer is observed" true (Exact.checked_json output=question)
    | _ -> fail "terminal observation did not preserve the original result" in
  read store;read (Store.create ~root);
  check int "read never invokes the provider" 1 !sends;
  check bool "terminal record is unchanged" true (before=require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id));
  check bool "same ID with another original input refuses" true
    (Result.is_error (observe store (request ~message:"Different input" original.request_id))))
let test_observe_started_is_open_while_provider_is_running ()=with_root (fun root ->
  let store=Store.create ~root in
  let original=request "readonly-running" in
  let runner ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _=Ok (fun ~validate ->
    require (before_dispatch Exact.Generation);
    let before=require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id) in
    check bool "actual provider's started record remains open" true
      (require (observe (Store.create ~root) original)=Exact.Retained_open);
    check bool "publication recovery respects the active original claim" true
      (require (recover (Store.create ~root) original)=Exact.Retained_open);
    check bool "read cannot infer terminal uncertainty or rewrite started history" true
      (before=require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id));
    let output=require (validate question) in executed (Exact.Call_ended (Exact.Answered {output;slot="original";usage=None}))) in
  check bool "the actual in-flight call can still answer" true (answered_with question (run_request store runner original)))
let test_observe_exception_and_later_denial_preserves_original ()=with_root (fun root ->
  let store=Store.create ~root in
  let original=request "readonly-exception" in
  let runner ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _=Ok (fun ~validate:_ ->
    require (before_dispatch Exact.Generation);
    raise Exit) in
  ignore (run_request store runner original);
  let hidden={package with exact_outputs=[]} in
  ignore (require (Exact.run ~authorize_request ~store ~declaration_id ~package:hidden ~runner original));
  check bool "exception evidence and denial audit do not replace the original unknown" true
    (require (observe (Store.create ~root) original)=Exact.Retained_terminal (Exact.Retained_unknown Exact.Raised));
  let valid=request "readonly-denied-answer" in
  let answer,_,_=counting_runner store (ref [Answer question]) in
  ignore (run_request store answer valid);
  ignore (require (Exact.run ~authorize_request ~store ~declaration_id ~package:hidden ~runner:answer valid));
  check bool "host observation is the original answer, not package redelivery" true
    (match require (observe store valid) with
     | Exact.Retained_terminal (Exact.Retained_call (Exact.Answered {output;_})) -> Exact.checked_json output=question
     | _ -> false))
let test_observe_interrupted_attempt_with_later_denial ()=with_root (fun root ->
  let store=Store.create ~root in
  let original=request "readonly-interrupted" in
  require (Store.save_exact_request store ~declaration_id ~request_id:original.request_id (`Assoc [
    "declaration_id",`String declaration_id;"request_id",`String original.request_id;
    "digest",`String (Exact.digest original);"request",Exact.request_to_json original;
    "attempts",`List [other_process_marker];"final",`Null]));
  check bool "read alone leaves the interrupted attempt open" true (require (observe store original)=Exact.Retained_open);
  let runner,sends,_=counting_runner store (ref []) in
  ignore (require (Exact.run ~authorize_request ~store ~declaration_id ~package:{package with exact_outputs=[]} ~runner original));
  check bool "recovered cause survives later delivery denial" true
    (require (observe store original)=Exact.Retained_terminal (Exact.Retained_unknown Exact.Interrupted));
  check int "observing recovery never sends again" 0 !sends)
let test_observe_rejects_malformed_identity_attempts_and_schema ()=with_root (fun root ->
  let store=Store.create ~root in
  let original=request "readonly-tampered" in
  let runner,_,_=counting_runner store (ref [Answer question]) in ignore (run_request store runner original);
  let wire=match require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id) with
    | Some wire -> wire | None -> fail "original fixture record" in
  let replace key value=match wire with `Assoc fields -> `Assoc (List.map (fun (name,old) -> name,if name=key then value else old) fields)
    | _ -> fail "original fixture object" in
  let variants=[replace "declaration_id" (`String "another-installation");replace "request_id" (`String "another-request");
    replace "digest" (`String "different");replace "request" (Exact.request_to_json (request ~message:"other" original.request_id));
    replace "attempts" (`List [`Assoc ["reason",`String "provider_unavailable";"detail",`String "original";"extra",`Bool true]]);
    replace "attempts" (`List [`Assoc ["status",`String "answered";"slot",`String "slot";"output",question;"exception",`String "not unknown"]]);
    replace "final" (`Assoc ["status",`String "answered";"slot",`String "slot";"output",`String "wrong shape"]);
    (match wire with `Assoc fields -> `Assoc (("extra",`Bool true)::fields) | _ -> fail "object")] in
  List.iter (fun invalid ->
    require (Store.save_exact_request store ~declaration_id ~request_id:original.request_id invalid);
    check bool "malformed stored evidence is neither absent nor terminal authority" true (Result.is_error (observe store original))) variants;
  require (Store.save_exact_request store ~declaration_id ~request_id:original.request_id wire);
  let granted=request ~schema "readonly-granted" in
  check bool "a supplied schema cannot weaken the original request grant" true
    (Result.is_error (Exact.observe_retained ~store ~declaration_id ~schema:(`Assoc ["type",`String "string"]) granted)))

let test_host_admission_class_is_forwarded admission_class () =
  with_root (fun root ->
    let store=Store.create ~root in
    let original=request "host-policy" in
    let expected_wire=Exact.request_to_json original and expected_digest=Exact.digest original in
    let observed=ref [] in
    let authorize_request ~store:_ ~declaration_id:_ ~package:_ _ =
      Ok {Exact.admission_class; before_dispatch=(fun () -> Ok ()); with_execution=(fun run -> run ()); validate_output=(fun _ -> Ok ())} in
    let runner ~before_dispatch:_ ~admission_class ~lane_key:_ ~schema:_ ~size_refused:_ _ =
      observed:=admission_class :: !observed;
      Ok (fun ~validate ->
        match validate question with
        | Ok output -> executed (Exact.Call_ended (Exact.Answered {output;slot="host-slot";usage=None}))
        | Error detail -> fail detail) in
    check bool "host-authorized request answers" true
      (answered_with question (require (Exact.run ~store ~declaration_id ~package
        ~authorize_request ~runner original)));
    check bool "the broker forwards the host's exact typed class" true (!observed=[admission_class]);
    let stored=match require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id) with
      | Some stored -> stored | None -> fail "original execution record was not retained" in
    check bool "host policy does not change the retained worker request" true
      (Yojson.Safe.equal expected_wire (Yojson.Safe.Util.member "request" stored));
    check string "host policy does not change the retained request digest" expected_digest
      (Yojson.Safe.Util.member "digest" stored |> Yojson.Safe.Util.to_string))

let test_retained_delivery_rechecks_host_authority () =
  with_root (fun root ->
    let store=Store.create ~root in
    let original=request "fresh-host-authority" in
    let permitted=ref true and checks=ref 0 in
    let authorize_request ~store:_ ~declaration_id:_ ~package:_ _ =
      incr checks;
      if !permitted then
        Ok {Exact.admission_class=Agent_core.Llm_provider.Admission_class.Background;
            before_dispatch=(fun () -> Ok ()); with_execution=(fun run -> run ()); validate_output=(fun _ -> Ok ())}
      else Error (Exact.Undecided {detail="original host authority is unavailable"}) in
    let runner,sends,_=counting_runner store (ref [Answer question]) in
    let execute store = Exact.run ~store ~declaration_id ~package ~authorize_request ~runner original in
    check bool "original answers" true (answered_with question (require (execute store)));
    let original_record=require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id) in
    permitted:=false;
    let reopened=Store.create ~root in
    check bool "reopened retained delivery needs fresh host authority" true (Result.is_error (execute reopened));
    check bool "authority refusal preserves the complete original result" true
      (original_record=require (Store.load_exact_request reopened ~declaration_id ~request_id:original.request_id));
    permitted:=true;
    check bool "restored authority delivers the original answer" true
      (answered_with question (require (execute reopened)));
    check int "authority is read on every new and retained request" 3 !checks;
    check int "retained delivery never resolves or runs another provider" 1 !sends;
    check bool "successful replay preserves the original record too" true
      (original_record=require (Store.load_exact_request reopened ~declaration_id ~request_id:original.request_id)))

let test_authority_refusal_does_not_start_a_request () =
  with_root (fun root ->
    let store=Store.create ~root in
    let original=request "host-refused-before-start" in
    let authorize_request ~store:_ ~declaration_id:_ ~package:_ _ =
      Error (Exact.Undecided {detail="original binding is unreadable"}) in
    let runner ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ = fail "refused original reached the runner" in
    check bool "new request preserves host refusal" true
      (Result.is_error (Exact.run ~store ~declaration_id ~package ~authorize_request ~runner original));
    check bool "no admission or started record was published" true
      (require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id)=None))

let owned_authority owned ~store:_ ~declaration_id:_ ~package:_ _ =
  if !owned then Ok {Exact.admission_class=Agent_core.Llm_provider.Admission_class.Standard;
                     before_dispatch=(fun () -> Ok ());
                     with_execution=(fun run -> run ());
                     validate_output=(fun _ -> Ok ())}
  else Error (Exact.Unowned {reason="no original host request owns it"})

let test_an_unowned_request_ends_as_not_allowed () =
  with_root (fun root ->
    let owned=ref false in
    let runner,sends,_=counting_runner (Store.create ~root) (ref []) in
    let execute store = require (Exact.run ~store ~declaration_id ~package
        ~authorize_request:(owned_authority owned) ~runner (request "unowned")) in
    check bool "an unowned request ends as not_allowed with the owner's reason" true
      (match execute (Store.create ~root) with
       | Exact.Final (Exact.Not_allowed {reason}) -> reason="no original host request owns it"
       | Exact.Final _ | Exact.Not_final _ -> false);
    owned:=true;
    check bool "the refusal is retained across a restart and a later grant" true
      (match execute (Store.create ~root) with
       | Exact.Final (Exact.Not_allowed _) -> true | Exact.Final _ | Exact.Not_final _ -> false);
    check int "without a send" 0 !sends)

let test_an_unowned_retained_answer_is_refused_and_kept () =
  with_root (fun root ->
    let store=Store.create ~root in
    let owned=ref true in
    let runner,sends,_=counting_runner store (ref [Answer question]) in
    let execute () = require (Exact.run ~store ~declaration_id ~package
        ~authorize_request:(owned_authority owned) ~runner (request "kept-answer")) in
    check bool "the owned request answers" true (answered_with question (execute ()));
    owned:=false;
    check bool "once unowned the answer is refused" true
      (match execute () with Exact.Final (Exact.Not_allowed _) -> true | Exact.Final _ | Exact.Not_final _ -> false);
    check int "the refusal is recorded beside the original answer" 2 (List.length (attempts store "kept-answer"));
    owned:=true;
    check bool "the original answer is delivered once it is owned again" true (answered_with question (execute ()));
    check int "one provider call across the refusal" 1 !sends)

let test_execution_guard_is_not_retained_delivery_authority () =
  with_root (fun root ->
    let store=Store.create ~root in
    let original=request "execution-only-guard" in
    let permit=ref false and checks=ref 0 and scopes=ref 0 and active=ref false in
    let authorize_request ~store:_ ~declaration_id:_ ~package:_ _ =
      Ok {Exact.admission_class=Agent_core.Llm_provider.Admission_class.Background;
        with_execution=(fun run ->
          incr scopes;active:=true;
          Fun.protect ~finally:(fun () -> active:=false) (fun () ->
            let result=run () in
            if !permit then
              check bool "scope owns final publication before it exits" true
                (match require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id) with
                 | Some wire -> Yojson.Safe.Util.member "final" wire<>`Null
                 | None -> false);
            result));
        validate_output=(fun _ -> Ok ());
        before_dispatch=(fun () ->
          check bool "lifecycle registration precedes initial authority" true !active;incr checks;
          if !permit then Ok () else Error "original semantic configuration changed")} in
    let runner,sends,_=counting_runner store (ref [Answer question]) in
    let execute ()=Exact.run ~store ~declaration_id ~package ~authorize_request ~runner original in
    check bool "a semantic revision veto does not resolve a provider" true (Result.is_error (execute ()));
    check int "no provider sends before execution authority" 0 !sends;
    check bool "initial veto leaves no started marker" true
      (require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id)=None);
    permit:=true;
    check bool "permitted original answers" true (answered_with question (require (execute ())));
    let retained=require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id) in
    let before= !checks and scopes_before= !scopes in
    permit:=false;
    check bool "a returned original answer survives execution authority changing" true
      (answered_with question (require (execute ())));
    check int "retained delivery never asks the execution-only guard" before !checks;
    check int "retained delivery never opens an external lifecycle scope" scopes_before !scopes;
    check bool "every inline execution scope has already exited" false !active;
    check int "the original provider was called once" 1 !sends;
    check bool "local observation still sees the original terminal while dispatch is forbidden" true
      (match require (Exact.observe_retained ~store ~declaration_id ~schema original) with
       | Exact.Retained_terminal (Retained_call (Answered _)) -> true
       | Retained_absent | Retained_open | Retained_terminal _ -> false);
    check bool "execution authority changes preserve original bytes" true
      (retained=require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id)))

let test_worker_cannot_select_admission_policy () =
  let original=request "untrusted-policy" in
  let fields=match Exact.request_to_json original with
    | `Assoc fields -> fields | _ -> fail "expected original request object" in
  List.iter (fun field ->
    check bool "worker policy field is not accepted as permission" true
      (Result.is_error (Exact.request_of_json (`Assoc ((field,`String "background")::fields)))))
    ["priority";"admission_class"]

let test_host_cause_codec_keeps_worker_wire () =
  List.iter (fun cause ->
    let retained=Exact.Retained_unknown cause in
    let wire=Exact.retained_final_to_json retained in
    check bool "host evidence round-trips its cause" true
      (require (Exact.retained_final_of_json ~schema wire)=retained);
    check bool "worker receives the unchanged unknown shape" true
      (Exact.final_to_json (Exact.delivered retained)=`Assoc ["status",`String "outcome_unknown"]);
    check bool "worker decoder cannot accept host-only cause" true
      (Result.is_error (Exact.final_of_json ~schema wire))) [Exact.Interrupted;Exact.Cut;Exact.Raised];
  List.iter (fun wire ->
    check bool "host evidence refuses missing, unknown, extra and duplicate causes" true
      (Result.is_error (Exact.retained_final_of_json ~schema wire)))
    [`Assoc ["status",`String "outcome_unknown"];
     `Assoc ["status",`String "outcome_unknown";"cause",`String "other"];
     `Assoc ["status",`String "outcome_unknown";"cause",`String "cut";"exception",`String "no"];
     `Assoc ["status",`String "outcome_unknown";"cause",`String "cut";"cause",`String "raised"]]

let test_host_record_hard_cut_and_attempt_order ()=with_root (fun root ->
  let store=Store.create ~root in
  let original=request "strict-host-attempts" in
  let raised,_,_=counting_runner store (ref [Answer question]) in
  ignore (run_request store raised original);
  let base=Option.get (require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id)) in
  let record attempts final=match base with
    | `Assoc fields -> `Assoc (("attempts",`List attempts)::("final",final)::
        (fields |> List.remove_assoc "attempts" |> List.remove_assoc "final"))
    | _ -> fail "original Exact object expected" in
  let unknown=`Assoc ["status",`String "outcome_unknown"] in
  let interrupted=Exact.retained_final_to_json (Exact.Retained_unknown Exact.Interrupted) in
  let cut=Exact.retained_final_to_json (Exact.Retained_unknown Exact.Cut) in
  let raised=`Assoc ["status",`String "outcome_unknown";"cause",`String "raised";"exception",`String "original error"] in
  List.iter (fun wire -> check bool "preflight decoder accepts new host attempt shapes" true
    (Result.is_ok (Exact.check_retained_record ~store ~first:wire ~proof:None ~second:wire)))
    [record [other_process_marker] `Null;record [interrupted] unknown;record [cut] unknown;record [raised] unknown];
  let answered=Yojson.Safe.Util.member "final" base in
  List.iter (fun wire ->
    check bool "preflight decoder rejects old or inconsistent attempt evidence" true
      (Result.is_error (Exact.check_retained_record ~store ~first:wire ~proof:None ~second:wire));
    require (Store.save_exact_request store ~declaration_id ~request_id:original.request_id wire);
    check bool "read-only host observation refuses the same malformed record" true
      (Result.is_error (observe store original)))
    [record [`Null] `Null; record [`Null] unknown; record [unknown] unknown;
     record [interrupted] `Null;record [interrupted] answered;
     record [other_process_marker;cut] unknown;record [other_process_marker] unknown;
     record [`Assoc ["started",`String "not-an-incarnation"]] `Null;
     record [`Assoc ["status",`String "outcome_unknown";"cause",`String "raised"]] unknown;
     record [`Assoc ["status",`String "outcome_unknown";"cause",`String "raised";"exception",`String " "]] unknown;
     record [`Assoc ["status",`String "outcome_unknown";"cause",`String "cut";"exception",`String "not raised"]] unknown])

(* The deploy preflight reads a record with its proof link the way [run] does
   (RFC exact-request-skips-a-slot-that-refused-its-input 3.3). [run] writes
   each store below the workspace the preflight is pointed at. *)
module Preflight = Masc.Lane_addon_store_preflight
module Observation = Masc.Lane_addon_exact_observation

let with_workspace f =
  let base = Filename.temp_file "lane-exact-preflight-" ".fixture" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
    Eio_main.run (fun _env ->
      let root = Store.directory ~masc_dir:(Common.masc_dir_from_base_path ~base_path:base) in
      f ~base (Store.create ~root)))

let answered store id =
  let original = request id in
  let runner,_,_ = counting_runner store (ref [Answer question]) in
  ignore (run_request store runner original);
  original

let record_file store original =
  Filename.concat (Store.root store)
    (Store.exact_request_path ~declaration_id ~request_id:original.Exact.request_id)

let link_file store original =
  let instance_id,request_id = proof_address original in
  Filename.concat (Store.root store) (Store.host_result_path ~instance_id ~request_id)

let read_bytes path = In_channel.with_open_bin path In_channel.input_all
let write_bytes path bytes = Out_channel.with_open_bin path (fun out -> output_string out bytes)

let preflight ?(after_read=ignore) base =
  match Preflight.For_testing.scan ~after_read Preflight.Store.Exact_requests ~base_path:base with
  | Ok report -> report
  | Error detail -> fail detail

let refused (report : Preflight.report) =
  List.map (fun (refusal : Preflight.refusal) -> refusal.path, refusal.delete) report.Preflight.refusals

let readers (report : Preflight.report) =
  List.map (fun (refusal : Preflight.refusal) -> Preflight.decoder_name refusal.decoder) report.Preflight.refusals

let test_preflight_deletes_a_refused_record_with_its_link_and_observations () =
  with_workspace (fun ~base store ->
    let original = answered store "preflight-refused" in
    ignore (answered store "preflight-kept");
    let link = link_file store original in
    let proof = match Yojson.Safe.Util.member "executions" (Yojson.Safe.from_file link) with
      | `List [proof] -> proof
      | _ -> fail "expected one original proof" in
    require (Observation.retain ~store ~declaration_id ~request_id:original.Exact.request_id
      ~attempt_ordinal:1 ~proof []);
    let observations = Filename.concat (Store.root store) (Observation.directory ~declaration_id) in
    let observed = Sys.readdir observations |> Array.to_list |> List.map (Filename.concat observations) in
    let record = record_file store original in
    (* An old null marker: [run] refuses the record, whose ids stay readable. *)
    (match Yojson.Safe.from_file record with
     | `Assoc fields ->
       Yojson.Safe.to_file record
         (`Assoc (("attempts",`List [`Null])::("final",`Null)::
                  (fields |> List.remove_assoc "attempts" |> List.remove_assoc "final")))
     | _ -> fail "original Exact object expected");
    let report = preflight base in
    check int "both records and the observation file are read" 3 report.Preflight.rows;
    check (list (pair string (list string))) "fresh state deletes the record with its link and observation"
      [record, record :: link :: observed] (refused report);
    check (list string) "the record reader refuses it"
      [Preflight.decoder_name Preflight.Exact_record] (readers report))

let test_preflight_reads_the_proof_link_with_its_record () =
  let renumbered link = match Yojson.Safe.from_file link with
    | `Assoc fields ->
      let renumber = function
        | `Assoc entry -> `Assoc (List.map (fun (name,value) ->
            if String.equal name "attempt_ordinal" then name,`Int 2 else name,value) entry)
        | entry -> entry in
      Yojson.Safe.to_file link (`Assoc (List.map (fun (name,value) -> match name,value with
        | "executions",`List entries -> name,`List (List.map renumber entries)
        | _ -> name,value) fields))
    | _ -> fail "original execution link object expected" in
  List.iter (fun (label,damage,at_link,decoder) -> with_workspace (fun ~base store ->
    let original = answered store "preflight-link" in
    let record = record_file store original and link = link_file store original in
    damage link;
    let report = preflight base in
    check (list (pair string (list string))) label
      [(if at_link then link else record), [record; link]] (refused report);
    check (list string) (label ^ ": refusing reader") [Preflight.decoder_name decoder] (readers report)))
    [ "a link that is not JSON is refused with its record",(fun link -> write_bytes link "{"),true,Preflight.Json
    ; "a proof of an attempt the record lacks refuses the record with its link",renumbered,false,Preflight.Exact_record ]

let test_preflight_refuses_a_misfiled_record_alone () =
  with_workspace (fun ~base store ->
    let original = answered store "preflight-filed" in
    let record = record_file store original in
    let misfiled = Filename.concat (Store.root store)
        (Store.exact_request_path ~declaration_id ~request_id:"preflight-elsewhere") in
    write_bytes misfiled (read_bytes record);
    let report = preflight base in
    check int "both files are read" 2 report.Preflight.rows;
    check (list (pair string (list string))) "a record under another request's key is deleted alone"
      [misfiled, [misfiled]] (refused report))

let test_preflight_refuses_a_link_no_record_names () =
  with_workspace (fun ~base store ->
    let orphaned = answered store "preflight-orphaned" in
    ignore (answered store "preflight-named");
    let link = link_file store orphaned in
    Sys.remove (record_file store orphaned);
    let report = preflight base in
    check (list (pair string (list string))) "the link without its record is deleted alone"
      [link, [link]] (refused report);
    check (list string) "no record names it"
      [Preflight.decoder_name Preflight.Exact_proof_link] (readers report))

let test_preflight_names_a_link_written_after_the_listing () =
  with_workspace (fun ~base store ->
    let listed = answered store "preflight-listed" in
    let later = request "preflight-later" in
    let runner,_,_ = counting_runner store (ref [Answer question]) in
    let record = record_file store listed in
    (* The server answers another request after the check listed the records
       and before it lists the proof links. *)
    let wrote = ref false in
    let after_read path =
      if String.equal path record && not !wrote then (
        wrote := true;
        ignore (run_request store runner later)) in
    let report = preflight ~after_read base in
    check bool "the server wrote during the check" true !wrote;
    check bool "the later request has its link" true (Sys.file_exists (link_file store later));
    check (list (pair string (list string))) "the record listed again names the later link" []
      (refused report))

let test_preflight_refuses_a_slot_observation_the_sweep_cannot_read () =
  with_workspace (fun ~base store ->
    ignore (answered store "preflight-observed");
    let observations = Filename.concat (Store.root store) (Observation.directory ~declaration_id) in
    Unix.mkdir observations 0o700;
    let unreadable = Filename.concat observations "unreadable.json" in
    write_bytes unreadable {|{"version":1}|};
    let report = preflight base in
    check (list (pair string (list string))) "the observation file is deleted alone"
      [unreadable, [unreadable]] (refused report);
    check (list string) "the sweep's read refuses it"
      [Preflight.decoder_name Preflight.Exact_slot_observation] (readers report))

let test_preflight_stops_on_another_store_root () =
  with_workspace (fun ~base store ->
    ignore (answered store "preflight-moved");
    let alias = Filename.temp_file "lane-exact-preflight-alias-" ".fixture" in
    Sys.remove alias;
    Unix.symlink base alias;
    Fun.protect ~finally:(fun () -> Sys.remove alias) (fun () ->
      match Preflight.For_testing.scan ~after_read:ignore Preflight.Store.Exact_requests ~base_path:alias with
      | Ok _ -> fail "a link written under another store root must stop the check"
      | Error detail ->
        check bool ("the stop names both roots: " ^ detail) true
          (Astring.String.is_infix ~affix:(Store.root store) detail
           && Astring.String.is_infix ~affix:alias detail)))

let test_preflight_binds_a_link_written_between_its_reads () =
  with_workspace (fun ~base store ->
    let original = request "preflight-appended" in
    let busy = Exact.Provider_unavailable {detail="synthetic first refusal"} in
    let runner,_,_ = counting_runner store (ref [Refused busy; Answer question]) in
    let record = record_file store original and link = link_file store original in
    ignore (run_request store runner original);
    let first_record = read_bytes record and first_link = read_bytes link in
    ignore (run_request store runner original);
    let second_record = read_bytes record and second_link = read_bytes link in
    write_bytes record first_record;
    write_bytes link first_link;
    (* The server writes attempt 2 to the record, then proof 2, while the
       check is between its first read of the record and its read of the link. *)
    let appended = ref false in
    let after_read path =
      if String.equal path record && not !appended then (
        appended := true;
        write_bytes record second_record;
        write_bytes link second_link) in
    let report = preflight ~after_read base in
    check bool "the server wrote after the first read" true !appended;
    check int "the record is read" 1 report.Preflight.rows;
    check (list (pair string (list string))) "the link is bound to the record read after it" []
      (refused report))

let () =
  run "lane add-on exact requests"
    [ ( "retention"
      , [ test_case "host cause codec preserves worker wire" `Quick test_host_cause_codec_keeps_worker_wire
        ; test_case "host hard cut validates attempt order and cause evidence" `Quick test_host_record_hard_cut_and_attempt_order
        ; test_case "a record republished during a read is read again" `Quick test_republished_record_is_read_again
        ; test_case "retained before the call and replayed after a restart" `Quick test_retained_before_the_call_and_replayed
        ; test_case "an unavailable lane sends nothing and survives a restart" `Quick
            test_an_unavailable_lane_sends_nothing_and_survives_a_restart
        ; test_case "a provider refusal that may pass is tried again" `Quick
            test_a_provider_refusal_that_may_pass_is_tried_again
        ; test_case "an answer outside the schema is not answered" `Quick
            test_an_answer_outside_the_schema_is_not_answered
        ; test_case "a reused request id is refused" `Quick test_a_reused_request_id_is_refused
        ; test_case "a started attempt without outcome is unknown" `Quick test_a_started_attempt_without_outcome_is_unknown
        ; test_case "an exception ends the request as unknown" `Quick test_an_exception_ends_the_request_as_unknown
        ; test_case "an exception before the first generation dispatch is an error" `Quick
            test_an_exception_before_the_first_generation_dispatch_is_an_error
        ; test_case "an undeclared output is not allowed" `Quick test_an_undeclared_output_is_not_allowed
        ; test_case "selection hides but preserves a retained answer" `Quick test_selection_hides_but_preserves_a_retained_answer
        ; test_case "a request in flight is not run twice" `Quick test_a_request_in_flight_is_not_run_twice
        ; test_case "a cancelled call leaves its attempt started" `Quick test_a_cancelled_call_leaves_its_attempt_started
        ; test_case "a call cut off before its dispatch is tried again" `Quick
            test_a_call_cut_off_before_its_dispatch_is_tried_again
        ; test_case "the started marker is written at the first generation dispatch" `Quick
            test_the_started_marker_is_written_at_the_first_generation_dispatch
        ; test_case "a call that ends without a dispatch retains its proof" `Quick
            test_a_call_that_ends_without_a_dispatch_retains_its_proof
        ; test_case "a marker that cannot be written is an error" `Quick
            test_a_marker_that_cannot_be_written_is_an_error
        ; test_case "an ended call whose marker cannot be written is an error" `Quick
            test_an_ended_call_whose_marker_cannot_be_written_is_an_error
        ; test_case "an ended call writes its marker before its proof" `Quick
            test_an_ended_call_writes_its_marker_before_its_proof
        ; test_case "a retained answer is checked against the schema declared now" `Quick
            test_a_retained_answer_is_checked_against_the_schema_declared_now
        ; test_case "confirmed proof recovers lost outcome publication" `Quick
            test_confirmed_proof_recovers_lost_outcome_publication
        ; test_case "v2 proof recovers lost outcome publication" `Quick
            test_v2_proof_recovers_lost_outcome_publication
        ; test_case "original consumer recovers proof without worker RPC" `Quick
            test_original_consumer_recovers_proof_without_worker_rpc
        ; test_case "publication recovery preserves an unproven original" `Quick
            test_publication_recovery_preserves_unproven_original
        ; test_case "original execution binds request schema and actual attempt" `Quick test_original_execution_is_bound_to_one_attempt
        ; test_case "v1 and v2 original proofs remain distinct" `Quick test_v1_and_v2_original_proofs_remain_distinct
        ; test_case "latest original evidence cannot borrow a previous attempt" `Quick test_latest_execution_never_borrows_an_earlier_proof
        ; test_case "proof failure leaves uncertainty without exposing an answer" `Quick test_proof_publication_failure_never_exposes_an_answer
        ; test_case "malformed proof refuses local recovery without provider replay" `Quick test_malformed_proof_refuses_publication_recovery
        ; test_case "recovery validates the complete original attempt history" `Quick test_recovery_refuses_malformed_earlier_attempt
        ; test_case "orphan original proof prevents a duplicate dispatch" `Quick test_orphaned_proof_prevents_another_dispatch
        ; test_case "recovered refusal returns before a later retry" `Quick test_recovered_refusal_is_returned_before_a_later_retry
        ; test_case "completed terminal without final cannot dispatch again" `Quick test_completed_attempt_cannot_lose_its_final_and_dispatch_again
        ; test_case "request decoding is strict" `Quick test_request_decoding_is_strict
        ; test_case "conversation retention binds speaker roles" `Quick test_conversation_is_retained_with_role_identity
        ; test_case "conversation wire refuses ambiguous roles" `Quick test_conversation_rejects_ambiguous_or_unsupported_wire
        ; test_case "request schema authority preserves retained identity" `Quick test_request_schema_authority_and_retention
        ; test_case "provider schema cannot weaken the package baseline" `Quick test_request_schema_is_provider_requirement_not_baseline_replacement
        ; test_case "request schema wire is canonical" `Quick test_request_schema_canonical_wire
        ; test_case "unknown outcome survives schema grant changes" `Quick test_unknown_is_preserved_before_schema_grant_refusal
        ; test_case "host observes original terminal without replay or package delivery" `Quick test_observe_missing_and_original_terminal_without_another_call
        ; test_case "started provider remains open during a read" `Quick test_observe_started_is_open_while_provider_is_running
        ; test_case "exception and denial audit preserve the original terminal" `Quick test_observe_exception_and_later_denial_preserves_original
        ; test_case "interrupted started marker and denial audit remain valid" `Quick test_observe_interrupted_attempt_with_later_denial
        ; test_case "strict original identity attempt and schema validation" `Quick test_observe_rejects_malformed_identity_attempts_and_schema
        ; test_case "trusted Background reaches the runner" `Quick
            (test_host_admission_class_is_forwarded Agent_core.Llm_provider.Admission_class.Background)
        ; test_case "trusted Standard reaches the runner" `Quick
            (test_host_admission_class_is_forwarded Agent_core.Llm_provider.Admission_class.Standard)
        ; test_case "retained delivery rechecks authority without replacing original" `Quick test_retained_delivery_rechecks_host_authority
        ; test_case "host refusal prevents a new admission and dispatch" `Quick test_authority_refusal_does_not_start_a_request
        ; test_case "an unowned request ends as not_allowed" `Quick test_an_unowned_request_ends_as_not_allowed
        ; test_case "an unowned retained answer is refused and kept" `Quick test_an_unowned_retained_answer_is_refused_and_kept
        ; test_case "execution authority does not gate retained local delivery" `Quick test_execution_guard_is_not_retained_delivery_authority
        ; test_case "worker wire cannot select admission policy" `Quick test_worker_cannot_select_admission_policy ] )
    ; ( "deploy preflight"
      , [ test_case "a refused record is deleted with its link and observations" `Quick
            test_preflight_deletes_a_refused_record_with_its_link_and_observations
        ; test_case "the proof link is read with its record" `Quick
            test_preflight_reads_the_proof_link_with_its_record
        ; test_case "a misfiled record is refused alone" `Quick test_preflight_refuses_a_misfiled_record_alone
        ; test_case "a link no record names is refused" `Quick test_preflight_refuses_a_link_no_record_names
        ; test_case "a link written after the listing is not refused" `Quick
            test_preflight_names_a_link_written_after_the_listing
        ; test_case "a slot observation the sweep cannot read is refused" `Quick
            test_preflight_refuses_a_slot_observation_the_sweep_cannot_read
        ; test_case "another store root stops the check" `Quick test_preflight_stops_on_another_store_root
        ; test_case "a link written between the reads is bound to the second read" `Quick
            test_preflight_binds_a_link_written_between_its_reads ] ) ]
