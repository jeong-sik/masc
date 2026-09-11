(** Exact gemini/antigravity item in an explicitly named keychain; never searches
    the default account or displays authentication UI. *)
type observation = Found of string | Missing | Unsupported | Unavailable
val read : path:string -> observation
(** Only callers owning the named private destination may clear its item. *)
val clear : path:string -> (unit, unit) result
