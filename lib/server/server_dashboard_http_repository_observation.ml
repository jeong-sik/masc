(** Server_dashboard_http_repository_observation — repository observation snapshot endpoint *)

open Dashboard_http_helpers
open Server_utils

let handle_repository_observation_snapshot ~sw ~clock request reqd =
  with_public_read (fun state req inner_reqd ->
    let open Yojson in
    let open Json in
    let repos = state.repos in
    let repo_list =
      repos
      |> List.map (fun r ->
           `Assoc [
             ("name", `String r.name);
             ("path", `String r.path);
             ("branch", `String r.branch);
             ("head_commit", `String r.head_commit);
             ("last_synced", `Float r.last_synced);
           ])
    in
    let snapshot =
      `Assoc [
        ("ok", `Bool true);
        ("timestamp", `Float (Clock.now sw));
        ("repository_count", `Int (List.length repo_list));
        ("repositories", `List repo_list);
      ]
    in
    Http.Response.json ~compress:true snapshot inner_reqd)
    ~request reqd