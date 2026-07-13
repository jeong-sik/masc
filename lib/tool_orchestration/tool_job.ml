type t = {
  job_id : string;
  batch_id : string;
  turn_id : string option [@default None];
  goal_id : string option [@default None];
  keeper_id : string option [@default None];
  tool_name : string;
  tool_version : string option [@default None];
  schema_hash : string;
  input_json : Yojson.Safe.t;
  read_only : bool;
  resource_keys : string list;
  idempotency_key : string option [@default None];
  deadline_ms : int option [@default None];
  attempt : int;
}
[@@deriving yojson, show]

(* NDT-OK: UUID entropy is a replay handle only; tests pass explicit [job_id]. *)
let uuid_rng = Random.State.make_self_init ()

let fresh_id () =
  Uuidm.v4_gen uuid_rng () |> Uuidm.to_string

let rec normalize_input_for_hash = function
  | `Assoc kvs ->
    let kvs =
      List.sort (fun (a, _) (b, _) -> String.compare a b) kvs
      |> List.map (fun (k, v) -> (k, normalize_input_for_hash v))
    in
    `Assoc kvs
  | `List xs -> `List (List.map normalize_input_for_hash xs)
  | other -> other

let schema_hash_of_yojson schema =
  normalize_input_for_hash schema
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex

let read_only_of_tool_name name =
  (* DET-OK: sound-partial allow — unknown tools default to writer semantics, which
     makes the scheduler use the conservative [write:any] resource key below. *)
  let metadata = Tool_catalog.metadata name in
  match metadata.readonly with
  | Some true -> true
  | Some false | None -> false

let default_resource_keys_of_tool ~read_only ~tool_name:_ ~input_json:_ =
  if read_only then [] else [ "write:any" ]

let fallback_schema_for_tool tool_name =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc []
    ; "required", `List []
    ; "x-masc-unregistered-tool", `String tool_name
    ]

let make
    ?(job_id = fresh_id ())
    ?turn_id
    ?goal_id
    ?keeper_id
    ?tool_version
    ?idempotency_key
    ?deadline_ms
    ?(attempt = 1)
    ?resource_keys
    ~batch_id
    ~tool_name
    ~input_json
    () =
  let schema =
    match Tool_dispatch.lookup_schema tool_name with
    | Some s -> s
    | None -> fallback_schema_for_tool tool_name
  in
  let read_only = read_only_of_tool_name tool_name in
  let resource_keys =
    match resource_keys with
    | Some keys -> keys
    | None -> default_resource_keys_of_tool ~read_only ~tool_name ~input_json
  in
  { job_id
  ; batch_id
  ; turn_id
  ; goal_id
  ; keeper_id
  ; tool_name
  ; tool_version
  ; schema_hash = schema_hash_of_yojson schema
  ; input_json
  ; read_only
  ; resource_keys
  ; idempotency_key
  ; deadline_ms
  ; attempt
  }

let with_attempt t attempt = { t with attempt }
