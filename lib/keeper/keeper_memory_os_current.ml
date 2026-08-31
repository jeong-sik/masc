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

type librarian_failure_kind =
  | Prompt_render_failure
  | Execution_clock_unavailable
  | Exact_setup_failure
  | Exact_execution_failure
  | Domain_output_invalid
  | Memory_snapshot_write_failure
  | Runtime_context_unavailable
  | Lane_cancelled
  | Unhandled_exception

type journal_entry =
  | Journal_committed of
      { recorded_at : float
      ; revision : int
      ; source : source
      ; change : change
      ; dropped : Keeper_memory_os_types.dropped_statement list option
      }
  | Journal_failed of
      { recorded_at : float
      ; trace_id : string
      ; kind : librarian_failure_kind
      ; detail : string
      ; snapshot_present : bool
      ; cadence_deferred : bool
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
    ]
;;

let source_of_json = function
  | `Assoc fields
    when exact_object_fields [ "kind"; "trace_id" ] fields ->
    (match
       List.assoc_opt "kind" fields
       , List.assoc_opt "trace_id" fields
     with
     | Some (`String kind), Some (`String trace_id) ->
       (match source_kind_of_string kind with
        | Some kind
          when not (String.equal (String.trim trace_id) "") ->
          Some { kind; trace_id }
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

let librarian_failure_kind_to_string = function
  | Prompt_render_failure -> "prompt_render_failure"
  | Execution_clock_unavailable -> "execution_clock_unavailable"
  | Exact_setup_failure -> "exact_setup_failure"
  | Exact_execution_failure -> "exact_execution_failure"
  | Domain_output_invalid -> "domain_output_invalid"
  | Memory_snapshot_write_failure -> "memory_snapshot_write_failure"
  | Runtime_context_unavailable -> "runtime_context_unavailable"
  | Lane_cancelled -> "lane_cancelled"
  | Unhandled_exception -> "unhandled_exception"
;;

let librarian_failure_kind_of_string = function
  | "prompt_render_failure" -> Some Prompt_render_failure
  | "execution_clock_unavailable" -> Some Execution_clock_unavailable
  | "exact_setup_failure" -> Some Exact_setup_failure
  | "exact_execution_failure" -> Some Exact_execution_failure
  | "domain_output_invalid" -> Some Domain_output_invalid
  | "memory_snapshot_write_failure" -> Some Memory_snapshot_write_failure
  | "runtime_context_unavailable" -> Some Runtime_context_unavailable
  | "lane_cancelled" -> Some Lane_cancelled
  | "unhandled_exception" -> Some Unhandled_exception
  | _ -> None
;;

let committed_outcome = "committed"
let failed_outcome = "failed"

(* [dropped_statements = None] means the writer makes no drop-reason
   statements (explicit keeper writes, upserts); [Some list] is the
   librarian's own account of every drop in this commit, possibly empty.
   Statements live only on the journal line: the snapshot codec stays
   frozen, so existing on-disk snapshots keep parsing unchanged. *)
let journal_entry_to_json ~dropped_statements snapshot =
  `Assoc
    ([ "outcome", `String committed_outcome
     ; "recorded_at", `Float snapshot.updated_at
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

let journal_failure_to_json
      ~now
      ~trace_id
      ~kind
      ~detail
      ~snapshot_present
      ~cadence_deferred
  =
  `Assoc
    [ "outcome", `String failed_outcome
    ; "recorded_at", `Float now
    ; "trace_id", `String trace_id
    ; "kind", `String (librarian_failure_kind_to_string kind)
    ; "detail", `String detail
    ; "snapshot_present", `Bool snapshot_present
    ; "cadence_deferred", `Bool cadence_deferred
    ]
;;

(* The journal is observation only: the snapshot commit it describes already
   reached disk, so an append failure degrades to a warning instead of
   vetoing the commit. Cancellation is never absorbed. *)
let append_journal_line ~keepers_dir ~keeper_id json =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  try Fs_compat.append_jsonl path json with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | exn ->
    Log.Keeper.warn
      "memory journal append failed path=%s: %s"
      path
      (Printexc.to_string exn)
;;

let append_journal_entry ~keepers_dir ~keeper_id ~dropped_statements snapshot =
  append_journal_line
    ~keepers_dir
    ~keeper_id
    (journal_entry_to_json ~dropped_statements snapshot)
;;

let append_librarian_failure
      ~keepers_dir
      ~keeper_id
      ~now
      ~trace_id
      ~kind
      ~detail
      ~snapshot_present
      ~cadence_deferred
  =
  append_journal_line
    ~keepers_dir
    ~keeper_id
    (journal_failure_to_json
       ~now
       ~trace_id
       ~kind
       ~detail
       ~snapshot_present
       ~cadence_deferred)
;;

let committed_entry_of_fields fields =
  let dropped_of_json = function
    | `List items ->
      List.fold_left
        (fun acc item ->
           match acc, Keeper_memory_os_types.dropped_statement_of_json item with
           | Some acc, Some statement -> Some (statement :: acc)
           | _, _ -> None)
        (Some [])
        items
      |> Option.map List.rev
    | _ -> None
  in
  match
    ( List.assoc_opt "recorded_at" fields
    , List.assoc_opt "revision" fields
    , List.assoc_opt "source" fields
    , List.assoc_opt "change" fields )
  with
  | Some (`Float recorded_at), Some (`Int revision), Some source, Some change ->
    (match source_of_json source, change_of_json change with
     | Some source, Some change when revision >= 0 ->
       (match List.assoc_opt "dropped" fields with
        | None -> Ok (Journal_committed { recorded_at; revision; source; change; dropped = None })
        | Some dropped ->
          (match dropped_of_json dropped with
           | Some statements ->
             Ok
               (Journal_committed
                  { recorded_at; revision; source; change; dropped = Some statements })
           | None -> Error "committed line has an undecodable dropped list"))
     | _, _ -> Error "committed line has an undecodable source or change")
  | _ -> Error "committed line is missing recorded_at/revision/source/change"
;;

let failed_entry_of_fields fields =
  match
    ( List.assoc_opt "recorded_at" fields
    , List.assoc_opt "trace_id" fields
    , List.assoc_opt "kind" fields
    , List.assoc_opt "detail" fields
    , List.assoc_opt "snapshot_present" fields
    , List.assoc_opt "cadence_deferred" fields )
  with
  | ( Some (`Float recorded_at)
    , Some (`String trace_id)
    , Some (`String kind)
    , Some (`String detail)
    , Some (`Bool snapshot_present)
    , Some (`Bool cadence_deferred) ) ->
    (match librarian_failure_kind_of_string kind with
     | Some kind ->
       Ok
         (Journal_failed
            { recorded_at; trace_id; kind; detail; snapshot_present; cadence_deferred })
     | None -> Error (Printf.sprintf "failed line has an unknown kind %S" kind))
  | _ ->
    Error
      "failed line is missing recorded_at/trace_id/kind/detail/snapshot_present/cadence_deferred"
;;

(* Lines written before the [outcome] tag existed decode to [Error]. Guessing
   that an untagged line is a commit would let the pre-tag shape keep flowing
   through a reader that believes every line is self-describing, and no
   migration code is written for retired shapes. *)
let journal_entry_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "outcome" fields with
     | Some (`String outcome) when String.equal outcome committed_outcome ->
       committed_entry_of_fields fields
     | Some (`String outcome) when String.equal outcome failed_outcome ->
       failed_entry_of_fields fields
     | Some (`String outcome) ->
       Error (Printf.sprintf "journal line has an unknown outcome %S" outcome)
     | Some _ -> Error "journal line has a non-string outcome"
     | None -> Error "journal line has no outcome tag")
  | _ -> Error "journal line is not a JSON object"
