(** Admin-only exact cleanup boundaries for Keeper-owned derived state. *)

module Http = Http_server_eio
module Current = Keeper_memory_os_current
module Context = Keeper_librarian_context

let ( let* ) = Result.bind
let permission = Masc_domain.CanAdmin
let prefix = "/api/v1/keepers/"

type target =
  | Current_memory of string
  | Working_context of string

let route path =
  if not (String.starts_with ~prefix path)
  then None
  else
    match
      String.sub path (String.length prefix) (String.length path - String.length prefix)
      |> String.split_on_char '/'
    with
    | [ keeper_name; "memory"; "retractions" ] when keeper_name <> "" ->
      Some (Current_memory keeper_name)
    | [ keeper_name; "working-context"; "source-retractions" ]
      when keeper_name <> "" ->
      Some (Working_context keeper_name)
    | _ -> None
;;

type current_memory_request =
  { plan_id : string
  ; expected_revision : int
  ; expected_snapshot_sha256 : string
  ; retractions : Current.retraction list
  }

type working_context_request =
  { plan_id : string
  ; expected_version : Context.version
  ; expected_snapshot_sha256 : string
  ; source_references : string list
  }

let exact_fields expected fields =
  let expected = List.sort String.compare expected in
  let observed = List.map fst fields |> List.sort String.compare in
  if observed = expected
  then Ok ()
  else
    Error
      (Printf.sprintf
         "request fields must be exactly [%s]"
         (String.concat ", " expected))
;;

let object_fields what = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length names = List.length (List.sort_uniq String.compare names)
    then Ok fields
    else Error (what ^ " contains duplicate fields")
  | json ->
    Error
      (Printf.sprintf
         "%s must be an object, received %s"
         what
         (Json_util.kind_name json))
;;

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field: " ^ name)
;;

let nonempty_trimmed_string name fields =
  let* value = field name fields in
  match value with
  | `String value
    when value <> "" && String.equal value (String.trim value) ->
    Ok value
  | _ -> Error (name ^ " must be a non-empty trimmed string")
;;

let positive_int name fields =
  let* value = field name fields in
  match value with
  | `Int value when value > 0 -> Ok value
  | _ -> Error (name ^ " must be a positive integer")
;;

let snapshot_sha256 fields =
  let* value = nonempty_trimmed_string "expected_snapshot_sha256" fields in
  if String_util.is_lowercase_sha256_hex value
  then Ok value
  else
    Error
      "expected_snapshot_sha256 must be exactly 64 lowercase hexadecimal characters"
;;

let list_field name fields =
  let* value = field name fields in
  match value with
  | `List values -> Ok values
  | _ -> Error (name ^ " must be an array")
;;

let parse_json body =
  match Yojson.Safe.from_string body with
  | json -> Ok json
  | exception Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
;;

let parse_current_memory_request body =
  let* json = parse_json body in
  let* fields = object_fields "request" json in
  let* () =
    exact_fields
      [ "expected_revision"
      ; "expected_snapshot_sha256"
      ; "plan_id"
      ; "retractions"
      ]
      fields
  in
  let* plan_id = nonempty_trimmed_string "plan_id" fields in
  let* expected_revision = positive_int "expected_revision" fields in
  let* expected_snapshot_sha256 = snapshot_sha256 fields in
  let* rows = list_field "retractions" fields in
  if rows = []
  then Error "retractions must be a non-empty array"
  else
    let rec decode index seen = function
      | [] -> Ok []
      | json :: rest ->
        let* row = object_fields (Printf.sprintf "retractions[%d]" index) json in
        let* () = exact_fields [ "memory_id"; "reason" ] row in
        let* memory_id = nonempty_trimmed_string "memory_id" row in
        let* reason = nonempty_trimmed_string "reason" row in
        if not (Keeper_memory_os_types.is_memory_id memory_id)
        then Error (Printf.sprintf "retractions[%d].memory_id is invalid" index)
        else if Set_util.StringSet.mem memory_id seen
        then Error ("retractions repeats memory_id: " ^ memory_id)
        else
          let* tail =
            decode
              (index + 1)
              (Set_util.StringSet.add memory_id seen)
              rest
          in
          Ok (Current.{ memory_id; reason } :: tail)
    in
    let* retractions = decode 0 Set_util.StringSet.empty rows in
    Ok { plan_id; expected_revision; expected_snapshot_sha256; retractions }
;;

let parse_working_context_request body =
  let* json = parse_json body in
  let* fields = object_fields "request" json in
  let* () =
    exact_fields
      [ "expected_generation"
      ; "expected_revision"
      ; "expected_snapshot_sha256"
      ; "plan_id"
      ; "source_references"
      ]
      fields
  in
  let* plan_id = nonempty_trimmed_string "plan_id" fields in
  let* expected_generation = nonempty_trimmed_string "expected_generation" fields in
  let* expected_revision = positive_int "expected_revision" fields in
  let* expected_snapshot_sha256 = snapshot_sha256 fields in
  let* values = list_field "source_references" fields in
  if values = []
  then Error "source_references must be a non-empty array"
  else
    let rec decode index seen = function
      | [] -> Ok []
      | `String reference :: rest
        when reference <> "" && String.equal reference (String.trim reference) ->
        if Set_util.StringSet.mem reference seen
        then Error ("source_references repeats reference: " ^ reference)
        else
          let* tail =
            decode
              (index + 1)
              (Set_util.StringSet.add reference seen)
              rest
          in
          Ok (reference :: tail)
      | _ :: _ ->
        Error
          (Printf.sprintf
             "source_references[%d] must be a non-empty trimmed string"
             index)
    in
    let* source_references = decode 0 Set_util.StringSet.empty values in
    Ok
      { plan_id
      ; expected_version = expected_generation, expected_revision
      ; expected_snapshot_sha256
      ; source_references
      }
