(** Admin-only fleet event-queue preview and exact-selection cancellation.
    Execution revalidates the selected incarnations before writing its target
    record. New arrivals outside that selection never acquire cancel authority.
    The record contains identity metadata, not a restorable queue snapshot. *)

module Http = Http_server_eio
module Execute = Server_dashboard_http_keeper_event_queue_operator_execute

let ( let* ) = Result.bind
let schema = "keeper_event_queue.bulk.request.v2"
let result_schema = "keeper_event_queue.bulk.result.v2"
let permission = Masc_domain.CanAdmin

type filter =
  { keepers : string list option
  ; sources : string list option
  }

type selection =
  { keeper_name : string
  ; source_ref : string
  ; source_incarnation : int64
  }

type request =
  | Preview of filter
  | Cancel of { filter : filter; reason : string; selections : selection list }

type row =
  { keeper_name : string
  ; source_ref : string
  ; source_incarnation : int64
  ; source_label : string
  ; source_arrived_at : float
  ; first_admitted_at : float option
  }

type row_status =
  | Cancelled
  | Committed_followup_failed
  | Failed of string

type row_result =
  { row : row
  ; status : row_status
  ; response : Yojson.Safe.t option
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

let object_fields = function
  | `Assoc fields ->
    let keys = List.map fst fields in
    if List.length keys = List.length (List.sort_uniq String.compare keys)
    then Ok fields
    else Error "object contains duplicate fields"
  | _ -> Error "expected an object"
;;

let exact_fields expected fields =
  if List.sort String.compare (List.map fst fields) = List.sort String.compare expected
  then Ok ()
  else Error ("fields must be exactly [" ^ String.concat ", " expected ^ "]")
;;

let optional_strings name fields =
  match List.assoc_opt name fields with
  | None -> Ok None
  | Some (`List values) ->
    let rec loop seen = function
      | [] -> Ok (Some (List.rev seen))
      | `String value :: rest
        when value <> "" && String.equal value (String.trim value)
             && not (List.mem value seen) -> loop (value :: seen) rest
      | _ -> Error (name ^ " must contain distinct, non-empty, trimmed strings")
    in
    loop [] values
  | Some _ -> Error (name ^ " must be a list of strings")
;;

let parse_filter value =
  let* fields = object_fields value in
  let* () =
    if List.for_all (fun (key, _) -> List.mem key [ "keepers"; "sources" ]) fields
    then Ok ()
    else Error "filter only accepts keepers and sources"
  in
  let* keepers = optional_strings "keepers" fields in
  let* sources = optional_strings "sources" fields in
  Ok { keepers; sources }
;;

let parse_selection value =
  let* fields = object_fields value in
  let* () = exact_fields [ "keeper_name"; "source_ref"; "source_incarnation" ] fields in
  let* keeper_name = string_field "keeper_name" fields in
  let* source_ref = string_field "source_ref" fields in
  let* incarnation = string_field "source_incarnation" fields in
  let* source_incarnation =
    match Int64.of_string_opt incarnation with
    | Some value when Int64.compare value 0L >= 0
                      && String.equal incarnation (Int64.to_string value) -> Ok value
    | Some _ | None -> Error "source_incarnation must be a non-negative decimal int64 string"
  in
  if not (Keeper_config.validate_name keeper_name)
  then Error "invalid keeper_name"
  else if String.length source_ref <> 64
          || not (String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) source_ref)
  then Error "source_ref must be exactly 64 lowercase hexadecimal characters"
  else Ok { keeper_name; source_ref; source_incarnation }
;;

module Selection_map = Map.Make (struct
    type t = string * string * int64
    let compare = Stdlib.compare
  end)

let selection_key (selection : selection) =
  selection.keeper_name, selection.source_ref, selection.source_incarnation
;;

let row_key (row : row) = row.keeper_name, row.source_ref, row.source_incarnation

let parse_selections = function
  | `List values when values <> [] ->
    let rec loop seen acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        let* selection = parse_selection value in
        let key = selection_key selection in
        if Selection_map.mem key seen
        then Error "selections contains a duplicate row"
        else loop (Selection_map.add key () seen) (selection :: acc) rest
    in
    loop Selection_map.empty [] values
  | _ -> Error "selections must be a non-empty list"
;;

