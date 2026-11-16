(* Explicit deterministic effect ports. The replay supplies actual source bodies. *)
module Workspace = struct
 type config={base_path:string;workspace_path:string}
 let masc_dir config=config.base_path^"/.masc"
end
module Ports = struct
 let trace=ref []
 let note label=trace:=label:: !trace
 let scenario=ref 0
 let state_present=ref true
 let ledger_calls=ref 0
 let refuse_ledger=ref false
 exception Forbidden_ledger_access
 let marker label=`Assoc["source",`String label]
 let paused_details=`List[`Assoc["name",`String "held";"activation_mode",`String "autonomous";
   "pause_kind",`String "operator_paused";"elapsed_seconds",`Int 12;"root_cause",`String "operator"]]
 type phase_counts={running:int}
 type phase_snapshot={counts:phase_counts}
 type paused_scan={details:Yojson.Safe.t}
 type fleet_scan={paused_scan:paused_scan;bootable_names:string list;autoboot_scan:string list}
 let runtime_base_path_opt ()=if !state_present then Some "/fixture/base" else None
 let keeper_phase_snapshot ?base_path:_ ()=note "phase";{counts={running=2}}
 let current_server_state_opt ()=if !state_present then Some () else None
 module Mcp_server=struct
   let workspace_config ()={Workspace.base_path="/fixture/base";workspace_path="/fixture/workspace"}
 end
 let read_keeper_metas _=note "metas";()
 let keeper_fleet_meta_scan ?(include_paused_details=true) ()=
   note(if include_paused_details then "meta_scan/full" else "meta_scan/light");
   {paused_scan={details=if include_paused_details then paused_details else `List[]};
    bootable_names=["valid";"invalid-profile"];autoboot_scan=["valid"]}
 let boot_path_bootable_names ()=note "boot_path";["valid"]
 let keeper_execution_snapshot ()=note "execution";()
 let empty_keeper_execution_snapshot=()
 let empty_paused_keeper_scan={details=`List[]}
 let empty_autoboot_keeper_scan=[]
 let registry_paused_keeper_names ()=["held"]
 let paused_keepers_health_json_of_scan ~registry_paused_names:_ scan=
   `Assoc["count",`Int 1;"details",scan.details]
 let paused_keeper_count json=Yojson.Safe.Util.(json |>member "count" |>to_int)
 let keeper_fleet_safety_health_json ~meta_reading:_ ~bootable_names ~autoboot_scan:_
   ~phase_snapshot:_ ~execution_snapshot:_ ?base_path:_ ~phase_counts:_ ~paused_keepers_json:_ ()=
   marker(if !scenario=4 then "unread-census" else String.concat "," bootable_names)
 module Keeper_disk_pressure=struct let snapshot_json ~masc_root:_ ()=marker "disk" end
 module Common=struct let masc_dir_from_base_path ~base_path=base_path^"/.masc" end
 module Keeper_fd_pressure=struct let runtime_state_json ~active_keepers:_ ()=marker "fd" end
 let keeper_owner_health_json ()=marker "owner"
 let keeper_board_event_collection_health_json ()=marker "board"
 let keeper_reaction_ledger_health_json ~execution_snapshot:_ ()=
   incr ledger_calls;note "ledger";
   if !refuse_ledger then raise Forbidden_ledger_access;
   `Assoc["status",`String(if !scenario=4 then "unavailable" else "degraded");
     "pending_stimulus_count",`Int !scenario;"quarantined_row_count",`Int 1;
     "read_error_count",`Int(if !scenario=4 then 1 else 0)]
 let fd_accountant_snapshot_json ()=note "fd_accountant";marker "fd_accountant"
end
open Ports
module Build_identity=struct
 type t={binary_commit:string option;repo_head_commit:string option}
 let current ()=note "build";{binary_commit=(if !scenario=2 then None else Some "binary");repo_head_commit=Some "binary"}
 let repo_root ()=Some "/fixture/repo"
 let to_yojson _=marker "build"
end
type git_upstream_status={branch:string option;upstream_ref:string option;
 upstream_head_commit:string option;behind_count:int option}
let empty_git_upstream_status={branch=None;upstream_ref=None;upstream_head_commit=None;behind_count=None}
let git_rev_parse_short path=note("git:"^path);Some(if !scenario=1 then "changed" else "binary")
let git_upstream_status _=Some{branch=Some "fixture";upstream_ref=Some "origin/main";
 upstream_head_commit=Some "upstream";behind_count=Some(if !scenario=1 then 2 else 0)}
module Env_config_core=struct let base_path_source_opt ()=Some("fixture","/fixture/input") end
module Prompt_registry=struct let get_markdown_dir ()=Some "/fixture/base/prompts" end
module Config_dir_resolver=struct
 let prompts_dir_for_base_path ~base_path=base_path^"/prompts"
 let resolve ()=()
 let to_json ()=marker "config"
end
module Server_dashboard_http_runtime_info_json=struct let commit_equal=String.equal end
let normalized_path_opt path=Some path
let server_workspace_mismatch ~server_repo_path:_ _= !scenario=1
let runtime_diagnostics_json ()=note "diagnostics";`List[marker "diagnostic"],(if !scenario=1 then 1 else 0),0
let path_item_json ~source path=`Assoc["path",`String path;"source",`String source;"exists",`Bool true]
module Keeper_runtime_resolved=struct let current ()=() let to_yojson ()=marker "keeper_runtime" end
let deployment_state_json ~build:_ ~server_repo_commit:_ ~upstream_status:_ ~source_mismatch=
 `Assoc["status",`String(if source_mismatch then "different" else "current")]
let gate_hitl_json ()=marker "gate"
module Tool_misc=struct
 type context={config:Workspace.config;agent_name:string;help_schemas:string list}
 let tool_inventory_json _ ~include_hidden:_=marker "inventory"
end
module Config=struct let raw_all_tool_schemas=[] end
module Server_timing=struct
 type t=unit
 type phase=Projection_config_resolution|Projection_runtime_resolution|Tools_compute|Cache_lookup
 let measure () _ f=f ()
end
open Server_timing
module Pool_work=struct let cpu ~name:_ f=f let submit f=f () end
module Tool_unified=struct let summary_report ~public_names:_ ()=marker "usage" end
module Keeper_tool_descriptor_resolution=struct let public_names_for_internal _=[] end
module Tool_usage_log=struct let source_metadata_json ~masc_root:_=marker "log" end
module Masc_domain=struct let now_iso ()="2000-01-01T00:00:00Z" end
module Server_keeper_waiting_inventory=struct let dashboard_json _=marker "waiting" end
module Keeper_effective_tool_surface=struct
 let resolve ~config:_ ~keeper_name=`String keeper_name
 let to_yojson json=json
end
module Keeper_volume_gc_periodic=struct let envelope_field="sandbox_volume_gc_report" end
module Server_sandbox_volume_gc_report=struct let envelope_json ~base_path:_ ()=marker "volume" end
module Keeper_cleanup_status_json=struct let envelope_field="keeper_cleanup" end
module Server_keeper_build_maintenance=struct let envelope_json ()=marker "cleanup" end
module Dashboard_projection_read=struct type t=Current|Reuse end
module Dashboard_snapshot=struct type tools_result=Tools_ready of Yojson.Safe.t|Tools_pending of Yojson.Safe.t|Tools_error of Yojson.Safe.t end
module Dashboard_cache=struct
 type origin=Seeded|Computed|Timeout
 type payload={origin:origin;json:Yojson.Safe.t}
 let mode=ref Computed
 let invalidate _=()
 let seed_stale_if_missing _ ~stale_for:_ _=()
 let get_or_compute_payload _ ~ttl:_ compute=
   match !mode with
   | Computed->{origin=Computed;json=Pool_work.submit compute}
   | Seeded->{origin=Seeded;json=`Assoc["status",`String "warming"]}
   | Timeout->{origin=Timeout;json=`Assoc["error",`String "fixture-cache-failure"]}
end
