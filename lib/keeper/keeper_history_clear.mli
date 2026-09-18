(** Emptying a keeper's saved history ([masc_keeper_clear]).

    The clear saves the checkpoint of one trace with its conversation messages
    removed, and then says so in the keeper's turn-boundary store (RFC
    librarian-lifecycle §4.6). The order is the contract: the
    [History_restarted] line is appended only after the store reports the emptied
    checkpoint as saved, so a reader that sees the line knows the history was
    already emptied. A clear the store refused, or could not write, leaves no
    line.

    The line is not written first because a reader could then confirm its
    position against the still-full history with the line already in view,
    and have nothing left to explain the mismatch once the save lands. *)

type outcome =
  | Cleared of
      { cleared_message_count : int
      ; marker : (unit, string) result
            (** Whether the [History_restarted] line was written. [Error] does
                not undo or fail the clear, as a turn's line does not fail the
                turn. The keeper's next turn starts from the emptied history
                and writes the same line when it starts; until then nothing in
                the store explains why the history started over. A store that
                ends mid-line refuses every append until it is repaired, so
                neither that turn nor clearing again helps there (RFC §6). *)
      }
      (** The emptied checkpoint is the canonical one on disk. *)
  | Superseded of
      { incoming_turn_count : int
      ; known_turn_count : int
      }
      (** A newer writer owns the canonical checkpoint: the store's stale
          no-op. Nothing was written. *)
  | Save_unconfirmed of { detail : string }
      (** The save failed or raised, and no line was written. Whether the
          history was emptied is unknown, which is why the name does not
          claim it was not: the store reports a save only once the payload,
          the rename and the directory fsync all succeeded, so a failure
          before the last of those still leaves the emptied checkpoint as the
          canonical one. The tool surface answers with
          [Effect_outcome_unknown] and asks the operator to run the clear
          again, which is safe either way. *)

(** Empty the history [ctx] holds and save it as the checkpoint of [session].
    [preserve_system] keeps the [System] messages, which are not atoms, so
    either way the saved history holds no atom. The trace the line names is
    [session.session_id], the value the checkpoint is saved under.

    Nothing but a cancellation is raised: a save that raises is [Save_unconfirmed],
    and a line that cannot be written is [marker]. A cancellation the store
    re-raises after it has written the checkpoint leaves an emptied history
    with no line, the one state this module cannot report. *)
val clear
  :  keepers_dir:string
  -> runtime_id:string
  -> keeper_name:string
  -> session:Keeper_context_core.session_context
  -> preserve_system:bool
  -> Keeper_context_core.working_context
  -> outcome