let parse body =
  let* value =
    try Ok (Yojson.Safe.from_string body)
    with Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
  in
  let* fields = object_fields value in
  let* request_schema = string_field "schema" fields in
  if not (String.equal request_schema schema)
  then Error ("unsupported schema: " ^ request_schema)
  else
    let* action = string_field "action" fields in
    let* filter_value = field "filter" fields in
    let* filter = parse_filter filter_value in
    match action with
    | "preview" ->
      let* () = exact_fields [ "schema"; "action"; "filter" ] fields in
      Ok (Preview filter)
    | "cancel" ->
      let* () = exact_fields [ "schema"; "action"; "filter"; "reason"; "selections" ] fields in
      let* reason = string_field "reason" fields in
      if reason = "" || not (String.equal reason (String.trim reason))
      then Error "reason must be non-empty and trimmed"
      else
        let* selection_values = field "selections" fields in
        let* selections = parse_selections selection_values in
        Ok (Cancel { filter; reason; selections })
    | _ -> Error ("unknown event queue bulk action: " ^ action)
;;

(* Never report an unreadable queue as an empty fleet. *)
let rows_for_keeper ~base_path keeper_name =
  match Keeper_event_queue_persistence.load_state_result ~base_path ~keeper_name with
  | Error detail -> Error (Printf.sprintf "keeper %s: queue read failed: %s" keeper_name detail)
  | Ok state ->
    Ok (Keeper_event_queue_state.pending_selections state
        |> List.map (fun (selection : Keeper_event_queue_state.pending_selection) ->
          { keeper_name
          ; source_ref = Keeper_event_queue_state.source_snapshot_ref selection.source
          ; source_incarnation = selection.admitted_revision
          ; source_label = Keeper_event_queue.payload_kind_label selection.source.payload
          ; source_arrived_at = selection.source.arrived_at
          ; first_admitted_at = selection.first_admitted_at
          }))
;;

let all_rows config =
  let base_path = config.Workspace.base_path in
  let* keeper_names = Keeper_meta_store.keeper_names_result config in
  let rec loop acc = function
    | [] -> Ok (List.concat (List.rev acc))
    | keeper_name :: rest ->
      let* rows = rows_for_keeper ~base_path keeper_name in
      loop (rows :: acc) rest
  in
  loop [] keeper_names
;;

let row_matches filter (row : row) =
  (match filter.keepers with None -> true | Some names -> List.mem row.keeper_name names)
  && (match filter.sources with None -> true | Some kinds -> List.mem row.source_label kinds)
;;

let plan_rows filter rows = List.filter (row_matches filter) rows

let select_rows filter selections rows =
  let current =
    List.fold_left (fun map row -> Selection_map.add (row_key row) row map)
      Selection_map.empty rows
  in
  let rec loop seen acc = function
    | [] -> Ok (List.rev acc)
    | selection :: rest ->
      let key = selection_key selection in
      if Selection_map.mem key seen
      then Error "selections contains a duplicate row"
      else
        match Selection_map.find_opt key current with
        | Some row when row_matches filter row ->
          loop (Selection_map.add key () seen) (row :: acc) rest
        | Some _ -> Error "a selected row is outside the filter; preview again"
        | None -> Error "a selected row changed or left the queue; preview again"
  in
  loop Selection_map.empty [] selections
;;

module String_map = Map.Make (String)

let count_by key rows =
  List.fold_left
    (fun acc row ->
      let k = key row in
      let seen = match String_map.find_opt k acc with Some n -> n | None -> 0 in
      String_map.add k (seen + 1) acc)
    String_map.empty rows
  |> String_map.bindings
;;

let oldest_age_seconds rows =
  let now = Time_compat.now () in
  let rec oldest observed = function
    | [] -> Option.map (fun at -> now -. at) observed
    | { first_admitted_at = None; _ } :: _ -> None
    | { first_admitted_at = Some at; _ } :: rest ->
      if not (Float.is_finite at) || at > now
      then None
      else oldest (Some (match observed with None -> at | Some before -> Float.min before at)) rest
  in
  if Float.is_finite now then oldest None rows else None
;;

