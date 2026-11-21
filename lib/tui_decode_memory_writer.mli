(** One Keeper's Memory writer as its [keeper-memory-health] row carries it
    under [writer] (RFC librarian-call-only-proposes §12.1, §12.3).

    The server writes the member from what the writer holds
    ({!Keeper_memory_writer_health.keeper_rows}). Every token is closed: a
    token this build does not know fails the decode, and the row that carries
    it is drawn as refused. Nothing is given a default.

    The row's [request] says where the Keeper's latest request started
    against the read end (§11.3). The screen draws W2 and nothing else of
    it, so it is read to check W2 against and is not kept. *)

(** What one declared slot said to the last reading ask no slot answered. *)
type slot_outcome =
  | Input_too_large
  | Output_over_reserve
  | Window_reached
  | Refused  (** Refused without a size fact. *)
  | Not_called
  | Unavailable
  | Busy
  | Overdue
  | Lost
  | Unusable  (** It answered, and the answer could not be used. *)

(** Why the reader could not make the next question. Each carries what the
    operator sends to pass it (§12.4). *)
type input_fault =
  | Line_unreadable of { offset : int }
  | Turn_log_replaced of
      { expected : string
      ; observed : string option  (** [None]: the file names no id now. *)
      }
  | Position_lost of
      { offset : int
      ; length : int
      }
  | Content_unreadable of { line : int }

type ask_failure =
  | Raised
  | Flow_stopped
  | Read_failed

(** How the last reading ask ended, of those the writer keeps. *)
type last_read =
  | Read_committed
  | Read_refused_not_all_sized of
      { about_memory_now : bool
      ; about_lane_now : bool
      (** The lane value the refusals were read against is the one declared
          now. *)
      ; slots : (string * slot_outcome) list  (** By declared slot id. *)
      }
  (** Every slot declared then refused a question of one item, and not every
      one gave a size: the end E4 reads (§12.2). No slot was silent. *)
  | Read_lane of
      { one_item : bool
      ; silent : bool  (** A slot declared then said nothing. *)
      ; about_memory_now : bool
      ; slots : (string * slot_outcome) list  (** By declared slot id. *)
      }
  | Read_input_fault of input_fault
  | Read_ask_failed of ask_failure

(** How the last room ask ended. *)
type last_room =
  | Room_made
  | Room_unchanged
  | Room_stale
  | Room_not_judged
  | Room_fits_none of
      { about_memory_now : bool
      ; about_lane_now : bool
      }

type asked =
  | Asked_range
  | Asked_item_alone
  | Asked_room

type asking =
  { ask : int
  ; since : float
  ; asked : asked
  }

(** What an open store is doing. *)
type activity =
  | Idle
  | Asking of asking
  | Resting
  | Refused_at_bottom

(** How far reading stands. *)
type position =
  | Before_first
  | Through of
      { line : int
      ; within_item : bool  (** Part of the unit at [line], up to an item. *)
      }

(** The last line of the commit log. *)
type last_line =
  | Line_started
  | Line_commit of { seq : int }

type stop =
  | Log_diverged
  | Memory_unreadable
  | Log_unreadable
  | Store_unwritable
  | Store_raised

(** The snapshot file of a stopped store as it is on disk: what an adoption
    names (§12.4). *)
type snapshot_file =
  | File of
      { sha : string
      ; bytes : int
      }
  | File_absent
  | File_not_a_snapshot
  | File_not_read

(** What the writer keeps of its last asks, on an open store and on a
    stopped one alike. *)
type kept =
  { lane : bool  (** The writer holds a lane value. *)
  ; last_read : last_read option  (** [None]: no reading ask ended since the boot. *)
  ; last_room : last_room option
  ; read_alone : bool
  (** The last committed read was of an item alone, without Memory. *)
  }

type row =
  | Booting  (** What is unread cannot be told before the boot read the tail. *)
  | Retired
  | Open of
      { activity : activity
      ; unread : bool
      ; kept : kept
      ; last_line : last_line
      ; last_line_at : float
      ; turn_log : string
      ; covers_through : position
      ; snapshot : string  (** The snapshot sha the commit log's tail names. *)
      ; facts : int
      }
  | Stopped of
      { stop : stop
      ; snapshot_file : snapshot_file
      ; kept : kept
      }

type shown =
  { level : Librarian_level.level
  ; alarms : Librarian_level.alarm list
  ; row : row
  }

type t =
  | None_in_process
  (** The answering process runs no writer table. A server always runs one. *)
  | No_writer
  (** The Keeper is not in the registry, so no writer is made for it (§11.1). *)
  | Writer of shown

val decode : Yojson.Safe.t -> (t, string) result
(** The [writer] member of a row. [Error] names the first field that is
    missing, unknown, of the wrong shape, or at odds with another: a level
    that is not {!Librarian_level.level} of the alarms, W2 on without a
    [behind] request or off with one, a [behind] whose [sends_from] is not
    past its [read_end], an ask on a state that is not asking, a state
    without the fields it carries. *)
