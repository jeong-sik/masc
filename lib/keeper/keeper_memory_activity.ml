open Result.Syntax
module Memory = Keeper_memory_os_types

type kind =
  | Created
  | Reobserved
  | Revised
  | Absorbed
  | Retracted
  | Removed
  | Invalidated
  | Relation_unavailable

type fact =
  { memory_id : string
  ; claim : string option
  }

type event =
  { identity : string
  ; recorded_at : float
  ; revision : int
  ; kind : kind
  ; before : fact list
  ; after : fact list
  ; reason : string option
  }

type t =
  { limit : int
  ; journal_lines : int
  ; events : event list
  ; notes : string list
  }

let reference (fact : Memory.fact) =
  { memory_id = Memory.memory_id fact; claim = Some fact.claim }
;;

let project_commit ?(lookup_fact = fun _ -> None) ~identity (commit : Librarian_log.commit) =
  let recorded_at = commit.at in
  let revision = commit.revision in
  if not (Float.is_finite recorded_at && recorded_at >= 0.)
  then Error "invalid commit log observation clock"
  else if revision < 0
  then Error "invalid commit log revision"
  else (
    let added_by_id = Hashtbl.create (max 8 (List.length commit.effects.added)) in
    List.iter
      (fun (f : Memory.fact) -> Hashtbl.replace added_by_id (Memory.memory_id f) f)
      commit.effects.added;
    let resolve id =
      match Hashtbl.find_opt added_by_id id with
      | Some f -> Some f
      | None -> lookup_fact id
    in
    let make suffix kind before after reason =
      { identity = identity ^ ":" ^ suffix
      ; recorded_at
      ; revision
      ; kind
      ; before
      ; after
      ; reason
      }
    in
    let merged_by_into : (string, Memory.fact list) Hashtbl.t = Hashtbl.create 8 in
    let merged_order = ref [] in
    let revised_events = ref [] in
    let removal_events = ref [] in
    let handled_after = Hashtbl.create 8 in
    List.iter
      (fun ((old_fact : Memory.fact), (reason : Librarian_effects.removal)) ->
         let old_id = Memory.memory_id old_fact in
         match reason with
         | Librarian_effects.Merged_into into_id ->
           if not (Hashtbl.mem merged_by_into into_id)
           then merged_order := into_id :: !merged_order;
           let prev =
             Option.value ~default:[] (Hashtbl.find_opt merged_by_into into_id)
           in
           Hashtbl.replace merged_by_into into_id (old_fact :: prev)
         | Librarian_effects.Revised_into into_id
         | Librarian_effects.Superseded_by into_id ->
           (match resolve into_id with
            | Some successor ->
              Hashtbl.replace handled_after into_id ();
              revised_events :=
                make
                  ("revision:" ^ old_id ^ ":" ^ into_id)
                  Revised
                  [ reference old_fact ]
                  [ reference successor ]
                  None
                :: !revised_events
            | None ->
              revised_events :=
                make
                  ("unresolved:" ^ old_id ^ ":" ^ into_id)
                  Relation_unavailable
                  [ reference old_fact ]
                  [ { memory_id = into_id; claim = None } ]
                  (Some "retained successor is not proven by this commit")
                :: !revised_events)
         | Librarian_effects.Retracted { reason; _ } ->
           removal_events :=
             make ("remove:" ^ old_id) Retracted [ reference old_fact ] [] (Some reason)
             :: !removal_events
         | Librarian_effects.Dropped { reason }
         | Librarian_effects.Molted { reason } ->
           removal_events :=
             make ("remove:" ^ old_id) Removed [ reference old_fact ] [] (Some reason)
             :: !removal_events
         | Librarian_effects.Support_lost _ ->
           removal_events :=
             make ("remove:" ^ old_id) Invalidated [ reference old_fact ] [] None
             :: !removal_events)
      commit.effects.removed;
    let absorbed_events =
      List.rev !merged_order
      |> List.filter_map (fun into_id ->
        match Hashtbl.find_opt merged_by_into into_id with
        | None | Some [] -> None
        | Some originals_rev ->
          let originals = List.rev originals_rev in
          (match resolve into_id with
           | Some successor ->
             Hashtbl.replace handled_after into_id ();
             Some
               (make
                  ("absorb:" ^ into_id)
                  Absorbed
                  (List.map reference originals)
                  [ reference successor ]
                  None)
           | None ->
             Some
               (make
                  ("unresolved:absorb:" ^ into_id)
                  Relation_unavailable
                  (List.map reference originals)
                  [ { memory_id = into_id; claim = None } ]
                  (Some "absorbed target is not proven by this commit"))))
    in
    let addition_events =
      List.filter_map
        (fun (f : Memory.fact) ->
           let id = Memory.memory_id f in
           if Hashtbl.mem handled_after id
           then None
           else Some (make ("add:" ^ id) Created [] [ reference f ] None))
        commit.effects.added
    in
    let touched_events =
      List.filter_map
        (fun id ->
           match lookup_fact id with
           | None -> None
           | Some old ->
             let updated = { old with last_seen = max old.last_seen recorded_at } in
             Some
               (make
                  ("seen:" ^ id)
                  Reobserved
                  [ reference old ]
                  [ reference updated ]
                  None))
        commit.effects.touched
    in
    Ok
      (List.rev !revised_events
       @ absorbed_events
       @ List.rev !removal_events
       @ addition_events
       @ touched_events))
