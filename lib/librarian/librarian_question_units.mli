(** The units one question carries, read from a commit log's tail at a
    width (RFC librarian-call-only-proposes §7.1 step 3, §7.6). An ask reads
    them to make its question. An operator's [Skip_item] reads the head item
    alone the same way, so it passes what that question would carry (§12.4).

    It reads the turn log and the unit content, and nothing else. *)

(** The units read, split at the first that holds items: the head (§7.6). *)
type range =
  { before : Librarian_unread.span list (** Units with no items, before the head. *)
  ; head : Librarian_unread.span
  ; after : Librarian_unread.span list
  }

type units_error =
  | No_head of Librarian_unread.stop
  (** No unit before where reading stopped holds an item. *)
  | Turn_log_fault of Librarian_unit.input_fault
  | Turn_log_unread of { detail : string }
  (** The turn log could not be read, or it changed while it was read. *)

(** The units from [tail], when one holds an item. A width of units stops
    after that many units with items, and a width of items after the first.
    Reading that stopped at a line it cannot pass gives the units before
    that line. *)
val units
  :  turns_path:string
  -> width:Librarian_width.width
  -> Librarian_log.line
  -> (range, units_error) result

(** What one question is made of. *)
type contents =
  { units : Librarian_read_unit.t list
  ; reach : Librarian_read_result.reach
  ; trace : string (** The last unit's trace. *)
  ; offered : Librarian_width.offered
  }

type contents_error =
  | Content_unreadable of { span : Librarian_unread.span }
  (** A bundle the unit [span] names is there and does not read now. *)
  | Content_unread of { detail : string }
  (** A byte file or the external store could not be read, or it changed
      while it was read. *)

(** Only the head is cut by a width of items. Every other unit is read to
    its end. The reach is where the last unit's read ended. *)
val contents
  :  Librarian_unit_content.stores
  -> width:Librarian_width.width
  -> range
  -> (contents, contents_error) result
