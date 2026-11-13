(** A registered tool, as the inventory lists it. *)
type tool_entry = {
  tl_name : string;
  tl_description : string;
  tl_surfaces : string list;
      (** Where the tool is visible: the MCP surface, keeper projections, and
          so on. Empty means registered and projected nowhere. *)
  tl_direct_call : bool;
}

type inventory_freshness =
  | Warming
      (** The server answered with its warming placeholder: it has not built
          the inventory yet, so the empty list beside this is not an answer
          about how many tools exist. *)
  | Settled
      (** The server answered from a built inventory. An empty list here does
          mean no tools. *)

(** Where one tool on the keeper's effective surface came from, as
    [origin.kind] names it. Only a composition skill carries
    [origin.skill_provenance], and it always carries the key: [skill_source_id]
    is read from [skill_provenance.identity.source_id], and is [None] when the
    producer sent [null] because it could not resolve the provenance. *)
type effective_tool_origin =
  | Descriptor_origin
  | Instruction_skill_origin
  | Composition_skill_origin of { skill_source_id : string option }
  | Composition_control_origin
  | Unrecognised_origin of string
      (** A kind this build does not know, kept as the server spelled it so
          the Tools column still draws it and the rest of the surface still
          loads. Its provenance is not read. *)

val effective_tool_origin_kind : effective_tool_origin -> string
(** The [origin.kind] word the server sent. *)

type effective_tool = {
  et_name : string;
  et_origin : effective_tool_origin;
}

type effective_tool_delivery =
  | Effective_tools_delivered
  | Effective_tools_suppressed_runtime_unsupported

type skill_flow_dependency = {
  sfd_node_id : string;
  sfd_kind : string;
}

type skill_flow_node = {
  sfn_id : string;
  sfn_tool_name : string;
  sfn_dependencies : skill_flow_dependency list;
  sfn_batch_index : int;
  sfn_execution_mode : string;
}

type skill_flow_batch = {
  sfb_index : int;
  sfb_execution_mode : string;
  sfb_node_ids : string list;
}

type skill_flow = {
  sf_nodes : skill_flow_node list;
  sf_batches : skill_flow_batch list;
}

type skills_catalog_surface = {
  scs_reference : Skill_reference.t;
  scs_kind : string;
  scs_flow : skill_flow option;
}

(** One catalog surface one Keeper used, from
    [GET /api/v1/keepers/skill-usage?keeper=]. *)
type keeper_skill_usage_row = {
  ksu_reference : Skill_reference.t;
  ksu_invocations : int;
  ksu_deliveries : int;
  ksu_actions : int;
  ksu_last_used_at : string;
}

