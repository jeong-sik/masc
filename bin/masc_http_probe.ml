(** Time the TUI's own HTTP client with no TUI around it.

    RFC-0429 §3.0 asks which segment of a TUI request eats the seconds, and
    names two candidates: the connection pool, or where the TUI's main loop
    yields. This runs [Masc_http_client.get_sync] the way
    [Masc_tui_http.http_get] runs it — same library, same clock, same
    timeout — and nothing else, so a reading here is the transport with the
    TUI subtracted.

    Measured 2026-09-07 against the live server on this host, with a TUI
    running beside it:

    {v
    path                              server   this probe   live TUI
    /api/v1/keepers/asks (87 B)        8 ms       6 ms       1084 ms
    /api/v1/keepers/turns (2 KB)       1 ms       2 ms       1361 ms
    /api/v1/gate/keepers (9 KB)        2 ms       4 ms       3013 ms
    /api/v1/dashboard/briefing (1.5 MB)         16 ms       2508 ms
    v}

    So the pool is not the candidate. [--mimic-tui-loop] tries the other
    one — wait for a key, yield, repeat — and does not reproduce the stall
    either. [--loop-work-ms] adds the piece that was missing: what a loop
    iteration costs before it yields.

    {v
    loop work per iteration    asks (87 B)   briefing (1.5 MB)
    none                          8 ms            18 ms
    10 ms                       132 ms          5050 ms
    50 ms                       610 ms          timed out at 10 s
    v}

    The request advances one step per iteration of the loop beside it, so a
    reply costs the number of steps it takes times what one iteration costs.
    [asks] takes about thirteen steps at any loop cost; the megabyte-and-a-
    half takes some five hundred. Ten milliseconds of work per iteration is
    enough to turn an eighteen-millisecond read into five seconds, and fifty
    reaches the ten-second timeout RFC-0429 §1.2 recorded against the live
    TUI.

    What decides that is not the domain they share but where the loop waits.
    [--eio-wait] and [--eio-stdin] wait the same sixteen milliseconds inside
    Eio rather than inside the kernel, and the same 1.78 MB with the same
    10 ms of work per iteration reads:

    {v
    how the loop waits                       briefing (1.78 MB)
    Unix.select on stdin                     5544-5631 ms
    Eio.Time.sleep                              14-26 ms
    Eio.Flow.single_read on stdin, bounded      67-202 ms
    v}

    A loop blocked in the kernel freezes the whole domain, so the request
    gets one step per pass. A loop blocked inside Eio leaves the run queue,
    and the request runs until it blocks in turn.

    Usage: masc-http-probe --url URL [--token-file PATH] [--trials N]
    [--agent NAME] [--mimic-tui-loop] *)

let usage =
  "masc-http-probe --url URL [--token-file PATH] [--trials N] [--agent NAME] \
   [--mimic-tui-loop] [--loop-work-ms MS] [--eio-wait] [--eio-stdin]"

type args = {
  url : string;
  token_file : string option;
  trials : int;
  agent : string;
  mimic_tui_loop : bool;
  loop_work_ms : float;
  wait_through_eio : bool;
  wait_on_eio_stdin : bool;
}

(* The TUI sends this header on every request; the probe is only a control if
   the server sees the same caller. *)
let default_agent = "masc-tui"
let default_trials = 5

(* [Masc_tui_http.request_timeout_sec]. A probe that waited longer than the
   TUI does would report a success the TUI would have given up on. *)
let timeout_sec = 10.0

