(* [Unix.file_descr] is an int on every platform this builds for, which is the
   representation the stubs read with [Int_val]; declaring the externals over
   the abstract type keeps the conversion in C instead of an [Obj.magic]
   here. The key crosses as its constant-constructor representation, so the
   stub's switch follows the order of [reclaimed_key]. *)
type reclaimed_key =
  | Literal_next
  | Discard_output
  | Delayed_suspend

external key_char : Unix.file_descr -> reclaimed_key -> int = "masc_tui_termios_key_char"

external set_key_char : Unix.file_descr -> reclaimed_key -> int -> bool
  = "masc_tui_termios_set_key_char"

external disable_key : Unix.file_descr -> reclaimed_key -> bool
  = "masc_tui_termios_disable_key"

type 'a per_key = {
  literal_next : 'a;
  discard_output : 'a;
  delayed_suspend : 'a;
}

(* The one place that walks the keys. A key is a constructor, a field, a line
   here and a line in [restore]; once the field exists, this record literal
   and [restore]'s pattern do not compile without their lines. *)
let per_key f =
  { literal_next = f Literal_next
  ; discard_output = f Discard_output
  ; delayed_suspend = f Delayed_suspend
  }

let restore_one fd key char =
  (* [-1]: the key did not exist or the descriptor was not a terminal when
     the snapshot was taken, so there is nothing to give back. *)
  if char >= 0 then ignore (set_key_char fd key char : bool)

type snapshot = int per_key

let snapshot fd = per_key (key_char fd)

let reclaim fd = ignore (per_key (fun key -> disable_key fd key) : bool per_key)

let restore fd (snapshot : snapshot) =
  let { literal_next; discard_output; delayed_suspend } = snapshot in
  restore_one fd Literal_next literal_next;
  restore_one fd Discard_output discard_output;
  restore_one fd Delayed_suspend delayed_suspend
