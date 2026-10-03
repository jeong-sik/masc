import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';

const require=createRequire(import.meta.url);
const {compile}=require('../docs/design/lane-composition-export.js');
const html=fs.readFileSync(fileURLToPath(new URL('../docs/design/lane-addons-composer.html',import.meta.url)),'utf8');
const script=html.split('<script>')[1].split('</script>')[0];
new vm.Script(script);
const context=vm.createContext({document:{getElementById(){return {classList:{toggle(){}}}}}});
vm.runInContext(script.slice(0,script.indexOf('Object.entries(kinds).forEach'))+`
graph=template('isolated');
globalThis.fixture=validate(copy(graph));
`,context);
const graph=JSON.parse(JSON.stringify(context.fixture));
for(const node of graph.nodes){
  if(node.kind==='source'){node.snapshot_path='/retained/shared-input.json';node.snapshot_source_id='actual-source';}
  if(node.installation){node.installation={id:node.id,model_route:'explicit.'+node.id,
    max_tokens:512,instructions:'Keep "quotes", newlines\nand DEL \x7f as data.'};}
}
const settings={run_id:'shared-run',analysis_id:'same-analysis',compute_manifest:'/packages/fusion-compute/lane.toml',
  report_manifest:'/packages/fusion-report/lane.toml',prompt:'Compare the original evidence.'};
