type t =
  { request_id : string
  ; participant_name : string option
  ; question : string
  ; schema : Yojson.Safe.t option
  ; timeout_s : float option
  ; created_at : float
  }

type pending = { run_id : string; request : t }
type settlement_error = No_pending_request | Request_not_current

let settle ~current supplied =
  match current with
  | None -> Error No_pending_request
  | Some owned ->
    if String.equal owned.run_id supplied.run_id
       && String.equal owned.request.request_id supplied.request.request_id
    then Ok owned
    else Error Request_not_current

let pending_to_json pending =
  let request = pending.request in
  `Assoc
    [ "run_id", `String pending.run_id
    ; "request", `Assoc
        [ "request_id", `String request.request_id
        ; "participant_name", (match request.participant_name with None -> `Null | Some x -> `String x)
        ; "question", `String request.question
        ; "schema", (match request.schema with None -> `Null | Some x -> x)
        ; "timeout_s", (match request.timeout_s with None -> `Null | Some x -> `Float x)
        ; "created_at", `Float request.created_at
        ]
    ]

let ( let* ) = Result.bind
let object_fields expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare expected ->
    Ok fields
  | _ -> Error "input wait must contain exactly its canonical fields"
let string = function `String x -> Ok x | _ -> Error "input wait string required"
let identifier json =
  let* x = string json in
  if String.equal x "" then Error "input wait identity must be nonempty" else Ok x
let number = function
  | `Int x -> Ok (float_of_int x)
  | `Float x when Float.is_finite x -> Ok x
  | _ -> Error "input wait finite number required"
let optional read = function `Null -> Ok None | x -> Result.map Option.some (read x)

let pending_of_json json =
  let* fields = object_fields ["run_id";"request"] json in
  let* run_id = identifier (List.assoc "run_id" fields) in
  let* fields = object_fields
    ["request_id";"participant_name";"question";"schema";"timeout_s";"created_at"]
    (List.assoc "request" fields) in
  let* request_id = identifier (List.assoc "request_id" fields) in
  let* participant_name = optional string (List.assoc "participant_name" fields) in
  let* question = string (List.assoc "question" fields) in
  let* schema = optional (fun x -> Ok x) (List.assoc "schema" fields) in
  let* timeout_s = optional number (List.assoc "timeout_s" fields) in
  let* created_at = number (List.assoc "created_at" fields) in
  Ok {run_id;request={request_id;participant_name;question;schema;timeout_s;created_at}}
