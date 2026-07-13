(** Keeper_memory_os_gc — exact explicit-expiry cleanup for facts. *)

open Keeper_memory_os_types

module Io = Keeper_memory_os_io
module String_map = Map.Make (String)

type gc_report =
  { total_input : int
  ; ttl_expired : int
  ; ttl_expired_ephemeral : int
  ; ttl_expired_non_ephemeral : int
  ; ttl_expired_by_category : (string * int) list
  ; written : int
  ; dry_run : bool
  }

exception Fact_store_corrupt of string

(* Exact producer validity boundary. Same boundary at equality:
   [ts >= now] current ⇔ [now > ts] expired. *)
let ttl_expired ~now (fact : fact) = not (fact_is_current ~now fact)

let bump_count key counts =
  let current =
    match String_map.find_opt key counts with
    | Some count -> count
    | None -> 0
  in
  String_map.add key (current + 1) counts
;;

let expired_category_counts expired =
  let ephemeral, non_ephemeral, by_category =
    List.fold_left
      (fun (ephemeral, non_ephemeral, by_category) (fact : fact) ->
         let category = fact.category in
         let category_key = category_to_string category in
         let ephemeral, non_ephemeral =
           match category with
           | Ephemeral -> ephemeral + 1, non_ephemeral
           | Fact
           | Constraint
           | Preference
           | Code_change
           | Validated_approach
           | Lesson
           | Blocker
           | Goal
           | Unknown _ -> ephemeral, non_ephemeral + 1
         in
         ephemeral, non_ephemeral, bump_count category_key by_category)
      (0, 0, String_map.empty)
      expired
  in
  ephemeral, non_ephemeral, String_map.bindings by_category
;;

(* GC performs one authorized deletion only: an explicit [valid_until] in the
   past. It does not deduplicate or rank rows; semantic forgetting belongs to the
   configured Memory/LLM consolidation plan. *)
let run_gc_with_store
      ~facts_path
      ~read_facts_all_strict
      ~rewrite_facts_atomically
      ?(dry_run = false)
      ~keeper_id
      ~now
      ()
  =
  (* Serialize the whole read-modify-rewrite on the same per-keeper facts lock the
     librarian write path (Keeper_librarian_runtime, wrapping [merge_facts])
     and the consolidation runtime already hold on facts_path. Without it, a
     librarian merge that commits between GC's read and GC's rewrite is silently
     overwritten — a lost update that permanently drops a freshly persisted fact.
     The lock spans both the read and the rewrite, so no concurrent writer can
     interleave; because the read-modify-rewrite is entirely inside the lock there
     is no unlocked gap to guard with a snapshot CAS (unlike
     Keeper_memory_os_consolidation_runtime, whose LLM call runs between its read
     and rewrite and so re-validates the snapshot under the lock). No clock is
     threaded: lock-retry sleeps run on a systhread (off the keeper hot path, GC
     is a 600s maintenance sweep, so cooperative yielding buys nothing), and
     File_lock_eio already offloads the blocking flock so the Eio domain is not
     stalled. Must run inside an Eio context (the maintenance fiber and tests
     both are). *)
  File_lock_eio.with_lock facts_path (fun () ->
    (* Read strictly: a malformed JSONL row aborts the sweep rather than being
       silently dropped by the lenient decoder and then erased by the rewrite
       below. Every other destructive rewrite path already refuses to overwrite a
       store it cannot fully parse — [merge_facts] via
       read_facts_for_rewrite, the consolidator and consolidation runtime via
       read_facts_all_strict. GC was the lone path that turned one corrupt line
       into permanent deletion of the surrounding facts (it read via the lenient
       read_facts_all). Preserve over delete: leave a corrupt store untouched and
       let the raised error surface so an operator can repair it. *)
    match read_facts_all_strict () with
    | Error message ->
      raise (Fact_store_corrupt ("memory os gc fact store read failed: " ^ message))
    | Ok facts ->
      let live, expired =
        List.partition (fun fact -> not (ttl_expired ~now fact)) facts
      in
      let ttl_expired_ephemeral, ttl_expired_non_ephemeral, ttl_expired_by_category =
        expired_category_counts expired
      in
      let survivors = live in
      if not dry_run then rewrite_facts_atomically survivors;
      { total_input = List.length facts
      ; ttl_expired = List.length expired
      ; ttl_expired_ephemeral
      ; ttl_expired_non_ephemeral
      ; ttl_expired_by_category
      ; written = List.length survivors
      ; dry_run
      })
;;

let run_gc ?dry_run ~keeper_id ~now () =
  run_gc_with_store
    ~facts_path:(Io.facts_path ~keeper_id)
    ~read_facts_all_strict:(fun () -> Io.read_facts_all_strict ~keeper_id)
    ~rewrite_facts_atomically:(fun facts -> Io.rewrite_facts_atomically ~keeper_id facts)
    ?dry_run
    ~keeper_id
    ~now
    ()
;;

let run_gc_for_keepers_dir ~keepers_dir ?dry_run ~keeper_id ~now () =
  run_gc_with_store
    ~facts_path:(Io.facts_path_for_keepers_dir ~keepers_dir ~keeper_id)
    ~read_facts_all_strict:(fun () ->
      Io.read_facts_all_strict_for_keepers_dir ~keepers_dir ~keeper_id)
    ~rewrite_facts_atomically:(fun facts ->
      Io.rewrite_facts_atomically_for_keepers_dir ~keepers_dir ~keeper_id facts)
    ?dry_run
    ~keeper_id
    ~now
    ()
;;