;;

let undecodable_to_string = function
  | Librarian_log_store.Not_json -> "not JSON"
  | Librarian_log_store.Malformed err -> Memory.wire_error_to_string err
;;

let read_inline ~keepers_dir ~keeper_id ~limit =
  if limit <= 0
  then { limit; journal_lines = 0; events = []; notes = [] }
  else (
    let log_path = Librarian_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id in
    let known_facts : (string, Memory.fact) Hashtbl.t = Hashtbl.create 32 in
    (match Keeper_memory_os_current.read_classified ~keepers_dir ~keeper_id with
     | Keeper_memory_os_current.Readable snap ->
       List.iter
         (fun f -> Hashtbl.replace known_facts (Memory.memory_id f) f)
         snap.facts
     | No_snapshot | Undecodable _ | Io_unreadable _ -> ());
    let tail_q :
      (int * (Librarian_log.commit, Librarian_log_store.undecodable) result) Queue.t
      =
      Queue.create ()
    in
    let push_row row =
      Queue.add row tail_q;
      if Queue.length tail_q > limit then ignore (Queue.take tail_q)
    in
    match
      Librarian_log_store.fold log_path ~init:()
        ~f:(fun () ({ at; line } : Librarian_log_store.scanned) ->
          match line with
          | Ok (Librarian_log.Started _) -> ()
          | Ok (Librarian_log.Committed commit) ->
            List.iter
              (fun f -> Hashtbl.replace known_facts (Memory.memory_id f) f)
              commit.effects.added;
            List.iter
              (fun (f, _) ->
                 let id = Memory.memory_id f in
                 if not (Hashtbl.mem known_facts id)
                 then Hashtbl.replace known_facts id f)
              commit.effects.removed;
            push_row (at, Ok commit)
          | Error err -> push_row (at, Error err))
    with
    | Error err ->
      { limit
      ; journal_lines = 0
      ; events = []
      ; notes = [ Private_jsonl_scan.error_to_string err ]
      }
    | Ok () ->
      let rows = Queue.fold (fun acc item -> item :: acc) [] tail_q |> List.rev in
      let lookup_fact id = Hashtbl.find_opt known_facts id in
      let events_rev, notes_rev =
        List.fold_left
          (fun (events, notes) (offset, row) ->
             let identity = Printf.sprintf "memory:%s:%d" keeper_id offset in
             match row with
             | Error err ->
               ( events
               , Printf.sprintf "memory log byte %d: %s" offset (undecodable_to_string err)
                 :: notes )
             | Ok commit ->
               (match project_commit ~lookup_fact ~identity commit with
                | Ok next ->
                  let unknown =
                    List.filter_map
                      (fun ev ->
                         if ev.kind = Relation_unavailable then ev.reason else None)
                      next
                  in
                  List.rev_append next events, List.rev_append unknown notes
                | Error reason ->
                  events, Printf.sprintf "memory log byte %d: %s" offset reason :: notes))
          ([], [])
          rows
      in
      { limit
      ; journal_lines = List.length rows
      ; events = List.rev events_rev
      ; notes = List.rev notes_rev
      })
