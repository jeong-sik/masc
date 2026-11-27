open Alcotest
open Masc

module Fs = Keeper_volume_filesystem
module Watch = Keeper_volume_filesystem_watch
module Sweep = Server_keeper_volume_maintenance

let volume_entry ~volume =
  `Assoc
    [ "id", `String volume
    ; ( "configuration"
      , `Assoc
          [ "name", `String volume
          ; "format", `String "ext4"
          ; "source", `String ("/images/" ^ volume ^ ".img")
          ] )
    ]
;;

let inspect_json ~volume = `List [ volume_entry ~volume ]

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

(* A3-2b: a multi-account host starts the volume reclaim and the sandbox GC
   report, and keeps only the Keeper build maintenance off. *)
let test_host_maintenance_loops_per_account_shape () =
  let loops ~multi_account = Server_bootstrap_maintenance.host_maintenance_loops ~multi_account in
  check bool "multi-account reclaims volumes" true
    (List.mem `Volume_reclaim (loops ~multi_account:true));
  check bool "multi-account reports sandbox GC" true
    (List.mem `Sandbox_gc_report (loops ~multi_account:true));
  check bool "multi-account skips the Keeper build maintenance" false
    (List.mem `Keeper_build (loops ~multi_account:true));
  check bool "single account keeps the Keeper build maintenance" true
    (List.mem `Keeper_build (loops ~multi_account:false));
  check int "single account starts all three loops" 3
    (List.length (loops ~multi_account:false))
;;

let test_inspect_from_list_batches_and_handles_missing_and_fallback () =
  let list_calls = ref 0 in
  let fallback_calls = ref 0 in
  let batch =
    Sweep.inspect_from_list
      ~list_volumes:(fun () ->
        incr list_calls;
        Ok (`List [ volume_entry ~volume:"vol-a"; volume_entry ~volume:"vol-b" ]))
      ~fallback_inspect:(fun ~volume:_ ->
        incr fallback_calls;
        Error "unexpected fallback")
  in
  check int "lazy list_volumes not called before first inspect" 0 !list_calls;
  (match batch ~volume:"vol-a" with
   | Ok json ->
     (match Fs.image_of_inspect json with
      | Ok image -> check string "vol-a image source" "/images/vol-a.img" image.source
      | Error err -> fail (Fs.inspect_failure_to_string err))
   | Error detail -> fail detail);
  (match batch ~volume:"vol-b" with
   | Ok json ->
     (match Fs.image_of_inspect json with
      | Ok image -> check string "vol-b image source" "/images/vol-b.img" image.source
      | Error err -> fail (Fs.inspect_failure_to_string err))
   | Error detail -> fail detail);
  (match batch ~volume:"vol-missing" with
   | Error detail -> check string "missing volume error" "volume not found: vol-missing" detail
   | Ok _ -> fail "expected missing volume error");
  check int "single list_volumes call across 3 inspects" 1 !list_calls;
  check int "zero fallback calls for complete listing" 0 !fallback_calls;
  (* Empty listing proves absence without fallback. *)
  let empty_fallback = ref 0 in
  let empty_batch =
    Sweep.inspect_from_list
      ~list_volumes:(fun () -> Ok (`List []))
      ~fallback_inspect:(fun ~volume:_ ->
        incr empty_fallback;
        Error "unexpected")
  in
  (match empty_batch ~volume:"vol-absent" with
   | Error detail -> check string "empty list missing error" "volume not found: vol-absent" detail
   | Ok _ -> fail "expected missing error on empty list");
  check int "zero fallback on empty list" 0 !empty_fallback;
  (* Incomplete or corrupt listings (nameless entry, duplicate keys, id/name
     mismatch) fall back cleanly rather than hiding volumes. *)
  let check_falls_back label entries =
    let fb = ref 0 in
    let b =
      Sweep.inspect_from_list
        ~list_volumes:(fun () -> Ok (`List entries))
        ~fallback_inspect:(fun ~volume ->
          incr fb;
          Ok (inspect_json ~volume))
    in
    (match b ~volume:"vol-a" with
     | Ok _ -> ()
     | Error detail -> fail (label ^ ": " ^ detail));
    check int (label ^ " uses fallback") 1 !fb
  in
  check_falls_back "nameless entry"
    [ volume_entry ~volume:"vol-a"; `Assoc [ "id", `String "nameless" ] ];
  check_falls_back "duplicate name key"
    [ `Assoc
        [ "id", `String "vol-a"
        ; ( "configuration"
          , `Assoc
              [ "name", `String "vol-a"
              ; "name", `String "vol-b"
              ; "format", `String "ext4"
              ; "source", `String "/images/vol-a.img"
              ] )
        ]
    ];
  check_falls_back "duplicate configuration key"
    [ `Assoc
        [ "configuration", `Assoc [ "name", `String "vol-a"; "format", `String "ext4"; "source", `String "/a.img" ]
        ; "configuration", `Assoc [ "name", `String "vol-b"; "format", `String "ext4"; "source", `String "/b.img" ]
        ]
    ];
  check_falls_back "id and configuration.name mismatch"
    [ `Assoc
        [ "id", `String "vol-b"
        ; ( "configuration"
          , `Assoc
              [ "name", `String "vol-a"
              ; "format", `String "ext4"
              ; "source", `String "/images/vol-a.img"
              ] )
        ]
    ];
  (* Duplicate entries across array items propagate to [image_of_inspect] as [Entries]. *)
  let dup_batch =
    Sweep.inspect_from_list
      ~list_volumes:(fun () ->
        Ok (`List [ volume_entry ~volume:"vol-dup"; volume_entry ~volume:"vol-dup" ]))
      ~fallback_inspect:(fun ~volume:_ -> fail "unexpected fallback on duplicate")
  in
  (match dup_batch ~volume:"vol-dup" with
   | Ok json ->
     (match Fs.image_of_inspect json with
      | Error (Fs.Entries { count = 2 }) -> ()
      | Error err -> fail ("unexpected error: " ^ Fs.inspect_failure_to_string err)
      | Ok _ -> fail "expected duplicate entry rejection")
   | Error detail -> fail detail);
  (* Non-array JSON caches once and yields [Not_an_array] without fallback. *)
  let non_array_calls = ref 0 in
  let non_array_fb = ref 0 in
  let non_array_batch =
    Sweep.inspect_from_list
      ~list_volumes:(fun () -> incr non_array_calls; Ok (`Assoc []))
      ~fallback_inspect:(fun ~volume:_ -> incr non_array_fb; Error "unexpected")
  in
  List.iter
    (fun volume ->
       match non_array_batch ~volume with
       | Ok json ->
         (match Fs.image_of_inspect json with
          | Error Fs.Not_an_array -> ()
          | Error err -> fail ("unexpected error: " ^ Fs.inspect_failure_to_string err)
          | Ok _ -> fail "expected Not_an_array")
       | Error detail -> fail detail)
    [ "v1"; "v2" ];
  check int "non-array list called once" 1 !non_array_calls;
  check int "non-array zero fallbacks" 0 !non_array_fb;
  (* Listing failure propagates once without triggering N fallback calls. *)
  let failed_list_calls = ref 0 in
  let failed_fallback_calls = ref 0 in
  let failed_batch =
    Sweep.inspect_from_list
      ~list_volumes:(fun () ->
        incr failed_list_calls;
        Error "exit=1: daemon unavailable")
      ~fallback_inspect:(fun ~volume:_ ->
        incr failed_fallback_calls;
        Error "fallback")
  in
  List.iter
    (fun volume ->
       match failed_batch ~volume with
       | Error detail -> check string "cached list failure" "exit=1: daemon unavailable" detail
       | Ok _ -> fail "expected list failure")
    [ "vol-1"; "vol-2" ];
  check int "list_volumes called once on failure" 1 !failed_list_calls;
  check int "zero fallback calls on list failure" 0 !failed_fallback_calls;
  (* Cancellation escapes without poisoning the snapshot cache. *)
  let cancel_calls = ref 0 in
  let cancel_batch =
    Sweep.inspect_from_list
      ~list_volumes:(fun () ->
        incr cancel_calls;
        if !cancel_calls = 1
        then raise (Eio.Cancel.Cancelled (Failure "cancelled"))
        else Ok (`List [ volume_entry ~volume:"vol-after-cancel" ]))
      ~fallback_inspect:(fun ~volume:_ -> Error "unexpected")
  in
  (match cancel_batch ~volume:"vol-after-cancel" with
   | exception Eio.Cancel.Cancelled _ -> ()
   | Ok _ | Error _ -> fail "expected Cancelled to propagate");
  (match cancel_batch ~volume:"vol-after-cancel" with
   | Ok _ -> ()
   | Error detail -> fail ("retry after cancel failed: " ^ detail));
  check int "list_volumes retried after cancellation" 2 !cancel_calls;
  (* Steady-state second sweep uses Watch.latest cache and calls list_volumes 0 times. *)
  let notices = Sweep.create_notice_ledger () in
  let steady_list_calls = ref 0 in
  let steady_vols =
    [ "keeper", { Watch.name = "batch-steady-work"; kind = Watch.Work }
    ; "keeper", { Watch.name = "batch-steady-build"; kind = Watch.Build }
    ]
  in
  let run_pulse () =
    let batch_inspect =
      Sweep.inspect_from_list
        ~list_volumes:(fun () ->
          incr steady_list_calls;
          Ok (`List [ volume_entry ~volume:"batch-steady-work"; volume_entry ~volume:"batch-steady-build" ]))
        ~fallback_inspect:(fun ~volume:_ -> Error "unexpected")
    in
    Sweep.sweep
      ~notices
      ~now:(fun () -> 0.)
      ~inspect:batch_inspect
      ~read_image:(fun ~path:_ -> Ok Fs.Clean)
      ~post:(fun ~keeper_name:_ ~volume:_ ~content:_ ~meta_json:_ -> Ok ())
      ~warn_uncertain:(fun ~keeper_name:_ ~volume:_ ~observed_at:_ ~detail:_ -> ())
      ~volumes:(fun () -> steady_vols)
  in
  run_pulse ();
  check int "first pulse calls list_volumes once for both volumes" 1 !steady_list_calls;
  run_pulse ();
  check int "steady-state second pulse spawns zero list_volumes calls" 1 !steady_list_calls
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
        ; test_case "a multi-account host starts the workspace scoped loops" `Quick
            test_host_maintenance_loops_per_account_shape
        ; test_case "inspect_from_list batches lookups and handles missing or incomplete listings" `Quick
            test_inspect_from_list_batches_and_handles_missing_and_fallback
        ] )
    ]
;;
