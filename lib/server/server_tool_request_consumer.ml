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
