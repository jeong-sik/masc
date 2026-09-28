type client = Codex | Claude | Antigravity | Muse
type provider = { id : string; label : string; client : client }
type model = { id : string; label : string; context : int option; tools : bool option }
type phase = Loading | Providers | Logging | Models | Capacity of model | Saving | Finished | Failed
type t = {
  requested : string; mutable generation : int; mutable phase : phase; mutable providers : provider list;
  mutable provider : provider option; mutable models : model list; mutable cursor : int;
  mutable account_ref : string option; mutable login_id : string option;
  mutable revision : string; mutable existing : string list; mutable draft : string;
  mutable output : string; mutable notice : string; mutable input_pending : bool;
  mutable cancel_stream : (unit -> unit) option;
}
type authentication = Authenticated | Login_completed | Credential_captured
type event = Started of string * string option | Output of string | Input_ready
  | Complete of string * authentication | Login_failed of string * string option | Login_error
type action = Inventory | Refresh_saved | Start of bool | Input of Yojson.Safe.t | Cancel
  | Recover | Discover | Prepare of model | Save of model * int option | Close | Nothing
val create : string -> t
val begin_attempt : t -> provider -> existing:bool -> string option
(** Capture the requested account, clear the previous live session identity and
    reset login input state before the next process is launched. *)
val key : t -> string -> action
val paste : t -> string -> unit
val inventory : t -> Yojson.Safe.t -> (unit, string) result
val models : t -> Yojson.Safe.t -> (unit, string) result
val prepared : t -> model -> Yojson.Safe.t -> (unit, string) result
val receipt : t -> Yojson.Safe.t -> (bool, string) result
val event : generation:int -> t -> event -> action
val source : t -> Yojson.Safe.t
val save_body : t -> model -> int option -> Yojson.Safe.t
val lines : t -> string list
val visible_lines : height:int -> t -> string list
val hints : t -> string
val decoder : integration_id:string -> (event -> unit) -> (string -> unit) * (unit -> bool)
