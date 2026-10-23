open Alcotest
open Masc
module Fs = Keeper_volume_filesystem
module Watch = Keeper_volume_filesystem_watch

(* RFC keeper-volume-filesystem-repair §3.2: the server's last read of each
   image-backed volume. The latest read is process-wide, so every case uses
   its own volume name. *)

let damaged = Fs.Errors_recorded { count = 3; first = None; last = None }

let inspect_json ~volume =
  `List
    [ `Assoc
        [ "id", `String volume
        ; ( "configuration"
          , `Assoc
              [ "name", `String volume
              ; "format", `String "ext4"
              ; "source", `String ("/images/" ^ volume ^ ".img")
              ] )
        ]
    ]
;;

(* An inspect that counts its calls and a read that answers from a queue. *)
let fakes reads =
  let inspected = ref 0 in
  let queue = ref reads in
  let inspect ~volume =
    incr inspected;
    Ok (inspect_json ~volume)
  in
  let read_image ~path:_ =
    match !queue with
    | next :: rest ->
      queue := rest;
      next
    | [] -> fail "read_image called more often than the case planned"
  in
  inspected, inspect, read_image
;;

let observe ~inspect ~read_image ~volume =
  Watch.observe ~now:0. ~inspect ~read_image ~volume
;;

let test_the_image_path_is_inspected_once () =
  let volume = "watch-path-once" in
  let inspected, inspect, read_image = fakes [ Ok Fs.Clean; Ok Fs.Clean ] in
  let _, first = observe ~inspect ~read_image ~volume in
  let _, second = observe ~inspect ~read_image ~volume in
  check int "one inspect for two reads" 1 !inspected;
  check (option string) "source kept" (Some "/images/watch-path-once.img") second.Watch.source;
  check bool "first read clean" true (first.Watch.result = Ok Fs.Clean)
;;

let test_a_failed_read_inspects_again () =
  let volume = "watch-failed-read" in
  let inspected, inspect, read_image =
    fakes [ Error (Fs.Unreadable "gone"); Ok Fs.Clean ]
  in
  let _ = observe ~inspect ~read_image ~volume in
  let _ = observe ~inspect ~read_image ~volume in
  check int "the read after a failure inspects again" 2 !inspected
;;

let test_an_inspect_failure_is_kept_as_such () =
  let volume = "watch-inspect-refused" in
  let inspect ~volume:_ = Error "XPC timeout" in
  let read_image ~path:_ = fail "no image to read" in
  let _, observation = observe ~inspect ~read_image ~volume in
  check (option string) "no source" None observation.Watch.source;
  check bool "inspect refused" true (observation.Watch.result = Error (Watch.Inspect_refused "XPC timeout"))
;;

let test_damage_appears_once () =
  let volume = "watch-damage-transitions" in
  let _, inspect, read_image = fakes [ Ok damaged; Ok damaged; Ok Fs.Clean; Ok damaged ] in
  let appeared () =
    let previous, current = observe ~inspect ~read_image ~volume in
    Watch.damage_appeared ~previous current
  in
  check bool "first read after start records errors" true (appeared ());
  check bool "still damaged" false (appeared ());
  check bool "repaired" false (appeared ());
  check bool "damaged again after a clean read" true (appeared ())
;;

let test_an_unparsed_inspect_is_typed () =
  let volume = "watch-inspect-unparsed" in
  let inspect ~volume:_ = Ok (`List []) in
  let read_image ~path:_ = fail "no image to read" in
  let _, observation = observe ~inspect ~read_image ~volume in
  check
    bool
    "no entry"
    true
    (observation.Watch.result = Error (Watch.Inspect_unparsed (Fs.Entries { count = 0 })))
;;

let test_latest_is_what_status_reads () =
  let volume = "watch-latest" in
  let _, inspect, read_image = fakes [ Ok damaged ] in
  let _ = observe ~inspect ~read_image ~volume in
  match Watch.latest ~volume with
  | Some observation ->
    check bool "latest read" true (observation.Watch.result = Ok damaged)
  | None -> fail "the read was not recorded"
;;

let () =
  run
    "keeper_volume_filesystem_watch"
    [ ( "observe"
      , [ test_case "image path inspected once" `Quick test_the_image_path_is_inspected_once
        ; test_case "failed read inspects again" `Quick test_a_failed_read_inspects_again
        ; test_case "inspect failure kept" `Quick test_an_inspect_failure_is_kept_as_such
        ; test_case "unparsed inspect typed" `Quick test_an_unparsed_inspect_is_typed
        ; test_case "damage appears once" `Quick test_damage_appears_once
        ; test_case "latest is what status reads" `Quick test_latest_is_what_status_reads
        ] )
    ]
;;
