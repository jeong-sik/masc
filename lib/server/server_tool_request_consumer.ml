type t =
  | Completion_review
  | Goal_proof_review
  | Candle_appraisal
  | Media_reading
[@@deriving enumerate]

let scope = function
  | Completion_review -> Verifier_review_owner.scope
  | Goal_proof_review -> Goal_verifier_worker.scope
  | Candle_appraisal -> Server_candle_appraiser.scope
  | Media_reading -> Keeper_media_reading_owner.scope
;;

let of_scope stored = List.find_opt (fun consumer -> String.equal stored (scope consumer)) all

type retired_scope =
  | Workspace_curator
  | Keeper_librarian_parts of { scope_hash : string }
  | Keeper_librarian_partitions of { scope_hash : string }
  | Keeper_librarian_admission_gate of { scope_hash : string }
  | Keeper_librarian_admission_closure of { scope_hash : string }

type scope_classification =
  | Active of t
  | Retired of retired_scope

let is_lowercase_sha256_hex s =
  String.length s = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       s
;;

let hashed_retired_scope ~prefix ~make stored =
  if String.starts_with ~prefix stored
  then (
    let plen = String.length prefix in
    let scope_hash = String.sub stored plen (String.length stored - plen) in
    if is_lowercase_sha256_hex scope_hash then Some (make scope_hash) else None)
  else None
;;

let retired_of_scope stored =
  if String.equal stored "workspace-curator"
  then Some Workspace_curator
  else
    match
      hashed_retired_scope
        ~prefix:"keeper-librarian-parts/"
        ~make:(fun scope_hash -> Keeper_librarian_parts { scope_hash })
        stored
    with
    | Some _ as hit -> hit
    | None ->
      (match
         hashed_retired_scope
           ~prefix:"keeper-librarian-partitions/"
           ~make:(fun scope_hash -> Keeper_librarian_partitions { scope_hash })
           stored
       with
       | Some _ as hit -> hit
       | None ->
         (match
            hashed_retired_scope
              ~prefix:"keeper-librarian-admission-gate/"
              ~make:(fun scope_hash -> Keeper_librarian_admission_gate { scope_hash })
              stored
          with
          | Some _ as hit -> hit
          | None ->
            hashed_retired_scope
              ~prefix:"keeper-librarian-admission-closure/"
              ~make:(fun scope_hash -> Keeper_librarian_admission_closure { scope_hash })
              stored))
;;

let classify_scope stored =
  match of_scope stored with
  | Some consumer -> Some (Active consumer)
  | None -> Option.map (fun retired -> Retired retired) (retired_of_scope stored)
;;
