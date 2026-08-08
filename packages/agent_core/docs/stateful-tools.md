# Stateful Tool Patterns

OAS tools are stateless by default: each `call_fn` receives input and returns output with no shared state. For tools that need to maintain state across calls, three patterns are available.

## 1. Closure State (per-session)

State lives in a closure captured at tool creation time. Lost on restart.

```ocaml
let make_counter_tool () =
  let count = ref 0 in
  Tool.create ~name:"counter"
    ~description:"Increment and return count"
    ~parameters:[]
    (fun _input ->
      incr count;
      Ok { Types.content = string_of_int !count })
```

**When to use**: Scratch state, accumulators, per-session caches.

**Trade-off**: No serialization needed, but state vanishes on checkpoint/restore.

## 2. Context State (per-agent, survives checkpoint)

State stored in `Context.t`, serialized with checkpoints.

```ocaml
let make_memory_tool (ctx : Context.t) =
  Tool.create ~name:"remember"
    ~description:"Store a key-value pair"
    ~parameters:[
      { name = "key"; description = "Key"; param_type = String; required = true };
      { name = "value"; description = "Value"; param_type = String; required = true };
    ]
    (fun input ->
      let open Yojson.Safe.Util in
      let key = input |> member "key" |> to_string in
      let value = input |> member "value" |> to_string in
      Context.set ctx key (`String value);
      Ok { Types.content = Printf.sprintf "Stored %s=%s" key value })
```

**When to use**: Agent memory, accumulated knowledge, session config.

**Trade-off**: Survives checkpoint/restore but context size grows.

OAS no longer ships a built-in memory tool family. Consumers that need
durable memory should own that storage outside OAS and expose it through
ordinary tools or hook-provided context.

## 3. External State (database, file)

State lives outside the process. Tool reads/writes external storage.

```ocaml
let make_db_tool ~db_url =
  Tool.create ~name:"query"
    ~description:"Query the database"
    ~parameters:[
      { name = "sql"; description = "SQL query"; param_type = String; required = true };
    ]
    (fun input ->
      let sql = Yojson.Safe.Util.(input |> member "sql" |> to_string) in
      (* Execute against external DB *)
      match Db.execute ~url:db_url sql with
      | Ok rows -> Ok { Types.content = Format.asprintf "%a" Db.pp_rows rows }
      | Error msg -> Error { Types.message = msg; recoverable = true })
```

**When to use**: Shared state across agents, durable storage, large datasets.

**Trade-off**: External dependency, network latency, needs error handling for connectivity.

## Choosing a Pattern

| Criterion | Closure | Context | External |
|-----------|---------|---------|----------|
| Survives checkpoint | No | Yes | Yes |
| Survives restart | No | No | Yes |
| Shared across agents | No | No | Yes |
| Setup complexity | None | Low | Medium |
| Size limits | Memory | JSON size | Storage |
