(** Authorized sandbox preparation. Bind workspace and native executable at the
    composition root; request JSON accepts only backend/network and manifest revision. *)
type error = Invalid_request | Configuration_unavailable | Configuration_changed
  | Lifecycle_busy | Existing_keeper | Prerequisite_required | Image_failed | Custom_image_required | Commit_unconfirmed
val error_message : error -> string
val inspect : base_path:string -> Yojson.Safe.t
val prepare : binary:string -> base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t,error) result
(** Image acquisition occurs before the final lifecycle guard and manifest CAS.
    Live or transitioning registry entries cannot have their selection changed. No Keeper is
    restarted, no model is verified and no guest execution is claimed here. *)
module For_testing : sig
  val revision : string -> string -> string
  val prepare : base_path:string -> run:Sandbox_readiness.runner ->
    image:(Sandbox_readiness.backend -> image:string -> (unit,error) result) ->
    Yojson.Safe.t -> (Yojson.Safe.t,error) result
end
