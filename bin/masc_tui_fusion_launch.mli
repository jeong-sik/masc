(** The launch form on the Fusion surface: the operator names a Keeper, a
    preset, a topology and a prompt, and the TUI posts them to
    [POST /api/v1/keepers/<keeper>/fusion].

    Pure, in the way [Masc_tui_lane_addons] keeps its action form pure: the
    schema form does the editing, this module decides what the form offers,
    what a submitted value means, and what the overlay says. The screen and
    the network are the caller's. *)

(** One launch, as the form submitted it. [topology] is the closed sum the
    server dispatches on; the wire spelling is [Fusion_types]'s. *)
type request =
  { keeper : string
  ; preset : string
  ; topology : Fusion_types.fusion_topology
  ; prompt : string
  ; web_tools : bool
  }

type t

(** What one key did to the form. [Editing] is also where an input the
    schema refused lands: the form stays open with the refusal on its own
    line. [Submitted] carries the form as it waits for the answer. *)
type event =
  | Editing of t
  | Submitted of t * request
  | Closed

val open_form :
  keepers:string list ->
  keeper:string option ->
  options:Masc.Tui_decode.fusion_launch_options ->
  (t, string) result
(** [keepers] are the roster's names and [keeper] the one to start on, taken
    when it is in the roster and otherwise the first. The preset starts on
    the configured default when that is one of the presets, otherwise on the
    first. Refuses, in words the surface shows, when Fusion is disabled, no
    preset is configured, or no Keeper can own the run. *)

val edit : key:string -> t -> event
(** Every key the overlay receives. While a submit waits for its answer the
    form takes no key, so a second Enter cannot start a second run. *)

val paste : text:string -> t -> t
(** Pasted text goes into the field under the cursor, newlines kept: a prompt
    is the one field on this surface that holds many lines. *)

val refused : detail:string -> t -> t
(** The server declined the submitted launch. The form returns to editing
    with the server's sentence on its refusal line, the values intact. *)

val submitting : t -> bool

val request_body : request -> Yojson.Safe.t
(** The launch endpoint's body: [prompt], [preset], [topology] and
    [web_tools], nothing the endpoint does not read. *)

val lines : t -> string list
(** The overlay's text, top to bottom: the refusal line when there is one,
    the waiting line while a submit is out, then the schema form. *)

val hints : string
(** The overlay's footer: the schema form's own keys, the array-item key left
    out because no field here is an array. *)
