(** Fleet-wide bulk cancel for the Keeper event queue.

    Admin-only, the same boundary as the per-Keeper operator control
    ([Server_dashboard_http_keeper_event_queue_operator]). The default is a
    dry run: it reports the exact number of rows it would cancel, grouped by
    keeper and source, plus the oldest age, and mutates nothing. Execution
    requires an explicit confirm token and writes a backup of every row it is
    about to cancel before it touches the queue. Each row is cancelled through
    the same durable, fenced per-Keeper transition the single-row operator
    boundary uses. A retry re-plans from current state, so a row cancelled by
    an earlier attempt is no longer in the plan and is not cancelled twice. *)

module Http = Http_server_eio
module Execute = Server_dashboard_http_keeper_event_queue_operator_execute

let ( let* ) = Result.bind

let schema = "keeper_event_queue.bulk.request.v1"
let result_schema = "keeper_event_queue.bulk.result.v1"
let confirm_token = "cancel-pending-events"
let permission = Masc_domain.CanAdmin

type filter =
  { keepers : string list option
  ; sources : string list option
  }

type request =
  { dry_run : bool
  ; confirm : string option
  ; reason : string
  ; filter : filter
  }

type row =
  { keeper_name : string
  ; source_ref : string
  ; source_incarnation : int64
  ; source_label : string
  ; since : float
  }

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field: " ^ name)
;;

let string_field name fields =
  let* value = field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (name ^ " must be a string")
;;

let string_list_field name fields =
  let* value = field name fields in
  match value with
  | `List items ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | `String item :: rest -> loop (item :: acc) rest
      | _ -> Error (name ^ " must be a list of strings")
    in
    loop [] items
  | _ -> Error (name ^ " must be a list of strings")
;;

let parse_filter fields =
  match List.assoc_opt "filter" fields with
  | None -> Ok { keepers = None; sources = None }
  | Some (`Assoc filter_fields) ->
    let* keepers =
      match List.assoc_opt "keepers" filter_fields with
      | None -> Ok None
      | Some _ -> Result.map Option.some (string_list_field "keepers" filter_fields)
    in
    let* sources =
      match List.assoc_opt "sources" filter_fields with
      | None -> Ok None
      | Some _ -> Result.map Option.some (string_list_field "sources" filter_fields)
    in
    Ok { keepers; sources }
  | Some _ -> Error "filter must be an object"
;;

let parse body =
  let* fields =
    match Yojson.Safe.from_string body with
    | `Assoc fields -> Ok fields
    | value ->
      Error
        (Printf.sprintf
           "request body must be an object, received %s"
           (Json_util.kind_name value))
    | exception Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
  in
  let* request_schema = string_field "schema" fields in
  if not (String.equal request_schema schema)
  then Error ("unsupported schema: " ^ request_schema)
  else
    let* action = string_field "action" fields in
    if not (String.equal action "cancel")
    then Error ("unknown event queue bulk action: " ^ action)
    else
      let* dry_run =
        match List.assoc_opt "dry_run" fields with
        | None -> Ok true
        | Some (`Bool value) -> Ok value
        | Some _ -> Error "dry_run must be a boolean"
      in
      let* confirm =
        match List.assoc_opt "confirm" fields with
        | None -> Ok None
        | Some (`String value) -> Ok (Some value)
        | Some _ -> Error "confirm must be a string"
      in
      let* reason = string_field "reason" fields in
      if reason = "" || not (String.equal reason (String.trim reason))
      then Error "reason must be non-empty and trimmed"
      else
        let* filter = parse_filter fields in
        Ok { dry_run; confirm; reason; filter }
;;

let rows_for_keeper ~base_path keeper_name =
  match Keeper_event_queue_persistence.load_state_result ~base_path ~keeper_name with
  | Error _ -> []
  | Ok state ->
    Keeper_event_queue_state.pending_selections state
    |> List.map (fun (selection : Keeper_event_queue_state.pending_selection) ->
      { keeper_name
      ; source_ref = Keeper_event_queue_state.source_snapshot_ref selection.source
      ; source_incarnation = selection.admitted_revision
      ; source_label = Keeper_event_queue.payload_kind_label selection.source.payload
      ; since = selection.source.arrived_at
      })
;;

let all_rows config =
  let base_path = config.Workspace.base_path in
  match Keeper_meta_store.keeper_names_result config with
  | Error _ -> []
  | Ok keeper_names -> List.concat_map (rows_for_keeper ~base_path) keeper_names
;;

let row_matches filter row =
  let keeper_ok =
    match filter.keepers with
    | None -> true
    | Some keepers -> List.mem row.keeper_name keepers
  in
  let source_ok =
    match filter.sources with
    | None -> true
    | Some sources -> List.mem row.source_label sources
  in
  keeper_ok && source_ok
;;

(* The rows a request would act on. Dry-run counts these and execution
   cancels exactly these, so the two can never disagree. *)
let plan_rows filter rows = List.filter (row_matches filter) rows

let count_by key rows =
  let table = Hashtbl.create 16 in
  List.iter
    (fun row ->
       let k = key row in
       let seen = match Hashtbl.find_opt table k with Some n -> n | None -> 0 in
       Hashtbl.replace table k (seen + 1))
    rows;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) table []
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
;;

