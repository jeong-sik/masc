open Alcotest

module Operation = Keeper_chat_operation

let value = function Ok value -> value | Error detail -> fail detail
let operation_id = Operation.Operation_id.of_string "public-error-incident" |> value
let sentinel = "orchid river seventy nine"
let target = "/private/example/.masc/keepers/alpha/chat-operations.sqlite3"
let diagnostic = "provider failed: " ^ sentinel ^ "; storage target=" ^ target

let operation state : Operation.t =
  { operation_id; batch_membership = None
  ; admission_digest = "admission"; execution_digest = "execution"
  ; sequence = 7L; source = `Assoc ["kind", `String "human"]
  ; input = None; state; created_at = 100. }
;;

let member name = Yojson.Safe.Util.member name

let test_failed_operation_public_boundary () =
  List.iter (fun kind ->
    let original = operation (Operation.Failed
      { completed_at = 101.
      ; failure = { kind; detail = diagnostic; outcome_ref = Some target } }) in
    let public = Operation.to_public_json original in
    check string "closed typed failure code" (Operation.failure_kind_to_string kind)
      Yojson.Safe.Util.(public |> member "failure_kind" |> to_string);
    check string "fixed public message" (Operation.public_failure_message kind)
      Yojson.Safe.Util.(public |> member "failure_detail" |> to_string);
    check string "actual operation joins operator diagnostics" "public-error-incident"
      Yojson.Safe.Util.(public |> member "incident_id" |> to_string);
    check bool "diagnostic reference is not public error content" true
      (member "outcome_ref" public = `Null);
    let text = Yojson.Safe.to_string public in
    let contains needle =
      let n = String.length needle in
      let rec loop i = i+n <= String.length text &&
        (String.sub text i n = needle || loop (i+1)) in loop 0 in
    check bool "non-prefix exact secret absent" false (contains sentinel);
    check bool "BasePath and storage target absent" false (contains target);
    let internal = Operation.to_json original in
    check string "operator facts retain the exact diagnostic" diagnostic
      Yojson.Safe.Util.(internal |> member "failure_detail" |> to_string);
    check string "operator facts retain the exact reference" target
      Yojson.Safe.Util.(internal |> member "outcome_ref" |> to_string))
    Operation.all_failure_kinds
;;

let test_nonfailure_operation_projection_is_unchanged () =
  List.iter (fun state ->
    let original = operation state in
    check bool "nonfailure state keeps the canonical facts" true
      (Operation.to_public_json original = Operation.to_json original))
    [ Operation.Queued; Running {started_at = 100.5}
    ; Succeeded {completed_at = 101.;outcome_ref = "trace-1"}
    ; Cancelled {completed_at = 101.} ]
;;

let submitted_prompt = "cobalt harbor eighty one"

(* The submitting Keeper reads an operation back by its id. The projection may
   only drop facts; every field it reports is the operation's own fact, and the
   identity, state and terminal facts survive for every state. *)
let test_status_projection_keeps_state_and_drops_the_request () =
  let failed =
    List.map (fun kind ->
      Operation.Failed
        { completed_at = 101.
        ; failure = { kind; detail = diagnostic; outcome_ref = Some target } })
      Operation.all_failure_kinds
  in
  let states =
    [ Operation.Queued; Running { started_at = 100.5 }
    ; Succeeded { completed_at = 101.; outcome_ref = "trace-1" }
    ; Cancelled { completed_at = 101. } ]
    @ failed
  in
  let batch =
    ({ execution_id = operation_id; input_digest = "batch-input-digest" }
     : Operation.batch_membership)
  in
  let carried_fact_names =
    [ "operation_id"; "created_at"; "state"; "started_at"; "completed_at"
    ; "outcome_ref"; "failure_kind"; "failure_detail"; "batch_execution_id" ]
  in
  List.iter (fun batch_membership ->
    List.iter (fun state ->
      let original =
        { (operation state) with
          input = Some (`Assoc [ "message", `String submitted_prompt ])
        ; batch_membership }
      in
      let full = Yojson.Safe.Util.to_assoc (Operation.to_json original) in
      let status = Yojson.Safe.Util.to_assoc (Operation.to_status_json original) in
      List.iter (fun (name, value) ->
        check bool (name ^ " is the operation's own fact") true
          (List.assoc_opt name full = Some value))
        status;
      List.iter (fun name ->
        check bool (name ^ " is kept when the operation has it") (List.mem_assoc name full)
          (List.mem_assoc name status))
        carried_fact_names;
      List.iter (fun name ->
        check bool (name ^ " is not repeated to the submitter") false
          (List.mem_assoc name status))
        [ "schema"; "sequence"; "admission_digest"; "execution_digest"; "source"
        ; "input"; "batch_input_digest" ];
      check bool "the submitted prompt is not repeated" false
        (let text = Yojson.Safe.to_string (Operation.to_status_json original) in
         let n = String.length submitted_prompt in
         let rec loop i = i + n <= String.length text
           && (String.sub text i n = submitted_prompt || loop (i + 1)) in
         loop 0))
      states)
    [ None; Some batch ]
;;

let () =
  run "Keeper public operation failures"
    [ "public boundary",
      [ test_case "secret and path stay internal; incident survives" `Quick
          test_failed_operation_public_boundary
      ; test_case "nonfailure state is unchanged" `Quick
          test_nonfailure_operation_projection_is_unchanged ]
    ; "status projection",
      [ test_case "state survives and the request is not repeated" `Quick
          test_status_projection_keeps_state_and_drops_the_request ] ]
