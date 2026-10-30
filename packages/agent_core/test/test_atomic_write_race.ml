(** Race test for [Fs_atomic_eio.save_atomic].

    Property under test: N fibers saving to the same logical name
    never see a [renameat ENOENT] because each writer has a unique
    tmp path. Afterwards the target contains exactly one writer's
    bytes and no stray tmp sibling is left behind.

    Reference: masc-mcp#9780 (boundary-allow) — two fibers wrote to "<id>.json.tmp"
    and the second fiber's [rename] blew up when the first already
    consumed the shared tmp.

    All cases share a single [Eio_main.run] scheduler so coverage
    runs under bisect don't multiply io_uring instances past the
    memlock limit. *)

open Agent_core

let read_file path =
  try Some (Eio.Path.load path) with
  | Eio.Io _ | Unix.Unix_error _ -> None
;;

let scan_tmp_leftovers dir =
  Eio.Path.read_dir dir
  |> List.filter (fun name ->
    let len = String.length name in
    len > 4 && String.sub name (len - 4) 4 = ".tmp")
;;

(* ── Cases ───────────────────────────────────────────────────────── *)

let test_save_round_trip _env dir =
  (match Fs_atomic_eio.save_atomic ~dir ~name:"a.json" "hello" with
   | Ok () -> ()
   | Error e -> Alcotest.fail ("save failed: " ^ Error.to_string e));
  let target = Eio.Path.(dir / "a.json") in
  Alcotest.(check (option string)) "target content" (Some "hello") (read_file target)
;;

let test_save_overwrite _env dir =
  let save content =
    match Fs_atomic_eio.save_atomic ~dir ~name:"a.json" content with
    | Ok () -> ()
    | Error e -> Alcotest.fail ("save failed: " ^ Error.to_string e)
  in
  save "one";
  save "two";
  save "three";
  let target = Eio.Path.(dir / "a.json") in
  Alcotest.(check (option string)) "last writer wins" (Some "three") (read_file target)
;;

let test_concurrent_same_name _env dir =
  let n = 8 in
  let contents = List.init n (fun i -> Printf.sprintf "writer-%d" i) in
  let results = Array.make n (Error (Error.Internal "uninit")) in
  Eio.Switch.run (fun sw ->
    List.iteri
      (fun i content ->
         Eio.Fiber.fork ~sw (fun () ->
           results.(i) <- Fs_atomic_eio.save_atomic ~dir ~name:"shared.json" content))
      contents);
  Array.iteri
    (fun i r ->
       match r with
       | Ok () -> ()
       | Error e -> Alcotest.failf "fiber %d failed: %s" i (Error.to_string e))
    results;
  let target = Eio.Path.(dir / "shared.json") in
  let content = read_file target in
  Alcotest.(check bool) "target exists" true (content <> None);
  (match content with
   | Some s ->
     Alcotest.(check bool) "content is one writer's bytes" true (List.mem s contents)
   | None -> ());
  Alcotest.(check (list string)) "no leftover tmp" [] (scan_tmp_leftovers dir)
;;

let test_concurrent_distinct_names _env dir =
  let n = 8 in
  Eio.Switch.run (fun sw ->
    for i = 0 to n - 1 do
      let name = Printf.sprintf "file-%d.json" i in
      let content = Printf.sprintf "content-%d" i in
      Eio.Fiber.fork ~sw (fun () ->
        match Fs_atomic_eio.save_atomic ~dir ~name content with
        | Ok () -> ()
        | Error e -> Alcotest.failf "save %s: %s" name (Error.to_string e))
    done);
  for i = 0 to n - 1 do
    let target = Eio.Path.(dir / Printf.sprintf "file-%d.json" i) in
    let expected = Printf.sprintf "content-%d" i in
    Alcotest.(check (option string))
      (Printf.sprintf "file-%d content" i)
      (Some expected)
      (read_file target)
  done;
  Alcotest.(check (list string)) "no leftover tmp" [] (scan_tmp_leftovers dir)
;;

(* ── Suite: one Eio_main.run for the whole process ───────────────── *)

let () =
  Eio_main.run
  @@ fun env ->
  let counter = ref 0 in
  let run_with_dir f () =
    let fs = Eio.Stdenv.fs env in
    incr counter;
    let suffix = Printf.sprintf "%d_%d" (Unix.getpid ()) !counter in
    let dir = Eio.Path.(fs / "/tmp" / ("agent_core-atomic-" ^ suffix)) in
    Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 dir;
    Fun.protect
      ~finally:(fun () ->
        try Eio.Path.rmtree ~missing_ok:true dir with
        | _ -> ())
      (fun () -> f env dir)
  in
  Alcotest.run
    "fs_atomic_eio"
    [ ( "save_atomic"
      , [ Alcotest.test_case "round-trip" `Quick (run_with_dir test_save_round_trip)
        ; Alcotest.test_case
            "overwrite last-wins"
            `Quick
            (run_with_dir test_save_overwrite)
        ; Alcotest.test_case
            "concurrent same name no race"
            `Quick
            (run_with_dir test_concurrent_same_name)
        ; Alcotest.test_case
            "concurrent distinct names"
            `Quick
            (run_with_dir test_concurrent_distinct_names)
        ] )
    ]
;;
