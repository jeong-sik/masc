(** Tripwire guardrails: fail-fast parallel validators.

    Uses [Eio.Fiber.first] for cancel-on-first-completion semantics.
    When the tripwire fiber finishes (violation found), the action fiber
    is cancelled. When the action finishes first, tripwires are cancelled.

    @since 0.102.0 *)

type tripwire =
  { name : string
  ; check : Types.message list -> (unit, string) result
  }

type tripwire_result =
  | All_clear
  | Tripped of
      { tripwire_name : string
      ; reason : string
      }

(** Run all tripwire checks. Returns as soon as any check fails (Error).
    If all pass, blocks forever (Promise.await) so the action fiber can win.
    Runs inside Fiber.first — the losing fiber gets cancelled. *)
let check_tripwires ~messages tripwires =
  let violation = ref None in
  (* Run all checks in a switch — first failure wins *)
  let found_violation =
    try
      Eio.Switch.run
      @@ fun sw ->
      List.iter
        (fun (tw : tripwire) ->
           Eio.Fiber.fork ~sw (fun () ->
             match tw.check messages with
             | Ok () -> ()
             | Error reason ->
               violation := Some (tw.name, reason);
               (* Cancel the switch to stop other checks *)
               raise Exit))
        tripwires;
      (* If we reach here, all checks passed *)
      false
    with
    | Exit -> true
    | Eio.Cancel.Cancelled _ -> false
  in
  match found_violation, !violation with
  | true, Some (name, reason) -> Tripped { tripwire_name = name; reason }
  | _ -> All_clear
;;

let guarded_action ~tripwires ~messages ~action =
  if tripwires = []
  then (
    match action () with
    | Ok v -> Ok v
    | Error e -> Error (`Action e))
  else (
    let action_result = ref None in
    let trip_result = ref All_clear in
    Eio.Fiber.first
      (fun () ->
         (* Action fiber *)
         action_result := Some (action ()))
      (fun () ->
         (* Tripwire fiber *)
         let tw_result = check_tripwires ~messages tripwires in
         match tw_result with
         | All_clear ->
           (* All passed — block forever so action fiber wins.
             Fiber.first will cancel this when action completes. *)
           let p, _ = Eio.Promise.create () in
           Eio.Promise.await p
         | Tripped _ ->
           (* Violation — return normally, Fiber.first cancels action *)
           trip_result := tw_result);
    match !trip_result with
    | Tripped _ as t -> Error (`Tripped t)
    | All_clear ->
      (match !action_result with
       | Some (Ok v) -> Ok v
       | Some (Error e) -> Error (`Action e)
       | None -> Error (`Action (Error.Internal "action cancelled without tripwire"))))
;;
