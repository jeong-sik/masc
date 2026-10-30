/* Pure declaration preview. No filesystem, provider, server or delivery effects. */
(function (root) {
  'use strict';
  const requireText=(value,label)=>{
    if(typeof value!=='string'||!value.trim())throw Error(label+'을 입력하세요.');
    for(const character of value){const point=character.codePointAt(0);if(point>=0xd800&&point<=0xdfff)throw Error(label+'에 잘못된 Unicode 문자가 있습니다.');}
    return value;
  };
  const absolute=(value,label)=>{
    value=requireText(value,label);
    if(!value.startsWith('/')||value.includes('\0'))throw Error(label+'은 서버의 절대 경로여야 합니다.');
    return value;
  };
  const identifier=(value,label)=>{
    value=requireText(value,label);
    if(!/^[a-zA-Z0-9_-]+$/.test(value))throw Error(label+'은 영문·숫자·밑줄·하이픈으로 작성하세요.');
    return value;
  };
  // TOML basic strings accept JSON string escapes, except escaped slash is
  // unnecessary. JSON.stringify also keeps newlines and quote injection data.
  const quote=value=>JSON.stringify(value).replace(/\x7f/g,'\\u007f');
  function compile(graph){
    if(!graph||graph.version!==2||!Array.isArray(graph.nodes)||!Array.isArray(graph.edges))throw Error('version 2 조립안이 필요합니다.');
    const settings=graph.installation_settings;
    if(!settings||typeof settings!=='object'||Array.isArray(settings))throw Error('조립안의 공통 설치 설정이 필요합니다.');
    const run=requireText(settings.run_id,'실행 이름'),analysis=requireText(settings.analysis_id,'분석 이름');
    const compute=absolute(settings.compute_manifest,'계산 패키지 manifest 경로');
    const report=absolute(settings.report_manifest,'보고서 패키지 manifest 경로');
    const prompt=requireText(settings.prompt,'공통 질문');
    const nodes=new Map(),installations=new Set(),edges=new Set();
    for(const node of graph.nodes){
      identifier(node.id,'블록 ID');
      if(nodes.has(node.id))throw Error('중복 블록 ID: '+node.id);
      if(!['source','panel','judge','report','broadcast','agent'].includes(node.kind))throw Error('설치 선언을 지원하지 않는 블록: '+node.kind);
      nodes.set(node.id,node);
      if(['panel','judge','report'].includes(node.kind)){
        const id=identifier(node.installation?.id,'설치 이름 ('+node.name+')');
        if(installations.has(id))throw Error('중복 설치 이름: '+id);
        installations.add(id);
      }
    }
    for(const edge of graph.edges){
      if(!nodes.has(edge.from)||!nodes.has(edge.to)||edge.from===edge.to)throw Error('연결 대상을 확인하세요.');
      const key=JSON.stringify([edge.from,edge.to]);
      if(edges.has(key))throw Error('중복 연결입니다.');edges.add(key);
      const from=nodes.get(edge.from).kind,to=nodes.get(edge.to).kind;
      const allowed={source:['panel'],panel:['judge','report'],judge:['judge','report'],report:['broadcast','agent'],broadcast:['agent'],agent:[]};
      if(!allowed[from].includes(to))throw Error('실제 패키지 입력 계약과 맞지 않는 연결: '+from+' → '+to);
    }
    const ordered=[],remaining=new Set(nodes.keys());
    while(remaining.size){
      const ready=[...remaining].filter(id=>graph.edges.filter(e=>e.to===id).every(e=>!remaining.has(e.from)));
      if(!ready.length)throw Error('순환 연결은 설치할 수 없습니다.');
      for(const id of ready){ordered.push(nodes.get(id));remaining.delete(id);}
    }
    const declarations=[];
    for(const node of ordered){
      if(!['panel','judge','report'].includes(node.kind))continue;
      const upstream=graph.edges.filter(e=>e.to===node.id).map(e=>nodes.get(e.from));
      if(!upstream.length)throw Error(node.name+'의 입력 연결이 필요합니다.');
      const config=node.installation;
      const binding={};
      if(node.kind!=='report'){
        if(!Number.isSafeInteger(config.max_tokens)||config.max_tokens<=0)throw Error(node.name+'의 출력 토큰 한도를 양의 정수로 입력하세요.');
        Object.assign(binding,{analysis_id:analysis,role:node.kind,prompt,
          instructions:requireText(config.instructions,node.name+' 지시'),max_tokens:config.max_tokens,
          model_route:requireText(config.model_route,node.name+' 모델 경로')});
      }
      const sources=upstream.map(input=>input.kind==='source'
        ?{source_id:requireText(input.snapshot_source_id,input.name+' 자료 JSON의 source_id'),kind:'snapshot_file',path:absolute(input.snapshot_path,input.name+' 자료 경로')}
        :{source_id:input.installation.id,kind:'lane_output',installation_id:input.installation.id,
          output_id:'result',selection:'latest_completed'});
      if(new Set(sources.map(source=>source.source_id)).size!==sources.length)throw Error(node.name+'의 입력 source_id가 중복됩니다.');
      const lines=['id = '+quote(config.id),'run_id = '+quote(run),
        'manifest_path = '+quote(node.kind==='report'?report:compute),'','[binding]'];
      for(const [key,value] of Object.entries(binding))lines.push(key+' = '+(typeof value==='number'?String(value):quote(value)));
      for(const source of sources){lines.push('','[[binding.sources]]');for(const [key,value] of Object.entries(source))lines.push(key+' = '+quote(value));}
      declarations.push({installation_id:config.id,file_name:config.id+'.toml',toml:lines.join('\n')+'\n',binding:{...binding,sources}});
    }
    if(!declarations.length)throw Error('설치할 패널·Judge·보고서가 없습니다.');
    return {run_id:run,analysis_id:analysis,declarations,
      manual_delivery:ordered.filter(n=>['broadcast','agent'].includes(n.kind)).map(n=>({id:n.id,kind:n.kind,name:n.name})),
      executed:false};
  }
  root.MascLaneComposition={compile};
  if(typeof module!=='undefined')module.exports=root.MascLaneComposition;
})(globalThis);