let row_json (row : row) =
  `Assoc
    [ "keeper_name", `String row.keeper_name
    ; "source", `String row.source_label
    ; "source_ref", `String row.source_ref
    ; "source_incarnation", `String (Int64.to_string row.source_incarnation)
    ; "state", `String "pending"
    ; "source_arrived_at", `Float row.source_arrived_at
    ; "first_admitted_at", Json_util.float_opt_to_json row.first_admitted_at
    ]
;;

let counts_json counts = `Assoc (List.map (fun (key, count) -> key, `Int count) counts)

(* The operation id is an opaque correlation identifier for one bulk request,
   not an authentication secret; [Random_id.uuid_v7] wraps the process crypto
   RNG boundary. *)
let fresh_operation_id () = Random_id.uuid_v7 ()
;;

let backup_path ~base_path operation_id =
  Filename.concat
    (Config_dir_resolver.event_queue_bulk_backups_dir ~base_path)
    (operation_id ^ ".json")
;;

(* The backup folder does not exist until the first bulk operation, and the
   atomic write stages its file inside the folder it is given, so the folder
   is made here. Without it every confirmed bulk cancel on a workspace that
   had never run one ended in "backup write failed" and cancelled nothing. *)
let write_backup ~base_path ~operation_id backup =
  let path = backup_path ~base_path operation_id in
  match Fs_compat.mkdir_p (Filename.dirname path) with
  | exception Sys_error detail -> Error detail
  | () ->
    Fs_compat.save_file_atomic_strict path (Yojson.Safe.to_string backup)
    |> Result.map (fun () -> path)
;;

let cancel_row ~config ~operation_id ~reason (row : row) =
  let operator_operation_id =
    Printf.sprintf "bulk:%s:%s:%s:%s" operation_id row.keeper_name row.source_ref
      (Int64.to_string row.source_incarnation)
  in
  match Execute.run ~config ~keeper_name:row.keeper_name
          (Execute.Cancel { source_ref = row.source_ref
                          ; source_incarnation = row.source_incarnation
                          ; operator_operation_id; reason }) with
  | Error detail -> { row; status = Failed detail; response = None }
  | Ok outcome ->
    { row
    ; status = (match outcome.Execute.completion with
                | Execute.Complete -> Cancelled
                | Execute.Committed_followup_failed -> Committed_followup_failed)
    ; response = Some outcome.response
    }
;;

let execute_rows ~cancel ~operation_id ~reason rows =
  List.map (cancel ~operation_id ~reason) rows
;;

let row_result_json result =
  let status, error =
    match result.status with
    | Cancelled -> "cancelled", []
    | Committed_followup_failed -> "committed_followup_failed", []
    | Failed detail -> "failed", [ "error", `String detail ]
  in
  `Assoc
    ([ "row", row_json result.row; "status", `String status ]
     @ error
     @ (match result.response with None -> [] | Some response -> [ "result", response ]))
;;

let preview_json rows =
  `Assoc
    [ "schema", `String result_schema; "ok", `Bool true; "action", `String "preview"
    ; "would_cancel", `Int (List.length rows)
    ; "keeper_counts", counts_json (count_by (fun (row : row) -> row.keeper_name) rows)
    ; "source_counts", counts_json (count_by (fun row -> row.source_label) rows)
    ; "oldest_age_seconds", Json_util.float_opt_to_json (oldest_age_seconds rows)
    ; "rows", `List (List.map row_json rows)
    ]
;;

let handle_post state ~actor:_ req reqd body =
  let respond ?(status = `OK) json =
    Http.Response.json_value ~status ~request:req json reqd
  in
  let reject status detail =
    respond ~status (`Assoc [ "schema", `String result_schema; "ok", `Bool false
                            ; "error", `String detail ])
  in
  match parse body with
  | Error detail -> reject `Bad_request detail
  | Ok request ->
    let config = Mcp_server.workspace_config state in
    (match all_rows config with
     | Error detail -> reject `Internal_server_error detail
     | Ok all ->
       match request with
       | Preview filter -> respond (preview_json (plan_rows filter all))
       | Cancel { filter; reason; selections } ->
         match select_rows filter selections all with
         | Error detail -> reject `Conflict detail
         | Ok rows ->
           let operation_id = fresh_operation_id () in
           let backup =
             `Assoc [ "schema", `String result_schema; "operation_id", `String operation_id
                    ; "reason", `String reason; "rows", `List (List.map row_json rows) ]
           in
           match write_backup ~base_path:config.Workspace.base_path ~operation_id backup with
           | Error detail -> reject `Internal_server_error ("backup write failed: " ^ detail)
           | Ok path ->
             let results = execute_rows ~cancel:(cancel_row ~config) ~operation_id ~reason rows in
             let cancelled, followup_failed, failed =
               List.fold_left (fun (cancelled, followup, failed) result ->
                 match result.status with
                 | Cancelled -> cancelled + 1, followup, failed
                 | Committed_followup_failed -> cancelled, followup + 1, failed
                 | Failed _ -> cancelled, followup, failed + 1)
                 (0, 0, 0) results
             in
             respond (`Assoc
               [ "schema", `String result_schema; "ok", `Bool true; "action", `String "cancel"
               ; "operation_id", `String operation_id; "backup_path", `String path
               ; "requested", `Int (List.length rows); "cancelled", `Int cancelled
               ; "committed_followup_failed", `Int followup_failed; "failed", `Int failed
               ; "results", `List (List.map row_result_json results) ]))
;;
