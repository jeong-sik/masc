open Result.Syntax

type role = User | Assistant
type message = { role : role; text : string }

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

(* Every request in this file comes from [Request.of_json]: the record is
   private here as it is in the interface. [of_json] keeps the schema
   canonical, so two requests with equal canonical bodies write the same JSON
   and have the same [digest]. *)
module Request : sig
  type t = private
    { request_id : string
    ; output : string
    ; system : string option
    ; messages : message list
    ; schema : Yojson.Safe.t option
    }
  val of_json : Yojson.Safe.t -> (t, string) result
end = struct
  type t =
    { request_id : string
    ; output : string
    ; system : string option
    ; messages : message list
    ; schema : Yojson.Safe.t option
    }

  let of_json = function
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
          let rec loop acc = function
            | [] -> Ok (List.rev acc)
            | value :: rest ->
              let* message = message_of_json value in
              loop (message :: acc) rest
          in
          loop [] values
        | Some _ | None -> Error "messages requires at least one conversation message"
      in
      let* schema = match List.assoc_opt "schema" fields with
        | None -> Ok None
        | Some (`Assoc _ as schema) -> Lane_addon_action.canonical schema |> Result.map Option.some
        | Some _ -> Error "request schema must be a JSON object" in
      Ok { request_id; output; system; messages; schema }
    | _ -> Error "an exact_output request must be an object"
end

type request = Request.t = private
  { request_id : string
  ; output : string
  ; system : string option
  ; messages : message list
  ; schema : Yojson.Safe.t option
  }

let request_of_json = Request.of_json

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

(* A request with the digest of that same request. Proofs and records name a
   request only by its [request_id] and [digest], so every read or write that
   binds a proof or a record to a request takes this value. [make] is the only
   way to build one.

   The digest writes the whole request out as text. It is made the first time
   a read or write compares it, names a proof file with it or writes it into a
   new record, so a read that stops before any of these writes nothing out.
   One value belongs to one operation, which uses it from one flow at a time:
   a [Systhread_host.run] step runs on another thread while its caller waits.
   So no two threads force it at once. *)
module Digested : sig
  type t
  val make : request -> t
  val request : t -> request
  val digest : t -> string
end = struct
  type t = { request : request; digest : string Lazy.t }
  let make request = { request; digest = lazy (digest request) }
  let request t = t.request
  let digest t = Lazy.force t.digest
end

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

let validate_consumer_shape ~schema answer =
  match Lane_addon_exact_shape.issue ~at:"$" schema answer with
  | None -> Ok answer
  | Some issue -> Error (Lane_addon_exact_shape.to_string issue)

let validate_answer ~output request answer =
  let* _ = schema_for_request ~output request in
  let* answer = Lane_addon_action.validate_input ~schema:output.Lane_addon_types.schema ~name:request.output answer in
  match request.schema with
  | None -> Ok answer
  | Some schema -> validate_consumer_shape ~schema answer

type input_refusal =
  | Input_capacity
  | Context_overflow
  | Invalid_request
  | Request_body_refused
[@@deriving enumerate]

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

type unknown_cause = Interrupted | Cut | Raised
type retained_final =
  | Retained_call of call_final
  | Retained_unknown of unknown_cause
  | Retained_not_allowed of { reason : string }
  | Retained_request_id_reused

let delivered = function
  | Retained_call final -> Call_final final
  | Retained_unknown (Interrupted | Cut | Raised) -> Outcome_unknown
  | Retained_not_allowed {reason} -> Not_allowed {reason}
  | Retained_request_id_reused -> Request_id_reused

let cause_to_string = function Interrupted -> "interrupted" | Cut -> "cut" | Raised -> "raised"
let cause_of_json = function
  | `String "interrupted" -> Ok Interrupted
  | `String "cut" -> Ok Cut
  | `String "raised" -> Ok Raised
  | _ -> Error "unknown Exact outcome requires interrupted, cut or raised cause"

type lane_unavailable =
  | Lane_unconfigured
  | Lane_off
  | No_admitted_slots
  | Lane_registry_unavailable of { detail : string }
  | Every_slot_held of { until : float }

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

let input_refusal_of_string s = List.find_opt (fun v -> String.equal (input_refusal_to_string v) s) all_of_input_refusal

let refused_before_host = function
  | Call_final (Input_refused Request_body_refused) -> true
  | Call_final
      ( Answered _ | Invalid_output _ | Output_limit_reached _
      | Input_refused (Input_capacity | Context_overflow | Invalid_request) )
  | Outcome_unknown | Not_allowed _ | Request_id_reused -> false

let usage_to_json { input_tokens; output_tokens } =
  `Assoc [ "input_tokens", `Int input_tokens; "output_tokens", `Int output_tokens ]

let final_status = function
  | Call_final (Answered _) -> "answered"
  | Call_final (Invalid_output _) -> "invalid_output"
  | Call_final (Input_refused _) -> "input_refused"
  | Call_final (Output_limit_reached _) -> "output_limit_reached"
  | Outcome_unknown -> "outcome_unknown"
  | Not_allowed _ -> "not_allowed"
  | Request_id_reused -> "request_id_reused"

let final_to_json final =
  let status = "status", `String (final_status final) in
  match final with
  | Call_final (Answered { output; slot; usage }) ->
    `Assoc
      ([ status; "output", output; "slot", `String slot ]
       @ match usage with None -> [] | Some usage -> [ "usage", usage_to_json usage ])
  | Call_final (Invalid_output { detail }) -> `Assoc [ status; "detail", `String detail ]
  | Call_final (Input_refused kind) ->
    `Assoc [ status; "kind", `String (input_refusal_to_string kind) ]
  | Call_final (Output_limit_reached { detail }) -> `Assoc [ status; "detail", `String detail ]
  | Outcome_unknown -> `Assoc [ status ]
  | Not_allowed { reason } -> `Assoc [ status; "reason", `String reason ]
  | Request_id_reused -> `Assoc [ status ]

(* The retained record reads back only what this module wrote; anything else is
   an unreadable record, not a guess. *)
let worker_final_shape json =
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
  let* final = worker_final_shape normalized in
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

(* A granted consumer schema is a provider requirement with a partial shape
   guard, not a Host_tool input contract. Original proofs and observations use
   the same meaning as initial validation. Delivery independently rechecks the
   current package baseline and original consumer authority. *)
let original_final_of_json ~schema request json =
  match request.schema with
  | None -> final_of_json ~schema json
  | Some _ ->
      let* final = final_shape_of_json json in
      match final with
      | Call_final (Answered {output;slot;usage}) ->
          let* output = validate_consumer_shape ~schema output in
          Ok (Call_final (Answered {output;slot;usage}))
      | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
      | Outcome_unknown | Not_allowed _ | Request_id_reused -> Ok final

let original_consumer_answer_payload request json =
  let* schema = Option.to_result ~none:"Original request has no consumer schema" request.schema in
  let* final = original_final_of_json ~schema request json in
  match final with
  | Call_final (Answered {output;_}) -> Ok (checked_json output)
  | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
  | Outcome_unknown | Not_allowed _ | Request_id_reused -> Error "Original final is not an answer"

let retained_final_to_json = function
  | Retained_unknown cause ->
      `Assoc ["status", `String "outcome_unknown"; "cause", `String (cause_to_string cause)]
  | (Retained_call _ | Retained_not_allowed _ | Retained_request_id_reused) as retained ->
      final_to_json (delivered retained)

let host_final_shape_of_json json =
  let* normalized = Lane_addon_action.canonical json in
  match normalized with
  | `Assoc fields when List.assoc_opt "status" fields = Some (`String "outcome_unknown") ->
      let* cause = match List.assoc_opt "cause" fields with
        | Some cause -> cause_of_json cause
        | None -> Error "unknown Exact outcome has no host cause" in
      let retained = Retained_unknown cause in
      let* encoded = Lane_addon_action.canonical (retained_final_to_json retained) in
      if Yojson.Safe.equal encoded normalized then Ok retained
      else Error "invalid or unknown retained final fields"
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      let* final = final_shape_of_json normalized in
      (match final with
       | Call_final final -> Ok (Retained_call final)
       | Not_allowed {reason} -> Ok (Retained_not_allowed {reason})
       | Request_id_reused -> Ok Retained_request_id_reused
       | Outcome_unknown -> Error "unknown Exact outcome has no host cause")

let retained_final_of_json ~schema json =
  let* retained = host_final_shape_of_json json in
  match retained with
  | Retained_call (Answered {output;slot;usage}) ->
      let* output = Lane_addon_action.validate_input ~schema ~name:"model result" output in
      Ok (Retained_call (Answered {output;slot;usage}))
  | Retained_call (Invalid_output _ | Input_refused _ | Output_limit_reached _)
  | Retained_unknown (Interrupted | Cut | Raised) | Retained_not_allowed _ | Retained_request_id_reused -> Ok retained

let not_final_reason = function
  | Lane_unavailable Lane_unconfigured -> "lane_unconfigured"
  | Lane_unavailable Lane_off -> "lane_off"
  | Lane_unavailable No_admitted_slots -> "no_admitted_slots"
  | Lane_unavailable (Lane_registry_unavailable _) -> "lane_registry_unavailable"
  | Lane_unavailable (Every_slot_held _) -> "every_slot_held"
  | Provider_refused (Provider_unavailable _) -> "provider_unavailable"
  | Provider_refused (Provider_auth_refused _) -> "provider_auth_refused"
  | Provider_refused (Provider_configuration_refused _) -> "provider_configuration_refused"
  | Attempt_in_progress -> "attempt_in_progress"

let not_final_to_json not_final =
  let reason = "reason", `String (not_final_reason not_final) in
  match not_final with
  | Lane_unavailable (Lane_unconfigured | Lane_off | No_admitted_slots) | Attempt_in_progress ->
    `Assoc [ reason ]
  | Lane_unavailable (Every_slot_held { until }) -> `Assoc [ reason; "until", `Float until ]
  | Lane_unavailable (Lane_registry_unavailable { detail })
  | Provider_refused
      ( Provider_unavailable { detail }
      | Provider_auth_refused { detail }
      | Provider_configuration_refused { detail } ) -> `Assoc [ reason; "detail", `String detail ]

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
  | Some (`String "every_slot_held") when only ["reason"; "until"] ->
    (* The store writes a whole number as an integer
       (Lane_addon_action.canonical), and a reset a provider states in whole
       seconds, as Claude Code does, is one. *)
    let seconds = match List.assoc_opt "until" fields with
      | Some (`Float until) -> Some until
      | Some (`Int until) -> Some (float_of_int until)
      | Some (`Intlit digits) -> float_of_string_opt digits
      | Some _ | None -> None in
    (match seconds with
     | Some until when Float.is_finite until && Float.compare until 0.0 > 0 ->
       Ok (Lane_unavailable (Every_slot_held { until }))
     | Some _ | None -> Error "every_slot_held needs until as a positive finite number of seconds")
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
type dispatch_guard = unit -> (unit, string) result
type dispatch = Measurement | Generation
type runner = before_dispatch:(dispatch -> (unit, string) result) ->
  admission_class:Agent_core.Llm_provider.Admission_class.t ->
  lane_key:string -> schema:Yojson.Safe.t ->
  size_refused:Keeper_exact_walk_receipt.http_slot list -> request -> (call, lane_unavailable) result

type recorded_attempt =
  | Started of string
  | Deferred of not_final
  | Completed_call of call_final
  | Unknown_interrupted
  | Unknown_cut
  | Unknown_raised of string
  | Delivery_refused of { reason : string }
  | Reused

let recorded_attempt_to_json = function
  | Started incarnation -> `Assoc ["started", `String incarnation]
  | Deferred reason -> not_final_to_json reason
  | Completed_call final -> final_to_json (Call_final final)
  | Unknown_interrupted -> retained_final_to_json (Retained_unknown Interrupted)
  | Unknown_cut -> retained_final_to_json (Retained_unknown Cut)
  | Unknown_raised text ->
      `Assoc ["status", `String "outcome_unknown"; "cause", `String "raised"; "exception", `String text]
  | Delivery_refused {reason} -> final_to_json (Not_allowed {reason})
  | Reused -> final_to_json Request_id_reused

let recorded_attempt_of_json json =
  let* normalized = Lane_addon_action.canonical json in
  let* attempt = match normalized with
    | `Assoc ["started", `String incarnation]
        when String.length incarnation = 32 && String.for_all (function
          | '0'..'9' | 'a'..'f' -> true | _ -> false) incarnation -> Ok (Started incarnation)
    | `Assoc fields when List.assoc_opt "status" fields = Some (`String "outcome_unknown") ->
        let* cause = match List.assoc_opt "cause" fields with
          | Some cause -> cause_of_json cause
          | None -> Error "unknown Exact attempt has no host cause" in
        (match cause, List.assoc_opt "exception" fields with
         | Interrupted, None -> Ok Unknown_interrupted
         | Cut, None -> Ok Unknown_cut
         | Raised, Some (`String text) when String.trim text <> "" -> Ok (Unknown_raised text)
         | (Interrupted | Cut), Some _ | Raised, (None | Some _) ->
             Error "only a raised Exact attempt requires nonblank exception evidence")
    | `Assoc fields when List.mem_assoc "status" fields ->
        let* final = final_shape_of_json normalized in
        (match final with
         | Call_final final -> Ok (Completed_call final)
         | Not_allowed {reason} -> Ok (Delivery_refused {reason})
         | Request_id_reused -> Ok Reused
         | Outcome_unknown -> Error "unknown Exact attempt has no host cause")
    | `Assoc _ -> let* reason = not_final_of_json normalized in Ok (Deferred reason)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        Error "retained Exact attempt requires an outcome or incarnation marker" in
  let* encoded = Lane_addon_action.canonical (recorded_attempt_to_json attempt) in
  if Yojson.Safe.equal encoded normalized then Ok attempt
  else Error "retained Exact attempt has unknown or inconsistent fields"

(* Final wire values remain worker-shaped. The cause and raised text belong
   to the typed attempt that established that final. *)
type record =
  { digest : string
  ; request : Yojson.Safe.t
  ; attempts : recorded_attempt list
  ; final : final option
  }

let record_to_json ~declaration_id ~request_id record =
  `Assoc
    [ "declaration_id", `String declaration_id
    ; "request_id", `String request_id
    ; "digest", `String record.digest
    ; "request", record.request
    ; "attempts", `List (List.map recorded_attempt_to_json record.attempts)
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
      | Some (`List values) ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | value :: rest ->
            let* attempt = recorded_attempt_of_json value in
            loop (attempt :: acc) rest
        in
        loop [] values
      | _ -> Error "record attempts"
    in
    let* final =
      match List.assoc_opt "final" fields with
      | Some `Null -> Ok None
      | Some final -> final_shape_of_json final |> Result.map Option.some
      | None -> Error "record final"
    in
    Ok { digest; request; attempts; final }
  | _ -> Error "record must be an object"

let bound_record ~declaration_id bound wire =
    let request = Digested.request bound in
    let* wire = Lane_addon_action.canonical wire in
    let* record = record_of_json wire in
    let* encoded = Lane_addon_action.canonical
      (record_to_json ~declaration_id ~request_id:request.request_id record) in
    let* () = if Yojson.Safe.equal wire encoded then Ok ()
      else Error "retained Exact record has different identity or unknown fields" in
    let* original = request_of_json record.request in
    let* expected = Lane_addon_action.canonical (request_to_json request) in
    let* captured = Lane_addon_action.canonical (request_to_json original) in
    (* Both requests come from [Request.of_json], so equal canonical bodies
       have equal digests. Comparing the record's digest with the caller's
       once also covers the original's. *)
    let* () = if Yojson.Safe.equal captured record.request && Yojson.Safe.equal captured expected
        && String.equal record.digest (Digested.digest bound) then Ok ()
      else Error "retained Exact record differs from the original request or digest" in
    Ok record

type retained_observation = Retained_absent | Retained_open | Retained_terminal of retained_final
let original_schema ~declaration_id ~schema request =
  let* _ = Runtime_schema.addon_lane ~declaration_id ~output:request.output in
  let* schema = Lane_addon_action.canonical schema in
  let* () = match schema with `Assoc _ -> Ok () | _ -> Error "original Exact schema must be an object" in
  let* () = match request.schema with
    | Some original when not (Yojson.Safe.equal original schema) ->
      Error "retained observation schema differs from its original request grant"
    | Some _ | None -> Ok () in
  Ok schema

let validate_record ~request ~schema record =
  let decode_final = match schema with
    | None -> final_shape_of_json
    | Some schema -> original_final_of_json ~schema request in
  let rec deferred_only = function
    | [] -> Ok ()
    | Deferred _ :: rest -> deferred_only rest
    | (Started _ | Completed_call _ | Unknown_interrupted | Unknown_cut | Unknown_raised _
      | Delivery_refused _ | Reused) :: _ -> Error "original Exact request has inconsistent attempt order" in
  let retained = function
    | Completed_call final -> Ok (Retained_call final)
    | Unknown_interrupted -> Ok (Retained_unknown Interrupted)
    | Unknown_cut -> Ok (Retained_unknown Cut)
    | Unknown_raised _ -> Ok (Retained_unknown Raised)
    | Delivery_refused {reason} -> Ok (Retained_not_allowed {reason})
    | Reused -> Ok Retained_request_id_reused
    | Started _ | Deferred _ -> Error "original Exact final has no completed determining attempt" in
  let rec without_delivery_refusals = function
    | Delivery_refused _ :: rest -> without_delivery_refusals rest
    | ([] | (Started _ | Deferred _ | Completed_call _ | Unknown_interrupted | Unknown_cut
        | Unknown_raised _ | Reused) :: _) as attempts -> attempts in
  match record.final with
  | None ->
      let* () = match List.rev record.attempts with
        | Started _ :: earlier -> deferred_only earlier
        | ([] | (Deferred _ | Completed_call _ | Unknown_interrupted | Unknown_cut | Unknown_raised _
            | Delivery_refused _ | Reused) :: _) as attempts -> deferred_only attempts in
      Ok Retained_open
  | Some final ->
      let* final = decode_final (final_to_json final) in
      let attempts = match final with
        | Call_final _ | Outcome_unknown | Request_id_reused ->
            without_delivery_refusals (List.rev record.attempts)
        | Not_allowed _ -> List.rev record.attempts in
      let* observed = match attempts, final with
        | (Completed_call _ | Unknown_interrupted | Unknown_cut | Unknown_raised _
          | Delivery_refused _ | Reused as decisive) :: earlier, _ ->
            let* () = deferred_only earlier in retained decisive
        | ([], Not_allowed {reason}) | (Deferred _ :: _, Not_allowed {reason}) ->
            let* () = deferred_only attempts in Ok (Retained_not_allowed {reason})
        | [], (Call_final _ | Outcome_unknown | Request_id_reused)
        | (Started _ :: _), _ | (Deferred _ :: _), (Call_final _ | Outcome_unknown | Request_id_reused) ->
            Error "original Exact final has no completed determining attempt" in
      let* actual = Lane_addon_action.canonical (final_to_json (delivered observed)) in
      let* expected = Lane_addon_action.canonical (final_to_json final) in
      if Yojson.Safe.equal actual expected then Ok (Retained_terminal observed)
      else Error "original Exact final differs from its determining attempt"

type recovery_error =
  | Recovery_unavailable of string
  | Recovery_invalid of string

let describe_recovery_error = function
  | Recovery_unavailable detail -> detail
  | Recovery_invalid detail -> detail
;;

(* A record this read could not reach may appear later; a record it reached and
   refused cannot turn into a different record by waiting. Keeping the two
   apart is what lets the caller refuse instead of retrying forever.
   Written as functions, not as [Result.map_error] values: a partially applied
   [map_error] is not generalized, so the first use would pin the error type and
   every other call site would fail to type. *)
let unreadable result =
  Result.map_error (fun detail -> Recovery_unavailable detail) result
let invalid result =
  Result.map_error (fun detail -> Recovery_invalid detail) result

(* What the original's record shows: [wire] is the JSON it holds, [None] when
   there is no record, and [schema] the one [original_schema] checked. *)
let observation ~declaration_id ~schema bound = function
  | None -> Ok Retained_absent
  | Some wire ->
    let* record = bound_record ~declaration_id bound wire in
    validate_record ~request:(Digested.request bound) ~schema:(Some schema) record

let observe_retained_classified ~store ~declaration_id ~schema bound =
  let request = Digested.request bound in
  (* [original_schema] reads no record: it validates the caller's own schema and
     compares it with the grant kept in the request. A mismatch there cannot be
     cured by reading again, so it is an invalid original rather than an
     unreachable one. *)
  let* schema = invalid (original_schema ~declaration_id ~schema request) in
  let* wire = unreadable (Lane_addon_store.load_exact_request store ~declaration_id
    ~request_id:request.request_id) in
  invalid (observation ~declaration_id ~schema bound wire)

let observe_retained ~store ~declaration_id ~schema request =
  Result.map_error describe_recovery_error
    (observe_retained_classified ~store ~declaration_id ~schema (Digested.make request))

let observe_record ~declaration_id ~schema request record =
  let* schema = original_schema ~declaration_id ~schema request in
  observation ~declaration_id ~schema (Digested.make request) record

(* The host link belongs to the original request owner, not to a worker
   evidence address. Canonical tagged tuples keep both ID spaces unambiguous. *)
let proof_tuple values = Yojson.Safe.to_string (`List values)
let proof_instance_id ~declaration_id =
  proof_tuple [`String "exact-original-execution"; `String declaration_id]
(* A proof file is named by its original request's [request_id] and
   [digest]. *)
let proof_request_key ~request_id ~digest =
  proof_tuple [`String "original-request"; `String request_id; `String digest]
(* The proof functions below take a [Digested.t]. The entry point of an
   operation makes it once and every proof it reads or writes shares it. *)
let proof_key ~declaration_id bound =
  proof_instance_id ~declaration_id,
  proof_request_key ~request_id:(Digested.request bound).request_id
    ~digest:(Digested.digest bound)
let proof_directory ~declaration_id =
  Lane_addon_store.host_result_directory ~instance_id:(proof_instance_id ~declaration_id)

let outcome_to_json = function
  | Call_ended final -> final_to_json (Call_final final)
  | Call_refused refusal -> not_final_to_json (Provider_refused refusal)

let attempt_of_outcome = function
  | Call_ended final -> Final (Call_final final)
  | Call_refused refusal -> Not_final (Provider_refused refusal)

let outcome_of_json ~schema request json =
  match json with
  | `Assoc fields when List.mem_assoc "status" fields ->
      let* final = original_final_of_json ~schema request json in
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

let proof_to_json ~store ~declaration_id bound ~schema ~attempt_ordinal execution =
  let request = Digested.request bound in
  `Assoc ["version", `Int 1; "kind", `String "exact-original-execution";
    "store_root", `String (Lane_addon_store.root store); "declaration_id", `String declaration_id;
    "request_id", `String request.request_id; "digest", `String (Digested.digest bound);
    "request", request_to_json request; "schema", schema; "attempt_ordinal", `Int attempt_ordinal;
    "outcome", outcome_to_json execution.outcome;
    "receipt", Keeper_exact_walk_receipt.to_json execution.receipt]

let decode_proof ~store ~declaration_id bound ~attempt_ordinal json =
  let request = Digested.request bound in
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
  let* outcome = outcome_of_json ~schema request outcome in
  let* receipt = field "receipt" in
  (* Version 1 was historically decoded after wrapper canonicalization. Keep
     that read behavior, while version 2 checks the original JSON types before
     canonicalization can turn an integral float into an integer. *)
  let* receipt = match receipt with
    | `Assoc fields when List.assoc_opt "version" fields=Some (`Int 2) ->
      (match json with
       | `Assoc original ->
         let* ()=if List.assoc_opt "version" original=Some (`Int 1)
             && List.assoc_opt "attempt_ordinal" original=Some (`Int attempt_ordinal)
           then Ok () else Error "version 2 original proof requires integer wrapper identity" in
         (match List.assoc_opt "receipt" original with
          | Some raw -> Keeper_exact_walk_receipt.of_json raw
          | None -> Error "missing original execution receipt")
       | _ -> Error "original execution proof must be an object")
    | _ -> Keeper_exact_walk_receipt.of_json receipt in
  let execution = {outcome; receipt} in
  let* () = validate_execution execution in
  let* encoded = Lane_addon_action.canonical
    (proof_to_json ~store ~declaration_id bound ~schema ~attempt_ordinal execution) in
  if Yojson.Safe.equal normalized encoded then Ok (schema, execution)
  else Error "original execution proof has unknown, conflicting or rebound identity fields"

(* One existing Store link retains this original request's sparse ordered
   completed attempts. Losing the Exact index cannot hide an earlier proof
   merely because its ordinal was greater than one. This is not a work index. *)
let proofs_to_json ~store ~declaration_id bound proofs =
  `Assoc ["version",`Int 1; "kind",`String "exact-original-executions";
    "executions",`List (List.map (fun (attempt_ordinal,schema,execution) ->
      proof_to_json ~store ~declaration_id bound ~schema ~attempt_ordinal execution) proofs)]

(* The proof link is read from disk and then decoded. Callers that must tell a
   transient read failure from a permanently invalid link use these two steps
   apart; [load_proofs] keeps them together for callers that need only the
   result. *)
let load_proof_wire ~store ~declaration_id bound =
  let instance_id,request_id=proof_key ~declaration_id bound in
  Lane_addon_store.load_host_result store ~instance_id ~request_id

let decode_proofs ~store ~declaration_id bound = function
  | None -> Ok []
  | Some wire ->
    let* normalized=Lane_addon_action.canonical wire in
    let* values=match wire with
      | `Assoc fields -> (match List.assoc_opt "executions" fields with
          | Some (`List (_::_ as values)) -> Ok values
          | Some _ | None -> Error "original execution link requires nonempty completed attempts")
      | _ -> Error "original execution link must be an object" in
    let* _,proofs=List.fold_left (fun state wire ->
      let* previous,proofs=state in
      let* normalized_entry=Lane_addon_action.canonical wire in
      let* attempt_ordinal=match normalized_entry with
        | `Assoc fields -> (match List.assoc_opt "attempt_ordinal" fields with
            | Some (`Int ordinal) when ordinal>previous -> Ok ordinal
            | Some _ | None -> Error "original execution ordinals must be positive and strictly increasing")
        | _ -> Error "original execution attempt must be an object" in
      let* schema,execution=decode_proof ~store ~declaration_id bound ~attempt_ordinal wire in
      Ok (attempt_ordinal,(attempt_ordinal,schema,execution)::proofs)) (Ok (0,[])) values in
    let proofs=List.rev proofs in
    let* encoded=Lane_addon_action.canonical (proofs_to_json ~store ~declaration_id bound proofs) in
    if Yojson.Safe.equal normalized encoded then Ok proofs
    else Error "original execution link has unknown or conflicting fields"

let load_proofs ~store ~declaration_id bound =
  let* wire=load_proof_wire ~store ~declaration_id bound in
  decode_proofs ~store ~declaration_id bound wire

let proof_request_id ~declaration_id ~file_name json =
  let* request = match json with
    | `Assoc fields -> (match List.assoc_opt "executions" fields with
        | Some (`List (`Assoc first :: _)) ->
          (match List.assoc_opt "request" first with
           | Some request -> request_of_json request
           | None -> Error "missing original execution request")
        | Some _ | None -> Error "original execution link requires nonempty completed attempts")
    | _ -> Error "original execution link must be an object" in
  (* The sweep binds this file to no caller's request. It only checks that the
     file holds the request its name says. *)
  let request_key = proof_request_key ~request_id:request.request_id ~digest:(digest request) in
  if String.equal file_name
      (Filename.basename (Lane_addon_store.host_result_path
        ~instance_id:(proof_instance_id ~declaration_id) ~request_id:request_key))
  then Ok request.request_id
  else Error "original execution link is stored under another request's name"

let selected_proof ~attempt_ordinal proofs =
  List.find_map (fun (ordinal,schema,execution) ->
    if ordinal=attempt_ordinal then Some (schema,execution) else None) proofs

let proof_matches_attempt record (ordinal,_schema,execution) =
  match List.nth_opt record.attempts (ordinal-1) with
  | None -> Error "original execution proof has no matching started attempt"
  | Some (Started _) -> Ok ()
  | Some (Deferred _ | Completed_call _ | Unknown_interrupted | Unknown_cut | Unknown_raised _
    | Delivery_refused _ | Reused as original) ->
    let* original=Lane_addon_action.canonical (recorded_attempt_to_json original) in
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

(* Binding a proof to its attempt compares two values that are already decoded,
   so a mismatch is permanent: reading the same two records again cannot make
   them agree. *)
let bind_proofs record proofs =
  List.fold_left (fun state proof -> let* ()=state in proof_matches_attempt record proof) (Ok ()) proofs

let bound_proofs ~store ~declaration_id bound record =
  let* proofs=load_proofs ~store ~declaration_id bound in
  let* ()=bind_proofs record proofs in
  Ok proofs

module Retained_key = struct
  type t = { declaration_id : string; request_id : string; digest : string }

  let of_record = function
    | `Assoc fields ->
      let text name = match List.assoc_opt name fields with
        | Some (`String value) -> Ok value
        | Some _ | None -> Error ("record " ^ name) in
      let* declaration_id = text "declaration_id" in
      let* request_id = text "request_id" in
      let* digest = text "digest" in
      Ok { declaration_id; request_id; digest }
    | _ -> Error "record must be an object"

  let of_request ~declaration_id request =
    { declaration_id; request_id = request.request_id; digest = digest request }

  let equal left right =
    String.equal left.declaration_id right.declaration_id
    && String.equal left.request_id right.request_id
    && String.equal left.digest right.digest

  let proof_path key =
    Lane_addon_store.host_result_path
      ~instance_id:(proof_instance_id ~declaration_id:key.declaration_id)
      ~request_id:(proof_request_key ~request_id:key.request_id ~digest:key.digest)
end

let retained_final json = Result.map (fun record -> record.final) (record_of_json json)

let proof_store_roots = function
  | `Assoc fields ->
    (match List.assoc_opt "executions" fields with
     | Some (`List entries) ->
       List.filter_map (function
         | `Assoc entry ->
           (match List.assoc_opt "store_root" entry with
            | Some (`String root) -> Some root
            | Some _ | None -> None)
         | _ -> None) entries
     | Some _ | None -> [])
  | _ -> []

(* The reads [run] applies to a retained record and its proof link, in the
   order a check beside a running server reads them: the record, the link,
   then the record again. The server writes attempt n to the record before
   proof n and removes no attempt, so the second record holds every attempt
   the link proves. Both records are bound to the request and digest the first
   one names. *)
let check_retained_record ~store ~first ~proof ~second =
  let* { Retained_key.declaration_id; _ } = Retained_key.of_record first in
  let* stored = record_of_json first in
  let* original = request_of_json stored.request in
  let bound = Digested.make original in
  let* _ = bound_record ~declaration_id bound first in
  let* record = bound_record ~declaration_id bound second in
  let* _ = validate_record ~request:original ~schema:None record in
  let* proofs = decode_proofs ~store ~declaration_id bound proof in
  bind_proofs record proofs

(* RFC-exact-request-skips-a-slot-that-refused-its-input 3.2. The HTTP slots
   whose provider refused this request for its size, read from its retained
   proofs. The newest proof that sent to a slot decides for that slot, and its
   refusal counts only when that proof sent the schema this run sends. *)
let size_refused_slots ~schema proofs =
  match Lane_addon_action.canonical schema with
  | Error _ -> []
  | Ok schema ->
    let same_schema sent = match Lane_addon_action.canonical sent with
      | Ok sent -> Yojson.Safe.equal sent schema
      | Error _ -> false in
    let _decided,refused=List.fold_left (fun state (_ordinal,sent,(execution : execution_result)) ->
      List.fold_left (fun (decided,refused) ((slot : Keeper_exact_walk_receipt.http_slot),answer) ->
        if List.mem slot.slot_id decided then decided,refused
        else slot.slot_id::decided,(match answer with
          | Keeper_exact_walk_receipt.Input_size_refused when same_schema sent -> slot::refused
          | Keeper_exact_walk_receipt.Input_size_refused | Keeper_exact_walk_receipt.Other_answer -> refused))
        state (Keeper_exact_walk_receipt.http_slot_answers execution.receipt))
      ([],[]) (List.rev proofs) in
    List.rev refused

let retain_proof ~store ~declaration_id bound ~schema ~attempt_ordinal execution =
  let* () = validate_execution execution in
  let json = proof_to_json ~store ~declaration_id bound ~schema ~attempt_ordinal execution in
  let* _ = decode_proof ~store ~declaration_id bound ~attempt_ordinal json in
  let* proofs=load_proofs ~store ~declaration_id bound in
  let* updated=match selected_proof ~attempt_ordinal proofs with
    | Some (original_schema,original) ->
      let* expected=Lane_addon_action.canonical json in
      let* actual=Lane_addon_action.canonical (proof_to_json ~store ~declaration_id bound
        ~schema:original_schema ~attempt_ordinal original) in
      if Yojson.Safe.equal expected actual then Ok proofs else Error "conflicting original execution proof"
    | None ->
      if List.exists (fun (ordinal,_,_) -> ordinal>attempt_ordinal) proofs
      then Error "original execution proof cannot insert an earlier completed attempt"
      else Ok (proofs @ [attempt_ordinal,schema,execution]) in
  let json=proofs_to_json ~store ~declaration_id bound updated in
  let* expected=Lane_addon_action.canonical json in
  let instance_id,request_id=proof_key ~declaration_id bound in
  let* ()=Lane_addon_store.save_host_result store ~instance_id ~request_id json in
  let* confirmed=load_proofs ~store ~declaration_id bound in
  let* confirmed=Lane_addon_action.canonical (proofs_to_json ~store ~declaration_id bound confirmed) in
  if Yojson.Safe.equal expected confirmed then Ok ()
  else Error "original execution proof changed before durable confirmation"

type original_execution = No_completed_original | Completed_original of execution_result
let read_original_execution ~store ~declaration_id ~schema ~attempt_ordinal request =
  if attempt_ordinal <= 0 then Error "original execution attempt ordinal must be positive"
  else
    let* schema=original_schema ~declaration_id ~schema request in
    let bound=Digested.make request in
    let* wire=Lane_addon_store.load_exact_request store ~declaration_id ~request_id:request.request_id in
    match wire with
    | None ->
      let* proofs=load_proofs ~store ~declaration_id bound in
      if proofs=[] then Ok No_completed_original
      else Error "original execution proof has no original Exact request"
    | Some wire ->
      let* record=bound_record ~declaration_id bound wire in
      let* _=validate_record ~request ~schema:None record in
      let* proofs=bound_proofs ~store ~declaration_id bound record in
      (match selected_proof ~attempt_ordinal proofs with
       | None -> Ok No_completed_original
       | Some (retained_schema,execution) ->
         if Yojson.Safe.equal schema retained_schema then Ok (Completed_original execution)
         else Error "original execution proof differs from the supplied original schema")

type latest_original_execution =
  | No_completed_latest
  | Completed_latest of { attempt_ordinal : int; execution : execution_result }

(* The latest completed attempt the original's record and proof link show,
   with the schema [original_schema] checked. [proof] reads the link. It is
   called after the record checks, which is when a store read reads it. *)
let latest_bound ~store ~declaration_id ~schema bound ~record ~proof =
  let request = Digested.request bound in
  let proofs () =
    let* wire=proof () in
    decode_proofs ~store ~declaration_id bound wire in
  match record with
  | None ->
    let* proofs=proofs () in
    if proofs=[] then Ok No_completed_latest
    else Error "original execution proof has no original Exact request"
  | Some wire ->
    let* record=bound_record ~declaration_id bound wire in
    let* _=validate_record ~request ~schema:None record in
    let* proofs=proofs () in
    let* ()=bind_proofs record proofs in
    let rec last_execution_ordinal ordinal = function
      | Delivery_refused _ :: earlier -> last_execution_ordinal (ordinal - 1) earlier
      | [] | (Started _ | Deferred _ | Completed_call _ | Unknown_interrupted
          | Unknown_cut | Unknown_raised _ | Reused) :: _ -> ordinal in
    let length=List.length record.attempts in
    let attempt_ordinal = match record.final with
      | Some (Call_final _ | Outcome_unknown | Request_id_reused) ->
          last_execution_ordinal length (List.rev record.attempts)
      | None | Some (Not_allowed _) -> length in
    match selected_proof ~attempt_ordinal proofs with
    | None -> Ok No_completed_latest
    | Some (retained_schema,execution) ->
      if Yojson.Safe.equal schema retained_schema then Ok (Completed_latest {attempt_ordinal;execution})
      else Error "original execution proof differs from the supplied original schema"

let read_latest_bound ~store ~declaration_id ~schema bound =
  let request = Digested.request bound in
  let* schema=original_schema ~declaration_id ~schema request in
  let* record=Lane_addon_store.load_exact_request store ~declaration_id ~request_id:request.request_id in
  latest_bound ~store ~declaration_id ~schema bound ~record
    ~proof:(fun () -> load_proof_wire ~store ~declaration_id bound)

let read_latest_original_execution ~store ~declaration_id ~schema request =
  read_latest_bound ~store ~declaration_id ~schema (Digested.make request)

let latest_of_files ~store ~declaration_id ~schema request ~record ~proof =
  let* schema=original_schema ~declaration_id ~schema request in
  latest_bound ~store ~declaration_id ~schema (Digested.make request) ~record
    ~proof:(fun () -> Ok proof)

let read_latest_slot_observations ~store ~declaration_id ~schema request =
  let bound = Digested.make request in
  let* latest=read_latest_bound ~store ~declaration_id ~schema bound in
  match latest with
  | No_completed_latest -> Ok None
  | Completed_latest {attempt_ordinal;execution} ->
    let proof=proof_to_json ~store ~declaration_id bound ~schema
      ~attempt_ordinal execution in
    Lane_addon_exact_observation.read ~store ~declaration_id ~request_id:request.request_id
      ~attempt_ordinal ~proof

(* Requests this process is running, by store root, declaration and request.
   Only the base-path lease holder runs requests (see the interface), so a
   started attempt that is not here was cut off by a crash or a cancellation. *)
let in_flight : (string * string * string, unit) Hashtbl.t = Hashtbl.create 16
let in_flight_lock = Mutex.create ()

let claim key =
  Mutex.protect in_flight_lock (fun () ->
    if Hashtbl.mem in_flight key then false else (Hashtbl.replace in_flight key (); true))

let release key = Mutex.protect in_flight_lock (fun () -> Hashtbl.remove in_flight key)

let finish_record prior = function
  | Call_ended final ->
      {prior with attempts=prior.attempts @ [Completed_call final];
        final=Some (Call_final final)}
  | Call_refused refusal ->
      {prior with attempts=prior.attempts @ [Deferred (Provider_refused refusal)]}

type recovery =
  | Recovered of retained_observation
  | Finish_from_proof of record

(* What recovery does with the original's record and proof link, with the
   schema [original_schema] checked. [proof] reads the link after the record
   checks, and [invalid_error] names a record or link that can never become a
   trustworthy original. An open record whose latest started attempt has a
   completed proof is finished from that proof. *)
let recovery ~store ~declaration_id ~schema ~invalid_error bound ~record ~proof =
  let request = Digested.request bound in
  let invalid result = Result.map_error invalid_error result in
  let proofs () =
    let* wire = proof () in
    invalid (decode_proofs ~store ~declaration_id bound wire) in
  match record with
  | None ->
      let* proofs = proofs () in
      if proofs = [] then Ok (Recovered Retained_absent)
      else invalid (Error "original execution proof has no original Exact request")
  | Some wire ->
      let* record = invalid (bound_record ~declaration_id bound wire) in
      let* observed = invalid (validate_record ~request ~schema:(Some schema) record) in
      let* proofs = proofs () in
      let* () = invalid (bind_proofs record proofs) in
      match record.final, List.rev record.attempts with
      | None, Started _ :: earlier ->
          (match selected_proof ~attempt_ordinal:(List.length record.attempts) proofs with
           | None -> Ok (Recovered observed)
           | Some (retained_schema, execution) ->
               if not (Yojson.Safe.equal schema retained_schema) then
                 invalid (Error "original execution proof differs from the supplied original schema")
               else
                 (match execution.outcome with
                  | Call_refused _ -> Ok (Recovered observed)
                  | Call_ended _ ->
                      Ok (Finish_from_proof
                            (finish_record {record with attempts=List.rev earlier} execution.outcome))))
      | None, ([] | (Deferred _ | Completed_call _ | Unknown_interrupted | Unknown_cut
          | Unknown_raised _ | Delivery_refused _ | Reused) :: _)
      | Some (Call_final _ | Outcome_unknown | Not_allowed _ | Request_id_reused), _ ->
          Ok (Recovered observed)

let recover_retained ~store ~declaration_id ~schema request =
  (* Same split as [observe_retained]: the schema is the caller's own, so a
     mismatch is permanent. *)
  let* schema = invalid (original_schema ~declaration_id ~schema request) in
  let bound = Digested.make request in
  let key = Lane_addon_store.root store, declaration_id, request.request_id in
  (* [observe_retained] already reports [recovery_error], so a concurrent claim
     is forwarded unchanged instead of being folded into one class. *)
  if not (claim key) then observe_retained_classified ~store ~declaration_id ~schema bound
  else Fun.protect ~finally:(fun () -> release key) (fun () ->
    let* record = unreadable (Lane_addon_store.load_exact_request store ~declaration_id
      ~request_id:request.request_id) in
    (* The proof link is read from disk and then decoded. A read that fails may
       succeed later; a link that decodes to something else never will. *)
    let* recovered = recovery ~store ~declaration_id ~schema
        ~invalid_error:(fun detail -> Recovery_invalid detail) bound ~record
        ~proof:(fun () -> unreadable (load_proof_wire ~store ~declaration_id bound)) in
    match recovered with
    | Recovered observed -> Ok observed
    | Finish_from_proof finished ->
        let* () = unreadable (Lane_addon_store.save_exact_request store ~declaration_id
          ~request_id:request.request_id
          (record_to_json ~declaration_id ~request_id:request.request_id finished)) in
        observe_retained_classified ~store ~declaration_id ~schema bound)

let recovery_of_files ~store ~declaration_id ~schema request ~record ~proof =
  let* schema = original_schema ~declaration_id ~schema request in
  let bound = Digested.make request in
  let* recovered = recovery ~store ~declaration_id ~schema ~invalid_error:Fun.id bound ~record
      ~proof:(fun () -> Ok proof) in
  match recovered with
  | Recovered observed -> Ok observed
  | Finish_from_proof finished ->
      observation ~declaration_id ~schema bound
        (Some (record_to_json ~declaration_id ~request_id:request.request_id finished))

(* Created once before the first started marker, shared by all roots and
   domains in this process. The lock guards only this short initialization;
   no Eio operation or caller-supplied function runs under it. *)
let incarnation_lock = Mutex.create ()
let process_incarnation = ref None
let incarnation () = Mutex.protect incarnation_lock (fun () ->
  match !process_incarnation with
  | Some incarnation -> incarnation
  | None ->
      let incarnation = Random_id.hex ~bytes:16 in
      process_incarnation := Some incarnation;
      incarnation)

type output_validator = Yojson.Safe.t -> (unit, string) result
type execution_scope = (unit -> (attempt, string) result) -> (attempt, string) result
type request_authorization = {
  admission_class : Agent_core.Llm_provider.Admission_class.t;
  validate_output : output_validator;
  before_dispatch : dispatch_guard;
  with_execution : execution_scope;
}
type authority_refusal =
  | Unowned of { reason : string }
  | Undecided of { detail : string }
type execution_authority =
  store:Lane_addon_store.t -> declaration_id:string -> package:Lane_addon_types.package ->
  request -> (request_authorization, authority_refusal) result

let run ~store ~declaration_id ~(package : Lane_addon_types.package) ~runner ~authorize_request request =
  let request_id = request.request_id in
  let key = Lane_addon_store.root store, declaration_id, request_id in
  (* Identity precedes permission: even a refused request owns its id. *)
  if not (claim key) then Ok (Not_final Attempt_in_progress)
  else Fun.protect ~finally:(fun () -> release key) (fun () ->
    let bound = Digested.make request in
    let save record =
      Systhread_host.run ~label:"addon-exact-request-save" (fun () ->
        Lane_addon_store.save_exact_request store ~declaration_id ~request_id
          (record_to_json ~declaration_id ~request_id record)) in
    let* retained = Systhread_host.run ~label:"addon-exact-request-load" (fun () ->
      Lane_addon_store.load_exact_request store ~declaration_id ~request_id) in
    let* retained = match retained with
      | None -> Ok None
      | Some json ->
        let* stored = record_of_json json in
        let* original = request_of_json stored.request in
        let* () = if String.equal original.request_id request_id then Ok ()
          else Error "retained Exact record has a different original request ID" in
        let* stored = bound_record ~declaration_id (Digested.make original) json in
        let* _ = validate_record ~request:original ~schema:None stored in
        Ok (Some stored) in
    match retained with
    | Some record when not (String.equal record.digest (Digested.digest bound)) -> Ok (Final Request_id_reused)
    | None | Some _ ->
      let previous = match retained with
        | Some record -> record
        | None -> {digest = Digested.digest bound; request = request_to_json (Digested.request bound);
            attempts = []; final = None} in
      let* proofs=Systhread_host.run ~label:"addon-exact-proofs-load" (fun () ->
        bound_proofs ~store ~declaration_id bound previous) in
      let finish = finish_record in
      let* previous, recovered = match previous.final with
        | None ->
            (match List.rev previous.attempts with
             | Started started_by :: earlier ->
               let attempt_ordinal=List.length previous.attempts in
               (match selected_proof ~attempt_ordinal proofs with
                | None ->
                  let cause = if String.equal started_by (incarnation ())
                    then Unknown_cut else Unknown_interrupted in
                  let unknown={previous with attempts=List.rev earlier @ [cause]; final=Some Outcome_unknown} in
                  let* ()=save unknown in Ok (unknown,None)
                | Some (_original_schema, execution) ->
                  Eio.Cancel.protect (fun () ->
                    let finished=finish {previous with attempts=List.rev earlier} execution.outcome in
                    let* ()=save finished in
                    Ok (finished,Some (attempt_of_outcome execution.outcome))))
             | [] | (Deferred _ | Completed_call _ | Unknown_interrupted | Unknown_cut | Unknown_raised _
                 | Delivery_refused _ | Reused) :: _ -> Ok (previous,None))
        | Some (Call_final _ | Outcome_unknown | Not_allowed _ | Request_id_reused) -> Ok (previous,None) in
      let deny reason =
        let refusal = Not_allowed {reason} in
        let record = match previous.final with
          | None -> {previous with final = Some refusal}
          | Some (Not_allowed _) -> previous
          | Some (Call_final _ | Outcome_unknown | Request_id_reused) ->
              (* A selection change cannot erase the original provider result. *)
              {previous with attempts = previous.attempts @ [Delivery_refused {reason}]} in
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
        match authorize_request ~store ~declaration_id ~package request with
        | Error (Unowned {reason}) -> deny reason
        | Error (Undecided {detail}) -> Error detail
        | Ok authorization ->
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
        | None, None -> authorization.with_execution (fun () ->
          Eio.Fiber.check ();
          let* ()=authorization.before_dispatch () in
          (* The started marker says a generation request may have reached a
             provider, or that a call which sent none is publishing its
             proof. It is written when the call reaches its first generation
             dispatch: after any provider admission wait, before the request
             is sent. A call cut off while it waited leaves no marker, so the
             next run tries the request again. *)
          let started = ref false and marker_failure = ref None in
          let mark_started () =
            if !started then Ok ()
            else
              match save {previous with attempts = previous.attempts @ [Started (incarnation ())]} with
              | Ok () -> started := true; marker_failure := None; Ok ()
              | Error detail -> marker_failure := Some detail; Error detail in
          let before_dispatch = function
            | Measurement -> authorization.before_dispatch ()
            | Generation ->
              let* () = mark_started () in
              (* The save yields. A retiring incarnation must not send after
                 it returns. A cancelled started attempt remains unknown. *)
              Eio.Fiber.check ();
              authorization.before_dispatch () in
          match runner ~before_dispatch ~admission_class:authorization.admission_class ~lane_key ~schema
                  ~size_refused:(size_refused_slots ~schema proofs) request with
          | Error unavailable ->
            let reason = Lane_unavailable unavailable in
            let* () = save {previous with attempts = previous.attempts @ [Deferred reason]} in
            Ok (Not_final reason)
          | Ok call ->
            (* The request is retained before the first provider call. *)
            let* () = match retained with
              | Some _ -> Ok ()
              | None -> save previous in
            (* The save yields. A retiring incarnation must not enter a call
               after it returns. *)
            Eio.Fiber.check ();
            let slot_capture=Exact_lane_slot_capture.create ~owner:(Runtime_schema.Addon lane) () in
            let called =
              match Exact_lane_slot_capture.with_capture slot_capture (fun () -> call ~validate) with
              | execution ->
                  let recorded = match execution.outcome with
                    | Call_ended final -> Completed_call final
                    | Call_refused refusal -> Deferred (Provider_refused refusal) in
                  Ok (attempt_of_outcome execution.outcome, recorded, Some execution)
              | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
              | exception exn ->
                  let raised = Printexc.to_string exn in
                  (* The marker is what says a generation request may have
                     reached a provider. A call that raised before this run
                     saved it sent none, so there is no outcome to be unsure
                     of: the run fails and writes no attempt, and the next
                     run reads the record as it was. *)
                  if !started then Ok (Final Outcome_unknown, Unknown_raised raised, None)
                  else Error ("the Exact call raised before its first generation dispatch: " ^ raised) in
            match !marker_failure with
            | Some detail ->
              (* The marker save reported a failure, so the guard stopped the
                 call before its dispatch. That is the host's own write
                 failure, not an outcome of the call. *)
              Error detail
            | None ->
            let* attempt, recorded, execution = called in
            Eio.Cancel.protect (fun () ->
              let* () = match execution with
                | None -> Ok ()
                | Some execution ->
                  (* A proof is read against its started attempt, so a call
                     that ended without a generation dispatch writes the
                     marker before its proof. *)
                  let* () = mark_started () in
                  Systhread_host.run ~label:"addon-exact-proof-retain" (fun () ->
                    retain_proof ~store ~declaration_id bound ~schema
                      ~attempt_ordinal:(List.length previous.attempts + 1) execution) in
              (* Optional observations have their own proof-bound link. A
                 failed diagnostic write cannot undo accepted original work. *)
              (match execution,Exact_lane_slot_capture.observations slot_capture with
               | Some execution,Some observations ->
                 let attempt_ordinal=List.length previous.attempts+1 in
                 let proof=proof_to_json ~store ~declaration_id bound ~schema ~attempt_ordinal execution in
                 (match Systhread_host.run ~label:"addon-exact-observation-retain" (fun () ->
                    Lane_addon_exact_observation.retain ~store ~declaration_id
                      ~request_id:request.request_id ~attempt_ordinal ~proof observations) with
                  | Ok () -> ()
                  | Error detail -> Log.Misc.warn "Exact slot observations were not retained: %s" detail)
               | None,_ | Some _,None -> ());
              let finished = match attempt with
                | Final final ->
                    {previous with attempts = previous.attempts @ [recorded]; final = Some final}
                | Not_final _ ->
                    {previous with attempts = previous.attempts @ [recorded]} in
              let* () = save finished in
              Ok attempt)))
