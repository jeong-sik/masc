(** Durable delivery of committed Goal effects. The Goal store owns each
    notification until its exact workspace row and every snapshotted recipient
    transcript are committed. No evaluator, queue admission or Keeper wake runs. *)
type backend = {
  snapshot : config:Workspace_utils.config -> (string list, string) result;
  project : config:Workspace_utils.config ->
    delivery:Workspace_broadcast.broadcast_delivery -> recipient:string -> (unit, string) result;
}
val register_backend : backend -> unit
val flush : Workspace_utils.config -> (unit, string) result
(** Drain audit and notifications, regardless of current Goal phase/existence.
    An error is retained and reported while unrelated recipients and notices
    continue. Call outside any Goal transaction. Recipient I/O runs outside the
    Goal lock; a separate process/fiber lock serializes delivery and retries. *)
module For_testing : sig
  val replace_backend : backend option -> backend option
end
