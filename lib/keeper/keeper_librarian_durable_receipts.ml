(** Actual complete original receipt state. This has no dependency on
    resolution intents, lineage, floor execution or source ACK. *)
module Request = Keeper_librarian_durable_request
module Source = Keeper_librarian_durable_capture
module Current = Keeper_memory_os_current
open Result.Syntax
let require condition detail = if condition then Ok () else Error detail
(* A range the message floor published carries the messages it could not read
   in its receipt identity; the original names none. The range is the same. *)
let same_atom_range (expected : Current.durable_range_id) (actual : Current.durable_range_id) =
  Yojson.Safe.equal (Current.durable_range_id_to_json {expected with unread_messages=[]})
    (Current.durable_range_id_to_json {actual with unread_messages=[]})
let same_official_range (expected : Current.official_range_id) (actual : Current.official_range_id) =
  Yojson.Safe.equal (Current.official_range_id_to_json {expected with unread_messages=[]})
    (Current.official_range_id_to_json {actual with unread_messages=[]})
let state request =
  let source=Request.source request and owner=Request.physical_owner request in
  let keepers_dir=Request.keepers_dir owner and keeper_id=Request.keeper_id owner in
  let* atom=match Source.range_id source with
    | None -> Ok None
    | Some expected ->
      let* actual=Current.committed_durable_coverage ~keepers_dir ~keeper_id
        ~receipt_scope:expected.receipt_scope in
      Ok (Some (Option.fold ~none:false ~some:(fun actual -> same_atom_range expected actual) actual)) in
  let* official=match Source.official_range_id source with
    | None -> Ok None
    | Some expected ->
      let* actual=Current.committed_official_coverage ~keepers_dir ~keeper_id
        ~receipt_scope:expected.receipt_scope in
      Ok (Some (Option.fold ~none:false ~some:(fun actual -> same_official_range expected actual) actual)) in
  let proofs=Option.to_list atom @ Option.to_list official in
  let* ()=require (proofs<>[]) "Original history has no Memory range receipts" in
  if List.for_all Fun.id proofs then Ok true
  else if List.exists Fun.id proofs then Error "Original history has only a partial committed range receipt set"
  else Ok false
