(** Compact runtime-trust JSON + degraded snapshot row helpers,
    extracted from operator_control_snapshot.ml. *)

(* Local copies of trivial helpers to avoid sibling -> parent cycle. *)
let compact_runtime_trust_cache_ttl_sec = 10.0

(* Ordinary requests may reuse the compact projection. Source-triggered
   Current reads bypass it, including when no meta timestamp changed. *)
let compact_runtime_trust_cache_key
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
  =
  Printf.sprintf
    "operator:keeper-runtime-trust:compact:v1:%s:%s:%b"
    config.base_path
    meta.name
    meta.paused
;;

let project_compact_runtime_trust runtime_trust =
  let member key =
    match Json_util.assoc_member_opt key runtime_trust with
    | Some v -> v
    | None -> `Null
  in
  `Assoc
    [ "disposition", member "disposition"
    ; "disposition_reason", member "disposition_reason"
    ; "operator_disposition", member "operator_disposition"
    ; "operator_disposition_reason", member "operator_disposition_reason"
    ; "needs_attention", member "needs_attention"
    ; "attention_reason", member "attention_reason"
    ; "next_human_action", member "next_human_action"
    ; "execution", member "execution"
    ; "latest_terminal_reason", member "latest_terminal_reason"
    ; "latest_next_action", member "latest_next_action"
    ; "latest_causal_event", member "latest_causal_event"
    ]
;;

type read =
  | Read of Yojson.Safe.t
  | Timed_out of string

let compact_keeper_runtime_trust_observation ~config ~meta =
  let observation = Keeper_runtime_trust_snapshot.summary_observation ~config ~meta in
  {observation with json = project_compact_runtime_trust observation.json}
;;

let read_compact_keeper_runtime_trust
      ~read_policy
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
  =
  let read () = Keeper_runtime_trust_snapshot.summary_json ~config ~meta in
  let runtime_trust =
    match read_policy with
    | Dashboard_projection_read.Current -> read ()
    | Reuse ->
      Dashboard_cache.get_or_compute
        (compact_runtime_trust_cache_key ~config ~meta)
        ~ttl:compact_runtime_trust_cache_ttl_sec
        (Pool_work.cpu ~name:__FUNCTION__ read)
  in
  if Dashboard_cache.is_timeout_envelope runtime_trust
  then
    let detail =
      match Json_util.assoc_member_opt "message" runtime_trust with
      | Some (`String msg) when String.length (String.trim msg) > 0 -> msg
      | Some _ | None -> "runtime trust cache timed out"
    in
    Timed_out detail
  else Read (project_compact_runtime_trust runtime_trust)
;;

let keeper_runtime_trust_observation ~read_policy ~config ~meta =
  try
    match read_policy with
    | Dashboard_projection_read.Current ->
      compact_keeper_runtime_trust_observation ~config ~meta
    | Reuse ->
      (match read_compact_keeper_runtime_trust ~read_policy ~config ~meta with
       | Read json ->
         { Dashboard_projection_read.json
         ; next_deadline_unix = None
         ; completeness = Complete
         }
       | Timed_out detail ->
         { Dashboard_projection_read.json = `Null
         ; next_deadline_unix = None
         ; completeness = Partial detail
         })
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let detail = Printexc.to_string exn in
    Log.Dashboard.warn
      "operator snapshot trust compact failed for keeper %s: %s"
      meta.Keeper_meta_contract.name
      detail;
    { Dashboard_projection_read.json = `Null
    ; next_deadline_unix = None
    ; completeness = Partial detail
    }
;;
