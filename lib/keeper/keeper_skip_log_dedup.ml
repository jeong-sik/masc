(* Per-keeper skip-log deduplication.  See [.mli] for design rationale. *)

let last_emitted : (string, string * float) Hashtbl.t = Hashtbl.create 32

let mu = Eio.Mutex.create ()

let should_emit ~keeper_name ~reasons ~now ~ttl_sec =
  if ttl_sec <= 0.0 then true
  else
    let key = String.concat "," (List.sort compare reasons) in
    Eio.Mutex.use_rw ~protect:false mu (fun () ->
      match Hashtbl.find_opt last_emitted keeper_name with
      | Some (prev_key, prev_ts)
        when String.equal prev_key key && now -. prev_ts < ttl_sec ->
          false
      | _ ->
          Hashtbl.replace last_emitted keeper_name (key, now);
          true)
