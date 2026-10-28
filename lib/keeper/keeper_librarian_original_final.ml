module Owner = Lane_addon_tool_request_owner
module Exact = Lane_addon_exact
let ( let* ) = Result.bind
let ( let+ ) result f = Result.map f result
let require condition detail = if condition then Ok () else Error detail
let equal left right detail =
  let* left=Lane_addon_action.canonical left in
  let* right=Lane_addon_action.canonical right in
  require (Yojson.Safe.equal left right) detail

type target = {exact:Exact.request;schema:Yojson.Safe.t;declaration_id:string}
let target ~installation_id exact =
  let* schema=Option.to_result ~none:"Original history request lacks its schema" exact.Exact.schema in
  let* installation=Owner.installation_of_id installation_id in
  let+ declaration_id=match installation with Owner.Configuration id -> Ok id
    | Manual _ -> Error "Original history requires a configured host installation" in
  {exact;schema;declaration_id}
let refusal_evidence ~store ~target final =
  match final with
  | Exact.Call_final (Exact.Input_refused (Input_capacity | Context_overflow | Request_body_refused)) ->
    let* {exact;schema;declaration_id}=target () in
    let* observed=Exact.observe_retained ~store ~declaration_id ~schema exact in
    (match observed with
     | Exact.Retained_absent ->
       (* The worker's frame refusal: no provider or slot ran, so the final
          alone is the whole evidence. *)
       Ok (if Exact.refused_before_host final
           then Keeper_exact_walk_failure.of_input_refusal Keeper_librarian_input_refusal.Request_body_refused
           else Keeper_exact_walk_failure.empty)
     | Retained_open -> Ok Keeper_exact_walk_failure.empty
     | Retained_terminal _ ->
       let* latest=Exact.read_latest_original_execution ~store ~declaration_id ~schema exact in
       (match latest with
        | Exact.Completed_latest {execution={outcome=Exact.Call_ended actual;receipt;_};_}
          when Yojson.Safe.equal (Exact.final_to_json (Exact.Call_final actual)) (Exact.final_to_json final) ->
          (* The same bar admission's size check sets: a named input refusal
             from every visit, with no independent failure mixed in. A
             timeout or a bad request is not evidence about reading less. *)
          let evidence=Keeper_exact_walk_receipt.failure_evidence receipt in
          Ok (if Keeper_exact_walk_failure.refuses_input_capacity evidence
                 && not evidence.size_independent_execution_failure
              then evidence else Keeper_exact_walk_failure.empty)
        | Completed_latest {execution={outcome=Exact.Call_ended _ | Call_refused _;_};_}
        | No_completed_latest -> Ok Keeper_exact_walk_failure.empty))
  | Exact.Call_final (Answered _ | Invalid_output _ | Output_limit_reached _ | Input_refused Invalid_request)
  | Outcome_unknown | Not_allowed _ | Request_id_reused -> Ok Keeper_exact_walk_failure.empty
let confirm_final ~store {exact;schema;declaration_id} final =
  let* observed=Exact.observe_retained ~store ~declaration_id ~schema exact in
  match observed with
  | Exact.Retained_absent ->
    (* addons/exact_worker.py [submit] writes the refusal before the
       [store.write accepted] line, so the host never retains this request.
       The worker's deployed behavior is what makes this final the only one
       taken without a host terminal. *)
    if Exact.refused_before_host final then Ok ()
    else Error "Original history host terminal is absent"
  | Retained_open -> Error "Original history host terminal is unresolved"
  | Retained_terminal actual ->
  let* ()=equal (Exact.final_to_json (Exact.delivered actual)) (Exact.final_to_json final)
    "Original history final differs from the actual host terminal" in
  match final with
  | Exact.Call_final expected ->
    let* latest=Exact.read_latest_original_execution ~store ~declaration_id ~schema exact in
    (match latest with
     | Exact.No_completed_latest -> Error "Original history latest host execution proof is incomplete"
     | Completed_latest {attempt_ordinal;execution={outcome=Exact.Call_ended actual;_}} ->
       let* ()=require (attempt_ordinal>0) "Original history host attempt ordinal is invalid" in
       equal (Exact.final_to_json (Exact.Call_final expected)) (Exact.final_to_json (Exact.Call_final actual))
         "Original history final differs from its latest completed host execution"
     | Completed_latest {execution={outcome=Exact.Call_refused _;_};_} ->
       Error "Original history refused host execution cannot confirm a call result")
  | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused -> Ok ()
