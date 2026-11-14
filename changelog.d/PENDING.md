### Internal

- `scripts/tinker/librarian/synth_generate.py` refuses a facts answer whose
  items are not one text claim per slot and asks again. It no longer matches
  the claims it could read to the slots by position, where an item left out
  or not text put every later claim on the slot before its own. A fact
  shorter than 0.1 of its planned length is not kept, so a claim such as
  `NaN` no longer enters a memory. `summary.json` counts the refused facts
  answers and the facts left out, by reason (#51430, #PENDING).
