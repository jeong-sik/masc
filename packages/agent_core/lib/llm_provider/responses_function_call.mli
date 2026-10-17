(** Shared strict decoder for a supported Responses [function_call] item.
    Stream grouping never grants executable tool admission. *)
type t =
  { call_id : string
  ; name : string
  ; input : Yojson.Safe.t
  ; arguments : string
  }

val decode : Yojson.Safe.t -> (t, string) result
