(** Keeper-owned current Memory OS snapshot. *)

open Keeper_memory_os_types
open Result.Syntax

let suffix = ".memory-current.json"

type source_kind =
  | Librarian
  | Explicit_write

type source =
  { kind : source_kind
  ; trace_id : string
  ; generation : int
  }

type change =
  { added : fact list
  ; removed : fact list
  ; retained : int
  }

type t =
  { revision : int
  ; updated_at : float
  ; source : source
  ; facts : fact list
  ; change : change
  }

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

let journal_suffix = ".memory-journal.jsonl"

let journal_path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ journal_suffix)
;;

let list_keeper_ids_for_keepers_dir ~keepers_dir =
  if not (Sys.file_exists keepers_dir && Sys.is_directory keepers_dir)
  then []
  else
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.filter_map (Filename.chop_suffix_opt ~suffix)
    |> List.sort String.compare
;;

let source_kind_to_string = function
  | Librarian -> "librarian"
  | Explicit_write -> "explicit_write"
;;

let source_kind_of_string = function
  | "librarian" -> Some Librarian
  | "explicit_write" -> Some Explicit_write
  | _ -> None
;;

let exact_object_fields required fields =
  List.length required = List.length fields
  && List.for_all
       (fun required_name ->
          match
            List.filter
              (fun (observed_name, _) ->
                 String.equal required_name observed_name)
              fields
          with
          | [ _ ] -> true
          | [] | _ :: _ :: _ -> false)
       required
;;

let source_to_json source =
  `Assoc
    [ "kind", `String (source_kind_to_string source.kind)
    ; "trace_id", `String source.trace_id
    ; "generation", `Int source.generation
    ]
;;

let source_of_json = function
  | `Assoc fields
    when exact_object_fields [ "kind"; "trace_id"; "generation" ] fields ->
    (match
       List.assoc_opt "kind" fields
       , List.assoc_opt "trace_id" fields
       , List.assoc_opt "generation" fields
     with
     | Some (`String kind), Some (`String trace_id), Some (`Int generation) ->
       (match source_kind_of_string kind with
        | Some kind
          when not (String.equal (String.trim trace_id) "") && generation >= 0 ->
          Some { kind; trace_id; generation }
        | Some _ | None -> None)
     | _ -> None)
  | _ -> None
;;

let facts_of_json = function
  | `List values ->
    let rec loop seen acc = function
      | [] -> Some (List.rev acc)
      | value :: rest ->
        (match fact_of_json value with
         | Some fact ->
           let identity = memory_id fact in
           if Set_util.StringSet.mem identity seen
           then None
           else
             loop
               (Set_util.StringSet.add identity seen)
               (fact :: acc)
               rest
         | None -> None)
    in
    loop Set_util.StringSet.empty [] values
  | _ -> None
;;

let facts_to_json facts =
  `List (List.map fact_to_json facts)
;;

let change_to_json change =
  `Assoc
    [ "added", facts_to_json change.added
    ; "removed", facts_to_json change.removed
    ; "retained", `Int change.retained
    ]
;;

let change_of_json = function
  | `Assoc fields
    when exact_object_fields [ "added"; "removed"; "retained" ] fields ->
    (match
       List.assoc_opt "added" fields
       , List.assoc_opt "removed" fields
       , List.assoc_opt "retained" fields
     with
     | Some added, Some removed, Some (`Int retained) ->
       (match facts_of_json added, facts_of_json removed with
        | Some added, Some removed when retained >= 0 ->
          Some { added; removed; retained }
        | (Some _, Some _) | (Some _, None) | (None, _) -> None)
     | _ -> None)
  | _ -> None
;;

