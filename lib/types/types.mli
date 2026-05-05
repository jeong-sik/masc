(** Backward-compatible [Types] facade.

    This module intentionally mirrors {!Masc_domain}; it exists for legacy
    callers that still import [Types] while the domain surface lives in the
    explicit {!Masc_domain} facade. *)

include module type of struct
  include Masc_domain
end
