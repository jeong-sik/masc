(* test/test_oas_checkpoint_cancelled_never_absorbed.ml

   OCaml-side regression guard for the [CancelledNeverAbsorbed]
   invariant in [specs/keeper-state-machine/KeeperOASAdvanced.tla].

   The spec's [CancelledAbsorbed] bug action models a catch-all that
   swallows [Eio.Cancel.Cancelled] — a cancelled fiber returns a normal
   [Error] result instead of letting the cancel propagate to its parent
   switch.  The parent then believes the child completed cleanly while
   the cancel signal is lost ("zombie").  The spec's bug model is
   paired and verified on the TLA+ side; this test pins the OCaml
   runtime's compliance.

   [Keeper_oas_checkpoint.persist_checkpoint] is in the modelled OAS
   bridge surface (called from {!Cascade_runner}).  Its [try/with]
   returns [(unit, string) result] but re-raises [Cancelled] via a
   dedicated arm placed *before* the [| exn ->] catch-all.  This test
   asserts, by source inspection, that:

     1. the dedicated [| Eio.Cancel.Cancelled _ as e -> raise e] arm
        exists in [keeper_oas_checkpoint.ml], and
     2. it precedes the [| exn ->] catch-all in the same function (so a
        future reorder/removal can't silently funnel [Cancelled] into
        the [Error] branch).

   Source inspection rather than a runtime test because forcing
   [Fs_compat.save_file_atomic] to raise [Cancelled] would require
   mocking the filesystem module; the anchored-substring approach
   mirrors [test_keeper_supervisor_finally_cancel_swallow.ml] (the
   complementary case where re-raising from a [Fun.protect ~finally] is
   itself the regression). *)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let index_of haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec scan i =
    if i + n > h then None
    else if String.sub haystack i n = needle then Some i
    else scan (i + 1)
  in
  scan 0

let require ~label cond =
  if not cond then
    failwith
      (Printf.sprintf
         "[%s] keeper_oas_checkpoint.ml violates CancelledNeverAbsorbed \
          (KeeperOASAdvanced.tla): see lib/keeper/keeper_oas_checkpoint.ml \
          persist_checkpoint and iter 67 M-2.c"
         label)

let () =
  let parent p = Filename.dirname p in
  let exe = Sys.executable_name in
  let project_root = parent (parent (parent (parent exe))) in
  let candidates =
    [ Filename.concat project_root "lib/keeper/keeper_oas_checkpoint.ml"
    ; "lib/keeper/keeper_oas_checkpoint.ml"
    ; "../lib/keeper/keeper_oas_checkpoint.ml"
    ]
  in
  let src =
    match List.find_opt Sys.file_exists candidates with
    | Some p -> read_file p
    | None ->
      failwith
        (Printf.sprintf
           "no candidate source path resolved (cwd=%s, exe=%s)"
           (Sys.getcwd ()) exe)
  in
  (* Anchor 1: the dedicated re-raise arm exists. *)
  let reraise_arm = "| Eio.Cancel.Cancelled _ as e -> raise e" in
  require ~label:"cancelled re-raise arm present"
    (index_of src reraise_arm <> None);
  (* Anchor 2: it precedes the catch-all in the same with-block. *)
  (match index_of src reraise_arm, index_of src "| exn ->" with
   | Some i_reraise, Some i_catchall ->
     require ~label:"re-raise arm precedes catch-all"
       (i_reraise < i_catchall)
   | _ ->
     failwith "[order] expected both a Cancelled arm and an | exn -> catch-all");
  (* Anchor 3: the spec name is cited in the source comment so a future
     refactor that drops the arm also has to delete the rationale. *)
  require ~label:"spec invariant name cited"
    (index_of src "CancelledNeverAbsorbed" <> None);
  print_endline "test_oas_checkpoint_cancelled_never_absorbed: OK"
