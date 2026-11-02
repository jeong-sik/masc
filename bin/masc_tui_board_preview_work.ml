type admission = unit ref
type t = { mutex : Mutex.t; changed : Condition.t; mutable active : bool;
  mutable pending : admission option; mutable stopping : bool }

let create () = {mutex=Mutex.create ();changed=Condition.create ();active=false;pending=None;stopping=false}

let with_lock slot f =
  Mutex.lock slot.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock slot.mutex) f

let is_busy slot = with_lock slot (fun () -> slot.active || Option.is_some slot.pending)
let try_acquire slot = with_lock slot (fun () ->
  if slot.active || Option.is_some slot.pending || slot.stopping then false
  else (slot.active <- true; true))
let release slot = with_lock slot (fun () ->
  slot.active <- false;
  Condition.broadcast slot.changed)
let stop slot = with_lock slot (fun () ->
  slot.stopping <- true;
  slot.pending <- None;
  Condition.broadcast slot.changed)
let await_stopped slot = with_lock slot (fun () ->
  while slot.active do Condition.wait slot.changed slot.mutex done)

let try_run slot work =
  if not (try_acquire slot) then None
  else Some (Fun.protect work ~finally:(fun () -> release slot))

let reserve slot = with_lock slot (fun () ->
  if slot.active || Option.is_some slot.pending || slot.stopping then None
  else let admission = ref () in slot.pending <- Some admission; Some admission)

let reserve_after_active slot = with_lock slot (fun () ->
  if Option.is_some slot.pending || slot.stopping then None
  else let admission = ref () in slot.pending <- Some admission; Some admission)

let withdraw_pending slot = with_lock slot (fun () ->
  let withdrawn = Option.is_some slot.pending in
  slot.pending <- None;
  if withdrawn then Condition.broadcast slot.changed;
  withdrawn)

let withdraw slot admission = with_lock slot (fun () ->
  match slot.pending with
  | Some pending when pending == admission ->
      slot.pending <- None;
      Condition.broadcast slot.changed
  | Some _ | None -> ())

let run_reserved slot admission work =
  let admitted = with_lock slot (fun () ->
    match slot.pending with
    | Some pending when pending == admission && not slot.active && not slot.stopping ->
        slot.pending <- None; slot.active <- true; true
    | Some _ | None -> false) in
  if not admitted then None
  else Some (Fun.protect work ~finally:(fun () -> release slot))

let run_reserved_after_active slot admission work =
  let admitted = with_lock slot (fun () ->
    let owns () = Option.exists (fun pending -> pending == admission) slot.pending in
    while owns () && slot.active && not slot.stopping do
      Condition.wait slot.changed slot.mutex
    done;
    if owns () && not slot.stopping then begin
      slot.pending <- None;
      slot.active <- true;
      true
    end else false) in
  if not admitted then None
  else Some (Fun.protect work ~finally:(fun () -> release slot))

let run slot work =
  match try_run slot work with
  | Some result -> result
  | None -> Error "Previous Board attachment is still preparing; retry after it finishes"
