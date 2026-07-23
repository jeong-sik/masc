(** Regression guard for the keeper chat consumer wake wiring (P0-A).

    The consumer blocks on its Wake_inbox; only [Keeper_chat_consumer
    .notify_transition] refills it after boot. Before this guard, the
    bootstrap installed only the SSE broadcast on the queue transition
    observer and never installed a slot-transition observer, so a message
    enqueued after boot received a receipt and a "queued" response but was
    never leased or delivered — no error, no log.

    [server_bootstrap_loops.ml] wires the live consumer subsystem and cannot
    be exercised without a full server env, so this is a source guard: it
    pins that the consumer setup installs BOTH wake paths (durable queue
    mutation and freed turn slot) to [notify_transition]. The delivery
    behaviour once the observers are installed is covered separately by
    [test_keeper_chat_consumer_delivery.ml]. *)

open Alcotest

let target_file = "lib/server/server_bootstrap_loops.ml"

let load_source rel =
  let root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat root rel in
  if not (Sys.file_exists path) then failwith ("source file not found: " ^ path);
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

(* Keep only code lines: drop whole-line comments so a marker mentioned in
   prose cannot satisfy the guard. *)
let code_lines src =
  String.split_on_char '\n' src
  |> List.filter (fun line ->
    let trimmed = String.trim line in
    not (String.length trimmed >= 2 && String.sub trimmed 0 2 = "(*"))
  |> String.concat "\n"

let contains ~needle haystack =
  let n = String.length needle and m = String.length haystack in
  let rec go i = i + n <= m && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0

let test_queue_mutation_wakes_consumer () =
  let src = code_lines (load_source target_file) in
  (* The durable queue transition observer must wake the consumer, not only
     refresh the dashboard over SSE. *)
  check bool
    "bootstrap installs Keeper_chat_consumer.notify_transition on queue mutation"
    true
    (contains ~needle:"Keeper_chat_consumer.notify_transition" src)

let test_slot_release_wakes_consumer () =
  let src = code_lines (load_source target_file) in
  (* A freed turn slot must make the lane dispatchable again by waking the
     consumer through the admission slot-transition observer. *)
  check bool
    "bootstrap installs Keeper_turn_admission.set_slot_transition_observer"
    true
    (contains ~needle:"Keeper_turn_admission.set_slot_transition_observer" src)

let () =
  run "keeper_consumer_wake_wiring"
    [ ( "p0a_wake_paths"
      , [ test_case "queue mutation wakes consumer" `Quick
            test_queue_mutation_wakes_consumer
        ; test_case "slot release wakes consumer" `Quick
            test_slot_release_wakes_consumer
        ] )
    ]
