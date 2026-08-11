# task-238 bounded server evidence

Source: `lib/server/server_dashboard_http_keeper_api_post.ml`
Commit: `153a4322ab1daee6f5c92e4eaab10c827de9a5e1`

The dashboard GitHub login POST passes the named positive 600-second timeout to the streaming subprocess boundary and closes the response writer on every exit path.

```ocaml
         Fun.protect
           ~finally:(fun () -> Httpun.Body.Writer.close writer)
           (fun () ->
              match
                Keeper_github_identity.stream_login
                  ~timeout_sec:Keeper_github_identity.interactive_timeout_sec
                  ~base_path:config.base_path
                  ~keeper_name:name
                  ~hostname
                  ~env
                  ~is_closed:(fun () -> Httpun.Body.Writer.is_closed writer)
                  ~send_event:(github_login_stream_send writer)
                  ()
              with
              | Ok () -> ()
              | Error message when not (Httpun.Body.Writer.is_closed writer) ->
                github_login_stream_send
                  writer
                  "error"
                  (`Assoc [ "message", `String message ])
              | Error _ -> ()))
;;
```

This bounded excerpt is copied from the tracked handler at the cited commit.
