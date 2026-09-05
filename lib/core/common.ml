(* Local boolean-env helper for [masc_core]. It intentionally treats only
   1/true/yes/on as true and every other value as false; it does not mirror
   the richer [Env_config_core.get_bool] surface in [masc.config]. *)
let env_true name =
  match Sys.getenv_opt name with
  | None -> false
  | Some v ->
      let v = String.trim v |> String.lowercase_ascii in
      v = "1" || v = "true" || v = "yes" || v = "on"

let strict_finalizers () = env_true "MASC_STRICT_FINALIZERS"

let handle_finalizer_error ~module_name ~label ~during_exception ~backtrace ex =
  let suffix = if during_exception then " (during exception)" else "" in
  Log.Misc.error "%s %s failed in finalizer%s: %s"
    module_name label suffix (Printexc.to_string ex);
  if (not during_exception) && strict_finalizers () then
    Printexc.raise_with_backtrace ex backtrace

let protect ~module_name ~finally_label ~finally f =
  match f () with
  | v ->
      (try finally () with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | ex ->
           let bt = Printexc.get_raw_backtrace () in
           handle_finalizer_error ~module_name ~label:finally_label
             ~during_exception:false ~backtrace:bt ex);
      v
  | exception ex ->
      let bt = Printexc.get_raw_backtrace () in
      (try finally () with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | ex2 ->
           let bt2 = Printexc.get_raw_backtrace () in
           handle_finalizer_error ~module_name ~label:finally_label
             ~during_exception:true ~backtrace:bt2 ex2);
      Printexc.raise_with_backtrace ex bt

let masc_dirname = ".masc"

(* OUTPUT root segment for server-written keeper runtime state (meta json +
   metrics/memory/decisions/receipts sidecars). The SINGLE literal behind both
   keeper-dir SSOT functions; the input/output relocation (RFC) flips this one
   string (e.g. to "runtime/keepers"). *)
let keepers_runtime_dirname = "keepers"

(* What a fresh runtime config root may take from the distribution, keyed by an
   asset path relative to the embedded [config/] tree (or a bare top-level entry
   name). Keeper manifests are excluded: a workspace's roster is the operator's
   to declare, and the shipped examples autoboot into a sandbox the host may not
   have. The server's config-root seed has always dropped them; [masc init] did
   not, and on 2026-09-05 that produced four keepers that could not boot on a
   host without Docker and a hand-built sandbox image. [dune] is a build input
   ocaml-crunch swept up with the tree, not runtime config. *)
let seeds_into_fresh_config_root rel =
  let first_segment =
    match String.index_opt rel '/' with
    | Some i -> String.sub rel 0 i
    | None -> rel
  in
  (not (String.equal (Filename.basename rel) "dune"))
  && not (String.equal first_segment keepers_runtime_dirname)

let masc_dir_from_base_path ~base_path =
  Filename.concat base_path masc_dirname

(* Default-cluster keeper OUTPUT dir for callers holding only [base_path].
   Low-level on purpose: the cluster-aware [Workspace.keepers_runtime_dir]
   cannot be called from workspace-internal or accountability modules without a
   dependency cycle, so those route through here (matching their prior
   default-cluster behavior). *)
let keepers_runtime_dir_of_base ~base_path =
  Filename.concat (masc_dir_from_base_path ~base_path) keepers_runtime_dirname

type keeper_runtime_store =
  | Keeper_tool_usage
  | Keeper_runtime_manifests
  | Keeper_metrics
  | Keeper_execution_receipts
  | Keeper_turn_records
  | Keeper_provider_inputs
  | Keeper_reaction_ledger
  | Keeper_trajectories
  | Keeper_crash_events

let keeper_runtime_store_dirname = function
  | Keeper_tool_usage -> "tool_usage"
  | Keeper_runtime_manifests -> "runtime-manifests"
  | Keeper_metrics -> "metrics"
  | Keeper_execution_receipts -> "execution-receipts"
  | Keeper_turn_records -> "turn-records"
  | Keeper_provider_inputs -> "provider-inputs"
  | Keeper_reaction_ledger -> "reaction-ledger"
  | Keeper_trajectories -> "trajectories"
  | Keeper_crash_events -> "crash-events"

let keeper_runtime_stores =
  [ Keeper_tool_usage
  ; Keeper_runtime_manifests
  ; Keeper_metrics
  ; Keeper_execution_receipts
  ; Keeper_turn_records
  ; Keeper_provider_inputs
  ; Keeper_reaction_ledger
  ; Keeper_trajectories
  ; Keeper_crash_events
  ]

