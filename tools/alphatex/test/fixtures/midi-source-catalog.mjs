const [mode,flag]=process.argv.slice(2)
if(flag!=='--sources')process.exit(4)
const sources=[{id:'-17',name:'Keyboard'},{id:'99',name:'Second'}]
switch(mode){
  case 'valid':break
  case 'duplicate':sources.push(sources[0]);break
  case 'bad-id':sources[0].id='017';break
  case 'bad-name':sources[0].name=4;break
  case 'empty':sources.length=0;break
  case 'invalid':process.stdout.write('oops');process.exit(0)
  case 'wait':process.stdout.write('waiting\n');setInterval(()=>{},1000);break
  default:process.exit(5)
}
if(mode!=='wait')process.stdout.write(JSON.stringify({kind:'midi-sources',schemaVersion:1,sources})+'\n')
