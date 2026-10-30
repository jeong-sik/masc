module Input = Agent_input_request
open Alcotest

let request : Input.t =
  {request_id="request";participant_name=Some "same-agent";question="Which environment?";
   schema=Some (`Assoc ["type",`String "object"]);timeout_s=Some 20.;created_at=42.}
let pending run_id : Input.pending = {run_id;request}

let exact_ownership () =
  let original = pending "run-a" in
  let forged = {original with request={request with question="untrusted question"}} in
  check bool "return canonical owned question" true
    (Input.settle ~current:(Some original) forged = Ok original);
  check bool "same request ID from another run is refused" true
    (Input.settle ~current:(Some original) (pending "run-b") = Error Input.Request_not_current)

let stale_and_duplicate () =
  let a = pending "run" in
  let b = {a with request={request with request_id="next-request"}} in
  check bool "stale response cannot consume replacement" true
    (Input.settle ~current:(Some b) a = Error Input.Request_not_current);
  check bool "missing current request is not accepted" true
    (Input.settle ~current:None a = Error Input.No_pending_request)

let round_trip () =
  List.iter (fun original ->
    check bool "preserve full originating request" true
      (Input.pending_of_json (Input.pending_to_json original) = Ok original))
    [pending "run";{run_id="other";request={request with participant_name=None;schema=None;timeout_s=None}}]

let damaged_ownership () =
  let json = Input.pending_to_json (pending "run") in
  let fields = match json with `Assoc x -> x | _ -> fail "object" in
  List.iter (fun malformed ->
    check bool "refuse damaged ownership without guessing" true
      (Result.is_error (Input.pending_of_json malformed)))
    [`Null; `Assoc []; `Assoc (List.remove_assoc "run_id" fields);
     `Assoc (("run_id",`String "duplicate")::fields);
     `Assoc (("extra",`Null)::fields);
     `Assoc (("run_id",`String "")::List.remove_assoc "run_id" fields);
     `Assoc ["run_id",`String "run";"request",`Assoc ["request_id",`String "request"]]]

let () = run "Owned input requests"
  ["continuation ownership",
   [test_case "canonical request and concurrent same-name runs" `Quick exact_ownership;
    test_case "replacement and duplicate settlement" `Quick stale_and_duplicate;
    test_case "durable originating request round trip" `Quick round_trip;
    test_case "malformed ownership cannot become current" `Quick damaged_ownership]]
