(** Durable review surface for keeper delegation requests. *)

type stored_request =
  { request : Keeper_delegation_request.t
  ; dir : string
  ; json_path : string
  ; task_seed_md_path : string
  ; index_path : string
  }

type request_summary =
  { id : string
  ; requester : string
  ; topic : string
  ; goal : string option
  ; promotion_state : string
  ; dir : string
  ; json_path : string
  ; task_seed_md_path : string
  ; created_at : float option
  }

type request_listing =
  { total : int
  ; shown : int
  ; limit : int
  ; index_path : string
  ; items : request_summary list
  }

let requests_dir ~base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    "delegation-requests"
;;

let index_path ~base_path = Filename.concat (requests_dir ~base_path) "index.jsonl"

let component_hash raw =
  Digestif.SHA256.(digest_string raw |> to_hex) |> fun hex -> String.sub hex 0 16
;;

let component_prefix raw =
  let safe =
    Workspace_utils_backend_setup.sanitize_namespace_segment raw
    |> String.lowercase_ascii
  in
  let safe =
    match safe with
    | "default" when String.equal (String.trim raw) "" -> "untitled"
    | other -> other
  in
  if String.length safe > 48 then String.sub safe 0 48 else safe
;;

let optional_identity_component ~field = function
  | None -> field ^ ":none"
  | Some value -> field ^ ":some:" ^ value
;;

let request_identity_key (request : Keeper_delegation_request.t) =
  String.concat "\n"
    [ request.id
    ; request.requester
    ; request.topic
    ; request.reason
    ; optional_identity_component ~field:"goal" request.goal
    ]
;;

let summary_identity_key (summary : request_summary) = summary.id

let request_component request =
  component_prefix request.Keeper_delegation_request.id
  ^ "-"
  ^ component_hash (request_identity_key request)
;;

let request_dir ~base_path request =
  Filename.concat (requests_dir ~base_path) (request_component request)
;;

let request_json_path ~base_path request =
  Filename.concat (request_dir ~base_path request) "request.json"
;;

let request_task_seed_md_path ~base_path request =
  Filename.concat (request_dir ~base_path request) "TASK_SEED.md"
;;

let write_file path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  match Fs_compat.save_file_atomic path content with
  | Ok () -> Ok ()
  | Error msg -> Error (Printf.sprintf "%s: %s" path msg)
;;

let request_json_content request =
  Yojson.Safe.pretty_to_string (Keeper_delegation_request.to_json request) ^ "\n"
;;

let render_task_seed_md (request : Keeper_delegation_request.t) =
  let goal =
    match request.goal with
    | Some goal -> [ ""; "## Goal"; ""; goal ]
    | None -> []
  in
  let tags =
    match request.task_seed.tags with
    | [] -> []
    | tags -> "" :: "## Tags" :: "" :: List.map (fun tag -> "- `" ^ tag ^ "`") tags
  in
  String.concat "\n"
    ([ "# " ^ request.task_seed.title
     ; ""
     ; "- Requester: `" ^ request.requester ^ "`"
     ; "- State: `"
       ^ Keeper_delegation_request.promotion_state_to_string
           request.promotion_state
       ^ "`"
     ; "- Source action: `" ^ request.source_action ^ "`"
     ; ""
     ; "## Topic"
     ; ""
     ; request.topic
     ; ""
     ; "## Reason"
     ; ""
     ; (if String.trim request.reason = "" then "(no reason supplied)" else request.reason)
     ]
     @ goal
     @ [ ""
       ; "## Promotion Contract"
       ; ""
       ; request.task_seed.description
       ]
     @ tags
     @ [ "" ])
;;

let request_artifacts ~base_path request =
  [ request_json_path ~base_path request, request_json_content request
  ; request_task_seed_md_path ~base_path request, render_task_seed_md request
  ]
;;

let index_event_json request ~dir ~json_path ~task_seed_md_path =
  `Assoc
    [ "schema", `String "masc.keeper_delegation_request.index.v1"
    ; "id", `String request.Keeper_delegation_request.id
    ; "requester", `String request.requester
    ; "topic", `String request.topic
    ; "goal", Json_util.string_opt_to_json request.goal
    ; ( "promotion_state"
      , `String
          (Keeper_delegation_request.promotion_state_to_string
             request.promotion_state) )
    ; "dir", `String dir
    ; "json_path", `String json_path
    ; "task_seed_md_path", `String task_seed_md_path
    ; "ts", `Float (Time_compat.now ())
    ]
;;

let append_index index_path event =
  try
    Keeper_types_support.append_jsonl_line index_path event;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printf.sprintf "%s: %s" index_path (Printexc.to_string exn))
;;

let ( let* ) = Result.bind

let write_request ~base_path request =
  let dir = request_dir ~base_path request in
  let json_path = request_json_path ~base_path request in
  let task_seed_md_path = request_task_seed_md_path ~base_path request in
  let index_path = index_path ~base_path in
  let* () = write_file json_path (request_json_content request) in
  let* () = write_file task_seed_md_path (render_task_seed_md request) in
  let* () =
    append_index index_path
      (index_event_json request ~dir ~json_path ~task_seed_md_path)
  in
  Ok { request; dir; json_path; task_seed_md_path; index_path }
