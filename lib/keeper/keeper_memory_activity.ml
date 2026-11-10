open Result.Syntax
module Memory = Keeper_memory_os_types
module Current = Keeper_memory_os_current_types
module Store = Keeper_memory_os_current
module Snapshot = Keeper_memory_os_snapshot_codec
module Journal = Keeper_memory_os_current_journal
module Codec = Keeper_memory_os_journal_codec
module Program = Keeper_memory_os_program_types

type kind = Created | Reobserved | Revised | Absorbed | Retracted | Removed | Invalidated | Relation_unavailable
type fact = { memory_id : string; claim : string option }
type event =
  { identity : string; recorded_at : float; revision : int; kind : kind
  ; before : fact list; after : fact list; reason : string option }
type t = { limit : int; journal_lines : int; events : event list; notes : string list }

let reference (fact : Memory.fact) =
  { memory_id = Memory.memory_id fact; claim = Some fact.claim }

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
          Some (make ("revision:" ^ link.superseded ^ ":" ^ link.superseded_by) Revised [old] [successor] None)
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

let project_entry ?snapshot ?archive_error ~identity ~absorbed json entry =
  match entry with
  | Current.Journal_failed _ | Current.Journal_quarantined _ -> Ok []
  | Current.Journal_committed {recorded_at; revision; source; change; dropped; program} ->
    let* () = if Float.is_finite recorded_at && recorded_at >= 0.
      then Ok () else Error "invalid journal observation clock" in
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
        let links = Option.value links ~default:[] in
        let matches (observed : Current.t) = observed.revision = revision
          && observed.updated_at = recorded_at && observed.source = source && observed.change = change in
        let final_facts = match snapshot with
          | Some observed when matches observed -> observed.facts
          | Some _ | None -> change.added in
        let find id facts = List.find_opt (fun fact -> Memory.memory_id fact = id) facts in
        let archive = List.filter (fun (row : Keeper_memory_absorbed.record) ->
          row.trace_id = source.trace_id && row.recorded_at = recorded_at
          && match find row.memory_id change.removed with
             | None -> false | Some original -> original = row.fact) absorbed in
        let absorptions = List.map (fun (row : Keeper_memory_absorbed.record) ->
            Memory.{absorbed = row.memory_id; into = row.into}) archive
          |> List.sort_uniq (fun a b ->
            compare (a.Memory.absorbed, a.into) (b.Memory.absorbed, b.into)) in
        let invalidated = List.map (fun (row : Current.support_invalidation) ->
            Memory.memory_id row.fact) change.invalidated in
        let dropped = Option.value dropped ~default:[] in
        let candidates = List.map (fun (link : Memory.revision) -> link.superseded, link.superseded_by) links
          @ List.map (fun (link : Memory.absorbed_statement) -> link.absorbed, link.into) absorptions
          |> List.sort_uniq compare in
        let unresolved = List.filter_map (fun (from_id, into_id) ->
          match find from_id change.removed, find from_id final_facts, find into_id final_facts with
          | Some original, None, None -> Some
              {identity = identity ^ ":unresolved:" ^ from_id ^ ":" ^ into_id;
               recorded_at; revision; kind = Relation_unavailable;
               before = [reference original]; after = [{memory_id = into_id; claim = None}];
               reason = Some "retained successor is not proven by this historical transition"}
          | None, _, _ | _, Some _, _ | _, _, Some _ -> None) candidates in
        let unresolved = match archive_error, source.kind with
          | None, _ | Some _, (Current.Explicit_write | Current.Explicit_retract) -> unresolved
          | Some reason, Current.Librarian ->
            List.filter_map (fun original ->
              let id = Memory.memory_id original in
              if Option.is_some (find id final_facts) || List.mem id invalidated
                 || List.exists (fun (row : Memory.dropped_statement) -> row.memory_id = id) dropped
                 || List.exists (fun (from_id, _) -> from_id = id) candidates
              then None else Some
                {identity = identity ^ ":unresolved:" ^ id; recorded_at; revision;
                 kind = Relation_unavailable; before = [reference original]; after = []; reason = Some reason})
              change.removed @ unresolved in
        (* Full matching current facts supply retained targets; keeping those
           same facts on both sides does not invent new creation events. *)
        let retained = List.filter (fun fact -> Option.is_none (find (Memory.memory_id fact) change.added)) final_facts in
        let confirmed = changes ~identity ~recorded_at ~revision ~source:source.kind
          ~before:(change.removed @ retained) ~after:final_facts ~links ~absorbed:absorptions
          ~dropped ~invalidated in
        let unknown_source id = List.exists (fun event ->
          List.exists (fun fact -> fact.memory_id = id) event.before) unresolved in
        Ok (List.filter (fun event -> match event.kind, event.before with
          | Removed, [fact] -> not (unknown_source fact.memory_id)
          | (Created | Reobserved | Revised | Absorbed | Retracted | Invalidated | Relation_unavailable), _
          | Removed, ([] | _ :: _ :: _) -> true) confirmed @ unresolved)

