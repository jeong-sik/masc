(** Environment projection for official subscription CLIs.

    Metered API credentials are removed so a configured subscription runtime
    cannot silently fall back to pay-per-token API authentication. *)

val environment : unit -> string array
val is_metered_api_credential : string -> bool
