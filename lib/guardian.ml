(** Internal guardian loops (no external watchdog dependency). *)

open Printf

module Mode = struct
  type t = Masc | Lodge | Both

  let of_string s =
    match String.lowercase_ascii s with
    | "masc" | "mcp" -> Masc
    | "lodge" -> Lodge
    | "both" | "all" -> Both
    | _ -> Masc

  let to_string = function
    | Masc -> "masc"
    | Lodge -> "lodge"
    | Both -> "both"
end

let enabled = Env_config.Guardian.enabled
let mode = Mode.of_string Env_config.Guardian.mode
let masc_enabled =
  enabled && (match mode with Masc | Both -> true | Lodge -> false)

let lodge_enabled =
  enabled
  && Env_config.LodgeV2.enabled
  && (match mode with Lodge | Both -> true | Masc -> false)

let zombie_interval_s = Env_config.Guardian.zombie_interval_seconds
let gc_interval_s = Env_config.Guardian.gc_interval_seconds
let gc_days = Env_config.Guardian.gc_days

let lodge_interval_s = Env_config.Guardian.lodge_interval_seconds
let lodge_iterations = Env_config.Guardian.lodge_iterations
let lodge_delay_ms = Env_config.Guardian.lodge_delay_ms
let lodge_verbose = Env_config.Guardian.lodge_verbose
let lodge_respect_quiet_hours = Env_config.Guardian.lodge_respect_quiet_hours

let last_zombie_cleanup : string option ref = ref None
let last_gc : string option ref = ref None
let last_lodge : string option ref = ref None
let last_zombie_result : string option ref = ref None
let last_gc_result : string option ref = ref None
let last_lodge_result : (bool * string) option ref = ref None
let lodge_running = ref false

let log msg =
  eprintf "[guardian] %s\n%!" msg

let set_last r =
  r := Some (Types.now_iso ())

let is_quiet_hours () =
  if not lodge_respect_quiet_hours then false
  else
    let tm = Unix.localtime (Time_compat.now ()) in
    let hour = tm.Unix.tm_hour in
    let quiet_start = Env_config.LodgeV2.quiet_start in
    let quiet_end = Env_config.LodgeV2.quiet_end in
    quiet_start < quiet_end && hour >= quiet_start && hour < quiet_end

let status_json () : Yojson.Safe.t =
  let assoc = ref [
    ("enabled", `Bool enabled);
    ("mode", `String (Mode.to_string mode));
    ("masc_enabled", `Bool masc_enabled);
    ("lodge_enabled", `Bool lodge_enabled);
    ("zombie_interval_s", `Float zombie_interval_s);
    ("gc_interval_s", `Float gc_interval_s);
    ("gc_days", `Int gc_days);
    ("lodge_interval_s", `Float lodge_interval_s);
    ("lodge_iterations", `Int lodge_iterations);
    ("lodge_delay_ms", `Int lodge_delay_ms);
    ("lodge_verbose", `Bool lodge_verbose);
    ("lodge_respect_quiet_hours", `Bool lodge_respect_quiet_hours);
    ("lodge_running", `Bool !lodge_running);
  ] in
  let add_opt name = function
    | None -> ()
    | Some v -> assoc := (name, `String v) :: !assoc
  in
  add_opt "last_zombie_cleanup" !last_zombie_cleanup;
  add_opt "last_gc" !last_gc;
  add_opt "last_lodge" !last_lodge;
  (match !last_zombie_result with
   | None -> ()
   | Some v -> assoc := ("last_zombie_result", `String v) :: !assoc);
  (match !last_gc_result with
   | None -> ()
   | Some v -> assoc := ("last_gc_result", `String v) :: !assoc);
  (match !last_lodge_result with
   | None -> ()
   | Some (ok, msg) ->
       assoc := ("last_lodge_result", `Assoc [
         ("ok", `Bool ok);
         ("message", `String msg);
       ]) :: !assoc);
  `Assoc (List.rev !assoc)

let start_masc_loops ~sw ~clock config =
  if not masc_enabled then begin
    log "masc guardian disabled";
    ()
  end else begin
    if zombie_interval_s > 0.0 then
      Eio.Fiber.fork ~sw (fun () ->
        let rec loop () =
          (try
             let result = Room.cleanup_zombies config in
             last_zombie_result := Some result;
             set_last last_zombie_cleanup;
             log result
           with exn ->
             log (sprintf "zombie cleanup failed: %s" (Printexc.to_string exn)));
          Eio.Time.sleep clock zombie_interval_s;
          loop ()
        in
        loop ()
      );
    if gc_interval_s > 0.0 then
      Eio.Fiber.fork ~sw (fun () ->
        let rec loop () =
          (try
             let result = Room.gc config ~days:gc_days () in
             last_gc_result := Some result;
             set_last last_gc;
             log (sprintf "gc: %s" result)
           with exn ->
             log (sprintf "gc failed: %s" (Printexc.to_string exn)));
          Eio.Time.sleep clock gc_interval_s;
          loop ()
        in
        loop ()
      )
  end

let start_lodge_loop ~sw ~clock ~net =
  if not lodge_enabled then begin
    log "lodge guardian disabled";
    ()
  end else if lodge_interval_s <= 0.0 || lodge_iterations <= 0 then begin
    log "lodge guardian disabled by interval/iterations";
    ()
  end else
    Eio.Fiber.fork ~sw (fun () ->
      let rec loop () =
        if is_quiet_hours () then begin
          log "quiet hours - skipping lodge loop";
        end else begin
          lodge_running := true;
          let args = `Assoc [
            ("iterations", `Int lodge_iterations);
            ("delay_ms", `Int lodge_delay_ms);
            ("verbose", `Bool lodge_verbose);
          ] in
          let result =
            try Tool_lodge.autonomous_loop ~net args
            with exn ->
              (false, sprintf "exception: %s" (Printexc.to_string exn))
          in
          last_lodge_result := Some result;
          set_last last_lodge;
          lodge_running := false;
          (match result with
           | (true, msg) -> log (sprintf "lodge loop ok: %s" msg)
           | (false, msg) -> log (sprintf "lodge loop failed: %s" msg))
        end;
        Eio.Time.sleep clock lodge_interval_s;
        loop ()
      in
      loop ()
    )

let start ~sw ~clock ~net room_config =
  if not enabled then begin
    log "guardian disabled (set MASC_GUARDIAN_ENABLED=true)";
  end else begin
    start_masc_loops ~sw ~clock room_config;
    start_lodge_loop ~sw ~clock ~net;
    log (sprintf "guardian started (mode=%s)" (Mode.to_string mode))
  end
