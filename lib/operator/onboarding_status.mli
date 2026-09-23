(** Read-only first-run observations, shared by the CLI and operator HTTP UI.
    Declaration, verification and execution are separate facts. Inspecting this
    document never starts a model, creates a workspace, or changes configuration. *)
type action = Choose_workspace | Initialize_workspace | Configure_models
  | Configure_sandbox | Start_imp | Inspect_configuration

type condition = Satisfied | Needs_setup | Needs_verification | Invalid

type check_id =
  | Workspace
  | Runtime_configuration
  | Model_connection
  | Keeper_declaration
  | Sandbox
  | Keeper_persistence
  | Browser_lane

(** Whether an [Invalid] check keeps the workspace's existing history from opening.
    [Required_to_open]: the workspace, a loadable runtime.toml and Keeper
    metadata the boot admits. [Advisory] checks — imp's model binding,
    declaration and sandbox, and the browser lane — are reported but never
    send the operator back into setup. *)
type role = Required_to_open | Advisory

(** What a bare [masc] does with this observation: open the workspace's
    persisted Keeper history, or walk the setup journey. *)
type opening = Open_existing_history | Needs_journey

type check =
  { id : check_id
  ; condition : condition
  ; message : string
  ; actions : action list
  }

type t =
  { base_path : string option
  ; checks : check list
  ; selected_runtime : string option
  ; selected_model : string option
  }

(** [keeper_persistence] is Satisfied when the workspace holds Keeper
    metadata, whichever Keepers they are, and every file passes the check the
    server's boot reconcile applies. No metadata is Needs_setup; any file that
    fails it is Invalid, because the server refuses to boot on it. Persistence
    does not establish model, sandbox or running health. *)
val inspect : base_path:string option -> t

(** The wire name of a check, as serialized in [id]. *)
val check_id_name : check_id -> string

val role : check_id -> role

(** [Open_existing_history] needs [workspace], [runtime_configuration] and
    [keeper_persistence] Satisfied, and no [Required_to_open] check Invalid. It is a statement about readable
    history, never about a running Keeper, model or sandbox. *)
val opening : t -> opening
val to_json : t -> Yojson.Safe.t
val to_text : t -> string
