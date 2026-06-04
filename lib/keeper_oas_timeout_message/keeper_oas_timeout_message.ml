(** Shared structural OAS timeout message predicates.

    Keep this module dependency-light: it is used from low-level turn-driver
    helpers where depending on [Keeper_error_classify] would introduce a
    module cycle back through [Keeper_turn_driver]. *)

let is_structural message =
  String_util.contains_substring_ci message "(budget="
  || String_util.contains_substring_ci
       message
       "turn wall-clock budget exhausted"
;;
