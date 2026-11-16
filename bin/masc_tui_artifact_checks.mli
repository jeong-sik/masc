(** Read-only projection of shared, explicit revision confirmations. *)
type inventory = private
  { checks : Masc.Published_artifact_check.t list
  ; diagnostics : (string * string) list
  ; received_at : float }
(** Why a confirmation inventory read has no answer: its own failure, or the
    caller's kept-back notice for a read the workspace guard did not send. *)
type read_failure = Read_failed of string | Read_kept_back of string
type status =
  | Known of Masc.Published_artifact_check.t option
  | Unknown of string
  | Kept_back of string
      (** The inventory read was not sent; carries its kept-back notice. *)

val of_json : received_at:float -> Yojson.Safe.t -> (inventory, string) result
(** Strict record decoding and unique artifact/revision targets. The caller
    supplies its actual response-observation time, never a human check time. *)
val resolve : (unit, inventory, read_failure) Masc_tui_fetched.source ->
  Masc_tui_resource_catalog.report -> status
(** Only a settled, complete successful inventory establishes absence. Pending,
    failed, partial or digest-mismatched evidence remains unknown. *)
val unchecked_on_day : reports_complete:bool ->
  day:Masc_tui_resource_catalog.day ->
  entries:Masc_tui_resource_catalog.t list ->
  (unit, inventory, read_failure) Masc_tui_fetched.source -> int option
(** [None] when either inventory cannot establish the complete count. *)
val next_unchecked : reports_complete:bool ->
  entries:Masc_tui_resource_catalog.t list -> cursor:int ->
  (unit, inventory, read_failure) Masc_tui_fetched.source -> (int option, string) result
(** Find the next unchecked published revision after [cursor], wrapping in the
    supplied list's order. MCP entries are skipped. [Ok None] means a complete,
    settled inventory establishes that no listed report is unchecked. Unknown,
    partial or mismatched evidence is an error, including for an empty list. *)
val label : status -> string
val description : status -> string
