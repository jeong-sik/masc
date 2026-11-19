(** Admin-only exact cleanup boundaries for Keeper-owned derived state. *)

module Http = Http_server_eio
module Context = Keeper_librarian_context
module Unwritable = Keeper_tool_memory_validation

open Result.Syntax
let permission = Masc_domain.CanAdmin
let prefix = Server_dashboard_http_keeper_api_types.keeper_api_prefix

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

type retraction =
  { memory_id : string
  ; reason : string
  }

type current_memory_request =
  { plan_id : string
  ; retractions : retraction list
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
  let* () = exact_fields [ "plan_id"; "retractions" ] fields in
  let* plan_id = nonempty_trimmed_string "plan_id" fields in
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
          Ok ({ memory_id; reason } :: tail)
    in
    let* retractions = decode 0 Set_util.StringSet.empty rows in
    Ok { plan_id; retractions }
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

type retraction_result =
  | Retraction_committed of Librarian_log.commit
  | Retraction_not_current

type retractions_outcome =
  { answered : (retraction * retraction_result) list
  ; stopped : (retraction * Unwritable.memory_unwritable) option
  }

(* Each retraction is one direct write to the Keeper's Memory writer, in the
   order of the request, on the trace [plan_id]. The first one the writer
   does not take ends the request: the ones before it are committed, and
   sending the request again finds them not current. *)
let retract_through_writer ~base_path ~keeper ~actor (parsed : current_memory_request) =
  let stopped_at retraction why answered =
    { answered = List.rev answered; stopped = Some (retraction, why) }
  in
  match Keeper_memory_writers.find ~base_path with
  | None ->
    (match parsed.retractions with
     | [] -> { answered = []; stopped = None }
     | first :: _ -> stopped_at first Unwritable.No_writer_in_process [])
  | Some writers ->
    let rec next answered = function
      | [] -> { answered = List.rev answered; stopped = None }
      | ({ memory_id; reason } as retraction) :: rest ->
        (match
           Librarian_writers.write
             writers
             keeper
             ~by:(Librarian_effects.Operator actor)
             ~trace:parsed.plan_id
             (Retract { id = memory_id; reason })
         with
         | Written commit -> next ((retraction, Retraction_committed commit) :: answered) rest
         | Already_absent -> next ((retraction, Retraction_not_current) :: answered) rest
         | Already_held | Already_done ->
           stopped_at retraction Unwritable.Answer_of_another_write answered
         | Refused refusal ->
           stopped_at retraction (Unwritable.Refused_past_validation refusal) answered
         | Not_a_snapshot refusal ->
           stopped_at retraction (Unwritable.Not_a_snapshot refusal) answered
         | Unavailable (Store_stopped stop) ->
           stopped_at retraction (Unwritable.Store_stopped stop) answered
         | Unavailable Keeper_retired ->
           stopped_at retraction Unwritable.Keeper_not_registered answered)
    in
    next [] parsed.retractions
;;

(* A committed retraction says what left Memory in the two fields the
   Keeper's retraction receipt uses. *)
let retraction_json (({ memory_id; reason = (_ : string) } : retraction), result) =
  match result with
  | Retraction_not_current ->
    `Assoc [ "memory_id", `String memory_id; "outcome", `String "not_current" ]
  | Retraction_committed commit ->
    `Assoc
      ([ "memory_id", `String memory_id
       ; "outcome", `String "retracted"
       ; "revision", `Int commit.revision
       ]
       @ Keeper_tool_memory_runtime.removal_receipt commit.effects)
;;

(* A stopped store, a Keeper out of the registry and a process without
   writers did not take the write. The rest cannot come from a retraction
   this route parsed. *)
let status_of_unwritable : Unwritable.memory_unwritable -> Httpun.Status.t = function
  | Store_stopped _ | Keeper_not_registered | No_writer_in_process -> `Service_unavailable
  | Refused_past_validation _ | Not_a_snapshot _ | Answer_of_another_write ->
    `Internal_server_error
;;

let handle_current_memory state ~actor request reqd keeper_name body =
  match parse_current_memory_request body with
  | Error detail ->
    respond_error request reqd ~status:`Bad_request ~code:"invalid_request" detail
  | Ok parsed ->
    let config = Mcp_server.workspace_config state in
    let outcome =
      retract_through_writer
        ~base_path:config.Workspace.base_path
        ~keeper:keeper_name
        ~actor
        parsed
    in
    let answered = "retractions", `List (List.map retraction_json outcome.answered) in
    Log.Keeper.info
      "admin current Memory retraction keeper=%s actor=%s plan_id=%s answered=%d of %d"
      keeper_name
      actor
      parsed.plan_id
      (List.length outcome.answered)
      (List.length parsed.retractions);
    (match outcome.stopped with
     | None ->
       respond
         request
         reqd
         (`Assoc
            [ "ok", `Bool true
            ; "keeper", `String keeper_name
            ; "plan_id", `String parsed.plan_id
            ; answered
            ])
     | Some (({ memory_id; reason = (_ : string) } : retraction), why) ->
       respond
         request
         reqd
         ~status:(status_of_unwritable why)
         (`Assoc
            [ "ok", `Bool false
            ; "code", `String "memory_unwritable"
            ; "unwritable", `String (Unwritable.memory_unwritable_to_string why)
            ; "keeper", `String keeper_name
            ; "plan_id", `String parsed.plan_id
            ; "stopped_at_memory_id", `String memory_id
            ; answered
            ]))
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
