(** The editable chat draft. Cursor positions are UTF-8 byte offsets; every
    mutation keeps the cursor at a grapheme boundary. Restored drafts start at
    their end, while typed and pasted text is inserted at the current cursor.
    Each immutable text retains its own lazy boundary index. End insertion
    needs no boundary search; safe whole-grapheme tail deletion reuses the
    index prefix. Other edits resegment the complete replacement. *)
type t

type revision
(** Opaque draft-edit identity, also unique to its input object. *)
val revision : t -> revision
val has_revision : t -> revision -> bool
val invalidate_revision : t -> unit
(** A draft owner calls this when attachments/references change without text.
    Content mutators already invalidate the same revision; cursor moves do not. *)

val create : unit -> t
val contents : t -> string
val length : t -> int
val cursor : t -> int
val before_cursor : t -> string
val clear : t -> unit
val insert : t -> string -> unit

type owner
type owned_view
type snapshot
type source_range = { offset : int; length : int }

val snapshot : t -> snapshot
val snapshot_text : snapshot -> string
val snapshot_owned_view : snapshot -> owner -> owned_view option
(** Immutable text and span ownership captured together, including across
    explicit draft saves. [None] means this snapshot does not own the handle.
    A retired owner never occurs in a later snapshot. *)

val insert_owned : t -> string -> owner
(** Insert one owned span at the cursor, retiring any previous owner. Edits before/after it move or
    preserve its extent; an edit inside it, overlapping deletion, or [clear]
    retires it. Typing equal bytes later never revives the owner. *)

val owned_is_current : t -> owned_view -> bool
(** The captured input revision still owns this view. Projection preserves the
    original revision so preparation can refuse stale projected messages. *)

val project_owned : owned_view -> source_range list -> owned_view option
(** Project ordered disjoint source ranges, retaining ownership only when the
    whole owned span occurs in one range. [None] also refuses invalid ranges. *)

val replace_owned : owned_view -> replacement:string -> string
(** Replace the captured owned extent. Equal text elsewhere is ordinary text. *)

val insert_char : t -> char -> unit
val append : t -> string -> unit
(** Add text at the end of the whole draft and leave the cursor there.
    Voice transcripts keep this append contract even after cursor movement. *)
val append_separated : t -> separator:string -> string -> unit
(** Append [separator] when the draft is nonempty, then append the text, as
    one edit. An empty text still receives the separator for a nonempty draft. *)
val move_left : t -> unit
val move_right : t -> unit
val backspace : t -> unit
val delete_word : t -> unit
val can_leave_left : t -> bool
(** Only an empty draft at its start can hand Left to the Keeper navigator. *)
