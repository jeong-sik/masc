type timer

external create : float -> timer = "masc_wall_deadline_create"
external descriptor : timer -> Unix.file_descr = "masc_wall_deadline_descriptor"
external close : timer -> unit = "masc_wall_deadline_close"

let rec sleep_until_with ~now ~wait_once deadline =
  if Float.compare (now ()) deadline < 0 then begin
    wait_once deadline;
    (* A clock change can wake a timer before its deadline. Re-arm it instead
       of treating a backwards adjustment as an expiry. *)
    sleep_until_with ~now ~wait_once deadline
  end
;;

let wait_once ~on_armed deadline =
  let timer = create deadline in
  Fun.protect ~finally:(fun () -> close timer) (fun () ->
    let fd = descriptor timer in
    on_armed ();
    Eio_unix.await_readable fd)
;;

let sleep_until ?(on_armed = fun () -> ()) deadline =
  if not (Float.is_finite deadline) then invalid_arg "wall deadline must be finite";
  sleep_until_with ~now:Unix.gettimeofday ~wait_once:(wait_once ~on_armed) deadline
;;

module For_testing = struct
  let sleep_until_with = sleep_until_with
end
