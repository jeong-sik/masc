open Alcotest
open Masc

module Fs = Keeper_volume_filesystem
module Watch = Keeper_volume_filesystem_watch
module Sweep = Server_keeper_volume_maintenance

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

let inspect ~volume = Ok (inspect_json ~volume)
let damaged = Fs.Errors_recorded { count = 1; first = None; last = None }

(* This is the same sweep entrypoint used by [start]. Its injected effects
   are inspection, reading, Board publication and warning only. *)
let run_sweep ~notices ~read_image ~post ~warn_uncertain volumes =
  Sweep.sweep ~notices ~now:(fun () -> 0.) ~inspect ~read_image ~post
    ~warn_uncertain ~volumes:(fun () -> volumes)
;;

let test_damage_reaches_board_and_status () =
  let notices = Sweep.create_notice_ledger () in
  let volumes =
    [ "keeper", { Watch.name = "repair-hold-work"; kind = Watch.Work }
    ; "keeper", { Watch.name = "repair-hold-build"; kind = Watch.Build }
    ]
  in
  let posts = ref [] in
  let warnings = ref [] in
  let state = ref damaged in
  let read_image ~path:_ = Ok !state in
  let post ~keeper_name ~volume ~content ~meta_json =
    posts := (keeper_name, volume, content, meta_json) :: !posts;
    Ok ()
  in
  let warn_uncertain ~keeper_name ~volume ~observed_at:_ ~detail =
    warnings := (keeper_name, volume, detail) :: !warnings
  in
  let sweep () = run_sweep ~notices ~read_image ~post ~warn_uncertain volumes in
  sweep ();
  sweep ();
  check int "one Board write per damaged volume" 2 (List.length !posts);
  check int "no unknown notices" 0 (List.length !warnings);
  List.iter
    (fun (keeper, volume, content, meta) ->
       check string "notice keeper" "keeper" keeper;
       check bool "notice describes paused repair" true
         (Astring.String.is_infix ~affix:"does not start automatic" content);
       check bool "notice names its volume" true
         (Yojson.Safe.Util.member "volume" meta = `String volume);
       match Watch.latest ~volume with
       | Some { result = Ok { state; _ }; _ } ->
         check bool "damage retained for status" true (state = damaged)
       | Some _ | None -> fail "the damaged observation was not retained")
    !posts;
  state := Fs.Clean;
  sweep ();
  state := damaged;
  sweep ();
  check int "a clean read ends a recorded episode" 4 (List.length !posts)
;;

let test_unknown_notice_is_not_replayed_or_forgotten () =
  let notices = Sweep.create_notice_ledger () in
  let volume = { Watch.name = "repair-hold-unknown"; kind = Watch.Work } in
  let reads = ref [ Ok damaged; Error (Fs.Unreadable "unreadable"); Ok Fs.Clean; Ok damaged ] in
  let read_image ~path:_ =
    match !reads with
    | reading :: rest -> reads := rest; reading
    | [] -> fail "too many reads"
  in
  let posts = ref 0 in
  let warnings = ref 0 in
  let post ~keeper_name:_ ~volume:_ ~content:_ ~meta_json:_ =
    incr posts;
    Error "publication outcome unknown"
  in
  let warn_uncertain ~keeper_name:_ ~volume:_ ~observed_at:_ ~detail:_ = incr warnings in
  run_sweep ~notices ~read_image ~post ~warn_uncertain [ "keeper", volume ];
  run_sweep ~notices ~read_image ~post ~warn_uncertain [];
  for _ = 1 to 3 do
    run_sweep ~notices ~read_image ~post ~warn_uncertain [ "keeper", volume ]
  done;
  check int "a new damage episode is not suppressed" 2 !posts;
  check int "unknown writes remain visible without a listed volume or after clean" 6 !warnings
;;

let test_interrupted_post_and_reentrant_sweep_do_not_replay () =
  let notices = Sweep.create_notice_ledger () in
  let volume = { Watch.name = "repair-hold-interrupted"; kind = Watch.Work } in
  let posts = ref 0 in
  let warnings = ref 0 in
  let read_image ~path:_ = Ok damaged in
  let reenter = ref (fun () -> ()) in
  let post ~keeper_name:_ ~volume:_ ~content:_ ~meta_json:_ =
    incr posts;
    (!reenter) ();
    raise (Eio.Cancel.Cancelled (Failure "after Board write"))
  in
  let warn_uncertain ~keeper_name:_ ~volume:_ ~observed_at:_ ~detail:_ = incr warnings in
  let sweep () = run_sweep ~notices ~read_image ~post ~warn_uncertain [ "keeper", volume ] in
  reenter := sweep;
  (match sweep () with
   | () -> fail "cancellation was swallowed"
   | exception Eio.Cancel.Cancelled _ -> ());
  sweep ();
  check int "neither a reentrant sweep nor cancellation replays the write" 1 !posts;
  check int "interruption and the next pulse report uncertainty" 2 !warnings
;;

let test_failed_post_does_not_stop_other_volumes () =
  let notices = Sweep.create_notice_ledger () in
  let broken = { Watch.name = "repair-hold-throws"; kind = Watch.Work } in
  let next = { Watch.name = "repair-hold-after-throws"; kind = Watch.Build } in
  let posts = ref [] in
  let warnings = ref 0 in
  let read_image ~path:_ = Ok damaged in
  let post ~keeper_name:_ ~volume ~content:_ ~meta_json:_ =
    posts := volume :: !posts;
    if String.equal volume broken.name then failwith "after Board write" else Ok ()
  in
  let warn_uncertain ~keeper_name:_ ~volume:_ ~observed_at:_ ~detail:_ = incr warnings in
  let sweep () =
    run_sweep ~notices ~read_image ~post ~warn_uncertain
      [ "keeper", broken; "keeper", next ]
  in
  sweep ();
  sweep ();
  check (list string) "failure does not replay or stop the next volume"
    [ next.name; broken.name ] !posts;
  check int "the unresolved first notice is warned on both pulses" 2 !warnings;
  match Watch.latest ~volume:next.name with
  | Some { result = Ok { state; _ }; _ } ->
    check bool "the second volume was observed" true (state = damaged)
  | Some _ | None -> fail "the second volume was not observed"
;;

let () =
  run
    "server_keeper_volume_maintenance"
    [ ( "sweep"
      , [ test_case "damage reaches Board and status" `Quick
            test_damage_reaches_board_and_status
        ; test_case "unknown notice is retained" `Quick
            test_unknown_notice_is_not_replayed_or_forgotten
        ; test_case "interrupted and reentrant publication" `Quick
            test_interrupted_post_and_reentrant_sweep_do_not_replay
        ; test_case "one post exception does not stop the sweep" `Quick
            test_failed_post_does_not_stop_other_volumes
        ] )
    ]
;;
