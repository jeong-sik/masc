let ( let* ) = Result.bind

type role = User | Assistant
type message = { role : role; text : string }

type request =
  { request_id : string
  ; output : string
  ; system : string option
  ; messages : message list
  ; schema : Yojson.Safe.t option
  }

let request_keys = [ "kind"; "request_id"; "output"; "system"; "messages"; "schema" ]

let message_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = [ "role"; "text" ] ->
    let* role = match List.assoc "role" fields with
      | `String "user" -> Ok User
      | `String "assistant" -> Ok Assistant
      | _ -> Error "message role must be user or assistant"
    in
    (match List.assoc "text" fields with
     | `String text -> Ok { role; text }
     | _ -> Error "message text must be a string")
  | _ -> Error "a message must be exactly {role, text}"

let message_to_json message =
  `Assoc [ "role", `String (match message.role with User -> "user" | Assistant -> "assistant")
         ; "text", `String message.text ]

let request_of_json = function
  | `Assoc fields ->
    let text key =
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | Some _ | None -> Error (key ^ " requires a non-blank string")
    in
    let* () =
      let keys = List.map fst fields in
      if List.length keys = List.length (List.sort_uniq String.compare keys) then Ok ()
      else Error "an exact_output request has duplicate keys"
    in
    let* () =
      match List.find_opt (fun (key, _) -> not (List.mem key request_keys)) fields with
      | Some (key, _) -> Error ("an exact_output request has no key " ^ key)
      | None -> Ok ()
    in
    let* () =
      match List.assoc_opt "kind" fields with
      | Some (`String "exact_output") -> Ok ()
      | Some _ | None -> Error "kind must be exact_output"
    in
    let* request_id = text "request_id" in
    let* output = text "output" in
    let* system =
      match List.assoc_opt "system" fields with
      | None | Some `Null -> Ok None
      | Some (`String value) -> Ok (Some value)
      | Some _ -> Error "system must be a string"
    in
    let* messages =
      match List.assoc_opt "messages" fields with
      | Some (`List (_ :: _ as values)) ->
        List.fold_right
          (fun value acc ->
             let* acc = acc in
             let* message = message_of_json value in
             Ok (message :: acc))
          values (Ok [])
      | Some _ | None -> Error "messages requires at least one conversation message"
    in
    let* schema = match List.assoc_opt "schema" fields with
      | None -> Ok None
      | Some (`Assoc _ as schema) -> Lane_addon_action.canonical schema |> Result.map Option.some
      | Some _ -> Error "request schema must be a JSON object" in
    Ok { request_id; output; system; messages; schema }
  | _ -> Error "an exact_output request must be an object"

let request_to_json request =
  `Assoc
    ([ "kind", `String "exact_output"
     ; "request_id", `String request.request_id
     ; "output", `String request.output
     ]
     @ (match request.system with None -> [] | Some system -> [ "system", `String system ])
     @ [ "messages", `List (List.map message_to_json request.messages) ]
     @ (match request.schema with None -> [] | Some schema -> ["schema",schema]))

let digest request = Lane_addon_store.digest (Yojson.Safe.to_string (request_to_json request))

