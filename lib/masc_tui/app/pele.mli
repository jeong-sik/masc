(** Offline Pele ([masc-pele]) diagram rasterizer over [masc-pele-protocol:1].

    Sends a JSON scene request on stdin and accepts PNG bytes on stdout only
    when the helper confirms [masc-pele-protocol:1\n]. Owns and removes all
    temporary files via [Fun.protect]; enforces bounded execution timeout and
    propagates Eio cancellation after reaping any spawned child process. Never
    reads or writes the terminal. *)

type format =
  | Mermaid
  | Svg
  | Graph

type scene = private {
  format : format;
  source : string;
  max_width : int;
  font_size : int;
  now_ms : int64;
  colors : (string * string) option;
}

type crop = {
  left : float;
  top : float;
  right : float;
  bottom : float;
}

type raster = {
  width : int;
  height : int;
  crop : crop option;
}

type ending =
  | Exited of Unix.process_status
  | Killed_at_deadline
  | Cancelled

type runner = input:string -> output:string -> errors:string -> ending

val protocol_version : int
(** Supported helper protocol version ([1]). *)

val protocol_receipt : string
(** Exact confirmation line prefix expected from [masc-pele]:
    ["masc-pele-protocol:1"]. *)

val default_timeout_s : float
(** Default bounded subprocess execution timeout ([10.0] seconds). *)

val colors_of_palette : Masc_tui_term.Palette.t -> string * string
(** Format observed terminal [(foreground, background)] colors as lowercase
    [#rrggbb] hex pairs for {!scene}. *)

val scene :
  format:format ->
  max_width:int ->
  font_size:int ->
  now_ms:int64 ->
  colors:(string * string) option ->
  string ->
  scene
(** Freeze original source, layout metrics, timestamp, and optional palette
    colors into an immutable scene. Raster requests never relayout a scene. *)

val command_runner : ?executable:string -> run:(string -> ending) -> runner
(** Run [executable] (default ["masc-pele"]) with its three temp files through
    a supplied shell command runner. *)

val process_runner :
  ?executable:string ->
  ?timeout_s:float ->
  ?clock:_ Eio.Time.clock ->
  ?cancelled:(unit -> bool) ->
  unit ->
  runner
(** Direct [Unix.create_process] runner with [Unix.O_CLOEXEC] temp descriptors,
    bounded timeout, cooperative [?cancelled] polling (killing and reaping the
    child promptly when [cancelled ()] turns [true]), and clean kill-and-reap on
    deadline expiry, [WSTOPPED], or [Eio.Cancel.Cancelled]. Callers running
    inside an Eio event loop must pass [?clock] or dispatch onto
    {!Masc_tui_net.Worker_pool} / [Eio_unix.run_in_systhread] so blocking
    syscalls never stall the UI domain. *)

val render :
  cache_dir:string ->
  ?timeout_s:float ->
  ?clock:_ Eio.Time.clock ->
  ?cancelled:(unit -> bool) ->
  ?raster:raster ->
  ?runner:runner ->
  scene ->
  (string, string) result
(** Encode [scene] (and optional [raster] geometry) to JSON, execute [masc-pele]
    via [runner] (default {!process_runner}), verify the
    [masc-pele-protocol:1\n] handshake, and return PNG bytes or an explicit,
    bounded, control-stripped failure diagnostic. Always removes temporary files
    before returning. Callers inside Eio must pass [?clock] or run on a worker
    domain / systhread. *)
