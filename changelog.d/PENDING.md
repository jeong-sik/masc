### Internal

- `scripts/tinker/librarian/synth_generate.py` refuses a facts answer whose
  items are not one text claim per slot and asks again. It no longer matches
  the claims it could read to the slots by position, where an item left out
  or not text put every later claim on the slot before its own. A claim is
  text when something is left after OCaml's `String.trim`, the librarian's
  own test for a memory claim. `summary.json` counts the refused facts
  answers and the facts left out, by reason (#51430, #PENDING).
