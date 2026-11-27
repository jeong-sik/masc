import{d as k,q as $,y as m,m as i}from"./vendor.js";import{I as u}from"./inline-spinner.js";import{c as y}from"./core.js";function z(t,e=!1){const[r]=k(()=>y()),o=$(()=>r.load(async(l,p)=>{const n=await t(l);if(n.ok)return{kind:"received",data:n.value};if(e&&n.error.kind==="not_found")return{kind:"received",data:null};const v=n.error.kind==="unauthorized"||n.error.kind==="forbidden";return{kind:"failed",error:n.error,data:v?null:p?.data??null}}),[r,t,e]);m(()=>(o(),()=>r.cancel()),[r,o]);const{data:a,loading:s,error:c}=r.state.value,f=a?.data??null,d=c??(a?.kind==="failed"&&!s?a.error.message:null);return{data:f,received:!s&&d===null&&a?.kind==="received",loading:s,error:d,refresh:o,accept:l=>r.reset({kind:"received",data:l})}}function K({label:t,read:e}){const r=e.data!==null;return e.loading?r?i`
        <div class="kp-pill" data-tone="info" role="status" style=${{alignSelf:"flex-start"}}>
          <${u} size="xs" /> ${t} 불러오는 중… · 마지막 조회 표시 중
        </div>`:i`
      <div class="kp-empty" role="status">
        <${u} size="xs" /> ${t} 불러오는 중…
      </div>`:e.error!==null?i`
    <div class="kp-lifecycle-bar">
      <span class="ap-error" role="alert">
        ${t} 조회 실패 · ${e.error}${r?" · 마지막 조회 표시 중":""}
      </span>
      <button type="button" class="btn-ghost" onClick=${()=>{e.refresh()}}>${t} 다시 읽기</button>
    </div>`:e.received?null:i`<div class="kp-empty">${t} 조회 대기</div>`}export{K,z as u};
