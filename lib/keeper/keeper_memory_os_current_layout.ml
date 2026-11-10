open Keeper_memory_os_types
open Result.Syntax
open Keeper_memory_os_current_types

let suffix = ".memory-current.json"

let upsert_error_to_string = function
  | Unsupported_derivation invalidation ->
    Printf.sprintf
      "derived Memory OS fact has no complete support path memory_id=%s missing_premise_ids=%s"
      (memory_id invalidation.fact)
      (String.concat "," invalidation.missing_premise_ids)
  | Upsert_persistence_failed detail -> detail
;;

let merge_basis = Keeper_memory_os_support_core.merge_basis

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

let journal_suffix = ".memory-journal.jsonl"

let journal_path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ journal_suffix)
;;

let durable_range_receipt_suffix = ".librarian-range-commit.json"

let durable_range_receipt_path ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ durable_range_receipt_suffix)
;;

let unread_ledger_path = Keeper_librarian_unread_ledger.path

let publication_receipt_suffix = ".memory-publication.json"

let publication_receipt_path ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ publication_receipt_suffix)
;;

let epoch_suffix = ".memory-epoch.json"

let epoch_path ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ epoch_suffix)

let read_epoch ~keepers_dir ~keeper_id =
  match Fs_compat.load_file_opt (epoch_path ~keepers_dir ~keeper_id) with
  | None -> Ok None
  | Some text ->
    (match Yojson.Safe.from_string text with
     | `Assoc fields ->
       let* () = exact_field_names_result ["schema_version";"epoch"] fields
         |> Result.map_error wire_error_to_string in
       (match List.assoc "schema_version" fields, List.assoc "epoch" fields with
        | `Int 1, `String epoch when String.trim epoch <> "" && epoch = String.trim epoch -> Ok (Some epoch)
        | _ -> Error "invalid Memory incarnation epoch")
     | _ -> Error "Memory incarnation epoch is not an object"
     | exception Yojson.Json_error detail -> Error ("Memory incarnation epoch: " ^ detail))

let rotate_epoch ~keepers_dir ~keeper_id =
  let epoch = Random_id.uuid_v7 () in
  let+ () = Fs_compat.save_file_atomic_strict (epoch_path ~keepers_dir ~keeper_id)
    (Yojson.Safe.to_string (`Assoc ["schema_version",`Int 1;"epoch",`String epoch])) in
  epoch

let ensure_epoch ~keepers_dir ~keeper_id =
  let* epoch = read_epoch ~keepers_dir ~keeper_id in
  match epoch with Some epoch -> Ok epoch | None -> rotate_epoch ~keepers_dir ~keeper_id

let retraction_plan_receipt_suffix = ".memory-retraction-plan.json"

let retraction_plan_receipt_path ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ retraction_plan_receipt_suffix)
;;
