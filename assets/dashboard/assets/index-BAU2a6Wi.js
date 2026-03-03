var fi=Object.defineProperty;var _i=(t,e,n)=>e in t?fi(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var yt=(t,e,n)=>_i(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var Be,L,Ga,Ja,vt,fa,Wa,Va,Ya,Xn,Sn,Cn,ee={},Qa=[],gi=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Ke=Array.isArray;function st(t,e){for(var n in e)t[n]=e[n];return t}function Zn(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function Xa(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Be.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return ke(t,r,a,s,null)}function ke(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++Ga,__i:-1,__u:0};return s==null&&L.vnode!=null&&L.vnode(i),i}function re(t){return t.children}function Ot(t,e){this.props=t,this.context=e}function Nt(t,e){if(e==null)return t.__?Nt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?Nt(t):null}function Za(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return Za(t)}}function _a(t){(!t.__d&&(t.__d=!0)&&vt.push(t)&&!Ne.__r++||fa!=L.debounceRendering)&&((fa=L.debounceRendering)||Wa)(Ne)}function Ne(){for(var t,e,n,a,s,i,r,c=1;vt.length;)vt.length>c&&vt.sort(Va),t=vt.shift(),c=vt.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=st({},a)).__v=a.__v+1,L.vnode&&L.vnode(n),ta(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??Nt(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,ns(i,n,r),a.__e=a.__=null,n.__e!=s&&Za(n)));Ne.__r=0}function ts(t,e,n,a,s,i,r,c,u,d,m){var l,p,v,g,x,S,A,C=a&&a.__k||Qa,E=e.length;for(u=$i(n,e,C,u,E),l=0;l<E;l++)(v=n.__k[l])!=null&&(p=v.__i==-1?ee:C[v.__i]||ee,v.__i=l,S=ta(t,v,p,s,i,r,c,u,d,m),g=v.__e,v.ref&&p.ref!=v.ref&&(p.ref&&ea(p.ref,null,v),m.push(v.ref,v.__c||g,v)),x==null&&g!=null&&(x=g),(A=!!(4&v.__u))||p.__k===v.__k?u=es(v,u,t,A):typeof v.type=="function"&&S!==void 0?u=S:g&&(u=g.nextSibling),v.__u&=-7);return n.__e=x,u}function $i(t,e,n,a,s){var i,r,c,u,d,m=n.length,l=m,p=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=ke(null,r,null,null,null):Ke(r)?r=t.__k[i]=ke(re,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=ke(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,u=i+p,r.__=t,r.__b=t.__b+1,c=null,(d=r.__i=hi(r,n,u,l))!=-1&&(l--,(c=n[d])&&(c.__u|=2)),c==null||c.__v==null?(d==-1&&(s>m?p--:s<m&&p++),typeof r.type!="function"&&(r.__u|=4)):d!=u&&(d==u-1?p--:d==u+1?p++:(d>u?p--:p++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<m;i++)(c=n[i])!=null&&(2&c.__u)==0&&(c.__e==a&&(a=Nt(c)),ss(c,c));return a}function es(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=es(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=Nt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function hi(t,e,n,a){var s,i,r,c=t.key,u=t.type,d=e[n],m=d!=null&&(2&d.__u)==0;if(d===null&&c==null||m&&c==d.key&&u==d.type)return n;if(a>(m?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((d=e[r=s>=0?s--:i++])!=null&&(2&d.__u)==0&&c==d.key&&u==d.type)return r}return-1}function ga(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||gi.test(e)?n:n+"px"}function ve(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||ga(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||ga(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Ya,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=Xn,t.addEventListener(e,i?Cn:Sn,i)):t.removeEventListener(e,i?Cn:Sn,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function $a(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Xn++;else if(e.t<n.u)return;return n(L.event?L.event(e):e)}}}function ta(t,e,n,a,s,i,r,c,u,d){var m,l,p,v,g,x,S,A,C,E,O,D,q,dt,pt,G,nt,R=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(u=!!(32&n.__u),i=[c=e.__e=n.__e]),(m=L.__b)&&m(e);t:if(typeof R=="function")try{if(A=e.props,C="prototype"in R&&R.prototype.render,E=(m=R.contextType)&&a[m.__c],O=m?E?E.props.value:m.__:a,n.__c?S=(l=e.__c=n.__c).__=l.__E:(C?e.__c=l=new R(A,O):(e.__c=l=new Ot(A,O),l.constructor=R,l.render=bi),E&&E.sub(l),l.state||(l.state={}),l.__n=a,p=l.__d=!0,l.__h=[],l._sb=[]),C&&l.__s==null&&(l.__s=l.state),C&&R.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=st({},l.__s)),st(l.__s,R.getDerivedStateFromProps(A,l.__s))),v=l.props,g=l.state,l.__v=e,p)C&&R.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),C&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(C&&R.getDerivedStateFromProps==null&&A!==v&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(A,O),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(A,l.__s,O)===!1){for(e.__v!=n.__v&&(l.props=A,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(M){M&&(M.__=e)}),D=0;D<l._sb.length;D++)l.__h.push(l._sb[D]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(A,l.__s,O),C&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(v,g,x)})}if(l.context=O,l.props=A,l.__P=t,l.__e=!1,q=L.__r,dt=0,C){for(l.state=l.__s,l.__d=!1,q&&q(e),m=l.render(l.props,l.state,l.context),pt=0;pt<l._sb.length;pt++)l.__h.push(l._sb[pt]);l._sb=[]}else do l.__d=!1,q&&q(e),m=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++dt<25);l.state=l.__s,l.getChildContext!=null&&(a=st(st({},a),l.getChildContext())),C&&!p&&l.getSnapshotBeforeUpdate!=null&&(x=l.getSnapshotBeforeUpdate(v,g)),G=m,m!=null&&m.type===re&&m.key==null&&(G=as(m.props.children)),c=ts(t,Ke(G)?G:[G],e,n,a,s,i,r,c,u,d),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),S&&(l.__E=l.__=null)}catch(M){if(e.__v=null,u||i!=null)if(M.then){for(e.__u|=u?160:128;c&&c.nodeType==8&&c.nextSibling;)c=c.nextSibling;i[i.indexOf(c)]=null,e.__e=c}else{for(nt=i.length;nt--;)Zn(i[nt]);An(e)}else e.__e=n.__e,e.__k=n.__k,M.then||An(e);L.__e(M,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):c=e.__e=yi(n.__e,e,n,a,s,i,r,u,d);return(m=L.diffed)&&m(e),128&e.__u?void 0:c}function An(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(An)}function ns(t,e,n){for(var a=0;a<n.length;a++)ea(n[a],n[++a],n[++a]);L.__c&&L.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){L.__e(i,s.__v)}})}function as(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Ke(t)?t.map(as):st({},t)}function yi(t,e,n,a,s,i,r,c,u){var d,m,l,p,v,g,x,S=n.props||ee,A=e.props,C=e.type;if(C=="svg"?s="http://www.w3.org/2000/svg":C=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(d=0;d<i.length;d++)if((v=i[d])&&"setAttribute"in v==!!C&&(C?v.localName==C:v.nodeType==3)){t=v,i[d]=null;break}}if(t==null){if(C==null)return document.createTextNode(A);t=document.createElementNS(s,C,A.is&&A),c&&(L.__m&&L.__m(e,i),c=!1),i=null}if(C==null)S===A||c&&t.data==A||(t.data=A);else{if(i=i&&Be.call(t.childNodes),!c&&i!=null)for(S={},d=0;d<t.attributes.length;d++)S[(v=t.attributes[d]).name]=v.value;for(d in S)if(v=S[d],d!="children"){if(d=="dangerouslySetInnerHTML")l=v;else if(!(d in A)){if(d=="value"&&"defaultValue"in A||d=="checked"&&"defaultChecked"in A)continue;ve(t,d,null,v,s)}}for(d in A)v=A[d],d=="children"?p=v:d=="dangerouslySetInnerHTML"?m=v:d=="value"?g=v:d=="checked"?x=v:c&&typeof v!="function"||S[d]===v||ve(t,d,v,S[d],s);if(m)c||l&&(m.__html==l.__html||m.__html==t.innerHTML)||(t.innerHTML=m.__html),e.__k=[];else if(l&&(t.innerHTML=""),ts(e.type=="template"?t.content:t,Ke(p)?p:[p],e,n,a,C=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&Nt(n,0),c,u),i!=null)for(d=i.length;d--;)Zn(i[d]);c||(d="value",C=="progress"&&g==null?t.removeAttribute("value"):g!=null&&(g!==t[d]||C=="progress"&&!g||C=="option"&&g!=S[d])&&ve(t,d,g,S[d],s),d="checked",x!=null&&x!=t[d]&&ve(t,d,x,S[d],s))}return t}function ea(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){L.__e(s,n)}}function ss(t,e,n){var a,s;if(L.unmount&&L.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||ea(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){L.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&ss(a[s],e,n||typeof t.type!="function");n||Zn(t.__e),t.__c=t.__=t.__e=void 0}function bi(t,e,n){return this.constructor(t,n)}function xi(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),L.__&&L.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],ta(e,t=e.__k=Xa(re,null,[t]),s||ee,ee,e.namespaceURI,s?null:e.firstChild?Be.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),ns(i,t,r)}Be=Qa.slice,L={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(c){t=c}throw t}},Ga=0,Ja=function(t){return t!=null&&t.constructor===void 0},Ot.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=st({},this.state),typeof t=="function"&&(t=t(st({},n),this.props)),t&&st(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),_a(this))},Ot.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),_a(this))},Ot.prototype.render=re,vt=[],Wa=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Va=function(t,e){return t.__v.__b-e.__v.__b},Ne.__r=0,Ya=/(PointerCapture)$|Capture$/i,Xn=0,Sn=$a(!1),Cn=$a(!0);var is=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],c=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=c:r===4?a[1]=Object.assign(a[1]||{},c):r===5?(a[1]=a[1]||{})[e[++i]]=c:r===6?a[1][e[++i]]+=c+"":r?(s=t.apply(c,is(t,c,n,["",null])),a.push(s),c[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(c)}return a},ha=new Map;function ki(t){var e=ha.get(this);return e||(e=new Map,ha.set(this,e)),(e=is(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",c="",u=[0],d=function(p){i===1&&(p||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?u.push(0,p,r):i===3&&(p||r)?(u.push(3,p,r),i=2):i===2&&r==="..."&&p?u.push(4,p,0):i===2&&r&&!p?u.push(5,0,!0,r):i>=5&&((r||!p&&i===5)&&(u.push(i,0,r,s),i=6),p&&(u.push(i,p,0,s),i=6)),r=""},m=0;m<n.length;m++){m&&(i===1&&d(),d(m));for(var l=0;l<n[m].length;l++)a=n[m][l],i===1?a==="<"?(d(),u=[u],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:c?a===c?c="":r+=a:a==='"'||a==="'"?c=a:a===">"?(d(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[m][l+1]===">")?(d(),i===3&&(u=u[0]),i=u,(u=u[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(d(),i=2):r+=a),i===3&&r==="!--"&&(i=4,u=u[0])}return d(),u})(t)),e),arguments,[])).length>1?e:e[0]}var o=ki.bind(Xa),ne,I,Qe,ya,Nn=0,os=[],P=L,ba=P.__b,xa=P.__r,ka=P.diffed,wa=P.__c,Sa=P.unmount,Ca=P.__;function na(t,e){P.__h&&P.__h(I,t,Nn||e),Nn=0;var n=I.__H||(I.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function me(t){return Nn=1,wi(cs,t)}function wi(t,e,n){var a=na(ne++,2);if(a.t=t,!a.__c&&(a.__=[cs(void 0,e),function(c){var u=a.__N?a.__N[0]:a.__[0],d=a.t(u,c);u!==d&&(a.__N=[d,a.__[1]],a.__c.setState({}))}],a.__c=I,!I.__f)){var s=function(c,u,d){if(!a.__c.__H)return!0;var m=a.__c.__H.__.filter(function(p){return!!p.__c});if(m.every(function(p){return!p.__N}))return!i||i.call(this,c,u,d);var l=a.__c.props!==c;return m.forEach(function(p){if(p.__N){var v=p.__[0];p.__=p.__N,p.__N=void 0,v!==p.__[0]&&(l=!0)}}),i&&i.call(this,c,u,d)||l};I.__f=!0;var i=I.shouldComponentUpdate,r=I.componentWillUpdate;I.componentWillUpdate=function(c,u,d){if(this.__e){var m=i;i=void 0,s(c,u,d),i=m}r&&r.call(this,c,u,d)},I.shouldComponentUpdate=s}return a.__N||a.__}function ft(t,e){var n=na(ne++,3);!P.__s&&ls(n.__H,e)&&(n.__=t,n.u=e,I.__H.__h.push(n))}function rs(t,e){var n=na(ne++,7);return ls(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Si(){for(var t;t=os.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(we),t.__H.__h.forEach(Tn),t.__H.__h=[]}catch(e){t.__H.__h=[],P.__e(e,t.__v)}}P.__b=function(t){I=null,ba&&ba(t)},P.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Ca&&Ca(t,e)},P.__r=function(t){xa&&xa(t),ne=0;var e=(I=t.__c).__H;e&&(Qe===I?(e.__h=[],I.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(we),e.__h.forEach(Tn),e.__h=[],ne=0)),Qe=I},P.diffed=function(t){ka&&ka(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(os.push(e)!==1&&ya===P.requestAnimationFrame||((ya=P.requestAnimationFrame)||Ci)(Si)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Qe=I=null},P.__c=function(t,e){e.some(function(n){try{n.__h.forEach(we),n.__h=n.__h.filter(function(a){return!a.__||Tn(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],P.__e(a,n.__v)}}),wa&&wa(t,e)},P.unmount=function(t){Sa&&Sa(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{we(a)}catch(s){e=s}}),n.__H=void 0,e&&P.__e(e,n.__v))};var Aa=typeof requestAnimationFrame=="function";function Ci(t){var e,n=function(){clearTimeout(a),Aa&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);Aa&&(e=requestAnimationFrame(n))}function we(t){var e=I,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),I=e}function Tn(t){var e=I;t.__c=t.__(),I=e}function ls(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}function cs(t,e){return typeof e=="function"?e(t):e}var Ai=Symbol.for("preact-signals");function qe(){if(lt>1)lt--;else{for(var t,e=!1;Ft!==void 0;){var n=Ft;for(Ft=void 0,Rn++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&ps(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(Rn=0,lt--,e)throw t}}function Ni(t){if(lt>0)return t();lt++;try{return t()}finally{qe()}}var T=void 0;function us(t){var e=T;T=void 0;try{return t()}finally{T=e}}var Ft=void 0,lt=0,Rn=0,Te=0;function ds(t){if(T!==void 0){var e=t.n;if(e===void 0||e.t!==T)return e={i:0,S:t,p:T.s,n:void 0,t:T,e:void 0,x:void 0,r:e},T.s!==void 0&&(T.s.n=e),T.s=e,t.n=e,32&T.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=T.s,e.n=void 0,T.s.n=e,T.s=e),e}}function j(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}j.prototype.brand=Ai;j.prototype.h=function(){return!0};j.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:us(function(){var a;(a=e.W)==null||a.call(e)}))};j.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&us(function(){var s;(s=e.Z)==null||s.call(e)}))}};j.prototype.subscribe=function(t){var e=this;return le(function(){var n=e.value,a=T;T=void 0;try{t(n)}finally{T=a}},{name:"sub"})};j.prototype.valueOf=function(){return this.value};j.prototype.toString=function(){return this.value+""};j.prototype.toJSON=function(){return this.value};j.prototype.peek=function(){var t=T;T=void 0;try{return this.value}finally{T=t}};Object.defineProperty(j.prototype,"value",{get:function(){var t=ds(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Rn>100)throw new Error("Cycle detected");this.v=t,this.i++,Te++,lt++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{qe()}}}});function _(t,e){return new j(t,e)}function ps(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function vs(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function ms(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function _t(t,e){j.call(this,void 0),this.x=t,this.s=void 0,this.g=Te-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}_t.prototype=new j;_t.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===Te))return!0;if(this.g=Te,this.f|=1,this.i>0&&!ps(this))return this.f&=-2,!0;var t=T;try{vs(this),T=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return T=t,ms(this),this.f&=-2,!0};_t.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}j.prototype.S.call(this,t)};_t.prototype.U=function(t){if(this.t!==void 0&&(j.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};_t.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(_t.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=ds(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function Q(t,e){return new _t(t,e)}function fs(t){var e=t.u;if(t.u=void 0,typeof e=="function"){lt++;var n=T;T=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,aa(t),a}finally{T=n,qe()}}}function aa(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,fs(t)}function Ti(t){if(T!==this)throw new Error("Out-of-order effect");ms(this),T=t,this.f&=-2,8&this.f&&aa(this),qe()}function Lt(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Lt.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Lt.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,fs(this),vs(this),lt++;var t=T;return T=this,Ti.bind(this,t)};Lt.prototype.N=function(){2&this.f||(this.f|=2,this.o=Ft,Ft=this)};Lt.prototype.d=function(){this.f|=8,1&this.f||aa(this)};Lt.prototype.dispose=function(){this.d()};function le(t,e){var n=new Lt(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var _s,fe,Ri=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,gs=[];le(function(){_s=this.N})();function Dt(t,e){L[t]=e.bind(null,L[t]||function(){})}function Re(t){if(fe){var e=fe;fe=void 0,e()}fe=t&&t.S()}function $s(t){var e=this,n=t.data,a=Di(n);a.value=n;var s=rs(function(){for(var c=e,u=e.__v;u=u.__;)if(u.__c){u.__c.__$f|=4;break}var d=Q(function(){var v=a.value.value;return v===0?0:v===!0?"":v||""}),m=Q(function(){return!Array.isArray(d.value)&&!Ja(d.value)}),l=le(function(){if(this.N=hs,m.value){var v=d.value;c.__v&&c.__v.__e&&c.__v.__e.nodeType===3&&(c.__v.__e.data=v)}}),p=e.__$u.d;return e.__$u.d=function(){l(),p.call(this)},[m,d]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}$s.displayName="ReactiveTextNode";Object.defineProperties(j.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:$s},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});Dt("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof j&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});Dt("__r",function(t,e){if(t(e),e.type!==re){Re();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return le(function(){r=this},{name:i}),r.c=s,r})(function(){var s;Ri&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),Re(n)}});Dt("__e",function(t,e,n,a){Re(),t(e,n,a)});Dt("diffed",function(t,e){Re();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var c=i[r];c!==void 0&&!(r in a)&&(c.d(),i[r]=void 0)}else i={},n.U=i;for(var u in a){var d=i[u],m=a[u];d===void 0?(d=Li(n,u,m),i[u]=d):d.o(m,s)}for(var l in a)s[l]=a[l]}}t(e)});function Li(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=_(n),r=n.peek();return{o:function(c,u){i.value=c,r=c.peek()},d:le(function(){this.N=hs;var c=i.value.value;r!==c?(r=void 0,s?t[e]=c:c!=null&&(c!==!1||e[4]==="-")?t.setAttribute(e,c):t.removeAttribute(e)):r=void 0})}}Dt("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var c=r.__$u;c&&(r.__$u=void 0,c.d())}}t(e)});Dt("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});Ot.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var c in this.props)if(!(c in t))return!0;return!1};function Di(t,e){return rs(function(){return _(t,e)},[])}var Ei=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Ii(){Ni(function(){for(var t;t=gs.shift();)_s.call(t)})}function hs(){gs.push(this)===1&&(L.requestAnimationFrame||Ei)(Ii)}const Pi=["overview","execution","board","activity","agents","tasks","goals","journal","trpg","council","mdal"],ys={tab:"overview",params:{},postId:null};function Na(t){return!!t&&Pi.includes(t)}function Ln(t){try{return decodeURIComponent(t)}catch{return t}}function Dn(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function Mi(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function bs(t,e){const n=t[0],a=e.tab,s=Na(n)?n:Na(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Ln(t[2]):t[0]==="post"&&t[1]&&(i=Ln(t[1]))),{tab:s,params:e,postId:i}}function Le(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return ys;const n=Ln(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const c=n.indexOf("?");c>=0&&(a=n.slice(0,c),s=n.slice(c+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=Dn(s),r=Mi(a);return bs(r,i)}function ji(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...ys,params:Dn(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=Dn(e.replace(/^\?/,""));return bs(a,s)}function xs(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const et=_(Le(window.location.hash));window.addEventListener("hashchange",()=>{et.value=Le(window.location.hash)});function Ge(t,e){const n={tab:t,params:{},postId:null};window.location.hash=xs(n)}function Oi(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Fi(){if(window.location.hash&&window.location.hash!=="#"){et.value=Le(window.location.hash);return}const t=ji(window.location.pathname,window.location.search);if(t){et.value=t;const e=xs(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",et.value=Le(window.location.hash)}const ks=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"goals",label:"Goals",icon:"🎯"},{id:"execution",label:"Execution",icon:"🛠️"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"},{id:"mdal",label:"MDAL",icon:"📈"}];function zi(){const t=et.value.tab;return o`
    <div class="main-tab-bar">
      ${ks.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Ge(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const Ta="masc_dashboard_sse_session_id",Ui=1e3,Hi=15e3,Tt=_(!1),sa=_(0),ws=_(null),De=_([]);function Bi(){let t=sessionStorage.getItem(Ta);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Ta,t)),t}const Ki=200;function J(t,e){const n={agent:t,text:e,timestamp:Date.now()};De.value=[n,...De.value].slice(0,Ki)}let tt=null,Ct=null,En=0;function Ss(){Ct&&(clearTimeout(Ct),Ct=null)}function qi(){if(Ct)return;En++;const t=Math.min(En,5),e=Math.min(Hi,Ui*Math.pow(2,t));Ct=setTimeout(()=>{Ct=null,Cs()},e)}function Cs(){Ss(),tt&&(tt.close(),tt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",Bi());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);tt=i,i.onopen=()=>{tt===i&&(En=0,Tt.value=!0)},i.onerror=()=>{tt===i&&(Tt.value=!1,i.close(),tt=null,qi())},i.onmessage=r=>{try{const c=JSON.parse(r.data);sa.value++,ws.value=c,Gi(c)}catch{}}}function Gi(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":J(n,"Joined");break;case"agent_left":J(n,"Left");break;case"broadcast":J(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":J(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":J(n,"New post");break;case"board_comment":J(n,"New comment");break;case"keeper_heartbeat":J(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":J(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":J(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":J(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:J(n,e)}}function Ji(){Ss(),tt&&(tt.close(),tt=null),Tt.value=!1}function As(){return new URLSearchParams(window.location.search)}function Ns(){const t=As(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Ts(){return{...Ns(),"Content-Type":"application/json"}}const Wi=15e3,Rs=3e4,Vi=6e4,Ra=new Set([408,425,429,500,502,503,504]);class ce extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,i=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);yt(this,"method");yt(this,"path");yt(this,"status");yt(this,"statusText");yt(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function ia(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new ce({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(s)}}function Yi(){var e,n;const t=As();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function ut(t){const e=await ia(t,{headers:Ns()},Wi);if(!e.ok)throw new ce({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Qi(t){return new Promise(e=>setTimeout(e,t))}function Xi(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function Zi(t){if(t instanceof ce)return t.timeout||typeof t.status=="number"&&Ra.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Xi(t.message);return e!==null&&Ra.has(e)}async function ue(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!Zi(s)||a>=n)throw s;const i=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${i}ms`,s),await Qi(i),a+=1}}async function gt(t,e,n){const a=await ia(t,{method:"POST",headers:{...Ts(),...n??{}},body:JSON.stringify(e)},Rs);if(!a.ok)throw new ce({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function to(t,e,n,a=Rs){const s=await ia(t,{method:"POST",headers:{...Ts(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new ce({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function eo(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function no(t){var e,n,a,s,i,r,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const u=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(u)}return((c=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:c.text)??""}async function H(t,e){const n=await to("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Vi),a=eo(n);return no(a)}function ao(t="compact"){return ut(`/api/v1/dashboard?mode=${t}`)}function Rt(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function so(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Ls(t){if(!w(t))return null;const e=f(t.id,"").trim(),n=f(t.author,"").trim(),a=f(t.content,"").trim();if(!e||!n)return null;const s=N(t.score,0),i=N(t.votes_up,0),r=N(t.votes_down,0),c=N(t.votes,s||i-r),u=N(t.comment_count,N(t.reply_count,0)),d=(()=>{const g=t.flair;if(typeof g=="string"&&g.trim())return g.trim();if(w(g)){const S=f(g.name,"").trim();if(S)return S}return f(t.flair_name,"").trim()||void 0})(),m=f(t.created_at_iso,"").trim()||Rt(t.created_at),l=f(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Rt(t.updated_at):m),v=f(t.title,"").trim()||so(a);return{id:e,author:n,title:v,content:a,tags:[],votes:c,vote_balance:s,comment_count:u,created_at:m,updated_at:l,flair:d,hearth_count:N(t.hearth_count,0)}}function io(t){if(!w(t))return null;const e=f(t.id,"").trim(),n=f(t.post_id,"").trim(),a=f(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:f(t.content,""),created_at:Rt(t.created_at)}}async function oo(t){return ue("fetchBoard",async()=>{const e=new URLSearchParams;t&&e.set("sort_by",t),e.set("limit","100");const n=e.toString(),a=await ut(`/api/v1/board${n?`?${n}`:""}`);return{posts:Array.isArray(a.posts)?a.posts.map(Ls).filter(i=>i!==null):[]}})}async function ro(t){return ue("fetchBoardPost",async()=>{const e=await ut(`/api/v1/board/${t}?format=flat`),n=w(e.post)?e.post:e,a=Ls(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(io).filter(r=>r!==null);return{...a,comments:i}})}function Ds(t,e){return gt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Yi()})}function lo(t,e,n){return gt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function co(t){const e=f(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function z(...t){for(const e of t){const n=f(e,"");if(n.trim())return n.trim()}return""}function La(t){const e=co(z(t.outcome,t.result,t.result_code));if(!e)return;const n=z(t.reason,t.reason_code,t.description,t.detail),a=z(t.summary,t.summary_ko,t.summary_en,t.note),s=z(t.details,t.details_text,t.text,t.note),i=z(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=z(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=z(t.raw_reason,t.raw_reason_code,t.error_message),u=(()=>{const l=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof l=="string"?[l]:Array.isArray(l)?l.map(p=>{if(typeof p=="string")return p.trim();if(w(p)){const v=f(p.summary,"").trim();if(v)return v;const g=f(p.text,"").trim();if(g)return g;const x=f(p.type,"").trim();return x||f(p.event_id,"").trim()}return""}).filter(p=>p.length>0):[]})(),d=(()=>{const l=N(t.turn,Number.NaN);if(Number.isFinite(l))return l;const p=N(t.turn_number,Number.NaN);if(Number.isFinite(p))return p;const v=N(t.current_turn,Number.NaN);if(Number.isFinite(v))return v;const g=N(t.round,Number.NaN);return Number.isFinite(g)?g:void 0})(),m=z(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:u.length>0?u:void 0,raw_reason:c||void 0,turn:d,phase:m||void 0}}function uo(t,e){const n=w(t.state)?t.state:{};if(f(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>w(r)?f(r.type,"")==="session.outcome":!1),i=w(n.session_outcome)?n.session_outcome:{};if(w(i)&&Object.keys(i).length>0){const r=La(i);if(r)return r}if(w(s))return La(w(s.payload)?s.payload:{})}function w(t){return typeof t=="object"&&t!==null}function f(t,e=""){return typeof t=="string"?t:e}function N(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function po(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function In(t,e=!1){return typeof t=="boolean"?t:e}function Mt(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(w(e)){const n=f(e.name,"").trim(),a=f(e.id,"").trim(),s=f(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function vo(t){const e={};if(!w(t)&&!Array.isArray(t))return e;if(w(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),i=f(a,"").trim();!s||!i||(e[s]=i)}),e;for(const n of t){if(!w(n))continue;const a=z(n.to,n.target,n.actor_id,n.name,n.id),s=z(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function mo(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function B(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}const fo=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function _o(t){const e=w(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const i=a.trim();i&&(fo.has(i.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[i]=s))}),n}function go(t,e){if(t!=="dice.rolled")return;const n=N(e.raw_d20,0),a=N(e.total,0),s=N(e.bonus,0),i=f(e.action,"roll"),r=N(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function $o(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function ho(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function yo(t,e,n,a){const s=n||e||f(a.actor_id,"")||f(a.actor_name,"");switch(t){case"turn.action.proposed":{const i=f(a.proposed_action,f(a.reply,""));return i?`${s||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=f(a.reply,f(a.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return f(a.reply,f(a.content,f(a.text,"Narration")));case"dice.rolled":{const i=f(a.action,"roll"),r=N(a.total,0),c=N(a.dc,0),u=f(a.label,""),d=s||"actor",m=c>0?` vs DC ${c}`:"",l=u?` (${u})`:"";return`${d} ${i}: ${r}${m}${l}`}case"turn.started":return`Turn ${N(a.turn,1)} started`;case"phase.changed":return`Phase: ${f(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${f(a.name,w(a.actor)?f(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${f(a.keeper_name,f(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${f(a.keeper_name,f(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${N(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${N(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||f(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||f(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${f(a.reason_code,"unknown")}`;case"memory.signal":{const i=w(a.entity_refs)?a.entity_refs:{},r=f(i.requested_tier,""),c=f(i.effective_tier,""),u=In(i.guardrail_applied,!1),d=f(a.summary_en,f(a.summary_ko,"Memory signal"));if(!r&&!c)return d;const m=r&&c?`${r}->${c}`:c||r;return`${d} [${m}${u?" (guardrail)":""}]`}case"world.event":{if(f(a.event_type,"")==="canon.check"){const r=f(a.status,"unknown"),c=f(a.contract_id,"n/a");return`Canon ${r}: ${c}`}return f(a.description,f(a.summary,"World event"))}case"combat.attack":return f(a.summary,f(a.result,"Attack resolved"));case"combat.defense":return f(a.summary,f(a.result,"Defense resolved"));case"session.outcome":return f(a.summary,f(a.outcome,"Session ended"));default:{const i=$o(a);return i?`${t}: ${i}`:t}}}function bo(t,e){const n=w(t)?t:{},a=f(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=f(n.actor_name,"").trim()||e[s]||f(w(n.payload)?n.payload.actor_name:"",""),r=w(n.payload)?n.payload:{},c=f(n.ts,f(n.timestamp,new Date().toISOString())),u=f(n.phase,f(r.phase,"")),d=f(n.category,"");return{type:a,actor:i||s||f(r.actor_name,""),actor_id:s||f(r.actor_id,""),actor_name:i,seq:n.seq,room_id:f(n.room_id,""),phase:u||void 0,category:d||ho(a),visibility:f(n.visibility,f(r.visibility,"public")),event_id:f(n.event_id,""),content:yo(a,s,i,r),dice_roll:go(a,r),timestamp:c}}function xo(t,e,n){var G,nt;const a=f(t.room_id,"")||n||"default",s=w(t.state)?t.state:{},i=w(s.party)?s.party:{},r=w(s.actor_control)?s.actor_control:{},c=w(s.join_gate)?s.join_gate:{},u=w(s.contribution_ledger)?s.contribution_ledger:{},d=Object.entries(i).map(([R,M])=>{const $=w(M)?M:{},pe=B($,"max_hp",void 0,10),pa=B($,"hp",void 0,pe),ai=B($,"max_mp",void 0,0),si=B($,"mp",void 0,0),ii=B($,"level",void 0,1),oi=B($,"xp",void 0,0),ri=In($.alive,pa>0),va=r[R],ma=typeof va=="string"?va:void 0,li=mo($.role,R,ma),ci=po($.generation),ui=z($.joined_at,$.joinedAt,$.started_at,$.startedAt),di=z($.claimed_at,$.claimedAt,$.assigned_at,$.assignedAt,$.assigned_time),pi=z($.last_seen,$.lastSeen,$.last_seen_at,$.lastSeenAt,$.last_active,$.lastActive),vi=z($.scene,$.current_scene,$.currentScene,$.world_scene,$.scene_name,$.sceneName),mi=z($.location,$.current_location,$.currentLocation,$.position,$.zone,$.area);return{id:R,name:f($.name,R),role:li,keeper:ma,archetype:f($.archetype,""),persona:f($.persona,""),portrait:f($.portrait,"")||void 0,background:f($.background,"")||void 0,traits:Mt($.traits),skills:Mt($.skills),stats_raw:_o($),status:ri?"active":"dead",generation:ci,joined_at:ui||void 0,claimed_at:di||void 0,last_seen:pi||void 0,scene:vi||void 0,location:mi||void 0,inventory:Mt($.inventory),notes:Mt($.notes),relationships:vo($.relationships),stats:{hp:pa,max_hp:pe,mp:si,max_mp:ai,level:ii,xp:oi,strength:B($,"strength","str",10),dexterity:B($,"dexterity","dex",10),constitution:B($,"constitution","con",10),intelligence:B($,"intelligence","int",10),wisdom:B($,"wisdom","wis",10),charisma:B($,"charisma","cha",10)}}}),m=d.filter(R=>R.status!=="dead"),l=uo(t,e),p={phase_open:In(c.phase_open,!0),min_points:N(c.min_points,3),window:f(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},v=Object.entries(u).map(([R,M])=>{const $=w(M)?M:{};return{actor_id:R,score:N($.score,0),last_reason:f($.last_reason,"")||null,reasons:Mt($.reasons)}}),g=d.reduce((R,M)=>(R[M.id]=M.name,R),{}),x=e.map(R=>bo(R,g)),S=N(s.turn,1),A=f(s.phase,"round"),C=f(s.map,""),E=w(s.world)?s.world:{},O=C||f(E.ascii_map,f(E.map,"")),D=x.filter((R,M)=>{const $=e[M];if(!w($))return!1;const pe=w($.payload)?$.payload:{};return N(pe.turn,-1)===S}),q=(D.length>0?D:x).slice(-12),dt=f(s.status,"active");return{session:{id:a,room:a,status:dt==="ended"?"ended":dt==="paused"?"paused":"active",round:S,actors:m,created_at:((G=x[0])==null?void 0:G.timestamp)??new Date().toISOString()},current_round:{round_number:S,phase:A,events:q,timestamp:((nt=x[x.length-1])==null?void 0:nt.timestamp)??new Date().toISOString()},map:O||void 0,join_gate:p,contribution_ledger:v,outcome:l,party:m,story_log:x,history:[]}}async function ko(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await ut(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function wo(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([ut(`/api/v1/trpg/state${e}`),ko(t)]);return xo(n,a,t)}function So(t){return gt("/api/v1/trpg/rounds/run",{room_id:t})}function Co(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Ao(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),gt("/api/v1/trpg/dice/roll",e)}function No(t,e){const n=Co();return gt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function To(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),gt("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function Ro(t,e,n){return gt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Lo(t,e,n){const a=await H("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function Do(t){const e=await H("trpg.mid_join.request",t);return JSON.parse(e)}async function Es(t,e){await H("masc_broadcast",{agent_name:t,message:e})}async function Eo(t,e,n=1){await H("masc_add_task",{title:t,description:e,priority:n})}async function Io(t){return H("masc_join",{agent_name:t})}async function Is(t){await H("masc_leave",{agent_name:t})}async function Po(t){await H("masc_heartbeat",{agent_name:t})}async function Mo(t=40){return(await H("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function jo(t,e=20){return H("masc_task_history",{task_id:t,limit:e})}async function Oo(){return ue("fetchDebates",async()=>{const t=await ut("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!w(e))return null;const n=f(e.id,"").trim(),a=f(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:f(e.status,"open"),argument_count:N(e.argument_count,0),created_at:Rt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Fo(){return ue("fetchCouncilSessions",async()=>{const t=await ut("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!w(e))return null;const n=f(e.id,"").trim(),a=f(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:f(e.initiator,"system"),votes:N(e.votes,0),quorum:N(e.quorum,0),state:f(e.state,"open"),created_at:Rt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function zo(t){const e=await H("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Uo(t){return ue("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await ut(`/api/v1/council/debates/${e}/summary`);if(!w(n))return null;const a=f(n.id,"").trim();return a?{id:a,topic:f(n.topic,""),status:f(n.status,"open"),support_count:N(n.support_count,0),oppose_count:N(n.oppose_count,0),neutral_count:N(n.neutral_count,0),total_arguments:N(n.total_arguments,0),created_at:Rt(n.created_at_iso??n.created_at),summary_text:f(n.summary_text,"")}:null})}async function Ho(){try{const t=await H("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Et=_([]),de=_([]),Ps=_([]),It=_([]),$t=_(null),jt=_(null),Pn=_(new Map),Ms=_([]),Mn=_("hot"),js=_(null),it=_(""),Je=_([]),zt=_(!1),at=_(new Map),jn=_(!1),On=_(!1),Fn=_(!1),Os=Q(()=>Et.value.filter(t=>t.status==="active"||t.status==="idle")),oa=Q(()=>{const t=de.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function Bo(t){var s;const e=t.metrics_series;if(!e||e.length===0){const i=((s=t.status)==null?void 0:s.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const a=n.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const Ko=Q(()=>{const t=new Map;for(const e of It.value)t.set(e.name,Bo(e));return t}),qo=12e4,Go=Q(()=>{const t=Date.now(),e=new Set,n=Pn.value;for(const a of It.value){const s=n.get(a.name);s!=null&&t-s>qo&&e.add(a.name)}return e}),Ee={},Jo=5e3;function zn(){delete Ee.compact,delete Ee.full}function V(t){return typeof t=="object"&&t!==null}function h(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function k(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ut(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Fs(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function Wo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Vo(t){if(!V(t))return null;const e=h(t.name);return e?{name:e,status:Fs(t.status),current_task:h(t.current_task)??null,last_seen:h(t.last_seen),emoji:h(t.emoji),koreanName:h(t.koreanName)??h(t.korean_name),model:h(t.model),traits:Ut(t.traits),interests:Ut(t.interests),activityLevel:k(t.activityLevel)??k(t.activity_level),primaryValue:h(t.primaryValue)??h(t.primary_value)}:null}function Yo(t){if(!V(t))return null;const e=h(t.id),n=h(t.title);return!e||!n?null:{id:e,title:n,status:Wo(t.status),priority:k(t.priority),assignee:h(t.assignee),description:h(t.description),created_at:h(t.created_at),updated_at:h(t.updated_at)}}function Qo(t){if(!V(t))return null;const e=h(t.from)??h(t.from_agent)??"system",n=h(t.content)??"",a=h(t.timestamp)??new Date().toISOString();return{id:h(t.id),seq:k(t.seq),from:e,content:n,timestamp:a,type:h(t.type)}}function Xo(t){return Array.isArray(t)?t.map(e=>{if(!V(e))return null;const n=k(e.ts_unix);if(n==null)return null;const a=V(e.handoff)?e.handoff:null;return{ts:n,context_ratio:k(e.context_ratio)??0,context_tokens:k(e.context_tokens)??0,context_max:k(e.context_max)??0,latency_ms:k(e.latency_ms)??0,generation:k(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:k(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:k(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?k(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Zo(t){return(Array.isArray(t)?t:V(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!V(n))return null;const a=V(n.agent)?n.agent:null,s=V(n.context)?n.context:null,i=V(n.metrics_window)?n.metrics_window:void 0,r=h(n.name);if(!r)return null;const c=k(n.context_ratio)??k(s==null?void 0:s.context_ratio),u=h(n.status)??h(a==null?void 0:a.status)??"offline",d=Fs(u),m=h(n.model)??h(n.active_model)??h(n.primary_model),l=Ut(n.skill_secondary),p=s?{source:h(s.source),context_ratio:k(s.context_ratio),context_tokens:k(s.context_tokens),context_max:k(s.context_max),message_count:k(s.message_count),has_checkpoint:typeof s.has_checkpoint=="boolean"?s.has_checkpoint:void 0}:void 0,v=a?{name:h(a.name),status:h(a.status),current_task:h(a.current_task)??null,last_seen:h(a.last_seen)}:void 0,g=Xo(n.metrics_series);return{name:r,emoji:h(n.emoji),koreanName:h(n.koreanName)??h(n.korean_name),agent_name:h(n.agent_name),trace_id:h(n.trace_id),model:m,primary_model:h(n.primary_model),active_model:h(n.active_model),next_model_hint:h(n.next_model_hint)??null,status:d,last_heartbeat:h(n.last_heartbeat)??h(a==null?void 0:a.last_seen),generation:k(n.generation),turn_count:k(n.turn_count)??k(n.total_turns),context_ratio:c,context_tokens:k(n.context_tokens)??k(s==null?void 0:s.context_tokens),context_max:k(n.context_max)??k(s==null?void 0:s.context_max),context_source:h(n.context_source)??h(s==null?void 0:s.source),context:p,traits:Ut(n.traits),interests:Ut(n.interests),primaryValue:h(n.primaryValue)??h(n.primary_value),activityLevel:k(n.activityLevel)??k(n.activity_level),memory_recent_note:h(n.memory_recent_note)??null,conversation_tail_count:k(n.conversation_tail_count),k2k_count:k(n.k2k_count),handoff_count_total:k(n.handoff_count_total)??k(n.trace_history_count),compaction_count:k(n.compaction_count),last_compaction_saved_tokens:k(n.last_compaction_saved_tokens),skill_primary:h(n.skill_primary)??null,skill_secondary:l,skill_reason:h(n.skill_reason)??null,metrics_series:g.length>0?g:void 0,metrics_window:i,agent:v}}).filter(n=>n!==null)}async function We(t="full"){var a,s,i;const e=Date.now(),n=Ee[t];if(!(n&&e-n.time<Jo)){jn.value=!0;try{const r=await ao(t);Ee[t]={data:r,time:e},Et.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(Vo).filter(c=>c!==null),de.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(Yo).filter(c=>c!==null),Ps.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(Qo).filter(c=>c!==null),It.value=Zo(r.keepers),$t.value=V(r.status)?r.status:null,jt.value=r.perpetual??null}catch(r){console.error("Dashboard fetch error:",r)}finally{jn.value=!1}}}async function ht(){On.value=!0;try{const t=await oo(Mn.value);Ms.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{On.value=!1}}async function ot(){var t;Fn.value=!0;try{const e=it.value||((t=$t.value)==null?void 0:t.room)||"default";it.value||(it.value=e);const n=await wo(e);js.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Fn.value=!1}}async function Un(){zt.value=!0;try{const t=await Ho();Je.value=Array.isArray(t)?t:[]}catch(t){console.error("Goals fetch error:",t)}finally{zt.value=!1}}let Xe=null,Ze=null;function tr(){return ws.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Pn.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Pn.value=n}if(zn(),Xe||(Xe=setTimeout(()=>{We(),Xe=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(Ze||(Ze=setTimeout(()=>{ht(),Ze=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&zn(),e.type==="mdal_started"&&e.loop_id){const n=new Map(at.value);n.set(e.loop_id,{loop_id:e.loop_id,profile:e.profile??"custom",status:"running",current_iteration:0,max_iterations:0,baseline_metric:e.baseline??0,current_metric:e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]}),at.value=n}if(e.type==="mdal_iteration"&&e.loop_id){const n=new Map(at.value),a=n.get(e.loop_id);if(a){const s={iteration:e.iteration??0,metric_before:e.metric_before??0,metric_after:e.metric_after??0,delta:e.delta??0,changes:"",failed_attempts:"",next_suggestion:"",elapsed_ms:0,cost_usd:null};n.set(e.loop_id,{...a,current_iteration:e.iteration??a.current_iteration,current_metric:e.metric_after??a.current_metric,history:[s,...a.history]}),at.value=n}}if((e.type==="mdal_completed"||e.type==="mdal_stopped")&&e.loop_id){const n=new Map(at.value),a=n.get(e.loop_id);a&&(n.set(e.loop_id,{...a,status:e.type==="mdal_completed"?"completed":"stopped"}),at.value=n)}}})}let Ht=null;function er(){Ht||(Ht=setInterval(()=>{zn(),We()},1e4))}function nr(){Ht&&(clearInterval(Ht),Ht=null)}function y({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function X({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function ar(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function F({timestamp:t}){const e=ar(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}const ra=_(null);function zs(t){ra.value=t}function Da(){ra.value=null}const kt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function sr(t){if(!t)return 0;const e=kt.findIndex(n=>n.level===t);return e>=0?e:0}function ir({keeper:t}){const e=sr(t.autonomy_level),n=kt[e]??kt[0];if(!n)return null;const a=(e+1)/kt.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${kt.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${kt.map((s,i)=>o`
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
            <strong><${F} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Se(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function or({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${s.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Se(t.context_tokens)}</div>
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
  `}function rr({keeper:t}){var m,l;const e=t.metrics_series??[];if(e.length<2){const p=(((m=t.context)==null?void 0:m.context_ratio)??0)*100,v=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${p.toFixed(1)}%;background:${v}"></div>
        </div>
        <span class="chart-pct">${p.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,i=e.length,r=e.map((p,v)=>{const g=s+v/(i-1)*(n-2*s),x=a-s-(p.context_ratio??0)*(a-2*s);return{x:g,y:x,p}}),c=r.map(({x:p,y:v})=>`${p.toFixed(1)},${v.toFixed(1)}`).join(" "),u=(((l=e[e.length-1])==null?void 0:l.context_ratio)??0)*100,d=u>85?"#ef4444":u>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p})=>p.is_handoff).map(({x:p})=>o`
          <line x1="${p.toFixed(1)}" y1="${s}" x2="${p.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${d}" stroke-width="1.5"/>
        ${r.filter(({p})=>p.is_compaction).map(({x:p,y:v})=>o`
          <circle cx="${p.toFixed(1)}" cy="${v.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${u.toFixed(1)}%</span>
    </div>`}const tn=_("");function lr({keeper:t}){var s,i,r,c;const e=tn.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(u=>u.title.toLowerCase().includes(e)||u.key.includes(e)||u.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${tn.value}
        onInput=${u=>{tn.value=u.target.value}}
      />
      ${a.map(u=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${u.title}</span>
          <span class="keeper-field-key">${u.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${u.value}</span>
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Se(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Se(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Se(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function cr({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function ur({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function dr({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Ea({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function en(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function pr({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:en(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:en(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:en(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function vr({keeperName:t}){const[e,n]=me("Loading internal monologue..."),[a,s]=me(""),[i,r]=me([]),[c,u]=me(!1),d=async()=>{try{const l=await H("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof l=="string"?l:JSON.stringify(l,null,2))}catch(l){n("Failed to load: "+String(l))}};ft(()=>{d()},[t]);const m=async()=>{if(!a.trim())return;u(!0);const l=a;s(""),r(p=>[...p,{role:"You",text:l}]);try{const p=await H("masc_keeper_msg",{name:t,message:l});r(v=>[...v,{role:t,text:typeof p=="string"?p:JSON.stringify(p)}]),d()}catch(p){r(v=>[...v,{role:"System",text:"Error: "+String(p)}])}finally{u(!1)}};return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Inner Monologue</h3>
      
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <!-- Chat Area -->
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <div style="background: rgba(0,0,0,0.3); border: 1px solid var(--border); border-radius: 12px; height: 300px; overflow-y: auto; padding: 12px; display: flex; flex-direction: column; gap: 8px; font-size: 0.85rem;">
            ${i.length===0?o`<div style="color: var(--text-muted); font-style: italic;">No direct messages yet.</div>`:null}
            ${i.map(l=>o`
              <div style="padding: 8px; border-radius: 8px; background: ${l.role==="You"?"rgba(0, 240, 255, 0.1)":"rgba(255, 255, 255, 0.05)"}; border-left: 2px solid ${l.role==="You"?"var(--accent-cyan)":"var(--text-muted)"};">
                <strong style="color: ${l.role==="You"?"var(--accent-cyan)":"var(--text-primary)"}; display: block; margin-bottom: 4px;">${l.role}</strong>
                <span style="white-space: pre-wrap;">${l.text}</span>
              </div>
            `)}
          </div>
          <div style="display: flex; gap: 8px;">
            <input 
              type="text" 
              value=${a} 
              onInput=${l=>s(l.currentTarget.value)} 
              onKeyDown=${l=>l.key==="Enter"&&!l.shiftKey&&m()}
              placeholder="Ping the agent..."
              disabled=${c}
              style="flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--text-primary); font-family: var(--font-body);"
            />
            <button 
              onClick=${m} 
              disabled=${c||!a.trim()}
              style="background: var(--accent-cyan); color: #000; border: none; border-radius: 8px; padding: 8px 16px; font-weight: bold; cursor: pointer; opacity: ${c?.5:1};"
            >
              ${c?"Sending...":"Send"}
            </button>
          </div>
        </div>

        <!-- Monologue / Status Area -->
        <div style="background: #050810; border: 1px solid var(--card-border); border-radius: 12px; padding: 12px; height: 345px; overflow-y: auto; font-family: monospace; font-size: 0.75rem; color: var(--ok); white-space: pre-wrap; box-shadow: inset 0 0 15px rgba(0,0,0,0.8);">
          ${e}
        </div>
        
      </div>
    </div>
  `}function mr(){var e,n,a;const t=ra.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&Da()}}
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
            <${X} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Da()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${or} keeper=${t} />

        ${""}
        <${rr} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${y} title="Field Dictionary">
            <${lr} keeper=${t} />
          <//>

          ${""}
          <${y} title="Profile">
            <${Ea} traits=${t.traits??[]} label="Traits" />
            <${Ea} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${F} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${y} title="Autonomy">
                <${ir} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${y} title="TRPG Stats">
                <${cr} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${y} title="Equipment (${t.inventory.length})">
                <${ur} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${y} title="Relationships (${Object.keys(t.relationships).length})">
                <${dr} rels=${t.relationships} />
              <//>
            `:null}

          <${y} title="Runtime Signals">
            <${pr} keeper=${t} />
          <//>

          <${y} title="Memory & Context">
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
        <${vr} keeperName=${t.name} />
      </div>
    </div>
  `:null}let fr=0;const mt=_([]);function b(t,e="success",n=4e3){const a=++fr;mt.value=[...mt.value,{id:a,message:t,type:e}],setTimeout(()=>{mt.value=mt.value.filter(s=>s.id!==a)},n)}function _r(t){mt.value=mt.value.filter(e=>e.id!==t)}function gr(){const t=mt.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>_r(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const $r="masc_dashboard_agent_name",Pt=_(null),Ie=_(!1),ae=_(""),Pe=_([]),se=_([]),At=_(""),Bt=_(!1);function Us(t){Pt.value=t,la()}function Ia(){Pt.value=null,ae.value="",Pe.value=[],se.value=[],At.value=""}function hr(){const t=Pt.value;return t?Et.value.find(e=>e.name===t)??null:null}function Hs(t){return t?de.value.filter(e=>e.assignee===t):[]}async function la(){const t=Pt.value;if(t){Ie.value=!0,ae.value="",Pe.value=[],se.value=[];try{const e=await Mo(80);Pe.value=e.filter(s=>s.includes(t)).slice(0,20);const n=Hs(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await jo(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));se.value=a}catch(e){ae.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ie.value=!1}}}async function Pa(){var a;const t=Pt.value,e=At.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem($r))==null?void 0:a.trim())||"dashboard";Bt.value=!0;try{await Es(n,`@${t} ${e}`),At.value="",b(`Mention sent to ${t}`,"success"),la()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";b(i,"error")}finally{Bt.value=!1}}function yr({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${X} status=${t.status} />
    </div>
  `}function br({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function xr(){var s,i,r,c;const t=Pt.value;if(!t)return null;const e=hr(),n=Hs(t),a=Pe.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${u=>{u.target.classList.contains("agent-detail-overlay")&&Ia()}}
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
                        <${X} status=${e.status} />
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
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(u=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(c=e==null?void 0:e.interests)==null?void 0:c.map(u=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${F} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{la()}} disabled=${Ie.value}>
              ${Ie.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Ia}>Close</button>
          </div>
        </div>

        ${ae.value?o`<div class="council-error">${ae.value}</div>`:null}

        <div class="agent-detail-grid">
          <${y} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(u=>o`<${yr} key=${u.id} task=${u} />`)}</div>`}
          <//>

          <${y} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((u,d)=>o`<div key=${d} class="agent-activity-line">${u}</div>`)}</div>`}
          <//>
        </div>

        <${y} title="Task History">
          ${se.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${se.value.map(u=>o`<${br} key=${u.taskId} row=${u} />`)}</div>`}
        <//>

        <${y} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${At.value}
              onInput=${u=>{At.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&Pa()}}
              disabled=${Bt.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Pa()}}
              disabled=${Bt.value||At.value.trim()===""}
            >
              ${Bt.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function bt({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function kr({agent:t}){return o`
    <div class="agent" onClick=${()=>Us(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${X} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function wr(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Sr(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function Ma(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function Cr({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,a=Ko.value.get(t.name),s=Go.value.has(t.name);return o`
    <div class="live-agent keeper-card ${s?"stale":""}" onClick=${()=>zs(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${X} status=${t.status} />
          ${a?o`<span class="pill pill-lifecycle pill-lifecycle-${a}">${a}</span>`:null}
          ${s?o`<span class="pill pill-stale">stale</span>`:null}
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
          ${t.skill_primary?o`<span class="pill pill-skill">${t.skill_primary}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>

        <!-- Row 2: Context bar -->
        ${e!=null?o`
          <div class="keeper-ctx-row">
            <div class="keeper-ctx-bar">
              <div class="keeper-ctx-fill ${Ma(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${Ma(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${wr(t.context_tokens)})`:null}
            </span>
          </div>
        `:null}

        <!-- Row 3: Operational metrics -->
        ${t.generation!=null?o`
          <div class="keeper-metrics-row">
            <span>Gen ${t.generation}</span>
            <span>T${t.turn_count??0}</span>
            ${(t.handoff_count_total??0)>0?o`<span class="keeper-metric-hl">↻${t.handoff_count_total}</span>`:null}
            ${(t.compaction_count??0)>0?o`<span class="keeper-metric-compact">◆${t.compaction_count}</span>`:null}
            ${(t.k2k_count??0)>0?o`<span>K2K:${t.k2k_count}</span>`:null}
            ${(t.conversation_tail_count??0)>0?o`<span>💬${t.conversation_tail_count}</span>`:null}
          </div>
        `:null}

        <!-- Row 4: Heartbeat freshness -->
        ${t.last_heartbeat?o`
          <div class="keeper-heartbeat-row">
            <span class="keeper-heartbeat-dot ${t.status==="active"?"pulse":""}"></span>
            <${F} timestamp=${t.last_heartbeat} />
          </div>
        `:null}

        <!-- Row 5: Trait chips -->
        ${t.traits&&t.traits.length>0?o`
          <div class="keeper-trait-row">
            ${t.traits.slice(0,3).map(i=>o`<span class="keeper-trait-chip">${i}</span>`)}
            ${t.traits.length>3?o`<span class="keeper-trait-more">+${t.traits.length-3}</span>`:null}
          </div>
        `:null}

        <!-- Row 6: Memory note preview -->
        ${t.memory_recent_note?o`
          <div class="keeper-note-preview">${Sr(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function ja(){var r,c,u,d,m;const t=$t.value,e=Et.value,n=It.value,a=oa.value,s=(r=t==null?void 0:t.monitoring)==null?void 0:r.board,i=(c=t==null?void 0:t.monitoring)==null?void 0:c.council;return o`
    <div class="stats-grid">
      <${bt} label="Agents" value=${e.length} />
      <${bt} label="Active" value=${Os.value.length} color="#4ade80" />
      <${bt} label="Keepers" value=${n.length} color="#22d3ee" />
      <${bt} label="Tasks" value=${de.value.length} />
      <${bt} label="In Progress" value=${a.inProgress.length} color="#fbbf24" />
      <${bt} label="Done" value=${a.done.length} color="#4ade80" />
    </div>

    ${s||i?o`
        <${y} title="Operations SLO" class="section">
          <div class="grid-2col">
            <div class="stat-card">
              <div class="stat-label">Board Feed</div>
              <div class="stat-value" style=${`color: ${Fa(s==null?void 0:s.alert_level)}`}>
                ${Oa(s==null?void 0:s.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${_e(s==null?void 0:s.last_activity_age_s)}</span>
                <span>SLO: ≤ ${_e(s==null?void 0:s.slo_target_age_s)}</span>
                <span>SLO Breach: ${s!=null&&s.slo_breached?"Yes":"No"}</span>
                <span>Posts (24h): ${(s==null?void 0:s.new_posts_24h)??0}</span>
                <span>Unanswered: ${(s==null?void 0:s.unanswered_posts)??0}</span>
              </div>
            </div>

            <div class="stat-card">
              <div class="stat-label">Council Feed</div>
              <div class="stat-value" style=${`color: ${Fa(i==null?void 0:i.alert_level)}`}>
                ${Oa(i==null?void 0:i.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${_e(i==null?void 0:i.last_activity_age_s)}</span>
                <span>Open Debates: ${(i==null?void 0:i.debates_open)??0}</span>
                <span>Pending Debates: ${(i==null?void 0:i.debates_pending)??0}</span>
                <span>Quorum Risk: ${(i==null?void 0:i.sessions_without_quorum)??0}</span>
                <span>SLO: ≤ ${_e(i==null?void 0:i.slo_target_quorum_age_s)}</span>
                <span>SLO Breach: ${i!=null&&i.slo_breached?"Yes":"No"}</span>
              </div>
            </div>
          </div>
        <//>
      `:null}

    <div class="grid-2col">
      <${y} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(l=>o`<${kr} key=${l.name} agent=${l} />`)}
        </div>
      <//>

      <${y} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(l=>o`<${Cr} key=${l.name} keeper=${l} />`)}
        </div>
      <//>
    </div>

    ${jt.value?o`
        <${y} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${jt.value.running?"Running":"Stopped"}</span>
            ${jt.value.goal?o`<span>Goal: ${jt.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${y} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?o`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?o`<span>Project: ${t.project}</span>`:null}
            ${t.version?o`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${Ar(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
            ${((u=t.data_quality)==null?void 0:u.board_contract_ok)===!1?o`<span class="pill pill-stale">Board Contract: Degraded</span>`:null}
            ${((d=t.data_quality)==null?void 0:d.council_feed_ok)===!1?o`<span class="pill pill-stale">Council Feed: Degraded</span>`:null}
            ${(m=t.data_quality)!=null&&m.last_sync_at?o`<span>Data Sync: <${F} timestamp=${t.data_quality.last_sync_at} /></span>`:null}
          </div>
        <//>
      `:null}
  `}function Ar(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function _e(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Oa(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function Fa(t){const e=(t??"").toLowerCase();return e==="ok"?"#4ade80":e==="warn"?"#fbbf24":e==="bad"?"#fb7185":"#94a3b8"}const Hn=_([]),Bn=_([]),Kt=_(""),Me=_(!1),qt=_(!1),ie=_(""),je=_(null),W=_(null),Kn=_(!1);async function qn(){Me.value=!0,ie.value="";try{const[t,e]=await Promise.all([Oo(),Fo()]);Hn.value=t,Bn.value=e}catch(t){ie.value=t instanceof Error?t.message:"Failed to load council data"}finally{Me.value=!1}}async function za(){const t=Kt.value.trim();if(t){qt.value=!0;try{const e=await zo(t);Kt.value="",b(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await qn()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";b(n,"error")}finally{qt.value=!1}}}async function Nr(t){je.value=t,Kn.value=!0,W.value=null;try{W.value=await Uo(t)}catch(e){ie.value=e instanceof Error?e.message:"Failed to load debate status",W.value=null}finally{Kn.value=!1}}function Tr({debate:t}){const e=je.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Nr(t.id)}
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
  `}function Rr({session:t}){return o`
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
  `}function Lr(){var e;const t=(e=$t.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${F} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Dr(){var e,n;ft(()=>{qn()},[]);const t=((n=(e=$t.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${Lr} />
      <${y} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Kt.value}
            onInput=${a=>{Kt.value=a.target.value}}
            onKeyDown=${a=>{a.key==="Enter"&&za()}}
            disabled=${qt.value}
          />
          <button
            class="control-btn secondary"
            onClick=${za}
            disabled=${qt.value||Kt.value.trim()===""}
          >
            ${qt.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${qn} disabled=${Me.value}>
            ${Me.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${ie.value?o`<div class="council-error">${ie.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${y} title="Debates" class="section">
          <div class="council-list">
            ${Hn.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:Hn.value.map(a=>o`<${Tr} key=${a.id} debate=${a} />`)}
          </div>
        <//>

        <${y} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Bn.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:Bn.value.map(a=>o`<${Rr} key=${a.id} session=${a} />`)}
          </div>
        <//>
      </div>

      <${y} title=${je.value?`Debate Detail (${je.value})`:"Debate Detail"} class="section">
        ${Kn.value?o`<div class="loading-indicator">Loading debate detail...</div>`:W.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${W.value.status}</span>
                  <span>Total arguments: ${W.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${W.value.support_count}</span>
                  <span>Oppose: ${W.value.oppose_count}</span>
                  <span>Neutral: ${W.value.neutral_count}</span>
                </div>
                ${W.value.summary_text?o`<pre class="council-detail">${W.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Er({text:t}){if(!t)return null;const e=Ir(t);return o`<div class="markdown-content">${e}</div>`}function Ir(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],c=s.slice(r.length).trim(),u=[];for(a++;a<e.length&&!e[a].startsWith(r);)u.push(e[a]),a++;a++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${u.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],c=s.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&r.push(c),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const d=e[a].replace("</think>","").trim();d&&r.push(d),a++}const u=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${nn(u)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${nn(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${nn(i.join(`
`))}</p>`)}return n}function nn(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const Pr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Gn=_([]),Gt=_(!1),Jn=_(null),Jt=_(""),Mr=_("dashboard-user"),Wt=_(!1);async function Bs(t){Jn.value=t,Gt.value=!0;try{const e=await ro(t);if(Jn.value!==t)return;Gn.value=e.comments??[]}catch{}finally{Gt.value=!1}}async function Ua(t){const e=Jt.value.trim();if(e){Wt.value=!0;try{await lo(t,Mr.value,e),Jt.value="",b("Comment posted","success"),await Bs(t),ht()}catch{b("Failed to post comment","error")}finally{Wt.value=!1}}}function jr(){const t=Mn.value;return o`
    <div class="board-controls">
      ${Pr.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{Mn.value=e.id,ht()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function an(){var e;const t=(e=$t.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${F} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Ks({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Or({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Ds(t.id,n),ht()}catch{b("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Oi(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${Ks} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${F} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function Fr({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${F} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function zr({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Jt.value}
        onInput=${e=>{Jt.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Ua(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Wt.value}
      />
      <button
        onClick=${()=>Ua(t)}
        disabled=${Wt.value||Jt.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Wt.value?"...":"Post"}
      </button>
    </div>
  `}function Ur({post:t}){Jn.value!==t.id&&!Gt.value&&Bs(t.id);const e=async n=>{try{await Ds(t.id,n),ht()}catch{b("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>Ge("board")}>← Back to Board</button>
      <${y} title=${o`${t.title} <${Ks} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Er} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${F} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${y} title="Comments (${Gt.value?"...":Gn.value.length})">
        ${Gt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Fr} comments=${Gn.value} />`}
        <${zr} postId=${t.id} />
      <//>
    </div>
  `}function Hr(){var s,i;const t=Ms.value,e=On.value,n=et.value.postId,a=((i=(s=$t.value)==null?void 0:s.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(c=>c.id===n);return r?o`
          <${an} />
          <${Ur} post=${r} />
        `:o`
          <div>
            <${an} />
            <button class="back-btn" onClick=${()=>Ge("board")}>← Back to Board</button>
            <div class="empty-state">
              ${a?"Post not available while board feed is degraded":"Post not found"}
            </div>
          </div>
        `}return o`
    <${an} />
    <${jr} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${a?"No posts loaded (board feed degraded). Check board contract sync.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${Or} key=${r.id} post=${r} />`)}
          </div>`}
  `}function Br(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Kr(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function Ha(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function qr({row:t}){const e=new Date(t.timestamp),n=isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1});return o`
    <div class="term-row">
      <span class="term-time">${n}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-source ${t.source}">${t.source==="message"?"msg":"evt"}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Gr(){const t=Ps.value.map(Br),e=De.value.map(Kr),n=[...t,...e].sort((a,s)=>Ha(s.timestamp)-Ha(a.timestamp)).slice(0,100);return o`
    <div class="section">
      <h2 style="color: var(--accent); text-shadow: 0 0 10px rgba(0,240,255,0.5); margin-bottom: 16px; font-family: monospace;">> LIVE_ACTIVITY_STREAM</h2>
      <div class="terminal-feed">
        ${n.length===0?o`<div class="empty-state" style="font-family: monospace; color: var(--ok);">> Waiting for signal...</div>`:n.map(a=>o`<${qr} key=${a.id} row=${a} />`)}
      </div>
    </div>
  `}function qs({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,i=2*Math.PI*a,r=i*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${s}" cy="${s}" r="${a}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${s}" cy="${s}" r="${a}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(t*100)}%</span>
    </div>
  `}const Jr={born_at:{label:"Born",description:"Keeper 메타가 생성된 시각입니다.",sourcePath:"keepers[].created_at",interpretation:"최근 생성일수록 신규 Keeper입니다."},generation:{label:"Generation",description:"승계/핸드오프를 거치며 누적된 세대 번호입니다.",sourcePath:"keepers[].generation",interpretation:"값이 높을수록 세대 전환을 더 많이 경험했습니다."},status:{label:"Status",description:"현재 실행 상태입니다.",sourcePath:"keepers[].status",interpretation:"active/idle은 동작 중, offline/inactive는 비활성 상태입니다."},recent_activity:{label:"Recent",description:"가장 최근 변화/행동 요약입니다.",sourcePath:"keepers[].last_drift_reason | keepers[].last_proactive_reason | keepers[].memory_recent_note",formula:"first_non_null(last_drift_reason, last_proactive_reason, memory_recent_note)",interpretation:"최근 어떤 일을 했는지 한 줄로 파악합니다."},relations:{label:"Relations",description:"다른 Keeper와의 최근 상호작용 빈도입니다.",sourcePath:"keepers[].k2k_count, keepers[].k2k_mentions",formula:"k2k_count + top(k2k_mentions)",interpretation:"값이 높을수록 협업/호출이 잦습니다."},personality_change:{label:"Personality Change",description:"성향 변화 추세를 드리프트 지표로 요약한 값입니다.",sourcePath:"keepers[].drift_count_total, keepers[].metrics_window.goal_drift_avg",formula:"drift_count_total + goal_drift_avg",interpretation:"높을수록 최근 성향/목표 정렬 변화가 컸습니다."}};function Wr(t){return Jr[t]}function xt({metric:t}){const e=Wr(t);return o`
    <span
      class="metric-tip"
      tabindex="0"
      role="button"
      aria-label="${e.label} 설명"
      title="${e.description} (source: ${e.sourcePath})"
    >
      i
      <span class="metric-tip-pop" role="tooltip">
        <strong>${e.label}</strong>
        <span>${e.description}</span>
        ${e.formula?o`<span><code>formula:</code> ${e.formula}</span>`:null}
        <span><code>source:</code> ${e.sourcePath}</span>
        ${e.interpretation?o`<span>${e.interpretation}</span>`:null}
      </span>
    </span>
  `}function Vr({agent:t}){return o`
    <button class="agent-card ${t.status}" onClick=${()=>Us(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${qs} ratio=${t.context_ratio} />
        <${X} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function Yr(t){return typeof t!="number"||Number.isNaN(t)?null:`${Math.round(t*100)}%`}function Qr(t){var s,i,r;const e=(s=t.last_drift_reason)==null?void 0:s.trim();if(e)return e;const n=(i=t.last_proactive_reason)==null?void 0:i.trim();if(n)return n;const a=(r=t.memory_recent_note)==null?void 0:r.trim();return a||"—"}function Xr(t){var a;const e=t.k2k_count??0,n=(a=t.k2k_mentions)==null?void 0:a[0];return n?`${e} · ${n.keeper}(${n.count})`:String(e)}function Zr(t){var a;const e=t.drift_count_total??0,n=Yr((a=t.metrics_window)==null?void 0:a.goal_drift_avg);return e===0&&!n?"Stable":n?`Drift ${e} · Δ${n}`:`Drift ${e}`}function tl({keeper:t}){var s;const e=Qr(t),n=Xr(t),a=Zr(t);return o`
    <div class="live-agent keeper-card" onClick=${()=>zs(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${qs} ratio=${t.context_ratio} />
        <${X} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Born <${xt} metric="born_at" /></span>
            <strong class="keeper-core-value">
              ${t.created_at?o`<${F} timestamp=${t.created_at} />`:"—"}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Gen <${xt} metric="generation" /></span>
            <strong class="keeper-core-value">${t.generation??"—"}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Status <${xt} metric="status" /></span>
            <strong class="keeper-core-value">${t.status}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Relations <${xt} metric="relations" /></span>
            <strong class="keeper-core-value">${n}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Recent <${xt} metric="recent_activity" /></span>
            <strong class="keeper-core-value keeper-core-text">${e}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Personality <${xt} metric="personality_change" /></span>
            <strong class="keeper-core-value">${a}</strong>
          </div>
        </div>

        <!-- Inner Information Section -->
        <div class="keeper-inner-info">
          ${(s=t.agent)!=null&&s.current_task?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Task</span>
              <span class="keeper-value">${t.agent.current_task}</span>
            </div>
          `:null}
          ${t.will?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Will (의지)</span>
              <span class="keeper-value">${t.will}</span>
            </div>
          `:null}
          ${t.needs?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Needs (니즈)</span>
              <span class="keeper-value">${t.needs}</span>
            </div>
          `:null}
          ${t.desires?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Desires (욕구)</span>
              <span class="keeper-value">${t.desires}</span>
            </div>
          `:null}
          ${t.memory_recent_note?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Memory Note</span>
              <span class="keeper-value memory-note">"${t.memory_recent_note}"</span>
            </div>
          `:null}
        </div>
      </div>
    </div>
  `}function el(){const t=Et.value,e=It.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${tl} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${Vr} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function sn({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${F} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function nl(){const{todo:t,inProgress:e,done:n}=oa.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>o`<${sn} key=${a.id} task=${a} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>o`<${sn} key=${a.id} task=${a} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>o`<${sn} key=${a.id} task=${a} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function al(t){return t==null?"P3":t<=1?"P1":t===2?"P2":t>=4?"P4+":"P3"}function on({task:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.title}</div>
        <div class="council-sub">
          <span>${al(t.priority)}</span>
          ${t.assignee?o`<span>Assignee: ${t.assignee}</span>`:o`<span>Unassigned</span>`}
          ${t.created_at?o`<span><${F} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </div>
  `}function sl(){const t=oa.value,e=t.inProgress,n=t.todo,a=t.done,s=Os.value,i=n.filter(c=>(c.priority??3)<=2),r=n.filter(c=>!c.assignee);return o`
    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-label">In Progress</div>
        <div class="stat-value" style="color:#fbbf24">${e.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Ready Queue</div>
        <div class="stat-value">${n.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Urgent Ready</div>
        <div class="stat-value" style="color:#fb7185">${i.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Done (Visible)</div>
        <div class="stat-value" style="color:#4ade80">${a.length}</div>
      </div>
    </div>

    <div class="council-grid">
      <${y} title="Execution Queue" class="section">
        <div class="council-list">
          ${e.length===0?o`<div class="empty-state">No active execution tasks</div>`:e.slice(0,20).map(c=>o`<${on} key=${c.id} task=${c} />`)}
        </div>
      <//>

      <${y} title="Ready Queue" class="section">
        <div class="council-list">
          ${n.length===0?o`<div class="empty-state">No ready tasks</div>`:n.slice(0,20).map(c=>o`<${on} key=${c.id} task=${c} />`)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${y} title="Assignee Coverage" class="section">
        <div class="council-list">
          ${s.length===0?o`<div class="empty-state">No active agents</div>`:s.map(c=>o`
                <div class="council-row session">
                  <div class="council-row-main">
                    <div class="council-topic">${c.name}</div>
                    <div class="council-sub">
                      ${c.current_task?o`<span>${c.current_task}</span>`:o`<span>Idle</span>`}
                    </div>
                  </div>
                  <${X} status=${c.status} />
                </div>
              `)}
        </div>
      <//>

      <${y} title="Attention Needed" class="section">
        <div class="council-list">
          ${r.length===0?o`<div class="empty-state">No unassigned tasks</div>`:r.slice(0,20).map(c=>o`<${on} key=${c.id} task=${c} />`)}
        </div>
      <//>
    </div>
  `}function il({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",a=t.message??t.content??t.status??"";return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${a}</span>
    </div>
  `}function ol(){const t=De.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${il} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const Oe=_("all"),Fe=_("all"),Gs=Q(()=>{let t=Je.value;return Oe.value!=="all"&&(t=t.filter(e=>e.horizon===Oe.value)),Fe.value!=="all"&&(t=t.filter(e=>e.status===Fe.value)),t}),rl=Q(()=>{const t={short:[],mid:[],long:[]};for(const e of Gs.value){const n=t[e.horizon];n&&n.push(e)}return t});function ll(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function ca(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function Ce(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function cl({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Ce(t.horizon)}">
            ${ca(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${ll(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${F} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${X} status=${t.status} />
        <div class="goal-updated">
          <${F} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function rn({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return o`
    <${y} title="${ca(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>o`<${cl} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function ul(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Oe.value===t?"active":""}"
            onClick=${()=>{Oe.value=t}}
          >
            ${t==="all"?"All":ca(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Fe.value===t?"active":""}"
            onClick=${()=>{Fe.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function dl(){const t=Je.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${Ce("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Ce("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Ce("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function pl(){ft(()=>{Un()},[]);const t=rl.value;return o`
    <div>
      <${y} title="Goals Overview" class="section">
        <${dl} />
        <${ul} />
        <div style="margin-top:8px;">
          <button class="control-btn ghost" onClick=${Un} disabled=${zt.value}>
            ${zt.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      <//>

      ${zt.value&&Je.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:Gs.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
            <${rn} horizon="short" items=${t.short??[]} />
            <${rn} horizon="mid" items=${t.mid??[]} />
            <${rn} horizon="long" items=${t.long??[]} />
          `}
    </div>
  `}const wt=_(""),ln=_("ability_check"),cn=_("10"),un=_("12"),ge=_(""),$e=_("idle"),rt=_(""),he=_("keeper-late"),dn=_("player"),pn=_(""),K=_("idle"),vn=_(null),ye=_(""),mn=_(""),fn=_("player"),_n=_(""),gn=_(""),$n=_(""),Vt=_("20"),hn=_("20"),yn=_(""),be=_("idle"),Wn=_(null),Js=_("overview"),bn=_("all"),xn=_("all"),kn=_("all"),vl=12e4,Ve=_(null),Ba=_(Date.now());function ml(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function fl(t,e){return e>0?Math.round(t/e*100):0}const _l={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},gl={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function xe(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function $l(t){const e=t.trim().toLowerCase();return _l[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function hl(t){const e=t.trim().toLowerCase();return gl[e]??"상황에 따라 선택되는 전술 액션입니다."}function ct(t){return typeof t=="object"&&t!==null}function U(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function Z(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function oe(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const yl=new Set(["str","dex","con","int","wis","cha"]);function bl(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!ct(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,i])=>{const r=s.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){a[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){a[r]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function xl(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(Vt.value.trim(),10);Number.isFinite(a)&&a>n&&(Vt.value=String(n))}function Vn(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function kl(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function wl(t){Js.value=t}function Ws(t){const e=Ve.value;return e==null||e<=t}function Sl(t){const e=Ve.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function ze(){Ve.value=null}function Vs(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Cl(t,e){Vs(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Ve.value=Date.now()+vl,b("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Ae(t){return Ws(t)?(b("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Yn(t,e,n){return Vs([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Al({hp:t,max:e}){const n=fl(t,e),a=ml(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Nl({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Tl({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Ys({actor:t}){var u,d,m,l;const e=(u=t.archetype)==null?void 0:u.trim(),n=(d=t.persona)==null?void 0:d.trim(),a=(m=t.portrait)==null?void 0:m.trim(),s=(l=t.background)==null?void 0:l.trim(),i=t.traits??[],r=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([p,v])=>Number.isFinite(v)).filter(([p])=>!yl.has(p.toLowerCase()));return o`
    <div class="trpg-actor">
      ${a?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${a}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${p=>{const v=p.target;v&&(v.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${X} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Tl} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Al} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Nl} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${xe(e)}</div>`:null}
      ${s?o`<div class="trpg-actor-meta">Background: ${s}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([p,v])=>o`
                <span class="trpg-custom-stat-chip">${xe(p)} ${v}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(p=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${xe(p)}</span>
                  <span class="trpg-annot-desc">${$l(p)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(p=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${xe(p)}</span>
                  <span class="trpg-annot-desc">${hl(p)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Rl({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Qs({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return o`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${kl(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Vn(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${F} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Ll({events:t}){const e="__none__",n=bn.value,a=xn.value,s=kn.value,i=Array.from(new Set(t.map(Vn).map(l=>l.trim()).filter(l=>l!==""))).sort((l,p)=>l.localeCompare(p)),r=Array.from(new Set(t.map(l=>(l.type??"").trim()).filter(l=>l!==""))).sort((l,p)=>l.localeCompare(p)),c=t.some(l=>(l.type??"").trim()===""),u=Array.from(new Set(t.map(l=>(l.phase??"").trim()).filter(l=>l!==""))).sort((l,p)=>l.localeCompare(p)),d=t.some(l=>(l.phase??"").trim()===""),m=t.filter(l=>{if(n!=="all"&&Vn(l)!==n)return!1;const p=(l.type??"").trim(),v=(l.phase??"").trim();if(a===e){if(p!=="")return!1}else if(a!=="all"&&p!==a)return!1;if(s===e){if(v!=="")return!1}else if(s!=="all"&&v!==s)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${l=>{bn.value=l.target.value}}>
          <option value="all">all</option>
          ${i.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${l=>{xn.value=l.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${e}>(none)</option>`:null}
          ${r.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${l=>{kn.value=l.target.value}}>
          <option value="all">all</option>
          ${d?o`<option value=${e}>(none)</option>`:null}
          ${u.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{bn.value="all",xn.value="all",kn.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${m.length} / 전체 ${t.length}
      </span>
    </div>
    <${Qs} events=${m.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Dl({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function Xs({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function El({state:t,nowMs:e}){var d;const n=it.value||((d=t.session)==null?void 0:d.room)||"",a=$e.value,s=t.party??[];if(!s.find(m=>m.id===wt.value)&&s.length>0){const m=s[0];m&&(wt.value=m.id)}const r=async()=>{var l,p;if(!n){b("Room ID가 비어 있습니다.","error");return}if(!Ae(e))return;const m=((l=t.current_round)==null?void 0:l.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(Yn("라운드 실행",n,m)){$e.value="running";try{const v=await So(n);Wn.value=v,$e.value="ok";const g=ct(v.summary)?v.summary:null,x=g?oe(g,"advanced",!1):!1,S=g?U(g,"progress_reason",""):"";b(x?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${S?`: ${S}`:""}`,x?"success":"warning"),ot()}catch(v){Wn.value=null,$e.value="error";const g=v instanceof Error?v.message:"라운드 실행에 실패했습니다.";b(g,"error")}finally{ze()}}},c=async()=>{var l,p;if(!n||!Ae(e))return;const m=((l=t.current_round)==null?void 0:l.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(Yn("턴 강제 진행",n,m))try{await No(n),b("턴을 다음 단계로 이동했습니다.","success"),ot()}catch{b("턴 이동에 실패했습니다.","error")}finally{ze()}},u=async()=>{if(!n||!Ae(e))return;const m=wt.value.trim();if(!m){b("먼저 Actor를 선택하세요.","warning");return}const l=Number.parseInt(cn.value,10),p=Number.parseInt(un.value,10);if(Number.isNaN(l)||Number.isNaN(p)){b("stat/dc는 숫자여야 합니다.","warning");return}const v=Number.parseInt(ge.value,10),g=ge.value.trim()===""||Number.isNaN(v)?void 0:v;try{await Ao({roomId:n,actorId:m,action:ln.value.trim()||"ability_check",statValue:l,dc:p,rawD20:g}),b("주사위 판정을 기록했습니다.","success"),ot()}catch{b("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${m=>{it.value=m.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${wt.value}
            onChange=${m=>{wt.value=m.target.value}}
          >
            <option value="">Actor 선택</option>
            ${s.map(m=>o`<option value=${m.id}>${m.name} (${m.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${ln.value}
              onInput=${m=>{ln.value=m.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${cn.value}
              onInput=${m=>{cn.value=m.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${un.value}
              onInput=${m=>{un.value=m.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ge.value}
              onInput=${m=>{ge.value=m.target.value}}
              onKeyDown=${m=>{m.key==="Enter"&&u()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${u}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${r}
              disabled=${a==="running"}
            >
              ${a==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${c}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${a!=="idle"?o`<div class="trpg-run-status ${a}">${a==="running"?"처리 중...":a==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function Il({state:t}){var s;const e=it.value||((s=t.session)==null?void 0:s.room)||"",n=be.value,a=async()=>{if(!e){b("Room ID가 비어 있습니다.","warning");return}const i=ye.value.trim(),r=mn.value.trim();if(!r&&!i){b("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Vt.value.trim(),10),u=Number.parseInt(hn.value.trim(),10),d=Number.isFinite(u)?Math.max(1,u):20,m=Number.isFinite(c)?Math.max(0,Math.min(d,c)):d;let l={};try{l=bl(yn.value)}catch(p){b(p instanceof Error?p.message:"능력치 JSON 오류","error");return}be.value="spawning";try{const p=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,v=await To(e,{actor_id:i||void 0,name:r||void 0,role:fn.value,idempotencyKey:p,portrait:gn.value.trim()||void 0,background:$n.value.trim()||void 0,hp:m,max_hp:d,alive:m>0,stats:Object.keys(l).length>0?l:void 0}),g=typeof v.actor_id=="string"?v.actor_id.trim():"";if(!g)throw new Error("생성 응답에 actor_id가 없습니다.");const x=_n.value.trim();x&&await Ro(e,g,x),wt.value=g,rt.value=g,i||(ye.value=""),be.value="ok",b(`Actor 생성 완료: ${g}`,"success"),await ot()}catch(p){be.value="error",b(p instanceof Error?p.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${mn.value}
            onInput=${i=>{mn.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${fn.value}
            onChange=${i=>{fn.value=i.target.value}}
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
            value=${_n.value}
            onInput=${i=>{_n.value=i.target.value}}
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
              value=${ye.value}
              onInput=${i=>{ye.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${gn.value}
              onInput=${i=>{gn.value=i.target.value}}
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
              value=${Vt.value}
              onInput=${i=>{Vt.value=i.target.value}}
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
              value=${hn.value}
              onInput=${i=>{const r=i.target.value;hn.value=r,xl(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${$n.value}
              onInput=${i=>{$n.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${yn.value}
              onInput=${i=>{yn.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Pl({state:t,nowMs:e}){var p;const n=it.value||((p=t.session)==null?void 0:p.room)||"",a=t.join_gate,s=vn.value,i=ct(s)?s:null,r=(t.party??[]).filter(v=>v.role!=="dm"),c=rt.value.trim(),u=r.some(v=>v.id===c),d=u?c:c?"__manual__":"",m=async()=>{const v=rt.value.trim(),g=he.value.trim();if(!n||!v){b("Room/Actor가 필요합니다.","warning");return}K.value="checking";try{const x=await Lo(n,v,g||void 0);vn.value=x,K.value="ok",b("참가 가능 여부를 갱신했습니다.","success")}catch(x){K.value="error";const S=x instanceof Error?x.message:"참가 가능 여부 확인에 실패했습니다.";b(S,"error")}},l=async()=>{var A,C;const v=rt.value.trim(),g=he.value.trim(),x=pn.value.trim();if(!n||!v||!g){b("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Ae(e))return;const S=((A=t.current_round)==null?void 0:A.phase)??((C=t.session)==null?void 0:C.status)??"unknown";if(Yn("Mid-Join 승인 요청",n,S)){K.value="requesting";try{const E=await Do({room_id:n,actor_id:v,keeper_name:g,role:dn.value,...x?{name:x}:{}});vn.value=E;const O=ct(E)?oe(E,"granted",!1):!1,D=ct(E)?U(E,"reason_code",""):"";O?b("Mid-Join이 승인되었습니다.","success"):b(`Mid-Join이 거절되었습니다${D?`: ${D}`:""}`,"warning"),K.value=O?"ok":"error",ot()}catch(E){K.value="error";const O=E instanceof Error?E.message:"Mid-Join 요청에 실패했습니다.";b(O,"error")}finally{ze()}}};return o`
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
            value=${d}
            onChange=${v=>{const g=v.target.value;if(g==="__manual__"){(u||!c)&&(rt.value="");return}rt.value=g}}
          >
            <option value="">Actor 선택</option>
            ${r.map(v=>o`
              <option value=${v.id}>${v.name} (${v.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${d==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${rt.value}
                onInput=${v=>{rt.value=v.target.value}}
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
            value=${he.value}
            onInput=${v=>{he.value=v.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${dn.value}
            onChange=${v=>{dn.value=v.target.value}}
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
            value=${pn.value}
            onInput=${v=>{pn.value=v.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${m} disabled=${K.value==="checking"||K.value==="requesting"}>
              ${K.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${l} disabled=${K.value==="checking"||K.value==="requesting"}>
              ${K.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${oe(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Z(i,"effective_score",0)}/${Z(i,"required_points",0)}</span>
            ${U(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${U(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Zs({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function ti({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function ei(){const t=Wn.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=ct(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(ct).slice(-8),i=t.canon_check,r=ct(i)?i:null,c=r&&Array.isArray(r.warnings)?r.warnings.filter(D=>typeof D=="string").slice(0,3):[],u=r&&Array.isArray(r.violations)?r.violations.filter(D=>typeof D=="string").slice(0,3):[],d=n?oe(n,"advanced",!1):!1,m=n?U(n,"progress_reason",""):"",l=n?U(n,"progress_detail",""):"",p=n?Z(n,"player_successes",0):0,v=n?Z(n,"player_required_successes",0):0,g=n?oe(n,"dm_success",!1):!1,x=n?Z(n,"timeouts",0):0,S=n?Z(n,"unavailable",0):0,A=n?Z(n,"reprompts",0):0,C=n?Z(n,"npc_attacks",0):0,E=n?Z(n,"keeper_timeout_sec",0):0,O=n?Z(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${d?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${d?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${g?"DM ok":"DM stalled"} / players ${p}/${v}
          </span>
        </div>
        ${m?o`<div style="margin-top:4px; font-size:12px;">${m}</div>`:null}
        ${l?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${l}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${E||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${O}</div></div>
      </div>

      ${s.length>0?o`
          <div class="trpg-round-list">
            ${s.map(D=>{const q=U(D,"status","unknown"),dt=U(D,"actor_id","-"),pt=U(D,"role","-"),G=U(D,"reason",""),nt=U(D,"action_type",""),R=U(D,"reply","");return o`
                <div class="trpg-round-item ${q.includes("fallback")||q.includes("timeout")?"failed":"active"}">
                  <span>${dt} (${pt})</span>
                  <span style="margin-left:auto; font-size:11px;">${q}</span>
                  ${nt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${nt}</div>`:null}
                  ${G?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${G}</div>`:null}
                  ${R?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${R.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${U(r,"status","unknown")}</strong>
            </div>
            ${u.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${u.map(D=>o`<div>violation: ${D}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(D=>o`<div>warning: ${D}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Ml({state:t,nowMs:e}){var r,c,u;const n=it.value||((r=t.session)==null?void 0:r.room)||"",a=((c=t.current_round)==null?void 0:c.phase)??((u=t.session)==null?void 0:u.status)??"unknown",s=Ws(e),i=Sl(e);return o`
    <${y} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${s?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${s?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${s?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${s?o`<button class="trpg-run-btn recommend" onClick=${()=>Cl(n,a)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{ze(),b("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function jl({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>wl(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Ol({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${y} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${y} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Qs} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${y} title="맵" style="margin-top:16px;">
              <${Rl} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${y} title="현재 라운드">
          <${ti} state=${t} />
        <//>

        <${y} title="기여도" style="margin-top:16px;">
          <${Zs} state=${t} />
        <//>

        <${y} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>o`<${Ys} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${y} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Xs} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Fl({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${y} title=${`이벤트 타임라인 (${e.length})`}>
          <${Ll} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${y} title="최근 라운드 결과">
          <${ei} />
        <//>

        <${y} title="현재 라운드" style="margin-top:16px;">
          <${ti} state=${t} />
        <//>
      </div>
    </div>
  `}function zl({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${Ml} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${y} title="조작 패널">
            <${El} state=${t} nowMs=${e} />
          <//>

          <${y} title="Actor Spawn" style="margin-top:16px;">
            <${Il} state=${t} />
          <//>

          <${y} title="Mid-Join Gate" style="margin-top:16px;">
            <${Pl} state=${t} nowMs=${e} />
          <//>

          <${y} title="최근 라운드 결과" style="margin-top:16px;">
            <${ei} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${y} title="기여도" style="margin-top:0;">
            <${Zs} state=${t} />
          <//>

          <${y} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>o`<${Ys} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${y} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Xs} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Ul(){var c,u,d,m,l;const t=js.value,e=Fn.value;if(ft(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const p=window.setInterval(()=>{Ba.value=Date.now()},1e3);return()=>{window.clearInterval(p)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>ot()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,i=Js.value,r=Ba.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${it.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((u=t.current_round)==null?void 0:u.phase)??((d=t.session)==null?void 0:d.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>ot()}>새로고침</button>
      </div>

      <${Dl} outcome=${s} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((m=t.session)==null?void 0:m.status)??"active"}</div>
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

      <${jl} active=${i} />

      ${i==="overview"?o`<${Ol} state=${t} />`:i==="timeline"?o`<${Fl} state=${t} />`:o`<${zl} state=${t} nowMs=${r} />`}
    </div>
  `}const Hl=Q(()=>{const t=Array.from(at.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t}),Bl=Q(()=>Array.from(at.value.values()).filter(t=>t.status==="running").length),Kl=Q(()=>Array.from(at.value.values()).filter(t=>t.status==="completed").length);function wn(t){switch(t){case"running":return"#fbbf24";case"completed":return"#4ade80";case"stopped":return"#94a3b8";case"error":return"#fb7185";default:return"#888"}}function ni(t){return`${t>=0?"+":""}${t.toFixed(4)}`}function ql(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Gl({history:t}){if(t.length===0)return o`<span class="mdal-spark-empty">No iterations yet</span>`;const n=[...t].reverse().map(u=>u.metric_after),a=Math.min(...n),i=Math.max(...n)-a||1,r="▁▂▃▄▅▆▇█",c=n.map(u=>{const d=Math.min(Math.floor((u-a)/i*7),7);return r[d]}).join("");return o`
    <span class="mdal-spark" title="Metric progression (${n.length} iterations)">
      ${c}
    </span>
  `}function Jl({record:t}){const e=t.delta>0?"positive":t.delta<0?"negative":"neutral";return o`
    <div class="mdal-iter-row">
      <span class="mdal-iter-num">#${t.iteration}</span>
      <span class="mdal-iter-metric">${t.metric_before.toFixed(4)}</span>
      <span class="mdal-iter-arrow">\u2192</span>
      <span class="mdal-iter-metric">${t.metric_after.toFixed(4)}</span>
      <span class="mdal-iter-delta ${e}">${ni(t.delta)}</span>
      <span class="mdal-iter-time">${t.elapsed_ms}ms</span>
    </div>
  `}function Wl({loop:t}){const e=t.current_metric-t.baseline_metric;return o`
    <${y} title=${`${t.loop_id}`} class="mdal-loop-card">
      <div class="mdal-loop-header">
        <div class="mdal-loop-badges">
          <${X} status=${t.status} />
          <span class="mdal-profile-badge">${t.profile}</span>
        </div>
        <span class="mdal-loop-target" title="Target">${t.target}</span>
      </div>

      <div class="mdal-loop-metrics">
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Baseline</span>
          <span class="mdal-metric-value">${t.baseline_metric.toFixed(4)}</span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Current</span>
          <span class="mdal-metric-value">${t.current_metric.toFixed(4)}</span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Total Delta</span>
          <span class="mdal-metric-value ${e>=0?"positive":"negative"}">
            ${ni(e)}
          </span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Iteration</span>
          <span class="mdal-metric-value">
            ${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}
          </span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Stagnation</span>
          <span class="mdal-metric-value">
            ${t.stagnation_streak}${t.stagnation_limit>0?`/${t.stagnation_limit}`:""}
          </span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Elapsed</span>
          <span class="mdal-metric-value">${ql(t.elapsed_seconds)}</span>
        </div>
      </div>

      <div class="mdal-spark-section">
        <span class="mdal-metric-label">Progress</span>
        <${Gl} history=${t.history} />
      </div>

      ${t.history.length>0?o`
        <details class="mdal-history-details">
          <summary>Iteration History (${t.history.length})</summary>
          <div class="mdal-iter-list">
            ${t.history.map(n=>o`<${Jl} key=${n.iteration} record=${n} />`)}
          </div>
        </details>
      `:null}
    <//>
  `}function Vl(){const t=Hl.value,e=Bl.value,n=Kl.value,a=t.filter(s=>s.status==="stopped").length;return o`
    <style>
      .mdal-loop-card { margin-bottom: 12px; }
      .mdal-loop-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; flex-wrap: wrap; gap: 4px; }
      .mdal-loop-badges { display: flex; gap: 6px; align-items: center; }
      .mdal-profile-badge { background: #334155; color: #e2e8f0; padding: 2px 8px; border-radius: 4px; font-size: 12px; }
      .mdal-loop-target { color: #94a3b8; font-size: 13px; }
      .mdal-loop-metrics { display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr)); gap: 8px; margin: 8px 0; }
      .mdal-metric-pair { display: flex; flex-direction: column; }
      .mdal-metric-label { font-size: 11px; color: #64748b; text-transform: uppercase; letter-spacing: 0.5px; }
      .mdal-metric-value { font-size: 16px; font-weight: 600; font-variant-numeric: tabular-nums; }
      .mdal-metric-value.positive { color: #4ade80; }
      .mdal-metric-value.negative { color: #fb7185; }
      .mdal-spark-section { margin: 8px 0; }
      .mdal-spark { font-family: monospace; font-size: 18px; letter-spacing: 1px; color: #38bdf8; }
      .mdal-spark-empty { color: #64748b; font-size: 13px; }
      .mdal-history-details { margin-top: 8px; }
      .mdal-history-details summary { cursor: pointer; color: #94a3b8; font-size: 13px; }
      .mdal-iter-list { margin-top: 6px; }
      .mdal-iter-row { display: flex; gap: 8px; align-items: center; padding: 3px 0; font-size: 13px; font-variant-numeric: tabular-nums; border-bottom: 1px solid #1e293b; }
      .mdal-iter-num { color: #64748b; min-width: 28px; }
      .mdal-iter-metric { color: #e2e8f0; min-width: 60px; text-align: right; }
      .mdal-iter-arrow { color: #475569; }
      .mdal-iter-delta { min-width: 70px; text-align: right; font-weight: 600; }
      .mdal-iter-delta.positive { color: #4ade80; }
      .mdal-iter-delta.negative { color: #fb7185; }
      .mdal-iter-delta.neutral { color: #94a3b8; }
      .mdal-iter-time { color: #64748b; margin-left: auto; }
    </style>

    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-label">Running</div>
        <div class="stat-value" style="color:${wn("running")}">${e}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Completed</div>
        <div class="stat-value" style="color:${wn("completed")}">${n}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Stopped</div>
        <div class="stat-value" style="color:${wn("stopped")}">${a}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Total Loops</div>
        <div class="stat-value">${t.length}</div>
      </div>
    </div>

    <div class="council-grid">
      ${t.length===0?o`
          <${y} title="MDAL Loops" class="section">
            <div class="empty-state">
              No MDAL loops active. Start one with <code>masc_mdal_start</code>.
            </div>
          <//>
        `:t.map(s=>o`<${Wl} key=${s.loop_id} loop=${s} />`)}
    </div>
  `}const ua="masc_dashboard_agent_name";function Yl(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(ua);return e??n??"dashboard"}const Y=_(Yl()),Yt=_(""),Qt=_(""),Ue=_(""),Xt=_(!1),St=_(!1),Zt=_(!1),te=_(!1),He=_(!1),Ye=_(!1);function da(t){const e=t.trim();Y.value=e,e&&localStorage.setItem(ua,e)}function Ql(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Qn(){const t=Y.value.trim();if(t){Zt.value=!0;try{const e=await Io(t),n=Ql(e);n&&da(n),Ye.value=!0,b(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";b(n,"error")}finally{Zt.value=!1}}}async function Xl(){const t=Y.value.trim();if(t){te.value=!0;try{await Is(t),Ye.value=!1,b(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";b(n,"error")}finally{te.value=!1}}}async function Zl(){const t=Y.value.trim();if(t)try{await Is(t)}catch{}localStorage.removeItem(ua),da("dashboard"),Ye.value=!1,await Qn()}async function tc(){const t=Y.value.trim();if(t){He.value=!0;try{await Po(t),b("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";b(n,"error")}finally{He.value=!1}}}async function Ka(){const t=Y.value.trim(),e=Yt.value.trim();if(!(!t||!e)){Xt.value=!0;try{await Es(t,e),Yt.value="",b("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";b(a,"error")}finally{Xt.value=!1}}}async function ec(){const t=Qt.value.trim(),e=Ue.value.trim()||"Created from dashboard";if(t){St.value=!0;try{await Eo(t,e,1),Qt.value="",Ue.value="",b("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";b(a,"error")}finally{St.value=!1}}}function nc(){return ft(()=>{Qn()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${Y.value}
        onInput=${t=>da(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${Yt.value}
          onInput=${t=>{Yt.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&Ka()}}
          disabled=${Xt.value}
        />
        <button
          class="control-btn"
          onClick=${Ka}
          disabled=${Xt.value||Yt.value.trim()===""||Y.value.trim()===""}
        >
          ${Xt.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Qn()}}
          disabled=${Zt.value||Y.value.trim()===""}
        >
          ${Zt.value?"Joining...":Ye.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Xl()}}
          disabled=${te.value||Y.value.trim()===""}
        >
          ${te.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Zl()}}
          disabled=${Zt.value||te.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{tc()}}
          disabled=${He.value||Y.value.trim()===""}
        >
          ${He.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${Qt.value}
        onInput=${t=>{Qt.value=t.target.value}}
        disabled=${St.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${Ue.value}
        onInput=${t=>{Ue.value=t.target.value}}
        disabled=${St.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${ec}
        disabled=${St.value||Qt.value.trim()===""}
      >
        ${St.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function ac(){const t=Tt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${sa.value} events</span>
    </div>
  `}function sc(){const t=et.value.tab,e=Tt.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${ks.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>Ge(n.id)}
            >
              ${n.icon} ${n.label}
            </button>
          `)}
        </div>
        <div class="rail-links">
          <a class="rail-link" href="/dashboard/lodge">Legacy Lodge</a>
          <a class="rail-link" href="/dashboard/credits">Legacy Credits</a>
        </div>
      </section>

      <section class="rail-card">
        <h3>Live Snapshot</h3>
        <div class="rail-stats">
          <div class="rail-stat-row">
            <span>Connection</span>
            <strong>${e?"Online":"Offline"}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Agents</span>
            <strong>${Et.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${It.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${de.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${sa.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{We(),t==="board"&&ht(),t==="trpg"&&ot()}}
        >
          Refresh Now
        </button>
      </section>

      <${nc} />
    </aside>
  `}function ic(){switch(et.value.tab){case"overview":return o`<${ja} />`;case"council":return o`<${Dr} />`;case"board":return o`<${Hr} />`;case"execution":return o`<${sl} />`;case"activity":return o`<${Gr} />`;case"agents":return o`<${el} />`;case"tasks":return o`<${nl} />`;case"goals":return o`<${pl} />`;case"journal":return o`<${ol} />`;case"trpg":return o`<${Ul} />`;case"mdal":return o`<${Vl} />`;default:return o`<${ja} />`}}function oc(){return ft(()=>{Fi(),Cs(),We();const t=tr();return er(),()=>{Ji(),t(),nr()}},[]),ft(()=>{const t=et.value.tab;t==="board"&&ht(),t==="trpg"&&ot(),t==="goals"&&Un()},[et.value.tab]),o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">Decision and execution operations console</p>
        </div>
        <div class="header-right">
          <${ac} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${zi} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${jn.value&&!Tt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${ic} />`}
        </main>
        <${sc} />
      </div>

      <${mr} />
      <${xr} />
      <${gr} />
    </div>
  `}const qa=document.getElementById("app");qa&&xi(o`<${oc} />`,qa);