let oldest_age_seconds rows =
  match rows with
  | [] -> None
  | _ ->
    let oldest =
      List.fold_left (fun acc row -> Float.min acc row.since) Float.max_float rows
    in
    Some (Float.max 0.0 (Time_compat.now () -. oldest))
;;

let row_json row =
  `Assoc
    [ "keeper_name", `String row.keeper_name
    ; "source", `String row.source_label
    ; "source_ref", `String row.source_ref
    ; "source_incarnation", `String (Int64.to_string row.source_incarnation)
    ; "since", `Float row.since
    ]
;;

let counts_json counts =
  `Assoc (List.map (fun (key, count) -> key, `Int count) counts)
;;

(* The operation id is an opaque correlation identifier for one bulk request,
   not an authentication secret; [Random_id.uuid_v7] wraps the process crypto
   RNG boundary. *)
let fresh_operation_id () = Random_id.uuid_v7 ()
;;

let backup_path ~base_path operation_id =
  Filename.concat
    (Filename.concat base_path "event-queue-bulk-backups")
    (operation_id ^ ".json")
;;

let cancel_row ~config ~operation_id ~reason row =
  let operator_operation_id =
    Printf.sprintf
      "bulk:%s:%s:%s:%s"
      operation_id
      row.keeper_name
      row.source_ref
      (Int64.to_string row.source_incarnation)
  in
  let outcome =
    Execute.run
      ~config
      ~keeper_name:row.keeper_name
      (Execute.Cancel
         { source_ref = row.source_ref
         ; source_incarnation = row.source_incarnation
         ; operator_operation_id
         ; reason
         })
  in
  match outcome with
  | Ok _ -> `Assoc [ "keeper_name", `String row.keeper_name; "ok", `Bool true ]
  | Error detail ->
    `Assoc
      [ "keeper_name", `String row.keeper_name
      ; "ok", `Bool false
      ; "error", `String detail
      ]
;;

(* Cancel exactly the planned rows through [cancel]. The real caller passes
   {!cancel_row}; tests pass a recorder so the dry-run count and the executed
   rows can be compared without the durable machinery. *)
let execute_rows ~cancel ~operation_id ~reason rows =
  List.map (cancel ~operation_id ~reason) rows
;;

let handle_post state ~actor:_ req reqd body =
  let respond ?(status = `OK) json =
    Http.Response.json_value ~status ~request:req json reqd
  in
  match parse body with
  | Error detail ->
    respond
      ~status:`Bad_request
      (`Assoc
        [ "schema", `String result_schema
        ; "ok", `Bool false
        ; "error", `String detail
        ])
  | Ok request ->
    let config = Mcp_server.workspace_config state in
    let rows = plan_rows request.filter (all_rows config) in
    let keeper_counts = count_by (fun row -> row.keeper_name) rows in
    let source_counts = count_by (fun row -> row.source_label) rows in
    let oldest = oldest_age_seconds rows in
    if request.dry_run
    then
      respond
        (`Assoc
          [ "schema", `String result_schema
          ; "ok", `Bool true
          ; "dry_run", `Bool true
          ; "would_cancel", `Int (List.length rows)
          ; "keeper_counts", counts_json keeper_counts
          ; "source_counts", counts_json source_counts
          ; "oldest_age_seconds", Json_util.float_opt_to_json oldest
          ; "rows", `List (List.map row_json rows)
          ])
    else
      match request.confirm with
      | Some token when String.equal token confirm_token ->
        let operation_id = fresh_operation_id () in
        let backup =
          `Assoc
            [ "schema", `String result_schema
            ; "operation_id", `String operation_id
            ; "reason", `String request.reason
            ; "rows", `List (List.map row_json rows)
            ]
        in
        let path = backup_path ~base_path:config.Workspace.base_path operation_id in
        (match
           Fs_compat.save_file_atomic_strict path (Yojson.Safe.to_string backup)
         with
         | Error detail ->
           respond
             ~status:`Internal_server_error
             (`Assoc
               [ "schema", `String result_schema
               ; "ok", `Bool false
               ; "error", `String ("backup write failed: " ^ detail)
               ])
         | Ok () ->
           let results =
             execute_rows
               ~cancel:(cancel_row ~config)
               ~operation_id
               ~reason:request.reason
               rows
           in
           let cancelled =
             List.fold_left
               (fun acc result ->
                  match Json_util.assoc_member_opt "ok" result with
                  | Some (`Bool true) -> acc + 1
                  | _ -> acc)
               0
               results
           in
           respond
             (`Assoc
               [ "schema", `String result_schema
               ; "ok", `Bool true
               ; "dry_run", `Bool false
               ; "operation_id", `String operation_id
               ; "backup_path", `String path
               ; "would_cancel", `Int (List.length rows)
               ; "cancelled", `Int cancelled
               ; "failed", `Int (List.length rows - cancelled)
               ; "results", `List results
               ]))
      | _ ->
        respond
          ~status:`Bad_request
          (`Assoc
            [ "schema", `String result_schema
            ; "ok", `Bool false
            ; "error", `String "execution requires the confirm token"
            ])
;;
