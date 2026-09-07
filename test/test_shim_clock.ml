(** The shim reads its intervals off a clock no correction moves.

    [Shim_clock.elapsed_seconds] comes from a C stub over
    CLOCK_MONOTONIC rather than from [Unix.gettimeofday], because the shim's
    supervisor subtracts two readings to decide when to kill the payload, how
    long to drain its pipes, and how long to wait before SIGKILL. A wall-clock
    difference also measures whatever correction the clock took in between.

    These cases hold the two properties a caller of that kind depends on and
    one that says the stub is not the wall clock after all — a stub that
    called [gettimeofday] by mistake would pass the first two. *)

open Alcotest

let test_never_goes_backwards () =
  let previous = ref (Shim_clock.elapsed_seconds ()) in
  for _ = 1 to 2_000 do
    let now = Shim_clock.elapsed_seconds () in
    if now < !previous then
      failf "the clock went backwards: %.9f then %.9f" !previous now;
    previous := now
  done

let test_advances_over_a_sleep () =
  let before = Shim_clock.elapsed_seconds () in
  (* Slept in the kernel rather than spun, so the case measures elapsed time
     and not this process's CPU: [Sys.time] would pass a spin loop and fail
     this. *)
  ignore (Unix.select [] [] [] 0.05 : _ * _ * _);
  let elapsed = Shim_clock.elapsed_seconds () -. before in
  (* A floor only. An upper bound would be a scheduling assertion, and this
     runs beside every other suite. *)
  check bool
    (Printf.sprintf "0.05s of sleep advanced the clock (saw %.4fs)" elapsed)
    true
    (elapsed >= 0.04)

let test_origin_is_not_the_epoch () =
  (* CLOCK_MONOTONIC counts from an unspecified origin -- boot on both of the
     shim's targets -- so its reading is far below seconds-since-epoch. This
     is what separates it from the clock it replaced: on 2026-09-07 the wall
     clock reads about 1.79e9 and this reads about 5.1e5. Bounded loosely
     enough to stay true for a host up for years. *)
  let reading = Shim_clock.elapsed_seconds () in
  let one_year_of_seconds = 31_557_600. in
  check bool
    (Printf.sprintf "reading %.0f is an uptime, not an epoch time" reading)
    true
    (reading >= 0. && reading < 100. *. one_year_of_seconds)

let () =
  run "shim_clock"
    [ ( "monotonic"
      , [ test_case "never goes backwards" `Quick test_never_goes_backwards
        ; test_case "advances over a sleep" `Quick test_advances_over_a_sleep
        ; test_case "the origin is not the epoch" `Quick test_origin_is_not_the_epoch
        ] )
    ]
