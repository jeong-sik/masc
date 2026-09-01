(** Keeper-owned current Memory OS snapshot. *)

open Keeper_memory_os_types
open Result.Syntax

let suffix = ".memory-current.json"

type source_kind =
  | Librarian
  | Explicit_write
  | Explicit_retract

type source =
  { kind : source_kind
  ; trace_id : string
  }

type support_invalidation =
  { fact : fact
  ; missing_premise_ids : string list
  }

type change =
  { added : fact list
  ; removed : fact list
  ; retained : int
  ; invalidated : support_invalidation list
  }

type upsert_error =
  | Unsupported_derivation of support_invalidation
  | Upsert_persistence_failed of string

type retract_error =
  | Retract_memory_id_invalid
  | Retract_reason_empty
  | Retract_fact_not_found of string
  | Retract_persistence_failed of string

let upsert_error_to_string = function
  | Unsupported_derivation invalidation ->
    Printf.sprintf
      "derived Memory OS fact has no complete support path memory_id=%s missing_premise_ids=%s"
      (memory_id invalidation.fact)
      (String.concat "," invalidation.missing_premise_ids)
  | Upsert_persistence_failed detail -> detail
;;

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
  | Explicit_retract -> "explicit_retract"
;;

let source_kind_of_string = function
  | "librarian" -> Some Librarian
  | "explicit_write" -> Some Explicit_write
  | "explicit_retract" -> Some Explicit_retract
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

module Identity_map = Map.Make (String)

let fact_payload fact =
  fact_to_json fact |> Yojson.Safe.to_string
;;

let derivations_supported current_ids derivations =
  List.exists
    (fun derivation ->
       List.for_all
         (fun premise_id -> Set_util.StringSet.mem premise_id current_ids)
         derivation.premise_ids)
    derivations
;;

let missing_premises_for current_ids derivations =
  List.fold_left
    (fun missing derivation ->
       List.fold_left
         (fun missing premise_id ->
            if Set_util.StringSet.mem premise_id current_ids
            then missing
            else Set_util.StringSet.add premise_id missing)
         missing
         derivation.premise_ids)
    Set_util.StringSet.empty
    derivations
  |> Set_util.StringSet.elements
;;

let support_closure_ids facts =
  let rules =
    List.concat_map
      (fun fact ->
         match fact.basis with
         | Observed -> []
         | Derived derivations ->
           List.map
             (fun derivation -> memory_id fact, derivation.premise_ids)
             derivations)
      facts
    |> Array.of_list
  in
  let remaining = Array.map (fun (_, premise_ids) -> List.length premise_ids) rules in
  let dependents = Hashtbl.create (Array.length rules) in
  Array.iteri
    (fun rule_index (_, premise_ids) ->
       List.iter
         (fun premise_id ->
            let current = Hashtbl.find_opt dependents premise_id |> Option.value ~default:[] in
            Hashtbl.replace dependents premise_id (rule_index :: current))
         premise_ids)
    rules;
  let current = ref Set_util.StringSet.empty in
  let pending = Queue.create () in
  let activate identity =
    if not (Set_util.StringSet.mem identity !current)
    then (
      current := Set_util.StringSet.add identity !current;
      Queue.add identity pending)
  in
  List.iter
    (fun fact ->
       match fact.basis with
       | Observed -> activate (memory_id fact)
       | Derived _ -> ())
    facts;
  while not (Queue.is_empty pending) do
    let identity = Queue.take pending in
    Hashtbl.find_opt dependents identity
    |> Option.value ~default:[]
    |> List.iter (fun rule_index ->
      remaining.(rule_index) <- remaining.(rule_index) - 1;
      if remaining.(rule_index) = 0
      then activate (fst rules.(rule_index)))
  done;
  !current
;;

