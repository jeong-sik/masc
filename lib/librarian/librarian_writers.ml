module Digest = Agent_core.Checkpoint_objects
module Machine = Librarian_machine
module Writer = Librarian_writer
module By_keeper = Map.Make (String)
module StringSet = Set_util.StringSet

type t =
  { sw : Eio.Switch.t
  ; on_world_promotions :
      (keeper_id:string -> Librarian_lifecycle.world_promotion list -> unit) option Atomic.t
  ; now : unit -> float
  ; registered : string -> bool
  ; place : string -> Machine.place
  ; stores : string -> Librarian_unit_content.stores
  ; ask : Librarian_ask.input -> Librarian_read_result.t
  ; ask_room : Librarian_ask.room_input -> Librarian_room_result.t
  ; start_turn_log : string -> (unit, string) result
  ; declared : Machine.declared option Atomic.t
  ; writers : Writer.t By_keeper.t Atomic.t
  ; retiring : StringSet.t Atomic.t
  ; to_run : Writer.t Eio.Stream.t
  }

let create ~sw ~now ~registered ~place ~stores ~ask ~ask_room ~start_turn_log =
  let t =
    { sw
    ; on_world_promotions = Atomic.make None
    ; now
    ; registered
    ; place
    ; stores
    ; ask
    ; ask_room
    ; start_turn_log
    ; declared = Atomic.make None
    ; writers = Atomic.make By_keeper.empty
    ; retiring = Atomic.make StringSet.empty
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

let set_world_promotions_callback t cb = Atomic.set t.on_world_promotions cb

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
          ~on_world_promotions:(fun ~keeper_id promos ->
            Option.iter (fun cb -> cb ~keeper_id promos) (Atomic.get t.on_world_promotions))
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

let skip_item t keeper ~by ~target =
  asked t keeper ~unregistered:act_unregistered (fun writer -> Writer.skip_item writer ~by ~target)
;;

let skip_line t keeper ~offset =
  asked t keeper ~unregistered:act_unregistered (fun writer -> Writer.skip_line writer ~offset)
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

let rec claim_retiring t keeper =
  let cur = Atomic.get t.retiring in
  if StringSet.mem keeper cur
  then false
  else if Atomic.compare_and_set t.retiring cur (StringSet.add keeper cur)
  then true
  else claim_retiring t keeper
;;

let rec release_retiring t keeper =
  let cur = Atomic.get t.retiring in
  if not (StringSet.mem keeper cur)
  then ()
  else if Atomic.compare_and_set t.retiring cur (StringSet.remove keeper cur)
  then ()
  else release_retiring t keeper
;;

let pulse t keepers =
  List.iter (fun keeper -> Option.iter Writer.pulse (ensure t keeper)) keepers;
  (* Never block the global maintenance loop waiting on one retiring writer:
     fork each unregistered writer's retirement asynchronously on [t.sw]. *)
  By_keeper.iter
    (fun keeper writer ->
       if (not (t.registered keeper)) && claim_retiring t keeper
       then
         Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
           Fun.protect
             ~finally:(fun () -> release_retiring t keeper)
             (fun () -> ignore (retire_writer t keeper writer : Writer.retirement));
           `Stop_daemon))
    (Atomic.get t.writers)
;;

let compaction_epoch_advanced t keeper ~epoch_id =
  Option.iter (fun w -> Writer.compaction_epoch_advanced w ~epoch_id) (ensure t keeper)
;;

let request_molt t keeper ~trigger =
  Option.iter (fun w -> Writer.request_molt w ~trigger) (ensure t keeper)
;;

let is_stopped t keeper =
  match By_keeper.find_opt keeper (Atomic.get t.writers) with
  | None -> false
  | Some writer ->
    (match Writer.status writer with
     | Stopped _ -> true
     | Booting | Open _ | Retired -> false)
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
