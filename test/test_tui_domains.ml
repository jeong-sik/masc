(* Which TUI domain collects on which minor heap, checked on domains started
   the way the TUI starts them. The UI domain applies its heap first, as
   [Masc_tui.run_with_eio_context] does, so a domain started after it that
   took the UI's heap instead of its own would show it here. *)

let words () = (Gc.get ()).Gc.minor_heap_size

(* What the runtime gives a new domain: 256k words, or OCAMLRUNPARAM's [s]. *)
let runtime_words () = Domain.join (Domain.spawn words)

(* With OCAMLRUNPARAM present the operator's setting owns every domain. *)
let tuned_words runtime =
  match Sys.getenv_opt "OCAMLRUNPARAM" with
  | Some _ -> runtime
  | None -> 4 * 1024 * 1024

let test_only_the_drawing_domain_takes_the_large_heap () =
  let runtime = runtime_words () in
  Minor_heap.apply Masc_tui_domains.(minor_heap Ui);
  Alcotest.(check int) "the UI domain draws on the tuned heap" (tuned_words runtime) (words ());
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let io = Masc_tui_io_domain.start ~sw ~env ~minor_heap:Masc_tui_domains.(minor_heap Io) in
  Alcotest.(check int) "the IO domain keeps the runtime heap" runtime
    (Masc_tui_io_domain.run io words);
  let worker =
    Domain_pool.create ~sw ~domain_count:1
      (Minor_heap.domain_mgr Masc_tui_domains.(minor_heap Worker) (Eio.Stdenv.domain_mgr env))
  in
  Alcotest.(check int) "the worker domain keeps the runtime heap" runtime
    (Domain_pool.submit_cpu ~name:__FUNCTION__ worker words)
;;

let () =
  Alcotest.run "TUI domains"
    [ ( "minor heap"
      , [ Alcotest.test_case "only the drawing domain takes the large heap" `Quick
            test_only_the_drawing_domain_takes_the_large_heap
        ] )
    ]
;;
