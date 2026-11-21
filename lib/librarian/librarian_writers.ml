module Digest = Agent_core.Checkpoint_objects
module Machine = Librarian_machine
module Writer = Librarian_writer
module By_keeper = Map.Make (String)

type t =
  { now : unit -> float
  ; registered : string -> bool
  ; place : string -> Machine.place
  ; stores : string -> Librarian_unit_content.stores
  ; ask : Librarian_ask.input -> Librarian_read_result.t
  ; ask_room : Librarian_ask.room_input -> Librarian_room_result.t
  ; start_turn_log : string -> (unit, string) result
  ; declared : Machine.declared option Atomic.t
  ; writers : Writer.t By_keeper.t Atomic.t
  ; to_run : Writer.t Eio.Stream.t
  }

let create ~sw ~now ~registered ~place ~stores ~ask ~ask_room ~start_turn_log =
  let t =
    { now
    ; registered
    ; place
    ; stores
    ; ask
    ; ask_room
    ; start_turn_log
    ; declared = Atomic.make None
    ; writers = Atomic.make By_keeper.empty
    ; to_run = Eio.Stream.create max_int
    }
  in
  (* A writer is made wherever it is first asked for, in any domain. Its
     fiber is forked here, where [sw] lives. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec run_next () =
      let writer = Eio.Stream.take t.to_run in
      Eio.Fiber.fork_daemon ~sw (fun () ->
        Writer.run writer;
        `Stop_daemon);
      run_next ()
    in
    run_next ());
  t
;;

let live_writer writers keeper =
  match By_keeper.find_opt keeper writers with
  | None -> None
  | Some writer ->
    (match Writer.status writer with
     | Retired -> None
     | Booting | Open _ | Stopped _ -> Some writer)
;;

(* The table is replaced only when it is still the one that was read, so
   finding no live writer and registering a new one are one step. A writer
   that loses the race was never run and is dropped. *)
let rec ensure t keeper =
  let writers = Atomic.get t.writers in
  match live_writer writers keeper with
  | Some _ as found -> found
  | None ->
    if not (t.registered keeper)
    then None
    else (
      let writer =
        Writer.create
          ~now:t.now
          ~registered:(fun () -> t.registered keeper)
          ~declared:(fun () -> Atomic.get t.declared)
          ~stores:(t.stores keeper)
          ~ask:t.ask
          ~ask_room:t.ask_room
          ~start_turn_log:(fun () -> t.start_turn_log keeper)
          (t.place keeper)
      in
      if Atomic.compare_and_set t.writers writers (By_keeper.add keeper writer writers)
      then (
        Eio.Stream.add t.to_run writer;
        Some writer)
      else ensure t keeper)
;;

let rec view t keeper =
  match ensure t keeper with
  | None -> Error `No_writer
  | Some writer ->
    (match Writer.status writer with
     | Booting -> Error `Booting
     | Open line -> Ok (Writer.view line)
     | Stopped stop -> Error (`Stopped stop)
     (* It ended after it was found. The Keeper's next writer answers. *)
     | Retired -> view t keeper)
;;

let rec asked t keeper ~unregistered ask =
  match ensure t keeper with
  | None -> unregistered
  | Some writer ->
    (match ask writer with
     | Writer.Answered answer -> answer
     | Ended -> asked t keeper ~unregistered ask)
;;

let write t keeper ~by ~trace write =
  asked t keeper ~unregistered:(Machine.Unavailable Keeper_retired) (fun writer ->
    Writer.write writer ~by ~trace write)
;;

let act_unregistered = Machine.Not_done (Act_unavailable Keeper_retired)
let resume t keeper = asked t keeper ~unregistered:act_unregistered Writer.resume

let adopt t keeper ~by ~observed =
  asked t keeper ~unregistered:act_unregistered (fun writer -> Writer.adopt writer ~by ~observed)
;;

let restart_reading t keeper ~observed =
  asked t keeper ~unregistered:act_unregistered (fun writer ->
    Writer.restart_reading writer ~observed)
;;

(* Only the writer that retired leaves the table: by now the Keeper may be
   registered again and have another. *)
let rec forget t keeper writer =
  let writers = Atomic.get t.writers in
  match By_keeper.find_opt keeper writers with
  | None -> ()
  | Some current ->
    if current == writer
       && not (Atomic.compare_and_set t.writers writers (By_keeper.remove keeper writers))
    then forget t keeper writer
;;

let retire_writer t keeper writer =
  let retirement = Writer.retire writer in
  (match retirement with
   | Retired_now -> forget t keeper writer
   | Still_registered -> ());
  retirement
;;

let retire t keeper =
  match By_keeper.find_opt keeper (Atomic.get t.writers) with
  | None -> Writer.Retired_now
  | Some writer -> retire_writer t keeper writer
;;

let turn_closed t keeper = Option.iter Writer.turn_closed (ensure t keeper)

(* The value is set before any writer is told, and a writer reads it only
   when it takes a hint. A writer in the table the hints go to takes one; a
   writer added after that takes its first event later than the set, so it
   reads this value or a newer one. *)
let declaration_changed t declared =
  Atomic.set t.declared declared;
  By_keeper.iter
    (fun (_ : string) writer -> Writer.declaration_changed writer)
    (Atomic.get t.writers)
;;

let pulse t keepers =
  List.iter (fun keeper -> Option.iter Writer.pulse (ensure t keeper)) keepers;
  By_keeper.iter
    (fun keeper writer ->
       if not (t.registered keeper)
       then ignore (retire_writer t keeper writer : Writer.retirement))
    (Atomic.get t.writers)
;;

let statuses t =
  List.map
    (fun (keeper, writer) -> keeper, Writer.status writer)
    (By_keeper.bindings (Atomic.get t.writers))
;;

let held t =
  List.map
    (fun (keeper, writer) -> keeper, Writer.held writer)
    (By_keeper.bindings (Atomic.get t.writers))
;;
