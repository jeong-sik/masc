(** Where one tool call reaches. RFC open-tool-carries-cohort-and-reach D2.

    The value is a display projection for the turn preview. It grants no
    permission and no approval decision reads it. *)

type t =
  | Masc_state  (** MASC's own stores and other Keepers only. *)
  | Sandbox
      (** The Keeper sandbox's files, or a process or container on the host.
          Whether that process opens a network connection is not known. *)
  | Network  (** An outbound request to the internet or a third-party service. *)
  | Model_provider  (** A call to a model: a fusion panel, vision, a local model runtime. *)

val to_wire : t -> string
(** ["masc_state" | "sandbox" | "network" | "model_provider"]. *)