let parse_args argv =
  let rec walk acc = function
    | [] -> Ok acc
    | "--url" :: value :: rest -> walk { acc with url = value } rest
    | "--token-file" :: value :: rest ->
        walk { acc with token_file = Some value } rest
    | "--agent" :: value :: rest -> walk { acc with agent = value } rest
    | "--mimic-tui-loop" :: rest -> walk { acc with mimic_tui_loop = true } rest
    | "--eio-stdin" :: rest ->
        walk
          { acc with mimic_tui_loop = true; wait_on_eio_stdin = true }
          rest
    | "--eio-wait" :: rest ->
        walk { acc with mimic_tui_loop = true; wait_through_eio = true } rest
    | "--loop-work-ms" :: value :: rest -> (
        match float_of_string_opt value with
        | Some work when work >= 0.0 ->
            walk { acc with mimic_tui_loop = true; loop_work_ms = work } rest
        | Some _ | None ->
            Error
              (Printf.sprintf "--loop-work-ms wants a non-negative number, got %S"
                 value))
    | "--trials" :: value :: rest -> (
        match int_of_string_opt value with
        | Some trials when trials > 0 -> walk { acc with trials } rest
        | Some _ | None -> Error (Printf.sprintf "--trials wants a positive integer, got %S" value))
    | flag :: _ -> Error (Printf.sprintf "unknown argument %S" flag)
  in
  match
    walk
      { url = "";
        token_file = None;
        trials = default_trials;
        agent = default_agent;
        mimic_tui_loop = false;
        loop_work_ms = 0.0;
        wait_through_eio = false;
        wait_on_eio_stdin = false
      }
      (List.tl (Array.to_list argv))
  with
  | Error _ as error -> error
  | Ok args when String.equal args.url "" -> Error "--url is required"
  | Ok args -> Ok args

let read_token path =
  match In_channel.with_open_text path In_channel.input_all with
  | contents -> Ok (String.trim contents)
  | exception Sys_error detail -> Error detail

let headers ~agent ~token =
  let agent_header = [ ("X-MASC-Agent", agent) ] in
  match token with
  | None -> agent_header
  | Some token -> ("Authorization", "Bearer " ^ token) :: agent_header

let ms_of_ns ns = Int64.to_float ns /. 1e6

let trials ~env ~args ~token =
  let clock = Eio.Stdenv.clock env in
  let headers = headers ~agent:args.agent ~token in
  for trial = 1 to args.trials do
    let started = Mtime_clock.elapsed_ns () in
    let result =
      Masc_http_client.get_sync ~clock ~timeout_sec ~url:args.url ~headers ()
    in
    let elapsed = Int64.sub (Mtime_clock.elapsed_ns ()) started in
    match result with
    | Ok (status, body) ->
        Printf.printf "trial %d: %.1f ms, status %d, %d bytes\n%!" trial
          (ms_of_ns elapsed) status (String.length body)
    | Error detail ->
        Printf.printf "trial %d: %.1f ms, failed: %s\n%!" trial
          (ms_of_ns elapsed) detail
  done

(* [masc_tui.ml]'s [maximum_input_wait_seconds]. The shape below is only a
   control if it waits the way the TUI waits. *)
let tui_input_wait_seconds = 0.016

(* The TUI's main loop, reduced to the two things that decide who gets to
   run: it waits for a key with [Unix.select], which blocks the whole domain
   rather than one fiber, and then it yields. The guess this tests is that
   a fiber which yields is runnable again at once, so the scheduler never
   reaches the point where it asks the OS which sockets have answers.

   It does not hold. Measured 2026-09-07, the 87-byte reply comes back in
   6 ms with this loop spinning beside it -- against 1084 ms in the live
   TUI. Kept as the negative control, so the next reading starts past it. *)
(* What a frame costs, stood in for by arithmetic. The real loop lays out and
   writes a screen between one yield and the next, and a fiber waiting on a
   socket cannot run while that happens. This burns the time without needing
   a terminal, so the reading says what the cost does rather than what the
   drawing does. *)
let burn_cpu_for ~milliseconds =
  if milliseconds > 0.0 then begin
    let deadline =
      Int64.add
        (Mtime_clock.elapsed_ns ())
        (Int64.of_float (milliseconds *. 1e6))
    in
    let spun = ref 0 in
    while Int64.compare (Mtime_clock.elapsed_ns ()) deadline < 0 do
      incr spun
    done
  end

