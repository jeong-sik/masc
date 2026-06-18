type policy_verdict =
  | Approved
  | Pending of string
  | Denied of string
[@@deriving yojson, show, eq]

type t = {
  job_id : string;
  batch_id : string;
  turn_id : string option;
  goal_id : string option;
  keeper_id : string option;
  tool_name : string;
  tool_version : string option;
  schema_hash : string;
  input_json : Yojson.Safe.t;
  read_only : bool;
  resource_keys : string list;
  idempotency_key : string option;
  deadline_ms : int option;
  approval : policy_verdict;
  attempt : int;
}
[@@deriving yojson, show]

let fresh_id () =
  Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string

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
  (Tool_catalog.metadata name).readonly |> Option.value ~default:false

let default_resource_keys_of_tool ~tool_name ~input_json =
  let get = Tool_args.get_string_opt input_json in
  let keys = ref [] in
  let add prefix key_name =
    match get key_name with
    | Some value -> keys := (prefix ^ value) :: !keys
    | None -> ()
  in
  (if String.starts_with ~prefix:"masc_goal_" tool_name then add "goal:" "goal_id");
  (if String.starts_with ~prefix:"masc_task_" tool_name then add "task:" "task_id");
  (if String.starts_with ~prefix:"masc_board_" tool_name then add "board:thread:" "thread_id");
  (if String.starts_with ~prefix:"masc_workspace_" tool_name then add "workspace:" "workspace_path");
  (if tool_name = "tool_read_file"
      || tool_name = "tool_edit_file"
      || tool_name = "tool_write_file"
   then add "file:" "path");
  (if tool_name = "tool_search_files" then add "repo:" "path");
  List.rev !keys

let make
    ?(job_id = fresh_id ())
    ?turn_id
    ?goal_id
    ?keeper_id
    ?tool_version
    ?idempotency_key
    ?deadline_ms
    ?(approval = Approved)
    ?(attempt = 1)
    ?resource_keys
    ~batch_id
    ~tool_name
    ~input_json
    () =
  let schema =
    match Tool_dispatch.lookup_schema tool_name with
    | Some s -> s
    | None ->
      `Assoc
        [ "type", `String "object"
        ; "properties", `Assoc []
        ; "required", `List []
        ]
  in
  let resource_keys =
    match resource_keys with
    | Some keys -> keys
    | None -> default_resource_keys_of_tool ~tool_name ~input_json
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
  ; read_only = read_only_of_tool_name tool_name
  ; resource_keys
  ; idempotency_key
  ; deadline_ms
  ; approval
  ; attempt
  }

let with_approval t approval = { t with approval }
let with_attempt t attempt = { t with attempt }
