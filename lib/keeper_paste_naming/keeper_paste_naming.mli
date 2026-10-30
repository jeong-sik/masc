(** Single source of truth for the spilled-paste file name.

    The TUI spill writer ([bin/masc_tui_paste_spill.ml]) constructs names
    through {!file_name}; the turn-setup delivery
    ([Keeper_paste_delivery]) recognises them through {!parse}. Both sides
    of the bin/lib boundary read this one module, so a naming change moves
    writer and matcher together — a drift between two local spellings would
    otherwise strand staged pastes silently (delivery would no-op on files
    it no longer recognises).

    Shape: [pasted-<now_iso>-<nonce>.txt]. *)

type parsed =
  { now_iso : string
  ; nonce : string
  }

val file_name : now_iso:string -> nonce:string -> string

val parse : string -> parsed option
(** Sound partial parser: only the exact {!file_name} shape decodes.
    [nonce] is the segment after the last dash, so dashes inside [now_iso]
    stay part of it. *)

val is_paste_file : string -> bool
(** [true] exactly when {!parse} accepts the name. *)
