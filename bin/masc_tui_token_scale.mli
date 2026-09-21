(** How a byte figure is read in tokens, and where the ratio came from.

    The window a request has to fit is sized in tokens and the provider
    counts tokens; masc measures bytes before dispatch. Every size the TUI
    shows for context is therefore an estimated token figure whose basis is
    one of these, named in prose beside the figures. *)

(** Why a record's own body and count could not give a ratio. *)
type own_ratio_refusal =
  | No_body  (** No serialized body passed through masc for this record. *)
  | No_count  (** A body, but the provider reported no input count. *)
  | Turn_total_count
      (** Sum over a client turn's requests, not one request. *)
  | Cumulative_count
      (** The count covers the whole conversation, not this request. *)
  | Unknown_scope  (** The provider did not say what the count covers. *)

type basis =
  | This_turn of { wire_bytes : int; tokens : int }
      (** This record's own serialized body over its per-request count. *)
  | Keeper_page of { samples : int; own : own_ratio_refusal }
      (** Median over the rows on this page that carried both; [own] says
          why this record could not. *)
  | Fleet_measured of { own : own_ratio_refusal option }
      (** {!fleet_bytes_per_token}; nothing on the page carried both.
          [None] when there was no record to read from at all. *)

type t =
  { tokens_per_byte : float
  ; basis : basis
  }

(** Median request_body_bytes / input_tokens over the fleet's per-request
    turn records of 2026-09-13..15 (n = 2,004). *)
val fleet_bytes_per_token : float

(** The scale a screen with no turn record reads at. *)
val fleet : t

(** This record's own ratio, else the page median, else the fleet figure.
    A conversation-cumulative or unknown-scope count never divides. *)
val of_turn : rows:Turn_record.t list -> Turn_record.t -> t

val estimate : t -> int -> int

(** ["≈"] followed by {!Masc_tui_context_inspector.format_tokens} of the
    estimate. *)
val format_estimate : t -> int -> string

(** One sentence naming the basis, why this record could not supply it,
    and calling the figures estimates. *)
val note : t -> string
