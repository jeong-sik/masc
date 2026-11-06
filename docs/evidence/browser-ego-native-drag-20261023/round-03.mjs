const task=await taskSpace(7);
await task.finish({keep:[]});
console.log({finished:7});
