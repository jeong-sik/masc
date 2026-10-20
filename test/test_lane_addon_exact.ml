(** A package's exact-output request is retained before the runner is asked,
    and replayed instead of asked again (RFC operator-quiz §4.3, K1). *)
open Alcotest
module Exact = Masc.Lane_addon_exact
module Store = Masc.Lane_addon_store
module Types = Masc.Lane_addon_types

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
  ; contributions = [ Types.Observe ]; command = [ "unused" ]
  ; directory = "/nonexistent"; skills_directory = None; action_tool = None
  ; state_storage = Types.Ephemeral; tool_invocation = Types.Direct; tool_hooks = []; worker_service = Types.Mcp_tools; exported_tools = []; outputs = []
  ; refresh_policy = Types.Every_hint; model_access = Types.Model_disabled
  ; exact_outputs = [ { Types.name = "author"; schema } ]; operator_asks = false
  ; binding_schema = None; presentation = Masc.Lane_addon_presentation.empty
  ; execution = Types.Container { runtime = Types.Docker; image = "unused"
      ; resources = { cpus = 0.5; memory_bytes = 134217728L; pids = Some 16; max_reply_bytes = 65536 } } }

let declaration_id = "quiz"

let request ?(output = "author") ?(message = "Write one question.") id =
  require
    (Exact.request_of_json
       (`Assoc
          [ "kind", `String "exact_output"; "request_id", `String id; "output", `String output
          ; "messages", `List [ `Assoc [ "role", `String "user"; "text", `String message ] ] ]))

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
  let runner ~lane_key ~schema:_ (request : Exact.request) =
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
       | Refused reason -> Ok (fun ~validate:_ -> sent (); Exact.Call_refused reason)
       | Answer json ->
         Ok
           (fun ~validate ->
              sent ();
              match validate json with
              | Ok output -> Exact.Call_ended (Exact.Answered { output; slot = "s"; usage = None })
              | Error detail -> Exact.Call_ended (Exact.Invalid_output { detail })))
  in
  runner, sends, seen

let run_request store runner request = require (Exact.run ~store ~declaration_id ~package ~runner request)

let attempts store id =
  match require (Store.load_exact_request store ~declaration_id ~request_id:id) with
  | Some json -> Yojson.Safe.Util.(json |> member "attempts" |> to_list)
  | None -> []

let test_retained_before_the_call_and_replayed () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner, sends, seen = counting_runner store (ref [ Answer question ]) in
    check bool "first run answers" true (answered_with question (run_request store runner (request "r1")));
    (match !seen with
     | [ (lane_key, Ok (Some json)) ] ->
       check string "the call runs on the installation's add-on lane" "quiz/author" lane_key;
       check bool "the request was retained with a started attempt before the call" true
         (Yojson.Safe.Util.(json |> member "attempts" |> to_list) = [ `Null ])
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
            ; "attempts", `List [ `Null ]; "final", `Null ]));
    let runner, sends, _ = counting_runner store (ref []) in
    check bool "the host cannot tell whether the provider got it" true
      (run_request store runner pending = Exact.Final Exact.Outcome_unknown);
    check int "so it does not send again" 0 !sends;
    check bool "and the verdict is retained" true (run_request store runner pending = Exact.Final Exact.Outcome_unknown))

let test_an_exception_ends_the_request_as_unknown () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner ~lane_key:_ ~schema:_ _ = Ok (fun ~validate:_ -> failwith "connection reset after send") in
    check bool "an exception is Outcome_unknown" true (run_request store runner (request "r5") = Exact.Final Exact.Outcome_unknown);
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
    let allowed = {package with exact_outputs = [{Types.name="grade";schema}]} in
    check bool "the same denied request retains its final after permission changes" true
      (match require (Exact.run ~store:restarted ~declaration_id ~package:allowed ~runner (request ~output:"grade" "r6")) with
       | Exact.Final (Exact.Not_allowed _) -> true | _ -> false);
    check int "without a send" 0 !sends)

