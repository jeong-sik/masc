(** The writers of this process: one for every registered Keeper
    (RFC librarian-call-only-proposes §8.6, §9.5, §11.1).

    Nothing starts or stops a writer by name. The table follows the Keeper
    registry: whoever asks for a registered Keeper's writer gets the live
    one, and a new one is made when there is none or the last one ended. A
    Keeper that is not registered gets none. So the code that brings a
    Keeper up and the code that takes it out of the registry do not call
    this module to start or stop anything.

    Finding a writer and registering a new one are one step, so a Keeper
    never has two live writers here. A new writer's boot reads its files
    after that step, in the fiber this table runs it in.

    Every function but {!create} can be called from any domain. *)

module Digest := Agent_core.Checkpoint_objects

type t

(** Writers run on [sw], in the domain that calls [create], and so do their
    asks.

    [registered] says whether a Keeper has a writer: it is in the Keeper
    registry and writes a turn log. [place] is where that Keeper's files
    are, and [stores] where its turns' content is. [now] stamps every line.
    [ask] asks one question ({!Librarian_ask.run}). [start_turn_log] is a
    Keeper's store start first step, which its writer runs before every
    boot ({!Librarian_writer.create}). A table starts with no declaration,
    so no writer asks before {!declaration_changed}. *)
val create
  :  sw:Eio.Switch.t
  -> now:(unit -> float)
  -> registered:(string -> bool)
  -> place:(string -> Librarian_machine.place)
  -> stores:(string -> Librarian_unit_content.stores)
  -> ask:(Librarian_ask.input -> Librarian_read_result.t)
  -> ask_room:(Librarian_ask.room_input -> Librarian_room_result.t)
  -> start_turn_log:(string -> (unit, string) result)
  -> t

(** What a Keeper's request reads (§11.1). It does not wait for the writer.

    - [`Booting]: the writer is opening its store. A registered Keeper that
      is asked about for the first time gets its writer here, so this is the
      first answer.
    - [`Stopped _]: the store is stopped.
    - [`No_writer]: the Keeper is not registered. *)
val view
  :  t
  -> string
  -> (Librarian_writer.view, [ `Booting | `Stopped of Librarian_store.stop | `No_writer ]) result

(** A direct write to a Keeper's Memory. Waits for the writer's answer: its
    boot when it is booting, and one commit.

    [Unavailable Keeper_retired] is the answer for a Keeper that is not
    registered, and for no other. A writer that ended before it took the
    write did nothing with it, so the write goes to the Keeper's next
    writer. *)
val write
  :  t
  -> string
  -> by:Librarian_effects.actor
  -> trace:string
  -> Librarian_direct.write
  -> Librarian_machine.write_answer

val resume : t -> string -> Librarian_machine.act_answer

val adopt
  :  t
  -> string
  -> by:string
  -> observed:Digest.digest
  -> Librarian_machine.act_answer

(** For the path that removes a Keeper: call it after the Keeper is out of
    the registry and before its files are removed. [Retired_now] says no
    writer holds them. [Still_registered] says the Keeper is registered
    again and its writer goes on. *)
val retire : t -> string -> Librarian_writer.retirement

(** A [Closed] or a [Reset] line was appended to the Keeper's turn log
    (§9.5). A registered Keeper gets its writer, and the writer the hint. *)
val turn_closed : t -> string -> unit

(** The declaration of now, for every writer of the table and every writer
    made after it. [None]: no lane value is declared. *)
val declaration_changed : t -> Librarian_machine.declared option -> unit

(** The maintenance tick. Every Keeper of [keepers] that is registered gets
    its writer and a pulse, and the writer of every Keeper that is no longer
    registered is retired. *)
val pulse : t -> string list -> unit

(** The writers this table holds, by Keeper, with what each one shows. A
    reading only: it makes no writer. *)
val statuses : t -> (string * Librarian_writer.status) list

(** The writers this table holds, by Keeper, with what each one holds
    (§12). A reading only, as {!statuses}. *)
val held : t -> (string * Librarian_writer.held) list
