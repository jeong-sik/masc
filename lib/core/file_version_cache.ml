(* See .mli. *)

type version =
  { device : int
  ; inode : int
  ; size : int
  ; mtime : float
  }

let version_of_stats stats =
  { device = stats.Unix.st_dev
  ; inode = stats.Unix.st_ino
  ; size = stats.Unix.st_size
  ; mtime = stats.Unix.st_mtime
  }
;;

let version_of_path path =
  match Unix.stat path with
  | stats -> Some (version_of_stats stats)
  | exception Unix.Unix_error _ -> None
;;

let same_version left right =
  left.device = right.device
  && left.inode = right.inode
  && left.size = right.size
  && Float.equal left.mtime right.mtime
;;

type 'a slot =
  { version : version option
  ; mutable value : 'a option
  ; mutable readers : int
  }

type 'a t =
  { slots : (string, 'a slot) Hashtbl.t
  ; mutex : Mutex.t
  }

let create () = { slots = Hashtbl.create 1; mutex = Mutex.create () }

type 'a lookup =
  | Kept of 'a
  | Decode of 'a slot

type 'a completion =
  | Publish of 'a
  | Leave_unfilled
  | File_changed

let lookup t path ~seen current =
  Mutex.protect t.mutex (fun () ->
    let attached = Hashtbl.find_opt t.slots path in
    if not (Option.equal ( == ) seen attached) then None
    else
      let slot =
        match attached with
        | Some slot when Option.equal same_version slot.version current -> slot
        | Some _ | None ->
          let slot = { version = current; value = None; readers = 0 } in
          Hashtbl.replace t.slots path slot;
          slot
      in
      match slot.value with
      | Some value -> Some (Kept value)
      | None ->
        slot.readers <- slot.readers + 1;
        Some (Decode slot))
;;

(* A change of version, a forget, or a writer publication detaches the old
   slot. Its readers can return their observations without publishing them. *)
let finish t path slot completion =
  Mutex.protect t.mutex (fun () ->
    match Hashtbl.find_opt t.slots path with
    | Some current when current == slot ->
      (match completion with
       | File_changed -> Hashtbl.remove t.slots path
       | Publish value ->
         slot.readers <- slot.readers - 1;
         slot.value <- Some value
       | Leave_unfilled ->
         slot.readers <- slot.readers - 1;
         if slot.readers = 0 && Option.is_none slot.value then Hashtbl.remove t.slots path)
    | Some _ | None -> ())
;;

let forget t path = Mutex.protect t.mutex (fun () -> Hashtbl.remove t.slots path)

let keep_written t path value =
  let written = version_of_path path in
  Mutex.protect t.mutex (fun () ->
    match written with
    | Some _ -> Hashtbl.replace t.slots path { version = written; value = Some value; readers = 0 }
    | None -> Hashtbl.remove t.slots path)
;;

let rec load t path ~decode =
  (* A writer can publish while stat is in progress. Check the binding we
     saw before stat so a delayed read cannot displace the published value. *)
  let seen = Mutex.protect t.mutex (fun () -> Hashtbl.find_opt t.slots path) in
  let current = version_of_path path in
  match lookup t path ~seen current with
  | None -> load t path ~decode
  | Some (Kept value) -> Ok value
  | Some (Decode slot) ->
    let completion = ref Leave_unfilled in
    Fun.protect ~finally:(fun () -> finish t path slot !completion) (fun () ->
      let decoded = decode () in
      (match decoded, current with
       | Ok value, Some before ->
         completion :=
           (match version_of_path path with
            | Some after when same_version before after -> Publish value
            | Some _ | None -> File_changed)
       | Ok _, None | Error _, (Some _ | None) -> ());
      decoded)
;;
