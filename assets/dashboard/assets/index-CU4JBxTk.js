var Cl=Object.defineProperty;var Nl=(t,e,n)=>e in t?Cl(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Te=(t,e,n)=>Nl(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var Xa,K,Yo,Xo,fe,Qi,Zo,tr,er,Di,js,Fs,Cn={},nr=[],Rl=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Za=Array.isArray;function Bt(t,e){for(var n in e)t[n]=e[n];return t}function Pi(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function ar(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Xa.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return oa(t,r,a,s,null)}function oa(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++Yo,__i:-1,__u:0};return s==null&&K.vnode!=null&&K.vnode(i),i}function jn(t){return t.children}function cn(t,e){this.props=t,this.context=e}function Ue(t,e){if(e==null)return t.__?Ue(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?Ue(t):null}function sr(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return sr(t)}}function Yi(t){(!t.__d&&(t.__d=!0)&&fe.push(t)&&!ha.__r++||Qi!=K.debounceRendering)&&((Qi=K.debounceRendering)||Zo)(ha)}function ha(){for(var t,e,n,a,s,i,r,u=1;fe.length;)fe.length>u&&fe.sort(tr),t=fe.shift(),u=fe.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=Bt({},a)).__v=a.__v+1,K.vnode&&K.vnode(n),Li(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??Ue(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,rr(i,n,r),a.__e=a.__=null,n.__e!=s&&sr(n)));ha.__r=0}function ir(t,e,n,a,s,i,r,u,d,v,p){var l,c,m,$,b,x,D,T=a&&a.__k||nr,z=e.length;for(d=Dl(n,e,T,d,z),l=0;l<z;l++)(m=n.__k[l])!=null&&(c=m.__i==-1?Cn:T[m.__i]||Cn,m.__i=l,x=Li(t,m,c,s,i,r,u,d,v,p),$=m.__e,m.ref&&c.ref!=m.ref&&(c.ref&&Ii(c.ref,null,m),p.push(m.ref,m.__c||$,m)),b==null&&$!=null&&(b=$),(D=!!(4&m.__u))||c.__k===m.__k?d=or(m,d,t,D):typeof m.type=="function"&&x!==void 0?d=x:$&&(d=$.nextSibling),m.__u&=-7);return n.__e=b,d}function Dl(t,e,n,a,s){var i,r,u,d,v,p=n.length,l=p,c=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=oa(null,r,null,null,null):Za(r)?r=t.__k[i]=oa(jn,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=oa(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+c,r.__=t,r.__b=t.__b+1,u=null,(v=r.__i=Pl(r,n,d,l))!=-1&&(l--,(u=n[v])&&(u.__u|=2)),u==null||u.__v==null?(v==-1&&(s>p?c--:s<p&&c++),typeof r.type!="function"&&(r.__u|=4)):v!=d&&(v==d-1?c--:v==d+1?c++:(v>d?c--:c++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<p;i++)(u=n[i])!=null&&(2&u.__u)==0&&(u.__e==a&&(a=Ue(u)),cr(u,u));return a}function or(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=or(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=Ue(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Pl(t,e,n,a){var s,i,r,u=t.key,d=t.type,v=e[n],p=v!=null&&(2&v.__u)==0;if(v===null&&u==null||p&&u==v.key&&d==v.type)return n;if(a>(p?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((v=e[r=s>=0?s--:i++])!=null&&(2&v.__u)==0&&u==v.key&&d==v.type)return r}return-1}function Xi(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Rl.test(e)?n:n+"px"}function Jn(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||Xi(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||Xi(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(er,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=Di,t.addEventListener(e,i?Fs:js,i)):t.removeEventListener(e,i?Fs:js,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Zi(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Di++;else if(e.t<n.u)return;return n(K.event?K.event(e):e)}}}function Li(t,e,n,a,s,i,r,u,d,v){var p,l,c,m,$,b,x,D,T,z,C,L,tt,xt,ft,et,lt,O=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[u=e.__e=n.__e]),(p=K.__b)&&p(e);t:if(typeof O=="function")try{if(D=e.props,T="prototype"in O&&O.prototype.render,z=(p=O.contextType)&&a[p.__c],C=p?z?z.props.value:p.__:a,n.__c?x=(l=e.__c=n.__c).__=l.__E:(T?e.__c=l=new O(D,C):(e.__c=l=new cn(D,C),l.constructor=O,l.render=Il),z&&z.sub(l),l.state||(l.state={}),l.__n=a,c=l.__d=!0,l.__h=[],l._sb=[]),T&&l.__s==null&&(l.__s=l.state),T&&O.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=Bt({},l.__s)),Bt(l.__s,O.getDerivedStateFromProps(D,l.__s))),m=l.props,$=l.state,l.__v=e,c)T&&O.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),T&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(T&&O.getDerivedStateFromProps==null&&D!==m&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(D,C),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(D,l.__s,C)===!1){for(e.__v!=n.__v&&(l.props=D,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(J){J&&(J.__=e)}),L=0;L<l._sb.length;L++)l.__h.push(l._sb[L]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(D,l.__s,C),T&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(m,$,b)})}if(l.context=C,l.props=D,l.__P=t,l.__e=!1,tt=K.__r,xt=0,T){for(l.state=l.__s,l.__d=!1,tt&&tt(e),p=l.render(l.props,l.state,l.context),ft=0;ft<l._sb.length;ft++)l.__h.push(l._sb[ft]);l._sb=[]}else do l.__d=!1,tt&&tt(e),p=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++xt<25);l.state=l.__s,l.getChildContext!=null&&(a=Bt(Bt({},a),l.getChildContext())),T&&!c&&l.getSnapshotBeforeUpdate!=null&&(b=l.getSnapshotBeforeUpdate(m,$)),et=p,p!=null&&p.type===jn&&p.key==null&&(et=lr(p.props.children)),u=ir(t,Za(et)?et:[et],e,n,a,s,i,r,u,d,v),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),x&&(l.__E=l.__=null)}catch(J){if(e.__v=null,d||i!=null)if(J.then){for(e.__u|=d?160:128;u&&u.nodeType==8&&u.nextSibling;)u=u.nextSibling;i[i.indexOf(u)]=null,e.__e=u}else{for(lt=i.length;lt--;)Pi(i[lt]);qs(e)}else e.__e=n.__e,e.__k=n.__k,J.then||qs(e);K.__e(J,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):u=e.__e=Ll(n.__e,e,n,a,s,i,r,d,v);return(p=K.diffed)&&p(e),128&e.__u?void 0:u}function qs(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(qs)}function rr(t,e,n){for(var a=0;a<n.length;a++)Ii(n[a],n[++a],n[++a]);K.__c&&K.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){K.__e(i,s.__v)}})}function lr(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Za(t)?t.map(lr):Bt({},t)}function Ll(t,e,n,a,s,i,r,u,d){var v,p,l,c,m,$,b,x=n.props||Cn,D=e.props,T=e.type;if(T=="svg"?s="http://www.w3.org/2000/svg":T=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(v=0;v<i.length;v++)if((m=i[v])&&"setAttribute"in m==!!T&&(T?m.localName==T:m.nodeType==3)){t=m,i[v]=null;break}}if(t==null){if(T==null)return document.createTextNode(D);t=document.createElementNS(s,T,D.is&&D),u&&(K.__m&&K.__m(e,i),u=!1),i=null}if(T==null)x===D||u&&t.data==D||(t.data=D);else{if(i=i&&Xa.call(t.childNodes),!u&&i!=null)for(x={},v=0;v<t.attributes.length;v++)x[(m=t.attributes[v]).name]=m.value;for(v in x)if(m=x[v],v!="children"){if(v=="dangerouslySetInnerHTML")l=m;else if(!(v in D)){if(v=="value"&&"defaultValue"in D||v=="checked"&&"defaultChecked"in D)continue;Jn(t,v,null,m,s)}}for(v in D)m=D[v],v=="children"?c=m:v=="dangerouslySetInnerHTML"?p=m:v=="value"?$=m:v=="checked"?b=m:u&&typeof m!="function"||x[v]===m||Jn(t,v,m,x[v],s);if(p)u||l&&(p.__html==l.__html||p.__html==t.innerHTML)||(t.innerHTML=p.__html),e.__k=[];else if(l&&(t.innerHTML=""),ir(e.type=="template"?t.content:t,Za(c)?c:[c],e,n,a,T=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&Ue(n,0),u,d),i!=null)for(v=i.length;v--;)Pi(i[v]);u||(v="value",T=="progress"&&$==null?t.removeAttribute("value"):$!=null&&($!==t[v]||T=="progress"&&!$||T=="option"&&$!=x[v])&&Jn(t,v,$,x[v],s),v="checked",b!=null&&b!=t[v]&&Jn(t,v,b,x[v],s))}return t}function Ii(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){K.__e(s,n)}}function cr(t,e,n){var a,s;if(K.unmount&&K.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||Ii(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){K.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&cr(a[s],e,n||typeof t.type!="function");n||Pi(t.__e),t.__c=t.__=t.__e=void 0}function Il(t,e,n){return this.constructor(t,n)}function El(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),K.__&&K.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],Li(e,t=e.__k=ar(jn,null,[t]),s||Cn,Cn,e.namespaceURI,s?null:e.firstChild?Xa.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),rr(i,t,r)}Xa=nr.slice,K={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(u){t=u}throw t}},Yo=0,Xo=function(t){return t!=null&&t.constructor===void 0},cn.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=Bt({},this.state),typeof t=="function"&&(t=t(Bt({},n),this.props)),t&&Bt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),Yi(this))},cn.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),Yi(this))},cn.prototype.render=jn,fe=[],Zo=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,tr=function(t,e){return t.__v.__b-e.__v.__b},ha.__r=0,er=/(PointerCapture)$|Capture$/i,Di=0,js=Zi(!1),Fs=Zi(!0);var ur=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],u=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=u:r===4?a[1]=Object.assign(a[1]||{},u):r===5?(a[1]=a[1]||{})[e[++i]]=u:r===6?a[1][e[++i]]+=u+"":r?(s=t.apply(u,ur(t,u,n,["",null])),a.push(s),u[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(u)}return a},to=new Map;function Ol(t){var e=to.get(this);return e||(e=new Map,to.set(this,e)),(e=ur(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",u="",d=[0],v=function(c){i===1&&(c||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,c,r):i===3&&(c||r)?(d.push(3,c,r),i=2):i===2&&r==="..."&&c?d.push(4,c,0):i===2&&r&&!c?d.push(5,0,!0,r):i>=5&&((r||!c&&i===5)&&(d.push(i,0,r,s),i=6),c&&(d.push(i,c,0,s),i=6)),r=""},p=0;p<n.length;p++){p&&(i===1&&v(),v(p));for(var l=0;l<n[p].length;l++)a=n[p][l],i===1?a==="<"?(v(),d=[d],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:u?a===u?u="":r+=a:a==='"'||a==="'"?u=a:a===">"?(v(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[p][l+1]===">")?(v(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(v(),i=2):r+=a),i===3&&r==="!--"&&(i=4,d=d[0])}return v(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Ol.bind(ar),Nn,Q,rs,eo,Hs=0,dr=[],X=K,no=X.__b,ao=X.__r,so=X.diffed,io=X.__c,oo=X.unmount,ro=X.__;function Ei(t,e){X.__h&&X.__h(Q,t,Hs||e),Hs=0;var n=Q.__H||(Q.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function pr(t){return Hs=1,Ml(fr,t)}function Ml(t,e,n){var a=Ei(Nn++,2);if(a.t=t,!a.__c&&(a.__=[fr(void 0,e),function(u){var d=a.__N?a.__N[0]:a.__[0],v=a.t(d,u);d!==v&&(a.__N=[v,a.__[1]],a.__c.setState({}))}],a.__c=Q,!Q.__f)){var s=function(u,d,v){if(!a.__c.__H)return!0;var p=a.__c.__H.__.filter(function(c){return!!c.__c});if(p.every(function(c){return!c.__N}))return!i||i.call(this,u,d,v);var l=a.__c.props!==u;return p.forEach(function(c){if(c.__N){var m=c.__[0];c.__=c.__N,c.__N=void 0,m!==c.__[0]&&(l=!0)}}),i&&i.call(this,u,d,v)||l};Q.__f=!0;var i=Q.shouldComponentUpdate,r=Q.componentWillUpdate;Q.componentWillUpdate=function(u,d,v){if(this.__e){var p=i;i=void 0,s(u,d,v),i=p}r&&r.call(this,u,d,v)},Q.shouldComponentUpdate=s}return a.__N||a.__}function qt(t,e){var n=Ei(Nn++,3);!X.__s&&mr(n.__H,e)&&(n.__=t,n.u=e,Q.__H.__h.push(n))}function vr(t,e){var n=Ei(Nn++,7);return mr(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function zl(){for(var t;t=dr.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(ra),t.__H.__h.forEach(Ks),t.__H.__h=[]}catch(e){t.__H.__h=[],X.__e(e,t.__v)}}X.__b=function(t){Q=null,no&&no(t)},X.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),ro&&ro(t,e)},X.__r=function(t){ao&&ao(t),Nn=0;var e=(Q=t.__c).__H;e&&(rs===Q?(e.__h=[],Q.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(ra),e.__h.forEach(Ks),e.__h=[],Nn=0)),rs=Q},X.diffed=function(t){so&&so(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(dr.push(e)!==1&&eo===X.requestAnimationFrame||((eo=X.requestAnimationFrame)||jl)(zl)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),rs=Q=null},X.__c=function(t,e){e.some(function(n){try{n.__h.forEach(ra),n.__h=n.__h.filter(function(a){return!a.__||Ks(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],X.__e(a,n.__v)}}),io&&io(t,e)},X.unmount=function(t){oo&&oo(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{ra(a)}catch(s){e=s}}),n.__H=void 0,e&&X.__e(e,n.__v))};var lo=typeof requestAnimationFrame=="function";function jl(t){var e,n=function(){clearTimeout(a),lo&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);lo&&(e=requestAnimationFrame(n))}function ra(t){var e=Q,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),Q=e}function Ks(t){var e=Q;t.__c=t.__(),Q=e}function mr(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}function fr(t,e){return typeof e=="function"?e(t):e}var Fl=Symbol.for("preact-signals");function ts(){if(ie>1)ie--;else{for(var t,e=!1;un!==void 0;){var n=un;for(un=void 0,Us++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&hr(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(Us=0,ie--,e)throw t}}function ql(t){if(ie>0)return t();ie++;try{return t()}finally{ts()}}var H=void 0;function _r(t){var e=H;H=void 0;try{return t()}finally{H=e}}var un=void 0,ie=0,Us=0,$a=0;function gr(t){if(H!==void 0){var e=t.n;if(e===void 0||e.t!==H)return e={i:0,S:t,p:H.s,n:void 0,t:H,e:void 0,x:void 0,r:e},H.s!==void 0&&(H.s.n=e),H.s=e,t.n=e,32&H.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=H.s,e.n=void 0,H.s.n=e,H.s=e),e}}function nt(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}nt.prototype.brand=Fl;nt.prototype.h=function(){return!0};nt.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:_r(function(){var a;(a=e.W)==null||a.call(e)}))};nt.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&_r(function(){var s;(s=e.Z)==null||s.call(e)}))}};nt.prototype.subscribe=function(t){var e=this;return Fn(function(){var n=e.value,a=H;H=void 0;try{t(n)}finally{H=a}},{name:"sub"})};nt.prototype.valueOf=function(){return this.value};nt.prototype.toString=function(){return this.value+""};nt.prototype.toJSON=function(){return this.value};nt.prototype.peek=function(){var t=H;H=void 0;try{return this.value}finally{H=t}};Object.defineProperty(nt.prototype,"value",{get:function(){var t=gr(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Us>100)throw new Error("Cycle detected");this.v=t,this.i++,$a++,ie++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{ts()}}}});function g(t,e){return new nt(t,e)}function hr(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function $r(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function yr(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function ke(t,e){nt.call(this,void 0),this.x=t,this.s=void 0,this.g=$a-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}ke.prototype=new nt;ke.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===$a))return!0;if(this.g=$a,this.f|=1,this.i>0&&!hr(this))return this.f&=-2,!0;var t=H;try{$r(this),H=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return H=t,yr(this),this.f&=-2,!0};ke.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}nt.prototype.S.call(this,t)};ke.prototype.U=function(t){if(this.t!==void 0&&(nt.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};ke.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(ke.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=gr(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function bt(t,e){return new ke(t,e)}function br(t){var e=t.u;if(t.u=void 0,typeof e=="function"){ie++;var n=H;H=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,Oi(t),a}finally{H=n,ts()}}}function Oi(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,br(t)}function Hl(t){if(H!==this)throw new Error("Out-of-order effect");yr(this),H=t,this.f&=-2,8&this.f&&Oi(this),ts()}function Ve(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Ve.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Ve.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,br(this),$r(this),ie++;var t=H;return H=this,Hl.bind(this,t)};Ve.prototype.N=function(){2&this.f||(this.f|=2,this.o=un,un=this)};Ve.prototype.d=function(){this.f|=8,1&this.f||Oi(this)};Ve.prototype.dispose=function(){this.d()};function Fn(t,e){var n=new Ve(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var kr,Vn,Kl=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,xr=[];Fn(function(){kr=this.N})();function Qe(t,e){K[t]=e.bind(null,K[t]||function(){})}function ya(t){if(Vn){var e=Vn;Vn=void 0,e()}Vn=t&&t.S()}function Sr(t){var e=this,n=t.data,a=Bl(n);a.value=n;var s=vr(function(){for(var u=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var v=bt(function(){var m=a.value.value;return m===0?0:m===!0?"":m||""}),p=bt(function(){return!Array.isArray(v.value)&&!Xo(v.value)}),l=Fn(function(){if(this.N=Ar,p.value){var m=v.value;u.__v&&u.__v.__e&&u.__v.__e.nodeType===3&&(u.__v.__e.data=m)}}),c=e.__$u.d;return e.__$u.d=function(){l(),c.call(this)},[p,v]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}Sr.displayName="ReactiveTextNode";Object.defineProperties(nt.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Sr},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});Qe("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof nt&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});Qe("__r",function(t,e){if(t(e),e.type!==jn){ya();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return Fn(function(){r=this},{name:i}),r.c=s,r})(function(){var s;Kl&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),ya(n)}});Qe("__e",function(t,e,n,a){ya(),t(e,n,a)});Qe("diffed",function(t,e){ya();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var u=i[r];u!==void 0&&!(r in a)&&(u.d(),i[r]=void 0)}else i={},n.U=i;for(var d in a){var v=i[d],p=a[d];v===void 0?(v=Ul(n,d,p),i[d]=v):v.o(p,s)}for(var l in a)s[l]=a[l]}}t(e)});function Ul(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=g(n),r=n.peek();return{o:function(u,d){i.value=u,r=u.peek()},d:Fn(function(){this.N=Ar;var u=i.value.value;r!==u?(r=void 0,s?t[e]=u:u!=null&&(u!==!1||e[4]==="-")?t.setAttribute(e,u):t.removeAttribute(e)):r=void 0})}}Qe("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var u=r.__$u;u&&(r.__$u=void 0,u.d())}}t(e)});Qe("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});cn.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var u in this.props)if(!(u in t))return!0;return!1};function Bl(t,e){return vr(function(){return g(t,e)},[])}var Wl=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Gl(){ql(function(){for(var t;t=xr.shift();)kr.call(t)})}function Ar(){xr.push(this)===1&&(K.requestAnimationFrame||Wl)(Gl)}const Jl=["command","overview","board","goals","agents","ops","trpg"],wr={tab:"overview",params:{},postId:null},Vl={journal:"overview",mdal:"goals",tasks:"goals",execution:"overview",council:"board",activity:"overview"};function co(t){return!!t&&Jl.includes(t)}function uo(t){if(t)return Vl[t]??t}function Bs(t){try{return decodeURIComponent(t)}catch{return t}}function Ws(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function Ql(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Tr(t,e){const n=uo(t[0]),a=uo(e.tab),s=co(n)?n:co(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Bs(t[2]):t[0]==="post"&&t[1]&&(i=Bs(t[1]))),{tab:s,params:e,postId:i}}function ba(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return wr;const n=Bs(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const u=n.indexOf("?");u>=0&&(a=n.slice(0,u),s=n.slice(u+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=Ws(s),r=Ql(a);return Tr(r,i)}function Yl(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...wr,params:Ws(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=Ws(e.replace(/^\?/,""));return Tr(a,s)}function Cr(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const Ft=g(ba(window.location.hash));window.addEventListener("hashchange",()=>{Ft.value=ba(window.location.hash)});function zt(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Cr(n)}function Xl(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Zl(){if(window.location.hash&&window.location.hash!=="#"){Ft.value=ba(window.location.hash);return}const t=Yl(window.location.pathname,window.location.search);if(t){Ft.value=t;const e=Cr(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",Ft.value=ba(window.location.hash)}const po="masc_dashboard_sse_session_id",tc=1e3,ec=15e3,Vt=g(!1),qn=g(0),Nr=g(null),le=g([]);function nc(){let t=sessionStorage.getItem(po);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(po,t)),t}const ac=200;function sc(t,e,n="system",a={}){const s={agent:t,text:e,timestamp:Date.now(),kind:n,...a};le.value=[s,...le.value].slice(0,ac)}function Gs(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function vo(t,e){const n=Gs(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Ct(t,e,n,a,s={}){sc(t,e,n,{eventType:a,...s})}let Mt=null,ze=null,Js=0;function Rr(){ze&&(clearTimeout(ze),ze=null)}function ic(){if(ze)return;Js++;const t=Math.min(Js,5),e=Math.min(ec,tc*Math.pow(2,t));ze=setTimeout(()=>{ze=null,Dr()},e)}function Dr(){Rr(),Mt&&(Mt.close(),Mt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",nc());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);Mt=i,i.onopen=()=>{Mt===i&&(Js=0,Vt.value=!0)},i.onerror=()=>{Mt===i&&(Vt.value=!1,i.close(),Mt=null,ic())},i.onmessage=r=>{try{const u=JSON.parse(r.data);qn.value++,Nr.value=u,oc(u)}catch{}}}function oc(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Ct(n,"Joined","system","agent_joined");break;case"agent_left":Ct(n,"Left","system","agent_left");break;case"broadcast":Ct(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Ct(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Ct(n,vo("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Gs(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Ct(n,vo("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Gs(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Ct(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Ct(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Ct(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Ct(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Ct(n,e,"system","unknown")}}function rc(){Rr(),Mt&&(Mt.close(),Mt=null),Vt.value=!1}function Pr(){return new URLSearchParams(window.location.search)}function Lr(){const t=Pr(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Ir(){return{...Lr(),"Content-Type":"application/json"}}const lc=15e3,Mi=3e4,cc=6e4,mo=new Set([408,425,429,500,502,503,504]);class Hn extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,i=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Te(this,"method");Te(this,"path");Te(this,"status");Te(this,"statusText");Te(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function zi(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Hn({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(s)}}function uc(){var e,n;const t=Pr();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Tt(t){const e=await zi(t,{headers:Lr()},lc);if(!e.ok)throw new Hn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function dc(t){return new Promise(e=>setTimeout(e,t))}function pc(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function vc(t){if(t instanceof Hn)return t.timeout||typeof t.status=="number"&&mo.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=pc(t.message);return e!==null&&mo.has(e)}async function Ye(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!vc(s)||a>=n)throw s;const i=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${i}ms`,s),await dc(i),a+=1}}async function Ut(t,e,n,a=Mi){const s=await zi(t,{method:"POST",headers:{...Ir(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new Hn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function mc(t,e,n,a=Mi){const s=await zi(t,{method:"POST",headers:{...Ir(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new Hn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function fc(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function _c(t){var e,n,a,s,i,r,u;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(d)}return((u=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:u.text)??""}async function kt(t,e){const n=await mc("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},cc),a=fc(n);return _c(a)}function gc(t="compact"){return Tt(`/api/v1/dashboard?mode=${t}`)}function hc(t={}){return Ye("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return Tt(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function $c(){return Tt("/api/v1/operator")}function yc(){return Tt("/api/v1/command-plane")}function bc(){return Tt("/api/v1/command-plane/help")}function kc(t,e){return Ut(t,e)}function xc(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return Mi}}function Kn(t){return Ut("/api/v1/operator/action",t,void 0,xc(t))}function Sc(t,e){return Ut("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const Ac=new Set(["lodge-system","team-session"]);function Be(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function wc(t){return Ac.has(t.trim().toLowerCase())}function Tc(t){return t.filter(e=>!wc(e.author))}function Cc(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Er(t){if(!M(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),a=h(t.content,"").trim();if(!e||!n)return null;const s=F(t.score,0),i=F(t.votes_up,0),r=F(t.votes_down,0),u=F(t.votes,s||i-r),d=F(t.comment_count,F(t.reply_count,0)),v=(()=>{const $=t.flair;if(typeof $=="string"&&$.trim())return $.trim();if(M($)){const x=h($.name,"").trim();if(x)return x}return h(t.flair_name,"").trim()||void 0})(),p=h(t.created_at_iso,"").trim()||Be(t.created_at),l=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Be(t.updated_at):p),m=h(t.title,"").trim()||Cc(a);return{id:e,author:n,title:m,content:a,tags:[],votes:u,vote_balance:s,comment_count:d,created_at:p,updated_at:l,flair:v,hearth_count:F(t.hearth_count,0)}}function Nc(t){if(!M(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),a=h(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:h(t.content,""),created_at:Be(t.created_at)}}async function Rc(t,e){return Ye("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),s=await Tt(`/api/v1/board${a?`?${a}`:""}`),i=Array.isArray(s.posts)?s.posts.map(Er).filter(u=>u!==null):[];return{posts:e!=null&&e.excludeSystem?Tc(i):i}})}async function Dc(t){return Ye("fetchBoardPost",async()=>{const e=await Tt(`/api/v1/board/${t}?format=flat`),n=M(e.post)?e.post:e,a=Er(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(Nc).filter(r=>r!==null);return{...a,comments:i}})}function Or(t,e){return Ut("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:uc()})}function Pc(t,e,n){return Ut("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Lc(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function ct(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function fo(t){const e=Lc(ct(t.outcome,t.result,t.result_code));if(!e)return;const n=ct(t.reason,t.reason_code,t.description,t.detail),a=ct(t.summary,t.summary_ko,t.summary_en,t.note),s=ct(t.details,t.details_text,t.text,t.note),i=ct(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=ct(t.winner_actor_id,t.winner_actor,t.actor_winner_id),u=ct(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const l=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof l=="string"?[l]:Array.isArray(l)?l.map(c=>{if(typeof c=="string")return c.trim();if(M(c)){const m=h(c.summary,"").trim();if(m)return m;const $=h(c.text,"").trim();if($)return $;const b=h(c.type,"").trim();return b||h(c.event_id,"").trim()}return""}).filter(c=>c.length>0):[]})(),v=(()=>{const l=F(t.turn,Number.NaN);if(Number.isFinite(l))return l;const c=F(t.turn_number,Number.NaN);if(Number.isFinite(c))return c;const m=F(t.current_turn,Number.NaN);if(Number.isFinite(m))return m;const $=F(t.round,Number.NaN);return Number.isFinite($)?$:void 0})(),p=ct(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:u||void 0,turn:v,phase:p||void 0}}function Ic(t,e){const n=M(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>M(r)?h(r.type,"")==="session.outcome":!1),i=M(n.session_outcome)?n.session_outcome:{};if(M(i)&&Object.keys(i).length>0){const r=fo(i);if(r)return r}if(M(s))return fo(M(s.payload)?s.payload:{})}function M(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function F(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Ec(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Vs(t,e=!1){return typeof t=="boolean"?t:e}function en(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(M(e)){const n=h(e.name,"").trim(),a=h(e.id,"").trim(),s=h(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function Oc(t){const e={};if(!M(t)&&!Array.isArray(t))return e;if(M(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),i=h(a,"").trim();!s||!i||(e[s]=i)}),e;for(const n of t){if(!M(n))continue;const a=ct(n.to,n.target,n.actor_id,n.name,n.id),s=ct(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function Mc(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function At(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}const zc=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function jc(t){const e=M(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const i=a.trim();i&&(zc.has(i.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[i]=s))}),n}function Fc(t,e){if(t!=="dice.rolled")return;const n=F(e.raw_d20,0),a=F(e.total,0),s=F(e.bonus,0),i=h(e.action,"roll"),r=F(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function qc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Hc(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Kc(t,e,n,a){const s=n||e||h(a.actor_id,"")||h(a.actor_name,"");switch(t){case"turn.action.proposed":{const i=h(a.proposed_action,h(a.reply,""));return i?`${s||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=h(a.reply,h(a.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return h(a.reply,h(a.content,h(a.text,"Narration")));case"dice.rolled":{const i=h(a.action,"roll"),r=F(a.total,0),u=F(a.dc,0),d=h(a.label,""),v=s||"actor",p=u>0?` vs DC ${u}`:"",l=d?` (${d})`:"";return`${v} ${i}: ${r}${p}${l}`}case"turn.started":return`Turn ${F(a.turn,1)} started`;case"phase.changed":return`Phase: ${h(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(a.name,M(a.actor)?h(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${h(a.keeper_name,h(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${h(a.keeper_name,h(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${F(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${F(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||h(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||h(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(a.reason_code,"unknown")}`;case"memory.signal":{const i=M(a.entity_refs)?a.entity_refs:{},r=h(i.requested_tier,""),u=h(i.effective_tier,""),d=Vs(i.guardrail_applied,!1),v=h(a.summary_en,h(a.summary_ko,"Memory signal"));if(!r&&!u)return v;const p=r&&u?`${r}->${u}`:u||r;return`${v} [${p}${d?" (guardrail)":""}]`}case"world.event":{if(h(a.event_type,"")==="canon.check"){const r=h(a.status,"unknown"),u=h(a.contract_id,"n/a");return`Canon ${r}: ${u}`}return h(a.description,h(a.summary,"World event"))}case"combat.attack":return h(a.summary,h(a.result,"Attack resolved"));case"combat.defense":return h(a.summary,h(a.result,"Defense resolved"));case"session.outcome":return h(a.summary,h(a.outcome,"Session ended"));default:{const i=qc(a);return i?`${t}: ${i}`:t}}}function Uc(t,e){const n=M(t)?t:{},a=h(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=h(n.actor_name,"").trim()||e[s]||h(M(n.payload)?n.payload.actor_name:"",""),r=M(n.payload)?n.payload:{},u=h(n.ts,h(n.timestamp,new Date().toISOString())),d=h(n.phase,h(r.phase,"")),v=h(n.category,"");return{type:a,actor:i||s||h(r.actor_name,""),actor_id:s||h(r.actor_id,""),actor_name:i,seq:n.seq,room_id:h(n.room_id,""),phase:d||void 0,category:v||Hc(a),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:Kc(a,s,i,r),dice_roll:Fc(a,r),timestamp:u}}function Bc(t,e,n){var et,lt;const a=h(t.room_id,"")||n||"default",s=M(t.state)?t.state:{},i=M(s.party)?s.party:{},r=M(s.actor_control)?s.actor_control:{},u=M(s.join_gate)?s.join_gate:{},d=M(s.contribution_ledger)?s.contribution_ledger:{},v=Object.entries(i).map(([O,J])=>{const k=M(J)?J:{},Lt=At(k,"max_hp",void 0,10),ee=At(k,"hp",void 0,Lt),pe=At(k,"max_mp",void 0,0),E=At(k,"mp",void 0,0),It=At(k,"level",void 0,1),ve=At(k,"xp",void 0,0),Gn=Vs(k.alive,ee>0),tn=r[O],f=typeof tn=="string"?tn:void 0,R=Mc(k.role,O,f),q=Ec(k.generation),at=ct(k.joined_at,k.joinedAt,k.started_at,k.startedAt),j=ct(k.claimed_at,k.claimedAt,k.assigned_at,k.assignedAt,k.assigned_time),vt=ct(k.last_seen,k.lastSeen,k.last_seen_at,k.lastSeenAt,k.last_active,k.lastActive),Y=ct(k.scene,k.current_scene,k.currentScene,k.world_scene,k.scene_name,k.sceneName),V=ct(k.location,k.current_location,k.currentLocation,k.position,k.zone,k.area);return{id:O,name:h(k.name,O),role:R,keeper:f,archetype:h(k.archetype,""),persona:h(k.persona,""),portrait:h(k.portrait,"")||void 0,background:h(k.background,"")||void 0,traits:en(k.traits),skills:en(k.skills),stats_raw:jc(k),status:Gn?"active":"dead",generation:q,joined_at:at||void 0,claimed_at:j||void 0,last_seen:vt||void 0,scene:Y||void 0,location:V||void 0,inventory:en(k.inventory),notes:en(k.notes),relationships:Oc(k.relationships),stats:{hp:ee,max_hp:Lt,mp:E,max_mp:pe,level:It,xp:ve,strength:At(k,"strength","str",10),dexterity:At(k,"dexterity","dex",10),constitution:At(k,"constitution","con",10),intelligence:At(k,"intelligence","int",10),wisdom:At(k,"wisdom","wis",10),charisma:At(k,"charisma","cha",10)}}}),p=v.filter(O=>O.status!=="dead"),l=Ic(t,e),c={phase_open:Vs(u.phase_open,!0),min_points:F(u.min_points,3),window:h(u.window,"round_boundary_only"),last_opened_turn:typeof u.last_opened_turn=="number"?u.last_opened_turn:null,last_closed_turn:typeof u.last_closed_turn=="number"?u.last_closed_turn:null},m=Object.entries(d).map(([O,J])=>{const k=M(J)?J:{};return{actor_id:O,score:F(k.score,0),last_reason:h(k.last_reason,"")||null,reasons:en(k.reasons)}}),$=v.reduce((O,J)=>(O[J.id]=J.name,O),{}),b=e.map(O=>Uc(O,$)),x=F(s.turn,1),D=h(s.phase,"round"),T=h(s.map,""),z=M(s.world)?s.world:{},C=T||h(z.ascii_map,h(z.map,"")),L=b.filter((O,J)=>{const k=e[J];if(!M(k))return!1;const Lt=M(k.payload)?k.payload:{};return F(Lt.turn,-1)===x}),tt=(L.length>0?L:b).slice(-12),xt=h(s.status,"active");return{session:{id:a,room:a,status:xt==="ended"?"ended":xt==="paused"?"paused":"active",round:x,actors:p,created_at:((et=b[0])==null?void 0:et.timestamp)??new Date().toISOString()},current_round:{round_number:x,phase:D,events:tt,timestamp:((lt=b[b.length-1])==null?void 0:lt.timestamp)??new Date().toISOString()},map:C||void 0,join_gate:c,contribution_ledger:m,outcome:l,party:p,story_log:b,history:[]}}async function Wc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Tt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Gc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([Tt(`/api/v1/trpg/state${e}`),Wc(t)]);return Bc(n,a,t)}function Jc(t){return Ut("/api/v1/trpg/rounds/run",{room_id:t})}function Vc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Qc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Ut("/api/v1/trpg/dice/roll",e)}function Yc(t,e){const n=Vc();return Ut("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Xc(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Ut("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function Zc(t,e,n){return Ut("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function tu(t,e,n){const a=await kt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function eu(t){const e=await kt("trpg.mid_join.request",t);return JSON.parse(e)}async function Mr(t,e){await kt("masc_broadcast",{agent_name:t,message:e})}async function nu(t,e,n=1){await kt("masc_add_task",{title:t,description:e,priority:n})}async function au(t){return kt("masc_join",{agent_name:t})}async function zr(t){await kt("masc_leave",{agent_name:t})}async function su(t){await kt("masc_heartbeat",{agent_name:t})}async function iu(t=40){return(await kt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function ou(t,e=20){return kt("masc_task_history",{task_id:t,limit:e})}async function ru(){return Ye("fetchDebates",async()=>{const t=await Tt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!M(e))return null;const n=h(e.id,"").trim(),a=h(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:h(e.status,"open"),argument_count:F(e.argument_count,0),created_at:Be(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function lu(){return Ye("fetchCouncilSessions",async()=>{const t=await Tt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!M(e))return null;const n=h(e.id,"").trim(),a=h(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:h(e.initiator,"system"),votes:F(e.votes,0),quorum:F(e.quorum,0),state:h(e.state,"open"),created_at:Be(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function cu(t){const e=await kt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function uu(t){return Ye("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await Tt(`/api/v1/council/debates/${e}/summary`);if(!M(n))return null;const a=h(n.id,"").trim();return a?{id:a,topic:h(n.topic,""),status:h(n.status,"open"),support_count:F(n.support_count,0),oppose_count:F(n.oppose_count,0),neutral_count:F(n.neutral_count,0),total_arguments:F(n.total_arguments,0),created_at:Be(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function du(t,e,n){return kt("masc_keeper_msg",{name:t,message:e})}async function pu(){try{const t=await kt("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const dn=g(""),Qt=g({}),dt=g({}),Qs=g({}),Ys=g({}),Xs=g({}),Zs=g({}),Yt=g({});function ot(t,e,n){t.value={...t.value,[e]:n}}function Xt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function B(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Rt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ie(t){return typeof t=="boolean"?t:void 0}function ti(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function ei(t){return Array.isArray(t)?t.map(e=>B(e)).filter(e=>!!e):[]}function vu(t){var n;const e=(n=B(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function mu(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function ls(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Xt(a))continue;const s=B(a.name);if(!s)continue;const i=B(a[e]);e==="summary"?n.push({name:s,summary:i}):n.push({name:s,reason:i})}return n}function fu(t){if(!Xt(t))return null;const e=B(t.name);return e?{name:e,trigger:B(t.trigger),outcome:B(t.outcome),summary:B(t.summary),reason:B(t.reason)}:null}function _u(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function gu(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function jr(t,e,n){return B(t)??gu(e,n)}function Fr(t,e){return typeof t=="boolean"?t:e==="recover"}function ka(t){if(!Xt(t))return null;const e=B(t.health_state),n=B(t.next_action_path),a=B(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:B(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:ti(t.last_reply_at),last_reply_preview:B(t.last_reply_preview)??null,last_error:B(t.last_error)??null,next_eligible_at_s:Rt(t.next_eligible_at_s)??null,recoverable:Fr(t.recoverable,n),summary:jr(t.summary,e,B(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function ji(t){return Xt(t)?{hour:Rt(t.hour),checked:Rt(t.checked)??0,acted:Rt(t.acted)??0,acted_names:ei(t.acted_names),activity_report:B(t.activity_report),quiet_hours_overridden:Ie(t.quiet_hours_overridden),skipped_reason:B(t.skipped_reason),acted_rows:ls(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:ls(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:ls(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(fu).filter(e=>e!==null):[]}:null}function hu(t){return Xt(t)?{enabled:Ie(t.enabled)??!1,interval_s:Rt(t.interval_s)??0,quiet_start:Rt(t.quiet_start),quiet_end:Rt(t.quiet_end),quiet_active:Ie(t.quiet_active),use_planner:Ie(t.use_planner),delegate_llm:Ie(t.delegate_llm),agent_count:Rt(t.agent_count),agents:ei(t.agents),last_tick_ago_s:Rt(t.last_tick_ago_s)??null,last_tick_ago:B(t.last_tick_ago),total_ticks:Rt(t.total_ticks),total_checkins:Rt(t.total_checkins),last_skip_reason:B(t.last_skip_reason)??null,last_tick_result:ji(t.last_tick_result),active_self_heartbeats:ei(t.active_self_heartbeats)}:null}function $u(t){return Xt(t)?{status:t.status,diagnostic:ka(t.diagnostic)}:null}function yu(t){return Xt(t)?{recovered:Ie(t.recovered)??!1,skipped_reason:B(t.skipped_reason)??null,before:ka(t.before),after:ka(t.after),down:t.down,up:t.up}:null}function bu(t,e){var T,z;if(!(t!=null&&t.name))return null;const n=B((T=t.agent)==null?void 0:T.status)??B(t.status)??"unknown",a=B((z=t.agent)==null?void 0:z.error)??null,s=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,u=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,v=t.proactive_cooldown_sec??0,p=t.last_proactive_ago_s??null,l=d&&p!=null?Math.max(0,v-p):null,c=r<=0||u==null?"never":u>900?"stale":"fresh",m=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,$=a??(s&&!i?"keeper keepalive is not running":null),b=n==="offline"||n==="inactive"?"offline":$?"degraded":c==="stale"?"stale":c==="never"?"idle":"healthy",x=$?_u($):e!=null&&e.quiet_active&&c!=="fresh"?"quiet_hours":s&&!i?"disabled":r<=0?"never_started":l!=null&&l>0?"min_gap":c==="fresh"||c==="stale"?"no_recent_activity":"unknown",D=b==="offline"||b==="degraded"||b==="stale"?"recover":x==="quiet_hours"?"manual_lodge_poke":x==="unknown"?"probe":"direct_message";return{health_state:b,quiet_reason:x,next_action_path:D,last_reply_status:c,last_reply_at:m,last_reply_preview:null,last_error:$,next_eligible_at_s:l!=null&&l>0?l:null,recoverable:Fr(void 0,D),summary:jr(void 0,b,x),keepalive_running:i}}function ku(t,e){if(!Xt(t))return null;const n=vu(t.role),a=B(t.content)??B(t.preview);if(!a)return null;const s=ti(t.ts_unix)??ti(t.timestamp);return{id:`${n}-${s??"entry"}-${e}`,role:n,label:mu(n),text:a,timestamp:s,delivery:"history"}}function xu(t,e,n){const a=Xt(n)?n:null,s=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((i,r)=>ku(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:ka(a==null?void 0:a.diagnostic),history:s,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function _o(t,e){const n=dt.value[t]??[];dt.value={...dt.value,[t]:[...n,e].slice(-50)}}function Su(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Au(t,e){const a=(dt.value[t]??[]).filter(s=>s.delivery!=="history"&&!e.some(i=>Su(s,i)));dt.value={...dt.value,[t]:[...e,...a].slice(-50)}}function es(t,e){Qt.value={...Qt.value,[t]:e},Au(t,e.history)}function go(t,e){const n=Qt.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};es(t,{...n,diagnostic:{...a,...e}})}async function Fi(){We();try{await xe()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function la(t){dn.value=t.trim()}async function qr(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Qt.value[n])return Qt.value[n];ot(Qs,n,!0),ot(Yt,n,null);try{const a=await kt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let s=null;try{s=JSON.parse(a)}catch{s=null}const i=xu(n,a,s);return es(n,i),i}catch(a){const s=a instanceof Error?a.message:`Failed to inspect ${n}`;return ot(Yt,n,s),null}finally{ot(Qs,n,!1)}}async function wu(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const s=`local-${Date.now()}`;_o(n,{id:s,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),ot(Ys,n,!0),ot(Yt,n,null);try{const i=await du(n,a);dt.value={...dt.value,[n]:(dt.value[n]??[]).map(r=>r.id===s?{...r,delivery:"delivered"}:r)},_o(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),go(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await Fi()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw dt.value={...dt.value,[n]:(dt.value[n]??[]).map(u=>u.id===s?{...u,delivery:"error",error:r}:u)},go(n,{last_reply_status:"error",last_error:r}),ot(Yt,n,r),i}finally{ot(Ys,n,!1)}}async function Tu(t,e){const n=t.trim();if(!n)return null;ot(Xs,n,!0),ot(Yt,n,null);try{const a=await Kn({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),s=$u(a.result),i=(s==null?void 0:s.diagnostic)??null;if(i){const r=Qt.value[n];es(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await Fi(),i}catch(a){const s=a instanceof Error?a.message:`Failed to probe ${n}`;throw ot(Yt,n,s),a}finally{ot(Xs,n,!1)}}async function Cu(t,e){const n=t.trim();if(!n)return null;ot(Zs,n,!0),ot(Yt,n,null);try{const a=await Kn({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),s=yu(a.result),i=(s==null?void 0:s.after)??null;if(i){const r=Qt.value[n];es(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await Fi(),i}catch(a){const s=a instanceof Error?a.message:`Failed to recover ${n}`;throw ot(Yt,n,s),a}finally{ot(Zs,n,!1)}}const Zt=g([]),yt=g([]),be=g([]),Dt=g([]),ue=g(null),rn=g(null),ni=g(new Map),Ht=g([]),Rn=g("hot"),_e=g(!0),Hr=g(null),Wt=g(""),Dn=g([]),Ee=g(!1),Kr=g(new Map),ai=g("unknown"),si=g(null),ii=g(!1),Pn=g(!1),oi=g(!1),Oe=g(!1),Nu=g(null),ri=g(null),Ur=g(null),Br=g(null),Ru=bt(()=>Zt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle")),Wr=bt(()=>{const t=yt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function Du(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const s=a.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const Gr=bt(()=>{const t=new Map;for(const e of Dt.value)t.set(e.name,Du(e));return t}),Pu=12e4;function Lu(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const s=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof s=="number"?Date.now()-s*1e3:null}const Jr=bt(()=>{const t=Date.now(),e=new Set,n=ni.value;for(const a of Dt.value){const s=Lu(a,n);s!=null&&t-s>Pu&&e.add(a.name)}return e}),xa={},Iu=5e3;function We(){delete xa.compact,delete xa.full}function pt(t){return typeof t=="object"&&t!==null}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function S(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function $e(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function li(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Vr(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Eu(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Ou(t){if(!pt(t))return null;const e=y(t.name);return e?{name:e,status:Vr(t.status),current_task:y(t.current_task)??null,last_seen:y(t.last_seen),emoji:y(t.emoji),koreanName:y(t.koreanName)??y(t.korean_name),model:y(t.model),traits:$e(t.traits),interests:$e(t.interests),activityLevel:S(t.activityLevel)??S(t.activity_level),primaryValue:y(t.primaryValue)??y(t.primary_value)}:null}function Mu(t){if(!pt(t))return null;const e=y(t.id),n=y(t.title);return!e||!n?null:{id:e,title:n,status:Eu(t.status),priority:S(t.priority),assignee:y(t.assignee),description:y(t.description),created_at:y(t.created_at),updated_at:y(t.updated_at)}}function zu(t){if(!pt(t))return null;const e=y(t.from)??y(t.from_agent)??"system",n=y(t.content)??"",a=y(t.timestamp)??new Date().toISOString();return{id:y(t.id),seq:S(t.seq),from:e,content:n,timestamp:a,type:y(t.type)}}function ju(t){return Array.isArray(t)?t.map(e=>{if(!pt(e))return null;const n=S(e.ts_unix);if(n==null)return null;const a=pt(e.handoff)?e.handoff:null;return{ts:n,context_ratio:S(e.context_ratio)??0,context_tokens:S(e.context_tokens)??0,context_max:S(e.context_max)??0,latency_ms:S(e.latency_ms)??0,generation:S(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:S(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:S(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?S(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function ho(t){if(!pt(t))return null;const e=y(t.health_state),n=y(t.next_action_path),a=y(t.last_reply_status);if(!e||!n||!a)return null;const s=y(t.quiet_reason)??null,i=y(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":s==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":s==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":s==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:s,next_action_path:n,last_reply_status:a,last_reply_at:li(t.last_reply_at)??y(t.last_reply_at)??null,last_reply_preview:y(t.last_reply_preview)??null,last_error:y(t.last_error)??null,next_eligible_at_s:S(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:i,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Fu(t,e){return(Array.isArray(t)?t:pt(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!pt(a))return null;const s=pt(a.agent)?a.agent:null,i=pt(a.context)?a.context:null,r=pt(a.metrics_window)?a.metrics_window:void 0,u=y(a.name);if(!u)return null;const d=S(a.context_ratio)??S(i==null?void 0:i.context_ratio),v=y(a.status)??y(s==null?void 0:s.status)??"offline",p=Vr(v),l=y(a.model)??y(a.active_model)??y(a.primary_model),c=$e(a.skill_secondary),m=i?{source:y(i.source),context_ratio:S(i.context_ratio),context_tokens:S(i.context_tokens),context_max:S(i.context_max),message_count:S(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,$=s?{name:y(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:y(s.error),status:y(s.status),current_task:y(s.current_task)??null,last_seen:y(s.last_seen),last_seen_ago_s:S(s.last_seen_ago_s),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0,b=ju(a.metrics_series),x={name:u,emoji:y(a.emoji),koreanName:y(a.koreanName)??y(a.korean_name),agent_name:y(a.agent_name),trace_id:y(a.trace_id),model:l,primary_model:y(a.primary_model),active_model:y(a.active_model),next_model_hint:y(a.next_model_hint)??null,status:p,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:S(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:S(a.proactive_idle_sec),proactive_cooldown_sec:S(a.proactive_cooldown_sec),last_heartbeat:y(a.last_heartbeat)??y(s==null?void 0:s.last_seen),generation:S(a.generation),turn_count:S(a.turn_count)??S(a.total_turns),keeper_age_s:S(a.keeper_age_s),last_turn_ago_s:S(a.last_turn_ago_s),last_handoff_ago_s:S(a.last_handoff_ago_s),last_compaction_ago_s:S(a.last_compaction_ago_s),last_proactive_ago_s:S(a.last_proactive_ago_s),context_ratio:d,context_tokens:S(a.context_tokens)??S(i==null?void 0:i.context_tokens),context_max:S(a.context_max)??S(i==null?void 0:i.context_max),context_source:y(a.context_source)??y(i==null?void 0:i.source),context:m,traits:$e(a.traits),interests:$e(a.interests),primaryValue:y(a.primaryValue)??y(a.primary_value),activityLevel:S(a.activityLevel)??S(a.activity_level),memory_recent_note:y(a.memory_recent_note)??null,conversation_tail_count:S(a.conversation_tail_count),k2k_count:S(a.k2k_count),handoff_count_total:S(a.handoff_count_total)??S(a.trace_history_count),compaction_count:S(a.compaction_count),last_compaction_saved_tokens:S(a.last_compaction_saved_tokens),diagnostic:ho(a.diagnostic),skill_primary:y(a.skill_primary)??null,skill_secondary:c,skill_reason:y(a.skill_reason)??null,metrics_series:b.length>0?b:void 0,metrics_window:r,agent:$};return x.diagnostic=ho(a.diagnostic)??bu(x,(e==null?void 0:e.lodge)??null),x}).filter(a=>a!==null)}function qu(t){return pt(t)?{...t,lodge:hu(t.lodge)??void 0}:null}function Hu(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function Ku(t){if(!pt(t))return null;const e=S(t.iteration);if(e==null)return null;const n=S(t.metric_before)??0,a=S(t.metric_after)??n,s=pt(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:a,delta:S(t.delta)??a-n,changes:y(t.changes)??"",failed_attempts:y(t.failed_attempts)??"",next_suggestion:y(t.next_suggestion)??"",elapsed_ms:S(t.elapsed_ms)??0,cost_usd:S(t.cost_usd)??null,evidence:s?{worker_engine:(s.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:y(s.worker_model)??"",tool_call_count:S(s.tool_call_count)??0,tool_names:$e(s.tool_names)??[],session_id:y(s.session_id)??"",evidence_status:s.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Uu(t){var i,r;if(!pt(t))return null;const e=y(t.loop_id);if(!e)return null;const n=S(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(Ku).filter(u=>u!==null):[],s=S(t.current_metric)??((i=a[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:y(t.profile)??"unknown",status:Hu(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:y(t.error_message)??y(t.error_reason)??null,stop_reason:y(t.stop_reason)??y(t.reason)??null,current_iteration:S(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:S(t.max_iterations)??0,baseline_metric:n,current_metric:s,target:y(t.target)??"",stagnation_streak:S(t.stagnation_streak)??0,stagnation_limit:S(t.stagnation_limit)??0,elapsed_seconds:S(t.elapsed_seconds)??0,updated_at:li(t.updated_at)??null,stopped_at:li(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:y(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:S(t.latest_tool_call_count)??0,latest_tool_names:$e(t.latest_tool_names)??[],session_id:y(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:a}}async function xe(t="full"){var a,s,i;const e=Date.now(),n=xa[t];if(!(n&&e-n.time<Iu)){ii.value=!0;try{const r=await gc(t);xa[t]={data:r,time:e},Zt.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(Ou).filter(d=>d!==null),yt.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(Mu).filter(d=>d!==null),be.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(zu).filter(d=>d!==null);const u=qu(r.status);ue.value=u,Dt.value=Fu(r.keepers,u),rn.value=r.perpetual??null,Nu.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{ii.value=!1}}}async function Gt(){Pn.value=!0;try{const t=await Rc(Rn.value,{excludeSystem:_e.value});Ht.value=t.posts??[],ri.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Pn.value=!1}}async function Jt(){var t;oi.value=!0;try{const e=Wt.value||((t=ue.value)==null?void 0:t.room)||"default";Wt.value||(Wt.value=e);const n=await Gc(e);Hr.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{oi.value=!1}}async function Sa(){Ee.value=!0;try{const t=await pu();Dn.value=Array.isArray(t)?t:[],Ur.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Ee.value=!1}}async function Ln(){Oe.value=!0;try{const t=await hc(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const a of e){const s=Uu(a);s&&n.set(s.loop_id,s)}Kr.value=n,Br.value=new Date().toISOString(),si.value=null,ai.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),ai.value="error",si.value=t instanceof Error?t.message:String(t)}finally{Oe.value=!1}}let ca=null;function Bu(t){ca=t}let cs=null,us=null,je=null,Fe=null;function Wu(){je||(je=setTimeout(()=>{ca==null||ca(),je=null},500))}function Gu(){Fe||(Fe=setTimeout(()=>{Ln(),Fe=null},350))}function Ju(){const t=Nr.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(ni.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),ni.value=n}We(),cs||(cs=setTimeout(()=>{xe(),cs=null},500)),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&(us||(us=setTimeout(()=>{Gt(),us=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&We(),e.type.startsWith("decision_")&&Wu(),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&Gu()}});return()=>{t(),je&&(clearTimeout(je),je=null),Fe&&(clearTimeout(Fe),Fe=null)}}let pn=null;function Vu(){pn||(pn=setInterval(()=>{We(),xe()},1e4))}function Qu(){pn&&(clearInterval(pn),pn=null)}function w({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function Pt({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Yu(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function U({timestamp:t}){const e=Yu(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function Z(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function st(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Ge(t){return(t??"").trim().toLowerCase()}function ut(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function jt(t){return typeof t!="number"||Number.isNaN(t)?3:t}function qi(t){const e=jt(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}function me(t){return(t??"").trim().toLowerCase()}function _t(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ua(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Qn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function nn(t){return t.last_heartbeat??Qn(t.last_turn_ago_s)??Qn(t.last_proactive_ago_s)??Qn(t.last_handoff_ago_s)??Qn(t.last_compaction_ago_s)}function Xu(t){const e=t.title.trim();return e||ua(t.content)}function Zu(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function In(t,e,n,a,s={}){var z;const i=me(t),r=e.filter(C=>me(C.assignee)===i&&(C.status==="claimed"||C.status==="in_progress")).length,u=n.filter(C=>me(C.from)===i).sort((C,L)=>_t(L.timestamp)-_t(C.timestamp))[0],d=a.filter(C=>me(C.agent)===i||me(C.author)===i).sort((C,L)=>_t(L.timestamp)-_t(C.timestamp))[0],v=(s.boardPosts??[]).filter(C=>me(C.author)===i).sort((C,L)=>_t(L.updated_at||L.created_at)-_t(C.updated_at||C.created_at))[0],p=(s.keepers??[]).filter(C=>me(C.name)===i&&nn(C)!==null).sort((C,L)=>_t(nn(L)??0)-_t(nn(C)??0))[0],l=u?_t(u.timestamp):0,c=d?_t(d.timestamp):0,m=v?_t(v.updated_at||v.created_at):0,$=p?_t(nn(p)??0):0,b=s.lastSeen?_t(s.lastSeen):0,x=((z=s.currentTask)==null?void 0:z.trim())||(r>0?`${r} claimed tasks`:null);if(l===0&&c===0&&m===0&&$===0&&b===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:x};const T=[u?{timestamp:u.timestamp,ts:l,text:ua(u.content)}:null,v?{timestamp:v.updated_at||v.created_at,ts:m,text:`Post: ${ua(Xu(v))}`}:null,p?{timestamp:nn(p),ts:$,text:Zu(p)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:c,text:ua(d.text)}:null].filter(C=>C!==null).sort((C,L)=>L.ts-C.ts)[0];return T&&T.ts>=b?{activeAssignedCount:r,lastActivityAt:T.timestamp,lastActivityText:T.text}:{activeAssignedCount:r,lastActivityAt:s.lastSeen??null,lastActivityText:x??"Presence heartbeat"}}let td=0;const ge=g([]);function A(t,e="success",n=4e3){const a=++td;ge.value=[...ge.value,{id:a,message:t,type:e}],setTimeout(()=>{ge.value=ge.value.filter(s=>s.id!==a)},n)}function ed(t){ge.value=ge.value.filter(e=>e.id!==t)}function nd(){const t=ge.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>ed(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const ad="masc_dashboard_agent_name",Xe=g(null),Aa=g(!1),En=g(""),wa=g([]),On=g([]),qe=g(""),vn=g(!1);function He(t){Xe.value=t,Hi()}function $o(){Xe.value=null,En.value="",wa.value=[],On.value=[],qe.value=""}function sd(){const t=Xe.value;return t?Zt.value.find(e=>e.name===t)??null:null}function Qr(t){return t?yt.value.filter(e=>e.assignee===t):[]}async function Hi(){const t=Xe.value;if(t){Aa.value=!0,En.value="",wa.value=[],On.value=[];try{const e=await iu(80);wa.value=e.filter(s=>s.includes(t)).slice(0,20);const n=Qr(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await ou(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));On.value=a}catch(e){En.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Aa.value=!1}}}async function yo(){var a;const t=Xe.value,e=qe.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(ad))==null?void 0:a.trim())||"dashboard";vn.value=!0;try{await Mr(n,`@${t} ${e}`),qe.value="",A(`Mention sent to ${t}`,"success"),Hi()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";A(i,"error")}finally{vn.value=!1}}function id({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Pt} status=${t.status} />
    </div>
  `}function od({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function rd(){var s,i,r,u;const t=Xe.value;if(!t)return null;const e=sd(),n=Qr(t),a=wa.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&$o()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${e!=null&&e.emoji?o`<span style="font-size:2rem">${e.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${t}
                  ${e!=null&&e.koreanName?o`<span style="font-size:0.75em;color:#888">(${e.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${e?o`
                        <${Pt} status=${e.status} />
                        ${e.model?o`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                        ${e.primaryValue?o`<span style="font-size:0.75rem;color:#a78bfa">${e.primaryValue}</span>`:""}
                      `:o`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(e==null?void 0:e.activityLevel)!=null?o`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(e.activityLevel*10,100)}%;height:100%;background:${e.activityLevel>=8?"#22c55e":e.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${e.activityLevel}/10</span>
              </div>
            `:""}
            ${(((s=e==null?void 0:e.traits)==null?void 0:s.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(d=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(u=e==null?void 0:e.interests)==null?void 0:u.map(d=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${U} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Hi()}} disabled=${Aa.value}>
              ${Aa.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${$o}>Close</button>
          </div>
        </div>

        ${En.value?o`<div class="council-error">${En.value}</div>`:null}

        <div class="agent-detail-grid">
          <${w} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${id} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${w} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((d,v)=>o`<div key=${v} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${w} title="Task History">
          ${On.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${On.value.map(d=>o`<${od} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${w} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${qe.value}
              onInput=${d=>{qe.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&yo()}}
              disabled=${vn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{yo()}}
              disabled=${vn.value||qe.value.trim()===""}
            >
              ${vn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const Ta=600*1e3,da=1200*1e3;function Yr(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function Xr(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function ld(t){return t.updated_at??t.created_at??null}function cd(t){const e=new Map;for(const n of t)e.set(Ge(n.name),In(n.name,yt.value,be.value,le.value,{currentTask:n.current_task,lastSeen:n.last_seen,boardPosts:Ht.value,keepers:Dt.value}));return e}function bo(t,e,n){var x,D;const a=Ge(t.assignee),s=a?e.get(a)??null:null,i=s?n.get(a)??null:null,r=(i==null?void 0:i.lastActivityAt)??(s==null?void 0:s.last_seen)??null,u=r?Math.max(0,Date.now()-Z(r)):Number.POSITIVE_INFINITY,d=ut(t.description),v=ut(s==null?void 0:s.current_task)??(i==null?void 0:i.lastActivityText)??null,p=t.status==="claimed"||t.status==="in_progress";let l="ok",c="Fresh owner coverage",m=v??d??t.id,$=!1,b=!1;return t.status==="todo"?t.assignee?s?s.status==="offline"||s.status==="inactive"?($=!0,l="bad",c="Assigned owner is offline",m="Queue item is blocked until ownership changes."):u>Ta?(l="warn",c="Owner exists but live signal is quiet",m=v??"Owner may need a nudge before pickup."):((i==null?void 0:i.activeAssignedCount)??0)>0||(x=s.current_task)!=null&&x.trim()?(l="warn",c="Owner is already carrying active work",m=v??`${(i==null?void 0:i.activeAssignedCount)??0} active tasks already assigned.`):(c="Ready and covered by a fresh operator",m=v??d??"This can be picked up immediately."):($=!0,l="bad",c="Assigned owner is not present in the room",m="Reassign or bring the owner back online."):($=!0,l=jt(t.priority)<=2?"bad":"warn",c=jt(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",m="Assign an agent before this queue item slips."):p&&(t.assignee?s?s.status==="offline"||s.status==="inactive"?($=!0,l="bad",c="Assigned owner is offline",m=v??"Execution has no live operator right now."):u>da?(b=!0,l="bad",c="Assigned owner has gone quiet",m=v??"Fresh operator signal is missing."):u>Ta?(b=!0,l="warn",c="Execution has been quiet for too long",m=v??"Check whether this work is blocked."):(D=s.current_task)!=null&&D.trim()?(c="Execution has fresh owner coverage",m=v??d??t.id):(l="warn",c=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",m=v??"Task state and agent focus are drifting apart."):($=!0,l="bad",c="Assigned owner is not active in the room",m="Execution is orphaned until ownership is restored."):($=!0,l="bad",c="Active work has no assignee",m="Claim or reassign this task immediately.")),{task:t,assigneeAgent:s,motion:i,tone:l,note:c,focus:m,lastSignalAt:r,lastTouchedAt:ld(t),ownerGap:$,quiet:b}}function ud(t,e){var c;const n=e.get(Ge(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,s=a?Math.max(0,Date.now()-Z(a)):Number.POSITIVE_INFINITY,i=!!((c=t.current_task)!=null&&c.trim()),r=n.activeAssignedCount,u=i||r>0;let d="loaded",v="ok",p="Healthy active load",l=ut(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(d="offline",v="bad",p="Agent is unavailable"):u&&s>da?(d="quiet",v="bad",p="Working without a fresh signal"):r>0&&!i?(d="drift",v="warn",p="Claimed work exists but current_task is empty",l=`${r} active tasks need explicit focus.`):i&&r===0?(d="drift",v="warn",p="current_task has no matching claimed work",l=ut(t.current_task)??"Task metadata and operator state drifted."):!u&&s<=Ta?(d="dispatchable",v="ok",p="Fresh signal and no active load",l=n.lastActivityText??"Ready for assignment."):u?s>Ta&&(d="loaded",v="warn",p="Execution load is healthy but slightly quiet",l=ut(t.current_task)??`${r} active tasks in flight.`):(d="quiet",v=s>da?"bad":"warn",p=s>da?"No fresh signal while idle":"Reachable, but not freshly active",l=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:v,state:d,note:p,focus:l,lastSignalAt:a,activeTaskCount:r}}function an({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function dd({item:t}){return o`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?qi(t.taskRow.task.priority):Xr(t.agentRow.state)}
        </span>
        ${t.kind==="task"?o`<span>${Yr(t.taskRow.task.status)}</span>`:o`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?o`<span><${U} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </div>
  `}function ko({row:t}){var e;return o`
    <div class="execution-task-row ${t.tone}">
      <div class="monitor-row-header">
        <span class="monitor-pill ${t.tone}">${qi(t.task.priority)}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.task.title}</span>
            <span class="monitor-sub">${t.task.id}</span>
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        ${t.assigneeAgent?o`<${Pt} status=${t.assigneeAgent.status} />`:o`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${Yr(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?o`<span>Owner ${t.task.assignee}</span>`:o`<span>Unassigned</span>`}
        ${t.lastTouchedAt?o`<span>Touched <${U} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?o`<span>Signal <${U} timestamp=${t.lastSignalAt} /></span>`:o`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&ut(t.assigneeAgent.current_task)!==t.focus?o`<div class="monitor-footnote">Owner focus: ${ut(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function pd({row:t}){const{agent:e}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>He(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Pt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Xr(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${U} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
  `}function vd(){const t=Zt.value,e=yt.value,n=new Map(t.map(l=>[Ge(l.name),l])),a=cd(t),s=e.filter(l=>l.status==="claimed"||l.status==="in_progress").map(l=>bo(l,n,a)).sort((l,c)=>{const m=st(c.tone)-st(l.tone);return m!==0?m:Z(c.lastSignalAt??c.lastTouchedAt)-Z(l.lastSignalAt??l.lastTouchedAt)}),i=e.filter(l=>l.status==="todo").map(l=>bo(l,n,a)).sort((l,c)=>{const m=st(c.tone)-st(l.tone);if(m!==0)return m;const $=jt(l.task.priority)-jt(c.task.priority);return $!==0?$:Z(l.lastTouchedAt)-Z(c.lastTouchedAt)}),r=t.map(l=>ud(l,a)).filter(l=>l.state==="dispatchable"||l.state==="drift"||l.state==="quiet").sort((l,c)=>{if(l.state==="dispatchable"&&c.state!=="dispatchable")return-1;if(c.state==="dispatchable"&&l.state!=="dispatchable")return 1;const m=st(c.tone)-st(l.tone);return m!==0?m:Z(c.lastSignalAt)-Z(l.lastSignalAt)}),u=[...s.filter(l=>l.tone!=="ok").map(l=>({kind:"task",key:`active-${l.task.id}`,tone:l.tone,title:l.task.title,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastSignalAt??l.lastTouchedAt,taskRow:l})),...i.filter(l=>l.tone==="bad").map(l=>({kind:"task",key:`ready-${l.task.id}`,tone:l.tone,title:l.task.title,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastTouchedAt,taskRow:l})),...r.filter(l=>l.state==="drift"||l.tone==="bad").map(l=>({kind:"agent",key:`agent-${l.agent.name}`,tone:l.tone,title:l.agent.name,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastSignalAt,agentRow:l}))].sort((l,c)=>{const m=st(c.tone)-st(l.tone);return m!==0?m:Z(c.timestamp)-Z(l.timestamp)}).slice(0,8),d=r.filter(l=>l.state==="dispatchable"),v=[...s,...i].filter(l=>l.ownerGap),p=s.filter(l=>l.quiet);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${an} label="Active work" value=${s.length} color="#fbbf24" caption="claimed + in progress" />
        <${an} label="Needs intervention" value=${u.length} color=${u.length>0?"#fb7185":"#4ade80"} caption="stalled or drifting now" />
        <${an} label="Ownership gaps" value=${v.length} color=${v.length>0?"#fb7185":"#4ade80"} caption="missing or unavailable owners" />
        <${an} label="Dispatchable agents" value=${d.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${an} label="Quiet execution" value=${p.length} color=${p.length>0?"#fbbf24":"#4ade80"} caption="active tasks with aging signals" />
      </div>

      <${w} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${u.length===0?o`<div class="empty-state">No active execution risks right now</div>`:u.map(l=>o`<${dd} key=${l.key} item=${l} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${w} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${i.length===0?o`<div class="empty-state">No ready tasks in the queue</div>`:i.slice(0,10).map(l=>o`<${ko} key=${l.task.id} row=${l} />`)}
          </div>
        <//>

        <${w} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?o`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(l=>o`<${pd} key=${l.agent.name} row=${l} />`)}
          </div>
        <//>
      </div>

      <${w} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${s.length===0?o`<div class="empty-state">No active execution tasks</div>`:s.map(l=>o`<${ko} key=${l.task.id} row=${l} />`)}
        </div>
      <//>
    </div>
  `}function md(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function fd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function _d(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function xo(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Zr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function gd(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function tl(t){if(!t)return null;const e=Qt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function el({keeper:t,showRawStatus:e=!1}){if(qt(()=>{t!=null&&t.name&&qr(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Qt.value[t.name],a=tl(t),s=Qs.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${md(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${fd((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${s?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?o` · ${Zr(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?o` · next eligible ${gd(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?o`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function nl({keeperName:t,placeholder:e}){const[n,a]=pr("");qt(()=>{t&&qr(t)},[t]);const s=dt.value[t]??[],i=Ys.value[t]??!1,r=Yt.value[t],u=async()=>{const d=n.trim();if(!(!t||!d)){a("");try{await wu(t,d)}catch(v){const p=v instanceof Error?v.message:`Failed to message ${t}`;A(p,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${s.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:s.map(d=>o`
              <div class="keeper-conversation-item" key=${d.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${xo(d)}`}>${d.label}</span>
                  <span class=${`keeper-role-chip ${xo(d)}`}>${_d(d)}</span>
                  ${d.timestamp?o`<span class="keeper-conversation-time">${Zr(d.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${d.text}</div>
                ${d.error?o`<div class="keeper-conversation-error">${d.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${d=>{a(d.target.value)}}
          disabled=${i||!t}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{u()}}
            disabled=${i||n.trim()===""||!t}
          >
            ${i?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${r?o`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function al({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=tl(e),s=Xs.value[e.name]??!1,i=Zs.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message",u=(a==null?void 0:a.recoverable)??r==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{Tu(e.name,t).catch(d=>{const v=d instanceof Error?d.message:`Failed to probe ${e.name}`;A(v,"error")})}}
        disabled=${s||!t.trim()}
      >
        ${s?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{Cu(e.name,t).catch(d=>{const v=d instanceof Error?d.message:`Failed to recover ${e.name}`;A(v,"error")})}}
        disabled=${i||!u||!t.trim()}
      >
        ${i?"Recovering...":"Recover"}
      </button>
      <button
        class=${`control-btn ghost ${r==="manual_lodge_poke"?"is-active":""}`}
        onClick=${n}
      >
        Poke Lodge
      </button>
    </div>
  `}const Ki=g(null);function Ca(t){Ki.value=t,la(t.name)}function So(){Ki.value=null}const De=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function hd(t){if(!t)return 0;const e=De.findIndex(n=>n.level===t);return e>=0?e:0}function $d({keeper:t}){const e=hd(t.autonomy_level),n=De[e]??De[0];if(!n)return null;const a=(e+1)/De.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${De.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${De.map((s,i)=>o`
            <span style="width:8px; height:8px; border-radius:50%; background:${i<=e?s.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?o`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${U} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function pa(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function yd({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${s.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${pa(t.context_tokens)}</div>
        <div class="kpi-label">Tokens</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${t.handoff_count_total??"—"}</div>
        <div class="kpi-label">Handoffs</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${t.compaction_count??"—"}</div>
        <div class="kpi-label">Compactions</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${a}</div>
        <div class="kpi-label">Cost (USD)</div>
      </div>
    </div>
  `}function bd({keeper:t}){var p,l;const e=t.metrics_series??[];if(e.length<2){const c=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,m=c>85?"#ef4444":c>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${c.toFixed(1)}%;background:${m}"></div>
        </div>
        <span class="chart-pct">${c.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,i=e.length,r=e.map((c,m)=>{const $=s+m/(i-1)*(n-2*s),b=a-s-(c.context_ratio??0)*(a-2*s);return{x:$,y:b,p:c}}),u=r.map(({x:c,y:m})=>`${c.toFixed(1)},${m.toFixed(1)}`).join(" "),d=(((l=e[e.length-1])==null?void 0:l.context_ratio)??0)*100,v=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:c})=>c.is_handoff).map(({x:c})=>o`
          <line x1="${c.toFixed(1)}" y1="${s}" x2="${c.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${u}" fill="none" stroke="${v}" stroke-width="1.5"/>
        ${r.filter(({p:c})=>c.is_compaction).map(({x:c,y:m})=>o`
          <circle cx="${c.toFixed(1)}" cy="${m.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const ds=g("");function kd({keeper:t}){var s,i,r,u;const e=ds.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ds.value}
        onInput=${d=>{ds.value=d.target.value}}
      />
      ${a.map(d=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${d.title}</span>
          <span class="keeper-field-key">${d.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${d.value}</span>
        </div>
      `)}
      ${t.trace_id?o`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${t.trace_id}</span></div>`:""}
      ${t.agent_name?o`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${t.agent_name}</span></div>`:""}
      ${t.primary_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.primary_model}</span></div>`:""}
      ${t.active_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.active_model}</span></div>`:""}
      ${t.next_model_hint?o`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.next_model_hint}</span></div>`:""}
      ${t.skill_primary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_primary}</span></div>`:""}
      ${t.skill_secondary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_secondary}</span></div>`:""}
      ${t.skill_reason?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_reason}</span></div>`:""}
      ${t.context_source?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${t.context_source}</span></div>`:""}
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${pa(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${pa(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${pa(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((u=t.context)==null?void 0:u.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function xd({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
    <div>
      <div style="display: flex; gap: 12px; margin-bottom: 10px;">
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">HP ${t.hp}/${t.max_hp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${e}%; height:100%; background:${e>50?"#4ade80":e>25?"#fbbf24":"#ef4444"}; border-radius:3px;" />
          </div>
        </div>
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">MP ${t.mp}/${t.max_mp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${n}%; height:100%; background:#818cf8; border-radius:3px;" />
          </div>
        </div>
      </div>
      <div style="display:grid; grid-template-columns: repeat(3,1fr); gap:6px;">
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(a=>o`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${a.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${a.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        Level ${t.level} — XP ${t.xp}
      </div>
    </div>
  `}function Sd({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Ad({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Ao({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ps(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function wd({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:ps(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ps(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ps(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function sl(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Td(){try{const t=await Kn({actor:sl(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=ji(t.result);We(),await xe(),e!=null&&e.skipped_reason?A(e.skipped_reason,"warning"):A(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";A(e,"error")}}function Cd({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${el} keeper=${t} />
          <${al}
            actor=${sl()}
            keeper=${t}
            onPokeLodge=${()=>{Td()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${nl}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Nd(){var e,n,a;const t=Ki.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&So()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?o`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${Pt} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>So()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${yd} keeper=${t} />

        ${""}
        <${bd} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${w} title="Field Dictionary">
            <${kd} keeper=${t} />
          <//>

          ${""}
          <${w} title="Profile">
            <${Ao} traits=${t.traits??[]} label="Traits" />
            <${Ao} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${U} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${w} title="Autonomy">
                <${$d} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${w} title="TRPG Stats">
                <${xd} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${w} title="Equipment (${t.inventory.length})">
                <${Sd} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${w} title="Relationships (${Object.keys(t.relationships).length})">
                <${Ad} rels=${t.relationships} />
              <//>
            `:null}

          <${w} title="Runtime Signals">
            <${wd} keeper=${t} />
          <//>

          <${w} title="Memory & Context">
            <div class="keeper-signal-list">
              <div class="keeper-signal-row">
                <span>Context source</span>
                <strong>${t.context_source??((e=t.context)==null?void 0:e.source)??"-"}</strong>
              </div>
              <div class="keeper-signal-row">
                <span>Context tokens</span>
                <strong>
                  ${t.context_tokens??((n=t.context)==null?void 0:n.context_tokens)??"-"}
                  /
                  ${t.context_max??((a=t.context)==null?void 0:a.context_max)??"-"}
                </strong>
              </div>
              ${t.memory_recent_note?o`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:o`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${Cd} keeper=${t} />
      </div>
    </div>
  `:null}const Je=g(!1);function Rd(){Je.value=!0}function wo(){Je.value=!1}function Dd(){Je.value=!Je.value}const vs=600*1e3,ms=1200*1e3,To=.8,fs=g("triage");function Ce(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function Yn(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function Co(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function No(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Pd(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function _s(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Ld(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Id(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Ed(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Od(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Co(t.quiet_start)}-${Co(t.quiet_end)} KST are active.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${No(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${No(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function Ro(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function Ne({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Md({item:t}){return o`
    <button class="monitor-alert ${t.tone}" onClick=${t.action}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.detail}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">${t.tone==="bad"?"Act now":t.tone==="warn"?"Watch":"Stable"}</span>
        ${t.timestamp?o`<span><${U} timestamp=${t.timestamp} /></span>`:null}
      </div>
    </button>
  `}function gs({tone:t,title:e,subtitle:n,meta:a,focus:s,onClick:i}){return o`
    <button class="monitor-row ${t}" onClick=${i}>
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e}</span>
            <span class="monitor-sub">${n}</span>
          </div>
        </div>
        <span class="monitor-pill ${t}">${t==="bad"?"Alert":t==="warn"?"Watch":"Ready"}</span>
      </div>
      <div class="monitor-meta">
        ${a.map(r=>o`<span>${r}</span>`)}
      </div>
      <div class="monitor-focus">${s}</div>
    </button>
  `}function Do(){var L,tt,xt,ft,et,lt,O,J,k,Lt,ee,pe,E,It,ve,Gn,tn;const t=ue.value,e=Zt.value,n=yt.value,a=Dt.value,s=Wr.value,i=(L=t==null?void 0:t.monitoring)==null?void 0:L.board,r=(tt=t==null?void 0:t.monitoring)==null?void 0:tt.council,u=Vt.value,d=new Map(e.map(f=>[Ge(f.name),f])),v=e.map(f=>{var Vi;const R=In(f.name,n,be.value,le.value,{currentTask:f.current_task,lastSeen:f.last_seen,boardPosts:Ht.value,keepers:a}),q=R.lastActivityAt??f.last_seen??null,at=q?Math.max(0,Date.now()-Z(q)):Number.POSITIVE_INFINITY,j=R.activeAssignedCount,vt=!!((Vi=f.current_task)!=null&&Vi.trim()),Y=vt||j>0;let V="ok",St="Fresh and ready",Ae=!1,we=!1;return f.status==="offline"||f.status==="inactive"?(V=Y?"bad":"warn",St=Y?"Load without an available owner":"Offline"):Y&&at>ms?(V="bad",St="Execution is stale"):j>0&&!vt?(V="warn",St="Claimed work has no current_task",we=!0):vt&&j===0?(V="warn",St="current_task has no claimed work",we=!0):!Y&&at<=vs?(V="ok",St="Dispatchable now",Ae=!0):!Y&&at>ms?(V="warn",St="Idle but not freshly active"):Y&&at>vs&&(V="warn",St="Execution is getting quiet"),{agent:f,lastSignalAt:q,activeTaskCount:j,tone:V,note:St,focus:ut(f.current_task)??R.lastActivityText??(Ae?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:Ae,drift:we}}).sort((f,R)=>{const q=st(R.tone)-st(f.tone);return q!==0?q:Z(R.lastSignalAt)-Z(f.lastSignalAt)}),p=a.map(f=>{var V;const R=Gr.value.get(f.name)??"idle",q=Jr.value.has(f.name),at=f.context_ratio??0,j=f.diagnostic??null;let vt="ok",Y="Healthy keeper";return q||f.status==="offline"||R==="handoff-imminent"||(j==null?void 0:j.health_state)==="offline"||(j==null?void 0:j.health_state)==="degraded"?(vt="bad",Y=ut(j==null?void 0:j.summary,56)??(q?"Heartbeat stale":R==="handoff-imminent"?"Handoff imminent":(j==null?void 0:j.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((j==null?void 0:j.health_state)==="stale"||at>=To||R==="preparing"||R==="compacting")&&(vt="warn",Y=ut(j==null?void 0:j.summary,56)??(at>=To?"High context pressure":`Lifecycle ${R}`)),{keeper:f,tone:vt,note:Y,focus:ut(j==null?void 0:j.summary,120)??ut((V=f.agent)==null?void 0:V.current_task)??f.skill_primary??f.last_proactive_reason??f.memory_recent_note??"No active focus",timestamp:f.last_heartbeat??null}}).sort((f,R)=>{const q=st(R.tone)-st(f.tone);return q!==0?q:Z(R.timestamp)-Z(f.timestamp)}),l=n.filter(f=>f.status==="todo"||f.status==="claimed"||f.status==="in_progress").map(f=>{var Ae,we;const R=f.assignee?d.get(Ge(f.assignee))??null:null,q=R?In(R.name,n,be.value,le.value,{currentTask:R.current_task,lastSeen:R.last_seen,boardPosts:Ht.value,keepers:a}):null,at=(q==null?void 0:q.lastActivityAt)??(R==null?void 0:R.last_seen)??null,j=at?Math.max(0,Date.now()-Z(at)):Number.POSITIVE_INFINITY,vt=f.status==="claimed"||f.status==="in_progress";let Y="ok",V="Covered",St=!1;return f.assignee?!R||R.status==="offline"||R.status==="inactive"?(Y="bad",V="Assigned owner is unavailable",St=!0):vt&&j>ms?(Y="bad",V="Execution has lost a fresh signal"):vt&&j>vs?(Y="warn",V="Execution is drifting quiet"):f.status==="todo"&&jt(f.priority)<=2&&!((Ae=R.current_task)!=null&&Ae.trim())&&((q==null?void 0:q.activeAssignedCount)??0)===0?(Y="ok",V="Ready for dispatch"):vt&&!((we=R.current_task)!=null&&we.trim())&&(Y="warn",V="Owner focus is not explicit"):(Y=jt(f.priority)<=2?"bad":"warn",V=vt?"Active work has no owner":"Ready work has no owner",St=!0),{task:f,owner:R,lastSignalAt:at,tone:Y,note:V,focus:ut(R==null?void 0:R.current_task)??(q==null?void 0:q.lastActivityText)??ut(f.description)??"Needs operator attention.",ownerGap:St}}).sort((f,R)=>{const q=st(R.tone)-st(f.tone);if(q!==0)return q;const at=jt(f.task.priority)-jt(R.task.priority);return at!==0?at:Z(R.lastSignalAt??R.task.updated_at??R.task.created_at)-Z(f.lastSignalAt??f.task.updated_at??f.task.created_at)}),c=l.filter(f=>f.task.status==="todo"&&jt(f.task.priority)<=2),m=l.filter(f=>f.ownerGap).length,$=v.filter(f=>f.dispatchable),b=v.filter(f=>f.drift||f.tone!=="ok"),x=p.filter(f=>f.tone!=="ok"),D=t!=null&&t.paused?"bad":((xt=t==null?void 0:t.data_quality)==null?void 0:xt.board_contract_ok)===!1||((ft=t==null?void 0:t.data_quality)==null?void 0:ft.council_feed_ok)===!1?"warn":u?"ok":"warn",T=[];t!=null&&t.paused&&T.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((et=t.data_quality)==null?void 0:et.last_sync_at)??null,action:()=>zt("ops")}),u||T.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:Rd}),Ce(i==null?void 0:i.alert_level)!=="ok"&&T.push({key:"board-monitor",tone:Ce(i==null?void 0:i.alert_level),title:"Board feed needs attention",detail:`Freshness ${_s(i==null?void 0:i.last_activity_age_s)} · ${(i==null?void 0:i.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>zt("board")}),Ce(r==null?void 0:r.alert_level)!=="ok"&&T.push({key:"council-monitor",tone:Ce(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${_s(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>zt("board")}),(((lt=t==null?void 0:t.data_quality)==null?void 0:lt.board_contract_ok)===!1||((O=t==null?void 0:t.data_quality)==null?void 0:O.council_feed_ok)===!1)&&T.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((J=t.data_quality)==null?void 0:J.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((k=t.data_quality)==null?void 0:k.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((Lt=t.data_quality)==null?void 0:Lt.last_sync_at)??null,action:()=>zt("ops")});const z=[...T,...l.filter(f=>f.tone!=="ok").slice(0,3).map(f=>({key:`task-${f.task.id}`,tone:f.tone,title:f.task.title,detail:`${f.note} · ${f.focus}`,timestamp:f.lastSignalAt??f.task.updated_at??f.task.created_at??null,action:()=>zt("overview")})),...x.slice(0,2).map(f=>({key:`keeper-${f.keeper.name}`,tone:f.tone,title:f.keeper.name,detail:`${f.note} · ${f.focus}`,timestamp:f.timestamp,action:()=>Ca(f.keeper)})),...b.slice(0,2).map(f=>({key:`agent-${f.agent.name}`,tone:f.tone,title:f.agent.name,detail:`${f.note} · ${f.focus}`,timestamp:f.lastSignalAt,action:()=>He(f.agent.name)}))].sort((f,R)=>{const q=st(R.tone)-st(f.tone);return q!==0?q:Z(R.timestamp)-Z(f.timestamp)}).slice(0,8),C=fs.value;return o`
    <div class="overview-sub-tabs">
      <button
        class="sub-tab-btn ${C==="triage"?"active":""}"
        onClick=${()=>{fs.value="triage"}}
      >Triage</button>
      <button
        class="sub-tab-btn ${C==="dispatch"?"active":""}"
        onClick=${()=>{fs.value="dispatch"}}
      >Dispatch</button>
    </div>

    ${C==="dispatch"?o`<${vd} />`:o`<div class="stats-grid">
      <${Ne}
        label="Room State"
        value=${t!=null&&t.paused?"Paused":"Running"}
        color=${Yn(D)}
        caption=${(t==null?void 0:t.room)??(t==null?void 0:t.project)??"default room"}
      />
      <${Ne}
        label="Urgent Queue"
        value=${c.length}
        color=${c.length>0?"#fb7185":"#4ade80"}
        caption="todo tasks at P1/P2"
      />
      <${Ne}
        label="Active Work"
        value=${s.inProgress.length}
        color="#fbbf24"
        caption="claimed + in progress"
      />
      <${Ne}
        label="Dispatchable"
        value=${$.length}
        color="#22d3ee"
        caption="fresh agents with no load"
      />
      <${Ne}
        label="Keeper Pressure"
        value=${x.length}
        color=${x.length>0?"#fbbf24":"#4ade80"}
        caption="stale or high-context keepers"
      />
      <${Ne}
        label="Owner Gaps"
        value=${m}
        color=${m>0?"#fb7185":"#4ade80"}
        caption="tasks missing a live owner"
      />
    </div>

    <${w} title="Room Health" class="section">
      <div class="monitor-section-head">
        <h2 class="monitor-headline">Operational health at a glance</h2>
        <p class="monitor-subheadline">The Overview now prioritizes room state, feed freshness, and immediate intervention signals over full entity dumps.</p>
      </div>
      <div class="overview-health-grid">
        <div class="stat-card">
          <div class="stat-label">Live Feed</div>
          <div class="stat-value" style=${`color:${u?"#4ade80":"#fbbf24"}`}>${u?"Online":"Retrying"}</div>
          <div class="monitor-stat-caption">${qn.value} events seen in this session</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Board Feed</div>
          <div class="stat-value" style=${`color:${Yn(Ce(i==null?void 0:i.alert_level))}`}>${Ro(i==null?void 0:i.alert_level)}</div>
          <div class="monitor-stat-caption">Freshness ${_s(i==null?void 0:i.last_activity_age_s)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Council Feed</div>
          <div class="stat-value" style=${`color:${Yn(Ce(r==null?void 0:r.alert_level))}`}>${Ro(r==null?void 0:r.alert_level)}</div>
          <div class="monitor-stat-caption">${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Runtime</div>
          <div class="stat-value" style=${`color:${Yn(D)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${Pd((t==null?void 0:t.uptime_seconds)??0)}</div>
        </div>
      </div>
      <div class="overview-note-stack">
        <div class="overview-inline-note">
          ${(ee=t==null?void 0:t.data_quality)!=null&&ee.last_sync_at?o`Last sync <${U} timestamp=${t.data_quality.last_sync_at} />`:o`No sync metadata yet`}
        </div>
        <div class="overview-inline-note">
          ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
        </div>
        <div class="overview-inline-note">${Od(t==null?void 0:t.lodge)}</div>
        ${(pe=t==null?void 0:t.lodge)!=null&&pe.last_skip_reason?o`<div class="overview-inline-note">Last Lodge skip: ${t.lodge.last_skip_reason}</div>`:null}
      </div>
    <//>

    <div class="grid-2col">
      <${w} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs intervention right now</h2>
          <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
        </div>
        <div class="monitor-alert-list">
          ${z.length===0?o`<div class="empty-state">No immediate intervention required</div>`:z.map(f=>o`<${Md} key=${f.key} item=${f} />`)}
        </div>
      <//>

      <${w} title="Dispatch Window" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who can pick up work next</h2>
          <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${$.length===0?o`<div class="empty-state">No fully dispatchable agents right now</div>`:$.slice(0,5).map(f=>o`
                <${gs}
                  key=${f.agent.name}
                  tone=${f.tone}
                  title=${f.agent.name}
                  subtitle=${f.note}
                  meta=${[f.lastSignalAt?`Signal ${new Date(f.lastSignalAt).toLocaleTimeString()}`:"No recent signal",f.agent.model??"model n/a",f.agent.koreanName??"room agent"]}
                  focus=${f.focus}
                  onClick=${()=>He(f.agent.name)}
                />
              `)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${w} title="Execution Pulse" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Priority work and ownership drift</h2>
          <p class="monitor-subheadline">Urgent ready tasks and active execution issues stay visible without duplicating the full Execution surface.</p>
        </div>
        <div class="monitor-list">
          ${l.length===0?o`<div class="empty-state">No active or ready tasks</div>`:l.slice(0,6).map(f=>o`
                <${gs}
                  key=${f.task.id}
                  tone=${f.tone}
                  title=${f.task.title}
                  subtitle=${`${qi(f.task.priority)} · ${f.note}`}
                  meta=${[f.task.assignee?`Owner ${f.task.assignee}`:"Unassigned",f.lastSignalAt?`Signal ${new Date(f.lastSignalAt).toLocaleTimeString()}`:"No live signal",f.task.updated_at?`Touched ${new Date(f.task.updated_at).toLocaleTimeString()}`:"No task timestamp"]}
                  focus=${f.focus}
                  onClick=${()=>zt("overview")}
                />
              `)}
        </div>
      <//>

      <${w} title="Keeper Pressure" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Long-running keepers under pressure</h2>
          <p class="monitor-subheadline">Only keepers with real pressure stay in the Overview. The full keeper census still lives in the Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${x.length===0?o`<div class="empty-state">No keeper pressure signals right now</div>`:x.slice(0,5).map(f=>{var R;return o`
                <${gs}
                  key=${f.keeper.name}
                  tone=${f.tone}
                  title=${f.keeper.name}
                  subtitle=${(R=f.keeper.diagnostic)!=null&&R.health_state?`${f.note} · ${f.keeper.diagnostic.health_state}`:f.note}
                  meta=${[f.timestamp?`Heartbeat ${new Date(f.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof f.keeper.context_ratio=="number"?Math.round(f.keeper.context_ratio*100):0}%`,f.keeper.model?`Model ${f.keeper.model}`:"model n/a",f.keeper.diagnostic?`${Id(f.keeper.diagnostic.quiet_reason)} · next ${Ed(f.keeper.diagnostic.next_action_path)} · reply ${f.keeper.diagnostic.last_reply_status}`:"Diagnostic unavailable"]}
                  focus=${f.focus}
                  onClick=${()=>Ca(f.keeper)}
                />
              `})}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${w} title="Agent Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Agents with drift or aging load</h2>
          <p class="monitor-subheadline">This is the short list. Use the Agents tab when you need the full live monitor.</p>
        </div>
        <div class="monitor-list">
          ${b.length===0?o`<div class="empty-state">No agent drift or stale load right now</div>`:b.slice(0,5).map(f=>o`
                <button class="monitor-row ${f.tone}" onClick=${()=>He(f.agent.name)}>
                  <div class="monitor-row-header">
                    <div class="monitor-row-title">
                      <div class="monitor-name-line">
                        <span class="monitor-title">${f.agent.name}</span>
                        ${f.agent.koreanName?o`<span class="monitor-sub">${f.agent.koreanName}</span>`:null}
                      </div>
                      <div class="monitor-note">${f.note}</div>
                    </div>
                    <${Pt} status=${f.agent.status} />
                    <span class="monitor-pill ${f.tone}">${f.dispatchable?"Ready":f.drift?"Drift":"Watch"}</span>
                  </div>
                  <div class="monitor-meta">
                    ${f.lastSignalAt?o`<span>Signal <${U} timestamp=${f.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
                    <span>${f.activeTaskCount>0?`${f.activeTaskCount} active tasks`:"No active tasks"}</span>
                    ${f.agent.model?o`<span>${f.agent.model}</span>`:null}
                  </div>
                  <div class="monitor-focus">${f.focus}</div>
                </button>
              `)}
        </div>
      <//>

      <${w} title="Runtime Notes" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Secondary runtime context</h2>
          <p class="monitor-subheadline">This stays below the triage queue so operators can scan first and drill later.</p>
        </div>
        <div class="overview-note-stack">
          <div class="overview-inline-note">
            Room ${(t==null?void 0:t.room)??"default"}${t!=null&&t.cluster?` · Cluster ${t.cluster}`:""}${t!=null&&t.project?` · Project ${t.project}`:""}
          </div>
          <div class="overview-inline-note">
            ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${Ru.value.length} · Total tasks ${n.length}
          </div>
          <div class="overview-inline-note">
            ${rn.value?`Perpetual runtime ${rn.value.running?"running":"stopped"}${rn.value.goal?` · ${ut(rn.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
          </div>
          <div class="overview-inline-note">
            Lodge ${(E=t==null?void 0:t.lodge)!=null&&E.enabled?"enabled":"disabled"} · Last tick ${((It=t==null?void 0:t.lodge)==null?void 0:It.last_tick_ago)??"never"} · Self heartbeats ${((Gn=(ve=t==null?void 0:t.lodge)==null?void 0:ve.active_self_heartbeats)==null?void 0:Gn.length)??0}${(tn=t==null?void 0:t.lodge)!=null&&tn.last_skip_reason?` · Skip ${t.lodge.last_skip_reason}`:""}
          </div>
          <div class="overview-inline-note">
            ${a.length>0?`Hot keepers: ${x.length} · Highest context ${Ld(Math.max(...a.map(f=>f.context_tokens??0)))}`:"No keepers registered"}
          </div>
        </div>
      <//>
    </div>`}
  `}const te=g(null),Na=g(!1),Ra=g(null),ci=g(null),Da=g(null),Ui=g("operations"),Un=g(null),ui=g(!1),Pa=g(null);function P(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function _(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function N(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function di(t){return typeof t=="boolean"?t:void 0}function mt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function zd(t){if(P(t))return{policy_class:_(t.policy_class),approval_class:_(t.approval_class),tool_allowlist:mt(t.tool_allowlist),model_allowlist:mt(t.model_allowlist),requires_human_for:mt(t.requires_human_for),autonomy_level:_(t.autonomy_level),escalation_timeout_sec:N(t.escalation_timeout_sec),kill_switch:di(t.kill_switch),frozen:di(t.frozen)}}function jd(t){if(P(t))return{headcount_cap:N(t.headcount_cap),active_operation_cap:N(t.active_operation_cap),max_cost_usd:N(t.max_cost_usd),max_tokens:N(t.max_tokens)}}function il(t){if(!P(t))return null;const e=_(t.unit_id),n=_(t.label),a=_(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:_(t.parent_unit_id)??null,leader_id:_(t.leader_id)??null,roster:mt(t.roster),capability_profile:mt(t.capability_profile),source:_(t.source),created_at:_(t.created_at),updated_at:_(t.updated_at),policy:zd(t.policy),budget:jd(t.budget)}}function ol(t){if(!P(t))return null;const e=il(t.unit);return e?{unit:e,leader_status:_(t.leader_status),roster_total:N(t.roster_total),roster_live:N(t.roster_live),active_operation_count:N(t.active_operation_count),health:_(t.health),reasons:mt(t.reasons),children:Array.isArray(t.children)?t.children.map(ol).filter(n=>n!==null):[]}:null}function Fd(t){if(P(t))return{total_units:N(t.total_units),company_count:N(t.company_count),platoon_count:N(t.platoon_count),squad_count:N(t.squad_count),leaf_agent_unit_count:N(t.leaf_agent_unit_count),live_agent_count:N(t.live_agent_count),managed_unit_count:N(t.managed_unit_count),active_operation_count:N(t.active_operation_count)}}function qd(t){const e=P(t)?t:{};return{version:_(e.version),generated_at:_(e.generated_at),source:_(e.source),summary:Fd(e.summary),units:Array.isArray(e.units)?e.units.map(ol).filter(n=>n!==null):[]}}function rl(t){if(!P(t))return null;const e=_(t.operation_id),n=_(t.objective),a=_(t.assigned_unit_id),s=_(t.trace_id),i=_(t.status);return!e||!n||!a||!s||!i?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:_(t.autonomy_level),policy_class:_(t.policy_class),budget_class:_(t.budget_class),detachment_session_id:_(t.detachment_session_id)??null,trace_id:s,checkpoint_ref:_(t.checkpoint_ref)??null,active_goal_ids:mt(t.active_goal_ids),note:_(t.note)??null,created_by:_(t.created_by),source:_(t.source),status:i,created_at:_(t.created_at),updated_at:_(t.updated_at)}}function Hd(t){if(!P(t))return null;const e=rl(t.operation);return e?{operation:e,assigned_unit_label:_(t.assigned_unit_label)}:null}function Kd(t){const e=P(t)?t:{},n=P(e.summary)?e.summary:void 0;return{version:_(e.version),generated_at:_(e.generated_at),summary:n?{total:N(n.total),active:N(n.active),paused:N(n.paused),managed:N(n.managed),projected:N(n.projected)}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Hd).filter(a=>a!==null):[]}}function Ud(t){if(!P(t))return null;const e=_(t.detachment_id),n=_(t.operation_id),a=_(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:_(t.leader_id)??null,roster:mt(t.roster),session_id:_(t.session_id)??null,checkpoint_ref:_(t.checkpoint_ref)??null,runtime_kind:_(t.runtime_kind)??null,runtime_ref:_(t.runtime_ref)??null,source:_(t.source),status:_(t.status),last_event_at:_(t.last_event_at)??null,last_progress_at:_(t.last_progress_at)??null,heartbeat_deadline:_(t.heartbeat_deadline)??null,created_at:_(t.created_at),updated_at:_(t.updated_at)}}function Bd(t){if(!P(t))return null;const e=Ud(t.detachment);return e?{detachment:e,assigned_unit_label:_(t.assigned_unit_label),operation:rl(t.operation)}:null}function Wd(t){const e=P(t)?t:{},n=P(e.summary)?e.summary:void 0;return{version:_(e.version),generated_at:_(e.generated_at),summary:n?{total:N(n.total),active:N(n.active),projected:N(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(Bd).filter(a=>a!==null):[]}}function Gd(t){if(!P(t))return null;const e=_(t.decision_id),n=_(t.trace_id),a=_(t.requested_action),s=_(t.scope_type),i=_(t.scope_id);return!e||!n||!a||!s||!i?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:s,scope_id:i,operation_id:_(t.operation_id)??null,target_unit_id:_(t.target_unit_id)??null,requested_by:_(t.requested_by),status:_(t.status),reason:_(t.reason)??null,source:_(t.source),detail:t.detail,created_at:_(t.created_at),decided_at:_(t.decided_at)??null,expires_at:_(t.expires_at)??null}}function Jd(t){const e=P(t)?t:{},n=P(e.summary)?e.summary:void 0;return{version:_(e.version),generated_at:_(e.generated_at),summary:n?{total:N(n.total),pending:N(n.pending),approved:N(n.approved),denied:N(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(Gd).filter(a=>a!==null):[]}}function Vd(t){if(!P(t))return null;const e=il(t.unit);return e?{unit:e,roster_total:N(t.roster_total),roster_live:N(t.roster_live),headcount_cap:N(t.headcount_cap),active_operations:N(t.active_operations),active_operation_cap:N(t.active_operation_cap),utilization:N(t.utilization)}:null}function Qd(t){const e=P(t)?t:{};return{version:_(e.version),generated_at:_(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(Vd).filter(n=>n!==null):[]}}function Yd(t){if(!P(t))return null;const e=_(t.alert_id);return e?{alert_id:e,severity:_(t.severity),kind:_(t.kind),scope_type:_(t.scope_type),scope_id:_(t.scope_id),title:_(t.title),detail:_(t.detail),timestamp:_(t.timestamp)}:null}function Xd(t){const e=P(t)?t:{},n=P(e.summary)?e.summary:void 0;return{version:_(e.version),generated_at:_(e.generated_at),summary:n?{total:N(n.total),bad:N(n.bad),warn:N(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Yd).filter(a=>a!==null):[]}}function Zd(t){if(!P(t))return null;const e=_(t.event_id),n=_(t.trace_id),a=_(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:_(t.operation_id)??null,unit_id:_(t.unit_id)??null,actor:_(t.actor)??null,source:_(t.source),timestamp:_(t.timestamp),detail:t.detail}}function tp(t){const e=P(t)?t:{};return{version:_(e.version),generated_at:_(e.generated_at),events:Array.isArray(e.events)?e.events.map(Zd).filter(n=>n!==null):[]}}function ep(t){if(!P(t))return null;const e=_(t.code),n=_(t.severity),a=_(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a}}function np(t){if(!P(t))return null;const e=_(t.lane_id),n=_(t.label),a=_(t.kind),s=_(t.phase),i=_(t.motion_state),r=_(t.source_of_truth),u=_(t.movement_reason),d=_(t.current_step);if(!e||!n||!a||!s||!i||!r||!u||!d)return null;const v=P(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:a,present:di(t.present)??!1,phase:s,motion_state:i,source_of_truth:r,last_movement_at:_(t.last_movement_at)??null,movement_reason:u,current_step:d,blockers:mt(t.blockers),counts:{operations:N(v.operations),detachments:N(v.detachments),workers:N(v.workers),approvals:N(v.approvals),alerts:N(v.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(ep).filter(p=>p!==null):[]}}function ap(t){if(!P(t))return null;const e=_(t.event_id),n=_(t.lane_id),a=_(t.kind),s=_(t.timestamp),i=_(t.title),r=_(t.detail),u=_(t.tone),d=_(t.source);return!e||!n||!a||!s||!i||!r||!u||!d?null:{event_id:e,lane_id:n,kind:a,timestamp:s,title:i,detail:r,tone:u,source:d}}function sp(t){if(!P(t))return null;const e=_(t.code),n=_(t.severity),a=_(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a,lane_ids:mt(t.lane_ids),count:N(t.count)??0}}function ip(t){if(!P(t))return;const e=P(t.overview)?t.overview:{},n=P(t.gaps)?t.gaps:{},a=P(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:_(t.generated_at),overview:{active_lanes:N(e.active_lanes),moving_lanes:N(e.moving_lanes),stalled_lanes:N(e.stalled_lanes),projected_lanes:N(e.projected_lanes),last_movement_at:_(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(np).filter(s=>s!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(ap).filter(s=>s!==null):[],gaps:{count:N(n.count),items:Array.isArray(n.items)?n.items.map(sp).filter(s=>s!==null):[]},recommended_next_action:a?{tool:_(a.tool)??"masc_operator_snapshot",label:_(a.label)??"Observe operator state",reason:_(a.reason)??"",lane_id:_(a.lane_id)??null}:void 0}}function op(t){const e=P(t)?t:{};return{version:_(e.version),generated_at:_(e.generated_at),topology:qd(e.topology),operations:Kd(e.operations),detachments:Wd(e.detachments),alerts:Xd(e.alerts),decisions:Jd(e.decisions),capacity:Qd(e.capacity),traces:tp(e.traces),swarm_status:ip(e.swarm_status)}}function rp(t){if(!P(t))return null;const e=_(t.title),n=_(t.path);return!e||!n?null:{title:e,path:n}}function lp(t){if(!P(t))return null;const e=_(t.id),n=_(t.title),a=_(t.summary);return!e||!n||!a?null:{id:e,title:n,summary:a}}function cp(t){if(!P(t))return null;const e=_(t.id),n=_(t.title),a=_(t.tool),s=_(t.summary);return!e||!n||!a||!s?null:{id:e,title:n,tool:a,summary:s,success_signals:mt(t.success_signals),pitfalls:mt(t.pitfalls)}}function up(t){if(!P(t))return null;const e=_(t.id),n=_(t.title),a=_(t.summary),s=_(t.when_to_use);return!e||!n||!a||!s?null:{id:e,title:n,summary:a,when_to_use:s,steps:Array.isArray(t.steps)?t.steps.map(cp).filter(i=>i!==null):[]}}function dp(t){if(!P(t))return null;const e=_(t.id),n=_(t.title),a=_(t.description);return!e||!n||!a?null:{id:e,title:n,description:a,tools:mt(t.tools)}}function pp(t){if(!P(t))return null;const e=_(t.id),n=_(t.title),a=_(t.symptom),s=_(t.why),i=_(t.fix_tool),r=_(t.fix_summary);return!e||!n||!a||!s||!i||!r?null:{id:e,title:n,symptom:a,why:s,fix_tool:i,fix_summary:r}}function vp(t){if(!P(t))return null;const e=_(t.id),n=_(t.title),a=_(t.path_id),s=_(t.transport);return!e||!n||!a||!s?null:{id:e,title:n,path_id:a,transport:s,request:t.request,response:t.response,notes:mt(t.notes)}}function mp(t){const e=P(t)?t:{};return{version:_(e.version),generated_at:_(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(rp).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(lp).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(up).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(dp).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(pp).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(vp).filter(n=>n!==null):[]}}function fp(t){Ui.value=t}async function ns(){Na.value=!0,Ra.value=null;try{const t=await yc();te.value=op(t)}catch(t){Ra.value=t instanceof Error?t.message:"Failed to load command plane snapshot"}finally{Na.value=!1}}async function _p(){ui.value=!0,Pa.value=null;try{const t=await bc();Un.value=mp(t)}catch(t){Pa.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{ui.value=!1}}async function de(t,e,n){ci.value=t,Da.value=null;try{await kc(e,n),await ns()}catch(a){throw Da.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{ci.value=null}}function gp(t){return de(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function hp(t){return de(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function $p(t){return de(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function yp(t={}){return de("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function bp(t){return de(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function kp(t){return de(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function xp(t,e){return de(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Sp(t,e){return de(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}function Ap(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Kt(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function wp(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Tp(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function rt(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}function Cp(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function it(t){return ci.value===t}function Np(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Rp(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function Dp(t){return t.status==="claimed"||t.status==="in_progress"}function Pp(t){const e=Un.value;if(!e)return null;for(const n of e.golden_paths){const a=n.steps.find(s=>s.tool===t);if(a)return a}return null}function hs(t){var e;return((e=Un.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Lp(t){const e=Un.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(a=>n.has(a.id))}async function oe(t){try{await t()}catch{}}function Ip(){var i;const t=te.value,e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,a=t==null?void 0:t.decisions.summary,s=t==null?void 0:t.alerts.summary;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>Units</span><strong>${(e==null?void 0:e.total_units)??0}</strong><small>${(e==null?void 0:e.managed_unit_count)??0} managed</small></div>
      <div class="monitor-stat-card"><span>Ops</span><strong>${(n==null?void 0:n.active)??0}</strong><small>${((i=t==null?void 0:t.detachments.summary)==null?void 0:i.active)??0} detachments</small></div>
      <div class="monitor-stat-card"><span>Approvals</span><strong>${(a==null?void 0:a.pending)??0}</strong><small>${(a==null?void 0:a.total)??0} tracked</small></div>
      <div class="monitor-stat-card"><span>Alerts</span><strong>${(s==null?void 0:s.bad)??0}</strong><small>${(s==null?void 0:s.warn)??0} warn</small></div>
    </div>
  `}function Ep(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Op({lane:t}){const e=t.counts??{},n=Ep(t);return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.label}</strong>
          <div class="command-card-sub">${t.source_of_truth}</div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${rt(n)}">${t.phase}</span>
          <span class="command-chip ${rt(n)}">${t.motion_state}</span>
          <span class="command-chip">${Kt(t.last_movement_at)}</span>
        </div>
      </div>
      <div class="command-card-grid">
        <span>Movement</span><span>${t.movement_reason}</span>
        <span>Step</span><span>${t.current_step}</span>
        <span>Counts</span><span>${e.operations??0} ops · ${e.detachments??0} dets · ${e.workers??0} workers · ${e.approvals??0} approvals · ${e.alerts??0} alerts</span>
      </div>
      ${t.blockers.length>0?o`<div class="command-card-foot">Blockers: ${t.blockers.join(" · ")}</div>`:null}
      ${t.hard_flags.length>0?o`
            <div class="command-tag-row">
              ${t.hard_flags.map(a=>o`<span class="command-tag ${rt(a.severity)}">${a.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Mp({event:t}){return o`
    <div class="command-trace-row">
      <div class="command-trace-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${rt(t.tone)}">${t.lane_id}</span>
        <span class="command-chip">${t.kind}</span>
        <span class="command-chip">${Kt(t.timestamp)}</span>
      </div>
      <div class="command-card-sub">${t.source}</div>
      <div class="command-card-foot">${t.detail}</div>
    </div>
  `}function zp({gap:t}){return o`
    <div class="command-guide-inline">
      <div class="command-guide-head">
        <strong>${t.code}</strong>
        <span class="command-chip ${rt(t.severity)}">${t.count}</span>
      </div>
      <p>${t.summary}</p>
      ${t.lane_ids.length>0?o`<div class="command-tag-row">${t.lane_ids.map(e=>o`<span class="command-tag">${e}</span>`)}</div>`:null}
    </div>
  `}function jp(){var r;const t=(r=te.value)==null?void 0:r.swarm_status,e=(t==null?void 0:t.lanes.filter(u=>u.present))??[],n=(t==null?void 0:t.gaps.items)??[],a=(t==null?void 0:t.timeline.slice(0,6))??[],s=t==null?void 0:t.overview,i=t==null?void 0:t.recommended_next_action;return o`
    <section class="card command-section">
      <div class="card-title">Swarm</div>
      ${t?o`
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>Active Lanes</span><strong>${(s==null?void 0:s.active_lanes)??0}</strong><small>${(s==null?void 0:s.moving_lanes)??0} moving</small></div>
              <div class="monitor-stat-card"><span>Stalled</span><strong>${(s==null?void 0:s.stalled_lanes)??0}</strong><small>${(s==null?void 0:s.projected_lanes)??0} projected</small></div>
              <div class="monitor-stat-card"><span>Last Movement</span><strong>${Kt(s==null?void 0:s.last_movement_at)}</strong><small>${t.generated_at?`snapshot ${Kt(t.generated_at)}`:"snapshot now"}</small></div>
              <div class="monitor-stat-card"><span>Next Action</span><strong>${(i==null?void 0:i.label)??"Observe operator state"}</strong><small>${(i==null?void 0:i.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            <div class="command-swarm-layout">
              <div class="command-card-stack">
                ${e.length>0?e.map(u=>o`<${Op} lane=${u} />`):o`<div class="empty-state">No active swarm lanes.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight">
                  <div class="command-guide-head">
                    <strong>${(i==null?void 0:i.label)??"Observe operator state"}</strong>
                    <span class="command-chip">${(i==null?void 0:i.lane_id)??"global"}</span>
                  </div>
                  <p>${(i==null?void 0:i.reason)??"No active swarm lane is visible yet."}</p>
                  <div class="command-card-foot">${(i==null?void 0:i.tool)??"masc_operator_snapshot"}</div>
                </div>

                <div class="command-guide-card ${n.length>0?"warn":"ok"}">
                  <div class="command-guide-head">
                    <strong>Hard Gaps</strong>
                    <span class="command-chip ${rt(n.some(u=>u.severity==="bad")?"bad":n.length>0?"warn":"ok")}">${n.length}</span>
                  </div>
                  ${n.length>0?o`<div class="command-card-stack">${n.slice(0,4).map(u=>o`<${zp} gap=${u} />`)}</div>`:o`<p>No hard gaps are currently visible.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>Movement Timeline</strong>
                    <span class="command-chip">${a.length}</span>
                  </div>
                  ${a.length>0?o`<div class="command-card-stack">${a.map(u=>o`<${Mp} event=${u} />`)}</div>`:o`<p>No recent movement events are attached yet.</p>`}
                </div>
              </div>
            </div>
          `:o`<div class="empty-state">Swarm status is unavailable.</div>`}
    </section>
  `}function Fp(){return o`
    <div class="command-surface-tabs">
      ${["operations","topology","alerts","trace","control"].map(e=>o`
        <button
          class="command-surface-tab ${Ui.value===e?"active":""}"
          onClick=${()=>fp(e)}
        >
          ${e}
        </button>
      `)}
    </div>
  `}function qp(){var ft,et,lt,O,J,k,Lt,ee,pe;const t=te.value,e=ue.value,n=Np(),a=n?Zt.value.find(E=>E.name===n)??null:null,s=n?yt.value.filter(E=>E.assignee===n&&Dp(E)):[],i=((ft=t==null?void 0:t.operations.summary)==null?void 0:ft.active)??0,r=((et=t==null?void 0:t.detachments.summary)==null?void 0:et.total)??0,u=((lt=t==null?void 0:t.decisions.summary)==null?void 0:lt.pending)??0,d=t==null?void 0:t.detachments.detachments.find(E=>{const It=E.detachment.heartbeat_deadline,ve=It?Date.parse(It):Number.NaN;return E.detachment.status==="stalled"||!Number.isNaN(ve)&&ve<=Date.now()}),v=t==null?void 0:t.alerts.alerts.find(E=>E.severity==="bad"),p=!!(e!=null&&e.room||e!=null&&e.project),l=(a==null?void 0:a.current_task)??null,c=Rp(a==null?void 0:a.last_seen),m=c!=null?c<=120:null,$=[p?{title:"Room readiness",tone:"ok",detail:`${(e==null?void 0:e.room)??(e==null?void 0:e.project)??"unknown"} · base ${(e==null?void 0:e.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room readiness",tone:"bad",detail:"No room snapshot yet. Set room to repo root before joining.",tool:"masc_set_room"},n?a?s.length===0?{title:"Task readiness",tone:"warn",detail:`${n} has no claimed task. Claim one or create one first.`,tool:yt.value.length>0?"masc_claim":"masc_add_task"}:l?m===!1?{title:"Task readiness",tone:"warn",detail:`${n} current_task=${l}, but heartbeat is stale (${c}s).`,tool:"masc_heartbeat"}:{title:"Task readiness",tone:"ok",detail:`${n} current_task=${l}${c!=null?` · last seen ${c}s ago`:""}`,tool:"masc_plan_get_task"}:{title:"Task readiness",tone:"bad",detail:`${n} has a claimed task but no session current_task binding.`,tool:"masc_plan_set_task"}:{title:"Task readiness",tone:"bad",detail:`${n} is not visible in the room roster.`,tool:"masc_join"}:{title:"Task readiness",tone:"warn",detail:"No ?agent= query param. Dashboard can show room health but not agent-specific next steps.",tool:"masc_join"},!t||(((O=t.topology.summary)==null?void 0:O.managed_unit_count)??0)===0?{title:"Operation readiness",tone:"warn",detail:"No managed units defined yet. CPv2 benchmark cannot start before hierarchy exists.",tool:"masc_unit_define"}:i===0?{title:"Operation readiness",tone:"warn",detail:`${((J=t.topology.summary)==null?void 0:J.managed_unit_count)??0} managed units are ready, but there is no active operation.`,tool:"masc_operation_start"}:{title:"Operation readiness",tone:"ok",detail:`${i} active operation(s) across ${((k=t.topology.summary)==null?void 0:k.managed_unit_count)??0} managed unit(s).`,tool:"masc_observe_operations"},u>0?{title:"Dispatch readiness",tone:"warn",detail:`${u} pending approval(s) are blocking strict actions.`,tool:"masc_policy_approve"}:i>0&&r===0?{title:"Dispatch readiness",tone:"bad",detail:"Active operation exists but no detachment has been materialized yet.",tool:"masc_dispatch_tick"}:d||v?{title:"Dispatch readiness",tone:"warn",detail:`Dispatch needs reconciliation${d?` · detachment ${d.detachment.detachment_id} is stalled`:""}${v?` · alert ${v.title??v.alert_id}`:""}.`,tool:u>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"Dispatch readiness",tone:"ok",detail:`${r} detachment(s) visible and no strict approval backlog.`,tool:"masc_detachment_list"}],b=p?!n||!a?"masc_join":s.length===0?yt.value.length>0?"masc_claim":"masc_add_task":l?m===!1?"masc_heartbeat":!t||(((Lt=t.topology.summary)==null?void 0:Lt.managed_unit_count)??0)===0?"masc_unit_define":i===0?"masc_operation_start":u>0?"masc_policy_approve":i>0&&r===0||d||v?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",x=Pp(b),T=Lp(b==="masc_set_room"?["repo-root-room"]:b==="masc_plan_set_task"?["claimed-not-current"]:b==="masc_heartbeat"?["heartbeat-stale"]:b==="masc_dispatch_tick"?["no-detachments"]:b==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),z=hs("room_task_hygiene"),C=hs("cpv2_benchmark"),L=hs("supervisor_session"),tt=((ee=Un.value)==null?void 0:ee.docs)??[],xt=[z,C,L].filter(E=>E!==null);return o`
    <div class="command-guide-grid">
      <section class="card command-section">
        <div class="card-title">Readiness</div>
        <div class="command-guide-readiness">
          ${$.map(E=>o`
            <article class="command-guide-card ${rt(E.tone)}">
              <div class="command-guide-head">
                <strong>${E.title}</strong>
                <span class="command-chip ${rt(E.tone)}">${E.tone}</span>
              </div>
              <p>${E.detail}</p>
              <div class="command-card-foot">Next tool: ${E.tool}</div>
            </article>
          `)}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title">Next Step</div>
        <article class="command-guide-card highlight">
          <div class="command-guide-head">
            <strong>${(x==null?void 0:x.title)??b}</strong>
            <span class="command-chip ok">${b}</span>
          </div>
          <p>${(x==null?void 0:x.summary)??"Use the next tool in the canonical flow to remove the current blocker."}</p>
          ${(pe=x==null?void 0:x.success_signals)!=null&&pe.length?o`<div class="command-tag-row">
                ${x.success_signals.map(E=>o`<span class="command-tag ok">${E}</span>`)}
              </div>`:null}
          ${T.length>0?o`<div class="command-guide-list">
                ${T.map(E=>o`
                  <article class="command-guide-inline">
                    <strong>${E.title}</strong>
                    <div>${E.symptom}</div>
                    <div class="command-card-sub">Fix with ${E.fix_tool}: ${E.fix_summary}</div>
                  </article>
                `)}
              </div>`:null}
        </article>
      </section>

      <section class="card command-section">
        <div class="card-title">How It Works</div>
        ${ui.value?o`<div class="empty-state">Loading CPv2 runbook…</div>`:Pa.value?o`<div class="empty-state error">${Pa.value}</div>`:o`
                <div class="command-guide-paths">
                  ${xt.map(E=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${E.title}</strong>
                        <span class="command-chip">${E.id}</span>
                      </div>
                      <p>${E.summary}</p>
                      <div class="command-card-sub">${E.when_to_use}</div>
                      <div class="command-step-list">
                        ${E.steps.map(It=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${It.tool}</span>
                            <span>${It.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${tt.length>0?o`<div class="command-doc-links">
                      ${tt.map(E=>o`<span class="command-tag">${E.title}: ${E.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function ll({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,s=t.active_operation_count??0,i=t.unit.policy;return o`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${Cp(t.unit.kind)}</span>
            <span class="command-chip ${rt(t.health)}">${t.health??"ok"}</span>
            ${i!=null&&i.frozen?o`<span class="command-chip warn">frozen</span>`:null}
            ${i!=null&&i.kill_switch?o`<span class="command-chip bad">kill-switch</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${t.unit.unit_id}</span>
            <span>Leader ${t.unit.leader_id??"unassigned"} / ${t.leader_status??"unknown"}</span>
            <span>Roster ${n}/${a}</span>
            <span>Ops ${s}</span>
            <span>Autonomy ${(i==null?void 0:i.autonomy_level)??"n/a"}</span>
          </div>
          ${t.reasons&&t.reasons.length>0?o`<div class="command-tag-row">
                ${t.reasons.map(r=>o`<span class="command-tag warn">${r}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?o`<div class="command-tree-children">
            ${t.children.map(r=>o`<${ll} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Hp({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,s=`recall:${e.operation_id}`;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${rt(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${Kt(e.updated_at)}</span>
      </div>
      ${e.checkpoint_ref?o`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        ${e.source==="managed"&&e.status==="active"?o`
              <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>oe(()=>gp(e.operation_id))}>
                ${it(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${it(s)} onClick=${()=>oe(()=>$p(e.operation_id))}>
                ${it(s)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?o`
              <button class="control-btn ghost" disabled=${it(a)} onClick=${()=>oe(()=>hp(e.operation_id))}>
                ${it(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Kp({card:t}){var n;const e=t.detachment;return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${rt(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${Kt(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Tp(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Kt(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?o`<span class="command-tag ${wp(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Up({alert:t}){return o`
    <article class="command-alert ${rt(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${rt(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${Kt(t.timestamp)}</span>
      </div>
      ${t.detail?o`<p>${t.detail}</p>`:null}
    </article>
  `}function Bp({event:t}){return o`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${Kt(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${Ap(t.detail)}</pre>
    </article>
  `}function Wp({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return o`
    <article class="command-card ${rt(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${rt(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${Kt(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${it(e)} onClick=${()=>oe(()=>bp(t.decision_id))}>
                ${it(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>oe(()=>kp(t.decision_id))}>
                ${it(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?o`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function Gp({row:t}){var u,d,v;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,s=!!((u=e.policy)!=null&&u.frozen),i=!!((d=e.policy)!=null&&d.kill_switch),r=Math.round((t.utilization??0)*100);return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${rt(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((v=e.policy)==null?void 0:v.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${s?"yes":"no"}</span>
        <span>Kill Switch</span><span>${i?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>oe(()=>xp(e.unit_id,!s))}>
          ${it(n)?"Applying…":s?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${it(a)} onClick=${()=>oe(()=>Sp(e.unit_id,!i))}>
          ${it(a)?"Applying…":i?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Jp(){const t=te.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?o`<div class="command-card-stack">
              ${t.operations.operations.map(e=>o`<${Hp} card=${e} />`)}
            </div>`:o`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>o`<${Kp} card=${e} />`)}
            </div>`:o`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Vp(){const t=te.value;return o`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${t&&t.topology.units.length>0?o`${t.topology.units.map(e=>o`<${ll} node=${e} />`)}`:o`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `}function Qp(){const t=te.value;return o`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${t&&t.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>o`<${Up} alert=${e} />`)}
          </div>`:o`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `}function Yp(){const t=te.value;return o`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${t&&t.traces.events.length>0?o`<div class="command-trace-stack">
            ${t.traces.events.map(e=>o`<${Bp} event=${e} />`)}
          </div>`:o`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `}function Xp(){const t=te.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${t&&t.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>o`<${Wp} decision=${e} />`)}
            </div>`:o`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${t&&t.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>o`<${Gp} row=${e} />`)}
            </div>`:o`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `}function Zp(){switch(Ui.value){case"topology":return o`<${Vp} />`;case"alerts":return o`<${Qp} />`;case"trace":return o`<${Yp} />`;case"control":return o`<${Xp} />`;case"operations":default:return o`<${Jp} />`}}function tv(){return qt(()=>{_p()},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{oe(()=>yp())}}
            disabled=${it("dispatch:tick")}
          >
            ${it("dispatch:tick")?"Reconciling…":"Run Tick"}
          </button>
          <button class="control-btn ghost" onClick=${()=>{ns()}} disabled=${Na.value}>
            ${Na.value?"Refreshing…":"Refresh"}
          </button>
        </div>
      </div>

      ${Ra.value?o`<div class="empty-state error">${Ra.value}</div>`:null}
      ${Da.value?o`<div class="empty-state error">${Da.value}</div>`:null}

      <${Ip} />
      <${jp} />
      <${qp} />
      <${Fp} />
      <${Zp} />
    </section>
  `}const Bn=g(null),La=g(!1),ce=g(null),W=g(!1),Ia=g([]);let ev=1;function G(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function I(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function ht(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function cl(t){return typeof t=="boolean"?t:void 0}function nv(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Pe(t,e=[]){if(Array.isArray(t))return t;if(!G(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function av(t){return G(t)?{id:I(t.id),seq:ht(t.seq),from:I(t.from)??I(t.from_agent)??"system",content:I(t.content)??"",timestamp:I(t.timestamp)??new Date().toISOString(),type:I(t.type)}:null}function sv(t){return G(t)?{room_id:I(t.room_id),current_room:I(t.current_room)??I(t.room),project:I(t.project),cluster:I(t.cluster),paused:cl(t.paused),pause_reason:I(t.pause_reason)??null,paused_by:I(t.paused_by)??null,paused_at:I(t.paused_at)??null}:{}}function Po(t){if(!G(t))return;const e=Object.entries(t).map(([n,a])=>{const s=I(a);return s?[n,s]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function iv(t){if(!G(t))return null;const e=G(t.status)?t.status:void 0,n=G(t.summary)?t.summary:G(e==null?void 0:e.summary)?e.summary:void 0,a=G(t.session)?t.session:G(e==null?void 0:e.session)?e.session:void 0,s=I(t.session_id)??I(n==null?void 0:n.session_id)??I(a==null?void 0:a.session_id);if(!s)return null;const i=Po(t.report_paths)??Po(e==null?void 0:e.report_paths),r=Pe(t.recent_events,["events"]).filter(G);return{session_id:s,status:I(t.status)??I(n==null?void 0:n.status)??I(a==null?void 0:a.status),progress_pct:ht(t.progress_pct)??ht(n==null?void 0:n.progress_pct),elapsed_sec:ht(t.elapsed_sec)??ht(n==null?void 0:n.elapsed_sec),remaining_sec:ht(t.remaining_sec)??ht(n==null?void 0:n.remaining_sec),done_delta_total:ht(t.done_delta_total)??ht(n==null?void 0:n.done_delta_total),summary:n,team_health:G(t.team_health)?t.team_health:G(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:G(t.communication_metrics)?t.communication_metrics:G(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:G(t.orchestration_state)?t.orchestration_state:G(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:G(t.cascade_metrics)?t.cascade_metrics:G(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:a,recent_events:r}}function ov(t){if(!G(t))return null;const e=I(t.name);if(!e)return null;const n=G(t.context)?t.context:void 0;return{name:e,agent_name:I(t.agent_name),status:I(t.status),autonomy_level:I(t.autonomy_level),context_ratio:ht(t.context_ratio)??ht(n==null?void 0:n.context_ratio),generation:ht(t.generation),active_goal_ids:nv(t.active_goal_ids),last_autonomous_action_at:I(t.last_autonomous_action_at)??null,last_turn_ago_s:ht(t.last_turn_ago_s),model:I(t.model)??I(t.active_model)??I(t.primary_model)}}function rv(t){if(!G(t))return null;const e=I(t.confirm_token)??I(t.token);return e?{confirm_token:e,actor:I(t.actor),action_type:I(t.action_type),target_type:I(t.target_type),target_id:I(t.target_id)??null,delegated_tool:I(t.delegated_tool),created_at:I(t.created_at),preview:t.preview}:null}function lv(t){const e=G(t)?t:{};return{room:sv(e.room),sessions:Pe(e.sessions,["items","sessions"]).map(iv).filter(n=>n!==null),keepers:Pe(e.keepers,["items","keepers"]).map(ov).filter(n=>n!==null),recent_messages:Pe(e.recent_messages,["messages"]).map(av).filter(n=>n!==null),pending_confirms:Pe(e.pending_confirms,["items","confirms"]).map(rv).filter(n=>n!==null),available_actions:Pe(e.available_actions,["actions"]).filter(G).map(n=>({action_type:I(n.action_type)??"unknown",target_type:I(n.target_type)??"unknown",description:I(n.description),confirm_required:cl(n.confirm_required)}))}}function Xn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Lo(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Ea(t){Ia.value=[{...t,id:ev++,at:new Date().toISOString()},...Ia.value].slice(0,20)}function ul(t){return t.confirm_required?Xn(t.preview)||"Confirmation required":Xn(t.result)||Xn(t.executed_action)||Xn(t.delegated_tool_result)||t.status}async function Wn(){La.value=!0,ce.value=null;try{const t=await $c();Bn.value=lv(t)}catch(t){ce.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{La.value=!1}}async function cv(t){W.value=!0,ce.value=null;try{const e=await Kn(t);return Ea({actor:t.actor,action_type:t.action_type,target_label:Lo(t),outcome:e.confirm_required?"preview":"executed",message:ul(e),delegated_tool:e.delegated_tool}),await Wn(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw ce.value=n,Ea({actor:t.actor,action_type:t.action_type,target_label:Lo(t),outcome:"error",message:n}),e}finally{W.value=!1}}async function uv(t,e){W.value=!0,ce.value=null;try{const n=await Sc(t,e);return Ea({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:ul(n),delegated_tool:n.delegated_tool}),await Wn(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw ce.value=a,Ea({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{W.value=!1}}const dl="masc_dashboard_agent_name";function dv(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(dl))==null?void 0:a.trim())||"dashboard"}const as=g(dv()),mn=g(""),pi=g("Operator pause"),fn=g(""),Oa=g(""),vi=g("2"),Ma=g(""),Ke=g("note"),za=g(""),ja=g(""),Fa=g(""),mi=g("2"),fi=g("Operator stop request"),_i=g(""),_n=g("");function pv(t){const e=t.trim()||"dashboard";as.value=e,localStorage.setItem(dl,e)}function Io(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function vv(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function qa(t){return typeof t=="string"?t.trim().toLowerCase():""}function mv(t){var a;const e=qa(t.status);if(e==="paused")return"bad";const n=qa((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function Eo(t){const e=qa(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function Se(t){const e=as.value.trim()||"dashboard";try{const n=await cv({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?A("Confirmation queued","warning"):A(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return A(a,"error"),null}}async function Oo(){const t=mn.value.trim();if(!t)return;await Se({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(mn.value="")}async function fv(){await Se({action_type:"room_pause",target_type:"room",payload:{reason:pi.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function _v(){await Se({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function gv(){const t=fn.value.trim();if(!t)return;await Se({action_type:"task_inject",target_type:"room",payload:{title:t,description:Oa.value.trim()||"Injected from Ops tab",priority:Number.parseInt(vi.value,10)||2},successMessage:"Task injection submitted"})&&(fn.value="",Oa.value="")}async function hv(){var i;const t=Bn.value,e=Ma.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){A("Select a team session first","warning");return}const n={turn_kind:Ke.value},a=za.value.trim();a&&(n.message=a),Ke.value==="task"&&(n.task_title=ja.value.trim()||"Operator injected task",n.task_description=Fa.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(mi.value,10)||2),await Se({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(za.value="",Ke.value==="task"&&(ja.value="",Fa.value=""))}async function $v(){var n;const t=Bn.value,e=Ma.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){A("Select a team session first","warning");return}await Se({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:fi.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function yv(){var s;const t=Bn.value,e=_i.value||((s=t==null?void 0:t.keepers[0])==null?void 0:s.name)||"",n=_n.value.trim();if(!e){A("Select a keeper first","warning");return}if(!n)return;await Se({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(_n.value="")}async function bv(t){const e=as.value.trim()||"dashboard";try{await uv(e,t),A("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";A(a,"error")}}function kv(){var l;const t=Bn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],s=(t==null?void 0:t.pending_confirms)??[],i=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===Ma.value)??n[0]??null,u=a.find(c=>c.name===_i.value)??a[0]??null,d=n.filter(c=>mv(c)!=="ok"),v=a.filter(c=>Eo(c)!=="ok"),p=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:s.length,detail:s.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:s.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:d.length,detail:d.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:d.some(c=>qa(c.status)==="paused")?"bad":d.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:v.length,detail:v.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:v.some(c=>Eo(c)==="bad")?"bad":v.length>0?"warn":"ok"}];return o`
    <section class="ops-view">
      <div class="ops-header card">
        <div>
          <div class="card-title">Operator Control</div>
          <h2 class="ops-heading">Guided control for room, sessions, and keepers</h2>
          <p class="ops-subheading">
            Structured actions only. Destructive changes remain behind confirmation tokens.
          </p>
        </div>
        <div class="ops-toolbar">
          <label class="control-label" for="ops-actor">Actor</label>
          <input
            id="ops-actor"
            class="control-input ops-actor-input"
            type="text"
            value=${as.value}
            onInput=${c=>pv(c.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{Wn()}} disabled=${La.value||W.value}>
            ${La.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${ce.value?o`
        <section class="ops-banner error">${ce.value}</section>
      `:null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Action Priority</h2>
          <p class="monitor-subheadline">Ops is the command surface. These four signals explain when to intervene before you drop into a specific control panel.</p>
        </div>
        <div class="ops-priority-grid">
          ${p.map(c=>o`
            <div key=${c.key} class="ops-priority-card ${c.tone}">
              <span class="ops-priority-label">${c.label}</span>
              <strong>${c.value}</strong>
              <div class="ops-priority-detail">${c.detail}</div>
            </div>
          `)}
        </div>
      </section>

      ${s.length>0?o`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <p class="ops-context-note">Only previewed actions that still need an explicit operator confirmation stay here.</p>
          <div class="ops-confirmation-list">
            ${s.map(c=>o`
              <article key=${c.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${c.action_type??"unknown"}</strong>
                  <span>${c.target_type??"target"}${c.target_id?`:${c.target_id}`:""}</span>
                  <span>${c.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${c.preview?o`<pre class="ops-code-block">${Io(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{bv(c.confirm_token)}} disabled=${W.value}>
                    Confirm
                  </button>
                  <span class="ops-token">${c.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        </section>
      `:null}

      <div class="ops-grid">
        <section class="card ops-panel">
          <div class="card-title">Room Control</div>
          <div class="ops-stat-grid">
            <div class="ops-stat">
              <span>Room</span>
              <strong>${e.current_room??e.room_id??"default"}</strong>
            </div>
            <div class="ops-stat">
              <span>Project</span>
              <strong>${e.project??"n/a"}</strong>
            </div>
            <div class="ops-stat">
              <span>Cluster</span>
              <strong>${e.cluster??"n/a"}</strong>
            </div>
            <div class="ops-stat ${e.paused?"warn":"ok"}">
              <span>Status</span>
              <strong>${e.paused?"Paused":"Running"}</strong>
            </div>
          </div>

          <label class="control-label" for="ops-broadcast">Broadcast</label>
          <div class="control-row">
            <input
              id="ops-broadcast"
              class="control-input"
              type="text"
              placeholder="@agent or room-wide operator update"
              value=${mn.value}
              onInput=${c=>{mn.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&Oo()}}
              disabled=${W.value}
            />
            <button class="control-btn" onClick=${()=>{Oo()}} disabled=${W.value||mn.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${pi.value}
              onInput=${c=>{pi.value=c.target.value}}
              disabled=${W.value}
            />
            <button class="control-btn ghost" onClick=${()=>{fv()}} disabled=${W.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{_v()}} disabled=${W.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${fn.value}
            onInput=${c=>{fn.value=c.target.value}}
            disabled=${W.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${Oa.value}
            onInput=${c=>{Oa.value=c.target.value}}
            disabled=${W.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${vi.value}
              onChange=${c=>{vi.value=c.target.value}}
              disabled=${W.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{gv()}} disabled=${W.value||fn.value.trim()===""}>
              Inject
            </button>
          </div>

          ${i.length>0?o`
            <div class="ops-section-head">Context Tail</div>
            <div class="ops-context-note">Recent room chatter stays available for context, but command work remains the primary focus of this tab.</div>
            <div class="ops-feed-list">
              ${i.slice(0,6).map(c=>o`
                <article key=${c.seq??c.id??c.timestamp} class="ops-feed-item">
                  <div class="ops-feed-meta">
                    <strong>${c.from}</strong>
                    <span>${c.timestamp}</span>
                  </div>
                  <div class="ops-feed-content">${c.content}</div>
                </article>
              `)}
            </div>
          `:null}
        </section>

        <section class="card ops-panel">
          <div class="card-title">Team Sessions</div>
          <div class="ops-entity-list">
            ${n.length===0?o`<div class="ops-empty">No team sessions available.</div>`:n.map(c=>{var m;return o`
              <button
                key=${c.session_id}
                class="ops-entity-card ${(r==null?void 0:r.session_id)===c.session_id?"active":""}"
                onClick=${()=>{Ma.value=c.session_id}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.session_id}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${Math.round(c.progress_pct??0)}%</span>
                  <span>${c.done_delta_total??0} done</span>
                  <span>${(m=c.team_health)!=null&&m.status?String(c.team_health.status):"health n/a"}</span>
                </div>
              </button>
            `})}
          </div>

          ${r?o`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${r.session_id}</div>
              <div class="ops-detail-meta">
                <span>Status: ${r.status??"unknown"}</span>
                <span>Elapsed: ${r.elapsed_sec??0}s</span>
                <span>Remaining: ${r.remaining_sec??0}s</span>
              </div>
              ${r.recent_events&&r.recent_events.length>0?o`
                <pre class="ops-code-block compact">${Io(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Ke.value}
              onChange=${c=>{Ke.value=c.target.value}}
              disabled=${W.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{hv()}} disabled=${W.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${za.value}
            onInput=${c=>{za.value=c.target.value}}
            disabled=${W.value||!r}
          ></textarea>
          ${Ke.value==="task"?o`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${ja.value}
              onInput=${c=>{ja.value=c.target.value}}
              disabled=${W.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${Fa.value}
              onInput=${c=>{Fa.value=c.target.value}}
              disabled=${W.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${mi.value}
              onChange=${c=>{mi.value=c.target.value}}
              disabled=${W.value||!r}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
          `:null}

          <div class="ops-section-head">Stop Session</div>
          <div class="control-row ops-split-row">
            <input
              class="control-input"
              type="text"
              value=${fi.value}
              onInput=${c=>{fi.value=c.target.value}}
              disabled=${W.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{$v()}} disabled=${W.value||!r}>
              Stop
            </button>
          </div>
        </section>

        <section class="card ops-panel">
          <div class="card-title">Keepers</div>
          <div class="ops-entity-list">
            ${a.length===0?o`<div class="ops-empty">No keepers available.</div>`:a.map(c=>o`
              <button
                key=${c.name}
                class="ops-entity-card ${(u==null?void 0:u.name)===c.name?"active":""}"
                onClick=${()=>{_i.value=c.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.name}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${c.model??"model n/a"}</span>
                  <span>${typeof c.context_ratio=="number"?`${Math.round(c.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${vv(c.last_turn_ago_s)}</span>
                </div>
              </button>
            `)}
          </div>

          ${u?o`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${u.name}</div>
              <div class="ops-detail-meta">
                <span>Autonomy: ${u.autonomy_level??"n/a"}</span>
                <span>Generation: ${u.generation??0}</span>
                <span>Goals: ${((l=u.active_goal_ids)==null?void 0:l.length)??0}</span>
              </div>
            </div>
          `:null}

          <label class="control-label" for="ops-keeper-message">Keeper Message</label>
          <textarea
            id="ops-keeper-message"
            class="control-textarea"
            rows=${6}
            placeholder="Send a structured intervention or course correction"
            value=${_n.value}
            onInput=${c=>{_n.value=c.target.value}}
            disabled=${W.value||!u}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{yv()}} disabled=${W.value||!u||_n.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${Ia.value.length===0?o`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:Ia.value.map(c=>o`
            <article key=${c.id} class="ops-log-entry ${c.outcome}">
              <div class="ops-log-head">
                <strong>${c.action_type}</strong>
                <span>${c.target_label}</span>
                <span>${c.at}</span>
              </div>
              <div class="ops-log-body">${c.message}</div>
            </article>
          `)}
        </div>
      </section>
    </section>
  `}function xv({text:t}){if(!t)return null;const e=Sv(t);return o`<div class="markdown-content">${e}</div>`}function Sv(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],u=s.slice(r.length).trim(),d=[];for(a++;a<e.length&&!e[a].startsWith(r);)d.push(e[a]),a++;a++,n.push(o`<pre><code class=${u?`language-${u}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],u=s.trim().replace(/^<think>/,"").trim();for(u&&u!=="</think>"&&r.push(u),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const v=e[a].replace("</think>","").trim();v&&r.push(v),a++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${$s(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${$s(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${$s(i.join(`
`))}</p>`)}return n}function $s(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const ln=g("posts"),gi=g([]),hi=g([]),gn=g(""),Ha=g(!1),hn=g(!1),Mn=g(""),Ka=g(null),Nt=g(null),$i=g(!1),se=g(null),va=g(null);async function ss(){Ha.value=!0,Mn.value="";try{const[t,e]=await Promise.all([ru(),lu()]);gi.value=t,hi.value=e,se.value=!0,va.value=Date.now()}catch(t){Mn.value=t instanceof Error?t.message:"Failed to load council data",se.value=!1}finally{Ha.value=!1}}Bu(ss);async function Mo(){const t=gn.value.trim();if(t){hn.value=!0;try{const e=await cu(t);gn.value="",A(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await ss()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";A(n,"error")}finally{hn.value=!1}}}async function Av(t){Ka.value=t,$i.value=!0,Nt.value=null;try{Nt.value=await uu(t)}catch(e){Mn.value=e instanceof Error?e.message:"Failed to load debate status",Nt.value=null}finally{$i.value=!1}}const pl=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],ma=g(null),$n=g([]),ye=g(!1),he=g(null),yn=g("");function wv(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Tv=g(wv()),bn=g(!1);async function Bi(t){he.value=t,ma.value=null,$n.value=[],ye.value=!0;try{const e=await Dc(t);if(he.value!==t)return;ma.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},$n.value=e.comments??[]}catch{he.value===t&&(ma.value=null,$n.value=[])}finally{he.value===t&&(ye.value=!1)}}async function zo(t){const e=yn.value.trim();if(e){bn.value=!0;try{await Pc(t,Tv.value,e),yn.value="",A("Comment posted","success"),await Bi(t),Gt()}catch{A("Failed to post comment","error")}finally{bn.value=!1}}}function Cv(){const t=Rn.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${pl.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{Rn.value=e.id,Gt()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${_e.value?"is-active":""}"
          onClick=${()=>{_e.value=!_e.value,Gt()}}
        >
          ${_e.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Gt} disabled=${Pn.value}>
          ${Pn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function yi(){var e;const t=(e=ue.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${U} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function vl({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Nv(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function jo(t){return t.updated_at!==t.created_at}function bi(){var n;const t=((n=pl.find(a=>a.id===Rn.value))==null?void 0:n.label)??Rn.value,e=Ht.value.length;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${e}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${t}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${_e.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${ri.value?o`<${U} timestamp=${ri.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Rv({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Or(t.id,n),Gt()}catch{A("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Xl(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-head">
          <div class="post-title-row">
            <div class="post-title">${t.title}</div>
            <div class="post-chip-row">
              <${vl} flair=${t.flair} />
              ${jo(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${U} timestamp=${t.created_at} /></span>
            ${jo(t)?o`<span>Updated <${U} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${Nv(t.content)}</div>
      </div>
    </div>
  `}function Dv({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${U} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Pv({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${yn.value}
        onInput=${e=>{yn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&zo(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${bn.value}
      />
      <button
        onClick=${()=>zo(t)}
        disabled=${bn.value||yn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${bn.value?"...":"Post"}
      </button>
    </div>
  `}function Lv({post:t}){he.value!==t.id&&!ye.value&&Bi(t.id);const e=async n=>{try{await Or(t.id,n),Gt()}catch{A("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>zt("board")}>← Back to Board</button>
      <${w} title=${o`${t.title} <${vl} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${xv} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${U} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${w} title="Comments (${ye.value?"...":$n.value.length})">
        ${ye.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Dv} comments=${$n.value} />`}
        <${Pv} postId=${t.id} />
      <//>
    </div>
  `}function Iv({debate:t}){const e=Ka.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Av(t.id)}
    >
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Args: ${t.argument_count}</span>
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function Ev({session:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.state?o`<span>State: ${t.state}</span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function ml(){return se.value===null||se.value&&!va.value?null:o`
    <div class="feed-health-banner ${se.value===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${se.value===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${va.value?o`<span class="feed-health-meta">Last sync: <${U} timestamp=${va.value} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Ov(){const t=se.value===!1;return o`
    <div>
      <${ml} />
      <${w} title="Start Debate" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${gn.value}
            onInput=${e=>{gn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&Mo()}}
            disabled=${hn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Mo}
            disabled=${hn.value||gn.value.trim()===""}
          >
            ${hn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${ss} disabled=${Ha.value}>
            ${Ha.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Mn.value?o`<div class="council-error">${Mn.value}</div>`:null}
      <//>

      <${w} title="Debates" class="section">
        <div class="council-list">
          ${gi.value.length===0?o`<div class="empty-state">${t?"No debates loaded (council feed degraded).":"No debates yet"}</div>`:gi.value.map(e=>o`<${Iv} key=${e.id} debate=${e} />`)}
        </div>
      <//>

      <${w} title=${Ka.value?`Debate Detail (${Ka.value})`:"Debate Detail"} class="section">
        ${$i.value?o`<div class="loading-indicator">Loading debate detail...</div>`:Nt.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${Nt.value.status}</span>
                  <span>Total arguments: ${Nt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${Nt.value.support_count}</span>
                  <span>Oppose: ${Nt.value.oppose_count}</span>
                  <span>Neutral: ${Nt.value.neutral_count}</span>
                </div>
                ${Nt.value.summary_text?o`<pre class="council-detail">${Nt.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Mv(){const t=se.value===!1;return o`
    <div>
      <${ml} />
      <${w} title="Voting Sessions" class="section">
        <div class="council-list">
          ${hi.value.length===0?o`<div class="empty-state">${t?"No sessions loaded (council feed degraded).":"No active sessions"}</div>`:hi.value.map(e=>o`<${Ev} key=${e.id} session=${e} />`)}
        </div>
      <//>
    </div>
  `}function zv(){const t=ln.value;return o`
    <div class="overview-sub-tabs" style="margin-bottom: 12px;">
      <button class="sub-tab-btn ${t==="posts"?"active":""}" onClick=${()=>{ln.value="posts"}}>Posts</button>
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{ln.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{ln.value="voting"}}>Voting</button>
    </div>
  `}function jv(){var a,s;const t=Ht.value,e=Pn.value,n=((s=(a=ue.value)==null?void 0:a.data_quality)==null?void 0:s.board_contract_ok)===!1;return o`
    <div>
      <${yi} />
      <${bi} />
      <${Cv} />
      ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
              <div class="empty-state">
                ${n?"No posts loaded (board feed degraded). Check board contract sync.":_e.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
              </div>
            `:o`<div class="board-post-list">
              ${t.map(i=>o`<${Rv} key=${i.id} post=${i} />`)}
            </div>`}
    </div>
  `}function Fv(){var s,i;const t=Ht.value,e=Ft.value.postId,n=((i=(s=ue.value)==null?void 0:s.data_quality)==null?void 0:i.board_contract_ok)===!1,a=ln.value;if(qt(()=>{(a==="debates"||a==="voting")&&ss()},[a]),e){const r=t.find(u=>u.id===e)??(he.value===e?ma.value:null);return!r&&he.value!==e&&!ye.value&&Bi(e),r?o`
          <${yi} />
          <${bi} />
          <${Lv} post=${r} />
        `:o`
          <div>
            <${yi} />
            <${bi} />
            <button class="back-btn" onClick=${()=>zt("board")}>← Back to Board</button>
            ${ye.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${n?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${zv} />
    ${a==="debates"?o`<${Ov} />`:a==="voting"?o`<${Mv} />`:o`<${jv} />`}
  `}function qv(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Hv(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Kv(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const fl=120,Uv=12,Bv=16,Wv=12,ki=g("all"),Gv={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Jv={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function Vv(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Qv(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:qv(t),actor:Hv(t),content:Kv(t),timestamp:new Date(t.timestamp).toISOString()}}function Yv(t,e){var s;const n=(s=t.assignee)==null?void 0:s.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function Xv(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Zn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function xi(t){return t.last_heartbeat??Zn(t.last_turn_ago_s)??Zn(t.last_proactive_ago_s)??Zn(t.last_handoff_ago_s)??Zn(t.last_compaction_ago_s)}function Zv(t,e){const n=xi(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function Et(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const Si=bt(()=>{const t=be.value.map(Vv),e=le.value.map(Qv),n=[...yt.value].sort((i,r)=>Et(r.updated_at??r.created_at??0)-Et(i.updated_at??i.created_at??0)).slice(0,Uv).map(Yv).filter(i=>i!==null),a=[...Ht.value].sort((i,r)=>Et(r.updated_at||r.created_at)-Et(i.updated_at||i.created_at)).slice(0,Bv).map(Xv),s=[...Dt.value].sort((i,r)=>Et(xi(r)??0)-Et(xi(i)??0)).slice(0,Wv).map(Zv).filter(i=>i!==null);return[...t,...e,...n,...a,...s].sort((i,r)=>Et(r.timestamp)-Et(i.timestamp))}),tm=bt(()=>{const t=Si.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),em=bt(()=>{const t=ki.value;return(t==="all"?Si.value:Si.value.filter(n=>n.kind===t)).slice(0,fl)}),nm=bt(()=>Zt.value.map(t=>({agent:t,motion:In(t.name,yt.value,be.value,le.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ht.value,keepers:Dt.value})})).sort((t,e)=>{const n=e.motion.activeAssignedCount-t.motion.activeAssignedCount;return n!==0?n:Et(e.motion.lastActivityAt??0)-Et(t.motion.lastActivityAt??0)}));function am(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function sn({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function sm({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${am(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Jv[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function im(){const t=tm.value,e=em.value,n=e[0],a=nm.value;return o`
    <div class="stats-grid">
      <${sn} label="Visible rows" value=${e.length} />
      <${sn} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${sn} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${sn} label="Board signals" value=${t.board} color="#fbbf24" />
      <${sn} label="SSE events" value=${qn.value} color="#c084fc" />
    </div>

    <${w} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(s=>o`
            <button
              class="goal-filter-btn ${ki.value===s?"active":""}"
              onClick=${()=>{ki.value=s}}
            >
              ${Gv[s]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${Vt.value?"":"pill-stale"}">
            ${Vt.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${U} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${fl} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?o`<div class="empty-state">Waiting for live or snapshot signals...</div>`:e.map(s=>o`<${sm} key=${s.id} row=${s} />`)}
      </div>
    <//>

    <${w} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${a.length===0?o`<div class="empty-state">No active agents</div>`:a.map(({agent:s,motion:i})=>o`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${s.name}</div>
                  <div class="activity-motion-meta">
                    ${i.activeAssignedCount>0?`${i.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${i.lastActivityAt?o` · <${U} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function _l({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,i=2*Math.PI*a,r=i*((100-t*100)/100);let u="mitosis-safe";return t>=.8?u="mitosis-critical":t>=.5&&(u="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${s}" cy="${s}" r="${a}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${u}" 
          cx="${s}" cy="${s}" r="${a}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${u}">${Math.round(t*100)}%</span>
    </div>
  `}const ys=600*1e3,om=1200*1e3,Fo=.8;function ne(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Re(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function rm(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function lm(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function cm(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function um(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function dm(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function pm(t){var d,v;const e=In(t.name,yt.value,be.value,le.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ht.value,keepers:Dt.value}),n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-ne(n)):Number.POSITIVE_INFINITY,s=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let i="watching",r="ok",u="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",u=n?"Offline or inactive":"No recent presence"):a>om?(i="quiet",r="bad",u=s?"Working without a fresh signal":"No fresh agent signal"):s?(i="working",r=a>ys?"warn":"ok",u=a>ys?"Execution looks quiet for too long":"Task and live signal aligned"):a>ys?(i="quiet",r="warn",u="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",u="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((v=t.current_task)==null?void 0:v.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:u}}function vm(t){const e=Gr.value.get(t.name)??"idle",n=Jr.value.has(t.name),a=t.context_ratio??0;let s="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(s="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=Fo)&&(s="warning",i="warn",r=a>=Fo?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:s,tone:i,focus:um(t),note:r}}function on({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function mm({item:t}){const e=t.kind==="agent"?()=>He(t.agent.name):()=>Ca(t.keeper);return o`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?o`<span><${U} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </button>
  `}function qo({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>He(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${_l} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Pt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${rm(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${U} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
        ${e.last_seen?o`<span>Seen <${U} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?o`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function fm({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Ca(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${_l} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Pt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${lm(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${U} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${dm(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${cm(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function _m(){const t=[...Zt.value].map(pm).sort((p,l)=>{const c=Re(l.tone)-Re(p.tone);if(c!==0)return c;const m=l.activeTaskCount-p.activeTaskCount;return m!==0?m:ne(l.lastSignalAt)-ne(p.lastSignalAt)}),e=[...Dt.value].map(vm).sort((p,l)=>{const c=Re(l.tone)-Re(p.tone);if(c!==0)return c;const m=(l.keeper.context_ratio??0)-(p.keeper.context_ratio??0);return m!==0?m:ne(l.keeper.last_heartbeat)-ne(p.keeper.last_heartbeat)}),n=t.filter(p=>p.state!=="offline"),a=t.filter(p=>p.state==="offline"),s=n.length,i=t.filter(p=>p.state==="working").length,r=t.filter(p=>p.lastSignalAt&&Date.now()-ne(p.lastSignalAt)<=12e4).length,u=t.filter(p=>p.tone!=="ok"),d=e.filter(p=>p.tone!=="ok"),v=[...d.map(p=>({kind:"keeper",key:`keeper-${p.keeper.name}`,tone:p.tone,title:p.keeper.name,subtitle:`${p.note} · ${p.focus}`,timestamp:p.keeper.last_heartbeat??null,keeper:p.keeper})),...u.map(p=>({kind:"agent",key:`agent-${p.agent.name}`,tone:p.tone,title:p.agent.name,subtitle:`${p.note} · ${p.focus}`,timestamp:p.lastSignalAt,agent:p.agent}))].sort((p,l)=>{const c=Re(l.tone)-Re(p.tone);return c!==0?c:ne(l.timestamp)-ne(p.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${on} label="Agents online" value=${s} color="#4ade80" caption="active + idle" />
        <${on} label="Working now" value=${i} color="#fbbf24" caption="task or claimed load" />
        <${on} label="Fresh signals" value=${r} color="#22d3ee" caption="within last 2 minutes" />
        <${on} label="Agent alerts" value=${u.length} color=${u.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${on} label="Keeper alerts" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${w} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${v.length===0?o`<div class="empty-state">No agent or keeper alerts right now</div>`:v.map(p=>o`<${mm} key=${p.key} item=${p} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${w} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(p=>o`<${fm} key=${p.keeper.name} row=${p} />`)}
          </div>
        <//>

        <${w} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Current task, recent signal, and quiet drift are surfaced together.</p>
          </div>
          <div class="monitor-list">
            ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
                ${n.length>0?o`
                  <div class="agent-group-header">
                    Active <span class="group-count">${n.length}</span>
                  </div>
                  ${n.map(p=>o`<${qo} key=${p.agent.name} row=${p} />`)}
                `:null}
                ${a.length>0?o`
                  <div class="agent-group-header">
                    Offline <span class="group-count">${a.length}</span>
                  </div>
                  ${a.map(p=>o`<${qo} key=${p.agent.name} row=${p} />`)}
                `:null}
              `}
          </div>
        <//>
      </div>
    </div>
  `}const Ua=g("all"),Ba=g("all"),Ai=bt(()=>{let t=Dn.value;return Ua.value!=="all"&&(t=t.filter(e=>e.horizon===Ua.value)),Ba.value!=="all"&&(t=t.filter(e=>e.status===Ba.value)),t}),gm=bt(()=>{const t={short:[],mid:[],long:[]};for(const e of Ai.value){const n=t[e.horizon];n&&n.push(e)}return t}),hm=bt(()=>{const t=Array.from(Kr.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function $m(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Wi(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function fa(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function ym(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Ho(t){return t.toFixed(4)}function Ko(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function bm({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${fa(t.horizon)}">
            ${Wi(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${$m(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${U} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Pt} status=${t.status} />
        <div class="goal-updated">
          <${U} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Uo({label:t,timestamp:e,source:n,note:a}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${a?o`<div class="planning-freshness-source">${a}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${U} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function bs({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return o`
    <${w} title="${Wi(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>o`<${bm} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function km(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Ua.value===t?"active":""}"
            onClick=${()=>{Ua.value=t}}
          >
            ${t==="all"?"All":Wi(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Ba.value===t?"active":""}"
            onClick=${()=>{Ba.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function xm(){const t=Dn.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return o`
    <div class="goal-summary">
      <div class="goal-summary-item">
        <div class="goal-summary-value">${t.length}</div>
        <div class="goal-summary-label">Total</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#4ade80">${e}</div>
        <div class="goal-summary-label">Active</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#888">${n}</div>
        <div class="goal-summary-label">Completed</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${fa("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${fa("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${fa("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Sm({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${Pt} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Ho(t.baseline_metric)}</span>
          <span>Current ${Ho(t.current_metric)}</span>
          <span class=${Ko(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Ko(t)}
          </span>
          <span>Elapsed ${ym(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${t.stop_reason||t.error_message?o`
              <div class="planning-loop-footnote">
                ${t.error_message??t.stop_reason}
              </div>
            `:null}
        <div class="planning-loop-footnote">
          ${t.strict_mode?"Strict hard evidence":"Legacy"} · ${t.worker_engine??"unknown engine"} · ${n}
        </div>
        ${e?o`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function ks({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${U} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Am(){const{todo:t,inProgress:e,done:n}=Wr.value;return o`
    <${w} title="Task Backlog" class="section">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>o`<${ks} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>o`<${ks} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>o`<${ks} key=${a.id} task=${a} />`)}
          ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function wm(){const t=gm.value,e=hm.value,n=e.filter(u=>u.status==="running").length,a=e.filter(u=>u.recoverable).length,s=Dn.value.filter(u=>u.status==="active").length,i=ai.value,r=i==="idle"?"No loop running":i==="error"?si.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${Ai.value.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Running loops</div>
          <div class="stat-value" style="color:#fbbf24">${n}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Recoverable loops</div>
          <div class="stat-value" style="color:#38bdf8">${a}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Known loops</div>
          <div class="stat-value">${e.length}</div>
        </div>
      </div>

      <${w} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>/api/v1/mdal/loops</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${Sa} disabled=${Ee.value}>
              ${Ee.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${Ln} disabled=${Oe.value}>
              ${Oe.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{Sa(),Ln()}}
              disabled=${Ee.value||Oe.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Uo} label="Goals" timestamp=${Ur.value} source="masc_goal_list" />
          <${Uo}
            label="MDAL loops"
            timestamp=${Br.value}
            source="/api/v1/mdal/loops"
            note=${r}
          />
        </div>
      <//>

      <${w} title="Goal Pipeline" class="section">
        <${xm} />
        <${km} />
      <//>

      ${Ee.value&&Dn.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:Ai.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${bs} horizon="short" items=${t.short??[]} />
              <${bs} horizon="mid" items=${t.mid??[]} />
              <${bs} horizon="long" items=${t.long??[]} />
            `}

      <${w} title="MDAL Loops" class="section">
        ${Oe.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&i==="error"?o`
                <div class="empty-state">
                  MDAL snapshot could not be loaded right now. Check the backend tool contract or runtime health.
                </div>
              `:e.length===0&&i==="idle"?o`
                <div class="empty-state">
                  No loop is running right now. This section wakes up when <code>masc_mdal_start</code> exposes a live loop.
                </div>
              `:e.length===0?o`
                  <div class="empty-state">
                    No loop snapshot is visible yet. Refresh once the backend has reported a planning loop.
                  </div>
                `:o`
                <div class="planning-loop-list">
                  ${e.map(u=>o`<${Sm} key=${u.loop_id} loop=${u} />`)}
                </div>
              `}
      <//>

      <${Am} />
    </div>
  `}const Le=g(""),xs=g("ability_check"),Ss=g("10"),As=g("12"),ta=g(""),ea=g("idle"),ae=g(""),na=g("keeper-late"),ws=g("player"),Ts=g(""),wt=g("idle"),Cs=g(null),aa=g(""),Ns=g(""),Rs=g("player"),Ds=g(""),Ps=g(""),Ls=g(""),kn=g("20"),Is=g("20"),Es=g(""),sa=g("idle"),wi=g(null),gl=g("overview"),Os=g("all"),Ms=g("all"),zs=g("all"),Tm=12e4,is=g(null),Bo=g(Date.now());function Cm(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Nm(t,e){return e>0?Math.round(t/e*100):0}const Rm={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Dm={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function ia(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Pm(t){const e=t.trim().toLowerCase();return Rm[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Lm(t){const e=t.trim().toLowerCase();return Dm[e]??"상황에 따라 선택되는 전술 액션입니다."}function re(t){return typeof t=="object"&&t!==null}function gt(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function Ot(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function zn(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const Im=new Set(["str","dex","con","int","wis","cha"]);function Em(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!re(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,i])=>{const r=s.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){a[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const u=Number.parseFloat(i.trim());if(Number.isFinite(u)){a[r]=Math.max(0,Math.trunc(u));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function Om(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(kn.value.trim(),10);Number.isFinite(a)&&a>n&&(kn.value=String(n))}function Ti(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Mm(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function zm(t){gl.value=t}function hl(t){const e=is.value;return e==null||e<=t}function jm(t){const e=is.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Wa(){is.value=null}function $l(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Fm(t,e){$l(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(is.value=Date.now()+Tm,A("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function _a(t){return hl(t)?(A("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Ci(t,e,n){return $l([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function qm({hp:t,max:e}){const n=Nm(t,e),a=Cm(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Hm({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Km({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function yl({actor:t}){var d,v,p,l;const e=(d=t.archetype)==null?void 0:d.trim(),n=(v=t.persona)==null?void 0:v.trim(),a=(p=t.portrait)==null?void 0:p.trim(),s=(l=t.background)==null?void 0:l.trim(),i=t.traits??[],r=t.skills??[],u=Object.entries(t.stats_raw??{}).filter(([c,m])=>Number.isFinite(m)).filter(([c])=>!Im.has(c.toLowerCase()));return o`
    <div class="trpg-actor">
      ${a?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${a}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${c=>{const m=c.target;m&&(m.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${Pt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Km} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${qm} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Hm} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${ia(e)}</div>`:null}
      ${s?o`<div class="trpg-actor-meta">Background: ${s}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${u.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${u.map(([c,m])=>o`
                <span class="trpg-custom-stat-chip">${ia(c)} ${m}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(c=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${ia(c)}</span>
                  <span class="trpg-annot-desc">${Pm(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(c=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${ia(c)}</span>
                  <span class="trpg-annot-desc">${Lm(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Um({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function bl({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return o`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Mm(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Ti(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${U} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Bm({events:t}){const e="__none__",n=Os.value,a=Ms.value,s=zs.value,i=Array.from(new Set(t.map(Ti).map(l=>l.trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),r=Array.from(new Set(t.map(l=>(l.type??"").trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),u=t.some(l=>(l.type??"").trim()===""),d=Array.from(new Set(t.map(l=>(l.phase??"").trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),v=t.some(l=>(l.phase??"").trim()===""),p=t.filter(l=>{if(n!=="all"&&Ti(l)!==n)return!1;const c=(l.type??"").trim(),m=(l.phase??"").trim();if(a===e){if(c!=="")return!1}else if(a!=="all"&&c!==a)return!1;if(s===e){if(m!=="")return!1}else if(s!=="all"&&m!==s)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${l=>{Os.value=l.target.value}}>
          <option value="all">all</option>
          ${i.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${l=>{Ms.value=l.target.value}}>
          <option value="all">all</option>
          ${u?o`<option value=${e}>(none)</option>`:null}
          ${r.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${l=>{zs.value=l.target.value}}>
          <option value="all">all</option>
          ${v?o`<option value=${e}>(none)</option>`:null}
          ${d.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Os.value="all",Ms.value="all",zs.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${p.length} / 전체 ${t.length}
      </span>
    </div>
    <${bl} events=${p.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Wm({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function kl({state:t}){const e=t.history??[];return e.length===0?null:o`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>o`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function Gm({state:t,nowMs:e}){var v;const n=Wt.value||((v=t.session)==null?void 0:v.room)||"",a=ea.value,s=t.party??[];if(!s.find(p=>p.id===Le.value)&&s.length>0){const p=s[0];p&&(Le.value=p.id)}const r=async()=>{var l,c;if(!n){A("Room ID가 비어 있습니다.","error");return}if(!_a(e))return;const p=((l=t.current_round)==null?void 0:l.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(Ci("라운드 실행",n,p)){ea.value="running";try{const m=await Jc(n);wi.value=m,ea.value="ok";const $=re(m.summary)?m.summary:null,b=$?zn($,"advanced",!1):!1,x=$?gt($,"progress_reason",""):"";A(b?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${x?`: ${x}`:""}`,b?"success":"warning"),Jt()}catch(m){wi.value=null,ea.value="error";const $=m instanceof Error?m.message:"라운드 실행에 실패했습니다.";A($,"error")}finally{Wa()}}},u=async()=>{var l,c;if(!n||!_a(e))return;const p=((l=t.current_round)==null?void 0:l.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(Ci("턴 강제 진행",n,p))try{await Yc(n),A("턴을 다음 단계로 이동했습니다.","success"),Jt()}catch{A("턴 이동에 실패했습니다.","error")}finally{Wa()}},d=async()=>{if(!n||!_a(e))return;const p=Le.value.trim();if(!p){A("먼저 Actor를 선택하세요.","warning");return}const l=Number.parseInt(Ss.value,10),c=Number.parseInt(As.value,10);if(Number.isNaN(l)||Number.isNaN(c)){A("stat/dc는 숫자여야 합니다.","warning");return}const m=Number.parseInt(ta.value,10),$=ta.value.trim()===""||Number.isNaN(m)?void 0:m;try{await Qc({roomId:n,actorId:p,action:xs.value.trim()||"ability_check",statValue:l,dc:c,rawD20:$}),A("주사위 판정을 기록했습니다.","success"),Jt()}catch{A("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${p=>{Wt.value=p.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Le.value}
            onChange=${p=>{Le.value=p.target.value}}
          >
            <option value="">Actor 선택</option>
            ${s.map(p=>o`<option value=${p.id}>${p.name} (${p.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${xs.value}
              onInput=${p=>{xs.value=p.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Ss.value}
              onInput=${p=>{Ss.value=p.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${As.value}
              onInput=${p=>{As.value=p.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ta.value}
              onInput=${p=>{ta.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&d()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${d}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${r}
              disabled=${a==="running"}
            >
              ${a==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${u}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${a!=="idle"?o`<div class="trpg-run-status ${a}">${a==="running"?"처리 중...":a==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function Jm({state:t}){var s;const e=Wt.value||((s=t.session)==null?void 0:s.room)||"",n=sa.value,a=async()=>{if(!e){A("Room ID가 비어 있습니다.","warning");return}const i=aa.value.trim(),r=Ns.value.trim();if(!r&&!i){A("이름 또는 Actor ID를 입력하세요.","warning");return}const u=Number.parseInt(kn.value.trim(),10),d=Number.parseInt(Is.value.trim(),10),v=Number.isFinite(d)?Math.max(1,d):20,p=Number.isFinite(u)?Math.max(0,Math.min(v,u)):v;let l={};try{l=Em(Es.value)}catch(c){A(c instanceof Error?c.message:"능력치 JSON 오류","error");return}sa.value="spawning";try{const c=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,m=await Xc(e,{actor_id:i||void 0,name:r||void 0,role:Rs.value,idempotencyKey:c,portrait:Ps.value.trim()||void 0,background:Ls.value.trim()||void 0,hp:p,max_hp:v,alive:p>0,stats:Object.keys(l).length>0?l:void 0}),$=typeof m.actor_id=="string"?m.actor_id.trim():"";if(!$)throw new Error("생성 응답에 actor_id가 없습니다.");const b=Ds.value.trim();b&&await Zc(e,$,b),Le.value=$,ae.value=$,i||(aa.value=""),sa.value="ok",A(`Actor 생성 완료: ${$}`,"success"),await Jt()}catch(c){sa.value="error",A(c instanceof Error?c.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Ns.value}
            onInput=${i=>{Ns.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Rs.value}
            onChange=${i=>{Rs.value=i.target.value}}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Keeper (optional)</label>
          <input
            id="trpg-spawn-keeper-input"
            name="trpg-spawn-keeper-input"
            type="text"
            value=${Ds.value}
            onInput=${i=>{Ds.value=i.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn recommend" onClick=${a} disabled=${n==="spawning"}>
              ${n==="spawning"?"Spawning...":"Spawn Actor"}
            </button>
          </div>
        </div>
      </div>

      <details class="trpg-control-details">
        <summary>상세 입력 (선택)</summary>
        <div class="trpg-control-grid">
          <div class="trpg-control-field">
            <label>Actor ID (optional)</label>
            <input
              id="trpg-spawn-actor-id-input"
              name="trpg-spawn-actor-id-input"
              type="text"
              value=${aa.value}
              onInput=${i=>{aa.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Ps.value}
              onInput=${i=>{Ps.value=i.target.value}}
              placeholder="https://.../portrait.png"
            />
          </div>
          <div class="trpg-control-field">
            <label>HP</label>
            <input
              id="trpg-spawn-hp-input"
              name="trpg-spawn-hp-input"
              type="number"
              min="0"
              value=${kn.value}
              onInput=${i=>{kn.value=i.target.value}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field">
            <label>Max HP</label>
            <input
              id="trpg-spawn-max-hp-input"
              name="trpg-spawn-max-hp-input"
              type="number"
              min="1"
              value=${Is.value}
              onInput=${i=>{const r=i.target.value;Is.value=r,Om(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Ls.value}
              onInput=${i=>{Ls.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Es.value}
              onInput=${i=>{Es.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Vm({state:t,nowMs:e}){var c;const n=Wt.value||((c=t.session)==null?void 0:c.room)||"",a=t.join_gate,s=Cs.value,i=re(s)?s:null,r=(t.party??[]).filter(m=>m.role!=="dm"),u=ae.value.trim(),d=r.some(m=>m.id===u),v=d?u:u?"__manual__":"",p=async()=>{const m=ae.value.trim(),$=na.value.trim();if(!n||!m){A("Room/Actor가 필요합니다.","warning");return}wt.value="checking";try{const b=await tu(n,m,$||void 0);Cs.value=b,wt.value="ok",A("참가 가능 여부를 갱신했습니다.","success")}catch(b){wt.value="error";const x=b instanceof Error?b.message:"참가 가능 여부 확인에 실패했습니다.";A(x,"error")}},l=async()=>{var D,T;const m=ae.value.trim(),$=na.value.trim(),b=Ts.value.trim();if(!n||!m||!$){A("Room/Actor/Keeper가 필요합니다.","warning");return}if(!_a(e))return;const x=((D=t.current_round)==null?void 0:D.phase)??((T=t.session)==null?void 0:T.status)??"unknown";if(Ci("Mid-Join 승인 요청",n,x)){wt.value="requesting";try{const z=await eu({room_id:n,actor_id:m,keeper_name:$,role:ws.value,...b?{name:b}:{}});Cs.value=z;const C=re(z)?zn(z,"granted",!1):!1,L=re(z)?gt(z,"reason_code",""):"";C?A("Mid-Join이 승인되었습니다.","success"):A(`Mid-Join이 거절되었습니다${L?`: ${L}`:""}`,"warning"),wt.value=C?"ok":"error",Jt()}catch(z){wt.value="error";const C=z instanceof Error?z.message:"Mid-Join 요청에 실패했습니다.";A(C,"error")}finally{Wa()}}};return o`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${a!=null&&a.phase_open?"OPEN":"CLOSED"}</strong>
        ${a!=null&&a.window?o`<span style="margin-left:8px;">(${a.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(a==null?void 0:a.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
            value=${v}
            onChange=${m=>{const $=m.target.value;if($==="__manual__"){(d||!u)&&(ae.value="");return}ae.value=$}}
          >
            <option value="">Actor 선택</option>
            ${r.map(m=>o`
              <option value=${m.id}>${m.name} (${m.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${v==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${ae.value}
                onInput=${m=>{ae.value=m.target.value}}
                placeholder="player-xyz"
                style="margin-top:6px;"
              />
            `:null}
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            id="trpg-join-keeper-input"
            name="trpg-join-keeper-input"
            type="text"
            value=${na.value}
            onInput=${m=>{na.value=m.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ws.value}
            onChange=${m=>{ws.value=m.target.value}}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Name (optional)</label>
          <input
            id="trpg-join-name-input"
            name="trpg-join-name-input"
            type="text"
            value=${Ts.value}
            onInput=${m=>{Ts.value=m.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${p} disabled=${wt.value==="checking"||wt.value==="requesting"}>
              ${wt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${l} disabled=${wt.value==="checking"||wt.value==="requesting"}>
              ${wt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${zn(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Ot(i,"effective_score",0)}/${Ot(i,"required_points",0)}</span>
            ${gt(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${gt(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function xl({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Sl({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Al(){const t=wi.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=re(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(re).slice(-8),i=t.canon_check,r=re(i)?i:null,u=r&&Array.isArray(r.warnings)?r.warnings.filter(L=>typeof L=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(L=>typeof L=="string").slice(0,3):[],v=n?zn(n,"advanced",!1):!1,p=n?gt(n,"progress_reason",""):"",l=n?gt(n,"progress_detail",""):"",c=n?Ot(n,"player_successes",0):0,m=n?Ot(n,"player_required_successes",0):0,$=n?zn(n,"dm_success",!1):!1,b=n?Ot(n,"timeouts",0):0,x=n?Ot(n,"unavailable",0):0,D=n?Ot(n,"reprompts",0):0,T=n?Ot(n,"npc_attacks",0):0,z=n?Ot(n,"keeper_timeout_sec",0):0,C=n?Ot(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${v?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${v?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${$?"DM ok":"DM stalled"} / players ${c}/${m}
          </span>
        </div>
        ${p?o`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${l?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${l}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${b}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${D}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${z||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${C}</div></div>
      </div>

      ${s.length>0?o`
          <div class="trpg-round-list">
            ${s.map(L=>{const tt=gt(L,"status","unknown"),xt=gt(L,"actor_id","-"),ft=gt(L,"role","-"),et=gt(L,"reason",""),lt=gt(L,"action_type",""),O=gt(L,"reply","");return o`
                <div class="trpg-round-item ${tt.includes("fallback")||tt.includes("timeout")?"failed":"active"}">
                  <span>${xt} (${ft})</span>
                  <span style="margin-left:auto; font-size:11px;">${tt}</span>
                  ${lt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${lt}</div>`:null}
                  ${et?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${et}</div>`:null}
                  ${O?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${O.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${gt(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(L=>o`<div>violation: ${L}</div>`)}
                </div>`:null}
            ${u.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${u.map(L=>o`<div>warning: ${L}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Qm({state:t,nowMs:e}){var r,u,d;const n=Wt.value||((r=t.session)==null?void 0:r.room)||"",a=((u=t.current_round)==null?void 0:u.phase)??((d=t.session)==null?void 0:d.status)??"unknown",s=hl(e),i=jm(e);return o`
    <${w} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${s?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${s?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${s?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${s?o`<button class="trpg-run-btn recommend" onClick=${()=>Fm(n,a)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Wa(),A("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Ym({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>zm(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Xm({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${w} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${w} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${bl} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${w} title="맵" style="margin-top:16px;">
              <${Um} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${w} title="현재 라운드">
          <${Sl} state=${t} />
        <//>

        <${w} title="기여도" style="margin-top:16px;">
          <${xl} state=${t} />
        <//>

        <${w} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>o`<${yl} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${kl} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Zm({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${w} title=${`이벤트 타임라인 (${e.length})`}>
          <${Bm} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${w} title="최근 라운드 결과">
          <${Al} />
        <//>

        <${w} title="현재 라운드" style="margin-top:16px;">
          <${Sl} state=${t} />
        <//>
      </div>
    </div>
  `}function tf({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${Qm} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${w} title="조작 패널">
            <${Gm} state=${t} nowMs=${e} />
          <//>

          <${w} title="Actor Spawn" style="margin-top:16px;">
            <${Jm} state=${t} />
          <//>

          <${w} title="Mid-Join Gate" style="margin-top:16px;">
            <${Vm} state=${t} nowMs=${e} />
          <//>

          <${w} title="최근 라운드 결과" style="margin-top:16px;">
            <${Al} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${w} title="기여도" style="margin-top:0;">
            <${xl} state=${t} />
          <//>

          <${w} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>o`<${yl} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${kl} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function ef(){var u,d,v,p,l;const t=Hr.value,e=oi.value;if(qt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const c=window.setInterval(()=>{Bo.value=Date.now()},1e3);return()=>{window.clearInterval(c)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Jt()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,i=gl.value,r=Bo.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Wt.value||((u=t.session)==null?void 0:u.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((v=t.session)==null?void 0:v.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Jt()}>새로고침</button>
      </div>

      <${Wm} outcome=${s} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((p=t.session)==null?void 0:p.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((l=t.current_round)==null?void 0:l.round_number)??0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${n.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Events</div>
          <div class="stat-value">${a.length}</div>
        </div>
      </div>

      <${Ym} active=${i} />

      ${i==="overview"?o`<${Xm} state=${t} />`:i==="timeline"?o`<${Zm} state=${t} />`:o`<${tf} state=${t} nowMs=${r} />`}
    </div>
  `}const Gi="masc_dashboard_agent_name";function nf(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Gi);return e??n??"dashboard"}const $t=g(nf()),xn=g(""),Sn=g(""),Ga=g(""),wl=g(null),Ja=g(null),An=g(!1),Me=g(!1),wn=g(!1),Tn=g(!1),Va=g(!1),Qa=g(!1),os=g(!1);function Ya(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function ga(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function Tl(t){return!t||t.length===0?"none":t.join(", ")}function af(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Ya(t.quiet_start)}-${Ya(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${ga(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${ga(t.interval_s)}.`:`Lodge ticks every ${ga(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function Ze(){We();try{await xe()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function Ji(t){const e=t.trim();$t.value=e,e&&localStorage.setItem(Gi,e)}function sf(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Ni(){const t=$t.value.trim();if(t){wn.value=!0;try{const e=await au(t),n=sf(e);n&&Ji(n),os.value=!0,await Ze(),A(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";A(n,"error")}finally{wn.value=!1}}}async function of(){const t=$t.value.trim();if(t){Tn.value=!0;try{await zr(t),os.value=!1,await Ze(),A(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";A(n,"error")}finally{Tn.value=!1}}}async function rf(){const t=$t.value.trim();if(t)try{await zr(t)}catch{}localStorage.removeItem(Gi),Ji("dashboard"),os.value=!1,await Ni()}async function lf(){const t=$t.value.trim();if(t){Va.value=!0;try{await su(t),await Ze(),A("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";A(n,"error")}finally{Va.value=!1}}}async function Wo(){const t=$t.value.trim(),e=xn.value.trim();if(!(!t||!e)){An.value=!0;try{await Mr(t,e),xn.value="",await Ze(),A("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";A(a,"error")}finally{An.value=!1}}}async function cf(){const t=Sn.value.trim(),e=Ga.value.trim()||"Created from dashboard";if(t){Me.value=!0;try{await nu(t,e,1),Sn.value="",Ga.value="",await Ze(),A("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";A(a,"error")}finally{Me.value=!1}}}async function Go(){const t=$t.value.trim()||"dashboard";Qa.value=!0,Ja.value=null;try{const e=await Kn({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=ji(e.result);wl.value=n,await Ze(),n!=null&&n.skipped_reason?A(n.skipped_reason,"warning"):A(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";Ja.value=n,A(n,"error")}finally{Qa.value=!1}}function uf({runtime:t}){var s,i;const e=wl.value??(t==null?void 0:t.last_tick_result)??null;if(Ja.value)return o`<div class="control-result-box is-error">${Ja.value}</div>`;if(!e)return o`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((s=e.skipped_rows)==null?void 0:s.slice(0,3))??[],a=((i=e.passed_rows)==null?void 0:i.slice(0,3))??[];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?o`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${Tl(e.acted_names)}</div>
      ${e.skipped_reason?o`<div class="control-status-copy">${e.skipped_reason}</div>`:null}
      ${e.activity_report?o`<pre class="control-transcript-text">${e.activity_report}</pre>`:null}
      ${n.length>0?o`
            <div class="control-result-list">
              ${n.map(r=>o`<div>${r.name}: ${r.reason??"skipped"}</div>`)}
            </div>
          `:null}
      ${a.length>0?o`
            <div class="control-result-list">
              ${a.map(r=>o`<div>${r.name}: ${r.reason??"passed"}</div>`)}
            </div>
          `:null}
    </div>
  `}function df(t){return t.find(n=>n.name===dn.value)??t[0]??null}function pf(){var a,s;const t=Dt.value,e=((a=ue.value)==null?void 0:a.lodge)??null,n=df(t);return qt(()=>{Ni()},[]),qt(()=>{var r;const i=((r=t[0])==null?void 0:r.name)??"";if(!dn.value&&i){la(i);return}dn.value&&!t.some(u=>u.name===dn.value)&&la(i)},[t.map(i=>i.name).join("|")]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Room Identity</h4>
          <p class="control-help">Broadcasts and operator actions use this agent name.</p>
        </div>

        <label class="control-label" for="dock-agent">Agent</label>
        <input
          id="dock-agent"
          class="control-input"
          type="text"
          value=${$t.value}
          onInput=${i=>Ji(i.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Ni()}}
            disabled=${wn.value||$t.value.trim()===""}
          >
            ${wn.value?"Joining...":os.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{of()}}
            disabled=${Tn.value||$t.value.trim()===""}
          >
            ${Tn.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{rf()}}
            disabled=${wn.value||Tn.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{lf()}}
            disabled=${Va.value||$t.value.trim()===""}
          >
            ${Va.value?"Pinging...":"Heartbeat"}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Room Broadcast</h4>
          <p class="control-help">This is visible to the room and other agents. Use it for announcements, nudges, and @mentions, not private keeper prompts.</p>
        </div>

        <label class="control-label" for="dock-message">Broadcast</label>
        <div class="control-row">
          <input
            id="dock-message"
            class="control-input"
            type="text"
            placeholder="@agent or room-wide update"
            value=${xn.value}
            onInput=${i=>{xn.value=i.target.value}}
            onKeyDown=${i=>{i.key==="Enter"&&Wo()}}
            disabled=${An.value}
          />
          <button
            class="control-btn"
            onClick=${()=>{Wo()}}
            disabled=${An.value||xn.value.trim()===""||$t.value.trim()===""}
          >
            ${An.value?"Sending...":"Send"}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Keeper Direct Message</h4>
          <p class="control-help">This sends a 1:1 message through <code>masc_keeper_msg</code> and keeps the actual reply thread in the dock so you can see whether the keeper answered.</p>
        </div>

        <label class="control-label" for="dock-keeper">Keeper</label>
        <select
          id="dock-keeper"
          class="control-input"
          value=${(n==null?void 0:n.name)??""}
          onInput=${i=>{la(i.target.value)}}
          disabled=${t.length===0}
        >
          ${t.length===0?o`<option value="">No keepers available</option>`:t.map(i=>o`<option value=${i.name}>${i.name}</option>`)}
        </select>

        <${el} keeper=${n} />
        <${al}
          actor=${$t.value.trim()||"dashboard"}
          keeper=${n}
          onPokeLodge=${()=>{Go()}}
        />
        <${nl}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${af(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${ga(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${Ya(e==null?void 0:e.quiet_start)}-${Ya(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${Tl((s=e==null?void 0:e.last_tick_result)==null?void 0:s.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?o`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{Go()}}
            disabled=${Qa.value}
          >
            ${Qa.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${uf} runtime=${e} />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Quick Task</h4>
          <p class="control-help">Fast backlog injection for local follow-up work.</p>
        </div>

        <input
          id="dock-task"
          class="control-input"
          type="text"
          placeholder="Task title"
          value=${Sn.value}
          onInput=${i=>{Sn.value=i.target.value}}
          disabled=${Me.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${Ga.value}
          onInput=${i=>{Ga.value=i.target.value}}
          disabled=${Me.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{cf()}}
          disabled=${Me.value||Sn.value.trim()===""}
        >
          ${Me.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const Jo=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],Ri=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals, MDAL loops, and task backlog in one planning surface"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],Vo="masc_dashboard_quick_actions_open";function vf(){const t=Vt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${qn.value} events</span>
    </div>
  `}function mf(){const t=Ft.value.tab,e=Vt.value,n=Ri.find(r=>r.id===t),a=Jo.find(r=>r.id===(n==null?void 0:n.group)),[s,i]=pr(()=>{const r=localStorage.getItem(Vo);return r!=="0"});return qt(()=>{localStorage.setItem(Vo,s?"1":"0")},[s]),o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${a?o`<span class="rail-section-chip">${a.label}</span>`:null}
        </div>
        ${Jo.map(r=>o`
          <div class="rail-nav-group" key=${r.id}>
            <div class="rail-group-label">${r.label}</div>
            <div class="rail-group-copy">${r.description}</div>
            <div class="rail-tab-list">
              ${Ri.filter(u=>u.group===r.id).map(u=>o`
                  <button
                    class="rail-tab-btn ${t===u.id?"active":""}"
                    onClick=${()=>zt(u.id)}
                  >
                    <span class="rail-tab-icon">${u.icon}</span>
                    <span class="rail-tab-copy">
                      <strong>${u.label}</strong>
                      <span>${u.description}</span>
                    </span>
                  </button>
                `)}
            </div>
          </div>
        `)}
        <div class="rail-view-note">
          <div class="rail-view-note-label">Current focus</div>
          <strong>${(n==null?void 0:n.label)??t}</strong>
          <p>${(n==null?void 0:n.description)??"Live operational view"}</p>
        </div>
      </section>

      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Snapshot</h3>
          <span class="rail-section-chip ${e?"ok":"bad"}">${e?"Live":"Offline"}</span>
        </div>
        <div class="rail-stat-grid">
          <div class="rail-stat-card">
            <span>Agents</span>
            <strong>${Zt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Keepers</span>
            <strong>${Dt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Tasks</span>
            <strong>${yt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Events</span>
            <strong>${qn.value}</strong>
          </div>
        </div>
        <div class="rail-snapshot-copy">
          <span>Connection ${e?"healthy":"recovering"}</span>
          <span>${(a==null?void 0:a.label)??"Observe"} workspace active</span>
        </div>
        <div class="rail-inline-actions">
          <button
            class="rail-refresh-btn"
            onClick=${()=>{xe(),t==="command"&&ns(),t==="ops"&&Wn(),t==="board"&&Gt(),t==="trpg"&&Jt(),t==="goals"&&(Sa(),Ln())}}
          >
            Refresh Now
          </button>
          <button class="rail-secondary-btn" onClick=${()=>zt("ops")}>
            Open Ops
          </button>
        </div>
      </section>

      <section class="rail-card fold-card">
        <div class="rail-card-head">
          <h3>Quick Actions</h3>
          <span class="rail-section-chip">${s?"Open":"Closed"}</span>
        </div>
        <button class="fold-toggle" onClick=${()=>i(r=>!r)}>
          <span>${s?"Hide inline actions":"Show inline actions"}</span>
          <span class="fold-toggle-meta">Join, broadcast, keeper DM, lodge poke</span>
        </button>
        ${s?o`<div class="rail-fold-body"><${pf} /></div>`:o`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function ff(){switch(Ft.value.tab){case"command":return o`<${tv} />`;case"overview":return o`<${Do} />`;case"ops":return o`<${kv} />`;case"board":return o`<${Fv} />`;case"agents":return o`<${_m} />`;case"goals":return o`<${wm} />`;case"trpg":return o`<${ef} />`;default:return o`<${Do} />`}}function _f(){qt(()=>{Zl(),Dr(),xe();const n=Ju();return Vu(),()=>{rc(),n(),Qu()}},[]),qt(()=>{const n=Ft.value.tab;n==="command"&&ns(),n==="ops"&&Wn(),n==="board"&&Gt(),n==="trpg"&&Jt(),n==="goals"&&(Sa(),Ln())},[Ft.value.tab]);const t=Ft.value.tab,e=Ri.find(n=>n.id===t);return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${(e==null?void 0:e.description)??"Decision and execution operations console"}</p>
        </div>
        <div class="header-right">
          <button
            class="activity-panel-toggle ${Je.value?"active":""}"
            onClick=${Dd}
            title="Toggle Activity Panel"
          >
            Activity
          </button>
          <${vf} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${mf} />
        <main class="dashboard-main">
          ${ii.value&&!Vt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${ff} />`}
        </main>
      </div>

      ${Je.value?o`
        <div class="activity-panel-backdrop" onClick=${wo} />
        <aside class="activity-panel">
          <div class="activity-panel-header">
            <h3>Activity Feed</h3>
            <button class="activity-panel-close" onClick=${wo}>Close</button>
          </div>
          <div class="activity-panel-body">
            <${im} />
          </div>
        </aside>
      `:null}

      <${Nd} />
      <${rd} />
      <${nd} />
    </div>
  `}const Qo=document.getElementById("app");Qo&&El(o`<${_f} />`,Qo);
