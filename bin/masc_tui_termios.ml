(* [Unix.file_descr] is an int on every platform this builds for, which is the
   representation the stubs read with [Int_val]; declaring the externals over
   the abstract type keeps the conversion in C instead of an [Obj.magic]
   here. *)
type reclaimed_key =
  | Literal_next
  | Discard_output
  | Delayed_suspend
  | Quit

(* Each key's c_cc slot on this platform, or [-1] where its tty has no such
   key. [slot] picks the stub by name, so no C code reads the order of
   [reclaimed_key]: a new key is a stub of its own and a match line this file
   does not compile without. *)
external literal_next_slot : unit -> int = "masc_tui_termios_literal_next_slot"
external discard_output_slot : unit -> int = "masc_tui_termios_discard_output_slot"
external delayed_suspend_slot : unit -> int = "masc_tui_termios_delayed_suspend_slot"
external quit_slot : unit -> int = "masc_tui_termios_quit_slot"

let slot = function
  | Literal_next -> literal_next_slot ()
  | Discard_output -> discard_output_slot ()
  | Delayed_suspend -> delayed_suspend_slot ()
  | Quit -> quit_slot ()

external slot_char : Unix.file_descr -> int -> int = "masc_tui_termios_slot_char"

external set_slot_char : Unix.file_descr -> int -> int -> bool
  = "masc_tui_termios_set_slot_char"

external disable_slot : Unix.file_descr -> int -> bool
  = "masc_tui_termios_disable_slot"

let key_char fd key = slot_char fd (slot key)
let set_key_char fd key char = set_slot_char fd (slot key) char
let disable_key fd key = disable_slot fd (slot key)

type 'a per_key = {
  literal_next : 'a;
  discard_output : 'a;
  delayed_suspend : 'a;
  quit : 'a;
}

(* The one place that walks the keys. A key is a constructor, a field, a line
   here and a line in [restore]; once the field exists, this record literal
   and [restore]'s pattern do not compile without their lines. *)
let per_key f =
  { literal_next = f Literal_next
  ; discard_output = f Discard_output
  ; delayed_suspend = f Delayed_suspend
  ; quit = f Quit
  }

let restore_one fd key char =
  (* [-1]: the key did not exist or the descriptor was not a terminal when
     the snapshot was taken, so there is nothing to give back. *)
  (* A refusal is a terminal already gone, which cannot take the character. *)
  (* See [restore] in masc_tui_termios.mli. *)
  if char >= 0 then ignore (set_key_char fd key char : bool)

type snapshot = int per_key

let snapshot fd = per_key (key_char fd)

(* false is a key this platform lacks or a hangup; the session goes on either way. *)
(* See [disable_key] in masc_tui_termios.mli. *)
let reclaim fd = ignore (per_key (fun key -> disable_key fd key) : bool per_key)

let restore fd (snapshot : snapshot) =
  let { literal_next; discard_output; delayed_suspend; quit } = snapshot in
  restore_one fd Literal_next literal_next;
  restore_one fd Discard_output discard_output;
  restore_one fd Delayed_suspend delayed_suspend;
  restore_one fd Quit quit
