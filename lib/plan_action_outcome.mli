(** Plan_action_outcome — closed sum for the [status] field emitted by
    the [masc_plan_*] / [masc_note_add] / [masc_deliver] handlers in
    {!Tool_plan}.  Replaces 6 inline [`String "initialized"]-style
    literals; adding a new handler now forces compiler-checked variant
    enumeration. *)

type t =
  | Initialized
  (** Emitted by [handle_plan_init] after a fresh planning context is
      created via {!Planning_eio.init}. *)
  | Updated
  (** Emitted by [handle_plan_update] after a successful
      {!Planning_eio.update_plan}. *)
  | Added
  (** Emitted by [handle_note_add] after a note is appended via
      {!Planning_eio.add_note}. *)
  | Delivered
  (** Emitted by [handle_deliver] after a deliverable is recorded via
      {!Planning_eio.set_deliverable}. *)
  | Set
  (** Emitted by [handle_plan_set_task] after [current_task] is
      reassigned. *)
  | Cleared
  (** Emitted by [handle_plan_clear_task] after [current_task] is
      cleared. *)

val to_label : t -> string
(** Wire-format label, byte-identical to the original inline literals. *)

val status_field : t -> string * Yojson.Safe.t
(** Pair [("status", `String (to_label outcome))] — convenience for the
    common envelope shape [`Assoc \[ status_field outcome; ...other \]]. *)
