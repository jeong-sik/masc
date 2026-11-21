(** What an operator does to a Keeper's Memory writer
    (RFC librarian-call-only-proposes §12.4).

    [POST /api/v1/keepers/:name/memory/act] takes one of:

    {v
    { "action": "resume" }
    { "action": "adopt", "observed": "<sha256 hex of the snapshot file>" }
    { "action": "restart_reading", "observed": "<id of the turn log file>" }
    v}

    - [resume] starts a stopped store again: its boot runs once more. The
      answer says how the store is afterwards, so a store that stopped again
      for the same reason says so.
    - [adopt] says the bytes the snapshot file holds are Memory: the way out
      of a store stopped because the commit log and the snapshot disagree, or
      because the log's last line does not decode (§8.7).
    - [restart_reading] reads the turn log file from its first line: the
      way out of reading that stands in another turn log than the file is,
      or at an offset the file does not hold. [observed] is the id the
      file's [Log_started] line names, so a file replaced again meanwhile is
      not read.

    The writer decides whether it takes the action. A refusal changes
    nothing. *)

module Digest := Agent_core.Checkpoint_objects

val permission : Masc_domain.permission

(** The Keeper a path names, when it is this route. *)
val route : string -> string option

type action =
  | Resume
  | Adopt of { observed : Digest.digest }
  | Restart_reading of { observed : Keeper_turn_log.Log_id.t }

val parse : string -> (action, string) result

(** How the Keeper's store is after the action. *)
type store =
  | Open
  | Booting
      (** A boot of the store is running after the action: another resume's,
          or the first boot of a new writer when the Keeper left the registry
          and was registered again. It reads what the action left, the line
          an adoption appended included, so the action is not sent again. *)
  | Stopped of Librarian_store.stop
  | No_writer  (** The Keeper left the Keeper registry meanwhile. *)

type answer =
  | Acted of store
  | Refused of Librarian_machine.act_refusal
  | No_writers  (** This process started no Memory writers for the workspace. *)

(** [actor] is the operator's name on the line an adoption appends. *)
val act : base_path:string -> keeper:string -> actor:string -> action -> answer

val handle_post
  :  Mcp_server.server_state
  -> actor:string
  -> Httpun.Request.t
  -> Http_reqd.t
  -> string
  -> string
  -> unit
