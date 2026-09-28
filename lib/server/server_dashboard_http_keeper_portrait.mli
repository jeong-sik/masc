(** [GET /api/v1/keepers/:name/portrait.png?size=N]: a Keeper's candle-imp
    portrait (lib/keeper_portrait) as a PNG with straight alpha.

    Public read, like the Keeper's other plain reads: a browser [<img>] sends
    no bearer token. The picture is a pure function of the name, but the
    route answers 404 for a name that is not a Keeper of this workspace, so
    the URL does not draw portraits for anything a caller types.

    The response carries a strong entity tag over the PNG bytes and
    [Cache-Control: no-cache]: a browser keeps the image and asks again, and
    the server answers [304 Not Modified] while the bytes are the same. The
    tag follows the bytes rather than a version number, so a change to the
    drawing cannot be served under an old tag. *)

val route : string -> string option
(** The Keeper name when the path is exactly
    [/api/v1/keepers/<name>/portrait.png]. *)

val default_size : int
(** Edge length in pixels when the request has no [size]. *)

type answer =
  | Invalid_name  (** Not a well-formed Keeper name: 400. *)
  | Invalid_size of string
      (** [size] is not a whole number of pixels in the renderer's range: 400.
          Out-of-range sizes are refused, not clamped. *)
  | Unknown_keeper  (** No Keeper by that name here: 404. *)
  | Lookup_failed of string  (** The Keeper store could not be read: 503. *)
  | Encode_failed of string  (** The PNG encoder refused the image: 500. *)
  | Png of string  (** The PNG file's bytes: 200 (or 304 on a matching tag). *)

val answer :
  name:string ->
  size:string option ->
  keeper_present:(unit -> (bool, string) result) ->
  answer
(** Decides the response. Checks run in this order: name syntax, size,
    Keeper presence, drawing. [keeper_present] is the only effect and runs
    only for a well-formed request. *)

val handle_get :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Serves {!answer} for the Keeper named by {!route}. Drawing and encoding
    run on the shared CPU pool. *)
