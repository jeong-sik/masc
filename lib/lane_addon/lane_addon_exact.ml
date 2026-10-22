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

let final_of_json ~schema json =
  let* normalized = Lane_addon_action.canonical json in
  let* final = retained_final_of_json normalized in
  let* encoded = Lane_addon_action.canonical (final_to_json final) in
  let* () = if encoded = normalized then Ok () else Error "invalid or unknown final result fields" in
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

type call = validate:(Yojson.Safe.t -> (checked, string) result) -> call_outcome
type runner = lane_key:string -> schema:Yojson.Safe.t -> request -> (call, lane_unavailable) result

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

(* Requests this process is running, by store root, declaration and request.
   Only the base-path lease holder runs requests (see the interface), so a
   started attempt that is not here was cut off by a crash or a cancellation. *)
let in_flight : (string * string * string, unit) Hashtbl.t = Hashtbl.create 16
let in_flight_lock = Mutex.create ()

let claim key =
  Mutex.protect in_flight_lock (fun () ->
    if Hashtbl.mem in_flight key then false else (Hashtbl.replace in_flight key (); true))

let release key = Mutex.protect in_flight_lock (fun () -> Hashtbl.remove in_flight key)

type validation_authority =
  store:Lane_addon_store.t -> declaration_id:string -> package:Lane_addon_types.package ->
  request -> (Yojson.Safe.t -> (unit, string) result, string) result

let run ~store ~declaration_id ~(package : Lane_addon_types.package) ~runner ~validate_request request =
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
      | Some json -> record_of_json json |> Result.map Option.some in
    match retained with
    | Some record when not (String.equal record.digest digest) -> Ok (Final Request_id_reused)
    | None | Some _ ->
      let previous = match retained with
        | Some record -> record
        | None -> {digest; request = request_to_json request; attempts = []; final = None} in
      let* previous = match previous.final with
        | None when List.exists Option.is_none previous.attempts ->
            let unknown = {previous with final = Some Outcome_unknown} in
            let* () = save unknown in Ok unknown
        | None | Some (Call_final _ | Outcome_unknown | Not_allowed _ | Request_id_reused) -> Ok previous in
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
        let* validate_domain = validate_request ~store ~declaration_id ~package request in
        let* lane = Runtime_schema.addon_lane ~declaration_id ~output:request.output in
        let lane_key = Runtime_schema.exact_lane_key (Runtime_schema.Addon lane) in
        let validate answer =
          let* checked = validate_answer ~output:declared request answer in
          let* () = validate_domain (checked_json checked) in
          Ok checked in
        let deliver = function
          | Call_final (Answered {output; slot; usage}) ->
              (match validate (checked_json output) with
               | Ok output -> Call_final (Answered {output; slot; usage})
               | Error detail -> Call_final (Invalid_output
                   {detail = "the retained answer does not match the package, original request or consumer semantics: " ^ detail}))
          | (Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _) | Outcome_unknown | Not_allowed _ | Request_id_reused)
            as final -> final in
        match previous.final with
        | Some final -> Ok (Final (deliver final))
        | None ->
          Eio.Fiber.check ();
          match runner ~lane_key ~schema request with
          | Error unavailable ->
            let reason = Lane_unavailable unavailable in
            let* () = save {previous with attempts = previous.attempts @ [Some (not_final_to_json reason)]} in
            Ok (Not_final reason)
          | Ok call ->
            let* () = save {previous with attempts = previous.attempts @ [None]} in
            (* The save yields. A retiring incarnation must not start a call
               after it returns. A cancelled started attempt remains unknown. *)
            Eio.Fiber.check ();
            let attempt, raised =
              match call ~validate with
              | Call_ended final -> Final (Call_final final), None
              | Call_refused refusal -> Not_final (Provider_refused refusal), None
              | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
              | exception exn -> Final Outcome_unknown, Some (Printexc.to_string exn) in
            let with_raised = function
              | `Assoc fields -> `Assoc (fields @ match raised with None -> [] | Some text -> ["exception", `String text])
              | json -> json in
            Eio.Cancel.protect (fun () ->
              let finished = match attempt with
                | Final final ->
                    {previous with attempts = previous.attempts @ [Some (with_raised (final_to_json final))]; final = Some final}
                | Not_final reason ->
                    {previous with attempts = previous.attempts @ [Some (not_final_to_json reason)]} in
              let* () = save finished in
              Ok attempt))
