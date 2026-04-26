(** Cross-cutting utilities used by many MASC subsystems.

    Kept small and dependency-light so every module can depend on it
    without introducing cycles. *)

(** Boolean environment variable with permissive truthy parsing:
    ["1"], ["true"], ["yes"], ["on"] (case/whitespace insensitive)
    all return [true]; absent, empty, or anything else returns [false]. *)
val env_true : string -> bool

(** [true] when [MASC_MCP_STRICT_FINALIZERS] env is truthy. Callers can
    opt into raising finally-block exceptions instead of swallowing
    them. *)
val strict_finalizers : unit -> bool

val handle_finalizer_error :
  module_name:string ->
  label:string ->
  during_exception:bool ->
  backtrace:Printexc.raw_backtrace ->
  exn ->
  unit
(** Logs a finalizer failure. When [during_exception = false] and
    [strict_finalizers ()] is [true], re-raises [exn] with its backtrace
    so strict runs surface hidden bugs. *)

val protect :
  module_name:string ->
  finally_label:string ->
  finally:(unit -> unit) ->
  (unit -> 'a) ->
  'a
(** Like [Fun.protect], but routes finalizer failures through
    {!handle_finalizer_error} so normal runs never lose the primary
    exception and strict runs surface finally failures. *)

val masc_dirname : string
(** SSOT directory name for MASC runtime state. Value is [".masc"].
    Call sites MUST reference this constant (or {!masc_dir_from_base_path})
    rather than inlining the literal — see #9571. The
    [test_masc_dirname_ssot] enforcement test flags regressions. *)

val masc_dir_from_base_path : base_path:string -> string
(** [masc_dir_from_base_path ~base_path] is
    [Filename.concat base_path masc_dirname]. Canonical way to spell
    [<base_path>/.masc]. *)

val auth_dir_from_base_path : base_path:string -> string
(** [<base_path>/.masc/auth]. SSOT path so {!Auth} and
    {!Keeper_identity} can both compute it without depending on each
    other (RFC P2 cycle-break prep). *)

val agents_dir_from_base_path : base_path:string -> string
(** [<base_path>/.masc/auth/agents]. Same SSOT motivation as
    {!auth_dir_from_base_path}; this is where keeper credential JSON
    files live ([<agent_name>.json]). *)

val max_tool_output_bytes : int
(** SSOT 64KB cap for MCP tool response bodies. *)

val truncate_response :
  ?max_bytes:int ->
  total_count:int ->
  string ->
  string
(** [truncate_response ?max_bytes ~total_count s] returns [s] unchanged
    when its length is at most [max_bytes] (default
    {!max_tool_output_bytes}). Otherwise returns the first [max_bytes]
    characters followed by a machine-readable truncation suffix that
    records the original length and [total_count]. *)