(* The same wait, told to Eio instead of to the kernel directly. A fiber that
   blocks here leaves the run queue, so whatever else is waiting on a socket
   runs until it blocks in turn -- rather than one step per pass, which is
   all a yield gives it.

   This waits on time alone, not on the keyboard, so it measures the one
   thing it is here to measure: what changes when the loop blocks inside Eio
   instead of inside the kernel. Racing [Eio_unix.await_readable Unix.stdin]
   against this sleep under [Fiber.first] is the shape a real loop would
   want, and on eio 1.3 it dies in the posix scheduler
   (lib_eio_posix/sched.ml:155, assertion failed) on the second pass, when
   the losing await is cancelled. Wiring the TUI's keyboard wait through Eio
   has to solve that first; the reading below does not depend on it. *)
let wait_through_eio_for ~clock =
  Eio.Time.sleep clock tui_input_wait_seconds

(* What a loop that must also wake on a key would do: read the terminal
   through Eio, bounded by the same 16 ms. Unlike [await_readable] this asks
   the flow for bytes, which is what the loop wants anyway -- it is about to
   read them. Whether cancelling the losing read is safe on a tty is the
   question this mode exists to answer. *)
let wait_on_eio_stdin_for ~clock ~stdin ~buffer =
  Eio.Fiber.first
    (fun () ->
      match Eio.Flow.single_read stdin buffer with
      | _read -> ()
      | exception End_of_file -> Eio.Time.sleep clock tui_input_wait_seconds)
    (fun () -> Eio.Time.sleep clock tui_input_wait_seconds)

let spin_like_the_tui ~finished ~work_ms ~wait_through_eio ~wait_on_eio_stdin
    ~clock ~stdin =
  let buffer = Cstruct.create 1024 in
  while not !finished do
    if wait_on_eio_stdin then wait_on_eio_stdin_for ~clock ~stdin ~buffer
    else if wait_through_eio then wait_through_eio_for ~clock
    else begin
      (* The waiting is the point; which descriptor came back is not read. *)
      let _readable, _, _ =
        Unix.select [ Unix.stdin ] [] [] tui_input_wait_seconds
      in
      ()
    end;
    burn_cpu_for ~milliseconds:work_ms;
    Eio.Fiber.yield ()
  done

let run ~env ~args ~token =
  if not args.mimic_tui_loop then trials ~env ~args ~token
  else begin
    let finished = ref false in
    Eio.Fiber.both
      (fun () ->
        Fun.protect
          ~finally:(fun () -> finished := true)
          (fun () -> trials ~env ~args ~token))
      (fun () ->
        spin_like_the_tui ~finished ~work_ms:args.loop_work_ms
          ~wait_through_eio:args.wait_through_eio
          ~wait_on_eio_stdin:args.wait_on_eio_stdin
          ~clock:(Eio.Stdenv.clock env)
          ~stdin:(Eio.Stdenv.stdin env))
  end

let () =
  match parse_args Sys.argv with
  | Error detail ->
      Printf.eprintf "%s\n%s\n%!" detail usage;
      exit 2
  | Ok args -> (
      match Option.map read_token args.token_file with
      | Some (Error detail) ->
          Printf.eprintf "token file: %s\n%!" detail;
          exit 2
      | token_result ->
          let token =
            match token_result with
            | Some (Ok token) -> Some token
            | Some (Error _) | None -> None
          in
          Eio_main.run @@ fun env ->
          Eio.Switch.run @@ fun sw ->
          Eio_context.set_env env;
          Eio_context.set_switch sw;
          Eio_context.set_clock (Eio.Stdenv.clock env);
          run ~env ~args ~token;
          (* The pool parks its connection on this switch and keeps it warm,
             so the switch has no reason to finish and returning here would
             hang. The readings are already printed and flushed. *)
          exit 0)
