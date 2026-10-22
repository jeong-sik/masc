(** The Lane Add-on records the deploy preflight ([validate-stores]) reads
    beside {!Keeper_durable_store}, with the decoders the runtime applies to
    them.

    A Lane Add-on record the new build cannot decode is refused by its reader
    long after the deploy: a native claim whose cleanup descriptor no longer
    decodes kept its installation [failed] and refused every new start
    (#45106), and old-shape bindings failed a declaration (#44651). Every one
    is a file the operator moves aside between stopping the old server and
    starting the new build, so the report names each file rather than the
    first, and the fresh-state step for it.

    The scan only lists directories and reads files. It takes no slot gate or
    store lock, syncs nothing, and creates, moves or writes nothing, so it can
    run while the old server is still serving the same workspace. *)

module Store : sig
  type t =
    | Bindings
    | Native_claims
    | Actions
    | Exact_requests
    | Tool_request_owners

  val all : t list
  (** Every constructor in declaration order. *)
end

(** The runtime reader that refused a record. *)
type decoder =
  | Json  (** The file is not JSON. *)
  | Retained_binding  (** {!Lane_addon_runtime.check_retained_binding} *)
  | Inventory_record  (** {!Lane_addon_runtime.check_inventory_record} *)
  | Native_lease  (** {!Native_addon_lease.inspect} *)
  | Cleanup_descriptor  (** {!Browser_addon_socket.check_retained} *)
  | Action_receipt
      (** {!Lane_addon_action.of_json}, and the receipt's own ids against the
          key it is stored under. *)
  | Exact_record  (** {!Lane_addon_exact.check_retained_record} *)
  | Tool_request_inventory  (** {!Lane_addon_store.tool_request_owner_entry} *)
  | Tool_request_owner  (** {!Lane_addon_tool_request_owner.check_published} *)

val decoder_name : decoder -> string

type refusal =
  { path : string
        (** The refused file; the slot directory when the lease refused a
            native claim. *)
  ; decoder : decoder
  ; detail : string  (** The decoder's own message. *)
  ; aside : string list
        (** What the operator moves aside with the server stopped. For a record
            it is that file. For a native claim it is the slot directory, then
            the binding and observations of the instance the slot names, when
            that could be read and they exist; recovering #45106 moved all
            three. *)
  }

type report =
  { rows : int  (** Files (installation slots, for native claims) read. *)
  ; refusals : refusal list  (** In path order. *)
  }

val name : Store.t -> string
(** The name the preflight prints, e.g. ["lane-addon bindings"]. *)

val on_refusal : Store.t -> string
(** What the running server does with a record of this store it cannot
    decode. *)

val fresh_state_step : refusal -> string
(** The step for one refused record: stop the server, move [aside] away, start
    the new build. *)

val scan : Store.t -> base_path:string -> (report, string) result
(** Read every record of the store under [base_path] with this build's
    decoders. A missing store directory is an empty store. [Error] means a
    directory exists and cannot be listed. *)
