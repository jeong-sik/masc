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
  ; contributions = [ Types.Observe ]; image = "unused"; command = [ "unused" ]
  ; directory = "/nonexistent"; skills_directory = None; action_tool = None; runtime = Types.Docker
  ; state_storage = Types.Ephemeral; tool_invocation = Types.Direct; exported_tools = []; outputs = []
  ; refresh_policy = Types.Every_hint; model_access = Types.Model_disabled
  ; exact_outputs = [ { Types.name = "author"; schema } ]
  ; binding_schema = None; presentation = Masc.Lane_addon_presentation.empty
  ; resources = { cpus = 0.5; memory_bytes = 134217728L; pids = Some 16; max_reply_bytes = 65536 } }

let declaration_id = "quiz"

let request ?(output = "author") ?(message = "Write one question.") id =
  require
    (Exact.request_of_json
       (`Assoc
          [ "kind", `String "exact_output"; "request_id", `String id; "output", `String output
          ; "messages", `List [ `String message ] ]))

let answered = Exact.Final (Exact.Answered { output = `Assoc [ "question", `String "Q?" ]; slot = "s"; usage = None })

(* A runner that counts its calls and, on each call, reads what the host has
   retained so far for that request. *)
let counting_runner store answers =
  let calls = ref 0 and seen = ref [] in
  let runner ~lane_key ~schema:_ (request : Exact.request) =
    incr calls;
    seen := (lane_key, Store.load_exact_request store ~declaration_id ~request_id:request.request_id) :: !seen;
    match !answers with
    | answer :: rest -> answers := rest; answer
    | [] -> fail "the runner was asked more often than the test expected"
  in
  runner, calls, seen

let run store runner request = require (Exact.run ~store ~declaration_id ~package ~runner request)

let attempts store id =
  match require (Store.load_exact_request store ~declaration_id ~request_id:id) with
  | Some json -> Yojson.Safe.Util.(json |> member "attempts" |> to_list)
  | None -> []

let test_retained_before_the_call_and_replayed () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner, calls, seen = counting_runner store (ref [ answered ]) in
    check bool "first run answers" true (run store runner (request "r1") = answered);
    (match !seen with
     | [ (lane_key, Ok (Some json)) ] ->
       check string "the call runs on the installation's add-on lane" "quiz/author" lane_key;
       check bool "the request was retained with a started attempt before the call" true
         (Yojson.Safe.Util.(json |> member "attempts" |> to_list) = [ `Null ])
     | _ -> fail "the runner saw no retained request");
    let restarted = Store.create ~root in
    check bool "after a restart the retained result is delivered" true (run restarted runner (request "r1") = answered);
    check int "and the runner is not asked again" 1 !calls)

let test_a_not_final_attempt_is_tried_again () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner, calls, _ = counting_runner store (ref [ Exact.Not_final Exact.Lane_off; answered ]) in
    check bool "an off lane does not end the request" true
      (run store runner (request "r2") = Exact.Not_final Exact.Lane_off);
    check int "its attempt is retained" 1 (List.length (attempts store "r2"));
    check bool "the next run asks again and ends it" true (run store runner (request "r2") = answered);
    check int "two attempts, two calls" 2 !calls;
    check int "both attempts are retained" 2 (List.length (attempts store "r2")))

let test_a_reused_request_id_is_refused () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner, calls, _ = counting_runner store (ref [ answered ]) in
    ignore (run store runner (request "r3"));
    check bool "the same id with another body is refused" true
      (run store runner (request ~message:"Something else." "r3") = Exact.Final Exact.Request_id_reused);
    check int "without a call" 1 !calls;
    check bool "and the original result stands" true (run store runner (request "r3") = answered))

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
    let runner, calls, _ = counting_runner store (ref []) in
    check bool "the host cannot tell whether the provider got it" true
      (run store runner pending = Exact.Final Exact.Outcome_unknown);
    check int "so it does not call again" 0 !calls;
    check bool "and the verdict is retained" true (run store runner pending = Exact.Final Exact.Outcome_unknown))

let test_an_exception_ends_the_request_as_unknown () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner ~lane_key:_ ~schema:_ _ = failwith "connection reset after send" in
    check bool "an exception is Outcome_unknown" true (run store runner (request "r5") = Exact.Final Exact.Outcome_unknown);
    match attempts store "r5" with
    | [ attempt ] ->
      check bool "its text stays in the attempt" true
        (Yojson.Safe.Util.(attempt |> member "exception") <> `Null)
    | _ -> fail "one attempt expected")

let test_an_undeclared_output_is_not_allowed () =
  with_root (fun root ->
    let store = Store.create ~root in
    let runner, calls, _ = counting_runner store (ref []) in
    (match run store runner (request ~output:"grade" "r6") with
     | Exact.Final (Exact.Not_allowed _) -> ()
     | _ -> fail "an output the manifest does not declare must be not_allowed");
    check int "without a call" 0 !calls)

let test_a_request_in_flight_is_not_run_twice () =
  with_root (fun root ->
    let store = Store.create ~root in
    let nested = ref None in
    let rec runner ~lane_key:_ ~schema:_ req =
      nested := Some (Exact.run ~store ~declaration_id ~package ~runner req);
      answered
    in
    check bool "the outer run answers" true (run store runner (request "r7") = answered);
    check bool "a second run of the same request meanwhile waits" true
      (!nested = Some (Ok (Exact.Not_final Exact.Attempt_in_progress))))

let test_request_decoding_is_strict () =
  List.iter (fun (label, json) ->
      check bool label true (Result.is_error (Exact.request_of_json json)))
    [ "another kind", `Assoc [ "kind", `String "ask"; "request_id", `String "a"; "output", `String "author"; "messages", `List [ `String "m" ] ]
    ; "no message", `Assoc [ "kind", `String "exact_output"; "request_id", `String "a"; "output", `String "author"; "messages", `List [] ]
    ; "a blank id", `Assoc [ "kind", `String "exact_output"; "request_id", `String " "; "output", `String "author"; "messages", `List [ `String "m" ] ]
    ; "an unknown key", `Assoc [ "kind", `String "exact_output"; "request_id", `String "a"; "output", `String "author"; "messages", `List [ `String "m" ]; "images", `List [] ] ]

let () =
  run "lane add-on exact requests"
    [ ( "retention"
      , [ test_case "retained before the call and replayed after a restart" `Quick test_retained_before_the_call_and_replayed
        ; test_case "a not-final attempt is tried again" `Quick test_a_not_final_attempt_is_tried_again
        ; test_case "a reused request id is refused" `Quick test_a_reused_request_id_is_refused
        ; test_case "a started attempt without outcome is unknown" `Quick test_a_started_attempt_without_outcome_is_unknown
        ; test_case "an exception ends the request as unknown" `Quick test_an_exception_ends_the_request_as_unknown
        ; test_case "an undeclared output is not allowed" `Quick test_an_undeclared_output_is_not_allowed
        ; test_case "a request in flight is not run twice" `Quick test_a_request_in_flight_is_not_run_twice
        ; test_case "request decoding is strict" `Quick test_request_decoding_is_strict ] ) ]
