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

val pass_target :
  parse:(string -> (string, string) result) -> Yojson.Safe.t -> (string option, string) result
(** The recipient a [masc_dos_pass] call names, read from its [to] argument
    and checked by [parse], which gets the trimmed text and returns the name.
    [None] is a call that frees the controller, and only a [to] that is left
    out or null means that: an empty, blank or non-string [to] is an [Error]. *)

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

(** What a call leaves behind in the worker. *)
type call_effect =
  | Reads_only
      (** changes nothing the worker holds, so the worker's last observation
          still shows the machine after the call *)
  | Changes_state
      (** moves the machine, hands its controller or writes a checkpoint. A
          save leaves the machine where it was, but it writes a file and adds
          a line to the activity feed the observation carries. *)

val call_effect : dos_tool -> call_effect
(** The DOS worker derives both its MCP [annotations.readOnlyHint] and the
    observation effect it declares to the host from this one value. *)

(** {1 Screen errors}

    Why a [masc_dos_screen] call answered with an error. The worker writes it
    into the failed result's [_meta]; host routes read it from there instead
    of matching the text. *)

type screen_error =
  | Screen_no_machine  (** no DOS program is loaded *)
  | Screen_capture_failed  (** the machine is there but its frame could not be read *)
  | Screen_encode_failed  (** the frame was read but could not be encoded *)

val screen_error_meta_field : screen_error -> string * Yojson.Safe.t
(** The [_meta] field the worker adds to a failed screen result. *)

val screen_error_of_meta : Yojson.Safe.t option -> screen_error option
(** The error a failed screen result's [_meta] names. [None] when the field is
    missing, is not a string, or names no {!screen_error}. *)
