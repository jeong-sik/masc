(** Memory fact listings and the pure all-Keepers projection. *)

open Tui_decode_fields
let ( let* ) = Result.bind

type memory_fact_retrieval =
  | Never_retrieved
  | Retrieved of { count : int; distinct_days : int; last_at : float }

type memory_fact_events = {
  mfe_retrieval : memory_fact_retrieval;
  mfe_retracted_count : int;
  mfe_revised_from : string list;
}

let no_memory_fact_events =
  { mfe_retrieval = Never_retrieved
  ; mfe_retracted_count = 0
  ; mfe_revised_from = []
  }

type memory_fact = {
  mf_keeper : string;
  mf_claim : string;
  mf_category : Keeper_memory_os_types.category;
  mf_origin : string;
  mf_first_seen : float;
  mf_last_seen : float;
  mf_memory_id : string;
  mf_events : memory_fact_events;
}

type memory_source_fact = {
  msf_keeper : string;
  msf_claim : string;
  msf_first_seen : float;
  msf_path : string;
  msf_sha256 : string;
}

type memory_invalidation = {
  mi_keeper : string;
  mi_source_path : string;
  mi_invalidated_at : float;
  mi_reason : string;
}

type 'a memory_store_reading =
  | Memory_store_read_error of string
  | Memory_store_absent
  | Memory_store_present of 'a

type memory_ordinary_store = {
  mos_facts : memory_fact list;
}

type memory_source_store = {
  mss_facts : memory_source_fact list;
  mss_invalidations : memory_invalidation list;
}

type memory_fact_snapshot = {
  mfs_keeper : string;
  mfs_ordinary : memory_ordinary_store memory_store_reading;
  mfs_source : memory_source_store memory_store_reading;
  mfs_events_read_error : string option;
}

(* The server computes these from the keeper's memory-events sidecar and
   never stores them (RFC-0418). This side shows the record as it is. *)
let decode_memory_fact_events json =
  let* retrieved_count = required_int_field json "retrieved_count" in
  let* retrieved_distinct_days = required_int_field json "retrieved_distinct_days" in
  let* last_retrieved_at = optional_float_field json "last_retrieved_at" in
  (* The server derives all three from one list of retrieval times
     ([Keeper_memory_os_events.summary_for]): an empty list gives 0, 0 and
     null, and a non-empty one gives a positive count, at least one day and
     a clock. Any other combination is not a record this decoder knows, so it
     is rejected here once instead of every reader drawing it. *)
  let* mfe_retrieval =
    match retrieved_count, retrieved_distinct_days, last_retrieved_at with
    | 0, 0, None -> Ok Never_retrieved
    | count, distinct_days, Some last_at when count > 0 && distinct_days > 0 ->
        Ok (Retrieved { count; distinct_days; last_at })
    | count, distinct_days, (None | Some _) ->
        Error
          (Printf.sprintf
             "memory fact events disagree: retrieved_count %d, \
              retrieved_distinct_days %d, last_retrieved_at %s"
             count distinct_days
             (match last_retrieved_at with
              | None -> "null"
              | Some at -> Float.to_string at))
  in
  let* mfe_retracted_count = required_int_field json "retracted_count" in
  let* mfe_revised_from = require_string_list json "revised_from" in
  Ok { mfe_retrieval; mfe_retracted_count; mfe_revised_from }

let decode_memory_fact ~keeper json =
  let* mf_claim = required_string_field json "claim" in
  let* raw_category = required_string_field json "category" in
  let* mf_category =
    (* The librarian taxonomy is a closed sum on the side that writes it
       ([Keeper_memory_os_types.category]; the model's schema enum is built
       from it and anything outside is rejected), so a word this build does
       not know is a store written by something newer, not a category. *)
    match Keeper_memory_os_types.category_of_string raw_category with
    | Some category -> Ok category
    | None -> Error (Printf.sprintf "unknown memory category %S" raw_category)
  in
  let* mf_origin = required_string_field json "origin" in
  let* mf_first_seen = Json_util.require_float json "first_seen" in
  let* mf_last_seen = Json_util.require_float json "last_seen" in
  let* mf_memory_id = required_string_field json "memory_id" in
  let* events_json = required_object_field json "events" in
  let* mf_events = decode_memory_fact_events events_json in
  Ok
    { mf_keeper = keeper
    ; mf_claim
    ; mf_category
    ; mf_origin
    ; mf_first_seen
    ; mf_last_seen
    ; mf_memory_id
    ; mf_events
    }

let decode_memory_source_fact ~keeper json =
  let* msf_claim = required_string_field json "claim" in
  let* msf_first_seen = Json_util.require_float json "first_seen" in
  let* msf_path = required_string_field json "path" in
  let* msf_sha256 = required_string_field json "sha256" in
  Ok { msf_keeper = keeper; msf_claim; msf_first_seen; msf_path; msf_sha256 }

