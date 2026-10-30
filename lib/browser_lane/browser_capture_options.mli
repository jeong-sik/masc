(** Native Ego PNG options. Output paths belong to the host's image broker.
    Omitted fields remain omitted; clipping and full-page captures never
    establish a viewport coordinate frame for later pointer input. *)
type scale = Css
type clip = { x : float; y : float; width : float; height : float; scale : float option }
type t = { full_page : bool option; clip : clip option; scale : scale option; raw : bool option }

val of_json : Yojson.Safe.t -> (t, string) result
(** Accept fullPage, clip, scale="css" and raw exactly as the installed SDK.
    Clip coordinates are finite; width, height and optional clip scale are
    positive. Host paths, unknown/duplicate fields and null are rejected. *)
val of_optional_json : Yojson.Safe.t option -> (t option, string) result
(** None means the ordinary viewport PNG contract. Some {} explicitly selects
    native capture, with SDK defaults and a separate non-pointer image scope. *)
val to_json : t -> Yojson.Safe.t
