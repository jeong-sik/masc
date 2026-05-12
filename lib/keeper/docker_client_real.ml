(* RFC-0070 Phase 3b-iv.2.4 — Real Docker_client (all 4 functions wired).

   Sub-phase 3b-iv.2.0 shipped placeholders for all four S functions.
   Sub-phases 3b-iv.2.{1,2,3} wired [rm] (#14844), [exec] (#14854),
   and [run] (#14862). Sub-phase 3b-iv.2.4 (this) wires [ps_query] +
   the JSON parser for [docker ps --format '\{\{json .\}\}'] output.
   Phase 3b-iv.2 series closes here. *)

(* ── Exit-status mapping helpers ─────────────────────────────── *)

(* Docker CLI exit code semantics for [docker rm]:
     0   — container removed successfully
     1   — container not found, or removal blocked (generic failure)
     125 — daemon error / docker CLI itself errored
     127 — synthesized by [Process_eio.run_argv_with_status] when the
           CLI binary cannot be spawned (missing executable / exec
           error). Functionally identical to "daemon unreachable" from
           the caller's POV. *)
let map_exit_status_for_rm (status : Unix.process_status) =
  match status with
  | Unix.WEXITED 0 -> Ok ()
  | Unix.WEXITED 127 -> Error Docker_client.Daemon_unreachable
  | Unix.WEXITED _ -> Error Docker_client.Cleanup_failed
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error Docker_client.Daemon_unreachable

(* Docker CLI exit code semantics for [docker exec] AND [docker run]:
   both return the executed *command's* exit code on success; only
   daemon-level statuses (125, 127, signal) surface as
   [Error Daemon_unreachable]. A non-zero command exit is a *response*
   ([Ok exec_result]), not a daemon error. *)
let map_status_to_exec_result
    ((status, stdout, stderr) :
      Unix.process_status * string * string)
  =
  match status with
  | Unix.WEXITED 125 | Unix.WEXITED 127 ->
    Error Docker_client.Daemon_unreachable
  | Unix.WEXITED code ->
    Ok Docker_response.{ exit_code = code; stdout; stderr }
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
    Error Docker_client.Daemon_unreachable

(* ── JSON parsing helpers for ps_query ───────────────────────── *)

(* [parse_labels "k1=v1,k2=v2"] returns [[("k1","v1"); ("k2","v2")]].
   Empty input maps to []. Tokens without '=' are dropped. Docker emits
   labels as a single comma-joined string in [docker ps --format].

   Order-preserving — the parsed list mirrors docker's emission order.
   {!Docker_response.equal_ps_record} treats label order as
   significant; canonical ordering is a higher-level concern (e.g.
   sort by key) the parser does NOT impose here. *)
let parse_labels (s : string) : (string * string) list =
  if String.equal s "" then []
  else
    let parts = String.split_on_char ',' s in
    List.filter_map
      (fun part ->
        match String.index_opt part '=' with
        | None -> None
        | Some i ->
          let k = String.sub part 0 i in
          let v = String.sub part (i + 1) (String.length part - i - 1) in
          Some (k, v))
      parts

(* Required-only subset of docker's ps JSON line. [@@deriving
   yojson { strict = false }] tolerates unknown fields like
   [CreatedAt], [Status], [Ports] without failure. *)
type raw_ps_record =
  { id : string [@key "ID"]
  ; names : string [@key "Names"]
  ; state : string [@key "State"]
  ; labels : string [@key "Labels"]
  }
[@@deriving yojson { strict = false }]

(* [parse_ps_line line] decodes one JSON-formatted [docker ps] line
   into a {!Docker_response.ps_record}. Returns [None] when the line
   is empty, fails to decode as JSON, fails to match the required
   schema, or carries an unknown [State] token — every drop is
   *opportunistic*; the caller (ps_query) silently skips. This is
   the documented compromise between RFC §3.3 "no permissive default"
   and the operational reality that [docker ps] can emit stray output
   under unusual conditions (e.g. warning lines on stderr leaking into
   stdout under specific BuildKit configurations); a single
   unparseable line should NOT collapse the entire fleet listing. *)
let parse_ps_line (line : string) : Docker_response.ps_record option =
  let trimmed = String.trim line in
  if String.equal trimmed "" then None
  else
    match Yojson.Safe.from_string trimmed with
    | exception Yojson.Json_error _ -> None
    | json ->
      (match raw_ps_record_of_yojson json with
       | Error _ -> None
       | Ok raw ->
         (match Docker_response.parse_state raw.state with
          | Error _ -> None
          | Ok status ->
            Some
              Docker_response.
                { id = raw.id
                ; name = Keeper_container_name.of_external_string raw.names
                ; status
                ; labels = parse_labels raw.labels
                }))

(* [parse_ps_output stdout] splits stdout by newline and parses each
   line. Unparseable lines are silently dropped (see [parse_ps_line]'s
   rationale). *)
let parse_ps_output (stdout : string) : Docker_response.ps_record list =
  String.split_on_char '\n' stdout |> List.filter_map parse_ps_line

(* [labels_to_filter_args] folds each [(k, v)] into a [--filter
   label=k=v] pair on the argv, suitable for [docker ps]. *)
let labels_to_filter_args (labels : (string * string) list) : string list =
  List.concat_map
    (fun (k, v) -> [ "--filter"; Printf.sprintf "label=%s=%s" k v ])
    labels

(* ── Functions ───────────────────────────────────────────────── *)

let ps_query ~labels =
  let argv =
    [ "docker"; "ps"; "-a"; "--format"; "{{json .}}" ]
    @ labels_to_filter_args labels
  in
  let status, stdout, _stderr =
    Process_eio.run_argv_with_status_split argv
  in
  match status with
  | Unix.WEXITED 0 -> Ok (parse_ps_output stdout)
  | Unix.WEXITED 125 | Unix.WEXITED 127 ->
    Error Docker_client.Daemon_unreachable
  | Unix.WEXITED _ -> Error Docker_client.Probe_format_drift
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
    Error Docker_client.Daemon_unreachable

let exec ~container ~cmd =
  let argv =
    [ "docker"
    ; "exec"
    ; Keeper_container_name.to_string container
    ; "sh"
    ; "-lc"
    ; cmd
    ]
  in
  map_status_to_exec_result (Process_eio.run_argv_with_status_split argv)

let run plan =
  let container_name =
    Keeper_container_name.to_string (Keeper_sandbox_plan.container_name plan)
  in
  let image = Keeper_sandbox_plan.image plan in
  let command = Keeper_sandbox_plan.command plan in
  let timeout_sec = Keeper_sandbox_plan.timeout_budget_sec plan in
  let argv =
    [ "docker"
    ; "run"
    ; "--rm"
    ; "--name"
    ; container_name
    ; image
    ; "sh"
    ; "-lc"
    ; command
    ]
  in
  map_status_to_exec_result
    (Process_eio.run_argv_with_status_split ~timeout_sec argv)

let rm container =
  let argv =
    [ "docker"; "rm"; "-f"; Keeper_container_name.to_string container ]
  in
  let status, _stdout = Process_eio.run_argv_with_status argv in
  map_exit_status_for_rm status