;;

let respond request reqd ?(status = `OK) json =
  Http.Response.json_value
    ~status
    ~request
    ~extra_headers:[ "cache-control", "no-store" ]
    json
    reqd
;;

let respond_error request reqd ~status ~code detail =
  respond
    request
    reqd
    ~status
    (`Assoc
       [ "ok", `Bool false
       ; "code", `String code
       ; "error", `String detail
       ])
;;

let append_retraction_events ~keepers_dir ~keeper_id ~plan_id ~now retractions =
  Keeper_memory_os_events.append_all
    ~keepers_dir
    ~keeper_id
    (List.map
       (fun ({ Current.memory_id; _ } : Current.retraction) ->
          { Keeper_memory_os_events.recorded_at = now
          ; memory_id
          ; trace_id = plan_id
          ; kind = Keeper_memory_os_events.Retracted
          })
       retractions)
  |> List.iter (fun error ->
       Log.Keeper.warn
         ~keeper_name:keeper_id
         "admin memory retraction event append failed plan_id=%s: %s"
         plan_id
         (Keeper_memory_os_events.append_error_to_string error))
;;

let handle_current_memory state ~actor request reqd keeper_name body =
  match parse_current_memory_request body with
  | Error detail ->
    respond_error request reqd ~status:`Bad_request ~code:"invalid_request" detail
  | Ok parsed ->
    let config = Mcp_server.workspace_config state in
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path
        ~base_path:config.Workspace.base_path
    in
    let now = Time_compat.now () in
    (match
       Current.retract_facts
         ~keepers_dir
         ~keeper_id:keeper_name
         ~expected_revision:parsed.expected_revision
         ~expected_snapshot_sha256:parsed.expected_snapshot_sha256
         ~now
         ~source:
           { Current.kind = Current.Explicit_retract
           ; trace_id = parsed.plan_id
           }
         parsed.retractions
     with
     | Ok snapshot ->
       append_retraction_events
         ~keepers_dir
         ~keeper_id:keeper_name
         ~plan_id:parsed.plan_id
         ~now
         parsed.retractions;
       Log.Keeper.info
         "admin current Memory retraction committed keeper=%s actor=%s plan_id=%s revision=%d direct=%d invalidated=%d"
         keeper_name
         actor
         parsed.plan_id
         snapshot.revision
         (List.length parsed.retractions)
         (List.length snapshot.change.invalidated);
       respond
         request
         reqd
         (`Assoc
            [ "ok", `Bool true
            ; "keeper", `String keeper_name
            ; "plan_id", `String parsed.plan_id
            ; "expected_revision", `Int parsed.expected_revision
            ; ( "expected_snapshot_sha256"
              , `String parsed.expected_snapshot_sha256 )
            ; "revision", `Int snapshot.revision
            ; "snapshot_sha256", `String (Current.snapshot_sha256 snapshot)
            ; ( "retracted_memory_ids"
              , `List
                  (List.map
                     (fun ({ Current.memory_id; _ } : Current.retraction) ->
                        `String memory_id)
                     parsed.retractions) )
            ; ( "removed_memory_ids"
              , `List
                  (List.map
                     (fun fact ->
                        `String (Keeper_memory_os_types.memory_id fact))
                     snapshot.change.removed) )
            ; ( "support_invalidations"
              , `List
                  (List.map
                     (fun (row : Current.support_invalidation) ->
                        `Assoc
                          [ ( "memory_id"
                            , `String
                                (Keeper_memory_os_types.memory_id row.fact) )
                          ; ( "missing_premise_ids"
                            , `List
                                (List.map
                                   (fun id -> `String id)
                                   row.missing_premise_ids) )
                          ])
                     snapshot.change.invalidated) )
            ])
     | Error Current.Retract_batch_empty ->
       respond_error request reqd ~status:`Bad_request ~code:"empty_retractions"
         "retractions must be non-empty"
     | Error (Current.Retract_batch_memory_id_invalid { index }) ->
       respond_error request reqd ~status:`Bad_request ~code:"invalid_memory_id"
         (Printf.sprintf "retractions[%d].memory_id is invalid" index)
     | Error (Current.Retract_batch_reason_empty { index }) ->
       respond_error request reqd ~status:`Bad_request ~code:"empty_reason"
         (Printf.sprintf "retractions[%d].reason is empty" index)
     | Error (Current.Retract_batch_duplicate_memory_id memory_id) ->
       respond_error request reqd ~status:`Bad_request ~code:"duplicate_memory_id"
         ("duplicate memory_id: " ^ memory_id)
     | Error Current.Retract_batch_snapshot_sha256_invalid ->
       respond_error request reqd ~status:`Bad_request
         ~code:"invalid_expected_snapshot_sha256"
         "expected_snapshot_sha256 is invalid"
     | Error
         (Current.Retract_batch_snapshot_conflict
            { expected_revision
            ; observed_revision
            ; expected_snapshot_sha256
            ; observed_snapshot_sha256
            }) ->
       respond
         request
         reqd
         ~status:`Conflict
         (`Assoc
            [ "ok", `Bool false
            ; "code", `String "snapshot_conflict"
            ; "expected_revision", `Int expected_revision
            ; ( "observed_revision"
              , match observed_revision with
                | None -> `Null
                | Some value -> `Int value )
            ; "expected_snapshot_sha256", `String expected_snapshot_sha256
            ; ( "observed_snapshot_sha256"
              , match observed_snapshot_sha256 with
                | None -> `Null
                | Some value -> `String value )
            ])
     | Error (Current.Retract_batch_fact_not_found memory_id) ->
       respond_error request reqd ~status:`Conflict ~code:"memory_id_not_current"
         ("memory_id is not current: " ^ memory_id)
     | Error
         (Current.Retract_batch_plan_evidence_pending
            { plan_id
            ; snapshot_revision
            ; snapshot_sha256
            ; detail
            }) ->
       respond
         request
         reqd
         ~status:`Service_unavailable
         (`Assoc
            [ "ok", `Bool false
            ; "code", `String "retraction_plan_evidence_pending"
            ; "snapshot_committed", `Bool true
            ; "keeper", `String keeper_name
            ; "plan_id", `String plan_id
            ; "revision", `Int snapshot_revision
            ; "snapshot_sha256", `String snapshot_sha256
            ; "error", `String detail
            ])
     | Error (Current.Retract_batch_persistence_failed detail) ->
       respond_error request reqd ~status:`Service_unavailable
         ~code:"memory_store_unavailable" detail)
;;

let handle_working_context state ~actor request reqd keeper_name body =
  match parse_working_context_request body with
  | Error detail ->
    respond_error request reqd ~status:`Bad_request ~code:"invalid_request" detail
  | Ok parsed ->
    let config = Mcp_server.workspace_config state in
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path
        ~base_path:config.Workspace.base_path
    in
    (match
       Context.retract_sources
         ~keepers_dir
         ~keeper_id:keeper_name
         ~expected_version:parsed.expected_version
         ~expected_snapshot_sha256:parsed.expected_snapshot_sha256
         ~source_references:parsed.source_references
     with
     | Ok snapshot ->
       Log.Keeper.info
         "admin working context source retraction committed keeper=%s actor=%s plan_id=%s generation=%s revision=%d sources=%d"
         keeper_name
         actor
         parsed.plan_id
         snapshot.generation
         snapshot.revision
         (List.length parsed.source_references);
       let receipt projection_fields =
         `Assoc
           ([ "ok", `Bool true
            ; "keeper", `String keeper_name
            ; "plan_id", `String parsed.plan_id
            ; ( "expected_snapshot_sha256"
              , `String parsed.expected_snapshot_sha256 )
            ; "generation", `String snapshot.generation
            ; "revision", `Int snapshot.revision
            ; "snapshot_sha256", `String (Context.snapshot_sha256 snapshot)
            ; ( "retracted_source_references"
              , `List
                  (List.map
                     (fun reference -> `String reference)
                     parsed.source_references) )
            ; "remaining_source_count", `Int (List.length snapshot.sources)
            ; "remaining_pocket_count", `Int (List.length snapshot.pockets)
            ]
            @ projection_fields)
       in
       (match
          Keeper_librarian_context_recall.publish
            ~base_path:config.Workspace.base_path
            ~keepers_dir
            ~keeper_name
            snapshot
        with
        | Ok () ->
          respond
            request
            reqd
            (receipt [ "recall_projection", `String "published" ])
        | Error publish_error ->
          (* A failed publisher may be older than an index another publisher
             just installed. Never delete that index: [Recall.render] owns the
             fail-closed check against the authoritative snapshot version. *)
          Log.Keeper.warn
            ~keeper_name
            "working context cleanup committed but recall publication failed; read side remains fail-closed plan_id=%s: %s"
            parsed.plan_id
            publish_error;
          respond
            request
            reqd
            (receipt
               [ ( "recall_projection"
                 , `String "unavailable_after_publish_failure" )
               ; "recall_projection_error", `String publish_error
               ]))
     | Error Context.Retract_sources_empty ->
       respond_error request reqd ~status:`Bad_request
         ~code:"empty_source_references" "source_references must be non-empty"
     | Error (Context.Retract_source_reference_empty { index }) ->
       respond_error request reqd ~status:`Bad_request
         ~code:"invalid_source_reference"
         (Printf.sprintf "source_references[%d] is empty or untrimmed" index)
     | Error (Context.Retract_source_reference_duplicate reference) ->
       respond_error request reqd ~status:`Bad_request
         ~code:"duplicate_source_reference"
         ("duplicate source reference: " ^ reference)
     | Error Context.Retract_snapshot_not_found ->
       respond_error request reqd ~status:`Not_found
         ~code:"working_context_not_found" "working context snapshot not found"
     | Error Context.Retract_snapshot_sha256_invalid ->
       respond_error request reqd ~status:`Bad_request
         ~code:"invalid_expected_snapshot_sha256"
         "expected_snapshot_sha256 is invalid"
     | Error
         (Context.Retract_snapshot_conflict
            { expected_version
            ; observed_version
            ; expected_snapshot_sha256
            ; observed_snapshot_sha256
            }) ->
       let expected_generation, expected_revision = expected_version in
       let observed_generation, observed_revision =
         match observed_version with
         | None -> `Null, `Null
         | Some (generation, revision) -> `String generation, `Int revision
       in
       respond
         request
         reqd
         ~status:`Conflict
         (`Assoc
            [ "ok", `Bool false
            ; "code", `String "snapshot_conflict"
            ; "expected_generation", `String expected_generation
            ; "expected_revision", `Int expected_revision
            ; "expected_snapshot_sha256", `String expected_snapshot_sha256
            ; "observed_generation", observed_generation
            ; "observed_revision", observed_revision
            ; ( "observed_snapshot_sha256"
              , match observed_snapshot_sha256 with
                | None -> `Null
                | Some value -> `String value )
            ])
     | Error (Context.Retract_source_not_found reference) ->
       respond_error request reqd ~status:`Conflict
         ~code:"source_reference_not_current"
         ("source reference is not current: " ^ reference)
     | Error (Context.Retract_sources_persistence_failed detail) ->
       respond_error request reqd ~status:`Service_unavailable
         ~code:"working_context_store_unavailable" detail)
;;

let handle_post state ~actor request reqd target body =
  let keeper_name =
    match target with
    | Current_memory keeper_name | Working_context keeper_name -> keeper_name
  in
  if not (Keeper_config.validate_name keeper_name)
  then
    respond_error request reqd ~status:`Bad_request
      ~code:"invalid_keeper_name" "invalid keeper name"
  else
    match target with
    | Current_memory keeper_name ->
      handle_current_memory state ~actor request reqd keeper_name body
    | Working_context keeper_name ->
      handle_working_context state ~actor request reqd keeper_name body
;;
