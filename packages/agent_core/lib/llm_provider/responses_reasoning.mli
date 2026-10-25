(** One Responses reasoning output item's canonical carrier.
    Prefer nonblank encrypted content, then full [content/reasoning_text] in
    wire order, then the existing summary carrier. Full reasoning and its
    condensation are alternatives, not concatenated copies. Unknown content
    part types are extensions; malformed recognized reasoning text fails. *)
type t =
  | Absent
  | Plaintext of string
  | Opaque of Yojson.Safe.t

val decode : Yojson.Safe.t -> (t, string) result
