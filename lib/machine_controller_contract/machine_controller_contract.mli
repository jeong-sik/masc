(** Host-authorized reasons for releasing a machine controller. The worker
    does not inspect Keeper registries or credential stores. *)
type holder_departure =
  | Keeper_stopped
  | Credential_expired
  | No_credential
  | Participant_departed

type admission = {
  observed_holder : string option;
  release : holder_departure option;
  handoff_target : string option;
}
(** Issued by the owning host under its credential transaction. The worker
    compares [observed_holder] before applying [release]. For handoff calls,
    [handoff_target] must equal the parsed recipient (including [None]). *)
val snapshot_tool : string
val release_tool : string
val admission_to_json : admission -> Yojson.Safe.t
val admission_of_json : Yojson.Safe.t -> (admission, string) result
val admission_schema : Yojson.Safe.t

(** {1 DOS tools}

    The shared DOS machine's tools, named once for the host that admits a
    call and the worker that runs it (RFC play-link-for-the-shared-machine
    §2.8). *)

type dos_tool =
  | Dos_load
  | Dos_eject
  | Dos_pass
  | Dos_meta
  | Dos_inventory
  | Dos_screen
  | Dos_step
  | Dos_press
  | Dos_click
  | Dos_type
  | Dos_peek
  | Dos_save
  | Dos_restore

val all_of_dos_tool : dos_tool list
(** Every tool, in the order the worker exports them. *)

val dos_tool_name : dos_tool -> string
(** The MCP tool name, ["masc_dos_load"] and so on. *)

val dos_tool_of_name : string -> dos_tool option
(** The tool whose {!dos_tool_name} is the string; [None] for any other. *)

(** What a call does with the machine's controller. *)
type controller_need =
  | Takes_controller  (** moves the machine, so it needs the controller *)
  | Hands_controller  (** [masc_dos_pass]: gives the controller to someone *)
  | No_controller  (** reads or saves the machine *)

val controller_need : dos_tool -> controller_need
