(** Shared strict decoder for a supported Responses [function_call] item.
    Stream grouping never grants executable tool admission.

    It reads the call's identity and its argument text. Whether that text is
    one JSON object is judged by whoever turns the call into content: the
    stream assembly, or the non-streamed parser. A call whose text is not an
    object is still a call the model made, so it never fails the item here. *)
type t =
  { call_id : string
  ; name : string
  ; arguments : string
  }

val decode : Yojson.Safe.t -> (t, string) result
