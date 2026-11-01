open Keeper_memory_os_current_types

type snapshot_evidence = int * string Lazy.t

type range_key = string * [ `Atom | `Official | `Explicit_candidate of string ]

let range_key = function
  | Atom_range range -> range.receipt_scope, `Atom
  | Official_range range -> range.receipt_scope, `Official
  | Explicit_candidate candidate ->
      candidate.queue_generation, `Explicit_candidate candidate.request_id
  | Explicit_candidate_with_recall binding ->
      binding.candidate_id.queue_generation,
      `Explicit_candidate binding.candidate_id.request_id

module Key_set = Set.Make (struct
  type t = range_key
  let compare = Stdlib.compare
end)

type decision =
  | Keep of durable_range_receipt list
  | Remove
  | Rewrite of durable_range_receipt list

type t =
  { all_verified_for_archive : durable_range_receipt list
  ; unproven : (int * durable_range_receipt) list
  ; decision : decision
  }

let receipt_range_id = function
  | Prepared { range_id; _ } | Committed { range_id; _ } -> range_id

let verify ~(snapshot : snapshot_evidence option) = function
  | Prepared { range_id; snapshot_revision; snapshot_sha256 } ->
      (match snapshot with
       | Some (revision, digest)
         when Int.equal revision snapshot_revision
              && String.equal (Lazy.force digest) snapshot_sha256 ->
           Some (Committed { range_id; snapshot_revision; snapshot_sha256 })
       | None | Some _ -> None)
  | Committed ({ snapshot_revision; snapshot_sha256; _ } as committed) ->
      (match snapshot with
       | Some (revision, _) when revision > snapshot_revision ->
           Some (Committed committed)
       | Some (revision, digest)
         when Int.equal revision snapshot_revision
              && String.equal (Lazy.force digest) snapshot_sha256 ->
           Some (Committed committed)
       | None | Some _ -> None)

let select ~snapshot ~had_skipped_entries receipts =
  let all_verified_for_archive = List.filter_map (verify ~snapshot) receipts in
  let unproven =
    List.mapi (fun index receipt -> index, receipt) receipts
    |> List.filter_map (fun (index, receipt) ->
        let range_id = receipt_range_id receipt in
        if List.exists
             (fun known -> receipt_range_id known = range_id)
             all_verified_for_archive
        then None
        else Some (index, receipt))
  in
  let _, reconciled_rev =
    List.fold_left (fun (seen, kept) receipt ->
        let key = range_key (receipt_range_id receipt) in
        if Key_set.mem key seen then seen, kept
        else Key_set.add key seen, receipt :: kept)
      (Key_set.empty, []) all_verified_for_archive
  in
  let reconciled = List.rev reconciled_rev in
  let decision =
    if receipts = reconciled && not had_skipped_entries then Keep reconciled
    else match reconciled with
      | [] -> Remove
      | _ :: _ -> Rewrite reconciled
  in
  { all_verified_for_archive; unproven; decision }