graph.installation_settings=settings;
const plan=compile(graph);
assert.equal(plan.executed,false);
assert.equal(plan.declarations.length,4);
assert.equal(plan.manual_delivery.length,3);
const panels=plan.declarations.filter(d=>d.binding.role==='panel');
assert.equal(panels.length,2);
for(const panel of panels){assert.equal(panel.binding.sources[0].source_id,'actual-source');assert.equal(panel.binding.sources[0].kind,'snapshot_file');}
const judge=plan.declarations.find(d=>d.binding.role==='judge');
assert.deepEqual(judge.binding.sources.map(s=>s.installation_id).sort(),panels.map(p=>p.installation_id).sort());
const report=plan.declarations.find(d=>!d.binding.role);
assert.equal(report.binding.sources[0].installation_id,judge.installation_id);
assert.equal(report.binding.sources[0].output_id,'result');
assert(plan.declarations.every(d=>d.toml.includes('run_id = "shared-run"')));
const copy=value=>JSON.parse(JSON.stringify(value));
const rejects=(edit,pattern)=>{const changed=copy(graph);edit(changed);assert.throws(()=>compile(changed),pattern);};
rejects(g=>{g.nodes.find(n=>n.kind==='panel').installation.model_route='';},/모델 경로/);
rejects(g=>{g.nodes.find(n=>n.kind==='source').snapshot_source_id='';},/source_id/);
rejects(g=>{g.nodes.find(n=>n.kind==='source').snapshot_path='relative.json';},/절대 경로/);
rejects(g=>{g.nodes.filter(n=>n.kind==='panel')[1].installation.id=g.nodes.find(n=>n.kind==='panel').installation.id;},/중복 설치/);
rejects(g=>{g.nodes.find(n=>n.kind==='panel').installation.max_tokens=0;},/양의 정수/);
rejects(g=>{g.nodes.find(n=>n.kind==='panel').installation.instructions='\ud800';},/Unicode/);
rejects(g=>{g.nodes.find(n=>n.kind==='panel').kind='analysis';},/지원하지 않는 블록/);
rejects(g=>{g.edges.push({from:g.nodes.find(n=>n.kind==='source').id,to:g.nodes.find(n=>n.kind==='judge').id});},/입력 계약/);
rejects(g=>{const original=g.nodes.find(n=>n.kind==='judge');const second=copy(original);second.id='second-judge';second.installation.id='second-judge';g.nodes.push(second);g.edges.push({from:original.id,to:second.id},{from:second.id,to:original.id});},/순환/);
rejects(g=>{const original=g.nodes.find(n=>n.kind==='source');const second=copy(original);second.id='second-source';g.nodes.push(second);g.edges.push({from:second.id,to:g.nodes.find(n=>n.kind==='panel').id});},/source_id가 중복/);
// The editor must preserve settings through import, and duplicates must get a
// new installation identity rather than silently stealing another worker ID.
const imported=vm.runInContext(`validate(${JSON.stringify(graph)})`,context);
assert.equal(JSON.stringify(compile(JSON.parse(JSON.stringify(imported)))),JSON.stringify(plan));
assert.deepEqual(JSON.parse(JSON.stringify(imported.installation_settings)),settings);
assert.equal(imported.nodes.find(n=>n.kind==='source').snapshot_source_id,'actual-source');
assert.equal(imported.nodes.find(n=>n.kind==='panel').installation.model_route,panels[0].binding.model_route);
for(const changed of [{...graph,version:1},{...graph,installation_settings:null},{...graph,installation_settings:{...settings,prompt:42}}])assert.throws(()=>vm.runInContext(`validate(${JSON.stringify(changed)})`,context));
const receivedJudge=graph.nodes.find(n=>n.kind==='judge');
const received={id:'retained-report',lane_id:'fusion/report',related_ids:['retained-context'],title:'Fixture report',fields:{format:'markdown',body:'Received result\n<not markup>',input_complete:false,scope:'supplied_fusion_computation',analysis_id:settings.analysis_id,computation_status:'answered',producer:{installation_id:receivedJudge.installation.id,instance_id:'actual-judge',run_id:settings.run_id,observation_seq:7}}};
const reportContext={id:'retained-context',lane_id:'fusion/report-context',fields:{body:'Retained input context',producer:received.fields.producer,raw_computed_rows:[]}};
function readReport(value){const packet=copy(value),output=packet.structuredContent??packet;output.rows=[...output.rows,reportContext];return vm.runInContext(`parseReceivedReports(${JSON.stringify(packet)})`,context);}
assert.equal(readReport({structuredContent:{rows:[received]}})[0].fields.body,received.fields.body);
assert.equal(readReport({rows:[received]})[0].fields.input_complete,false);
const matches=vm.runInContext(`declaredReportMatches(${JSON.stringify(received)},${JSON.stringify(graph)})`,context);
assert.equal(matches.length,1);
for(const mutate of [r=>{r.fields.producer.run_id='another-run';},r=>{r.fields.analysis_id='another-analysis';},r=>{r.fields.producer.installation_id='another-worker';}]){
 const other=copy(received);mutate(other);assert.equal(vm.runInContext(`declaredReportMatches(${JSON.stringify(other)},${JSON.stringify(graph)})`,context).length,0);
}
for(const invalid of [{rows:[]},{isError:true,structuredContent:{rows:[received]}},{rows:[{...received,fields:{...received.fields,body:42}}]},{rows:[{...received,fields:{...received.fields,computation_status:'completed'}}]}])assert.throws(()=>readReport(invalid));
const ownedReport={...received,id:'report-worker/1/report-id',lane_id:'report-worker/fusion/report'};
const sharing={instance_id:'report-worker',row_ids:[ownedReport.id],row_count:1,evidence:{uri:'lane-evidence:'+'a'.repeat(64),sha256:'a'.repeat(64)},delivery:{destination:'broadcast',status:'committed',receipt:{id:'fixture-message'}}};
const readSharing=value=>vm.runInContext(`parseSharingReceipt(${JSON.stringify(value)})`,context);
readSharing({structuredContent:sharing});
assert.equal(vm.runInContext(`receiptSelectsReport(${JSON.stringify(sharing)},${JSON.stringify(ownedReport)})`,context),true);
for(const other of [{...ownedReport,id:'report-worker/2/report-id'},{...ownedReport,lane_id:'another-worker/fusion/report'},{...ownedReport,lane_id:'fusion/report'}])assert.equal(vm.runInContext(`receiptSelectsReport(${JSON.stringify(sharing)},${JSON.stringify(other)})`,context),false);
for(const mutate of [r=>{r.row_ids.push(r.row_ids[0]);r.row_count=2;},r=>{r.row_count=2;},r=>{r.evidence.sha256='invented';},r=>{r.delivery.destination='keeper';},r=>{r.delivery={destination:'keeper',keeper_name:'imp',status:'committed'};},r=>{r.delivery={destination:'broadcast',status:'outcome_unknown'};}]){const invalid=copy(sharing);mutate(invalid);assert.throws(()=>readSharing(invalid));}
for(const state of ['accepted','failed','outcome_unknown'])readSharing({...sharing,delivery:{destination:'keeper',keeper_name:'imp',status:state,...(state==='accepted'?{}:{error:'fixture failure'})}});
if(process.argv[2])fs.writeFileSync(process.argv[2],JSON.stringify(plan,null,2)+'\n');
console.log('Composition export: 4 real declarations; explicit routes/identities; malformed inputs and cycles rejected; read-only report shapes and declared matches checked. No browser/server execution.');
