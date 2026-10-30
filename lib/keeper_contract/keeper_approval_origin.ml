open Result.Syntax

type admitted_source =
  { snapshot_ref : string
  ; admitted_revision : int64
  ; board_post_id : string option
  }

type logical_source =
  | Direct_operation of Keeper_operation_id.t
  | Admitted_sources of admitted_source list
  | No_admitted_source

type t =
  { source : logical_source
  ; turn_ref : Ids.Turn_ref.t option
  }

let unavailable = { source = No_admitted_source; turn_ref = None }

let valid_snapshot_ref text =
  String.length text = 64
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) text

let admitted_source ~snapshot_ref ~admitted_revision ~board_post_id =
  if not (valid_snapshot_ref snapshot_ref) then
    Error "approval origin snapshot_ref must be a lowercase SHA-256"
  else if admitted_revision < 0L then
    Error "approval origin admitted_revision must not be negative"
  else if Option.exists (fun id -> String.trim id = "" || String.trim id <> id) board_post_id then
    Error "approval origin board_post_id must be a nonblank canonical string"
  else Ok { snapshot_ref; admitted_revision; board_post_id }

let direct_operation ~operation_id ~turn_ref =
  { source = Direct_operation operation_id; turn_ref = Some turn_ref }

let compare_source left right =
  match String.compare left.snapshot_ref right.snapshot_ref with
  | 0 -> Int64.compare left.admitted_revision right.admitted_revision
  | order -> order

let admitted_sources ~sources ~turn_ref =
  let sources = List.sort compare_source sources in
  let rec distinct = function
    | [] | [ _ ] -> Ok ()
    | first :: (second :: _ as rest) ->
      if compare_source first second = 0 then Error "approval origin repeats an exact admitted source"
      else distinct rest
  in
  match sources with
  | [] -> Error "approval origin admitted_sources must not be empty"
  | _ :: _ ->
    let* () = distinct sources in
    Ok { source = Admitted_sources sources; turn_ref = Some turn_ref }

