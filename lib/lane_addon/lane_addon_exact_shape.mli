(** Consumer-schema guard for Exact Output, including JsonMode slots where
    providers only guarantee syntactic JSON. *)
type issue = Missing_required_key of string | Incompatible_required_shape of string
val issue : at:string -> Yojson.Safe.t -> Yojson.Safe.t -> issue option
(** Check visited object required keys, additionalProperties=false, array
    bounds and item schemas, scalar enum/const/length/numeric bounds, primitive
    types and anyOf alternatives. *)
val to_string : issue -> string
