const fs=require('node:fs'),vm=require('node:vm');
const [argsPath,scriptPath,outPath]=process.argv.slice(2);
const args=JSON.parse(fs.readFileSync(argsPath,'utf8'));
const source=fs.readFileSync(scriptPath,'utf8');
const run=vm.runInNewContext('('+source+')');
async function simulate(mode){
 const queue=[],calls=[];const current=args.source;
 const page={spaceId:current.spaceId,label:current.label,targetId:current.targetId,openedBy:current.openedBy};
 let world,binding,types=0,drains=0,cleanupCalls=0;
 const session='native-session-'+mode,frame='root-frame-distinct-from-target',contextId=41;
 const event=(method,params)=>({method,params,sessionId:session});
 page.keyboard={type:async function(text,options){calls.push('keyboard.type');types++;
  queue.push(event('Network.requestWillBeSent',{request:{headers:{Cookie:'PRIVATE_NATIVE_HEADER_SENTINEL'}}}));
  if(mode==='dialog')queue.push(event('Page.javascriptDialogOpening',{type:'alert',message:'nonce'}));
  if(mode==='context')queue.push(event('Runtime.executionContextDestroyed',{executionContextId:contextId,executionContextUniqueId:'native-unique'}));
  if(mode==='child')queue.push(event('Page.frameStartedLoading',{frameId:'unrelated-child'}));
  return mode==='value'?null:undefined;
 }};
 page.cdp=async(method,params={})=>{calls.push(method);
  switch(method){
   case 'Page.enable':case 'Runtime.enable':case 'Runtime.addBinding': if(method==='Runtime.addBinding')binding=params.name;return {};
   case 'Page.getFrameTree':return {frameTree:{frame:{id:frame,loaderId:'document',url:'https://fixture.test/'}}};
   case 'Page.createIsolatedWorld':world=params.worldName;queue.push(event('Runtime.executionContextCreated',{context:{id:contextId,uniqueId:'native-unique',name:world,origin:'https://fixture.test',auxData:{frameId:frame,isDefault:false,type:'isolated'}}}));return{executionContextId:contextId};
   case 'Runtime.evaluate':{
    const payload=vm.runInNewContext(params.expression,{[binding]:(payload)=>queue.push(event('Runtime.bindingCalled',{name:binding,payload,executionContextId:contextId}))});
    if(mode==='post-end'&&JSON.parse(payload).bound==='end')queue.push(event('Runtime.executionContextsCleared',{}));
    return{result:{type:'string',value:payload}};
   }
   case 'Runtime.removeBinding':cleanupCalls++;if(mode==='cleanup')throw Error('PRIVATE_NATIVE_HEADER_SENTINEL');return{};
   default:throw Error('unexpected fake native method');
  }
 };
 page.events=async()=>{calls.push('events');drains++;return queue.splice(0)};
 const task={spaceId:current.spaceId,ownership:'agent',tabs:async()=>[{...current,page}],page:()=>{throw Error('sparse task.page must not be used')}};
 const guard=mode==='guard'?async()=>{throw Error('PRIVATE_NATIVE_HEADER_SENTINEL')}:undefined;
 const answer=await run(task,null,args.binding,0,'a',undefined,current,current,guard);
 if(types!==(mode==='guard'?0:1))throw Error('wrong holding call count');
 if(types&&drains>2)throw Error('intervening extra drain');
 const shouldComplete=['normal','child','post-end','cleanup'].includes(mode);
 if((answer.status==='completed')!==shouldComplete)throw Error('wrong local continuation classification '+mode);
 if(!shouldComplete&&cleanupCalls!==0)throw Error('cleanup used to manufacture completion');
 return{mode,status:answer.status,typeCalls:types,drains,cleanupCalls,calls,capture:answer.capture};
}
(async()=>{const result=[];for(const mode of ['normal','dialog','context','child','post-end','cleanup','guard','value'])result.push(await simulate(mode));fs.writeFileSync(outPath,JSON.stringify(result,null,2)+'\n');console.log('8 actual-source producer cases PASS; fake native transport only')})().catch(error=>{console.error(error.message);process.exitCode=1});
