(** RFC-0108: trajectory writer atomicity stress.

    Drives many concurrent OCaml threads against [Trajectory.append_entry]
    for the same trace file (the contention surface that produced ~89
    utf-8 multibyte-tear lines in
    [.masc/trajectories/{analyst,imseonghan,sangsu,ramarama,issue_king,…}]
    on 2026-05-17). Post-fix the file must contain every record exactly
    once and every line must parse as JSON. *)

open Alcotest

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "%s_%d_%d_%.0f"
         prefix
         !counter
         (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  Unix.mkdir dir 0o755;
  dir

let read_lines path =
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let buf = Buffer.create 4096 in
        (try
           while true do
             Buffer.add_channel buf ic 4096
           done
         with End_of_file -> ());
        let content = Buffer.contents buf in
        String.split_on_char '\n' content
        |> List.filter (fun s -> s <> ""))

let make_entry ~tid ~seq : Trajectory.tool_call_entry =
  (* Multibyte payload that varies in length per record so utf-8 byte
     boundaries land at different offsets — that is the exact surface
     where the pre-fix shared-channel buffer corrupted lines. *)
  let kor_count = 100 + (seq mod 300) in
  let kor = String.concat "" (List.init kor_count (fun _ -> "가")) in
  {
    Trajectory.ts = Unix.gettimeofday ();
    ts_iso = "2026-05-17T00:00:00Z";
    turn = tid;
    round = seq;
    tool_name = Printf.sprintf "tool_%d" tid;
    args_json = Printf.sprintf "{\"k\":\"%s\",\"tid\":%d,\"seq\":%d}" kor tid seq;
    gate_decision = Trajectory.Pass;
    result = None;
    duration_ms = 0;
    error = None;
    cost_usd = 0.0;
  }

let test_concurrent_threads () =
  let dir = tmpdir "traj_atomicity" in
  let masc_root = dir in
  let keeper_name = "t_keeper" in
  let trace_id = "trace-test-1" in
  let n_threads = 16 in
  let n_records_per_thread = 100 in
  let threads =
    List.init n_threads (fun tid ->
      Thread.create
        (fun () ->
          for seq = 0 to n_records_per_thread - 1 do
            Trajectory.append_entry
              ~masc_root
              ~keeper_name
              ~trace_id
              (make_entry ~tid ~seq)
          done)
        ())
  in
  List.iter Thread.join threads;
  let path =
    Filename.concat
      (Filename.concat masc_root (Printf.sprintf "trajectories/%s" keeper_name))
      (Printf.sprintf "%s.jsonl" trace_id)
  in
  let lines = read_lines path in
  check
    int
    "line count == threads × records"
    (n_threads * n_records_per_thread)
    (List.length lines);
  (* Every line must parse — pre-fix utf-8 tear surfaces as Yojson
     Json_error or invalid_argument. *)
  let seen = Hashtbl.create (n_threads * n_records_per_thread) in
  List.iter
    (fun line ->
      let json =
        try Yojson.Safe.from_string line
        with e ->
          failf
            "invalid JSON (len=%d, first bytes %S): %s"
            (String.length line)
            (if String.length line > 60 then String.sub line 0 60 else line)
            (Printexc.to_string e)
      in
      let open Yojson.Safe.Util in
      let turn = json |> member "turn" |> to_int in
      let round = json |> member "round" |> to_int in
      let key = (turn, round) in
      if Hashtbl.mem seen key
      then failf "duplicate record: turn=%d round=%d" turn round;
      Hashtbl.add seen key ())
    lines;
  check
    int
    "unique (turn, round) pairs"
    (n_threads * n_records_per_thread)
    (Hashtbl.length seen)

let () =
  Alcotest.run
    "trajectory_atomicity"
    [ "atomicity",
      [ test_case "16 threads × 100 multibyte records" `Quick test_concurrent_threads ]
    ]
