open Keeper_types

(* Invariant (root-fix family 2/3, 2026-04-28; local-overrotation fix,
   2026-05-18): the declared sandbox profile is the execution contract.
   Docker keepers must never silently fall back to Local, and Local keepers
   must never silently upgrade to Docker.  DockerPlayground is a runtime
   capability switch, not permission to reinterpret sandbox_profile=local. *)
let effective_sandbox_profile ~(meta : keeper_meta) ~in_playground =
  match meta.sandbox_profile with
  | Docker ->
    (* Invariant: meta=Docker → effective=Docker. No silent host fallback. *)
    Docker, meta.network_mode
  | Local ->
    let _ = in_playground in
    Local, meta.network_mode
;;

let optional_ro_mount ~host ~container =
  if host = ""
  then []
  else if not (Sys.file_exists host)
  then []
  else [ "-v"; host ^ ":" ^ container ^ ":ro" ]
;;
