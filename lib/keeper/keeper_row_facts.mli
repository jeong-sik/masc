(** The facts of a Keeper's row that are kept in memory beside a file that is
    not a [Dated_jsonl] store (RFC "Keeper row facts are kept in memory by
    their writers", section 3.2). There is one: the newest row of the
    Keeper's decision record.

    {1 The newest decision row}

    The value is what the record's reader answers from the file: the newest
    row that is a JSON object within the record's last
    {!decision_window_lines} lines and {!decision_window_bytes} bytes, and
    [None] when there is none or no file.

    The record is one file, [keepers/<name>.decisions.jsonl]. Its cell is
    found by the name the file system gives that file ({!File_system_named}),
    so two spellings of the file reach one cell.

    Who changes the file: [Keeper_types_support.append_decision_record]
    appends its rows and rotates it, from a Keeper's turn, and the Keeper's
    purge removes it. A turn and a purge run only in the process that holds
    the workspace's writer lease. So a value is kept only in a process that
    said {!Fact_cell.keep_in_this_process}; any other process reads the file
    every time. *)

val decision_window_bytes : int
(** How far back from the record's end its reader looks. *)

val decision_window_lines : int
(** How many of the record's last lines its reader looks at. *)

(** One line of the record, as its reader takes it. *)
type decision_line =
  | Decision_row of Yojson.Safe.t  (** A JSON object. *)
  | Not_json of string  (** What the parser said. *)
  | Not_an_object

val decision_line : string -> decision_line
(** [decision_line line] reads a line without its newline. The reader and
    the writer's step both read a line with this function. *)

val newest_decision
  :  path:string
  -> read:(unit -> (Yojson.Safe.t option, 'e) result)
  -> (Yojson.Safe.t option, 'e) Fact_cell.filled
(** The newest decision row of the record at [path]. [read] reads it from the
    file and fails rather than answer [None] for a file it could not read: a
    kept [None] would stand until the next row is written.

    In a process that keeps facts the value is the cell's when the cell is
    filled, and [read]'s otherwise, kept when the cell did not change during
    the read. In any other process [read] runs every time and nothing is
    kept: the answer is {!Fact_cell.Read_not_kept} or
    {!Fact_cell.Read_failed}. *)

(** What an append did to the record's file besides adding the row. *)
type appended =
  | To_the_file_there
  | After_a_rotation
      (** The file that was there was renamed away or removed first, and the
          row went to a new file. *)

val appending_decision : path:string -> row:string -> (unit -> appended) -> unit
(** [appending_decision ~path ~row append] runs [append], which adds [row]
    and a newline to the record at [path], and keeps the record's cell right
    around it. [row] is the text that goes to disk.

    The cell is seen before [append] runs and settled after it. A filled
    cell takes the row when the row is a JSON object that, with its newline,
    is at least one byte shorter than the reader's window: that is the
    newest row a read then finds. For any other row the cell is forgotten and the next reader reads
    the file. The cell is also forgotten when another append of the record
    settled first, when the file came to exist under another name than the
    cell was chosen by, and when [append] raises: the file may or may not
    have changed. The exception is raised again. *)

val decision_records_removed : unit -> unit
(** Decision records were removed by code other than {!appending_decision}.
    Every remembered name and every kept row goes: which records went is not
    looked at, and neither is whether the removal succeeded. *)