;;

let read_journal_tail ~keepers_dir ~keeper_id ~limit =
  if limit <= 0
  then []
  else (
    let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
    match Fs_compat.load_file_opt path with
    | None -> []
    | Some contents ->
      let lines =
        String.split_on_char '\n' contents
        |> List.filter (fun line -> not (String.equal (String.trim line) ""))
      in
      let total = List.length lines in
      let skip = if total > limit then total - limit else 0 in
      lines
      |> List.filteri (fun index _ -> index >= skip)
      |> List.map (fun line ->
        match Yojson.Safe.from_string line with
        | json -> journal_entry_of_json json
        | exception Yojson.Json_error message ->
          Error (Printf.sprintf "journal line is not valid JSON: %s" message)))
;;

let update_locked
      ?clock
      ?dropped_statements
      ~keepers_dir
      ~keeper_id
      build
  =
  Fs_compat.mkdir_p keepers_dir;
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  Keeper_memory_os_aggregate_lock.with_lock
    ?clock
    ~keepers_dir
    ~keeper_id
    (fun () ->
       (* File_lock_eio.with_lock appends ".lock" itself; a pre-suffixed path
          locked "<snapshot>.lock.lock" and left a stray file per keeper. *)
       File_lock_eio.with_lock ?clock snapshot_path (fun () ->
         let* previous =
           match Fs_compat.load_file_opt snapshot_path with
           | None -> Ok None
           | Some content ->
             let+ snapshot = parse snapshot_path content in
             Some snapshot
         in
         let* source_payload =
           match
             Keeper_memory_source_current.read_for_keepers_dir
               ~keepers_dir
               ~keeper_id
           with
           | Ok None -> Ok ""
           | Ok (Some snapshot) ->
             Ok
               (Keeper_memory_source_current.render_payload
                  snapshot.facts
                  snapshot.invalidations)
           | Error detail -> Error detail
         in
         let* next = build ~source_payload previous in
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
                message)))
;;