type keeper_runtime_store_placement =
  | Keeper_scoped_dated
  | Keeper_scoped_versioned
  | Keeper_scoped_rotated
  | Workspace_scoped

let keeper_runtime_store_placement = function
  | Keeper_metrics
  | Keeper_execution_receipts
  | Keeper_turn_records
  | Keeper_provider_inputs
  | Keeper_crash_events -> Keeper_scoped_dated
  | Keeper_reaction_ledger -> Keeper_scoped_versioned
  | Keeper_runtime_manifests -> Keeper_scoped_rotated
  | Keeper_tool_usage | Keeper_trajectories -> Workspace_scoped

let keeper_runtime_store_of_dirname name =
  List.find_opt
    (fun store -> String.equal name (keeper_runtime_store_dirname store))
    keeper_runtime_stores

let auth_dir_from_base_path ~base_path =
  Filename.concat (masc_dir_from_base_path ~base_path) "auth"

let agents_dir_from_base_path ~base_path =
  Filename.concat (auth_dir_from_base_path ~base_path) "agents"

(** How large one tool result may be on the wire before the harness carrying
    it writes it to a file of its own.

    An official-client CLI spills a tool result it considers too large to a
    path under its own session directory and hands the model that path. A
    Keeper cannot read it: its tools resolve inside the sandbox, and on a
    microvm profile the host path is not even mounted. The model is told
    about a file nothing it holds can open.

    Measured 2026-09-03 on the claude_code lane: a 20,000-byte result passed
    through whole, and the smallest spilled file on disk was 31,558 bytes, so
    the harness cuts somewhere between. This sits below the low end with
    room, which is what keeps a MASC result on the model's side of that line.

    This is the only ceiling on a tool result. A separate 64KB constant used
    to decide both when a result is stored as a blob and how much of a blob
    one read returns, so a read of an externalized result came back at
    exactly the size that gets spilled — the mechanism defeated itself, and
    six of the eighteen measured rejections were reads of MASC's own
    artifacts. Storing and reading are bounded by this one value, and a
    result larger than it arrives as pages the model can ask for. *)
let max_tool_result_wire_bytes = 16_384

(** How much of one tool result MASC carries inline when it owns the wire.

    On an agent-core lane MASC builds the request itself, so no CLI is sitting
    between the model and the result and nothing spills it to a file. The
    reason {!max_tool_result_wire_bytes} is low does not exist here, and
    applying it anyway turns a result the model could have read into a blob it
    has to fetch back — an extra round trip in the same turn that produced it.

    Measured over tool_calls 2026-09-01..03: 702 of 20,117 agent-core results
    landed between the two ceilings. 211 of those were {!Keeper_artifact_read}
    pages, which the wire ceiling now caps below 16KB anyway, leaving about
    491 results over three days — near 12% of agent-core turns — that become
    blobs for no reason a harness imposes.

    This bounds context growth rather than avoiding a spill, which is why it
    is a separate number and not the same one scaled. *)
let max_agent_core_inline_result_bytes = 65_536

(** Acceptance ceiling for one captured subprocess stream, split head/tail.

    Head is an [Exec_buffer] head buffer, which grows only as far as the
    output actually reaches, so a large head budget costs nothing on the
    common short-output call. Tail is a ring buffer allocated eagerly at
    [tail_cap], so it is sized to the 256KB already used per keeper by the
    dashboard retained-stream buffer rather than to the head budget.

    claude-code's comparable ceiling is 64 MiB, but it streams bash output to
    a file on disk; MASC retains the capture in memory for the turn, so the
    ceiling here is set lower. 8 MiB still leaves the blob store 128x the
    64KB inline budget for range reads. *)
let max_process_capture_head_bytes = 8 * 1024 * 1024

let max_process_capture_tail_bytes = 256 * 1024

(* One spelling of "this string is going into a path component". It lived in
   [Workspace_utils_ops], which sits above [masc_auth], so the auth layer built
   its credential paths by concatenating [agent_name] raw while the workspace
   layer sanitised the same value. Two answers for one question, and the
   unsanitised one was the layer holding tokens. *)
let safe_filename name =
  let buf = Buffer.create (String.length name * 3) in
  String.iter
    (fun c ->
      let c_lower = Char.lowercase_ascii c in
      let valid =
        (c_lower >= 'a' && c_lower <= 'z')
        || (c_lower >= '0' && c_lower <= '9')
        || c_lower = '.'
        || c_lower = '_'
        || c_lower = '-'
      in
      if valid then Buffer.add_char buf c_lower
      else Printf.bprintf buf "_%02x" (Char.code c))
    name;
  Buffer.contents buf