let project ?snapshot ?archive_error ~identity ~absorbed json =
  (* The installed public store interface seals its concrete types. Cross
     that interface through the canonical validated snapshot wire format;
     production reads below already hold the internal guarded model. *)
  let* snapshot = match snapshot with
    | None -> Ok None
    | Some snapshot ->
      let+ snapshot = Snapshot.of_json (Store.to_json snapshot)
        |> Result.map_error Snapshot.snapshot_rejection_to_string in
      Some snapshot in
  let* entry = Codec.journal_entry_of_json json in
  project_entry ?snapshot ?archive_error ~identity ~absorbed json entry

module Archive_index = Map.Make (struct type t = string * float let compare = compare end)

let read_inline ~keepers_dir ~keeper_id ~limit =
  let path = Keeper_memory_os_current_layout.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  (* Fix the journal window first: a commit visible here has already appended
     its absorption rows. A concurrent later commit cannot enter this window. *)
  let rows =
    try Ok (Dated_jsonl.map_tail_rows path ~max_lines:limit ~f:(fun {Dated_jsonl.offset; line} ->
      let result = match Yojson.Safe.from_string line with
        | json -> Result.map (fun entry -> json, entry) (Codec.journal_entry_of_json json)
        | exception Yojson.Json_error reason -> Error reason in
      offset, result))
    with
    | Sys_error reason -> Error reason
    | Unix.Unix_error (error, op, arg) ->
        Error (Printf.sprintf "%s %s: %s" op arg (Unix.error_message error)) in
  match rows with
  | Error reason -> {limit; journal_lines = 0; events = []; notes = [reason]}
  | Ok rows ->
    let legacy_rewrite = function
      | _, Ok (`Assoc fields, Current.Journal_committed {program = None; change; _}) ->
          List.exists (fun original ->
            not (List.exists (fun added -> Memory.memory_id original = Memory.memory_id added) change.added))
            change.removed
          && Codec.journal_commit_effect fields = Ok (Some Current.Rewritten)
      | _, (Error _ | Ok (_, (Current.Journal_committed _
          | Current.Journal_failed _ | Current.Journal_quarantined _))) -> false in
    let needs_legacy = List.exists legacy_rewrite rows in
    let needs_archive = List.exists (fun row -> legacy_rewrite row && match row with
      | _, Ok (_, Current.Journal_committed {source; _}) -> source.kind = Current.Librarian
      | _, (Error _ | Ok (_, (Current.Journal_failed _ | Current.Journal_quarantined _))) -> false) rows in
    let archive, archive_notes =
      if not needs_archive then [], [] else
      match Keeper_memory_absorbed.read ~keepers_dir ~keeper_id with
      | Error reason -> [], [reason]
      | Ok records -> List.fold_left (fun (facts, notes) (index, row) -> match row with
          | Ok record -> record :: facts, notes
          | Error error -> facts, (Printf.sprintf "absorption line %d: %s" index
              (Keeper_memory_absorbed.read_error_to_string error)) :: notes) ([], []) records in
    let index = List.fold_left (fun index (row : Keeper_memory_absorbed.record) ->
      Archive_index.update (row.trace_id, row.recorded_at)
        (fun previous -> Some (row :: Option.value previous ~default:[])) index) Archive_index.empty archive in
    let snapshot = if not needs_legacy then None else
      match Journal.read_classified ~keepers_dir ~keeper_id with
      | Journal.Readable snapshot -> Some snapshot
      | Journal.No_snapshot | Journal.Undecodable _ | Journal.Io_unreadable _ -> None in
    let events, notes = List.fold_left (fun (events, notes) (offset, row) ->
      let identity = Printf.sprintf "memory:%s:%d" keeper_id offset in
      let result = match row with
        | Error reason -> Error reason
        | Ok (json, entry) ->
          let absorbed = match entry with
            | Current.Journal_committed {source; recorded_at; _} ->
                Option.value (Archive_index.find_opt (source.trace_id, recorded_at) index) ~default:[]
            | Current.Journal_failed _ | Current.Journal_quarantined _ -> [] in
          project_entry ?snapshot ?archive_error:(List.nth_opt archive_notes 0)
            ~identity ~absorbed json entry in
      match result with
      | Ok next ->
          let unknown = List.filter_map (fun event ->
            if event.kind = Relation_unavailable then event.reason else None) next in
          List.rev_append next events, List.rev_append unknown notes
      | Error reason -> events, (Printf.sprintf "journal byte %d: %s" offset reason) :: notes)
        ([], archive_notes) rows in
    {limit; journal_lines = List.length rows; events = List.rev events; notes = List.rev notes}

let read ~keepers_dir ~keeper_id ~limit =
  Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
    read_inline ~keepers_dir ~keeper_id ~limit)

let kind_to_string = function
  | Created -> "created" | Reobserved -> "reobserved" | Revised -> "revised"
  | Absorbed -> "absorbed" | Retracted -> "retracted" | Removed -> "removed"
  | Invalidated -> "invalidated" | Relation_unavailable -> "relation_unavailable"

let fact_to_json fact = `Assoc ["memory_id", `String fact.memory_id; "claim", (match fact.claim with None -> `Null | Some claim -> `String claim)]
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
    let* claim = optional_string_field json "claim" in
    if Memory.is_memory_id memory_id
       && (match claim with None -> true | Some text -> String.trim text <> "" && Memory.memory_id_of_claim text = memory_id)
    then Ok {memory_id; claim} else Error "activity claim does not match its memory identity" in
  let event json =
    let* identity = required_string_field json "identity" in
    let* recorded_at = Json_util.require_float json "recorded_at" in
    let* revision = required_int_field json "revision" in
    let* token = required_string_field json "kind" in
    let* kind = match token with
      | "created" -> Ok Created | "reobserved" -> Ok Reobserved | "revised" -> Ok Revised
      | "absorbed" -> Ok Absorbed | "retracted" -> Ok Retracted | "removed" -> Ok Removed
      | "invalidated" -> Ok Invalidated | "relation_unavailable" -> Ok Relation_unavailable
      | _ -> Error ("unknown memory activity kind: " ^ token) in
    let* before_rows = required_list_field json "before" in
    let* before = decode_list "before" fact before_rows in
    let* after_rows = required_list_field json "after" in
    let* after = decode_list "after" fact after_rows in
    let* reason = optional_string_field json "reason" in
    let complete facts = List.for_all (fun fact -> Option.is_some fact.claim) facts in
    let shape = match kind with
      | Created -> before = [] && after <> [] && complete after
      | Reobserved | Revised | Absorbed -> before <> [] && after <> [] && complete before && complete after
      | Retracted | Removed | Invalidated -> before <> [] && after = [] && complete before
      | Relation_unavailable -> before <> [] && complete before &&
          (match reason with Some text -> String.trim text <> "" | None -> false) in
    if shape && Float.is_finite recorded_at && recorded_at >= 0. && revision >= 0 && identity <> ""
    then Ok {identity; recorded_at; revision; kind; before; after; reason}
    else Error "invalid memory activity clock or identity" in
  let* limit = required_int_field json "limit" in
  let* journal_lines = required_int_field json "journal_lines" in
  let* rows = required_list_field json "events" in
  let* events = decode_list "events" event rows in
  let* notes = require_string_list json "notes" in
  let identities = List.map (fun event -> event.identity) events in
  if limit > 0 && journal_lines >= 0 && journal_lines <= limit
     && List.length (List.sort_uniq String.compare identities) = List.length identities
  then Ok {limit; journal_lines; events; notes}
  else Error "invalid memory activity window"