let same_logical_source left right =
  match left.source, right.source with
  | Direct_operation left, Direct_operation right ->
    String.equal (Keeper_operation_id.to_string left) (Keeper_operation_id.to_string right)
  | Admitted_sources left, Admitted_sources right ->
    List.equal (fun left right -> compare_source left right = 0 && left.board_post_id = right.board_post_id) left right
  (* Intended: unknown sources keep the pre-origin identity, so a next-turn retry still
     folds onto one approval (#28866). The grant stays one-shot for the exact input. *)
  | No_admitted_source, No_admitted_source -> true
  | Direct_operation _, (Admitted_sources _ | No_admitted_source)
  | Admitted_sources _, (Direct_operation _ | No_admitted_source)
  | No_admitted_source, (Direct_operation _ | Admitted_sources _) -> false

let source_to_yojson source =
  `Assoc
    [ "snapshot_ref", `String source.snapshot_ref
    ; "admitted_revision", `String (Int64.to_string source.admitted_revision)
    ; "board_post_id", (match source.board_post_id with Some id -> `String id | None -> `Null)
    ]

let to_yojson origin =
  let source = match origin.source with
    | Direct_operation id ->
      `Assoc [ "kind", `String "direct_operation"; "operation_id", `String (Keeper_operation_id.to_string id) ]
    | Admitted_sources sources ->
      `Assoc [ "kind", `String "admitted_sources"; "sources", `List (List.map source_to_yojson sources) ]
    | No_admitted_source -> `Assoc [ "kind", `String "no_admitted_source" ]
  in
  `Assoc
    [ "source", source
    ; "turn_ref", (match origin.turn_ref with Some value -> Ids.Turn_ref.to_yojson value | None -> `Null)
    ]

let fields expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare expected -> Ok fields
  | `Assoc _ -> Error "approval origin has missing, duplicate or unexpected fields"
  | _ -> Error "approval origin must be an object"

let string name fields = match List.assoc name fields with
  | `String value -> Ok value
  | _ -> Error ("approval origin " ^ name ^ " must be a string")

let source_of_yojson json =
  let* fields = fields [ "snapshot_ref"; "admitted_revision"; "board_post_id" ] json in
  let* snapshot_ref = string "snapshot_ref" fields in
  let* revision = string "admitted_revision" fields in
  let* admitted_revision =
    match Int64.of_string_opt revision with
    | Some value when Int64.to_string value = revision -> Ok value
    | Some _ | None -> Error "approval origin admitted_revision must be a canonical int64 string"
  in
  let* board_post_id = match List.assoc "board_post_id" fields with
    | `Null -> Ok None
    | `String id -> Ok (Some id)
    | _ -> Error "approval origin board_post_id must be a string or null"
  in
  admitted_source ~snapshot_ref ~admitted_revision ~board_post_id

let of_yojson json =
  let* outer = fields [ "source"; "turn_ref" ] json in
  let* turn_ref = match List.assoc "turn_ref" outer with
    | `Null -> Ok None
    | `String text ->
      (match Ids.Turn_ref.of_string text with
       | Some value -> Ok (Some value)
       | None -> Error "approval origin turn_ref is invalid")
    | _ -> Error "approval origin turn_ref must be a string or null"
  in
  let source_json = List.assoc "source" outer in
  let* kind = match source_json with
    | `Assoc fields ->
      (match List.assoc_opt "kind" fields with Some (`String kind) -> Ok kind | Some _ | None -> Error "approval origin source kind is required")
    | _ -> Error "approval origin source must be an object"
  in
  match kind, turn_ref with
  | "no_admitted_source", None ->
    let* _ = fields [ "kind" ] source_json in
    Ok unavailable
  | "direct_operation", Some turn_ref ->
    let* fields = fields [ "kind"; "operation_id" ] source_json in
    let* text = string "operation_id" fields in
    let* operation_id = Keeper_operation_id.of_string text in
    Ok (direct_operation ~operation_id ~turn_ref)
  | "admitted_sources", Some turn_ref ->
    let* fields = fields [ "kind"; "sources" ] source_json in
    let* sources = match List.assoc "sources" fields with
      | `List values ->
        List.fold_left (fun state value -> let* sources = state in let* source = source_of_yojson value in Ok (source :: sources)) (Ok []) values
      | _ -> Error "approval origin sources must be an array"
    in
    admitted_sources ~sources ~turn_ref
  | "no_admitted_source", Some _ -> Error "unavailable approval origin must not invent a turn witness"
  | ("direct_operation" | "admitted_sources"), None -> Error "admitted approval origin requires its original turn witness"
  | _, (Some _ | None) -> Error "unknown approval origin kind"

type admission =
  | Direct_request of Keeper_operation_id.t
  | Admitted of Keeper_event_queue_state.pending_selection list
  | Unavailable

let from_admission admission ~turn_ref =
  match admission with
  | Direct_request operation_id -> Ok (direct_operation ~operation_id ~turn_ref)
  | Unavailable | Admitted [] -> Ok unavailable
  | Admitted (_ :: _ as selections) ->
    let* sources =
      List.fold_left
        (fun state (selection : Keeper_event_queue_state.pending_selection) ->
           let* sources = state in
           let board_post_id = match selection.source.payload with
             | Keeper_event_queue.Board_signal _ | Board_attention _ -> Some selection.source.post_id
             | Bootstrap | Fusion_completed _ | Schedule_due _ | Connector_attention _
             | Hitl_resolved _ | Ask_answered _ | Completion_authority_rejected _
             | Task_cancelled _ | Workspace_message _ | Delegate_completed _
             | Composition_completed _ | Tool_result_ready _ | Owned_job_completed _ | Addon_operation_changed _ | Task_outcome _ -> None
           in
           let* source = admitted_source
               ~snapshot_ref:(Keeper_event_queue_state.source_snapshot_ref selection.source)
               ~admitted_revision:selection.admitted_revision ~board_post_id in
           Ok (source :: sources))
        (Ok []) selections
    in
    admitted_sources ~sources ~turn_ref
