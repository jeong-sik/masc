(** What one completed write of Keeper context to an official client put on
    the wire, measured from the bytes written: their count and SHA-256, and
    where the context-bearing values sit among them.

    Codex and Muse write compact JSON lines to stdin. Claude Code writes a
    stream-json line to stdin and a system prompt file. Antigravity writes the
    prompt itself to stdin. A receipt is built from the exact bytes a runtime
    writes and reaches its observer only after the write completed. It is
    neither the client's acceptance nor the provider's model input. *)

type slot =
  | Whole_write  (** A raw write: every byte written. *)
  | Developer_instructions  (** Codex [developerInstructions]. *)
  | Dynamic_tools  (** Codex [dynamicTools]. *)
  | Injected_item of int  (** Codex [thread/inject_items] item, by position. *)
  | Turn_text of int
      (** A [{"type":"text"}] element's text in the turn's input list, by the
          element's position; images come before the text. *)
  | Unattributed_carrier
      (** In a JSON line, every byte no selected slot covers, in order. *)

type encoding =
  | Json_line
      (** Compact JSON followed by LF. Count and hash cover the JSON, not the
          LF. A slot is a JSON value inside it, quotes and brackets included. *)
  | Raw  (** The bytes are the text itself. *)

type fragment = private
  { slot : slot
  ; offset : int option
        (** Where the slot starts in the write. [None] for
            [Unattributed_carrier], whose bytes are not contiguous. *)
  ; bytes : int
  ; sha256 : string
  }

type fragments =
  | Partitioned of fragment list
  | Serialization_mismatch
      (** The JSON did not have the layout the walk expects. The write's count
          and hash stay valid; slot attribution is unavailable. *)

type t = private
  { encoding : encoding
  ; bytes : int
  ; sha256 : string
  ; fragments : fragments
  }

(** {1 Building a receipt} *)

(** Which values of a JSON frame are slots. *)
type selection =
  | Select of slot  (** This value is the slot. *)
  | Fields of (string * selection) list
      (** An object: each named member by its selection; members not named
          are carried. *)
  | Elements of (int -> Yojson.Safe.t -> selection)
      (** A list: each element by its position and value. *)
  | Carry  (** Count this value in [Unattributed_carrier]. *)

val json_line : selection -> Yojson.Safe.t -> string -> t
(** [json_line selection json payload], where [payload] is
    [Yojson.Safe.to_string json]: the bytes written before the LF. A selected
    value must be a string, list or object. Ranges are read from [payload],
    never from a second serialization, and every key and delimiter is checked
    against it, so an unexpected layout gives [Serialization_mismatch] instead
    of claimed offsets. *)

val raw : string -> t
(** A write whose bytes are the given text: one [Whole_write] slot. *)

val turn_input : selection
(** The selection Codex, Muse and Claude Code share for a turn's input list:
    each [{"type":"text"}] element's [text] is [Turn_text] of the element's
    position. Other elements are carried. *)

(** {1 Reading a receipt} *)

val matching_fragment : t -> slot:slot -> string -> fragment option
(** The fragment at [slot] whose bytes are [text] as this write encodes it:
    the JSON string literal in a [Json_line], the text itself in a [Raw]
    write. *)

val encoded_text_sha256 : t -> string -> string
(** SHA-256 of [text] as this write would encode it in a slot. *)

val slot_fields : slot -> (string * Yojson.Safe.t) list
(** ["slot"] and ["index"] as the receipt JSON names them. *)

val to_json : t -> Yojson.Safe.t
(** Content-free: counts, digests and offsets. *)

val report : label:string -> ('a -> unit) -> 'a -> unit
(** Hand a receipt to its observer once the write completed. Operator
    interrupts and reserved exceptions propagate. Any other observer failure,
    including a deadline the observer raises itself, is logged as an
    unavailable measurement and the turn continues: the bytes are already
    outside the process. *)