let test_selection_hides_but_preserves_a_retained_answer () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner, sends, _ = counting_runner store (ref [Answer question]) in
    ignore (run_request store runner (request "selected"));
    let off request = require (Exact.run ~store ~declaration_id ~package:{package with exact_outputs=[]} ~runner request) in
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
    let blocking ~lane_key:_ ~schema:_ _ =
      Ok
        (fun ~validate ->
           Eio.Promise.resolve enter ();
           Eio.Promise.await released;
           match validate question with
           | Ok output -> Exact.Call_ended (Exact.Answered { output; slot = "s"; usage = None })
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
    check bool "and leaves the started attempt alone" true (!during = [ `Null ]);
    check bool "the first run answers" true (Option.fold ~none:false ~some:(answered_with question) !first);
    check bool "the same ids under another root run" true (Option.fold ~none:false ~some:(answered_with question) !other_root))

let test_a_cancelled_call_leaves_its_attempt_started () =
  with_root (fun root ->
    let store = Store.create ~root in
    let cancelled ~lane_key:_ ~schema:_ _ = Ok (fun ~validate:_ -> raise (Eio.Cancel.Cancelled Exit)) in
    (match Exact.run ~store ~declaration_id ~package ~runner:cancelled (request "r10") with
     | _ -> fail "a cancellation must reach the caller"
     | exception Eio.Cancel.Cancelled _ -> ());
    check bool "the started attempt stays" true (attempts store "r10" = [ `Null ]);
    let runner, sends, _ = counting_runner store (ref []) in
    check bool "disabled output refuses delivery of an unresolved attempt" true
      (match require (Exact.run ~store ~declaration_id ~package:{package with exact_outputs=[]} ~runner (request "r10")) with
       | Exact.Final (Exact.Not_allowed _) -> true | _ -> false);
    check bool "the next run reads it as unknown, so the claim was released" true
      (run_request store runner (request "r10") = Exact.Final Exact.Outcome_unknown);
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
            ; schema =
                `Assoc
                  [ "type", `String "object"
                  ; "properties", `Assoc [ "question", `Assoc [ "type", `String "integer" ] ]
                  ; "additionalProperties", `Bool false ] } ] }
    in
    (match require (Exact.run ~store ~declaration_id ~package:changed ~runner (request "r11")) with
     | Exact.Final (Exact.Call_final (Exact.Invalid_output _)) -> ()
     | _ -> fail "an answer retained under the old schema must not be delivered as answered");
    check int "and the provider is not called again" 1 !sends;
    check bool "the record keeps the answer as it came" true (answered_with question (run_request store runner (request "r11"))))

let test_an_outcome_that_cannot_be_written_stays_unknown () =
  with_root (fun root ->
    let store = Store.create ~root in
    let directory = Filename.concat (Filename.concat root "exact-requests") (Store.digest declaration_id) in
    let locking ~lane_key:_ ~schema:_ _ =
      Ok
        (fun ~validate ->
           Unix.chmod directory 0o500;
           match validate question with
           | Ok output -> Exact.Call_ended (Exact.Answered { output; slot = "s"; usage = None })
           | Error detail -> fail detail)
    in
    let result = Exact.run ~store ~declaration_id ~package ~runner:locking (request "r12") in
    Unix.chmod directory 0o700;
    check bool "the run reports the failed write" true (Result.is_error result);
    let runner, sends, _ = counting_runner store (ref []) in
    check bool "the sent call is not repeated" true (run_request store runner (request "r12") = Exact.Final Exact.Outcome_unknown);
    check int "without a send" 0 !sends)

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

let () =
  run "lane add-on exact requests"
    [ ( "retention"
      , [ test_case "retained before the call and replayed after a restart" `Quick test_retained_before_the_call_and_replayed
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
        ; test_case "an outcome that cannot be written stays unknown" `Quick
            test_an_outcome_that_cannot_be_written_stays_unknown
        ; test_case "request decoding is strict" `Quick test_request_decoding_is_strict
        ; test_case "conversation retention binds speaker roles" `Quick test_conversation_is_retained_with_role_identity
        ; test_case "conversation wire refuses ambiguous roles" `Quick test_conversation_rejects_ambiguous_or_unsupported_wire ] ) ]
