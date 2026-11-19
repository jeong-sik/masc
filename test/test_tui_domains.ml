(* Which minor heap each TUI domain collects on, read inside domains started
   by the functions [Masc_tui.run_with_eio_context] calls. The UI domain
   applies its heap first, as the TUI does, so the IO domain started after
   it shows the runtime's heap only if nothing passed the UI's heap on. *)

let words () = (Gc.get ()).Gc.minor_heap_size

(* What the runtime gives a new domain: 256k words, or OCAMLRUNPARAM's [s]. *)
let runtime_words () = Domain.join (Domain.spawn words)

(* With OCAMLRUNPARAM present the operator's setting owns every domain. *)
let tuned_words runtime =
  match Sys.getenv_opt "OCAMLRUNPARAM" with
  | Some _ -> runtime
  | None -> 4 * 1024 * 1024

let expected runtime role =
  match Masc_tui_domains.minor_heap role with
  | Minor_heap.Runtime_default -> runtime
  | Minor_heap.Tuned -> tuned_words runtime

let test_each_domain_collects_on_its_roles_heap () =
  let runtime = runtime_words () in
  Masc_tui_domains.use_ui_heap ();
  Alcotest.(check int) "the UI domain" (expected runtime Ui) (words ());
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let io = Masc_tui_io_domain.start ~sw ~env in
  Alcotest.(check int) "the IO domain" (expected runtime Io) (Masc_tui_io_domain.run io words);
  let worker = Masc_tui_domains.start_worker_pool ~sw (Eio.Stdenv.domain_mgr env) in
  Alcotest.(check int) "the worker domain" (expected runtime Worker)
    (Domain_pool.submit_cpu ~name:__FUNCTION__ worker words)
;;

(* The decision itself: only the drawing domain, which allocates every frame,
   takes the large heap. The request domain mostly waits on the network, and
   the worker decodes a file only when its version moves. *)
let test_only_the_drawing_domain_takes_the_large_heap () =
  let tuned = function
    | Minor_heap.Tuned -> true
    | Minor_heap.Runtime_default -> false
  in
  Alcotest.(check (list bool)) "Ui, Io, Worker" [ true; false; false ]
    (List.map (fun role -> tuned (Masc_tui_domains.minor_heap role))
       Masc_tui_domains.[ Ui; Io; Worker ])
;;

let () =
  Alcotest.run "TUI domains"
    [ ( "minor heap"
      , [ Alcotest.test_case "each domain collects on its role's heap" `Quick
            test_each_domain_collects_on_its_roles_heap
        ; Alcotest.test_case "only the drawing domain takes the large heap" `Quick
            test_only_the_drawing_domain_takes_the_large_heap
        ] )
    ]
;;
