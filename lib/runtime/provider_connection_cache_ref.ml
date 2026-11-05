let cache : Llm_provider.Http_client.cache option Atomic.t = Atomic.make None
let install installed = Atomic.set cache (Some installed)
let get () = Atomic.get cache