let decode_memory_invalidation ~keeper json =
  let* mi_source_path = required_string_field json "source_path" in
  let* mi_invalidated_at = Json_util.require_float json "invalidated_at" in
  let* mi_reason = required_string_field json "reason" in
  Ok { mi_keeper = keeper; mi_source_path; mi_invalidated_at; mi_reason }

(* The server answers each store with exactly one of three shapes:
   {"read_error"}, {"present": false}, or {"present": true, ...rows}. Read
   by which field is there; anything else is a decode error, never an empty
   store, so a broken reading cannot pass as "remembers nothing". *)
let decode_memory_store_reading ~label decode_present json =
  match Json_util.assoc_member_opt "read_error" json with
  | Some (`String detail) -> Ok (Memory_store_read_error detail)
  | Some other ->
      Error
        (Printf.sprintf "%s.read_error must be a string (received %s)" label
           (Json_util.kind_name other))
  | None ->
      let* present = required_bool_field json "present" in
      if not present then Ok Memory_store_absent
      else
        let* value = decode_present json in
        Ok (Memory_store_present value)

let decode_memory_ordinary_store ~keeper json =
  let* facts_json = required_list_field json "facts" in
  let* mos_facts = decode_list "facts" (decode_memory_fact ~keeper) facts_json in
  Ok { mos_facts }

let decode_memory_source_store ~keeper json =
  let* facts_json = required_list_field json "facts" in
  let* mss_facts = decode_list "facts" (decode_memory_source_fact ~keeper) facts_json in
  let* invalidations_json = required_list_field json "invalidations" in
  let* mss_invalidations =
    decode_list "invalidations" (decode_memory_invalidation ~keeper) invalidations_json
  in
  Ok { mss_facts; mss_invalidations }

let decode_memory_fact_snapshot json =
  let* mfs_keeper = required_string_field json "keeper" in
  let* mfs_events_read_error = required_nullable_string_field json "events_read_error" in
  let* ordinary_json = required_member json "ordinary" in
  let* mfs_ordinary =
    decode_memory_store_reading ~label:"ordinary"
      (decode_memory_ordinary_store ~keeper:mfs_keeper) ordinary_json
  in
  let* source_json = required_member json "source_bound" in
  let* mfs_source =
    decode_memory_store_reading ~label:"source_bound"
      (decode_memory_source_store ~keeper:mfs_keeper) source_json
  in
  Ok { mfs_keeper; mfs_ordinary; mfs_source; mfs_events_read_error }

let merge_keeper_memory_facts loads =
  let step (ord, src, invals, event_errors, unread) (keeper_name, load) =
    match load with
    | Error detail -> ord, src, invals, event_errors, (keeper_name, detail) :: unread
    | Ok snap ->
      let event_errors =
        match snap.mfs_events_read_error with
        | None -> event_errors
        | Some detail -> Printf.sprintf "%s: %s" keeper_name detail :: event_errors
      in
      let ord, unread =
        match snap.mfs_ordinary with
        | Memory_store_present store ->
          ( List.rev_append
              (List.map
                 (fun (f : memory_fact) -> { f with mf_keeper = keeper_name })
                 store.mos_facts)
              ord
          , unread )
        | Memory_store_read_error detail ->
          ord, (keeper_name, "ordinary store: " ^ detail) :: unread
        | Memory_store_absent -> ord, unread
      in
      let src, invals, unread =
        match snap.mfs_source with
        | Memory_store_present store ->
          ( List.rev_append
              (List.map
                 (fun (f : memory_source_fact) -> { f with msf_keeper = keeper_name })
                 store.mss_facts)
              src
          , List.rev_append
              (List.map
                 (fun (inv : memory_invalidation) -> { inv with mi_keeper = keeper_name })
                 store.mss_invalidations)
              invals
          , unread )
        | Memory_store_read_error detail ->
          src, invals, (keeper_name, "source-bound store: " ^ detail) :: unread
        | Memory_store_absent -> src, invals, unread
      in
      ord, src, invals, event_errors, unread
  in
  let ord, src, invals, event_errors, unread =
    List.fold_left step ([], [], [], [], []) loads
  in
  let snapshot =
    { mfs_keeper = "*"
    ; mfs_ordinary =
        Memory_store_present { mos_facts = List.rev ord }
    ; mfs_source =
        Memory_store_present
          { mss_facts = List.rev src
          ; mss_invalidations = List.rev invals
          }
    ; mfs_events_read_error =
        (match List.rev event_errors with
         | [] -> None
         | errors -> Some (String.concat "; " errors))
    }
  in
  let unread_summary =
    match List.rev unread with
    | [] -> None
    | failures ->
      Some
        (Printf.sprintf "%d of %d keepers not read: %s"
           (List.length (List.sort_uniq String.compare (List.map fst failures)))
           (List.length loads)
           (String.concat "; "
              (List.map (fun (keeper_name, detail) -> keeper_name ^ ": " ^ detail) failures)))
  in
  snapshot, unread_summary
