(** Immutable action feedback. Ordinary feedback retains its existing
    timestamp and identity; input rejection stays pending until it is actually
    presented with its complete text. *)
type rejection_kind = Input_rejected | Paste_rejected
type rejection
type t
type preferred = No_preferred | Csi_recovery | Rejection of rejection

(** A quit confirmation is tied to the exact ordinary notice created by the
    first gesture. Its presentation and input-drain state are immutable. *)
type quit_kind = Quit_key | Interrupt
type quit_confirmation
val arm_quit : kind:quit_kind -> ordinary:(string * float) -> quit_confirmation
val quit_kind : quit_confirmation -> quit_kind
val quit_ordinary : quit_confirmation -> string * float
val same_quit : quit_confirmation -> quit_confirmation -> bool
val quit_presented :
  quit_confirmation -> visible:quit_confirmation option -> was_visible:bool ->
  input_pending:bool -> quit_confirmation
val quit_after_drain :
  quit_confirmation -> currently_visible:quit_confirmation option ->
  input_pending:bool -> quit_confirmation
val quit_authorized :
  quit_confirmation -> kind:quit_kind -> currently_visible:quit_confirmation option ->
  ordinary_before:(string * float) option -> now:float -> window:float -> bool
(** A confirmation is authorized only after its exact notice was completely
    presented, any input already pending at presentation was drained, and the
    original ordinary notice has not been replaced or expired. Call before
    clearing the ordinary notice for the current input. *)

val empty : t
val ordinary : t -> (string * float) option
val ordinary_visible : t -> now:float -> window:float -> (string * float) option
val set_ordinary : t -> (string * float) option -> t
val csi_active : t -> bool
val start_csi : t -> t
val end_csi : t -> t
val ordinary_is_csi : t -> bool
(** CSI recovery is independent of ordinary notice replacement and remains
    active until the input reader confirms that the sequence ended. The
    original ordinary tuple keeps its physical identity. *)
val reject : t -> rejection_kind -> now:float -> window:float -> t
val rejection : t -> now:float -> window:float -> rejection option
(** Existing action feedback retains its previous priority. A pending input
    rejection stays in state until it can be offered without replacing it. *)
val preferred : t -> existing_action:bool -> now:float -> window:float -> preferred
val csi_recovery_text : string
val recovery_slot :
  t -> now:float -> window:float -> csi_fits:bool -> rejection_fits:bool -> preferred
(** Choose a separate recovery slot. An active CSI takes precedence even when
    it does not fit; an unshown rejection remains pending. *)
val rejection_text : rejection -> string
val same_rejection : rejection -> rejection -> bool
val presented : t -> rejection -> at:float -> input_pending:bool -> t
val after_drain :
  t -> at:float -> input_pending:bool -> currently_visible:rejection option -> t
(** Start the visible lifetime only if that exact notice is still on the last
    valid frame after input drains; otherwise it must be presented again. *)
val after_input :
  t -> input_seen:bool -> operator_input:bool -> currently_visible:rejection option ->
  now:float -> window:float -> t
(** Ordinary feedback is cleared by input as before. A rejection can be
    cleared by operator input only while its exact identity is still visible.
    Before expiry, a notice hidden by another surface becomes pending again. *)

val after_rejected_input :
  t -> ordinary_before:(string * float) option -> currently_visible:rejection option ->
  now:float -> window:float -> t
(** A rejected input clears the ordinary notice that preceded input handling,
    but preserves a newer notice produced during that handling. It never
    acknowledges a rejection. Ordinary tuples are compared by identity. *)
