(* #54296: a working-context signal sent while the server is still booting
   used to run its pass before the prompt registry was pinned, so the pass
   rendered [librarian.working_contexts_rule] as missing and was lost. The
   gate holds such signals and releases each Keeper exactly once when the
   registry is ready. These cases drive the real memory lane and read the
   prompt the pass needs inside the dispatched unit. *)

open Alcotest
open Masc
module Gate = Keeper_working_context_pass.For_testing

let rule_key = "librarian.working_contexts_rule"

let repo_source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()
;;

type observed =
  { keeper_name : string
  ; prompt_present : bool
  }

let prompt_present () = String.trim (Prompt_registry.get_prompt rule_key) <> ""

(* Temp dirs live under /tmp, where the Fs_compat test HOME guard refuses
   [remove_tree]; these are plain scratch directories. *)
let remove_dir dir = ignore (Sys.command (Filename.quote_command "rm" [ "-rf"; dir ]) : int)

(* Lane units run on other domains; the record they append to is shared. *)
type recorder =
  { mu : Stdlib.Mutex.t
  ; mutable rev : observed list
  }

(* Pin an empty directory: the state of a booting server before
   [Prompt_defaults.bootstrap_runtime]. *)
let pin_empty_registry () =
  Prompt_registry.clear ();
  let dir = Filename.temp_dir "wc-gate-empty-prompts" "" in
  Prompt_registry.set_markdown_dir dir;
  dir
;;

let pin_real_registry () =
  let dir = Filename.concat (repo_source_root ()) "config/prompts" in
  Prompt_registry.set_markdown_dir dir;
  dir
;;

(* The dispatch the gate calls: a real memory-lane submission whose unit
   records which Keeper ran and whether the rule prompt resolved. *)
let new_recorder () = { mu = Stdlib.Mutex.create (); rev = [] }

let record r o = Stdlib.Mutex.protect r.mu (fun () -> r.rev <- o :: r.rev)
let recorded r = Stdlib.Mutex.protect r.mu (fun () -> List.rev r.rev)

let lane_dispatch ~runs ~base_path ~keeper_name =
  match
    Keeper_memory_lane.submit ~base_path ~keeper_name (fun () ->
      record runs { keeper_name; prompt_present = prompt_present () })
  with
  | Keeper_memory_lane.Submitted | Keeper_memory_lane.Coalesced -> ()
  | Keeper_memory_lane.Ran_inline -> fail "memory lane was not initialized"
  | Keeper_memory_lane.Dropped -> fail "memory lane dropped the pass"
;;

let with_lane f =
  Masc_test_deps.ensure_rng_initialized ();
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "wc-gate-base" "" in
  Eio.Switch.on_release sw (fun () -> remove_dir base_path);
  Eio_context.with_test_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
  @@ fun () ->
  Keeper_memory_lane.For_testing.reset ();
  Keeper_memory_lane.init ~sw;
  Fun.protect
    ~finally:(fun () -> Keeper_memory_lane.For_testing.reset ())
    (fun () -> f ~base_path)
;;

let await_idle ~base_path names =
  List.iter
    (fun keeper_name -> Keeper_memory_lane.For_testing.await_idle ~base_path ~keeper_name)
    names
;;

let names runs = List.map (fun (r : observed) -> r.keeper_name) (recorded runs)

let test_signal_before_ready_runs_once_after_ready () =
  with_lane
  @@ fun ~base_path ->
  let empty_dir = pin_empty_registry () in
  check bool "boot state: rule prompt is missing" false (prompt_present ());
  let gate = Gate.create_gate () in
  let runs = new_recorder () in
  let dispatch = lane_dispatch ~runs in
  (* Two signals for one Keeper and one for another, all before readiness. *)
  Gate.signal gate ~dispatch ~base_path ~keeper_name:"alpha";
  Gate.signal gate ~dispatch ~base_path ~keeper_name:"beta";
  Gate.signal gate ~dispatch ~base_path ~keeper_name:"alpha";
  await_idle ~base_path [ "alpha"; "beta" ];
  check (list string) "nothing dispatched before the registry is pinned" [] (names runs);
  let (_ : string) = pin_real_registry () in
  Gate.open_gate gate ~dispatch;
  await_idle ~base_path [ "alpha"; "beta" ];
  check
    (list string)
    "each deferred Keeper dispatched exactly once, first-signal order"
    [ "alpha"; "beta" ]
    (names runs);
  check bool "every dispatched pass saw the rule prompt" true
    (List.for_all (fun (r : observed) -> r.prompt_present) (recorded runs));
  (* A second readiness call releases nothing again. *)
  Gate.open_gate gate ~dispatch;
  await_idle ~base_path [ "alpha"; "beta" ];
  check int "second open does not re-dispatch" 2 (List.length (recorded runs));
  remove_dir empty_dir
;;

let test_signal_after_ready_dispatches_directly () =
  with_lane
  @@ fun ~base_path ->
  let empty_dir = pin_empty_registry () in
  let gate = Gate.create_gate () in
  let runs = new_recorder () in
  let dispatch = lane_dispatch ~runs in
  (* Readiness first, with no signal pending. *)
  let (_ : string) = pin_real_registry () in
  Gate.open_gate gate ~dispatch;
  await_idle ~base_path [ "gamma" ];
  check (list string) "opening an empty gate dispatches nothing" [] (names runs);
  Gate.signal gate ~dispatch ~base_path ~keeper_name:"gamma";
  await_idle ~base_path [ "gamma" ];
  check (list string) "post-ready signal dispatched once" [ "gamma" ] (names runs);
  check bool "post-ready pass saw the rule prompt" true
    (List.for_all (fun (r : observed) -> r.prompt_present) (recorded runs));
  remove_dir empty_dir
;;

let test_pending_keepers_are_scoped_by_base_path () =
  with_lane
  @@ fun ~base_path ->
  let empty_dir = pin_empty_registry () in
  let other_base = Filename.temp_dir "wc-gate-other-base" "" in
  let gate = Gate.create_gate () in
  let seen = ref [] in
  let dispatch ~base_path ~keeper_name = seen := (base_path, keeper_name) :: !seen in
  Gate.signal gate ~dispatch ~base_path ~keeper_name:"delta";
  Gate.signal gate ~dispatch ~base_path:other_base ~keeper_name:"delta";
  Gate.open_gate gate ~dispatch;
  check
    (list (pair string string))
    "same name under two base paths is two Keepers"
    [ base_path, "delta"; other_base, "delta" ]
    (List.rev !seen);
  remove_dir other_base;
  remove_dir empty_dir
;;

let () =
  run
    "keeper_working_context_prompt_gate"
    [ ( "prompt readiness"
      , [ test_case
            "signal before ready runs once after ready"
            `Quick
            test_signal_before_ready_runs_once_after_ready
        ; test_case
            "signal after ready dispatches directly"
            `Quick
            test_signal_after_ready_dispatches_directly
        ; test_case
            "pending Keepers are scoped by base path"
            `Quick
            test_pending_keepers_are_scoped_by_base_path
        ] )
    ]
;;
