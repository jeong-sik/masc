(** The operator's acts on a Keeper's Memory writer, as the TUI sends them to
    [POST /api/v1/keepers/<k>/memory/act], and the answers it reads back
    (RFC librarian-call-only-proposes §12.4).

    Which acts a row offers follows what the writer machine accepts in that
    state. The value an act names comes from the row: the snapshot file's sha
    for an adoption, the turn log id for a restart, the line of the unit that
    does not read for a skip. The server reads the disk again when the act
    lands and refuses what no longer holds, so the answer is shown as the
    server wrote it. *)

type act =
  | Resume
  | Adopt of { observed : string }  (** The snapshot file's sha256, hex. *)
  | Restart_reading of { observed : string }  (** The turn log id on disk. *)
  | Skip_unreadable_unit of
      { turn_log : string
      ; line : int
      }  (** A skip of the unit at [line] whose content does not read. *)

val offered : Tui_decode_memory_writer.row -> act list
(** The acts the writer machine accepts for this row, in the order the key
    steps through them. A stopped store takes [Resume], and [Adopt] too when
    the log is diverged or unreadable and the snapshot file reads. A resting
    or bottomed store takes [Resume]. A reading that ended on a replaced turn
    log or a lost position takes [Restart_reading], one that ended on content
    that does not read takes the skip of that unit. *)

val step : act list -> armed:act option -> act option
(** The act the key arms next among [offered]: the first when nothing is
    armed or the armed act is no longer offered, the one after the armed act
    otherwise, back to the first after the last. [None] when nothing is
    offered. *)

val act_token : act -> string
(** The act's name on the wire: [resume], [adopt], [restart_reading] or
    [skip_item]. *)

val request : act -> Yojson.Safe.t
(** The request body, with exactly the fields the route takes. *)

type stop_detail =
  | Plain
  | Diverged of
      { expected : string
      ; observed : string
      }  (** The snapshot the log names and the one the file holds. *)
  | Raised of string

type stop =
  { stopped : string  (** The server's sentence for the stop. *)
  ; detail : stop_detail
  }

type store =
  | Store_open
  | Store_booting
  | Store_no_writer
  | Store_stopped of stop

type target =
  | Head_item of
      { turn_log : string
      ; line : int
      ; store : string
      ; at : int
      }
  | Unreadable_unit of
      { turn_log : string
      ; line : int
      }

type refusal =
  | Nothing_to_resume
  | Not_stopped
  | Snapshot_mismatch
  | Snapshot_unreadable
  | Not_replaced
  | Turn_log_unread
  | Not_the_head of target option  (** What reading stands on now, if anything. *)
  | Content_unread
  | Refused_store_stopped of stop
  | Keeper_not_registered

type answer =
  | Done of store  (** 200: the act landed; the store as it is after it. *)
  | Refused of refusal  (** 409: the machine refused; nothing changed. *)
  | Invalid_request of string  (** 400: the server's sentence. *)
  | No_writer_in_process  (** 503: the answering process runs no writer. *)

val read_answer :
  keeper:string -> act:act -> status_code:int -> body:string -> (answer, string) result option
(** [None] when the status is not one the route answers with (200, 400, 409,
    503): an auth refusal, a route this server lacks, a crash. [Some (Error _)]
    when the body of such a status does not decode, names another Keeper or
    act, or carries a field or word this build does not know. *)

val act_text : act -> string
(** The act and the value it names, in the wire's words. *)

val answer_text : ko:bool -> keeper:string -> act -> answer -> string
(** One line for the notice: the Keeper, the act and the server's answer in
    its own words -- the store after an accepted act, the refusal's code and
    what it carries. *)