let support_invalidation_to_json invalidation =
  let missing_premise_ids = invalidation.missing_premise_ids in
  if
    missing_premise_ids = []
    || not (List.for_all Keeper_memory_os_types.is_memory_id missing_premise_ids)
    || not
         (List.equal
            String.equal
            missing_premise_ids
            (List.sort_uniq String.compare missing_premise_ids))
  then invalid_arg "support invalidation must carry canonical missing premise identities";
  `Assoc
    [ "fact", fact_to_json invalidation.fact
    ; ( "missing_premise_ids"
      , `List
          (List.map
             (fun premise_id -> `String premise_id)
             invalidation.missing_premise_ids) )
    ]
;;

let support_invalidation_of_json = function
  | `Assoc fields
    when exact_object_fields [ "fact"; "missing_premise_ids" ] fields ->
    (match
       List.assoc_opt "fact" fields
       , List.assoc_opt "missing_premise_ids" fields
     with
     | Some fact_json, Some (`List premise_values) ->
       let rec premise_ids previous acc = function
         | [] -> Some (List.rev acc)
         | `String premise_id :: rest
           when Keeper_memory_os_types.is_memory_id premise_id
                && (match previous with
                    | None -> true
                    | Some previous -> String.compare previous premise_id < 0) ->
           premise_ids
             (Some premise_id)
             (premise_id :: acc)
             rest
         | _ -> None
       in
       (match fact_of_json fact_json, premise_ids None [] premise_values with
        | Some fact, Some (_ :: _ as missing_premise_ids) ->
          Some { fact; missing_premise_ids }
        | Some _, Some [] | Some _, None | None, _ -> None)
     | _ -> None)
  | _ -> None
;;

let change_to_json change =
  `Assoc
    [ "added", facts_to_json change.added
    ; "removed", facts_to_json change.removed
    ; "retained", `Int change.retained
    ; ( "invalidated"
      , `List (List.map support_invalidation_to_json change.invalidated) )
    ]
;;

let change_of_json = function
  | `Assoc fields
    when exact_object_fields
           [ "added"; "removed"; "retained"; "invalidated" ]
           fields ->
    (match
       List.assoc_opt "added" fields
       , List.assoc_opt "removed" fields
       , List.assoc_opt "retained" fields
       , List.assoc_opt "invalidated" fields
     with
     | Some added, Some removed, Some (`Int retained), Some (`List invalidated_json) ->
       let rec invalidations seen acc = function
         | [] -> Some (List.rev acc)
         | json :: rest ->
           (match support_invalidation_of_json json with
            | Some invalidation ->
              let identity = memory_id invalidation.fact in
              if Set_util.StringSet.mem identity seen
              then None
              else
                invalidations
                  (Set_util.StringSet.add identity seen)
                  (invalidation :: acc)
                  rest
            | None -> None)
       in
       (match
          facts_of_json added
          , facts_of_json removed
          , invalidations Set_util.StringSet.empty [] invalidated_json
        with
        | Some added, Some removed, Some invalidated when retained >= 0 ->
          Some { added; removed; retained; invalidated }
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let valid_snapshot_change ~facts ~current_ids ~change =
  let current_by_id =
    List.fold_left
      (fun by_id fact -> Identity_map.add (memory_id fact) fact by_id)
      Identity_map.empty
      facts
  in
  let added_are_current =
    List.for_all
      (fun added ->
         match Identity_map.find_opt (memory_id added) current_by_id with
         | Some current -> String.equal (fact_payload added) (fact_payload current)
         | None -> false)
      change.added
  in
  let removed_are_not_current_payloads =
    List.for_all
      (fun removed ->
         match Identity_map.find_opt (memory_id removed) current_by_id with
         | Some current ->
           not (String.equal (fact_payload removed) (fact_payload current))
         | None -> true)
      change.removed
  in
  let invalidations_match_current_support =
    List.for_all
      (fun invalidation ->
         not (Set_util.StringSet.mem (memory_id invalidation.fact) current_ids)
         &&
         match invalidation.fact.basis with
         | Observed -> false
         | Derived derivations ->
           (not (derivations_supported current_ids derivations))
           && List.equal
                String.equal
                invalidation.missing_premise_ids
                (missing_premises_for current_ids derivations))
      change.invalidated
  in
  added_are_current
  && removed_are_not_current_payloads
  && invalidations_match_current_support
  && change.retained + List.length change.added = List.length facts
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
          let current_ids = support_closure_ids facts in
          if
            Set_util.StringSet.cardinal current_ids = List.length facts
            && valid_snapshot_change ~facts ~current_ids ~change
          then
            Some
              { revision
              ; updated_at
              ; source
              ; facts
              ; change
              }
          else None
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

let compute_change ~previous ~next ~invalidated =
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
    ; invalidated
    }
;;

(* Truth maintenance over positive support sets. Observations seed a worklist;
   each newly supported identity advances only the derivations that name it.
   A derived fact activates when one whole derivation reaches zero missing
   premises. Unsupported cycles never enter the worklist. *)
let maintain_supported_facts facts =
  let current_ids = support_closure_ids facts in
  let current_rev, invalidated_rev =
    List.fold_left
      (fun (current_rev, invalidated_rev) fact ->
         if Set_util.StringSet.mem (memory_id fact) current_ids
         then fact :: current_rev, invalidated_rev
         else
           match fact.basis with
           | Observed -> fact :: current_rev, invalidated_rev
           | Derived derivations ->
             let missing_premise_ids =
               missing_premises_for current_ids derivations
             in
             current_rev, { fact; missing_premise_ids } :: invalidated_rev)
      ([], [])
      facts
  in
  List.rev current_rev, List.rev invalidated_rev
;;

let merge_basis existing incoming =
  match existing, incoming with
  | Observed, Observed | Observed, Derived _ -> Observed
  | Derived _, Observed -> Observed
  | Derived existing, Derived incoming ->
    let derivations =
      List.fold_left
        (fun derivations candidate ->
           if
             List.exists
               (fun current -> String.equal current.rule_id candidate.rule_id)
               derivations
           then
             List.map
               (fun current ->
                  if String.equal current.rule_id candidate.rule_id
                  then candidate
                  else current)
               derivations
           else derivations @ [ candidate ])
        existing
        incoming
    in
    Derived derivations
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
  let fields_are_exact =
    exact_object_fields
      [ "outcome"; "recorded_at"; "revision"; "source"; "change" ]
      fields
    || exact_object_fields
         [ "outcome"
         ; "recorded_at"
         ; "revision"
         ; "source"
         ; "change"
         ; "dropped"
         ]
         fields
  in
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
  if not fields_are_exact
  then Error "committed line has unknown, duplicate, or missing fields"
  else
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
  if
    not
      (exact_object_fields
         [ "outcome"
         ; "recorded_at"
         ; "trace_id"
         ; "kind"
         ; "detail"
         ; "snapshot_present"
         ; "cadence_deferred"
         ]
         fields)
  then Error "failed line has unknown, duplicate, or missing fields"
  else
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

let update_locked_with_error
      ?clock
      ?dropped_statements
      ~store_error
      ~keepers_dir
      ~keeper_id
      build
  =
  let dropped_statements_are_valid =
    match dropped_statements with
    | None -> true
    | Some statements ->
      List.for_all
        (fun (statement : Keeper_memory_os_types.dropped_statement) ->
           Keeper_memory_os_types.is_memory_id statement.memory_id
           && not (String.equal (String.trim statement.reason) ""))
        statements
  in
  if not dropped_statements_are_valid
  then Error (store_error "dropped statements must carry canonical identities and reasons")
  else (
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
             let+ snapshot =
               parse snapshot_path content |> Result.map_error store_error
             in
             Some snapshot
         in
         let* next = build previous in
         let content = Yojson.Safe.pretty_to_string (to_json next) ^ "\n" in
         match Fs_compat.save_file_atomic snapshot_path content with
         | Ok () ->
           append_journal_entry ~keepers_dir ~keeper_id ~dropped_statements next;
           List.iter
             (fun invalidation ->
                Log.Keeper.info
                  "memory os support retracted keeper=%s revision=%d memory_id=%s missing_premise_ids=%s"
                  keeper_id
                  next.revision
                  (memory_id invalidation.fact)
                  (String.concat "," invalidation.missing_premise_ids))
             next.change.invalidated;
           Ok next
         | Error message ->
           Error
             (store_error
                (Printf.sprintf
                   "current Memory OS atomic write failed path=%s: %s"
                   snapshot_path
                   message)))))
;;

let update_locked ?clock ?dropped_statements ~keepers_dir ~keeper_id build =
  update_locked_with_error
    ?clock
    ?dropped_statements
    ~store_error:Fun.id
    ~keepers_dir
    ~keeper_id
    build
;;

let make_snapshot_from_maintained
      ~previous
      ~now
      ~source
      ~facts
      ~invalidated
      ()
  =
  let previous_facts, revision =
    match previous with
    | None -> [], 1
    | Some snapshot -> snapshot.facts, snapshot.revision + 1
  in
  let+ change = compute_change ~previous:previous_facts ~next:facts ~invalidated in
  { revision
  ; updated_at = now
  ; source
  ; facts
  ; change
  }
;;

let make_snapshot
      ~previous
      ~now
      ~source
      ~facts
      ()
  =
  let facts, invalidated = maintain_supported_facts facts in
  make_snapshot_from_maintained
    ~previous
    ~now
    ~source
    ~facts
    ~invalidated
    ()
;;

let replace
      ?clock
      ?dropped_statements
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
    (fun previous ->
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
        ~previous
        ~now
        ~source
        ~facts
        ())
;;

let upsert_fact
      ?clock
      ~keepers_dir
      ~keeper_id
      ~now
      ~source
      incoming
  =
  update_locked_with_error
    ?clock
    ~store_error:(fun detail -> Upsert_persistence_failed detail)
    ~keepers_dir
    ~keeper_id
    (fun previous ->
    let current_facts =
      match previous with
      | None -> []
      | Some snapshot -> snapshot.facts
    in
    let current_ids =
      List.fold_left
        (fun ids fact -> Set_util.StringSet.add (memory_id fact) ids)
        Set_util.StringSet.empty
        current_facts
    in
    let* () =
      match incoming.basis with
      | Observed -> Ok ()
      | Derived derivations when derivations_supported current_ids derivations ->
        Ok ()
      | Derived derivations ->
        Error
          (Unsupported_derivation
             { fact = incoming
             ; missing_premise_ids = missing_premises_for current_ids derivations
             })
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
             ; basis = merge_basis existing.basis incoming.basis
             })
           else existing)
        current_facts
    in
    let facts = if !found then facts else facts @ [ incoming ] in
    let facts, invalidated = maintain_supported_facts facts in
    let incoming_identity = memory_id incoming in
    match
      List.find_opt
        (fun invalidation ->
           String.equal (memory_id invalidation.fact) incoming_identity)
        invalidated
    with
    | Some invalidation -> Error (Unsupported_derivation invalidation)
    | None ->
      make_snapshot_from_maintained
        ~previous
        ~now
        ~source
        ~facts
        ~invalidated
        ()
      |> Result.map_error (fun detail -> Upsert_persistence_failed detail))
