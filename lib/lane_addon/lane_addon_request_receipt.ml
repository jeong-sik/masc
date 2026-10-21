let ( let* ) = Result.bind
type receipt = { observed_at:float; payload:Yojson.Safe.t; digest:string }
let fields names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) =
      List.sort String.compare names -> Ok fields
  | _ -> Error "invalid original observer receipt fields"
let content observed_at payload = `Assoc ["observed_at",`Float observed_at;"payload",payload]
let make ~observed_at ~payload =
  let* () = if Float.is_finite observed_at && observed_at >= 0. then Ok ()
    else Error "observer time must be finite and nonnegative" in
  let* payload = Lane_addon_action.canonical payload in
  let* () = match payload with `Assoc _ -> Ok ()
    | _ -> Error "observer payload must be an object" in
  let* encoded = Lane_addon_action.canonical (content observed_at payload) in
  let digest = Lane_addon_store.digest (Yojson.Safe.to_string encoded) in
  Ok {observed_at;payload;digest}
let to_json receipt = `Assoc ["observed_at",`Float receipt.observed_at;
  "payload",receipt.payload;"digest",`String receipt.digest]
let of_json json =
  let* json = Lane_addon_action.canonical json in
  let* fields = fields ["observed_at";"payload";"digest"] json in
  let* observed_at = match List.assoc "observed_at" fields with
    | `Float value -> Ok value | `Int value -> Ok (float_of_int value)
    | `Intlit value -> (try Ok (float_of_string value)
        with Failure _ -> Error "invalid original observer time")
    | _ -> Error "invalid original observer time" in
  let* receipt = make ~observed_at ~payload:(List.assoc "payload" fields) in
  let* expected = Lane_addon_action.canonical (to_json receipt) in
  if Yojson.Safe.equal json expected then Ok receipt
  else Error "original observer receipt digest or time mismatch"
type stage = Registration | Completion
type event = Intended of stage * receipt | Recorded of stage * string
type publication = Unobserved | Pending of receipt | Acknowledged of receipt
type t = { registration:publication; completion:publication }
let empty = {registration=Unobserved;completion=Unobserved}
let stage_name = function Registration -> "registration" | Completion -> "completion"
let event_to_json = function
  | Intended (stage,receipt) -> `Assoc ["event",`String ("observer_" ^ stage_name stage ^ "_intended");
      "receipt",to_json receipt]
  | Recorded (stage,digest) -> `Assoc ["event",`String ("observer_" ^ stage_name stage ^ "_recorded");
      "digest",`String digest]
let event_of_json json =
  let* json = Lane_addon_action.canonical json in
  let* kind = match json with
    | `Assoc fields -> (match List.assoc_opt "event" fields with
        | Some (`String value) -> Ok value | _ -> Error "missing observer event")
    | _ -> Error "observer event must be an object" in
  let intended stage =
    let* fields = fields ["event";"receipt"] json in
    let* receipt = of_json (List.assoc "receipt" fields) in Ok (Intended (stage,receipt)) in
  let recorded stage =
    let* fields = fields ["event";"digest"] json in
    match List.assoc "digest" fields with
    | `String digest when String.trim digest<>"" -> Ok (Recorded (stage,digest))
    | _ -> Error "observer acknowledgement requires its original digest" in
  match kind with
  | "observer_registration_intended" -> intended Registration
  | "observer_completion_intended" -> intended Completion
  | "observer_registration_recorded" -> recorded Registration
  | "observer_completion_recorded" -> recorded Completion
  | _ -> Error "unknown observer event"
let append state event =
  let* event = event_of_json (event_to_json event) in
  match event with
  | Intended (Registration,receipt) -> (match state.registration,state.completion with
      | Unobserved,Unobserved -> Ok {state with registration=Pending receipt}
      | (Pending _ | Acknowledged _),(Unobserved | Pending _ | Acknowledged _)
      | Unobserved,(Pending _ | Acknowledged _) -> Error "observer registration intent already exists")
  | Intended (Completion,receipt) -> (match state.registration,state.completion with
      | (Pending _ | Acknowledged _),Unobserved -> Ok {state with completion=Pending receipt}
      | Unobserved,(Unobserved | Pending _ | Acknowledged _)
      | (Pending _ | Acknowledged _),(Pending _ | Acknowledged _) ->
        Error "observer completion requires an original registration and no previous completion")
  | Recorded (Registration,digest) -> (match state.registration with
      | Pending receipt when String.equal receipt.digest digest -> Ok {state with registration=Acknowledged receipt}
      | Unobserved | Pending _ | Acknowledged _ -> Error "observer registration acknowledgement differs from pending intent")
  | Recorded (Completion,digest) -> (match state.registration,state.completion with
      | Acknowledged _,Pending receipt when String.equal receipt.digest digest ->
        Ok {state with completion=Acknowledged receipt}
      | (Unobserved | Pending _),(Unobserved | Pending _ | Acknowledged _)
      | Acknowledged _,(Unobserved | Pending _ | Acknowledged _) ->
        Error "observer completion acknowledgement lacks its registered original intent")
