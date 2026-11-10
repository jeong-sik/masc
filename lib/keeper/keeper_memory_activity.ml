open Result.Syntax
module Memory = Keeper_memory_os_types
module Current = Keeper_memory_os_current
module Codec = Keeper_memory_os_journal_codec
module Program = Keeper_memory_os_program_types

type kind = Created | Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated
type fact = { memory_id : string; claim : string }
type event =
  { identity : string; recorded_at : float; revision : int; kind : kind
  ; before : fact list; after : fact list; reason : string option }
type t = { limit : int; journal_lines : int; events : event list; notes : string list }

let reference (fact : Memory.fact) =
  { memory_id = Memory.memory_id fact; claim = fact.claim }

let changes ~identity ~recorded_at ~revision ~source ~before ~after
    ~(links : Memory.revision list) ~(absorbed : Memory.absorbed_statement list)
    ~(dropped : Memory.dropped_statement list) ~invalidated =
  let find id facts = List.find_opt (fun fact -> Memory.memory_id fact = id) facts in
  let contains id facts = Option.is_some (find id facts) in
  let removed = List.filter (fun fact -> not (contains (Memory.memory_id fact) after)) before in
  let added = List.filter (fun fact -> not (contains (Memory.memory_id fact) before)) after in
  let make suffix kind before after reason =
    { identity = identity ^ ":" ^ suffix; recorded_at; revision; kind
    ; before = List.map reference before; after = List.map reference after; reason } in
  let related =
    List.filter_map (fun (link : Memory.revision) ->
      match find link.superseded removed, find link.superseded_by after with
      | Some old, Some successor ->
          Some (make ("revision:" ^ link.superseded) Revised [old] [successor] None)
      | None, _ | _, None -> None) links
    @ (List.map (fun (link : Memory.absorbed_statement) -> link.into) absorbed
       |> List.sort_uniq String.compare
       |> List.filter_map (fun into ->
         let originals = List.filter_map (fun (link : Memory.absorbed_statement) ->
           if link.into = into then find link.absorbed removed else None) absorbed in
         match originals, find into after with
         | [], _ | _, None -> None
         | originals, Some successor ->
             Some (make ("absorb:" ^ into) Absorbed originals [successor] None))) in
  let handled id side = List.exists (fun event ->
    List.exists (fun fact -> fact.memory_id = id) (side event)) related in
  let removals = List.filter_map (fun fact ->
    let id = Memory.memory_id fact in
    if handled id (fun event -> event.before) then None else
    let kind = if List.mem id invalidated then Invalidated else
      match source with Current.Explicit_retract -> Retracted
      | Current.Librarian | Current.Explicit_write -> Removed in
    let reason = Option.map (fun (row : Memory.dropped_statement) -> row.reason)
        (List.find_opt (fun (row : Memory.dropped_statement) -> row.memory_id = id) dropped) in
    Some (make ("remove:" ^ id) kind [fact] [] reason)) removed in
  let additions = List.filter_map (fun fact ->
    let id = Memory.memory_id fact in
    if handled id (fun event -> event.after) then None
    else Some (make ("add:" ^ id) Created [] [fact] None)) added in
  let updates = List.filter_map (fun (fact : Memory.fact) ->
    match find (Memory.memory_id fact) before with
    | Some old when fact.last_seen > old.last_seen ->
        Some (make ("seen:" ^ Memory.memory_id fact) Reobserved [old] [fact] None)
    | Some _ | None -> None) after in
  related @ removals @ additions @ updates

