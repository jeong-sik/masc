let machine_of_request_target target =
  match Uri.get_query_param (Uri.of_string target) "machine" with
  | None -> Ok None
  | Some "msx" -> Ok (Some Machine_lane.Msx)
  | Some "dos" -> Ok (Some Machine_lane.Dos)
  | Some value -> Error ("unknown observer machine: " ^ value)

type step_error =
  | Unavailable of string
  | Outcome_unknown of string
  | Host_refusal of string

let step = ref (fun ~config ~machine ->
  match machine with
  | Machine_lane.Msx ->
      Machine_addon_host.call_shared ~config
        ~principal:Lane_addon_call_context.Operator
        ~name:"masc_msx_step"
        ~arguments:(`Assoc ["frames", `Int 18; "include_frame", `Bool true])
      |> Result.map ignore
      |> Result.map_error (function
        | Lane_addon_runtime.Unavailable detail -> Unavailable detail
        | Lane_addon_runtime.Outcome_unknown detail -> Outcome_unknown detail
        | Lane_addon_runtime.Host_refusal
            (Lane_addon_call_context.Rejected detail | Lane_addon_call_context.Unavailable detail
            | Lane_addon_call_context.Activity_disabled detail
            | Lane_addon_call_context.Activity_unobserved detail) -> Host_refusal detail)
  | Machine_lane.Dos -> Ok ())

let start ~sw ~clock ~stop_promise ~machine ~config =
  Eio.Fiber.fork ~sw (fun () ->
    let rec tick () =
      match !step ~config ~machine with
      | Error (Unavailable detail) ->
          Log.Server.warn "machine spectator worker unavailable; retrying: %s" detail;
          Eio.Time.sleep clock 1.0;
          tick ()
      | Error (Outcome_unknown detail | Host_refusal detail) ->
          Log.Server.warn "machine spectator tick stopped: %s" detail
      | Ok () ->
          Eio.Time.sleep clock 0.3;
          tick ()
    in
    ignore (Eio.Fiber.first
      (fun () -> tick (); `Tick_stopped)
      (fun () -> Eio.Promise.await stop_promise; `Observer_closed)))

module For_testing = struct
  let with_step replacement f =
    let previous = !step in
    step := replacement;
    Fun.protect ~finally:(fun () -> step := previous) f
end
