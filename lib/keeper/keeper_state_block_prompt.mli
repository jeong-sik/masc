(** Canonical keeper [STATE] block prompt text. *)

val template_text : string
(** Canonical [STATE] block schema shown to keepers. *)

val instruction_text : string
(** Scoped instruction that embeds the canonical [STATE] block schema. *)

val field_summary : string
(** Short field-name summary for recovery/error text. *)
