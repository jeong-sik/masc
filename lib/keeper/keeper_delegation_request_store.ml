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

let request_identity_key (request : Keeper_delegation_request.t) =
  Keeper_delegation_request.identity_key request
;;

let summary_identity_key (summary : request_summary) = summary.id

let request_component request =
  Review_artifact_store.component
    ~display_id:request.Keeper_delegation_request.id
    ~identity_key:(request_identity_key request)
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

let request_json_content request =
  Yojson.Safe.pretty_to_string (Keeper_delegation_request.to_json request) ^ "\n"
;;

let render_task_seed_md (request : Keeper_delegation_request.t) =
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

let ( let* ) = Result.bind

let stored_request ~base_path request =
  { request
  ; dir = request_dir ~base_path request
  ; json_path = request_json_path ~base_path request
  ; task_seed_md_path = request_task_seed_md_path ~base_path request
  ; index_path = index_path ~base_path
  }
;;

let write_request ~base_path request =
  let stored = stored_request ~base_path request in
  let* () =
    Review_artifact_store.write_artifacts
      ~index_path:stored.index_path
      ~artifacts:(request_artifacts ~base_path request)
      ~index_event:
        (index_event_json request
           ~dir:stored.dir
           ~json_path:stored.json_path
           ~task_seed_md_path:stored.task_seed_md_path)
  in
  Ok stored
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

let write_request_if_changed ~base_path request =
  let stored = stored_request ~base_path request in
  let* changed =
    Review_artifact_store.write_if_changed
      ~index_path:stored.index_path
      ~artifacts:(request_artifacts ~base_path request)
      ~index_event:
        (index_event_json request
           ~dir:stored.dir
           ~json_path:stored.json_path
           ~task_seed_md_path:stored.task_seed_md_path)
      ~matches:(index_event_matches_request ~base_path request)
  in
  if changed then Ok (Some stored) else Ok None
;;

let write_execution_result ~base_path ~requester execution =
  let requests =
    Keeper_delegation_request.of_execution_result ~requester execution
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
    Some
      { id
      ; requester
      ; topic
      ; promotion_state
      ; dir
      ; json_path
      ; task_seed_md_path
      ; created_at = json_float_opt "ts" json
      }
  | _ -> None
;;

let list_requests ~base_path ~limit =
  let index_path = index_path ~base_path in
  let limit = max 0 limit in
  let* (total, items) =
    Review_artifact_store.list_index
      ~index_path
      ~limit
      ~of_json:request_summary_of_index_event
      ~identity_key:summary_identity_key
  in
  Ok { total; shown = List.length items; limit; index_path; items }
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
    ; "promotion_state", `String summary.promotion_state
    ; "dir", `String summary.dir
    ; "json_path", `String summary.json_path
    ; "task_seed_md_path", `String summary.task_seed_md_path
    ; "created_at", json_option_float summary.created_at
    ]
;;
