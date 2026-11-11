type one_scope =
  | Workspace_curator
  | Completion_review
  | Goal_proof_review
  | Candle_appraisal
[@@deriving enumerate]

type t =
  | Librarian of Keeper_librarian_store_preflight.purpose
  | One_scope of one_scope

let scope = function
  | Workspace_curator -> Workspace_memory_execution_capture.scope
  | Completion_review -> Verifier_review_owner.scope
  | Goal_proof_review -> Goal_verifier_worker.scope
  | Candle_appraisal -> Server_candle_appraiser.scope
;;

let of_scope stored =
  match Keeper_librarian_store_preflight.purpose stored with
  | Some purpose -> Some (Librarian purpose)
  | None ->
    List.find_map
      (fun consumer ->
         if String.equal stored (scope consumer) then Some (One_scope consumer) else None)
      all_of_one_scope
;;
