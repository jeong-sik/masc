(* HIGH-RISK-UNREVIEWED: these answers make a person's Keeper and give it one
   of their Runtimes in the authorization log. *)

(** The Keeper routes of the localhost preview (plan D1-5): a person makes a
    Keeper, gives it one of their Runtimes, and lists their Keepers. The
    records are those of {!Authz_keeper}; no Keeper TOML is written. The
    preview command judges the request with {!Auth_preview.keeper_owner} and
    hands the person here. A turn of a Keeper made here runs through
    {!turn_path} (plan D2-8), which the server answers.

    A Keeper or a Runtime of another person is answered as one that is not
    there (404), so the answer does not say whose it is. A Keeper name is
    taken for everyone once anyone made it, so that one is a 409.

    A Keeper made here runs its turns under a policy of its owner that allows
    the [autonomous] and [direct] channels; the Runtime it is given and that
    Runtime's Self grant limit the rest. *)

(** [/api/v1/auth/keepers]: [GET] is {!list}, [POST] is {!make}. *)
val keepers_path : string

(** [/api/v1/auth/keepers/assign]: [POST] is {!assign}. *)
val assign_path : string

(** [/api/v1/auth/keepers/turn]: [POST] runs one turn of the person's Keeper
    on the Runtime they gave it ([Server_preview_keeper_turn], plan D2-8). *)
val turn_path : string

(** A Keeper name of the Keeper grammar ({!Keeper_id.Keeper_name}), which is
    also the name of its TOML, as an id of the log. A name that is not both
    gets a 400 JSON [{"error": ...}]. *)
val keeper_id_of : string -> (Authz_types.Keeper_id.t, Login_routes.answer) result

(** A 200 JSON [{"keepers": [{"keeper_id":...,"runtime_id":...}]}]: the
    Keepers the person owns, each with the Runtime of its latest assignment
    or [null]. *)
val list : Authz_state.t -> Authz_types.User_id.t -> Login_routes.answer

(** The body is [{"keeper_id": <name>}], a name of the Keeper grammar
    ({!Keeper_id.Keeper_name}). A 200 JSON
    [{"keeper_id":...,"record":"made"}], or ["existing"] when the person
    made it before; a 409 when another person did. *)
val make : Authz_zone.t -> Authz_types.User_id.t -> body:string -> Login_routes.answer

(** The body is [{"keeper_id": <name>, "runtime_id": <id>}]. A 200 JSON
    [{"keeper_id":...,"runtime_id":...,"record":"assigned"}], or ["existing"]
    when the Keeper already has that Runtime; a 404 when the Keeper or the
    Runtime is not the person's. *)
val assign : Authz_zone.t -> Authz_types.User_id.t -> body:string -> Login_routes.answer
