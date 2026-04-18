(** Dashboard delete action handlers — board, tasks, goals.

    Extracted from server_routes_http_routes_dashboard.ml.
    Contains POST handler logic for /api/v1/dashboard/board/delete,
    /api/v1/dashboard/tasks/delete, /api/v1/dashboard/goals/delete,
    /api/v1/dashboard/goals/sweep. *)

module Http = Http_server_eio

open Server_auth

let add_delete_action_routes router =
  router
  |> Http.Router.post "/api/v1/dashboard/board/delete" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         (fun _state _agent_name req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "post_id" json with
             | None ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"post_id\":\"...\"}"}|} reqd
             | Some post_id ->
             match Board_dispatch.delete_post ~post_id with
             | Ok () ->
                 Http.Response.json ~compress:true ~request:req
                   {|{"ok":true}|} reqd
             | Error _ ->
                 Http.Response.json ~status:`Not_found ~request:req
                   {|{"ok":false,"error":"post not found or delete failed"}|} reqd
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"post_id\":\"...\"}"}|} reqd
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/dashboard/tasks/delete" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         (fun state _agent_name req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "task_id" json with
             | None ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"task_id\":\"...\"}"}|} reqd
             | Some task_id ->
             let config = state.Mcp_server.room_config in
             match Task_dispatch.delete_task config ~task_id with
             | Ok () ->
                 Http.Response.json ~compress:true ~request:req
                   {|{"ok":true}|} reqd
             | Error _ ->
                 Http.Response.json ~status:`Not_found ~request:req
                   {|{"ok":false,"error":"task not found or delete failed"}|} reqd
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"task_id\":\"...\"}"}|} reqd
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/dashboard/goals/delete" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         (fun state _agent_name req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "goal_id" json with
             | None ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"goal_id\":\"...\"}"}|} reqd
             | Some goal_id ->
             let config = state.Mcp_server.room_config in
             match Goal_store.delete_goal config ~goal_id with
             | Ok () ->
                 Http.Response.json ~compress:true ~request:req
                   {|{"ok":true}|} reqd
             | Error msg ->
                 Http.Response.json ~status:`Not_found ~request:req
                   (Printf.sprintf {|{"ok":false,"error":"%s"}|} (String.escaped msg))
                   reqd
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"goal_id\":\"...\"}"}|} reqd
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/dashboard/goals/sweep" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         (fun state _agent_name _req reqd ->
         let config = state.Mcp_server.room_config in
         let result = Goal_janitor.run config in
         Http.Response.json ~compress:true ~request
           (Yojson.Safe.to_string
              (`Assoc [("ok", `Bool true);
                       ("result", Goal_janitor.sweep_result_to_yojson result)]))
           reqd
       ) request reqd)
