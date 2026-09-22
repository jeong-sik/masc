(** Keeper instruction comparison used by runtime reconciliation.

    The whole text is compared, so an edit anywhere in a Keeper's
    instructions reads as drift. Trimming is the only normalization: the TOML
    and the persisted meta may differ in surrounding whitespace, and that
    difference is not an edit. *)

let normalized value = String.trim value
let text_equal left right = String.equal (normalized left) (normalized right)
