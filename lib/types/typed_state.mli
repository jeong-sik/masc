(** Typed_state — Phantom type + GADT PoC for compile-time state safety.

    Demonstrates three patterns:
    1. Phantom-typed task status (active vs terminal)
    2. GADT action state (preview vs confirmed)
    3. Rich validation errors with field path + context

    Wire compatibility: to_wire/of_wire preserve existing JSON format.

    @since PoC-3 (#3526) *)

(** {1 Phantom-typed task status} *)

(** Phantom types for phase classification. *)
type active
type terminal

(** A task status tagged with its phase at the type level.
    [active task_status_t] can transition; [terminal task_status_t] cannot. *)
type _ task_status_t

(** {2 Construction (phase-safe)} *)

val todo : unit -> active task_status_t
val claim : active task_status_t -> agent:string -> active task_status_t
val start : active task_status_t -> active task_status_t
val complete : active task_status_t -> notes:string option -> terminal task_status_t
val cancel : active task_status_t -> by:string -> reason:string option -> terminal task_status_t

(** {2 Wire conversion} *)

(** Erase phase information for serialization. *)
val to_wire : _ task_status_t -> Types_core.task_status

(** Existential wrapper for deserialized task status. *)
type any_task_status =
  | Active of active task_status_t
  | Terminal of terminal task_status_t

(** Parse wire format into phase-tagged status. *)
val of_wire : Types_core.task_status -> any_task_status

(** {2 Introspection} *)

val status_name : _ task_status_t -> string
val is_terminal : any_task_status -> bool

(** {1 GADT action state} *)

(** Phantom types for action lifecycle. *)
type preview
type confirmed

(** GADT encoding preview/confirmed distinction. *)
type _ action_state =
  | Preview : {
      action_type: string;
      target_type: string;
      target_id: string;
      payload: Yojson.Safe.t;
    } -> preview action_state
  | Confirmed : {
      token: string;
      action_type: string;
      target_type: string;
      target_id: string;
      payload: Yojson.Safe.t;
    } -> confirmed action_state

(** Create a preview action. *)
val make_preview :
  action_type:string ->
  target_type:string ->
  target_id:string ->
  payload:Yojson.Safe.t ->
  preview action_state

(** Confirm a preview action with a token. Only preview -> confirmed. *)
val confirm : preview action_state -> token:string -> confirmed action_state

(** Extract action type from either phase. *)
val action_type_of : _ action_state -> string

(** Extract confirmation token (only available on confirmed actions). *)
val token_of : confirmed action_state -> string

(** {1 Rich validation errors} *)

type validation_error = {
  field_path: string list;
  expected: string;
  actual: string;
  protocol_version: string option;
  hint: string option;
}

val validation_error_to_json : validation_error -> Yojson.Safe.t
val validation_error_to_string : validation_error -> string

(** Convenience constructors. *)
val field_error :
  path:string list ->
  expected:string ->
  actual:string ->
  ?protocol_version:string ->
  ?hint:string ->
  unit ->
  validation_error
