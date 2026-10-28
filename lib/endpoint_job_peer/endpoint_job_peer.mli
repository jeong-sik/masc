(** Connection-time kernel credentials for the endpoint's local control socket.
    This authenticates an OS account in the controller's user namespace, not a
    Keeper name, request body, live process, execution result or sandbox domain.
    Socket permissions, immutable service policy and request owner/route binding
    are separate obligations. Accounts sharing a UID share this authority. *)
type t
type identity = private { uid : int; gid : int; process_id : int }
type error =
  | Unsupported
  | Invalid_uid
  | Unsupported_transport
  | Not_connected
  | Closed
  | Uid_mismatch
  | Identity_changed
  | Syscall_failed of Unix.error
val error_to_string : error -> string
val supported : bool
val authenticate : allowed_uid:int -> _ Eio.Resource.t -> (t,error) result
(** Accept only a connected Unix stream socket whose actual SO_PEERCRED UID
    matches configured policy. No caller-supplied identity is accepted. Other
    transports/platforms never fall back to a claimed UID or process ID. The
    Eio descriptor wrapper is borrowed while reading kernel credentials, so a
    closed descriptor cannot be reused as another connection. This performs
    no socket reads/writes, process action, launch or registry mutation. *)
val identity : t -> identity
(** Diagnostic credentials captured at connect/listen/socketpair time. The PID
    is not a current process handle and must never authorize a signal. *)
val revalidate : allowed_uid:int -> t -> (unit,error) result
(** Recheck the same guarded descriptor and configured account before accepting
    a new control. A closed local wrapper or changed identity is rejected.
    Peer EOF/exit does not revoke an already accepted original job: the server
    stops reading requests on EOF, while accepted jobs retain their own Switch.
    No liveness, per-Keeper isolation or authority for another service is inferred. *)
