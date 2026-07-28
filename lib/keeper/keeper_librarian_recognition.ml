(** Keeper_librarian_recognition — the librarian's store-aware write contract.

    masc#26122: storage is recognition. The librarian reads the conversation
    window TOGETHER WITH the keeper's current fact store (rendered with 0-based
    indices) and returns typed operations. Whether something is already known
    is the model's judgment — no hash, byte comparison, or similarity threshold
    participates in the write decision. This module owns the operation domain
    and the pure application; parsing lives in [Keeper_librarian] (the wire
    boundary), IO/locking in [Keeper_librarian_runtime]. *)

open Keeper_memory_os_types
module Consolidation = Keeper_memory_os_consolidation

type valid_until_update =
  | Keep_valid_until
  | Clear_valid_until
  | Set_valid_for_days of int

type operation =
  | Add of fact
    (* New knowledge, fully authored by the librarian. *)
  | Reinforce of
      { index : int
      ; source_turn : int
      }
    (* The claim at [index] was re-recognized in this window. The row keeps its
       identity; only [last_verified_at] and [reinforcement_count] move. The
       re-observation's provenance ([source_turn]) is persisted in the
       recognition ledger, not on the row. *)
  | Merge of Consolidation.merge_group
    (* Two or more existing rows state the same knowledge; the librarian wrote
       the consolidated claim. Same structural gates as consolidation. *)
  | Revise of
      { index : int
      ; claim : string
      ; category : category option (* None = keep the row's category *)
      ; claim_id : string option (* None = keep the row's claim_id *)
      ; valid_until_update : valid_until_update
      }
    (* The claim at [index] is superseded by a corrected statement. *)
  | Forget of
      { index : int
      ; reason : string
      }
    (* The claim at [index] no longer holds. The reason is evidence, persisted
       in the recognition ledger. *)

let operation_label = function
  | Add _ -> wire_op_add
  | Reinforce _ -> wire_op_reinforce
  | Merge _ -> wire_op_merge
  | Revise _ -> wire_op_revise
  | Forget _ -> wire_op_forget
;;

(* Typed outcomes only. Rejections are representability/referencing failures
   or explicit recall-injection provenance, never heuristic identity judgment. *)
type disposition =
  | Applied
  | Rejected_target_overlap
  | Rejected_index_out_of_bounds
  | Rejected_target_consumed
  | Rejected_kind_mismatch
  | Rejected_valid_until_mismatch
  | Rejected_too_few_members
  | Rejected_recalled_echo

let disposition_label = function
  | Applied -> "applied"
  | Rejected_target_overlap -> "rejected_target_overlap"
  | Rejected_index_out_of_bounds -> "rejected_index_out_of_bounds"
  | Rejected_target_consumed -> "rejected_target_consumed"
  | Rejected_kind_mismatch -> "rejected_kind_mismatch"
  | Rejected_valid_until_mismatch -> "rejected_valid_until_mismatch"
  | Rejected_too_few_members -> "rejected_too_few_members"
  | Rejected_recalled_echo -> "rejected_recalled_echo"
;;

type apply_result =
  { facts : fact list
    (* The new store: surviving rows in original order (a merged row takes its
       earliest member's slot), added rows appended at the end. *)
  ; recognized_facts : fact list
    (* Rows created or rewritten by this pass (Add/Merge/Revise output), in
       operation order — the episode's [claims]. Reinforce is excluded: it
       confirms existing knowledge rather than producing new rows. *)
  ; dispositions : disposition list
    (* Positionally 1:1 with the input operations. *)
  }

let target_indices = function
  | Add _ -> []
  | Reinforce { index; _ } | Revise { index; _ } | Forget { index; _ } -> [ index ]
  | Merge group -> List.sort_uniq compare group.Consolidation.member_indices
;;

let operations_have_overlapping_targets operations =
  let seen = Hashtbl.create 8 in
  List.exists
    (fun operation ->
       List.exists
         (fun index ->
            if Hashtbl.mem seen index
            then true
            else (
              Hashtbl.add seen index ();
              false))
         (target_indices operation))
    operations
;;

(* Apply recognition operations to the store snapshot the librarian saw.
   Target overlap is a malformed operation set, not an ordering policy: a
   model must not be able to choose a destructive result by merely reordering
   two operations. The wire parser rejects such output before this boundary;
   this pure guard gives the same fail-closed result to direct callers. *)
let apply ?(recalled_reinforcement_indices = []) ~now ~operations facts =
  if operations_have_overlapping_targets operations
  then
    { facts
    ; recognized_facts = []
    ; dispositions = List.map (fun _ -> Rejected_target_overlap) operations
    }
  else
  let facts_arr = Array.of_list facts in
  let n = Array.length facts_arr in
  let in_range i = i >= 0 && i < n in
  (* [`Free] rows survive unless later consumed. [`Touched] rows were
     reinforced/revised in place. [`Dropped] rows leave the store (Forget or
     merged-away). A merged row is keyed by its anchor slot like
     [Consolidation.apply_plan]. *)
  let slot = Array.make n `Free in
  let merged_at = Hashtbl.create 8 in
  let added = ref [] in
  let recognized = ref [] in
  let target_free i = in_range i && slot.(i) = `Free in
  let apply_one op =
    match op with
    | Add fact ->
      added := fact :: !added;
      recognized := fact :: !recognized;
      Applied
    | Reinforce { index; source_turn = _ } ->
      if not (in_range index)
      then Rejected_index_out_of_bounds
      else if List.mem index recalled_reinforcement_indices
      then Rejected_recalled_echo
      else if slot.(index) <> `Free
      then Rejected_target_consumed
      else (
        let row = facts_arr.(index) in
        facts_arr.(index)
        <- { row with
             last_verified_at = Some now
           ; reinforcement_count = row.reinforcement_count + 1
           };
        slot.(index) <- `Touched;
        Applied)
    | Revise { index; claim; category; claim_id; valid_until_update } ->
      if not (in_range index)
      then Rejected_index_out_of_bounds
      else if slot.(index) <> `Free
      then Rejected_target_consumed
      else (
        let row = facts_arr.(index) in
        let revised =
          { row with
            claim
          ; (* DET-OK: typed optional op payload — the wire contract defines
               null as "keep the row's value"; parser rejected malformed. *)
            category = Option.value category ~default:row.category
          ; claim_id =
              (match claim_id with
               | Some id -> Some id
               | None -> row.claim_id)
          ; valid_until =
              (match valid_until_update with
               | Keep_valid_until -> row.valid_until
               | Clear_valid_until -> None
               | Set_valid_for_days days -> Some (valid_until_of_days ~now days))
          ; last_verified_at = Some now
          ; reinforcement_count = 0
          }
        in
        facts_arr.(index) <- revised;
        slot.(index) <- `Touched;
        recognized := revised :: !recognized;
        Applied)
    | Forget { index; reason = _ } ->
      if not (in_range index)
      then Rejected_index_out_of_bounds
      else if slot.(index) <> `Free
      then Rejected_target_consumed
      else (
        slot.(index) <- `Dropped;
        Applied)
    | Merge group ->
      (* A member can only be consumed by a preceding non-overlapping operation
         from a direct caller. The parser rejects overlapping model output,
         while this remains a defensive structural gate for the pure API. *)
      let members = List.sort_uniq compare group.Consolidation.member_indices in
      if List.exists (fun i -> not (in_range i)) members
      then Rejected_index_out_of_bounds
      else if not (List.for_all target_free members)
      then Rejected_target_consumed
      else (match members with
       | [] | [ _ ] -> Rejected_too_few_members
       | _ :: _ :: _ ->
         let member_facts = List.map (fun i -> facts_arr.(i)) members in
         if not (Consolidation.group_preserves_claim_kind ~members:member_facts)
         then Rejected_kind_mismatch
         else if not (Consolidation.group_preserves_valid_until ~members:member_facts)
         then Rejected_valid_until_mismatch
         else (
           let anchor =
             match members with
             | [] ->
               invalid_arg "Keeper_librarian_recognition.apply: empty merge members"
             | first :: rest ->
               List.fold_left
                 (fun acc i ->
                    if facts_arr.(i).first_seen < facts_arr.(acc).first_seen
                    then i
                    else acc)
                 first
                 rest
           in
           let merged =
             Consolidation.consolidated_fact ~now ~members:member_facts group
           in
           List.iter (fun i -> slot.(i) <- `Dropped) members;
           Hashtbl.replace merged_at anchor merged;
           recognized := merged :: !recognized;
           Applied))
  in
  let dispositions = List.map apply_one operations in
  let out = ref (List.rev !added) in
  for i = n - 1 downto 0 do
    (match slot.(i) with
     | `Free | `Touched -> out := facts_arr.(i) :: !out
     | `Dropped -> ());
    match Hashtbl.find_opt merged_at i with
    | Some merged -> out := merged :: !out
    | None -> ()
  done;
  { facts = !out
  ; recognized_facts = List.rev !recognized
  ; dispositions
  }
;;

(* JSON projection of one operation for the recognition evidence ledger.
   Add/Merge/Revise re-serialize their librarian-authored payloads; index
   references and reasons are preserved verbatim. *)
let operation_to_json op : Yojson.Safe.t =
  let base = [ wire_field_op, `String (operation_label op) ] in
  let rest =
    match op with
    | Add fact -> [ wire_field_fact, fact_to_json fact ]
    | Reinforce { index; source_turn } ->
      [ wire_field_index, `Int index; wire_field_source_turn, `Int source_turn ]
    | Merge { member_indices; consolidated_claim; category } ->
      [ ( wire_field_member_indices
        , `List (List.map (fun i -> `Int i) member_indices) )
      ; wire_field_claim, `String consolidated_claim
      ; wire_field_category, `String (category_to_string category)
      ]
    | Revise { index; claim; category; claim_id; valid_until_update } ->
      [ wire_field_index, `Int index; wire_field_claim, `String claim ]
      @ (match category with
         | Some c -> [ wire_field_category, `String (category_to_string c) ]
         | None -> [])
      @ (match claim_id with
         | Some id -> [ wire_field_claim_id, `String id ]
         | None -> [])
      @ (match valid_until_update with
         | Keep_valid_until -> []
         | Clear_valid_until -> [ wire_field_valid_for_days, `Null ]
         | Set_valid_for_days days -> [ wire_field_valid_for_days, `Int days ])
    | Forget { index; reason } ->
      [ wire_field_index, `Int index; wire_field_reason, `String reason ]
  in
  `Assoc (base @ rest)
;;
