
let () =
 let directory = "/owned-fixture-no-filesystem-operation" in
 let exercise stopped outcome expected =
  let owner = {B.stopped; revoked=false} in
  let original = ref (Some owner) and releasing = ref false in
  let notify = ref None and calls = ref 0 in
  let settlements = ref [{notify; settled=(fun () ->
    assert (!releasing && owner.revoked && !notify=Some B.Abandoned);
    incr calls;outcome)}] in
  let cleanup = make_cleanup ~original ~releasing ~settlements ~directory in
  assert (Eio.Lazy.force cleanup = expected);
  assert (Eio.Lazy.force cleanup = expected);
  assert (!calls=1) in
 exercise (Ok ()) (Ok ()) (Ok (Paths_retained directory));
 print_endline "actual allocation cleanup: joined resources and paths retained PASS";
 exercise (Error B.Listener_close_unconfirmed) (Ok ())
   (Error "private companion listener close unconfirmed");
 print_endline "actual allocation cleanup: descriptor uncertainty preserved PASS";
 exercise (Ok ()) (Error "private settlement unconfirmed")
   (Error "private settlement unconfirmed");
 print_endline "actual allocation cleanup: settlement uncertainty preserved PASS"
