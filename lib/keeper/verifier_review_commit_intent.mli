(** Authenticate the retained domain intent against its one original/judgment.
    This codec performs no domain observation or mutation. *)
val before_of_status : original:Verifier_review_original.t -> Masc_domain.task_status ->
  (Yojson.Safe.t, string) result
val before_status : original:Verifier_review_original.t -> Yojson.Safe.t ->
  (Masc_domain.task_status, string) result
(** One strict codec for the actual captured Awaiting state and derived intent.
    It reuses the canonical status metadata validator without another read. *)

val decode :
  original:Verifier_review_original.t -> judgment:Yojson.Safe.t ->
  authority:Masc_domain.completion_authority ->
  Lane_addon_request_progress.change ->
  (string * string * Task.Anti_rationalization.review_result *
    Task.Anti_rationalization.verdict, string) result

val prepare :
  original:Verifier_review_original.t -> judgment:Yojson.Safe.t ->
  authority:Masc_domain.completion_authority -> before:Yojson.Safe.t ->
  (Lane_addon_request_progress.change, string) result
(** Derive the exact existing commit intent from its captured before-state and
    one retained judgment; authenticate with the same decoder before returning. *)