let combined_measure ~max_bytes ~source_payload facts =
  let ordinary_bytes = Keeper_memory_os_budget.rendered_bytes facts in
  let source_bytes = String.length source_payload in
  let separator_bytes =
    if ordinary_bytes > 0 && source_bytes > 0 then 1 else 0
  in
  let saturated_add left right =
    if left > Int.max_int - right then Int.max_int else left + right
  in
  let actual_bytes =
    ordinary_bytes
    |> saturated_add source_bytes
    |> saturated_add separator_bytes
  in
  let measurement : Keeper_memory_os_budget.measurement =
    { actual_bytes; max_bytes }
  in
  if actual_bytes <= max_bytes
  then Keeper_memory_os_budget.Fits measurement
  else Keeper_memory_os_budget.Exceeds measurement
;;

let make_snapshot
      ~max_fact_bytes
      ~source_payload
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
  let max_fact_bytes = max 1 max_fact_bytes in
  match combined_measure ~max_bytes:max_fact_bytes ~source_payload facts with
  | Exceeds { actual_bytes; max_bytes } ->
    Error
      (Printf.sprintf
         "combined Memory OS rendered payload exceeds byte budget actual_bytes=%d max_bytes=%d"
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
  update_locked
    ?clock
    ?dropped_statements
    ~keepers_dir
    ~keeper_id
    (fun ~source_payload previous ->
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
        ~source_payload
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
  update_locked
    ?clock
    ~keepers_dir
    ~keeper_id
    (fun ~source_payload previous ->
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
             (* Byte-identical re-observation of an existing row. The exact
                claim bytes were already on file, so this is reinforcement,
                not a new fact: preserve the authoritative insertion time and
                the original origin (an injected copy re-observed must not
                repaint an authored row), refresh the observation time, and
                count the re-observation. This is the measurable damper on
                byte-identical reinjection: the loop accumulates a count, not
                rows. *)
             { incoming with
               first_seen = existing.first_seen
             ; last_seen = Float.max existing.last_seen incoming.last_seen
             ; reinforcement = existing.reinforcement + 1
             ; origin = existing.origin
             })
           else existing)
        current_facts
    in
    let facts = if !found then facts else facts @ [ incoming ] in
    (* When the rendered payload exceeds the byte budget, evict the stalest
       facts (by [last_seen], the most recent re-observation of the same claim
       bytes) other than the incoming one until it fits, so an explicit write
       never deadlocks a full memory and a fact that keeps proving relevant
       outlives budget pressure instead of dying of insertion age. A single
       incoming fact larger than the whole budget still fails closed below. *)
    let facts =
      match
        combined_measure ~max_bytes:max_fact_bytes ~source_payload facts
      with
      | Fits _ -> facts
      | Exceeds _ ->
        let incoming_id = memory_id incoming in
        let others, incoming_fact =
          List.partition
            (fun f -> not (String.equal (memory_id f) incoming_id))
            facts
        in
        let others =
          List.sort
            (fun a b -> Float.compare a.last_seen b.last_seen)
            others
        in
        let rec evict_oldest remaining =
          match remaining with
          | [] -> remaining
          | _ :: rest ->
            (match
               combined_measure
                 ~max_bytes:max_fact_bytes
                 ~source_payload
                 (incoming_fact @ remaining)
             with
             | Fits _ -> remaining
             | Exceeds _ -> evict_oldest rest)
        in
        let evicted = evict_oldest others in
        Log.Keeper.warn
          "memory os upsert evicted %d fact(s) to fit byte budget keeper=%s"
          (List.length others - List.length evicted)
          keeper_id;
        incoming_fact @ evicted
    in
    make_snapshot
      ~max_fact_bytes
      ~source_payload
      ~previous
      ~now
      ~source
      ~facts
      ())
;;

(* Read-side projection. The write-side [journal_entry_to_json] above encodes a
   committed snapshot for the append; this projects a line that was read back,
   including the shapes that only exist on the failure path. Reusing the
   existing field encoders keeps one owner for source/change on the wire. *)
let decoded_journal_entry_to_json = function
  | Journal_committed { recorded_at; revision; source; change; dropped } ->
    `Assoc
      ([ "outcome", `String committed_outcome
       ; "recorded_at", `Float recorded_at
       ; "revision", `Int revision
       ; "source", source_to_json source
       ; "change", change_to_json change
       ]
       @
       match dropped with
       | None -> []
       | Some statements ->
         [ "dropped", `List (List.map dropped_statement_to_json statements) ])
  | Journal_failed
      { recorded_at; trace_id; kind; detail; snapshot_present; cadence_deferred } ->
    `Assoc
      [ "outcome", `String failed_outcome
      ; "recorded_at", `Float recorded_at
      ; "trace_id", `String trace_id
      ; "kind", `String (librarian_failure_kind_to_string kind)
      ; "detail", `String detail
      ; "snapshot_present", `Bool snapshot_present
      ; "cadence_deferred", `Bool cadence_deferred
      ]
;;

(* A line this build could not decode keeps its position and says why. Dropping
   it would make a journal with a torn line read as a shorter one, and the
   operator counting passes is the one who would be misled. *)
let journal_line_to_json = function
  | Ok entry ->
    (match decoded_journal_entry_to_json entry with
     | `Assoc fields -> `Assoc (("ok", `Bool true) :: fields)
     | json -> json)
  | Error reason -> `Assoc [ "ok", `Bool false; "error", `String reason ]
;;
