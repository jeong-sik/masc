open Alcotest
open Masc
module Fs = Keeper_volume_filesystem
module Watch = Keeper_volume_filesystem_watch
module Repair = Keeper_volume_repair
module Sweep = Server_keeper_volume_maintenance

(* RFC keeper-volume-filesystem-repair §3.3: when the sweep starts a repair.
   The marks are process-wide, so every case uses its own volume name. *)

let receipt =
  Repair.repair
    ~now:(fun () -> 0.)
    ~repair_id:"repair-1"
    ~helper:(Error "no helper image")
    ~backup_exists:(fun ~path:_ -> false)
    ~teardown:(fun () -> Ok ())
    ~read_image:(fun ~path:_ -> Ok Fs.Clean)
    ~clone:(fun ~source:_ ~target:_ -> Ok ())
    ~keeper:"k"
    ~volume:{ Watch.name = "masc-keeper-work-k"; kind = Watch.Work }
    ~image:"/images/work.img"
;;

type counts =
  { mutable lane : int
  ; mutable finished : int
  ; mutable refused : int
  }

let counts () = { lane = 0; finished = 0; refused = 0 }
let run_now ~on_error:_ run = run ()

let schedule counts ?(fork = run_now) ~lane volume =
  Sweep.schedule_repair
    ~fork
    ~run_in_lane:(fun () ->
      counts.lane <- counts.lane + 1;
      lane ())
    ~on_finished:(fun _ -> counts.finished <- counts.finished + 1)
    ~on_lane_error:(fun _ -> counts.refused <- counts.refused + 1)
    ~volume
;;

let ran () = Ok (`Ran receipt)

(* A repair that ran, whatever its outcome, is not run again until a clean
   read ends the episode: a repeat would remove the Keeper's guests on every
   idle pulse. *)
let test_a_repair_runs_once_per_episode () =
  let c = counts () in
  let volume = "schedule-once" in
  schedule c ~lane:ran volume;
  schedule c ~lane:ran volume;
  check int "one repair in the episode" 1 c.lane;
  check int "its result was handled" 1 c.finished;
  Sweep.end_episode volume;
  schedule c ~lane:ran volume;
  check int "a new episode repairs again" 2 c.lane
;;

let test_a_busy_keeper_is_tried_again () =
  let c = counts () in
  let volume = "schedule-busy" in
  let busy () = Ok (`Busy Keeper_owner.Admission_paused) in
  schedule c ~lane:busy volume;
  schedule c ~lane:busy volume;
  check int "tried on each pulse" 2 c.lane;
  check int "nothing finished" 0 c.finished
;;

let test_a_refused_lane_is_reported_and_tried_again () =
  let c = counts () in
  let volume = "schedule-refused" in
  let refused () =
    Error (Keeper_owner_registry.Command_lookup_failed (Keeper_owner_registry.Owner_not_found "k"))
  in
  schedule c ~lane:refused volume;
  schedule c ~lane:refused volume;
  check int "tried on each pulse" 2 c.lane;
  check int "each refusal reported" 2 c.refused
;;

(* While a repair waits for or holds the lane, the next pulse starts no
   second one, and a clean read does not clear its mark. *)
let test_a_running_repair_is_not_started_twice () =
  let c = counts () in
  let volume = "schedule-running" in
  let pending = ref [] in
  let defer ~on_error:_ run = pending := run :: !pending in
  schedule c ~fork:defer ~lane:ran volume;
  schedule c ~fork:defer ~lane:ran volume;
  check int "one fiber" 1 (List.length !pending);
  Sweep.end_episode volume;
  schedule c ~fork:defer ~lane:ran volume;
  check int "still one fiber" 1 (List.length !pending);
  List.iter (fun run -> run ()) !pending;
  schedule c ~lane:ran volume;
  check int "the episode's one repair ran" 1 c.lane
;;

let test_a_crashed_repair_is_tried_again () =
  let c = counts () in
  let volume = "schedule-crashed" in
  let catching ~on_error run =
    try run () with
    | Failure _ -> on_error ()
  in
  let crash () = failwith "lane callback raised" in
  schedule c ~fork:catching ~lane:crash volume;
  schedule c ~fork:catching ~lane:crash volume;
  check int "tried again after the crash" 2 c.lane
;;

let observation ~volume result = { Watch.volume; observed_at = 0.; result }

let test_the_observation_decides_what_to_do () =
  let volume = { Watch.name = "act-on"; kind = Watch.Work } in
  let scheduled = ref [] in
  let record ~(volume : Watch.volume) ~image = scheduled := (volume.name, image) :: !scheduled in
  let damaged = Fs.Errors_recorded { count = 1; first = None; last = None } in
  Sweep.act_on
    ~schedule:record
    ~volume
    (observation ~volume:volume.name (Ok { Watch.source = "/images/act-on.img"; state = damaged }));
  check (list (pair string string)) "damage schedules a repair of that image" [ "act-on", "/images/act-on.img" ] !scheduled;
  Sweep.act_on
    ~schedule:record
    ~volume
    (observation ~volume:volume.name (Error (Watch.Inspect_refused "XPC timeout")));
  check int "a failed read schedules nothing" 1 (List.length !scheduled);
  (* A clean read ends the episode, so the next damage is repaired again. *)
  let c = counts () in
  schedule c ~lane:ran volume.name;
  Sweep.act_on
    ~schedule:record
    ~volume
    (observation ~volume:volume.name (Ok { Watch.source = "/images/act-on.img"; state = Fs.Clean }));
  schedule c ~lane:ran volume.name;
  check int "repaired again after a clean read" 2 c.lane
;;

let () =
  run
    "server_keeper_volume_maintenance"
    [ ( "schedule"
      , [ test_case "once per episode" `Quick test_a_repair_runs_once_per_episode
        ; test_case "busy keeper tried again" `Quick test_a_busy_keeper_is_tried_again
        ; test_case "refused lane tried again" `Quick test_a_refused_lane_is_reported_and_tried_again
        ; test_case "running repair not started twice" `Quick test_a_running_repair_is_not_started_twice
        ; test_case "crashed repair tried again" `Quick test_a_crashed_repair_is_tried_again
        ; test_case "observation decides" `Quick test_the_observation_decides_what_to_do
        ] )
    ]
;;