(* Baseline validation constructs one. [run] and the worker receipt path
   additionally check the original request's partial shape before delivery. *)
type checked = Yojson.Safe.t

let checked_json checked = checked

let schema_for_request ~(output:Lane_addon_types.exact_output) request =
  if output.name <> request.output then Error "exact output name does not match the request"
  else match request.schema,output.request_schema with
    | None,(Package_schema_only|Consumer_request_schema) -> Ok output.schema
    | Some _,Package_schema_only -> Error "the package output does not permit a consumer request schema"
    | Some schema,Consumer_request_schema -> Ok schema

let validate_answer ~output request answer =
  let* _ = schema_for_request ~output request in
  let* answer = Lane_addon_action.validate_input ~schema:output.Lane_addon_types.schema ~name:request.output answer in
  match request.schema with
  | None -> Ok answer
  | Some schema ->
      match Lane_addon_exact_shape.issue ~at:"$" schema answer with
      | None -> Ok answer
      | Some issue -> Error (Lane_addon_exact_shape.to_string issue)

type input_refusal =
  | Input_capacity
  | Context_overflow
  | Invalid_request
  | Request_body_refused

type usage = { input_tokens : int; output_tokens : int }

type call_final =
  | Answered of { output : checked; slot : string; usage : usage option }
  | Invalid_output of { detail : string }
  | Input_refused of input_refusal
  | Output_limit_reached of { detail : string }

type final =
  | Call_final of call_final
  | Outcome_unknown
  | Not_allowed of { reason : string }
  | Request_id_reused

type lane_unavailable =
  | Lane_unconfigured
  | Lane_off
  | No_admitted_slots
  | Lane_registry_unavailable of { detail : string }

type provider_refusal =
  | Provider_unavailable of { detail : string }
  | Provider_auth_refused of { detail : string }
  | Provider_configuration_refused of { detail : string }

type not_final =
  | Lane_unavailable of lane_unavailable
  | Provider_refused of provider_refusal
  | Attempt_in_progress

type attempt =
  | Final of final
  | Not_final of not_final

let input_refusal_to_string = function
  | Input_capacity -> "input_capacity"
  | Context_overflow -> "context_overflow"
  | Invalid_request -> "invalid_request"
  | Request_body_refused -> "request_body_refused"

let input_refusal_of_string = function
  | "input_capacity" -> Some Input_capacity
  | "context_overflow" -> Some Context_overflow
  | "invalid_request" -> Some Invalid_request
  | "request_body_refused" -> Some Request_body_refused
  | _ -> None

let usage_to_json { input_tokens; output_tokens } =
  `Assoc [ "input_tokens", `Int input_tokens; "output_tokens", `Int output_tokens ]

let final_to_json = function
  | Call_final (Answered { output; slot; usage }) ->
    `Assoc
      ([ "status", `String "answered"; "output", output; "slot", `String slot ]
       @ match usage with None -> [] | Some usage -> [ "usage", usage_to_json usage ])
  | Call_final (Invalid_output { detail }) ->
    `Assoc [ "status", `String "invalid_output"; "detail", `String detail ]
  | Call_final (Input_refused kind) ->
    `Assoc [ "status", `String "input_refused"; "kind", `String (input_refusal_to_string kind) ]
  | Call_final (Output_limit_reached { detail }) ->
    `Assoc [ "status", `String "output_limit_reached"; "detail", `String detail ]
  | Outcome_unknown -> `Assoc [ "status", `String "outcome_unknown" ]
  | Not_allowed { reason } -> `Assoc [ "status", `String "not_allowed"; "reason", `String reason ]
  | Request_id_reused -> `Assoc [ "status", `String "request_id_reused" ]

(* The retained record reads back only what this module wrote; anything else is
   an unreadable record, not a guess. *)
let retained_final_of_json json =
  let field key = match json with `Assoc fields -> List.assoc_opt key fields | _ -> None in
  let text key = match field key with Some (`String value) -> Ok value | _ -> Error ("final " ^ key) in
  let* status = text "status" in
  match status with
  | "answered" ->
    let* slot = text "slot" in
    let* output = Option.to_result ~none:"final output" (field "output") in
    let* usage =
      match field "usage" with
      | None -> Ok None
      | Some (`Assoc [ "input_tokens", `Int input_tokens; "output_tokens", `Int output_tokens ]) ->
        Ok (Some { input_tokens; output_tokens })
      | Some _ -> Error "final usage"
    in
    Ok (Call_final (Answered { output; slot; usage }))
  | "invalid_output" -> let* detail = text "detail" in Ok (Call_final (Invalid_output { detail }))
  | "output_limit_reached" ->
    let* detail = text "detail" in
    if String.trim detail="" then Error "output limit requires non-blank detail"
    else Ok (Call_final (Output_limit_reached { detail }))
  | "input_refused" ->
    let* kind = text "kind" in
    Option.to_result ~none:"final kind" (input_refusal_of_string kind)
    |> Result.map (fun kind -> Call_final (Input_refused kind))
  | "outcome_unknown" -> Ok Outcome_unknown
  | "not_allowed" -> let* reason = text "reason" in Ok (Not_allowed { reason })
  | "request_id_reused" -> Ok Request_id_reused
  | other -> Error ("final status " ^ other)

let final_shape_of_json json =
  let* normalized = Lane_addon_action.canonical json in
  let* final = retained_final_of_json normalized in
  let* encoded = Lane_addon_action.canonical (final_to_json final) in
  let* () = if encoded = normalized then Ok () else Error "invalid or unknown final result fields" in
  Ok final

let final_of_json ~schema json =
  let* final = final_shape_of_json json in
  match final with
  | Call_final (Answered {output;slot;usage}) ->
      let* output = Lane_addon_action.validate_input ~schema ~name:"model result" output in
      Ok (Call_final (Answered {output;slot;usage}))
  | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _) | Outcome_unknown | Not_allowed _ | Request_id_reused -> Ok final

let not_final_to_json = function
  | Lane_unavailable Lane_unconfigured -> `Assoc [ "reason", `String "lane_unconfigured" ]
  | Lane_unavailable Lane_off -> `Assoc [ "reason", `String "lane_off" ]
  | Lane_unavailable No_admitted_slots -> `Assoc [ "reason", `String "no_admitted_slots" ]
  | Lane_unavailable (Lane_registry_unavailable { detail }) ->
    `Assoc [ "reason", `String "lane_registry_unavailable"; "detail", `String detail ]
  | Provider_refused (Provider_unavailable { detail }) ->
    `Assoc [ "reason", `String "provider_unavailable"; "detail", `String detail ]
  | Provider_refused (Provider_auth_refused { detail }) ->
    `Assoc [ "reason", `String "provider_auth_refused"; "detail", `String detail ]
  | Provider_refused (Provider_configuration_refused { detail }) ->
    `Assoc [ "reason", `String "provider_configuration_refused"; "detail", `String detail ]
  | Attempt_in_progress -> `Assoc [ "reason", `String "attempt_in_progress" ]

let not_final_of_json json =
  let fields = match json with `Assoc fields -> fields | _ -> [] in
  let detail () = match List.assoc_opt "detail" fields with
    | Some (`String detail) -> Ok detail
    | Some _ | None -> Error "a not-final reason with a detail needs it as a string" in
  let only keys = List.sort String.compare (List.map fst fields) = List.sort String.compare keys in
  match List.assoc_opt "reason" fields with
  | Some (`String "lane_unconfigured") when only ["reason"] -> Ok (Lane_unavailable Lane_unconfigured)
  | Some (`String "lane_off") when only ["reason"] -> Ok (Lane_unavailable Lane_off)
  | Some (`String "no_admitted_slots") when only ["reason"] -> Ok (Lane_unavailable No_admitted_slots)
  | Some (`String "attempt_in_progress") when only ["reason"] -> Ok Attempt_in_progress
  | Some (`String "lane_registry_unavailable") when only ["reason"; "detail"] ->
    let* detail = detail () in Ok (Lane_unavailable (Lane_registry_unavailable { detail }))
  | Some (`String "provider_unavailable") when only ["reason"; "detail"] ->
    let* detail = detail () in Ok (Provider_refused (Provider_unavailable { detail }))
  | Some (`String "provider_auth_refused") when only ["reason"; "detail"] ->
    let* detail = detail () in Ok (Provider_refused (Provider_auth_refused { detail }))
  | Some (`String "provider_configuration_refused") when only ["reason"; "detail"] ->
    let* detail = detail () in Ok (Provider_refused (Provider_configuration_refused { detail }))
  | Some (`String reason) -> Error ("not a not-final reason of this host: " ^ reason)
  | Some _ | None -> Error "a not-final reason is an object with a string reason"

type call_outcome =
  | Call_ended of call_final
  | Call_refused of provider_refusal

type execution_result = { outcome : call_outcome; receipt : Keeper_exact_walk_receipt.t }
type call = validate:(Yojson.Safe.t -> (checked, string) result) -> execution_result
type runner = admission_class:Agent_core.Llm_provider.Admission_class.t ->
  lane_key:string -> schema:Yojson.Safe.t -> request -> (call, lane_unavailable) result

(* One record per declaration and request: the request, its digest, every
   attempt in order (an attempt with no outcome was started and never
   finished) and the final result once there is one. *)
type record =
  { digest : string
  ; request : Yojson.Safe.t
  ; attempts : Yojson.Safe.t option list
  ; final : final option
  }

let record_to_json ~declaration_id ~request_id record =
  `Assoc
    [ "declaration_id", `String declaration_id
    ; "request_id", `String request_id
    ; "digest", `String record.digest
    ; "request", record.request
    ; "attempts", `List (List.map (function None -> `Null | Some outcome -> outcome) record.attempts)
    ; "final", (match record.final with None -> `Null | Some final -> final_to_json final)
    ]

let record_of_json = function
  | `Assoc fields ->
    let* digest =
      match List.assoc_opt "digest" fields with Some (`String value) -> Ok value | _ -> Error "record digest"
    in
    let* request = Option.to_result ~none:"record request" (List.assoc_opt "request" fields) in
    let* attempts =
      match List.assoc_opt "attempts" fields with
      | Some (`List values) -> Ok (List.map (function `Null -> None | outcome -> Some outcome) values)
      | _ -> Error "record attempts"
    in
    let* final =
      match List.assoc_opt "final" fields with
      | Some `Null -> Ok None
      | Some final -> retained_final_of_json final |> Result.map Option.some
      | None -> Error "record final"
    in
    Ok { digest; request; attempts; final }
  | _ -> Error "record must be an object"

let bound_record ~declaration_id request wire =
    let* wire = Lane_addon_action.canonical wire in
    let* record = record_of_json wire in
    let* encoded = Lane_addon_action.canonical
      (record_to_json ~declaration_id ~request_id:request.request_id record) in
    let* () = if Yojson.Safe.equal wire encoded then Ok ()
      else Error "retained Exact record has different identity or unknown fields" in
    let* original = request_of_json record.request in
    let* expected = Lane_addon_action.canonical (request_to_json request) in
    let* captured = Lane_addon_action.canonical (request_to_json original) in
    let* () = if String.equal record.digest (digest original)
        && String.equal record.digest (digest request)
        && Yojson.Safe.equal captured record.request && Yojson.Safe.equal captured expected then Ok ()
      else Error "retained Exact record differs from the original request or digest" in
    Ok record

type retained_observation = Retained_absent | Retained_open | Retained_terminal of final
let original_schema ~declaration_id ~schema request =
  let* _ = Runtime_schema.addon_lane ~declaration_id ~output:request.output in
  let* schema = Lane_addon_action.canonical schema in
  let* () = match schema with `Assoc _ -> Ok () | _ -> Error "original Exact schema must be an object" in
  let* () = match request.schema with
    | Some original when not (Yojson.Safe.equal original schema) ->
      Error "retained observation schema differs from its original request grant"
    | Some _ | None -> Ok () in
  Ok schema

let validate_record ~schema record =
    let decode_final = match schema with
      | None -> final_shape_of_json
      | Some schema -> final_of_json ~schema in
    let attempt = function
      | None -> Ok ()
      | Some (`Assoc fields as json) ->
        let* outcome = match List.assoc_opt "exception" fields with
          | None -> Ok json
          | Some (`String detail) when String.trim detail<>"" ->
            let remaining=List.remove_assoc "exception" fields in
            if Yojson.Safe.equal (`Assoc remaining) (final_to_json Outcome_unknown) then Ok (`Assoc remaining)
            else Error "only an unknown Exact outcome can retain exception evidence"
          | Some _ -> Error "invalid retained Exact exception evidence" in
        (match List.assoc_opt "status" fields,List.assoc_opt "reason" fields with
         | Some _,(None | Some _) -> let* _ = decode_final outcome in Ok ()
         | None,Some _ -> let* _ = not_final_of_json outcome in Ok ()
         | None,None -> Error "invalid retained Exact attempt outcome")
      | Some _ -> Error "retained Exact attempt must be an outcome object or started marker" in
    let* () = List.fold_left (fun state value -> let* () = state in attempt value) (Ok ()) record.attempts in
    match record.final with
    | None -> Ok Retained_open
    | Some final ->
      let* final = decode_final (final_to_json final) in
      Ok (Retained_terminal final)

(* The reads [run] applies to a retained record before it reuses it, with the
   declaration and the original request the record names. *)
let check_retained_record wire =
  let* declaration_id = match wire with
    | `Assoc fields -> (match List.assoc_opt "declaration_id" fields with
        | Some (`String value) -> Ok value
        | Some _ | None -> Error "record declaration_id")
    | _ -> Error "record must be an object" in
  let* stored = record_of_json wire in
  let* original = request_of_json stored.request in
  let* stored = bound_record ~declaration_id original wire in
  let* _ = validate_record ~schema:None stored in
  Ok ()

let observe_retained ~store ~declaration_id ~schema request =
  let* schema = original_schema ~declaration_id ~schema request in
  let* wire = Lane_addon_store.load_exact_request store ~declaration_id ~request_id:request.request_id in
  match wire with
  | None -> Ok Retained_absent
  | Some wire ->
    let* record = bound_record ~declaration_id request wire in
    validate_record ~schema:(Some schema) record

(* The host link belongs to the original request owner, not to a worker
   evidence address. Canonical tagged tuples keep both ID spaces unambiguous. *)
let proof_key ~declaration_id request =
  let tuple values = Yojson.Safe.to_string (`List values) in
  tuple [`String "exact-original-execution"; `String declaration_id],
  tuple [`String "original-request"; `String request.request_id; `String (digest request)]

let outcome_to_json = function
  | Call_ended final -> final_to_json (Call_final final)
  | Call_refused refusal -> not_final_to_json (Provider_refused refusal)

let attempt_of_outcome = function
  | Call_ended final -> Final (Call_final final)
  | Call_refused refusal -> Not_final (Provider_refused refusal)

let outcome_of_json ~schema json =
  match json with
  | `Assoc fields when List.mem_assoc "status" fields ->
      let* final = final_of_json ~schema json in
      (match final with
       | Call_final final -> Ok (Call_ended final)
       | Outcome_unknown | Not_allowed _ | Request_id_reused ->
           Error "original execution proof must retain an actual call outcome")
  | `Assoc _ ->
      let* reason = not_final_of_json json in
      (match reason with
       | Provider_refused refusal -> Ok (Call_refused refusal)
       | Lane_unavailable _ | Attempt_in_progress ->
           Error "original execution proof cannot grant a never-started call")
  | _ -> Error "original execution outcome must be an object"

let validate_execution (execution : execution_result) =
  match execution.outcome, Keeper_exact_walk_receipt.answered_slot execution.receipt with
  | Call_ended (Answered {slot; _}), Some observed when String.equal slot observed -> Ok ()
  | Call_ended (Answered _), (None | Some _) -> Error "original answer differs from its execution receipt"
  | (Call_ended (Invalid_output _ | Input_refused _ | Output_limit_reached _) | Call_refused _), None -> Ok ()
  | (Call_ended (Invalid_output _ | Input_refused _ | Output_limit_reached _) | Call_refused _), Some _ ->
      Error "original failure cannot retain a successful execution receipt"

let proof_to_json ~store ~declaration_id request ~schema ~attempt_ordinal execution =
  `Assoc ["version", `Int 1; "kind", `String "exact-original-execution";
    "store_root", `String (Lane_addon_store.root store); "declaration_id", `String declaration_id;
    "request_id", `String request.request_id; "digest", `String (digest request);
    "request", request_to_json request; "schema", schema; "attempt_ordinal", `Int attempt_ordinal;
    "outcome", outcome_to_json execution.outcome;
    "receipt", Keeper_exact_walk_receipt.to_json execution.receipt]

let decode_proof ~store ~declaration_id request ~attempt_ordinal json =
  let* normalized = Lane_addon_action.canonical json in
  let field name = match normalized with
    | `Assoc fields -> Option.to_result ~none:("missing original execution " ^ name) (List.assoc_opt name fields)
    | _ -> Error "original execution proof must be an object" in
  let* schema = field "schema" in
  let* () = match schema with `Assoc _ -> Ok () | _ -> Error "original execution schema must be an object" in
  let* () = match request.schema with
    | Some granted -> let* granted = Lane_addon_action.canonical granted in
        if Yojson.Safe.equal schema granted then Ok () else Error "original execution differs from its request schema"
    | None -> Ok () in
  let* outcome = field "outcome" in
  let* outcome = outcome_of_json ~schema outcome in
  let* receipt = field "receipt" in
  let* receipt = Keeper_exact_walk_receipt.of_json receipt in
  let execution = {outcome; receipt} in
  let* () = validate_execution execution in
  let* encoded = Lane_addon_action.canonical
    (proof_to_json ~store ~declaration_id request ~schema ~attempt_ordinal execution) in
  if Yojson.Safe.equal normalized encoded then Ok (schema, execution)
  else Error "original execution proof has unknown, conflicting or rebound identity fields"

(* One existing Store link retains this original request's sparse ordered
   completed attempts. Losing the Exact index cannot hide an earlier proof
   merely because its ordinal was greater than one. This is not a work index. *)
let proofs_to_json ~store ~declaration_id request proofs =
  `Assoc ["version",`Int 1; "kind",`String "exact-original-executions";
    "executions",`List (List.map (fun (attempt_ordinal,schema,execution) ->
      proof_to_json ~store ~declaration_id request ~schema ~attempt_ordinal execution) proofs)]

let load_proofs ~store ~declaration_id request =
  let instance_id,request_id=proof_key ~declaration_id request in
  let* wire=Lane_addon_store.load_host_result store ~instance_id ~request_id in
  match wire with
  | None -> Ok []
  | Some wire ->
    let* normalized=Lane_addon_action.canonical wire in
    let* values=match normalized with
      | `Assoc fields -> (match List.assoc_opt "executions" fields with
          | Some (`List (_::_ as values)) -> Ok values
          | Some _ | None -> Error "original execution link requires nonempty completed attempts")
      | _ -> Error "original execution link must be an object" in
    let* _,proofs=List.fold_left (fun state wire ->
      let* previous,proofs=state in
      let* attempt_ordinal=match wire with
        | `Assoc fields -> (match List.assoc_opt "attempt_ordinal" fields with
            | Some (`Int ordinal) when ordinal>previous -> Ok ordinal
            | Some _ | None -> Error "original execution ordinals must be positive and strictly increasing")
        | _ -> Error "original execution attempt must be an object" in
      let* schema,execution=decode_proof ~store ~declaration_id request ~attempt_ordinal wire in
      Ok (attempt_ordinal,(attempt_ordinal,schema,execution)::proofs)) (Ok (0,[])) values in
    let proofs=List.rev proofs in
    let* encoded=Lane_addon_action.canonical (proofs_to_json ~store ~declaration_id request proofs) in
    if Yojson.Safe.equal normalized encoded then Ok proofs
    else Error "original execution link has unknown or conflicting fields"

let selected_proof ~attempt_ordinal proofs =
  List.find_map (fun (ordinal,schema,execution) ->
    if ordinal=attempt_ordinal then Some (schema,execution) else None) proofs

let proof_matches_attempt record (ordinal,_schema,execution) =
  match List.nth_opt record.attempts (ordinal-1) with
  | None -> Error "original execution proof has no matching started attempt"
  | Some None -> Ok ()
  | Some (Some original) ->
    let* original=Lane_addon_action.canonical original in
    let* outcome=Lane_addon_action.canonical (outcome_to_json execution.outcome) in
    let* ()=if Yojson.Safe.equal original outcome then Ok ()
      else Error "original attempt differs from its retained execution proof" in
    (match execution.outcome,record.final with
     | Call_refused _, (None | Some _) -> Ok ()
     | Call_ended _, Some (Call_final final) ->
       let* retained=Lane_addon_action.canonical (final_to_json (Call_final final)) in
       if Yojson.Safe.equal retained outcome then Ok ()
       else Error "original final differs from its completed execution proof"
     | Call_ended _, (None | Some (Outcome_unknown | Not_allowed _ | Request_id_reused)) ->
       Error "completed terminal attempt has no matching original final")

let bound_proofs ~store ~declaration_id request record =
  let* proofs=load_proofs ~store ~declaration_id request in
  let* ()=List.fold_left (fun state proof -> let* ()=state in proof_matches_attempt record proof) (Ok ()) proofs in
  Ok proofs

let retain_proof ~store ~declaration_id request ~schema ~attempt_ordinal execution =
  let* () = validate_execution execution in
  let json = proof_to_json ~store ~declaration_id request ~schema ~attempt_ordinal execution in
  let* _ = decode_proof ~store ~declaration_id request ~attempt_ordinal json in
  let* proofs=load_proofs ~store ~declaration_id request in
  let* updated=match selected_proof ~attempt_ordinal proofs with
    | Some (original_schema,original) ->
      let* expected=Lane_addon_action.canonical json in
      let* actual=Lane_addon_action.canonical (proof_to_json ~store ~declaration_id request
        ~schema:original_schema ~attempt_ordinal original) in
      if Yojson.Safe.equal expected actual then Ok proofs else Error "conflicting original execution proof"
    | None ->
      if List.exists (fun (ordinal,_,_) -> ordinal>attempt_ordinal) proofs
      then Error "original execution proof cannot insert an earlier completed attempt"
      else Ok (proofs @ [attempt_ordinal,schema,execution]) in
  let json=proofs_to_json ~store ~declaration_id request updated in
  let* expected=Lane_addon_action.canonical json in
  let instance_id,request_id=proof_key ~declaration_id request in
  let* ()=Lane_addon_store.save_host_result store ~instance_id ~request_id json in
  let* confirmed=load_proofs ~store ~declaration_id request in
  let* confirmed=Lane_addon_action.canonical (proofs_to_json ~store ~declaration_id request confirmed) in
  if Yojson.Safe.equal expected confirmed then Ok ()
  else Error "original execution proof changed before durable confirmation"

type original_execution = No_completed_original | Completed_original of execution_result
let read_original_execution ~store ~declaration_id ~schema ~attempt_ordinal request =
  if attempt_ordinal <= 0 then Error "original execution attempt ordinal must be positive"
  else
    let* schema=original_schema ~declaration_id ~schema request in
    let* wire=Lane_addon_store.load_exact_request store ~declaration_id ~request_id:request.request_id in
    match wire with
    | None ->
      let* proofs=load_proofs ~store ~declaration_id request in
      if proofs=[] then Ok No_completed_original
      else Error "original execution proof has no original Exact request"
    | Some wire ->
      let* record=bound_record ~declaration_id request wire in
      let* _=validate_record ~schema:None record in
      let* proofs=bound_proofs ~store ~declaration_id request record in
      (match selected_proof ~attempt_ordinal proofs with
       | None -> Ok No_completed_original
       | Some (retained_schema,execution) ->
         if Yojson.Safe.equal schema retained_schema then Ok (Completed_original execution)
         else Error "original execution proof differs from the supplied original schema")

(* Requests this process is running, by store root, declaration and request.
   Only the base-path lease holder runs requests (see the interface), so a
   started attempt that is not here was cut off by a crash or a cancellation. *)
let in_flight : (string * string * string, unit) Hashtbl.t = Hashtbl.create 16
let in_flight_lock = Mutex.create ()

let claim key =
  Mutex.protect in_flight_lock (fun () ->
    if Hashtbl.mem in_flight key then false else (Hashtbl.replace in_flight key (); true))

let release key = Mutex.protect in_flight_lock (fun () -> Hashtbl.remove in_flight key)

type output_validator = Yojson.Safe.t -> (unit, string) result
type request_authorization = {
  admission_class : Agent_core.Llm_provider.Admission_class.t;
  validate_output : output_validator;
}
type execution_authority =
  store:Lane_addon_store.t -> declaration_id:string -> package:Lane_addon_types.package ->
  request -> (request_authorization, string) result

let run ~store ~declaration_id ~(package : Lane_addon_types.package) ~runner ~authorize_request request =
  let request_id = request.request_id in
  let key = Lane_addon_store.root store, declaration_id, request_id in
  (* Identity precedes permission: even a refused request owns its id. *)
  if not (claim key) then Ok (Not_final Attempt_in_progress)
  else Fun.protect ~finally:(fun () -> release key) (fun () ->
    let digest = digest request in
    let save record =
      Eio_unix.run_in_systhread (fun () ->
        Lane_addon_store.save_exact_request store ~declaration_id ~request_id
          (record_to_json ~declaration_id ~request_id record)) in
    let* retained = Eio_unix.run_in_systhread (fun () ->
      Lane_addon_store.load_exact_request store ~declaration_id ~request_id) in
    let* retained = match retained with
      | None -> Ok None
      | Some json ->
        let* stored = record_of_json json in
        let* original = request_of_json stored.request in
        let* () = if String.equal original.request_id request_id then Ok ()
          else Error "retained Exact record has a different original request ID" in
        let* stored = bound_record ~declaration_id original json in
        let* _ = validate_record ~schema:None stored in
        Ok (Some stored) in
    match retained with
    | Some record when not (String.equal record.digest digest) -> Ok (Final Request_id_reused)
    | None | Some _ ->
      let previous = match retained with
        | Some record -> record
        | None -> {digest; request = request_to_json request; attempts = []; final = None} in
      let* proofs=Eio_unix.run_in_systhread (fun () ->
        bound_proofs ~store ~declaration_id request previous) in
      let finish prior outcome =
        match outcome with
        | Call_ended final ->
            {prior with attempts=prior.attempts @ [Some (final_to_json (Call_final final))];
              final=Some (Call_final final)}
        | Call_refused refusal ->
            {prior with attempts=prior.attempts @ [Some (not_final_to_json (Provider_refused refusal))]} in
      let* previous, recovered = match previous.final with
        | None when List.exists Option.is_none previous.attempts ->
            (match List.rev previous.attempts with
             | None :: earlier when not (List.exists Option.is_none earlier) ->
               let attempt_ordinal=List.length previous.attempts in
               (match selected_proof ~attempt_ordinal proofs with
                | None ->
                  let unknown={previous with final=Some Outcome_unknown} in
                  let* ()=save unknown in Ok (unknown,None)
                | Some (_original_schema, execution) ->
                  Eio.Cancel.protect (fun () ->
                    let finished=finish {previous with attempts=List.rev earlier} execution.outcome in
                    let* ()=save finished in
                    Ok (finished,Some (attempt_of_outcome execution.outcome))))
             | [] | Some _ :: _ | None :: _ -> Error "original Exact request has inconsistent started attempts")
        | None | Some (Call_final _ | Outcome_unknown | Not_allowed _ | Request_id_reused) -> Ok (previous,None) in
      let deny reason =
        let refusal = Not_allowed {reason} in
        let record = match previous.final with
          | None -> {previous with final = Some refusal}
          | Some (Not_allowed _) -> previous
          | Some (Call_final _ | Outcome_unknown | Request_id_reused) ->
              (* A selection change cannot erase the original provider result. *)
              {previous with attempts = previous.attempts @ [Some (final_to_json refusal)]} in
        let* () = save record in
        Ok (Final refusal) in
      match List.find_opt
        (fun (declared : Lane_addon_types.exact_output) -> String.equal declared.name request.output)
        package.exact_outputs with
      | None -> deny ("the effective package declares no exact output " ^ request.output)
      | Some declared ->
        match schema_for_request ~output:declared request with
        | Error reason -> deny reason
        | Ok schema ->
        let* authorization = authorize_request ~store ~declaration_id ~package request in
        let* lane = Runtime_schema.addon_lane ~declaration_id ~output:request.output in
        let lane_key = Runtime_schema.exact_lane_key (Runtime_schema.Addon lane) in
        let validate answer =
          let* checked = validate_answer ~output:declared request answer in
          let* () = authorization.validate_output (checked_json checked) in
          Ok checked in
        let deliver = function
          | Call_final (Answered {output; slot; usage}) ->
              (match validate (checked_json output) with
               | Ok output -> Call_final (Answered {output; slot; usage})
               | Error detail -> Call_final (Invalid_output
                   {detail = "the retained answer does not match the package, original request or consumer semantics: " ^ detail}))
          | (Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _) | Outcome_unknown | Not_allowed _ | Request_id_reused)
            as final -> final in
        match previous.final, recovered with
        | Some final, (None | Some _) -> Ok (Final (deliver final))
        | None, Some attempt -> Ok attempt
        | None, None ->
          Eio.Fiber.check ();
          match runner ~admission_class:authorization.admission_class ~lane_key ~schema request with
          | Error unavailable ->
            let reason = Lane_unavailable unavailable in
            let* () = save {previous with attempts = previous.attempts @ [Some (not_final_to_json reason)]} in
            Ok (Not_final reason)
          | Ok call ->
            let* () = save {previous with attempts = previous.attempts @ [None]} in
            (* The save yields. A retiring incarnation must not start a call
               after it returns. A cancelled started attempt remains unknown. *)
            Eio.Fiber.check ();
            let attempt, raised, execution =
              match call ~validate with
              | execution -> attempt_of_outcome execution.outcome, None, Some execution
              | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
              | exception exn -> Final Outcome_unknown, Some (Printexc.to_string exn), None in
            let with_raised = function
              | `Assoc fields -> `Assoc (fields @ match raised with None -> [] | Some text -> ["exception", `String text])
              | json -> json in
            Eio.Cancel.protect (fun () ->
              let* () = match execution with
                | None -> Ok ()
                | Some execution -> Eio_unix.run_in_systhread (fun () ->
                    retain_proof ~store ~declaration_id request ~schema
                      ~attempt_ordinal:(List.length previous.attempts + 1) execution) in
              let finished = match attempt with
                | Final final ->
                    {previous with attempts = previous.attempts @ [Some (with_raised (final_to_json final))]; final = Some final}
                | Not_final reason ->
                    {previous with attempts = previous.attempts @ [Some (not_final_to_json reason)]} in
              let* () = save finished in
              Ok attempt))
