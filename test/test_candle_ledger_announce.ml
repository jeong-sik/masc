(* RFC-0481 §3.2: a Candle ledger append tells the workspace's roster readers
   which Keepers' rows it moved. *)

open Alcotest
open Masc

module E = Candle_event

let at = match Candle_time.of_rfc3339 "2026-09-29T06:00:00Z" with
  | Ok at -> at
  | Error detail -> failwith detail

let event body : E.t = { at; body }

let touched = testable (fun ppf -> function
  | Candle_observe.Every_keeper -> Format.pp_print_string ppf "every keeper"
  | Candle_observe.Keepers keepers -> Format.fprintf ppf "keepers %s" (String.concat "," keepers))
  ( = )

let test_keepers_touched_names_the_moved_rows () =
  check touched "grants and a gift name their Keepers, once each"
    (Candle_observe.Keepers [ "alpha"; "beta"; "gamma" ])
    (Candle_observe.keepers_touched
       [ event (E.Granted { keeper = "beta"; amount_milli = 1000; reason = "seed" })
       ; event (E.Gifted { from_keeper = "beta"; to_keeper = "alpha"; amount_milli = 10; reason = "thanks" })
       ; event (E.Granted { keeper = "gamma"; amount_milli = 1000; reason = "seed" }) ]);
  check touched "a moved half-life moves every row" Candle_observe.Every_keeper
    (Candle_observe.keepers_touched
       [ event (E.Granted { keeper = "beta"; amount_milli = 1000; reason = "seed" })
       ; event (E.Half_life_set Candle_decay.Off) ]);
  check touched "a goal observation moves no row" (Candle_observe.Keepers [])
    (Candle_observe.keepers_touched
       [ event (E.Payout_failed
           { goal_id = "goal"; request_id = "req"; verification_run_id = "run"
           ; due_date = "2026-09-30" }) ])
;;

let test_ledger_appends_announce_their_keepers () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "candle-ledger-announce-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let heard = ref [] in
    let id = "candle-ledger-announce" in
    Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
      ~callback:(fun (sse : Sse.external_event) ->
        match
          Json_util.assoc_string_opt "type" sse.ext_payload,
          Json_util.assoc_string_opt "name" sse.ext_payload
        with
        | Some kind, Some name when String.equal kind Keeper_row_broadcast.row_changed_event ->
          heard := ("row", name) :: !heard
        | Some kind, None when String.equal kind Keeper_row_broadcast.roster_changed_event ->
          heard := ("roster", "") :: !heard
        | (Some _ | None), (Some _ | None) -> ())
      ();
    Server_candle_broadcast.install ();
    Fun.protect
      ~finally:(fun () ->
        Sse.unsubscribe_external id;
        Candle_ledger.install_append_observer (fun ~base_path:_ _ -> ()))
      (fun () ->
        let append events =
          match Candle_ledger.update ~base_path (fun _ -> Ok (events, ())) with
          | Ok () -> ()
          | Error error -> failf "%s" (Candle_ledger.update_error_to_string Fun.id error)
        in
        append
          [ event (E.Granted { keeper = "alpha"; amount_milli = 2000; reason = "seed" })
          ; event (E.Granted { keeper = "beta"; amount_milli = 2000; reason = "seed" }) ];
        append [ event (E.Gifted { from_keeper = "alpha"; to_keeper = "beta"; amount_milli = 10; reason = "thanks" }) ];
        append [ event (E.Half_life_set Candle_decay.Off) ];
        check (list (pair string string)) "each append announces the rows it moved"
          [ "row", "alpha"; "row", "beta"; "row", "alpha"; "row", "beta"; "roster", "" ]
          (List.rev !heard)))
;;

let () =
  run "candle_ledger_announce"
    [ ( "touched"
      , [ test_case "names the rows events move" `Quick test_keepers_touched_names_the_moved_rows ] )
    ; ( "append"
      , [ test_case "ledger appends announce their Keepers" `Quick
            test_ledger_appends_announce_their_keepers ] )
    ]
;;
