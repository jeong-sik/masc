(* Closed Kata VMM identity tests [task-2856].
   The set of runtime ids is host-validated and closed: a Keeper cannot
   invent one, and inventory recognises every Kata-family id instead of
   silently dropping per-VMM guests. *)

open Alcotest

module V = Masc.Keeper_microvm_kata_vmm
module M = Masc.Keeper_sandbox_microvm
module B = Masc.Keeper_microvm_backend
module R = Masc.Keeper_sandbox_runtime

let vmm_pp ppf = function
  | V.Qemu -> Format.fprintf ppf "Qemu"
  | V.Cloud_hypervisor -> Format.fprintf ppf "Cloud_hypervisor"
  | V.Dragonball -> Format.fprintf ppf "Dragonball"

let vmm = Alcotest.of_pp vmm_pp

let base = "/fixture/owned"
let id c = String.make 64 c

let row ?(root = base) ?(keeper = "alpha") ?(pid = "41001") ?(runtime = B.kata_containerd_shim) c =
  let labels =
    [ R.sandbox_component_label_key, R.sandbox_component_label_value
    ; R.sandbox_base_path_hash_label_key, R.base_path_hash root
    ; R.sandbox_keeper_label_key, keeper
    ; R.sandbox_kind_label_key, M.keeper_vm_container_kind
    ; R.sandbox_owner_pid_label_key, pid
    ]
  in
  `Assoc
    [ "id", `String (id c); "name", `String ("vm-" ^ keeper)
    ; "image", `String "proof:local"; "status", `String "Up 2 minutes"
    ; "created_at", `String "2026-09-08T00:00:00Z"; "runtime", `String runtime
    ; "labels", `Assoc (List.map (fun (k, v) -> (k, `String v)) labels) ]

let lines rows = String.concat "\n" (List.map Yojson.Safe.to_string rows)
let get = function Ok x -> x | Error e -> fail e
let alive pid = pid = 41001

let kata_family id =
  match V.classify_runtime_id id with
  | V.Ours _ | V.Default_shim -> true
  | V.Unknown_runtime _ -> false

(* The closed set: exactly four ids — the default shim plus three per-VMM
   splits.  Anything a Keeper might invent outside it stays unknown. *)
let test_runtime_set_is_closed () =
  let sorted = List.sort String.compare V.kata_runtime_ids in
  sorted
  = [ "io.containerd.kata-clh.v2"; "io.containerd.kata-dragonball.v2"
    ; "io.containerd.kata-qemu.v2"; V.default_shim_runtime_id ]
  |> Alcotest.(check bool "closed set of four host-validated ids") true;
  Alcotest.(check bool "invented id is not kata") false
    (kata_family "io.containerd.kata-custom.v2");
  Alcotest.(check bool "runc is not kata") false
    (kata_family "io.containerd.runc.v2")

let test_choice_decoder_refuses_everything_else () =
  Alcotest.(check (result vmm string))
    "three exact names are accepted" (Ok V.Qemu) (V.vmm_of_choice "qemu");
  Alcotest.(check (result vmm string))
    "cloud-hypervisor accepted" (Ok V.Cloud_hypervisor)
    (V.vmm_of_choice "cloud-hypervisor");
  Alcotest.(check (result vmm string))
    "dragonball accepted" (Ok V.Dragonball) (V.vmm_of_choice "dragonball");
  (match V.vmm_of_choice "io.containerd.kata-custom.v2" with
   | Error m ->
     Alcotest.(check bool) "a runtime id is refused as a choice" true
       (String.length m > 0)
   | Ok _ -> Alcotest.fail "a runtime id must not be a valid choice");
  (match V.vmm_of_choice "" with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "empty choice refused")

let test_classify_keeps_mismatch_explicit () =
  Alcotest.(check vmm) "per-VMM id resolves" V.Cloud_hypervisor
    (match V.classify_runtime_id (V.runtime_id_of V.Cloud_hypervisor) with
     | V.Ours vmm -> vmm
     | _ -> Alcotest.fail "expected Ours");
  (match V.classify_runtime_id V.default_shim_runtime_id with
   | V.Default_shim -> ()
     (* No VMM claim: the default shim's VMM is guest configuration this host
        does not observe, and the type now refuses to guess it. *)
   | _ -> Alcotest.fail "expected Default_shim without a VMM payload");
  (match V.classify_runtime_id "io.containerd.kata-fc.v2" with
   | V.Unknown_runtime id ->
     (* Firecracker is Kata-family but known-unsupported here: keep it
        unknown rather than treating it as somebody else's container. *)
     Alcotest.(check string) "firecracker stays unknown-unsupported"
       "io.containerd.kata-fc.v2" id
   | _ -> Alcotest.fail "kata-fc must stay Unknown_runtime");
  (match V.classify_runtime_id "io.containerd.runc.v2" with
   | V.Unknown_runtime id ->
     Alcotest.(check string) "unknown keeps the observed id"
       "io.containerd.runc.v2" id
   | _ -> Alcotest.fail "runc must stay Unknown_runtime")

(* Inventory: a guest started with any of the closed per-VMM runtime ids is
   ours; before [task-2856] only the fixed shim id matched, so per-VMM guests
   were invisible to adoption and sweep. *)
let test_inventory_recognises_every_kata_vmm () =
  let raw =
    lines
      [ row ~runtime:(V.runtime_id_of V.Qemu) 'a'
      ; row ~runtime:(V.runtime_id_of V.Cloud_hypervisor) 'b'
      ; row ~runtime:(V.runtime_id_of V.Dragonball) 'c'
      ; row ~runtime:B.kata_containerd_shim 'd'
      ]
  in
  let result =
    M.nerdctl_live_containers_of_json_lines ~base_path:base ~keeper_name:"alpha" raw
    |> get
  in
  let count = List.length result in
  Alcotest.(check int) "all four kata-family guests are visible" 4 count

let test_inventory_still_excludes_foreign_runtimes () =
  let raw = lines [ row ~runtime:"io.containerd.runc.v2" 'a' ] in
  let result =
    M.nerdctl_live_containers_of_json_lines ~base_path:base ~keeper_name:"alpha" raw
    |> get
  in
  Alcotest.(check int) "runc rows stay excluded" 0 (List.length result)

let test_sweep_sees_per_vmm_orphans () =
  (* owner 41002 is dead per [alive]; a per-VMM guest must be a sweep
     candidate exactly like a default-shim guest. *)
  let raw =
    lines
      [ row ~pid:"41002" ~runtime:(V.runtime_id_of V.Cloud_hypervisor) 'a'
      ; row ~keeper:"beta" ~runtime:(V.runtime_id_of V.Qemu) 'b'
      ]
  in
  let candidates = M.nerdctl_sweep_candidates_of_json_lines ~base_path:base ~is_pid_alive:alive raw |> get in
  Alcotest.(check int) "dead-owner per-VMM guest is a candidate" 1
    (List.length candidates);
  (match candidates with
   | [ c ] ->
     (match c.keeper_name with
      | Some name ->
        Alcotest.(check string) "candidate names the owning keeper" "alpha" name
      | None -> Alcotest.fail "candidate must carry the keeper name")
   | _ -> Alcotest.fail "expected exactly one candidate")

let case name f = (name, `Slow, f)

let () =
  run "kata vmm closed identity"
    [ ( "closed set", [ case "closed set" test_runtime_set_is_closed ] )
    ; ( "choice decoder",
        [ case "choice decoder" test_choice_decoder_refuses_everything_else ] )
    ; ( "classification",
        [ case "classification" test_classify_keeps_mismatch_explicit ] )
    ; ( "inventory",
        [ case "inventory recognises every kata vmm" test_inventory_recognises_every_kata_vmm
        ; case "inventory excludes foreign runtimes" test_inventory_still_excludes_foreign_runtimes
        ] )
    ; ( "sweep", [ case "sweep sees per-vmm orphans" test_sweep_sees_per_vmm_orphans ] ) ]
