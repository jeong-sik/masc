module Digest = Agent_core.Checkpoint_objects
module Store = Librarian_store
module Direct = Librarian_direct

type place =
  { memory_dir : string
  ; turns_dir : string
  ; keeper_id : string
  }

type state =
  | Idle of Store.t
  | Stopped of Store.stop
  | Retired

let boot { memory_dir; turns_dir; keeper_id } ~at =
  match Store.boot ~memory_dir ~turns_dir ~keeper_id ~at with
  | Ok store -> Idle store
  | Error stop -> Stopped stop
;;

type unavailable =
  | Store_stopped of Store.stop
  | Keeper_retired

type write_answer =
  | Written of Librarian_log.commit
  | Already_held
  | Already_done
  | Already_absent
  | Refused of Direct.refusal
  | Not_a_snapshot of Librarian_envelope.refusal
  | Unavailable of unavailable

let write state ~at ~by ~trace write =
  match state with
  | Retired -> state, Unavailable Keeper_retired
  | Stopped stop -> state, Unavailable (Store_stopped stop)
  | Idle store ->
    (match Direct.plan ~by ~at ~trace_id:trace (Store.memory store).facts write with
     | Already_held -> state, Already_held
     | Already_done -> state, Already_done
     | Already_absent -> state, Already_absent
     | Refused refusal -> state, Refused refusal
     | Writes { effects; facts = (_ : Keeper_memory_os_types.fact list) } ->
       (match Store.commit_direct store ~at ~by ~trace write effects with
        | Committed { store; line } -> Idle store, Written line
        (* The line is on disk, so the write is committed. The snapshot is
           the next boot's to write. *)
        | Committed_without_snapshot line -> Stopped Store_unwritable, Written line
        | Stopped stop -> Stopped stop, Unavailable (Store_stopped stop)
        | Not_a_snapshot refusal -> state, Not_a_snapshot refusal))
;;

type act_refusal =
  | Nothing_to_resume
  | Not_stopped
  | Snapshot_mismatch
  | Snapshot_unreadable
  | Act_unavailable of unavailable

type act_answer =
  | Done
  | Not_done of act_refusal

let resume ~boot state =
  match state with
  | Retired -> state, Not_done (Act_unavailable Keeper_retired)
  | Idle (_ : Store.t) -> state, Not_done Nothing_to_resume
  | Stopped (_ : Store.stop) -> boot (), Done
;;

let adopt { memory_dir; turns_dir; keeper_id } state ~at ~by ~observed =
  match state with
  | Retired -> state, Not_done (Act_unavailable Keeper_retired)
  | Idle (_ : Store.t) -> state, Not_done Not_stopped
  | Stopped ((Memory_unreadable | Store_unwritable) as stop) ->
    state, Not_done (Act_unavailable (Store_stopped stop))
  | Stopped (Log_diverged _ | Log_unreadable) ->
    (match Store.adopt ~memory_dir ~turns_dir ~keeper_id ~at ~by ~observed with
     | Ok store -> Idle store, Done
     | Error Snapshot_mismatch -> state, Not_done Snapshot_mismatch
     | Error Snapshot_unreadable -> state, Not_done Snapshot_unreadable
     | Error (Not_adopted stop) -> state, Not_done (Act_unavailable (Store_stopped stop)))
;;
