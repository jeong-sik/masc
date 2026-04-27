(** Boot-time audit for keeper egress policy file placement.

    Leak 11 (2026-04-27): keeper "executor" had its [egress.json] at the
    host-direct path [playground/<name>/egress.json] while the docker
    keeper code resolved [egress_policy_path] to
    [playground/docker/<name>/egress.json].  The file at the wrong
    location was never read; the lookup fail-closed for 24h+ and every
    URL command surfaced as [egress_blocked, allowed=[]].

    This module does no I/O writes — it inspects the file system and
    classifies each keeper's policy file state.  Callers (boot hook,
    CLI verification, tests) decide whether to log, fail, or repair.

    Status taxonomy ─

    [Ok_present] — expected path exists, no follow-up needed.

    [Missing_at_expected] — expected path is absent and there is no
    drifted copy elsewhere.  Operator should seed the file (egress
    policy is fail-closed without it).

    [Stale_orphan] — expected path is absent but a host-direct copy
    exists.  Indicates the same drift class that produced Leak 11:
    the file was seeded under the wrong sandbox_profile assumption.
    Operator should move (or copy + delete the orphan).

    Local keepers always treat [playground/<name>/] as the canonical
    location, so the [Stale_orphan] class only applies to Docker
    keepers. *)

module Coord = Coord
module Keeper_types = Keeper_types

type audit_status =
  | Ok_present
  | Missing_at_expected of { expected_path : string }
  | Stale_orphan of { expected_path : string; orphan_path : string }

type result = {
  agent_name : string;
  keeper_name : string;
  sandbox_profile : Keeper_types.sandbox_profile;
  status : audit_status;
}

let host_direct_egress_path ~(config : Coord.config)
    ~(meta : Keeper_types.keeper_meta) =
  (* The pre-Leak-11 location used by host (Local) keepers and by the
     external setup script that seeded executor's file at the wrong
     branch.  We compute it explicitly so the audit can detect a
     stale orphan even when the docker-path file is absent. *)
  Filename.concat
    (Filename.concat config.base_path
       (Filename.concat ".masc/playground" meta.name))
    "egress.json"

let audit_one ~(config : Coord.config) ~(meta : Keeper_types.keeper_meta) =
  let expected = Keeper_shell_docker.egress_policy_path ~config ~meta in
  let status =
    match meta.sandbox_profile with
    | Keeper_types.Local ->
        if Sys.file_exists expected then Ok_present
        else Missing_at_expected { expected_path = expected }
    | Keeper_types.Docker ->
        if Sys.file_exists expected then Ok_present
        else
          let orphan = host_direct_egress_path ~config ~meta in
          if Sys.file_exists orphan then
            Stale_orphan { expected_path = expected; orphan_path = orphan }
          else Missing_at_expected { expected_path = expected }
  in
  {
    agent_name = meta.agent_name;
    keeper_name = meta.name;
    sandbox_profile = meta.sandbox_profile;
    status;
  }

let audit_all ~(config : Coord.config) ~(metas : Keeper_types.keeper_meta list)
    =
  List.map (fun meta -> audit_one ~config ~meta) metas

(** A grep-friendly one-line summary; the boot hook emits this so
    operators can locate drifted keepers from the system log without
    reaching for Prometheus. *)
let format_log_line (r : result) =
  let profile = Keeper_types.sandbox_profile_to_string r.sandbox_profile in
  match r.status with
  | Ok_present ->
      Printf.sprintf "[egress_audit:ok] keeper=%s profile=%s" r.keeper_name
        profile
  | Missing_at_expected { expected_path } ->
      Printf.sprintf
        "[egress_audit:missing] keeper=%s profile=%s expected=%s"
        r.keeper_name profile expected_path
  | Stale_orphan { expected_path; orphan_path } ->
      Printf.sprintf
        "[egress_audit:stale_orphan] keeper=%s profile=%s expected=%s \
         orphan_at=%s"
        r.keeper_name profile expected_path orphan_path

(** Partition results by severity.  The boot hook can then route
    [Ok] at debug level and [missing]/[stale] at warn. *)
let partition (results : result list) =
  List.fold_left
    (fun (oks, missings, orphans) r ->
      match r.status with
      | Ok_present -> (r :: oks, missings, orphans)
      | Missing_at_expected _ -> (oks, r :: missings, orphans)
      | Stale_orphan _ -> (oks, missings, r :: orphans))
    ([], [], []) results
