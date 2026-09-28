(** Request-owned login processes. Input stays in memory and never reaches a
    Keeper, transcript, or process log. Registry scope is workspace + actor;
    the account lock uses the resolved physical credential store. *)
type key = Enter | Up | Down | Tab | Eof
type input = Text of string | Key of key
type error = Already_running | Not_found | Not_running | Input_pending | Invalid_input
  | Cancelled | Transport_failed | Process_failed of int | Interpreter_missing
type t
val error_message : error -> string
val input_of_json : Yojson.Safe.t -> (input, error) result
val id : t -> string
val bind_account : t -> account_key:string -> (unit, error) result
(** Replace the provisional new-account lock with its prepared physical home
    before publishing its reference or starting a process. *)
val is_active : workspace:string -> actor:string -> login_id:string -> bool
val monitor : t -> env:Eio_unix.Stdenv.base -> is_closed:(unit -> bool) ->
  (unit -> 'a) -> ('a, error) result
val with_session : workspace:string -> actor:string -> account_key:string ->
  (t -> ('a, error) result) -> ('a, error) result
val submit : workspace:string -> actor:string -> login_id:string -> input -> (unit, error) result
val cancel : workspace:string -> actor:string -> login_id:string -> (unit, error) result
val python : binary:string -> string option
(** The interpreter that runs the login helper: the release's bundled
    [python/bin/python3] beside [binary] when it is executable, else the first
    executable [python3] on [PATH]. [None] when neither exists. *)

val run : t -> env:Eio_unix.Stdenv.base -> child_env:string array ->
  cwd:string -> argv:string list -> terminal:bool ->
  is_closed:(unit -> bool) -> on_ready:(unit -> unit) ->
  on_input_ready:(unit -> unit) ->
  on_output:(string -> string -> unit) -> (unit, error) result
(** No session deadline: provider expiry, explicit cancel, disconnect and server
    shutdown own termination. The helper kills/reaps its complete child group. *)