let to_json snapshot =
  `Assoc
    [ "revision", `Int snapshot.revision
    ; "updated_at", `Float snapshot.updated_at
    ; "source", source_to_json snapshot.source
    ; "facts", facts_to_json snapshot.facts
    ; "change", change_to_json snapshot.change
    ]
;;

let of_json = function
  | `Assoc fields
    when exact_object_fields
           [ "revision"
           ; "updated_at"
           ; "source"
           ; "facts"
           ; "change"
           ]
           fields ->
    (match
       List.assoc_opt "revision" fields
       , List.assoc_opt "updated_at" fields
       , List.assoc_opt "source" fields
       , List.assoc_opt "facts" fields
       , List.assoc_opt "change" fields
     with
     | ( Some (`Int revision)
       , Some updated_at_json
       , Some source_json
       , Some facts_json
       , Some change_json ) ->
       let updated_at =
         match updated_at_json with
         | `Float value -> Some value
         | `Int value -> Some (float_of_int value)
         | _ -> None
       in
       (match
          updated_at
          , source_of_json source_json
          , facts_of_json facts_json
          , change_of_json change_json
        with
        | ( Some updated_at
          , Some source
          , Some facts
          , Some change )
          when revision >= 1
               && Float.is_finite updated_at
               && updated_at >= 0.0 ->
          Some
            { revision
            ; updated_at
            ; source
            ; facts
            ; change
            }
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let parse path content =
  try
    match of_json (Yojson.Safe.from_string content) with
    | Some snapshot -> Ok snapshot
    | None -> Error (Printf.sprintf "%s: invalid current Memory OS snapshot" path)
  with
  | Yojson.Json_error message ->
    Error (Printf.sprintf "%s: invalid JSON: %s" path message)
;;

let read_for_keepers_dir ~keepers_dir ~keeper_id =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  try
    match Fs_compat.load_file_opt snapshot_path with
    | None -> Ok None
    | Some content ->
      let+ snapshot = parse snapshot_path content in
      Some snapshot
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error message ->
    Error
      (Printf.sprintf
         "current Memory OS read failed path=%s: %s"
         snapshot_path
         message)
;;

module Identity_map = Map.Make (String)

let fact_payload fact =
  fact_to_json fact |> Yojson.Safe.to_string
;;

let map_facts facts =
  let rec loop map = function
    | [] -> Ok map
    | fact :: rest ->
      let identity = memory_id fact in
      if Identity_map.mem identity map
      then Error (Printf.sprintf "duplicate Memory OS fact identity: %s" identity)
      else loop (Identity_map.add identity fact map) rest
  in
  loop Identity_map.empty facts
;;

let compute_change ~previous ~next =
  let* previous_by_id = map_facts previous in
  let* next_by_id = map_facts next in
  let added_rev, retained =
    List.fold_left
      (fun (added_rev, retained) next_fact ->
         let identity = memory_id next_fact in
         match Identity_map.find_opt identity previous_by_id with
         | Some previous_fact
           when String.equal (fact_payload previous_fact) (fact_payload next_fact) ->
           added_rev, retained + 1
         | Some _ | None -> next_fact :: added_rev, retained)
      ([], 0)
      next
  in
  let removed_rev =
    List.fold_left
      (fun removed_rev previous_fact ->
         let identity = memory_id previous_fact in
         match Identity_map.find_opt identity next_by_id with
         | Some next_fact
           when String.equal (fact_payload previous_fact) (fact_payload next_fact) ->
           removed_rev
         | Some _ | None -> previous_fact :: removed_rev)
      []
      previous
  in
  Ok
    { added = List.rev added_rev
    ; removed = List.rev removed_rev
    ; retained
    }
;;

(* [dropped_statements = None] means the writer makes no drop-reason
   statements (explicit keeper writes, upserts); [Some list] is the
   librarian's own account of every drop in this commit, possibly empty.
   Statements live only on the journal line: the snapshot codec stays
   frozen, so existing on-disk snapshots keep parsing unchanged. *)
let journal_entry_to_json ~dropped_statements snapshot =
  `Assoc
    ([ "recorded_at", `Float snapshot.updated_at
     ; "revision", `Int snapshot.revision
     ; "source", source_to_json snapshot.source
     ; "change", change_to_json snapshot.change
     ]
     @
     match dropped_statements with
     | None -> []
     | Some statements ->
       [ ( "dropped"
         , `List (List.map dropped_statement_to_json statements) )
       ])
;;

(* The journal is observation only: the snapshot commit it describes already
   reached disk, so an append failure degrades to a warning instead of
   vetoing the commit. Cancellation is never absorbed. *)
let append_journal_entry ~keepers_dir ~keeper_id ~dropped_statements snapshot =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  try
    Fs_compat.append_jsonl
      path
      (journal_entry_to_json ~dropped_statements snapshot)
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | exn ->
    Log.Keeper.warn
      "memory journal append failed path=%s: %s"
      path
      (Printexc.to_string exn)
;;

let lock_path snapshot_path = snapshot_path ^ ".lock"

let update_locked
      ?clock
      ?dropped_statements
      ~keepers_dir
      ~keeper_id
      build
  =
  Fs_compat.mkdir_p keepers_dir;
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  File_lock_eio.with_lock ?clock (lock_path snapshot_path) (fun () ->
    let* previous =
      match Fs_compat.load_file_opt snapshot_path with
      | None -> Ok None
      | Some content ->
        let+ snapshot = parse snapshot_path content in
        Some snapshot
    in
    let* next = build previous in
    let content = Yojson.Safe.pretty_to_string (to_json next) ^ "\n" in
    match Fs_compat.save_file_atomic snapshot_path content with
    | Ok () ->
      append_journal_entry ~keepers_dir ~keeper_id ~dropped_statements next;
      Ok next
    | Error message ->
      Error
        (Printf.sprintf
           "current Memory OS atomic write failed path=%s: %s"
           snapshot_path
           message))
;;

let make_snapshot
      ~max_fact_bytes
      ~previous
      ~now
      ~source
      ~facts
      ()
  =
  let previous_facts, revision =
    match previous with
    | None -> [], 1
    | Some snapshot -> snapshot.facts, snapshot.revision + 1
  in
  match Keeper_memory_os_budget.measure ~max_bytes:max_fact_bytes facts with
  | Exceeds { actual_bytes; max_bytes } ->
    Error
      (Printf.sprintf
         "Memory OS rendered fact payload exceeds byte budget actual_bytes=%d max_bytes=%d"
         actual_bytes
         max_bytes)
  | Fits _ ->
    let+ change = compute_change ~previous:previous_facts ~next:facts in
    { revision
    ; updated_at = now
    ; source
    ; facts
    ; change
    }
;;

let replace
      ?clock
      ?dropped_statements
      ?(max_fact_bytes=Env_config.KeeperMemoryOs.recall_facts_max_bytes ())
      ~keepers_dir
      ~keeper_id
      ~expected_revision
      ~now
      ~source
      ~facts
      ()
  =
  update_locked ?clock ?dropped_statements ~keepers_dir ~keeper_id (fun previous ->
    let observed_revision =
      Option.map (fun snapshot -> snapshot.revision) previous
    in
    if observed_revision <> expected_revision
    then
      Error
        (Printf.sprintf
           "current Memory OS revision conflict expected=%s observed=%s"
           (Option.fold ~none:"absent" ~some:string_of_int expected_revision)
           (Option.fold ~none:"absent" ~some:string_of_int observed_revision))
    else
      make_snapshot
        ~max_fact_bytes
        ~previous
        ~now
        ~source
        ~facts
        ())
;;

let upsert_fact
      ?clock
      ?(max_fact_bytes=Env_config.KeeperMemoryOs.recall_facts_max_bytes ())
      ~keepers_dir
      ~keeper_id
      ~now
      ~source
      incoming
  =
  update_locked ?clock ~keepers_dir ~keeper_id (fun previous ->
    let current_facts =
      match previous with
      | None -> []
      | Some snapshot -> snapshot.facts
    in
    let incoming_identity = memory_id incoming in
    let found = ref false in
    let facts =
      List.map
        (fun existing ->
           if String.equal (memory_id existing) incoming_identity
           then (
             found := true;
             { incoming with first_seen = existing.first_seen })
           else existing)
        current_facts
    in
    let facts = if !found then facts else facts @ [ incoming ] in
    make_snapshot
      ~max_fact_bytes
      ~previous
      ~now
      ~source
      ~facts
      ())
;;
