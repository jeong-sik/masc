(** ExtrOcamlBasic maps bool, list, option, prod and unit to OCaml's own
    types with the same constructors, so driver.ml can pass String.equal and
    OCaml lists straight to the checker. N stays the extracted binary type. *)
From Coq Require Import ExtrOcamlBasic.
From WkblLaws Require Import Laws.
Extraction Language OCaml.
Extraction "laws.ml" check.