;;

let write_requests ~base_path requests =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | request :: rest ->
      let* stored = write_request ~base_path request in
      loop (stored :: acc) rest
  in
  loop [] requests
;;

let read_file_opt = Fs_compat.load_file_opt

let json_string_opt name json =
  match Yojson.Safe.Util.member name json with
  | `String s -> Some s
  | _ -> None
;;

let json_float_opt name json =
  match Yojson.Safe.Util.member name json with
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | _ -> None
;;

let index_event_matches_request ~base_path request json =
  let dir = request_dir ~base_path request in
  let json_path = request_json_path ~base_path request in
  let task_seed_md_path = request_task_seed_md_path ~base_path request in
  match
    ( json_string_opt "id" json
    , json_string_opt "requester" json
    , json_string_opt "topic" json
    , json_string_opt "promotion_state" json
    , json_string_opt "dir" json
    , json_string_opt "json_path" json
    , json_string_opt "task_seed_md_path" json )
  with
  | ( Some id
    , Some requester
    , Some topic
    , Some promotion_state
    , Some indexed_dir
    , Some indexed_json_path
    , Some indexed_task_seed_md_path ) ->
    String.equal id request.Keeper_delegation_request.id
    && String.equal requester request.requester
    && String.equal topic request.topic
    && String.equal promotion_state
         (Keeper_delegation_request.promotion_state_to_string
            request.promotion_state)
    && String.equal indexed_dir dir
    && String.equal indexed_json_path json_path
    && String.equal indexed_task_seed_md_path task_seed_md_path
  | _ -> false
;;

let index_contains_request ~base_path request =
  let index_path = index_path ~base_path in
  if not (Fs_compat.file_exists index_path)
  then Ok false
  else
    try
      Ok
        (Fs_compat.load_jsonl index_path
         |> List.exists (index_event_matches_request ~base_path request))
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printf.sprintf "%s: %s" index_path (Printexc.to_string exn))
;;

let write_request_if_changed ~base_path request =
  let artifacts_unchanged =
    request_artifacts ~base_path request
    |> List.for_all (fun (path, expected) ->
      match read_file_opt path with
      | Some content -> String.equal content expected
      | None -> false)
  in
  let* indexed = index_contains_request ~base_path request in
  if artifacts_unchanged && indexed
  then Ok None
  else (
    let* stored = write_request ~base_path request in
    Ok (Some stored))
;;

let write_execution_result ~base_path ~requester ?goal execution =
  let requests =
    Keeper_delegation_request.of_execution_result ~requester ?goal execution
  in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | request :: rest ->
      let* stored = write_request_if_changed ~base_path request in
      let acc =
        match stored with
        | Some stored -> stored :: acc
        | None -> acc
      in
      loop acc rest
  in
  loop [] requests
;;

let request_summary_of_index_event json =
  match
    ( json_string_opt "id" json
    , json_string_opt "requester" json
    , json_string_opt "topic" json
    , json_string_opt "promotion_state" json
    , json_string_opt "dir" json
    , json_string_opt "json_path" json
    , json_string_opt "task_seed_md_path" json )
  with
  | ( Some id
    , Some requester
    , Some topic
    , Some promotion_state
    , Some dir
    , Some json_path
    , Some task_seed_md_path ) ->
    let goal =
      match Yojson.Safe.Util.member "goal" json with
      | `String goal -> Some goal
      | _ -> None
    in
    Some
      { id
      ; requester
      ; topic
      ; goal
      ; promotion_state
      ; dir
      ; json_path
      ; task_seed_md_path
      ; created_at = json_float_opt "ts" json
      }
  | _ -> None
;;

let take n xs =
  let rec loop acc remaining = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: rest -> loop (x :: acc) (remaining - 1) rest
  in
  loop [] n xs
;;

let latest_unique summaries =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun (summary : request_summary) ->
       let key = summary_identity_key summary in
       if Hashtbl.mem seen key
       then false
       else (
         Hashtbl.add seen key ();
         true))
    summaries
;;

let list_requests ~base_path ~limit =
  let index_path = index_path ~base_path in
  let limit = max 0 limit in
  try
    let items =
      if Fs_compat.file_exists index_path
      then
        Fs_compat.load_jsonl index_path
        |> List.rev
        |> List.filter_map request_summary_of_index_event
        |> latest_unique
      else []
    in
    let total = List.length items in
    let items = take limit items in
    Ok { total; shown = List.length items; limit; index_path; items }
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printf.sprintf "%s: %s" index_path (Printexc.to_string exn))
;;

let json_option_float = function
  | Some f -> `Float f
  | None -> `Null
;;

let request_summary_to_json (summary : request_summary) =
  `Assoc
    [ "id", `String summary.id
    ; "requester", `String summary.requester
    ; "topic", `String summary.topic
    ; "goal", Json_util.string_opt_to_json summary.goal
    ; "promotion_state", `String summary.promotion_state
    ; "dir", `String summary.dir
    ; "json_path", `String summary.json_path
    ; "task_seed_md_path", `String summary.task_seed_md_path
    ; "created_at", json_option_float summary.created_at
    ]
;;
