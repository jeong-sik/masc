module Ledger = Keeper_skill_activation_ledger

type kept =
  { revision : string
  ; mutable by_reference : (Skill_reference.t * Ledger.catalog_usage option) list
  }

let kept : (string * string, kept) Hashtbl.t = Hashtbl.create 16
let kept_mu = Stdlib.Mutex.create ()

let usage ~base_path ~keeper_name ledger reference =
  let revision = Ledger.ledger_revision_to_string (Ledger.revision ledger) in
  let key = base_path, keeper_name in
  let found =
    Stdlib.Mutex.protect kept_mu (fun () ->
      match Hashtbl.find_opt kept key with
      | Some current when String.equal current.revision revision ->
        List.find_map
          (fun (seen, usage) -> if Skill_reference.equal seen reference then Some usage else None)
          current.by_reference
      | Some _ | None ->
        Hashtbl.replace kept key { revision; by_reference = [] };
        None)
  in
  match found with
  | Some usage -> usage
  | None ->
    let usage = Ledger.usage_for_reference ledger reference in
    Stdlib.Mutex.protect kept_mu (fun () ->
      match Hashtbl.find_opt kept key with
      | Some current when String.equal current.revision revision ->
        current.by_reference <- (reference, usage) :: current.by_reference
      | Some _ | None -> ());
    usage
;;
