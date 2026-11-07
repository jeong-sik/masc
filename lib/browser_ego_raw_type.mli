(** Shared native raw keyboard producer and private capture decoder. Neither
    tool arguments nor application evaluation results construct this context. *)
type context
val prepare : command_id:string -> generation:string ->
  source:Browser_ego_native_window.page -> indices:int list -> (context, string) result
(** Invocation-owned names/nonces; command/generation come from actual Pending. *)

val source : context -> Browser_ego_native_window.page
val arguments : context -> Yojson.Safe.t
(** Internal arguments injected after public strict decoding. *)

val script : string
(** Fixed [nativeTypeWindow(task, page, binding, index, text, options,
    sourceIdentity, currentIdentity, guard)] procedure. Both public routes use
    this code. [guard] is fixed Host code, never a caller-supplied function.
    The result keeps its private [capture] separate from any native error.
    It drains the Page's events with [mascPageEvents], so its step includes
    [Browser_ego_page_events.script] too. *)

val expected : context -> index:int -> current:Browser_ego_native_window.page ->
  (Browser_ego_native_window.expected, string) result
type cleanup = Not_attempted | Returned | Unconfirmed
type failure
type outcome = private
  | Not_entered of failure
  | Entered_unconfirmed of failure
  | Completed of { expected:Browser_ego_native_window.expected;
      completion:Browser_ego_native_window.completion; cleanup:cleanup }
(** [Not_entered] concerns only this raw step. A workflow still judges every
    earlier entered holding step; only whole-command No_hold may restore prior
    readiness. It is not authority to roll back the whole workflow. *)

val decode : context -> index:int -> current:Browser_ego_native_window.page ->
  Yojson.Safe.t -> (outcome, string) result
(** Independently classify genuine private captures. Invalid cleanup alone
    becomes Unconfirmed cleanup while a separately valid completion survives.
    Missing/ambiguous overall progress remains a caller-level unknown. *)

val public_failure : failure -> Yojson.Safe.t
(** Closed reason/phase, never raw response/event data or native error prose. *)

val failure_reason : failure -> Browser_ego_native_window.unconfirmed
(** Typed reason for the existing release judge; no private capture is exposed. *)
