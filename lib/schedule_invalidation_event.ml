(** A write was attempted; consumers re-read their authoritative view. *)
let event_type = "schedule_store_invalidated"

let json = `Assoc [ "type", `String event_type ]
