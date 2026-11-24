(** Request-owned login processes. Input stays in memory and never reaches a
    Keeper, transcript, or process log. Registry scope is workspace + actor;
    the account lock uses the resolved physical credential store. *)
type key = Enter | Up | Down | Tab | Eof
type input = Text of string | Key of key
type error = Already_running | Not_found | Not_running | Input_pending | Invalid_input
  | Cancelled | Transport_failed | Process_failed of int | Interpreter_missing
  | Completion_failed of string
type pipe = Stdout | Stderr
(** What the login shows, as the process writes it. *)
type output =
  | Piped of pipe * string
      (** A chunk the process wrote to a pipe. The chunks in order are its
          text. *)
  | Screen of string
      (** The whole screen of the terminal the process runs in, after its
          latest write: the rows down to the last that shows text, one per
          line, with SGR styles and OSC 8 hyperlinks. A row the terminal
          wrapped joins the next without a line break. It replaces the
          screen before it. *)
(** Structured authentication prompts extracted from the official login
    process's output after stripping terminal escape sequences. Deduplicated
    per session so repeated terminal redraws emit each prompt once. *)
type auth_hint =
  | Auth_url of { url : string }
  | Device_code of
      { code : string
      ; verification_uri : string option
      }
(** Whose login it is. The kind tells an agent and a person apart, so no agent
    name reaches the sessions or the receipts of a person. *)
type actor =
  | Agent of string  (** A single-user caller, by its agent name. *)
  | Person of string  (** A person of multi-account login, by their user id (plan D1-4). *)
type t
val error_message : error -> string
val input_of_json : Yojson.Safe.t -> (input, error) result
val id : t -> string
val bind_account : t -> account_key:string -> (unit, error) result
(** Replace the provisional new-account lock with its prepared physical home
    before publishing its reference or starting a process. *)
val is_active : workspace:string -> actor:actor -> login_id:string -> bool
val monitor : t -> env:Eio_unix.Stdenv.base -> is_closed:(unit -> bool) ->
  (unit -> 'a) -> ('a, error) result
val with_session : workspace:string -> actor:actor -> account_key:string ->
  (t -> ('a, error) result) -> ('a, error) result
val submit : workspace:string -> actor:actor -> login_id:string -> input -> (unit, error) result
val cancel : workspace:string -> actor:actor -> login_id:string -> (unit, error) result
val python : binary:string -> string option
(** The interpreter that runs the login helper: the release's bundled
    [python/bin/python3] beside [binary] when it is executable, else the first
    executable [python3] in an absolute [PATH] directory. Empty and relative
    entries are ignored because the child runs from the Keeper workspace.
    [None] when neither exists. *)

val strip_ansi : string -> string
(** Remove ANSI CSI, OSC (including OSC 8 hyperlinks), DCS/APC, and two-byte
    ESC sequences from terminal or piped output. *)

val extract_auth_hints : string -> auth_hint list
(** Extract validated [https://] OAuth authorization URLs (including OSC 8
    hyperlink targets) and RFC 8628 / provider device user codes from raw
    output after stripping ANSI escapes. *)

val run : ?saved_login:(unit -> (bool, string) result) ->
  ?on_auth_hint:(auth_hint -> unit) ->
  t -> env:Eio_unix.Stdenv.base -> child_env:string array ->
  cwd:string -> argv:string list -> terminal:bool ->
  is_closed:(unit -> bool) -> on_ready:(unit -> unit) ->
  on_input_ready:(unit -> unit) ->
  on_output:(output -> unit) -> (unit, error) result
(** No session deadline: provider expiry, explicit cancel, disconnect and server
    shutdown own termination. The helper kills/reaps its complete child group.
    With [~terminal:false] the process writes to pipes and [on_output] gets
    {!Piped}; with [~terminal:true] it runs in an 80 x 24 terminal and gets
    {!Screen}. When [on_auth_hint] is provided, validated [https://] URLs and
    device codes are extracted cleanly and delivered once per unique value for
    the session. [saved_login] is a read-only observation for clients without a
    login-only command. A saved login closes input and ends/reaps the child
    before returning [Ok ()]; a failed observation returns [Completion_failed].
    It is checked while waiting and before forwarding input. *)
