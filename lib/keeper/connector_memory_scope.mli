(** Exact account and destination for personal Memory. The caller must first
    prove the author and message through connector ingress. *)

type t = private
  | Discord of
      { account : Connector_account_ref.t
      ; guild_id : string option
      ; channel_id : string
      }

val of_surface : account:Connector_account_ref.t -> Surface_ref.t -> t option
(** Discord's channel ID is the concrete destination, including a thread.
    Display names and cached parent metadata do not change the scope.
    A missing guild stays distinct from any identified guild. *)

val destination_to_json : t -> Yojson.Safe.t
(** The destination coordinates. The question carries account identity
    separately, alongside the actor's observed display name. *)

val to_json : t -> Yojson.Safe.t
(** Canonical account plus destination, for stored Memory. *)

val of_json : Yojson.Safe.t -> (t, string) result
(** Closed decoder for the canonical stored scope. *)