(** One Keeper's usage of the catalog, read from its current ledger. *)
type keeper_skill_usage =
  | Keeper_usage_ready of keeper_skill_usage_row list
  | Keeper_usage_no_session  (** No current session, so nothing recorded. *)
  | Keeper_usage_unavailable of { kua_reason : string; kua_detail : string }
      (** Its metadata or its ledger could not be read. *)
  | Keeper_usage_no_catalog
      (** The ledger was read but there is no ready catalog to count it
          against. *)

type skill_rejection_diagnostic = {
  srd_diagnostic : Agent_core.Skill_document.diagnostic;
  srd_message : string;
}

type skill_rejection_reason =
  | Skill_document_rejected of skill_rejection_diagnostic list
  | Skill_document_unreadable
  | Skill_exact_identity_duplicate
  | Skill_invalid_package_id

type skill_catalog_rejection = {
  scr_source_index : int;
  scr_source_id : string;
  scr_package_id : string option;
  scr_content_revision : string option;
  scr_reason : skill_rejection_reason;
}

(** Where a configured Skill source stood when the catalog was built.

    A source that is not [Skill_source_ready] contributes nothing, which is
    the fact an operator asking "why is my Skill not loaded" needs first and
    the one the screen could not answer: the catalog surfaces name skills,
    never the roots they were looked for under. *)
type skill_source_observation =
  | Skill_source_ready of int
      (** Candidate directories under the source root. Each is one Skill:
          the scan is one level deep and reads that directory's SKILL.md. *)
  | Skill_source_missing
  | Skill_source_not_directory of string  (** The file kind found instead. *)
  | Skill_source_unavailable of string  (** The operation that failed. *)
  | Skill_source_unresolved
      (** The configured anchor or path was refused, so no root was tried. *)

type skill_catalog_source = {
  scso_id : string;
  scso_anchor : string;
  scso_path : string option;
      (** Configured path under the anchor. [None] for an absolute source,
          whose location the server deliberately does not publish. *)
  scso_access : string;
  scso_observation : skill_source_observation;
}
(** One entry of the ordered discovery list, in the order it is consulted.
    Earlier sources win, so the order is what decides which copy of a name
    is effective. *)

(** The [runtime.toml] Skill section as the catalog read it. *)
type skill_catalog_config =
  | Skill_config_configured of
      { revision : string
      ; resource_read_max_bytes : int option
      }
  | Skill_config_rejected of
      { source_revision : string
      ; diagnostics : string list
      }
      (** The section did not parse. The catalog still stands, on whatever
          the defaults give, and nothing on screen used to say so. *)
  | Skill_config_unreadable

type skills_catalog_state =
  | Skills_ready
  | Skills_not_registered
  | Skills_uninitialized
  | Skills_invalid_workspace

(** One Skill name two catalog entries declare. The first entry for the name
    in catalog order wins (Skill_catalog_snapshot.effective_projection):
    [scsh_winner]. The two can sit in different sources, or in one source
    whose directory names normalize to the same Skill name. A Keeper turn that
    lists Skills by name gets the winner, when the winner loads;
    [scsh_shadowed] is published but reaches a turn only when a Task names its
    exact reference. Both carry the same name and differ in identity. *)
type skill_catalog_shadow = {
  scsh_winner : Skill_reference.identity;
  scsh_shadowed : Skill_reference.identity;
}

type skills_catalog = {
  sc_state : skills_catalog_state;
  sc_config : skill_catalog_config option;
      (** [None] for every state but [Skills_ready], which is the only one
          that carries a snapshot. *)
  sc_sources : skill_catalog_source list;
  sc_surfaces : skills_catalog_surface list;
  sc_rejections : skill_catalog_rejection list;
  sc_shadows : skill_catalog_shadow list;
}

val skills_catalog_state_to_string : skills_catalog_state -> string
val skill_diagnostic_code_to_string :
  Agent_core.Skill_document.diagnostic -> string

type effective_skill_load_reason =
  | Skill_catalog_default
  | Skill_keeper_profile
  | Skill_task of string

type skill_output_route = { sor_name : string; sor_node_id : string; sor_pointer : string }
type skill_io =
  | Model_orchestrated
  | Composition_io of { input_schema : Yojson.Safe.t; exports : skill_output_route list }

type effective_skill_profile = {
  esp_reference : Skill_reference.t;
  esp_name : string;
  esp_kind : string;
  esp_execution : string;
  esp_body_bytes : int;
  esp_discovery_bytes : int;
  esp_load_reasons : effective_skill_load_reason list;
  esp_node_count : int;
  esp_batch_count : int;
  esp_max_parallelism : int;
  esp_flow : skill_flow option;
  esp_io : skill_io;
}

type configured_skill_name_unavailable = {
  csn_name : string;
  csn_reason : string;
}
(** A Skill name the Keeper profile selected that the turn's catalog does not
    hold. Not a read failure, so it is a different fact from
    [ets_skills_left_out]. [csn_reason] is the producer's word for why. *)

type effective_tool_surface =
  | Effective_surface_available of {
      ets_keeper_name : string;
      ets_runtime_id : string;
      ets_official_client_kind : string;
      ets_tool_delivery : effective_tool_delivery;
      ets_native_posture : string option;
      ets_skill_snapshot_revision : string;
      ets_skill_resource_read_max_bytes : int option;
      (* Documents the catalog could not read. Beside the skills rather than
         missing from them: a skill left out is absent from what the Keeper
         can call, and absence with no reason reads as a skill nobody
         wrote. *)
      ets_skills_left_out : string list;
      (* Names the profile selected and the turn catalog does not carry. The
         dashboard draws these under "Unavailable Skills"; the TUI reads the
         same list so both renderers of this surface say it. *)
      ets_unavailable_skill_names : configured_skill_name_unavailable list;
      ets_skill_profiles : effective_skill_profile list;
      ets_tool_surface_bytes : int option;
      ets_skill_tool_surface_bytes : int option;
      ets_skill_discovery_bytes : int;
      ets_skill_body_bytes : int option;
      ets_tools : effective_tool list;
      ets_tool_surface_sha256 : string option;
    }
  | Effective_surface_unavailable of {
      ets_keeper_name : string;
      ets_reason : string;
      ets_detail : string;
    }

type skill_activation_projection =
  | Skill_activations_available of {
      sap_keeper_name : string;
      sap_ledger : Keeper_skill_activation_ledger.t;
    }
  | Skill_activations_no_session of { sap_keeper_name : string }
  | Skill_activations_unavailable of {
      sap_keeper_name : string;
      sap_reason : string;
      sap_detail : string;
    }

(** What the server counted about one tool's calls, from
    [tool_usage.by_tool]. The counts cover the retained snapshot and the
    current process. *)
type tool_usage_row = {
  tu_name : string;
      (** The internal name the calls were counted under. *)
  tu_public_names : string list;
      (** The names a model sees this tool under, when it has any: [tool_execute]
          lists [Execute]. *)
  tu_calls : int;
  tu_failures : int;
  tu_p95_ms : float option;
      (** [None] when the server sent no 95th percentile for this tool. *)
}

type host_disk = {
  hd_mounted_on : string;
  hd_total_bytes : int;
  hd_available_bytes : int;
}

(** The server's own measurement of the filesystem that holds its state. *)
type host_disk_reading =
  | Host_disk_absent
      (** The envelope carried no measurement: the warming placeholder, or a
          server with no workspace to measure. *)
  | Host_disk_probe_failed of string
      (** The server's probe failed, in its words. *)
  | Host_disk_unreadable of string
      (** The envelope carried a measurement this build cannot read, and why. *)
  | Host_disk_measured of host_disk

(** What the server's storage cleanup last did. *)
type keeper_cleanup_reading =
  | Keeper_cleanup_absent  (** A server that publishes no such field. *)
  | Keeper_cleanup_unreadable of string
      (** The field could not be taken apart, and why. *)
  | Keeper_cleanup_read of Keeper_cleanup_status_json.reading
      (** Read part by part: the summary or a row this build cannot read is
          kept inside the reading as its reason. *)

type storage = {
  st_host_disk : host_disk_reading;
  st_keeper_cleanup : keeper_cleanup_reading;
}

type tool_snapshot = {
  ts_tools : tool_entry list;
  ts_count : int;
  ts_freshness : inventory_freshness;
      (** Whether the count above is an answer. *)
  ts_effective : effective_tool_surface option;
  ts_usage : tool_usage_row list option;
      (** One row per tool called at least once. [None] when the envelope
          carried no per-tool counts: the warming placeholder has totals and no
          [by_tool]. A tool with no row in a [Some] reading was not called,
          which is a different answer. *)
  ts_volume_gc_report : Keeper_volume_gc_periodic.t option;
      (** The server's last periodic [masc_sandbox_volume_gc] report. [None]
          until the server's first pass ends, and from a server that runs
          no pass. *)
  ts_storage : storage;
      (** The host disk and the cleanup results. Neither can fail the
          snapshot: what could not be read is a value of its own. *)
}

val decode_tool_snapshot : Yojson.Safe.t -> (tool_snapshot, string) result
(** Reads [tool_inventory], [tool_usage.by_tool],
    [sandbox_volume_gc_report], [runtime_resolution.disk_observation] and
    [keeper_cleanup] out of the /dashboard/tools envelope. The last two are
    read apart from the rest: a server that sends them in a shape this build
    cannot read still gives its tool inventory. *)

val tool_usage_for : tool_usage_row list -> name:string -> tool_usage_row option
(** The row for the tool the catalog lists as [name]. The server counts under
    the internal name, and the catalog lists public names as entries of their
    own, so [Read] has no row named [Read]: it is the row of [tool_read_file],
    which lists [Read] among its public names. A row named [name] comes first:
    when calls were counted under the public spelling itself, that row and
    the internal tool's row both fit [Execute], and the entry [Execute] reports
    the calls made as [Execute]. *)

val skill_activation_keeper : skill_activation_projection -> string
(** The Keeper a projection is for. *)

val decode_keeper_skill_activations :
  keeper:string -> Yojson.Safe.t -> (skill_activation_projection, string) result
(** Reads the [GET /api/v1/keepers/skill-activations?keeper=] answer for
    [keeper]: schema [masc.keeper-skill-activations/v1], the Keeper it
    answers for, and its projection. An answer for another Keeper is an
    error. *)

val decode_skills_catalog : Yojson.Safe.t -> (skills_catalog, string) result
(** Reads the /api/v1/skills snapshot: its surfaces and their flows. *)

val decode_keeper_skill_usage :
  keeper:string -> Yojson.Safe.t -> (keeper_skill_usage, string) result
(** Reads the [GET /api/v1/keepers/skill-usage?keeper=] answer for
    [keeper]. An answer for another Keeper is an error. *)

val skill_flow_mermaid : skill_flow -> (string, string) result
(** Pure declared topology for Pele. Diagram-local identifiers are generated;
    original node ids and tool names appear only in escaped labels. Dangling
    dependencies and duplicate node identities are refused. This graph carries
    no execution, replay or effect authority. *)
