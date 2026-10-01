(** [GET /api/v1/keepers/:name/portrait.png?size=N]: a Keeper's candle-imp
    portrait (lib/keeper_portrait) as a PNG with straight alpha.
    Optional [expected_equipment] is the existing strict equipment JSON codec.
    A malformed expectation is 400; a current equipment mismatch is 409 even
    for a held ETag. Dashboard requests always bind their observed equipment.

    A plain read of the Keeper, authorised like its other plain reads: open
    on a loopback server, a [CanReadState] token once HTTP auth is strict.
    The dashboard fetches it with its token rather than through a bare
    [<img>], which could not carry one. The picture combines the name-derived body and current equipment, but the route answers 404 for a name that is not a Keeper of this
    workspace, so the URL does not draw portraits for anything a caller
    types. HTTP/1.1 only, like the Keeper's other GET routes: the HTTP/2
    gateway serves none of them.

    The picture depends on nothing but the running binary, the name, size and equipment, so its strong entity tag is made from those inputs before anything
    is drawn: a request that already holds the tag gets [304 Not Modified]
    without a drawing. [Cache-Control: no-cache] makes the browser keep the
    file and revalidate it. A new binary gives new tags, so a change to the
    drawing is never served under an old one. Drawn images are kept in a
    small cache bounded by bytes. *)

val route : string -> string option
(** The Keeper name when the path is exactly
    [/api/v1/keepers/<name>/portrait.png]. *)

val default_size : int
(** Edge length in pixels when the request has no [size]. *)

(** What the entity tag is scoped to. *)
type build =
  | Executable of string
      (** The running executable's SHA-256: the tag is known before drawing. *)
  | Unscoped
      (** The executable could not be read: the tag is taken from the PNG
          bytes, so every request draws (or reads the cache) first. *)

val current_build : unit -> build
(** This process's {!build}, from {!Build_identity.current}, which hashes the
    executable once and keeps the digest. *)

(** PNG bytes already drawn, by name, edge length and equipment. Bounded by the total
    size of the bytes it holds; the oldest entries go first. *)
module Cache : sig
  type t

  val create : byte_budget:int -> t
  val length : t -> int
  val bytes : t -> int
  (** Total size of the PNG bytes held; never above the budget. *)
end

type answer =
  | Invalid_name  (** Not a well-formed Keeper name: 400. *)
  | Invalid_size of string
      (** [size] is not a whole number of pixels in the renderer's range: 400.
          Out-of-range sizes are refused, not clamped. *)
  | Invalid_equipment of string (** Malformed expected equipment: 400. *)
  | Equipment_changed (** Current equipment differs from the expected snapshot: 409. *)
  | Unknown_keeper  (** No Keeper by that name here: 404. *)
  | Lookup_failed of string  (** The Keeper store could not be read: 503. *)
  | Encode_failed of string  (** The PNG encoder refused the image: 500. *)
  | Not_modified of string
      (** The request already holds this tag: 304, nothing drawn. *)
  | Png of { etag : string; png : string }
      (** The PNG file's bytes under this tag: 200. *)

val answer :
  cache:Cache.t ->
  build:build ->
  name:string ->
  size:string option ->
  expected_equipment:(Keeper_portrait_look.equipment, string) result option ->
  keeper_present:(unit -> (bool, string) result) ->
  equipment:(unit -> (Keeper_portrait_look.equipment, string) result) ->
  holds_tag:(string -> bool) ->
  answer
(** [None] asks for current equipment without binding to a prior observation.
    [Some expected] requires the existing strict equipment codec's result.
    A mismatch is refused before ETag, cache or PNG publication.
    Decides the response. Checks run in this order: name syntax, size, expected equipment syntax,
    Keeper presence, current equipment, the request's tag, drawing. [keeper_present] runs only
    for a well-formed request; with an {!Executable} build, a request whose
    [holds_tag] accepts the tag is answered before any drawing or cache read. *)

val keeper_present : Workspace.config -> string -> unit -> (bool, string) result
(** Whether the Keeper's metadata file exists, from the file system alone: it
    does not read, decode, repair or rewrite the file, nor create the Keeper
    directory. [Error] only when the
    store cannot be examined (a permission error, or something other than a
    regular file where the metadata belongs). *)

val handle_get :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Serves {!answer} for the Keeper named by {!route}, with this process's
    {!current_build} and cache. Drawing and encoding run on the shared CPU
    pool. *)