;;

let retract_fact
      ?clock
      ~keepers_dir
      ~keeper_id
      ~now
      ~source
      ~memory_id:target_memory_id
      ~reason
      ()
  =
  if not (Keeper_memory_os_types.is_memory_id target_memory_id)
  then Error Retract_memory_id_invalid
  else if String.equal (String.trim reason) ""
  then Error Retract_reason_empty
  else
    update_locked_with_error
      ?clock
      ~dropped_statements:
        [ { Keeper_memory_os_types.memory_id = target_memory_id; reason } ]
      ~store_error:(fun detail -> Retract_persistence_failed detail)
      ~keepers_dir
      ~keeper_id
      (fun previous ->
      let current_facts =
        match previous with
        | None -> []
        | Some snapshot -> snapshot.facts
      in
      if
        not
          (List.exists
             (fun fact ->
                String.equal
                  (Keeper_memory_os_types.memory_id fact)
                  target_memory_id)
             current_facts)
      then Error (Retract_fact_not_found target_memory_id)
      else
        let candidates =
          List.filter
            (fun fact ->
               not
                 (String.equal
                    (Keeper_memory_os_types.memory_id fact)
                    target_memory_id))
            current_facts
        in
        let facts, invalidated = maintain_supported_facts candidates in
        make_snapshot_from_maintained
          ~previous
          ~now
          ~source
          ~facts
          ~invalidated
          ()
        |> Result.map_error (fun detail -> Retract_persistence_failed detail))
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