let project ~identity ~absorbed json =
  let* entry = Codec.journal_entry_of_json json in
  match entry with
  | Current.Journal_failed _ | Current.Journal_quarantined _ -> Ok []
  | Current.Journal_committed {recorded_at; revision; source; change; dropped; program} ->
    let fields = match json with `Assoc fields -> fields | _ -> [] in
    let* transition = Codec.journal_commit_effect fields in
    match transition with
    | Some Current.Unchanged -> Ok []
    | None -> Error (Printf.sprintf "revision %d: snapshot transition not recorded" revision)
    | Some Current.Rewritten ->
      match program with
      | Some publication ->
        Ok (List.concat_map (fun (stage : Program.stage) ->
          changes ~identity:(identity ^ ":stage:" ^ string_of_int stage.index)
            ~recorded_at ~revision ~source:source.kind
            ~before:stage.before ~after:stage.after ~links:stage.revisions_applied
            ~absorbed:stage.absorbed_applied ~dropped:stage.decision.dropped
            ~invalidated:(List.map (fun (row : Program.invalidation) ->
              Memory.memory_id row.fact) stage.invalidated)) publication.execution.stages)
      | None ->
        let* links = Codec.journal_revision_links fields in
        (* An archive append precedes publication. Require the committed
           transition itself to contain both exact endpoints of that pass. *)
        let absorbed = List.filter_map (fun (row : Keeper_memory_absorbed.record) ->
          if row.trace_id = source.trace_id && row.recorded_at = recorded_at
             && List.exists (fun fact -> Memory.memory_id fact = row.memory_id) change.removed
             && List.exists (fun fact -> Memory.memory_id fact = row.into) change.added
          then Some Memory.{absorbed = row.memory_id; into = row.into} else None) absorbed
          |> List.sort_uniq (fun a b ->
            compare (a.Memory.absorbed, a.into) (b.Memory.absorbed, b.into)) in
        Ok (changes ~identity ~recorded_at ~revision ~source:source.kind
          ~before:change.removed ~after:change.added ~links:(Option.value links ~default:[])
          ~absorbed ~dropped:(Option.value dropped ~default:[])
          ~invalidated:(List.map (fun (row : Current.support_invalidation) ->
            Memory.memory_id row.fact) change.invalidated))

let read_inline ~keepers_dir ~keeper_id ~limit =
  let path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let archive, archive_notes = match Keeper_memory_absorbed.read ~keepers_dir ~keeper_id with
    | Error reason -> [], [reason]
    | Ok rows -> List.fold_left (fun (facts, notes) (index, row) -> match row with
        | Ok record -> record :: facts, notes
        | Error error -> facts, (Printf.sprintf "absorption line %d: %s" index
            (Keeper_memory_absorbed.read_error_to_string error)) :: notes) ([], []) rows in
  let rows =
    try Ok (Dated_jsonl.map_tail_rows path ~max_lines:limit ~f:(fun {Dated_jsonl.offset; line} ->
      let identity = Printf.sprintf "memory:%s:%d" keeper_id offset in
      let result = match Yojson.Safe.from_string line with
        | json -> project ~identity ~absorbed:archive json
        | exception Yojson.Json_error reason -> Error reason in
      offset, result))
    with
    | Sys_error reason -> Error reason
    | Unix.Unix_error (error, op, arg) ->
        Error (Printf.sprintf "%s %s: %s" op arg (Unix.error_message error)) in
  match rows with
  | Error reason -> {limit; journal_lines = 0; events = []; notes = reason :: archive_notes}
  | Ok rows ->
    let events, notes = List.fold_left (fun (events, notes) (offset, row) -> match row with
      | Ok next -> List.rev_append next events, notes
      | Error reason -> events, (Printf.sprintf "journal byte %d: %s" offset reason) :: notes)
        ([], archive_notes) rows in
    {limit; journal_lines = List.length rows; events = List.rev events; notes = List.rev notes}

let read ~keepers_dir ~keeper_id ~limit =
  Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
    read_inline ~keepers_dir ~keeper_id ~limit)

let kind_to_string = function
  | Created -> "created" | Reobserved -> "reobserved" | Revised -> "revised"
  | Absorbed -> "absorbed" | Retracted -> "retracted" | Removed -> "removed"
  | Invalidated -> "invalidated"

let fact_to_json fact = `Assoc ["memory_id", `String fact.memory_id; "claim", `String fact.claim]
let event_to_json event = `Assoc
  [ "identity", `String event.identity; "recorded_at", `Float event.recorded_at
  ; "revision", `Int event.revision; "kind", `String (kind_to_string event.kind)
  ; "before", `List (List.map fact_to_json event.before)
  ; "after", `List (List.map fact_to_json event.after)
  ; "reason", (match event.reason with None -> `Null | Some reason -> `String reason) ]
let to_json activity = `Assoc
  [ "limit", `Int activity.limit; "journal_lines", `Int activity.journal_lines
  ; "events", `List (List.map event_to_json activity.events)
  ; "notes", `List (List.map (fun note -> `String note) activity.notes) ]

let of_json json =
  let open Tui_decode_fields in
  let fact json =
    let* memory_id = required_string_field json "memory_id" in
    let* claim = required_string_field json "claim" in
    if Memory.is_memory_id memory_id then Ok {memory_id; claim}
    else Error "invalid activity memory identity" in
  let event json =
    let* identity = required_string_field json "identity" in
    let* recorded_at = Json_util.require_float json "recorded_at" in
    let* revision = required_int_field json "revision" in
    let* token = required_string_field json "kind" in
    let* kind = match token with
      | "created" -> Ok Created | "reobserved" -> Ok Reobserved | "revised" -> Ok Revised
      | "absorbed" -> Ok Absorbed | "retracted" -> Ok Retracted | "removed" -> Ok Removed
      | "invalidated" -> Ok Invalidated | _ -> Error ("unknown memory activity kind: " ^ token) in
    let* before_rows = required_list_field json "before" in
    let* before = decode_list "before" fact before_rows in
    let* after_rows = required_list_field json "after" in
    let* after = decode_list "after" fact after_rows in
    let* reason = optional_string_field json "reason" in
    if Float.is_finite recorded_at && recorded_at >= 0. && revision >= 0 && identity <> ""
    then Ok {identity; recorded_at; revision; kind; before; after; reason}
    else Error "invalid memory activity clock or identity" in
  let* limit = required_int_field json "limit" in
  let* journal_lines = required_int_field json "journal_lines" in
  let* rows = required_list_field json "events" in
  let* events = decode_list "events" event rows in
  let* notes = require_string_list json "notes" in
  if limit > 0 && journal_lines >= 0 && journal_lines <= limit
  then Ok {limit; journal_lines; events; notes}
  else Error "invalid memory activity window"
