type t = {
  domain_mgr : Eio.Domain_manager.ty Eio.Domain_manager.t;
}

let create ~domain_mgr =
  { domain_mgr }

let run_cpu_intensive t f =
  (* Eio.Domain_manager를 통해 별도 OS 코어(Domain)로 연산 위임 *)
  Eio.Domain_manager.run t.domain_mgr f

let compute_local_embedding t ~text =
  run_cpu_intensive t (fun () ->
    (* ONNX C FFI 바인딩을 가정하며 GC finalise를 통해 C 텐서 메모리 누수 방어 *)
    let tensor = "mock_onnx_tensor_ptr" in
    Gc.finalise (fun _ -> 
      (* OrtReleaseTensor(tensor) FFI 호출 가정 *)
      ()
    ) tensor;
    (* 1,536차원 모크 임베딩 벡터 반환 *)
    Array.make 1536 0.05
  )
