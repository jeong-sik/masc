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
   host has retained so far for that request. *)
let counting_runner store steps =
  let sends = ref 0 and seen = ref [] in
  let runner ~before_dispatch:_ ~admission_class:_ ~lane_key ~schema:_ (request : Exact.request) =
    match !steps with
    | [] -> fail "the runner was asked more often than the test expected"
    | step :: rest ->
      steps := rest;
      let sent () =
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
    let runner ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ _ = Ok (fun ~validate:_ -> failwith "connection reset after send") in
    check bool "an exception is Outcome_unknown" true (run_request store runner (request "r5") = Exact.Final Exact.Outcome_unknown);
    check bool "the host preserves the raised cause" true
      (require (observe store (request "r5"))=Exact.Retained_terminal (Exact.Retained_unknown Exact.Raised));
    match attempts store "r5" with
    | [ attempt ] ->
      check bool "its text stays in the attempt" true
        (Yojson.Safe.Util.(attempt |> member "exception") <> `Null)
    | _ -> fail "one attempt expected")

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
    let blocking ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ _ =
      Ok
        (fun ~validate ->
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
    let cancelled ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ _ = Ok (fun ~validate:_ -> raise (Eio.Cancel.Cancelled Exit)) in
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
    let locking ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ _ =
      Ok
        (fun ~validate ->
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
    let runner, sends, _ = counting_runner store (ref []) in
    check bool "the original answer is published without another send" true (answered_with question (run_request store runner (request "r12")));
    check bool "completed proof wins over another process's marker" true
      (match require (observe store (request "r12")) with
       | Exact.Retained_terminal (Exact.Retained_call (Exact.Answered _)) -> true
       | _ -> false);
    check int "without a send" 0 !sends)

let original_execution store ?(attempt_ordinal=1) original =
  Exact.read_original_execution ~store ~declaration_id ~schema ~attempt_ordinal original

let proof_address original =
  let tuple values=Yojson.Safe.to_string (`List values) in
  tuple [`String "exact-original-execution";`String declaration_id],
  tuple [`String "original-request";`String original.Exact.request_id;`String (Exact.digest original)]

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
    check int "proof reads never dispatch" 2 !sends)

let test_proof_publication_failure_never_exposes_an_answer () =
  with_root (fun root ->
    let store=Store.create ~root in
    let original=request "blocked-proof" in
    let sends=ref 0 in
    let obstruction=Filename.concat root "host-results" in
    let runner ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ _ = Ok (fun ~validate ->
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
    let runner ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ _ = Ok (fun ~validate ->
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
    let second ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ _ = Ok (fun ~validate ->
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
    let first ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ _ = Ok (fun ~validate:_ ->
      incr sends;
      Unix.chmod directory 0o500;
      executed (Exact.Call_refused busy)) in
    let result=Exact.run ~authorize_request ~store ~declaration_id ~package ~runner:first original in
    Unix.chmod directory 0o700;
    check bool "original not-final outcome publication failed" true (Result.is_error result);
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
    let runner ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema _request =
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
  let runner ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ _=Ok (fun ~validate ->
    let before=require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id) in
    check bool "actual provider's started record remains open" true
      (require (observe (Store.create ~root) original)=Exact.Retained_open);
    check bool "read cannot infer terminal uncertainty or rewrite started history" true
      (before=require (Store.load_exact_request store ~declaration_id ~request_id:original.request_id));
    let output=require (validate question) in executed (Exact.Call_ended (Exact.Answered {output;slot="original";usage=None}))) in
  check bool "the actual in-flight call can still answer" true (answered_with question (run_request store runner original)))
let test_observe_exception_and_later_denial_preserves_original ()=with_root (fun root ->
  let store=Store.create ~root in
  let original=request "readonly-exception" in
  let runner ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ _=Ok (fun ~validate:_ -> raise Exit) in
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
    let runner ~before_dispatch:_ ~admission_class ~lane_key:_ ~schema:_ _ =
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
    let runner ~before_dispatch:_ ~admission_class:_ ~lane_key:_ ~schema:_ _ = fail "refused original reached the runner" in
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
    (Result.is_ok (Exact.check_retained_record wire)))
    [record [other_process_marker] `Null;record [interrupted] unknown;record [cut] unknown;record [raised] unknown];
  let answered=Yojson.Safe.Util.member "final" base in
  List.iter (fun wire ->
    check bool "preflight decoder rejects old or inconsistent attempt evidence" true
      (Result.is_error (Exact.check_retained_record wire));
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
        ; test_case "an undeclared output is not allowed" `Quick test_an_undeclared_output_is_not_allowed
        ; test_case "selection hides but preserves a retained answer" `Quick test_selection_hides_but_preserves_a_retained_answer
        ; test_case "a request in flight is not run twice" `Quick test_a_request_in_flight_is_not_run_twice
        ; test_case "a cancelled call leaves its attempt started" `Quick test_a_cancelled_call_leaves_its_attempt_started
        ; test_case "a retained answer is checked against the schema declared now" `Quick
            test_a_retained_answer_is_checked_against_the_schema_declared_now
        ; test_case "confirmed proof recovers lost outcome publication" `Quick
            test_confirmed_proof_recovers_lost_outcome_publication
        ; test_case "original execution binds request schema and actual attempt" `Quick test_original_execution_is_bound_to_one_attempt
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
        ; test_case "worker wire cannot select admission policy" `Quick test_worker_cannot_select_admission_policy ] ) ]
