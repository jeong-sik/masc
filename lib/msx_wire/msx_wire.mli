(** The body of a refused MSX write on the HTTP surface: the one codec the
    server routes encode with and the terminal decodes with, so the two cannot
    drift into different field sets. The library has no dependencies on either
    side. *)

(** Why a write was refused or could not be confirmed. The HTTP status says
    which class of answer this is; the code says which one, and a client
    branches on the code, never on the message. *)
type code =
  | Activity_disabled  (** machines.msx is off; nothing was started *)
  | Activity_unobserved  (** the activity setting is not available; nothing was started *)
  | Workspace_precondition_failed
      (** the request named another workspace than the server's; nothing was applied *)
  | Worker_unavailable
      (** no attached worker took the call; nothing was dispatched, so retrying is safe *)
  | Outcome_unknown
      (** the call was dispatched and its result was lost; the effect may have happened *)

val all_of_code : code list
val code_to_wire : code -> string
val code_of_wire : string -> code option

type refusal = { code : code option; message : string option }

val encode : ?code:code -> string -> Yojson.Safe.t
(** [{"code": code, "ok": false, "message": message}], without [code] when none
    is given. *)

val decode : Yojson.Safe.t -> (refusal, string) result
(** Reads an object with [ok=false]. Fields other than [ok], [code] and
    [message] are ignored; a repeated field, a [code] this type does not name,
    or a [code] or [message] that is not a string is an [Error], never a
    default. *)

(** {1 Tick request}

    The body of [POST /api/v1/msx/tick] and the arguments of
    [masc_msx_step] with [include_frame]: the route and the worker read the
    same fields with this one decoder. Bounding [frames] is each caller's
    own decision, since the route clamps what the terminal sends and the
    worker refuses a count the lane rejects. *)

type pixel_reference = { revision : string; width : int; height : int }
(** Pixels the client already holds: their SHA-256 and dimensions. *)

type pixel_response =
  | Full_frame  (** every tick carries the whole picture *)
  | Retained_pixels of pixel_reference option
      (** send the picture only when it differs from the one named, if any *)

type tick = { frames : int option; pixel_response : pixel_response }

val decode_tick : Yojson.Safe.t -> (tick, string) result
(** An object with only [frames] (an integer), [pixel_response] (["retained"])
    and [known_pixels]. [known_pixels] requires [pixel_response]. A repeated or
    unknown field, or a field of the wrong type, is an [Error] naming it. *)
