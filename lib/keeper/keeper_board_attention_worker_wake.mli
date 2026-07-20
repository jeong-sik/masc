(** Process-local wake hints for durable per-Keeper Board-attention workers.

    Hints may coalesce because the candidate and partition ledgers are the work
    authority. Registration is keyed by canonical BasePath plus Keeper name so
    multiple workspaces cannot signal one another. *)

type registration

type wake_result =
  | Signaled
  | Coalesced
  | Not_registered

type await_result =
  | Wake
  | Registration_closed

val register :
  sw:Eio.Switch.t ->
  base_path:string ->
  keeper_name:string ->
  (registration, string) result
(** Register one worker for the exact workspace/Keeper identity. Duplicate
    live registration is rejected. Switch release closes and unregisters the
    exact registration. *)

val request :
  base_path:string -> keeper_name:string -> (wake_result, string) result
(** Non-blockingly publish one coalescing hint. [Not_registered] is successful
    durable deferral: startup drain remains responsible for already-persisted
    work. *)

val await : registration -> await_result
(** Cancellably consume one hint or observe registration closure. *)
