(** Execute one retained verifier original through its host-built authority.
    Verdict extraction, commitment and Task/Goal transitions stay on the host. *)

type error =
  | Original_not_found
  | Original_corrupt of string
  | Grants_mismatch of string

val run_attempt :
  ?on_verdict:(Task.Anti_rationalization.review_result -> unit) ->
  ?on_tool_result:(input:Yojson.Safe.t -> Tool_result.result -> unit) ->
  ?sw:Eio.Switch.t option ->
  store:Verifier_review_owner.store -> verification_id:string -> attempt:int ->
  installation_id:string -> package_id:string ->
  authority:Verification_authority_tools.task_review ->
  provider_rest:(string -> Task.Anti_rationalization.provider_rest) -> unit ->
  (Task.Anti_rationalization.review_result, error) result
(** Strictly load the original for its recorded destination, then compare the
    host's opaque authority with its canonical binding and subject. Refuse a
    changed workspace, producer, full schema or submitted snapshot before
    dispatch. Execute the stored prompt and images; callers supply neither
    another question nor a lookup dispatch closure. The structured output
    contract must still match the review protocol. *)
