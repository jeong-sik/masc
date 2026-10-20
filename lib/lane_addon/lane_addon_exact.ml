let ( let* ) = Result.bind

type request =
  { request_id : string
  ; output : string
  ; system : string option
  ; messages : string list
  }

let request_keys = [ "kind"; "request_id"; "output"; "system"; "messages" ]

let request_of_json = function
  | `Assoc fields ->
    let text key =
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | Some _ | None -> Error (key ^ " requires a non-blank string")
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
             match value with
             | `String message -> Ok (message :: acc)
             | _ -> Error "messages holds user message strings")
          values (Ok [])
      | Some _ | None -> Error "messages requires at least one user message"
    in
    Ok { request_id; output; system; messages }
  | _ -> Error "an exact_output request must be an object"

let request_to_json request =
  `Assoc
    ([ "kind", `String "exact_output"
     ; "request_id", `String request.request_id
     ; "output", `String request.output
     ]
     @ (match request.system with None -> [] | Some system -> [ "system", `String system ])
     @ [ "messages", `List (List.map (fun message -> `String message) request.messages) ])

let digest request = Lane_addon_store.digest (Yojson.Safe.to_string (request_to_json request))

type input_refusal =
  | Input_capacity
  | Context_overflow
  | Invalid_request
  | Request_body_refused

type usage = { input_tokens : int; output_tokens : int }

type final =
  | Answered of { output : Yojson.Safe.t; slot : string; usage : usage option }
  | Invalid_output of { detail : string }
  | Input_refused of input_refusal
  | Outcome_unknown
  | Not_allowed of { reason : string }
  | Request_id_reused

type not_final =
  | Lane_unconfigured
  | Lane_off
  | No_admitted_slots
  | Provider_unavailable of { detail : string }
  | Provider_auth_refused of { detail : string }
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
  | Answered { output; slot; usage } ->
    `Assoc
      ([ "status", `String "answered"; "output", output; "slot", `String slot ]
       @ match usage with None -> [] | Some usage -> [ "usage", usage_to_json usage ])
  | Invalid_output { detail } -> `Assoc [ "status", `String "invalid_output"; "detail", `String detail ]
  | Input_refused kind ->
    `Assoc [ "status", `String "input_refused"; "kind", `String (input_refusal_to_string kind) ]
  | Outcome_unknown -> `Assoc [ "status", `String "outcome_unknown" ]
  | Not_allowed { reason } -> `Assoc [ "status", `String "not_allowed"; "reason", `String reason ]
  | Request_id_reused -> `Assoc [ "status", `String "request_id_reused" ]

(* The retained record reads back only what this module wrote; anything else is
   an unreadable record, not a guess. *)
let final_of_json json =
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
    Ok (Answered { output; slot; usage })
  | "invalid_output" -> let* detail = text "detail" in Ok (Invalid_output { detail })
  | "input_refused" ->
    let* kind = text "kind" in
    Option.to_result ~none:"final kind" (input_refusal_of_string kind)
    |> Result.map (fun kind -> Input_refused kind)
  | "outcome_unknown" -> Ok Outcome_unknown
  | "not_allowed" -> let* reason = text "reason" in Ok (Not_allowed { reason })
  | "request_id_reused" -> Ok Request_id_reused
  | other -> Error ("final status " ^ other)

let not_final_to_json = function
  | Lane_unconfigured -> `Assoc [ "reason", `String "lane_unconfigured" ]
  | Lane_off -> `Assoc [ "reason", `String "lane_off" ]
  | No_admitted_slots -> `Assoc [ "reason", `String "no_admitted_slots" ]
  | Provider_unavailable { detail } ->
    `Assoc [ "reason", `String "provider_unavailable"; "detail", `String detail ]
  | Provider_auth_refused { detail } ->
    `Assoc [ "reason", `String "provider_auth_refused"; "detail", `String detail ]
  | Attempt_in_progress -> `Assoc [ "reason", `String "attempt_in_progress" ]

type runner = lane_key:string -> schema:Yojson.Safe.t -> request -> attempt

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
      | Some final -> final_of_json final |> Result.map Option.some
      | None -> Error "record final"
    in
    Ok { digest; request; attempts; final }
  | _ -> Error "record must be an object"

(* Requests a runner is working on in this process. A started attempt that is
   not here was cut off by a crash or a cancellation. *)
let in_flight : (string * string, unit) Hashtbl.t = Hashtbl.create 16
let in_flight_lock = Mutex.create ()

let claim key =
  Mutex.protect in_flight_lock (fun () ->
    if Hashtbl.mem in_flight key then false else (Hashtbl.replace in_flight key (); true))

let release key = Mutex.protect in_flight_lock (fun () -> Hashtbl.remove in_flight key)

let run ~store ~declaration_id ~(package : Lane_addon_types.package) ~runner request =
  match
    List.find_opt
      (fun (declared : Lane_addon_types.exact_output) -> String.equal declared.name request.output)
      package.exact_outputs
  with
  | None ->
    Ok (Final (Not_allowed { reason = "the package manifest declares no exact output " ^ request.output }))
  | Some declared ->
    let request_id = request.request_id in
    let digest = digest request in
    let key = declaration_id, request_id in
    let save record =
      Eio_unix.run_in_systhread (fun () ->
        Lane_addon_store.save_exact_request store ~declaration_id ~request_id
          (record_to_json ~declaration_id ~request_id record))
    in
    let* retained =
      Eio_unix.run_in_systhread (fun () ->
        Lane_addon_store.load_exact_request store ~declaration_id ~request_id)
    in
    let* retained =
      match retained with
      | None -> Ok None
      | Some json -> record_of_json json |> Result.map Option.some
    in
    let started record = List.exists Option.is_none record.attempts in
    match retained with
    | Some record when not (String.equal record.digest digest) -> Ok (Final Request_id_reused)
    | Some { final = Some final; _ } -> Ok (Final final)
    | Some record when started record ->
      if claim key
      then
        Fun.protect ~finally:(fun () -> release key) (fun () ->
          let* () = save { record with final = Some Outcome_unknown } in
          Ok (Final Outcome_unknown))
      else Ok (Not_final Attempt_in_progress)
    | None | Some _ ->
      if not (claim key)
      then Ok (Not_final Attempt_in_progress)
      else
        Fun.protect ~finally:(fun () -> release key) (fun () ->
          let previous =
            match retained with
            | Some record -> record
            | None -> { digest; request = request_to_json request; attempts = []; final = None }
          in
          let* lane = Runtime_schema.addon_lane ~declaration_id ~output:request.output in
          let lane_key = Runtime_schema.exact_lane_key (Runtime_schema.Addon lane) in
          let started = { previous with attempts = previous.attempts @ [ None ] } in
          let* () = save started in
          (* An exception may come after the request left, so it ends the request
             as Outcome_unknown; its text stays in the attempt as evidence. *)
          let attempt, raised =
            match runner ~lane_key ~schema:declared.schema request with
            | attempt -> attempt, None
            | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
            | exception exn -> Final Outcome_unknown, Some (Printexc.to_string exn)
          in
          let with_raised = function
            | `Assoc fields ->
              `Assoc (fields @ match raised with None -> [] | Some text -> [ "exception", `String text ])
            | json -> json
          in
          (* No yielding operation may separate the attempt from its record. *)
          Eio.Cancel.protect (fun () ->
            let finished =
              match attempt with
              | Final final ->
                { started with
                  attempts = previous.attempts @ [ Some (with_raised (final_to_json final)) ]
                ; final = Some final
                }
              | Not_final reason ->
                { started with attempts = previous.attempts @ [ Some (not_final_to_json reason) ] }
            in
            let* () = save finished in
            Ok attempt))
