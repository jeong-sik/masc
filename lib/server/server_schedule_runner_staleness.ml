(* The status turns once [now -. finished > stale_after_sec]; waking this much
   after the deadline reads it turned. *)
let past_deadline_sec = 0.05

let watch ~clock ~stale_after_sec ~finished_at ~on_deadline =
  let rec loop announced =
    match finished_at () with
    | None ->
      Eio.Time.sleep clock stale_after_sec;
      loop announced
    | Some finished ->
      let wait = finished +. stale_after_sec -. Eio.Time.now clock in
      if wait >= 0.0 then (
        Eio.Time.sleep clock (wait +. past_deadline_sec);
        loop announced)
      else if Option.equal Float.equal announced (Some finished) then (
        Eio.Time.sleep clock stale_after_sec;
        loop announced)
      else (
        on_deadline ();
        loop (Some finished))
  in
  loop None
;;