;;

let read ~keepers_dir ~keeper_id ~limit =
  Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
    read_inline ~keepers_dir ~keeper_id ~limit)
;;

let kind_to_string = function
  | Created -> "created"
  | Reobserved -> "reobserved"
  | Revised -> "revised"
  | Absorbed -> "absorbed"
  | Retracted -> "retracted"
  | Removed -> "removed"
  | Invalidated -> "invalidated"
  | Relation_unavailable -> "relation_unavailable"
;;

let fact_to_json fact =
  `Assoc
    [ "memory_id", `String fact.memory_id
    ; "claim", (match fact.claim with None -> `Null | Some claim -> `String claim)
    ]
;;

let event_to_json event =
  `Assoc
    [ "identity", `String event.identity
    ; "recorded_at", `Float event.recorded_at
    ; "revision", `Int event.revision
    ; "kind", `String (kind_to_string event.kind)
    ; "before", `List (List.map fact_to_json event.before)
    ; "after", `List (List.map fact_to_json event.after)
    ; "reason", (match event.reason with None -> `Null | Some reason -> `String reason)
    ]
;;

let to_json activity =
  `Assoc
    [ "limit", `Int activity.limit
    ; "journal_lines", `Int activity.journal_lines
    ; "events", `List (List.map event_to_json activity.events)
    ; "notes", `List (List.map (fun note -> `String note) activity.notes)
    ]
;;

let of_json json =
  let open Json_decode_fields in
  let fact json =
    let* memory_id = required_string_field json "memory_id" in
    let* claim = optional_string_field json "claim" in
    if
      Memory.is_memory_id memory_id
      &&
      match claim with
      | None -> true
      | Some text -> String.trim text <> "" && Memory.memory_id_of_claim text = memory_id
    then Ok { memory_id; claim }
    else Error "activity claim does not match its memory identity"
  in
  let event json =
    let* identity = required_string_field json "identity" in
    let* recorded_at = Json_util.require_float json "recorded_at" in
    let* revision = required_int_field json "revision" in
    let* token = required_string_field json "kind" in
    let* kind =
      match token with
      | "created" -> Ok Created
      | "reobserved" -> Ok Reobserved
      | "revised" -> Ok Revised
      | "absorbed" -> Ok Absorbed
      | "retracted" -> Ok Retracted
      | "removed" -> Ok Removed
      | "invalidated" -> Ok Invalidated
      | "relation_unavailable" -> Ok Relation_unavailable
      | _ -> Error ("unknown memory activity kind: " ^ token)
    in
    let* before_rows = required_list_field json "before" in
    let* before = decode_list "before" fact before_rows in
    let* after_rows = required_list_field json "after" in
    let* after = decode_list "after" fact after_rows in
    let* reason = optional_string_field json "reason" in
    let complete facts = List.for_all (fun fact -> Option.is_some fact.claim) facts in
    let shape =
      match kind with
      | Created -> before = [] && after <> [] && complete after
      | Reobserved | Revised | Absorbed ->
        before <> [] && after <> [] && complete before && complete after
      | Retracted | Removed | Invalidated ->
        before <> [] && after = [] && complete before
      | Relation_unavailable ->
        before <> []
        && complete before
        &&
        (match reason with
         | Some text -> String.trim text <> ""
         | None -> false)
    in
    if shape && Float.is_finite recorded_at && recorded_at >= 0. && revision >= 0 && identity <> ""
    then Ok { identity; recorded_at; revision; kind; before; after; reason }
    else Error "invalid memory activity clock or identity"
  in
  let* limit = required_int_field json "limit" in
  let* journal_lines = required_int_field json "journal_lines" in
  let* rows = required_list_field json "events" in
  let* events = decode_list "events" event rows in
  let* notes = require_string_list json "notes" in
  let identities = List.map (fun event -> event.identity) events in
  if
    limit > 0
    && journal_lines >= 0
    && journal_lines <= limit
    && List.length (List.sort_uniq String.compare identities) = List.length identities
  then Ok { limit; journal_lines; events; notes }
  else Error "invalid memory activity window"
;;
