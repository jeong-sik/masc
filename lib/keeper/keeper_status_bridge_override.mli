(** Default vs live override-field detail builder + typed matchers
    for keeper status surfaces. *)

type override_field_detail =
  { field : string
  ; default_value : Yojson.Safe.t
  ; live_value : Yojson.Safe.t
  }

val override_field
  : string
  -> default_value:Yojson.Safe.t
  -> live_value:Yojson.Safe.t
  -> override_field_detail

val maybe_string_override
  : string
  -> ?normalize:(string -> string)
  -> string option
  -> string
  -> override_field_detail list
  -> override_field_detail list

val maybe_bool_override
  : string
  -> bool option
  -> bool
  -> override_field_detail list
  -> override_field_detail list

val maybe_string_list_override
  : string
  -> string list option
  -> string list
  -> override_field_detail list
  -> override_field_detail list

val nonempty_string_list_override
  : string
  -> string list
  -> string list
  -> override_field_detail list
  -> override_field_detail list

val maybe_string_option_override
  : string
  -> string option
  -> string option
  -> override_field_detail list
  -> override_field_detail list
