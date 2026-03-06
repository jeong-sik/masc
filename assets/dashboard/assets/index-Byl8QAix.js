var Xi=Object.defineProperty;var Zi=(t,e,n)=>e in t?Xi(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var At=(t,e,n)=>Zi(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var mn,L,Ss,Cs,bt,Ba,As,Ns,Ts,Aa,Yn,Qn,me={},Rs=[],to=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,fn=Array.isArray;function lt(t,e){for(var n in e)t[n]=e[n];return t}function Na(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function Is(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?mn.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return je(t,r,a,s,null)}function je(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++Ss,__i:-1,__u:0};return s==null&&L.vnode!=null&&L.vnode(i),i}function ye(t){return t.children}function Wt(t,e){this.props=t,this.context=e}function Ot(t,e){if(e==null)return t.__?Ot(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?Ot(t):null}function Ls(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return Ls(t)}}function qa(t){(!t.__d&&(t.__d=!0)&&bt.push(t)&&!Ke.__r++||Ba!=L.debounceRendering)&&((Ba=L.debounceRendering)||As)(Ke)}function Ke(){for(var t,e,n,a,s,i,r,c=1;bt.length;)bt.length>c&&bt.sort(Ns),t=bt.shift(),c=bt.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=lt({},a)).__v=a.__v+1,L.vnode&&L.vnode(n),Ta(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??Ot(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,Ms(i,n,r),a.__e=a.__=null,n.__e!=s&&Ls(n)));Ke.__r=0}function Ps(t,e,n,a,s,i,r,c,d,u,v){var l,p,m,g,x,A,T,N=a&&a.__k||Rs,E=e.length;for(d=eo(n,e,N,d,E),l=0;l<E;l++)(m=n.__k[l])!=null&&(p=m.__i==-1?me:N[m.__i]||me,m.__i=l,A=Ta(t,m,p,s,i,r,c,d,u,v),g=m.__e,m.ref&&p.ref!=m.ref&&(p.ref&&Ra(p.ref,null,m),v.push(m.ref,m.__c||g,m)),x==null&&g!=null&&(x=g),(T=!!(4&m.__u))||p.__k===m.__k?d=Ds(m,d,t,T):typeof m.type=="function"&&A!==void 0?d=A:g&&(d=g.nextSibling),m.__u&=-7);return n.__e=x,d}function eo(t,e,n,a,s){var i,r,c,d,u,v=n.length,l=v,p=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=je(null,r,null,null,null):fn(r)?r=t.__k[i]=je(ye,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=je(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+p,r.__=t,r.__b=t.__b+1,c=null,(u=r.__i=no(r,n,d,l))!=-1&&(l--,(c=n[u])&&(c.__u|=2)),c==null||c.__v==null?(u==-1&&(s>v?p--:s<v&&p++),typeof r.type!="function"&&(r.__u|=4)):u!=d&&(u==d-1?p--:u==d+1?p++:(u>d?p--:p++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<v;i++)(c=n[i])!=null&&(2&c.__u)==0&&(c.__e==a&&(a=Ot(c)),Os(c,c));return a}function Ds(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=Ds(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=Ot(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function no(t,e,n,a){var s,i,r,c=t.key,d=t.type,u=e[n],v=u!=null&&(2&u.__u)==0;if(u===null&&c==null||v&&c==u.key&&d==u.type)return n;if(a>(v?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((u=e[r=s>=0?s--:i++])!=null&&(2&u.__u)==0&&c==u.key&&d==u.type)return r}return-1}function Ga(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||to.test(e)?n:n+"px"}function Ae(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||Ga(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||Ga(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Ts,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=Aa,t.addEventListener(e,i?Qn:Yn,i)):t.removeEventListener(e,i?Qn:Yn,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Ja(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Aa++;else if(e.t<n.u)return;return n(L.event?L.event(e):e)}}}function Ta(t,e,n,a,s,i,r,c,d,u){var v,l,p,m,g,x,A,T,N,E,U,P,V,ht,yt,Y,rt,I=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[c=e.__e=n.__e]),(v=L.__b)&&v(e);t:if(typeof I=="function")try{if(T=e.props,N="prototype"in I&&I.prototype.render,E=(v=I.contextType)&&a[v.__c],U=v?E?E.props.value:v.__:a,n.__c?A=(l=e.__c=n.__c).__=l.__E:(N?e.__c=l=new I(T,U):(e.__c=l=new Wt(T,U),l.constructor=I,l.render=so),E&&E.sub(l),l.state||(l.state={}),l.__n=a,p=l.__d=!0,l.__h=[],l._sb=[]),N&&l.__s==null&&(l.__s=l.state),N&&I.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=lt({},l.__s)),lt(l.__s,I.getDerivedStateFromProps(T,l.__s))),m=l.props,g=l.state,l.__v=e,p)N&&I.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),N&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(N&&I.getDerivedStateFromProps==null&&T!==m&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(T,U),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(T,l.__s,U)===!1){for(e.__v!=n.__v&&(l.props=T,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(z){z&&(z.__=e)}),P=0;P<l._sb.length;P++)l.__h.push(l._sb[P]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(T,l.__s,U),N&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(m,g,x)})}if(l.context=U,l.props=T,l.__P=t,l.__e=!1,V=L.__r,ht=0,N){for(l.state=l.__s,l.__d=!1,V&&V(e),v=l.render(l.props,l.state,l.context),yt=0;yt<l._sb.length;yt++)l.__h.push(l._sb[yt]);l._sb=[]}else do l.__d=!1,V&&V(e),v=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++ht<25);l.state=l.__s,l.getChildContext!=null&&(a=lt(lt({},a),l.getChildContext())),N&&!p&&l.getSnapshotBeforeUpdate!=null&&(x=l.getSnapshotBeforeUpdate(m,g)),Y=v,v!=null&&v.type===ye&&v.key==null&&(Y=Es(v.props.children)),c=Ps(t,fn(Y)?Y:[Y],e,n,a,s,i,r,c,d,u),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),A&&(l.__E=l.__=null)}catch(z){if(e.__v=null,d||i!=null)if(z.then){for(e.__u|=d?160:128;c&&c.nodeType==8&&c.nextSibling;)c=c.nextSibling;i[i.indexOf(c)]=null,e.__e=c}else{for(rt=i.length;rt--;)Na(i[rt]);Xn(e)}else e.__e=n.__e,e.__k=n.__k,z.then||Xn(e);L.__e(z,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):c=e.__e=ao(n.__e,e,n,a,s,i,r,d,u);return(v=L.diffed)&&v(e),128&e.__u?void 0:c}function Xn(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(Xn)}function Ms(t,e,n){for(var a=0;a<n.length;a++)Ra(n[a],n[++a],n[++a]);L.__c&&L.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){L.__e(i,s.__v)}})}function Es(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:fn(t)?t.map(Es):lt({},t)}function ao(t,e,n,a,s,i,r,c,d){var u,v,l,p,m,g,x,A=n.props||me,T=e.props,N=e.type;if(N=="svg"?s="http://www.w3.org/2000/svg":N=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(u=0;u<i.length;u++)if((m=i[u])&&"setAttribute"in m==!!N&&(N?m.localName==N:m.nodeType==3)){t=m,i[u]=null;break}}if(t==null){if(N==null)return document.createTextNode(T);t=document.createElementNS(s,N,T.is&&T),c&&(L.__m&&L.__m(e,i),c=!1),i=null}if(N==null)A===T||c&&t.data==T||(t.data=T);else{if(i=i&&mn.call(t.childNodes),!c&&i!=null)for(A={},u=0;u<t.attributes.length;u++)A[(m=t.attributes[u]).name]=m.value;for(u in A)if(m=A[u],u!="children"){if(u=="dangerouslySetInnerHTML")l=m;else if(!(u in T)){if(u=="value"&&"defaultValue"in T||u=="checked"&&"defaultChecked"in T)continue;Ae(t,u,null,m,s)}}for(u in T)m=T[u],u=="children"?p=m:u=="dangerouslySetInnerHTML"?v=m:u=="value"?g=m:u=="checked"?x=m:c&&typeof m!="function"||A[u]===m||Ae(t,u,m,A[u],s);if(v)c||l&&(v.__html==l.__html||v.__html==t.innerHTML)||(t.innerHTML=v.__html),e.__k=[];else if(l&&(t.innerHTML=""),Ps(e.type=="template"?t.content:t,fn(p)?p:[p],e,n,a,N=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&Ot(n,0),c,d),i!=null)for(u=i.length;u--;)Na(i[u]);c||(u="value",N=="progress"&&g==null?t.removeAttribute("value"):g!=null&&(g!==t[u]||N=="progress"&&!g||N=="option"&&g!=A[u])&&Ae(t,u,g,A[u],s),u="checked",x!=null&&x!=t[u]&&Ae(t,u,x,A[u],s))}return t}function Ra(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){L.__e(s,n)}}function Os(t,e,n){var a,s;if(L.unmount&&L.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||Ra(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){L.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&Os(a[s],e,n||typeof t.type!="function");n||Na(t.__e),t.__c=t.__=t.__e=void 0}function so(t,e,n){return this.constructor(t,n)}function io(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),L.__&&L.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],Ta(e,t=e.__k=Is(ye,null,[t]),s||me,me,e.namespaceURI,s?null:e.firstChild?mn.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),Ms(i,t,r)}mn=Rs.slice,L={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(c){t=c}throw t}},Ss=0,Cs=function(t){return t!=null&&t.constructor===void 0},Wt.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=lt({},this.state),typeof t=="function"&&(t=t(lt({},n),this.props)),t&&lt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),qa(this))},Wt.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),qa(this))},Wt.prototype.render=ye,bt=[],As=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Ns=function(t,e){return t.__v.__b-e.__v.__b},Ke.__r=0,Ts=/(PointerCapture)$|Capture$/i,Aa=0,Yn=Ja(!1),Qn=Ja(!0);var js=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],c=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=c:r===4?a[1]=Object.assign(a[1]||{},c):r===5?(a[1]=a[1]||{})[e[++i]]=c:r===6?a[1][e[++i]]+=c+"":r?(s=t.apply(c,js(t,c,n,["",null])),a.push(s),c[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(c)}return a},Wa=new Map;function oo(t){var e=Wa.get(this);return e||(e=new Map,Wa.set(this,e)),(e=js(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",c="",d=[0],u=function(p){i===1&&(p||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,p,r):i===3&&(p||r)?(d.push(3,p,r),i=2):i===2&&r==="..."&&p?d.push(4,p,0):i===2&&r&&!p?d.push(5,0,!0,r):i>=5&&((r||!p&&i===5)&&(d.push(i,0,r,s),i=6),p&&(d.push(i,p,0,s),i=6)),r=""},v=0;v<n.length;v++){v&&(i===1&&u(),u(v));for(var l=0;l<n[v].length;l++)a=n[v][l],i===1?a==="<"?(u(),d=[d],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:c?a===c?c="":r+=a:a==='"'||a==="'"?c=a:a===">"?(u(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[v][l+1]===">")?(u(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(u(),i=2):r+=a),i===3&&r==="!--"&&(i=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=oo.bind(Is),fe,O,kn,Va,Zn=0,zs=[],j=L,Ya=j.__b,Qa=j.__r,Xa=j.diffed,Za=j.__c,ts=j.unmount,es=j.__;function Ia(t,e){j.__h&&j.__h(O,t,Zn||e),Zn=0;var n=O.__H||(O.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function Ne(t){return Zn=1,ro(Hs,t)}function ro(t,e,n){var a=Ia(fe++,2);if(a.t=t,!a.__c&&(a.__=[Hs(void 0,e),function(c){var d=a.__N?a.__N[0]:a.__[0],u=a.t(d,c);d!==u&&(a.__N=[u,a.__[1]],a.__c.setState({}))}],a.__c=O,!O.__f)){var s=function(c,d,u){if(!a.__c.__H)return!0;var v=a.__c.__H.__.filter(function(p){return!!p.__c});if(v.every(function(p){return!p.__N}))return!i||i.call(this,c,d,u);var l=a.__c.props!==c;return v.forEach(function(p){if(p.__N){var m=p.__[0];p.__=p.__N,p.__N=void 0,m!==p.__[0]&&(l=!0)}}),i&&i.call(this,c,d,u)||l};O.__f=!0;var i=O.shouldComponentUpdate,r=O.componentWillUpdate;O.componentWillUpdate=function(c,d,u){if(this.__e){var v=i;i=void 0,s(c,d,u),i=v}r&&r.call(this,c,d,u)},O.shouldComponentUpdate=s}return a.__N||a.__}function gt(t,e){var n=Ia(fe++,3);!j.__s&&Us(n.__H,e)&&(n.__=t,n.u=e,O.__H.__h.push(n))}function Fs(t,e){var n=Ia(fe++,7);return Us(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function lo(){for(var t;t=zs.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(ze),t.__H.__h.forEach(ta),t.__H.__h=[]}catch(e){t.__H.__h=[],j.__e(e,t.__v)}}j.__b=function(t){O=null,Ya&&Ya(t)},j.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),es&&es(t,e)},j.__r=function(t){Qa&&Qa(t),fe=0;var e=(O=t.__c).__H;e&&(kn===O?(e.__h=[],O.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(ze),e.__h.forEach(ta),e.__h=[],fe=0)),kn=O},j.diffed=function(t){Xa&&Xa(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(zs.push(e)!==1&&Va===j.requestAnimationFrame||((Va=j.requestAnimationFrame)||co)(lo)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),kn=O=null},j.__c=function(t,e){e.some(function(n){try{n.__h.forEach(ze),n.__h=n.__h.filter(function(a){return!a.__||ta(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],j.__e(a,n.__v)}}),Za&&Za(t,e)},j.unmount=function(t){ts&&ts(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{ze(a)}catch(s){e=s}}),n.__H=void 0,e&&j.__e(e,n.__v))};var ns=typeof requestAnimationFrame=="function";function co(t){var e,n=function(){clearTimeout(a),ns&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);ns&&(e=requestAnimationFrame(n))}function ze(t){var e=O,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),O=e}function ta(t){var e=O;t.__c=t.__(),O=e}function Us(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}function Hs(t,e){return typeof e=="function"?e(t):e}var uo=Symbol.for("preact-signals");function _n(){if(ft>1)ft--;else{for(var t,e=!1;Vt!==void 0;){var n=Vt;for(Vt=void 0,ea++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&qs(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(ea=0,ft--,e)throw t}}function po(t){if(ft>0)return t();ft++;try{return t()}finally{_n()}}var R=void 0;function Ks(t){var e=R;R=void 0;try{return t()}finally{R=e}}var Vt=void 0,ft=0,ea=0,Be=0;function Bs(t){if(R!==void 0){var e=t.n;if(e===void 0||e.t!==R)return e={i:0,S:t,p:R.s,n:void 0,t:R,e:void 0,x:void 0,r:e},R.s!==void 0&&(R.s.n=e),R.s=e,t.n=e,32&R.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=R.s,e.n=void 0,R.s.n=e,R.s=e),e}}function F(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}F.prototype.brand=uo;F.prototype.h=function(){return!0};F.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:Ks(function(){var a;(a=e.W)==null||a.call(e)}))};F.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&Ks(function(){var s;(s=e.Z)==null||s.call(e)}))}};F.prototype.subscribe=function(t){var e=this;return be(function(){var n=e.value,a=R;R=void 0;try{t(n)}finally{R=a}},{name:"sub"})};F.prototype.valueOf=function(){return this.value};F.prototype.toString=function(){return this.value+""};F.prototype.toJSON=function(){return this.value};F.prototype.peek=function(){var t=R;R=void 0;try{return this.value}finally{R=t}};Object.defineProperty(F.prototype,"value",{get:function(){var t=Bs(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(ea>100)throw new Error("Cycle detected");this.v=t,this.i++,Be++,ft++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{_n()}}}});function f(t,e){return new F(t,e)}function qs(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function Gs(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Js(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function kt(t,e){F.call(this,void 0),this.x=t,this.s=void 0,this.g=Be-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}kt.prototype=new F;kt.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===Be))return!0;if(this.g=Be,this.f|=1,this.i>0&&!qs(this))return this.f&=-2,!0;var t=R;try{Gs(this),R=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return R=t,Js(this),this.f&=-2,!0};kt.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}F.prototype.S.call(this,t)};kt.prototype.U=function(t){if(this.t!==void 0&&(F.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};kt.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(kt.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Bs(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function nt(t,e){return new kt(t,e)}function Ws(t){var e=t.u;if(t.u=void 0,typeof e=="function"){ft++;var n=R;R=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,La(t),a}finally{R=n,_n()}}}function La(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,Ws(t)}function vo(t){if(R!==this)throw new Error("Out-of-order effect");Js(this),R=t,this.f&=-2,8&this.f&&La(this),_n()}function Ut(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Ut.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Ut.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,Ws(this),Gs(this),ft++;var t=R;return R=this,vo.bind(this,t)};Ut.prototype.N=function(){2&this.f||(this.f|=2,this.o=Vt,Vt=this)};Ut.prototype.d=function(){this.f|=8,1&this.f||La(this)};Ut.prototype.dispose=function(){this.d()};function be(t,e){var n=new Ut(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var Vs,Te,mo=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Ys=[];be(function(){Vs=this.N})();function Ht(t,e){L[t]=e.bind(null,L[t]||function(){})}function qe(t){if(Te){var e=Te;Te=void 0,e()}Te=t&&t.S()}function Qs(t){var e=this,n=t.data,a=_o(n);a.value=n;var s=Fs(function(){for(var c=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=nt(function(){var m=a.value.value;return m===0?0:m===!0?"":m||""}),v=nt(function(){return!Array.isArray(u.value)&&!Cs(u.value)}),l=be(function(){if(this.N=Xs,v.value){var m=u.value;c.__v&&c.__v.__e&&c.__v.__e.nodeType===3&&(c.__v.__e.data=m)}}),p=e.__$u.d;return e.__$u.d=function(){l(),p.call(this)},[v,u]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}Qs.displayName="ReactiveTextNode";Object.defineProperties(F.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Qs},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});Ht("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof F&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});Ht("__r",function(t,e){if(t(e),e.type!==ye){qe();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return be(function(){r=this},{name:i}),r.c=s,r})(function(){var s;mo&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),qe(n)}});Ht("__e",function(t,e,n,a){qe(),t(e,n,a)});Ht("diffed",function(t,e){qe();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var c=i[r];c!==void 0&&!(r in a)&&(c.d(),i[r]=void 0)}else i={},n.U=i;for(var d in a){var u=i[d],v=a[d];u===void 0?(u=fo(n,d,v),i[d]=u):u.o(v,s)}for(var l in a)s[l]=a[l]}}t(e)});function fo(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=f(n),r=n.peek();return{o:function(c,d){i.value=c,r=c.peek()},d:be(function(){this.N=Xs;var c=i.value.value;r!==c?(r=void 0,s?t[e]=c:c!=null&&(c!==!1||e[4]==="-")?t.setAttribute(e,c):t.removeAttribute(e)):r=void 0})}}Ht("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var c=r.__$u;c&&(r.__$u=void 0,c.d())}}t(e)});Ht("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});Wt.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var c in this.props)if(!(c in t))return!0;return!1};function _o(t,e){return Fs(function(){return f(t,e)},[])}var go=function(t){queueMicrotask(function(){queueMicrotask(t)})};function $o(){po(function(){for(var t;t=Ys.shift();)Vs.call(t)})}function Xs(){Ys.push(this)===1&&(L.requestAnimationFrame||go)($o)}const ho=["overview","ops","execution","board","activity","agents","tasks","goals","journal","trpg","council","mdal"],Zs={tab:"overview",params:{},postId:null};function as(t){return!!t&&ho.includes(t)}function na(t){try{return decodeURIComponent(t)}catch{return t}}function aa(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function yo(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function ti(t,e){const n=t[0],a=e.tab,s=as(n)?n:as(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=na(t[2]):t[0]==="post"&&t[1]&&(i=na(t[1]))),{tab:s,params:e,postId:i}}function Ge(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Zs;const n=na(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const c=n.indexOf("?");c>=0&&(a=n.slice(0,c),s=n.slice(c+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=aa(s),r=yo(a);return ti(r,i)}function bo(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...Zs,params:aa(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=aa(e.replace(/^\?/,""));return ti(a,s)}function ei(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const ot=f(Ge(window.location.hash));window.addEventListener("hashchange",()=>{ot.value=Ge(window.location.hash)});function gn(t,e){const n={tab:t,params:{},postId:null};window.location.hash=ei(n)}function xo(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function ko(){if(window.location.hash&&window.location.hash!=="#"){ot.value=Ge(window.location.hash);return}const t=bo(window.location.pathname,window.location.search);if(t){ot.value=t;const e=ei(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",ot.value=Ge(window.location.hash)}const ni=[{id:"overview",label:"Overview",icon:"🏠"},{id:"ops",label:"Ops",icon:"🎮"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"goals",label:"Goals",icon:"🎯"},{id:"execution",label:"Execution",icon:"🛠️"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"},{id:"mdal",label:"MDAL",icon:"📈"}];function wo(){const t=ot.value.tab;return o`
    <div class="main-tab-bar">
      ${ni.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>gn(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const ss="masc_dashboard_sse_session_id",So=1e3,Co=15e3,jt=f(!1),Pa=f(0),ai=f(null),Je=f([]);function Ao(){let t=sessionStorage.getItem(ss);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(ss,t)),t}const No=200;function Q(t,e){const n={agent:t,text:e,timestamp:Date.now()};Je.value=[n,...Je.value].slice(0,No)}let it=null,Dt=null,sa=0;function si(){Dt&&(clearTimeout(Dt),Dt=null)}function To(){if(Dt)return;sa++;const t=Math.min(sa,5),e=Math.min(Co,So*Math.pow(2,t));Dt=setTimeout(()=>{Dt=null,ii()},e)}function ii(){si(),it&&(it.close(),it=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",Ao());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);it=i,i.onopen=()=>{it===i&&(sa=0,jt.value=!0)},i.onerror=()=>{it===i&&(jt.value=!1,i.close(),it=null,To())},i.onmessage=r=>{try{const c=JSON.parse(r.data);Pa.value++,ai.value=c,Ro(c)}catch{}}}function Ro(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":Q(n,"Joined");break;case"agent_left":Q(n,"Left");break;case"broadcast":Q(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":Q(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":Q(n,"New post");break;case"board_comment":Q(n,"New comment");break;case"keeper_heartbeat":Q(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":Q(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":Q(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":Q(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:Q(n,e)}}function Io(){si(),it&&(it.close(),it=null),jt.value=!1}function oi(){return new URLSearchParams(window.location.search)}function ri(){const t=oi(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function li(){return{...ri(),"Content-Type":"application/json"}}const Lo=15e3,ci=3e4,Po=6e4,is=new Set([408,425,429,500,502,503,504]);class xe extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,i=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);At(this,"method");At(this,"path");At(this,"status");At(this,"statusText");At(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function Da(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new xe({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(s)}}function Do(){var e,n;const t=oi();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function dt(t){const e=await Da(t,{headers:ri()},Lo);if(!e.ok)throw new xe({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Mo(t){return new Promise(e=>setTimeout(e,t))}function Eo(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function Oo(t){if(t instanceof xe)return t.timeout||typeof t.status=="number"&&is.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Eo(t.message);return e!==null&&is.has(e)}async function ke(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!Oo(s)||a>=n)throw s;const i=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${i}ms`,s),await Mo(i),a+=1}}async function pt(t,e,n){const a=await Da(t,{method:"POST",headers:{...li(),...n??{}},body:JSON.stringify(e)},ci);if(!a.ok)throw new xe({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function jo(t,e,n,a=ci){const s=await Da(t,{method:"POST",headers:{...li(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new xe({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function zo(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Fo(t){var e,n,a,s,i,r,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(d)}return((c=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:c.text)??""}async function B(t,e){const n=await jo("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Po),a=zo(n);return Fo(a)}function Uo(t="compact"){return dt(`/api/v1/dashboard?mode=${t}`)}function Ho(){return dt("/api/v1/operator")}function Ko(t){return pt("/api/v1/operator/action",t)}function Bo(t,e){return pt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function zt(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function qo(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function ui(t){if(!S(t))return null;const e=_(t.id,"").trim(),n=_(t.author,"").trim(),a=_(t.content,"").trim();if(!e||!n)return null;const s=w(t.score,0),i=w(t.votes_up,0),r=w(t.votes_down,0),c=w(t.votes,s||i-r),d=w(t.comment_count,w(t.reply_count,0)),u=(()=>{const g=t.flair;if(typeof g=="string"&&g.trim())return g.trim();if(S(g)){const A=_(g.name,"").trim();if(A)return A}return _(t.flair_name,"").trim()||void 0})(),v=_(t.created_at_iso,"").trim()||zt(t.created_at),l=_(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?zt(t.updated_at):v),m=_(t.title,"").trim()||qo(a);return{id:e,author:n,title:m,content:a,tags:[],votes:c,vote_balance:s,comment_count:d,created_at:v,updated_at:l,flair:u,hearth_count:w(t.hearth_count,0)}}function Go(t){if(!S(t))return null;const e=_(t.id,"").trim(),n=_(t.post_id,"").trim(),a=_(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:_(t.content,""),created_at:zt(t.created_at)}}async function Jo(t){return ke("fetchBoard",async()=>{const e=new URLSearchParams;t&&e.set("sort_by",t),e.set("limit","100");const n=e.toString(),a=await dt(`/api/v1/board${n?`?${n}`:""}`);return{posts:Array.isArray(a.posts)?a.posts.map(ui).filter(i=>i!==null):[]}})}async function Wo(t){return ke("fetchBoardPost",async()=>{const e=await dt(`/api/v1/board/${t}?format=flat`),n=S(e.post)?e.post:e,a=ui(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(Go).filter(r=>r!==null);return{...a,comments:i}})}function di(t,e){return pt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Do()})}function Vo(t,e,n){return pt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Yo(t){const e=_(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function K(...t){for(const e of t){const n=_(e,"");if(n.trim())return n.trim()}return""}function os(t){const e=Yo(K(t.outcome,t.result,t.result_code));if(!e)return;const n=K(t.reason,t.reason_code,t.description,t.detail),a=K(t.summary,t.summary_ko,t.summary_en,t.note),s=K(t.details,t.details_text,t.text,t.note),i=K(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=K(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=K(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const l=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof l=="string"?[l]:Array.isArray(l)?l.map(p=>{if(typeof p=="string")return p.trim();if(S(p)){const m=_(p.summary,"").trim();if(m)return m;const g=_(p.text,"").trim();if(g)return g;const x=_(p.type,"").trim();return x||_(p.event_id,"").trim()}return""}).filter(p=>p.length>0):[]})(),u=(()=>{const l=w(t.turn,Number.NaN);if(Number.isFinite(l))return l;const p=w(t.turn_number,Number.NaN);if(Number.isFinite(p))return p;const m=w(t.current_turn,Number.NaN);if(Number.isFinite(m))return m;const g=w(t.round,Number.NaN);return Number.isFinite(g)?g:void 0})(),v=K(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:c||void 0,turn:u,phase:v||void 0}}function Qo(t,e){const n=S(t.state)?t.state:{};if(_(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>S(r)?_(r.type,"")==="session.outcome":!1),i=S(n.session_outcome)?n.session_outcome:{};if(S(i)&&Object.keys(i).length>0){const r=os(i);if(r)return r}if(S(s))return os(S(s.payload)?s.payload:{})}function S(t){return typeof t=="object"&&t!==null}function _(t,e=""){return typeof t=="string"?t:e}function w(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function mt(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function ia(t,e=!1){return typeof t=="boolean"?t:e}function Gt(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(S(e)){const n=_(e.name,"").trim(),a=_(e.id,"").trim(),s=_(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function Xo(t){const e={};if(!S(t)&&!Array.isArray(t))return e;if(S(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),i=_(a,"").trim();!s||!i||(e[s]=i)}),e;for(const n of t){if(!S(n))continue;const a=K(n.to,n.target,n.actor_id,n.name,n.id),s=K(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function Zo(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function J(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}const tr=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function er(t){const e=S(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const i=a.trim();i&&(tr.has(i.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[i]=s))}),n}function nr(t,e){if(t!=="dice.rolled")return;const n=w(e.raw_d20,0),a=w(e.total,0),s=w(e.bonus,0),i=_(e.action,"roll"),r=w(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function ar(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function sr(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function ir(t,e,n,a){const s=n||e||_(a.actor_id,"")||_(a.actor_name,"");switch(t){case"turn.action.proposed":{const i=_(a.proposed_action,_(a.reply,""));return i?`${s||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=_(a.reply,_(a.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return _(a.reply,_(a.content,_(a.text,"Narration")));case"dice.rolled":{const i=_(a.action,"roll"),r=w(a.total,0),c=w(a.dc,0),d=_(a.label,""),u=s||"actor",v=c>0?` vs DC ${c}`:"",l=d?` (${d})`:"";return`${u} ${i}: ${r}${v}${l}`}case"turn.started":return`Turn ${w(a.turn,1)} started`;case"phase.changed":return`Phase: ${_(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${_(a.name,S(a.actor)?_(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${_(a.keeper_name,_(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${_(a.keeper_name,_(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${w(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${w(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||_(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||_(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${_(a.reason_code,"unknown")}`;case"memory.signal":{const i=S(a.entity_refs)?a.entity_refs:{},r=_(i.requested_tier,""),c=_(i.effective_tier,""),d=ia(i.guardrail_applied,!1),u=_(a.summary_en,_(a.summary_ko,"Memory signal"));if(!r&&!c)return u;const v=r&&c?`${r}->${c}`:c||r;return`${u} [${v}${d?" (guardrail)":""}]`}case"world.event":{if(_(a.event_type,"")==="canon.check"){const r=_(a.status,"unknown"),c=_(a.contract_id,"n/a");return`Canon ${r}: ${c}`}return _(a.description,_(a.summary,"World event"))}case"combat.attack":return _(a.summary,_(a.result,"Attack resolved"));case"combat.defense":return _(a.summary,_(a.result,"Defense resolved"));case"session.outcome":return _(a.summary,_(a.outcome,"Session ended"));default:{const i=ar(a);return i?`${t}: ${i}`:t}}}function or(t,e){const n=S(t)?t:{},a=_(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=_(n.actor_name,"").trim()||e[s]||_(S(n.payload)?n.payload.actor_name:"",""),r=S(n.payload)?n.payload:{},c=_(n.ts,_(n.timestamp,new Date().toISOString())),d=_(n.phase,_(r.phase,"")),u=_(n.category,"");return{type:a,actor:i||s||_(r.actor_name,""),actor_id:s||_(r.actor_id,""),actor_name:i,seq:n.seq,room_id:_(n.room_id,""),phase:d||void 0,category:u||sr(a),visibility:_(n.visibility,_(r.visibility,"public")),event_id:_(n.event_id,""),content:ir(a,s,i,r),dice_roll:nr(a,r),timestamp:c}}function rr(t,e,n){var Y,rt;const a=_(t.room_id,"")||n||"default",s=S(t.state)?t.state:{},i=S(s.party)?s.party:{},r=S(s.actor_control)?s.actor_control:{},c=S(s.join_gate)?s.join_gate:{},d=S(s.contribution_ledger)?s.contribution_ledger:{},u=Object.entries(i).map(([I,z])=>{const $=S(z)?z:{},Ce=J($,"max_hp",void 0,10),Ua=J($,"hp",void 0,Ce),Fi=J($,"max_mp",void 0,0),Ui=J($,"mp",void 0,0),Hi=J($,"level",void 0,1),Ki=J($,"xp",void 0,0),Bi=ia($.alive,Ua>0),Ha=r[I],Ka=typeof Ha=="string"?Ha:void 0,qi=Zo($.role,I,Ka),Gi=mt($.generation),Ji=K($.joined_at,$.joinedAt,$.started_at,$.startedAt),Wi=K($.claimed_at,$.claimedAt,$.assigned_at,$.assignedAt,$.assigned_time),Vi=K($.last_seen,$.lastSeen,$.last_seen_at,$.lastSeenAt,$.last_active,$.lastActive),Yi=K($.scene,$.current_scene,$.currentScene,$.world_scene,$.scene_name,$.sceneName),Qi=K($.location,$.current_location,$.currentLocation,$.position,$.zone,$.area);return{id:I,name:_($.name,I),role:qi,keeper:Ka,archetype:_($.archetype,""),persona:_($.persona,""),portrait:_($.portrait,"")||void 0,background:_($.background,"")||void 0,traits:Gt($.traits),skills:Gt($.skills),stats_raw:er($),status:Bi?"active":"dead",generation:Gi,joined_at:Ji||void 0,claimed_at:Wi||void 0,last_seen:Vi||void 0,scene:Yi||void 0,location:Qi||void 0,inventory:Gt($.inventory),notes:Gt($.notes),relationships:Xo($.relationships),stats:{hp:Ua,max_hp:Ce,mp:Ui,max_mp:Fi,level:Hi,xp:Ki,strength:J($,"strength","str",10),dexterity:J($,"dexterity","dex",10),constitution:J($,"constitution","con",10),intelligence:J($,"intelligence","int",10),wisdom:J($,"wisdom","wis",10),charisma:J($,"charisma","cha",10)}}}),v=u.filter(I=>I.status!=="dead"),l=Qo(t,e),p={phase_open:ia(c.phase_open,!0),min_points:w(c.min_points,3),window:_(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},m=Object.entries(d).map(([I,z])=>{const $=S(z)?z:{};return{actor_id:I,score:w($.score,0),last_reason:_($.last_reason,"")||null,reasons:Gt($.reasons)}}),g=u.reduce((I,z)=>(I[z.id]=z.name,I),{}),x=e.map(I=>or(I,g)),A=w(s.turn,1),T=_(s.phase,"round"),N=_(s.map,""),E=S(s.world)?s.world:{},U=N||_(E.ascii_map,_(E.map,"")),P=x.filter((I,z)=>{const $=e[z];if(!S($))return!1;const Ce=S($.payload)?$.payload:{};return w(Ce.turn,-1)===A}),V=(P.length>0?P:x).slice(-12),ht=_(s.status,"active");return{session:{id:a,room:a,status:ht==="ended"?"ended":ht==="paused"?"paused":"active",round:A,actors:v,created_at:((Y=x[0])==null?void 0:Y.timestamp)??new Date().toISOString()},current_round:{round_number:A,phase:T,events:V,timestamp:((rt=x[x.length-1])==null?void 0:rt.timestamp)??new Date().toISOString()},map:U||void 0,join_gate:p,contribution_ledger:m,outcome:l,party:v,story_log:x,history:[]}}async function lr(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await dt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function cr(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([dt(`/api/v1/trpg/state${e}`),lr(t)]);return rr(n,a,t)}function ur(t){return pt("/api/v1/trpg/rounds/run",{room_id:t})}function dr(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function pr(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),pt("/api/v1/trpg/dice/roll",e)}function vr(t,e){const n=dr();return pt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function mr(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),pt("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function fr(t,e,n){return pt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function _r(t,e,n){const a=await B("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function gr(t){const e=await B("trpg.mid_join.request",t);return JSON.parse(e)}async function pi(t,e){await B("masc_broadcast",{agent_name:t,message:e})}async function $r(t,e,n=1){await B("masc_add_task",{title:t,description:e,priority:n})}async function hr(t){return B("masc_join",{agent_name:t})}async function vi(t){await B("masc_leave",{agent_name:t})}async function yr(t){await B("masc_heartbeat",{agent_name:t})}async function br(t=40){return(await B("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function xr(t,e=20){return B("masc_task_history",{task_id:t,limit:e})}async function kr(){return ke("fetchDebates",async()=>{const t=await dt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!S(e))return null;const n=_(e.id,"").trim(),a=_(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:_(e.status,"open"),argument_count:w(e.argument_count,0),created_at:zt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function wr(){return ke("fetchCouncilSessions",async()=>{const t=await dt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!S(e))return null;const n=_(e.id,"").trim(),a=_(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:_(e.initiator,"system"),votes:w(e.votes,0),quorum:w(e.quorum,0),state:_(e.state,"open"),created_at:zt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Sr(t){const e=await B("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Cr(t){return ke("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await dt(`/api/v1/council/debates/${e}/summary`);if(!S(n))return null;const a=_(n.id,"").trim();return a?{id:a,topic:_(n.topic,""),status:_(n.status,"open"),support_count:w(n.support_count,0),oppose_count:w(n.oppose_count,0),neutral_count:w(n.neutral_count,0),total_arguments:w(n.total_arguments,0),created_at:zt(n.created_at_iso??n.created_at),summary_text:_(n.summary_text,"")}:null})}function Ar(t){const e=_(t,"").trim().toLowerCase();return e.startsWith("error")?"error":e==="running"||e==="completed"||e==="stopped"?e:"running"}function Nr(t){return S(t)?{iteration:mt(t.iteration)??0,metric_before:w(t.metric_before,0),metric_after:w(t.metric_after,0),delta:w(t.delta,0),changes:_(t.changes,""),failed_attempts:_(t.failed_attempts,""),next_suggestion:_(t.next_suggestion,""),elapsed_ms:mt(t.elapsed_ms)??0,cost_usd:typeof t.cost_usd=="number"&&Number.isFinite(t.cost_usd)?t.cost_usd:null}:null}function Tr(t){if(!S(t))return null;const e=_(t.loop_id,"").trim();if(!e)return null;const n=Array.isArray(t.history)?t.history.map(Nr).filter(a=>a!==null):[];return{loop_id:e,profile:_(t.profile,"custom"),status:Ar(t.status),current_iteration:mt(t.iteration)??mt(t.current_iteration)??0,max_iterations:mt(t.max_iterations)??0,baseline_metric:w(t.baseline_metric,0),current_metric:w(t.current_metric,w(t.baseline_metric,0)),target:_(t.target,""),stagnation_streak:mt(t.stagnation_streak)??0,stagnation_limit:mt(t.stagnation_limit)??0,elapsed_seconds:w(t.elapsed_seconds,0),history:n}}async function Rr(){try{const t=await B("masc_mdal_status",{}),e=JSON.parse(t);return S(e)&&_(e.error,"").trim()!==""?null:Tr(e)}catch{return null}}async function Ir(){try{const t=await B("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Kt=f([]),we=f([]),mi=f([]),Bt=f([]),wt=f(null),Jt=f(null),oa=f(new Map),fi=f([]),ra=f("hot"),_i=f(null),ct=f(""),$n=f([]),Yt=f(!1),Z=f(new Map),la=f(!1),ca=f(!1),ua=f(!1),gi=nt(()=>Kt.value.filter(t=>t.status==="active"||t.status==="idle")),Ma=nt(()=>{const t=we.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function Lr(t){var s;const e=t.metrics_series;if(!e||e.length===0){const i=((s=t.status)==null?void 0:s.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const a=n.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const Pr=nt(()=>{const t=new Map;for(const e of Bt.value)t.set(e.name,Lr(e));return t}),Dr=12e4,Mr=nt(()=>{const t=Date.now(),e=new Set,n=oa.value;for(const a of Bt.value){const s=n.get(a.name);s!=null&&t-s>Dr&&e.add(a.name)}return e}),We={},Er=5e3;function da(){delete We.compact,delete We.full}function tt(t){return typeof t=="object"&&t!==null}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function C(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Qt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function $i(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function Or(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function jr(t){if(!tt(t))return null;const e=y(t.name);return e?{name:e,status:$i(t.status),current_task:y(t.current_task)??null,last_seen:y(t.last_seen),emoji:y(t.emoji),koreanName:y(t.koreanName)??y(t.korean_name),model:y(t.model),traits:Qt(t.traits),interests:Qt(t.interests),activityLevel:C(t.activityLevel)??C(t.activity_level),primaryValue:y(t.primaryValue)??y(t.primary_value)}:null}function zr(t){if(!tt(t))return null;const e=y(t.id),n=y(t.title);return!e||!n?null:{id:e,title:n,status:Or(t.status),priority:C(t.priority),assignee:y(t.assignee),description:y(t.description),created_at:y(t.created_at),updated_at:y(t.updated_at)}}function Fr(t){if(!tt(t))return null;const e=y(t.from)??y(t.from_agent)??"system",n=y(t.content)??"",a=y(t.timestamp)??new Date().toISOString();return{id:y(t.id),seq:C(t.seq),from:e,content:n,timestamp:a,type:y(t.type)}}function Ur(t){return Array.isArray(t)?t.map(e=>{if(!tt(e))return null;const n=C(e.ts_unix);if(n==null)return null;const a=tt(e.handoff)?e.handoff:null;return{ts:n,context_ratio:C(e.context_ratio)??0,context_tokens:C(e.context_tokens)??0,context_max:C(e.context_max)??0,latency_ms:C(e.latency_ms)??0,generation:C(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:C(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:C(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?C(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Hr(t){return(Array.isArray(t)?t:tt(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!tt(n))return null;const a=tt(n.agent)?n.agent:null,s=tt(n.context)?n.context:null,i=tt(n.metrics_window)?n.metrics_window:void 0,r=y(n.name);if(!r)return null;const c=C(n.context_ratio)??C(s==null?void 0:s.context_ratio),d=y(n.status)??y(a==null?void 0:a.status)??"offline",u=$i(d),v=y(n.model)??y(n.active_model)??y(n.primary_model),l=Qt(n.skill_secondary),p=s?{source:y(s.source),context_ratio:C(s.context_ratio),context_tokens:C(s.context_tokens),context_max:C(s.context_max),message_count:C(s.message_count),has_checkpoint:typeof s.has_checkpoint=="boolean"?s.has_checkpoint:void 0}:void 0,m=a?{name:y(a.name),status:y(a.status),current_task:y(a.current_task)??null,last_seen:y(a.last_seen)}:void 0,g=Ur(n.metrics_series);return{name:r,emoji:y(n.emoji),koreanName:y(n.koreanName)??y(n.korean_name),agent_name:y(n.agent_name),trace_id:y(n.trace_id),model:v,primary_model:y(n.primary_model),active_model:y(n.active_model),next_model_hint:y(n.next_model_hint)??null,status:u,last_heartbeat:y(n.last_heartbeat)??y(a==null?void 0:a.last_seen),generation:C(n.generation),turn_count:C(n.turn_count)??C(n.total_turns),context_ratio:c,context_tokens:C(n.context_tokens)??C(s==null?void 0:s.context_tokens),context_max:C(n.context_max)??C(s==null?void 0:s.context_max),context_source:y(n.context_source)??y(s==null?void 0:s.source),context:p,traits:Qt(n.traits),interests:Qt(n.interests),primaryValue:y(n.primaryValue)??y(n.primary_value),activityLevel:C(n.activityLevel)??C(n.activity_level),memory_recent_note:y(n.memory_recent_note)??null,conversation_tail_count:C(n.conversation_tail_count),k2k_count:C(n.k2k_count),handoff_count_total:C(n.handoff_count_total)??C(n.trace_history_count),compaction_count:C(n.compaction_count),last_compaction_saved_tokens:C(n.last_compaction_saved_tokens),skill_primary:y(n.skill_primary)??null,skill_secondary:l,skill_reason:y(n.skill_reason)??null,metrics_series:g.length>0?g:void 0,metrics_window:i,agent:m}}).filter(n=>n!==null)}async function hn(t="full"){var a,s,i;const e=Date.now(),n=We[t];if(!(n&&e-n.time<Er)){la.value=!0;try{const r=await Uo(t);We[t]={data:r,time:e},Kt.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(jr).filter(c=>c!==null),we.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(zr).filter(c=>c!==null),mi.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(Fr).filter(c=>c!==null),Bt.value=Hr(r.keepers),wt.value=tt(r.status)?r.status:null,Jt.value=r.perpetual??null}catch(r){console.error("Dashboard fetch error:",r)}finally{la.value=!1}}}async function St(){ca.value=!0;try{const t=await Jo(ra.value);fi.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{ca.value=!1}}async function ut(){var t;ua.value=!0;try{const e=ct.value||((t=wt.value)==null?void 0:t.room)||"default";ct.value||(ct.value=e);const n=await cr(e);_i.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ua.value=!1}}async function Ve(){Yt.value=!0;try{const t=await Ir();$n.value=Array.isArray(t)?t:[]}catch(t){console.error("Goals fetch error:",t)}finally{Yt.value=!1}}async function hi(){try{const t=await Rr();if(!t)return;const e=new Map(Z.value),n=e.get(t.loop_id);e.set(t.loop_id,{...n??{},...t,history:t.history.length>0?t.history:(n==null?void 0:n.history)??[]}),Z.value=e}catch(t){console.error("MDAL fetch error:",t)}}let wn=null,Sn=null;function Kr(){return ai.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(oa.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),oa.value=n}if(da(),wn||(wn=setTimeout(()=>{hn(),wn=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(Sn||(Sn=setTimeout(()=>{St(),Sn=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&da(),e.type==="mdal_started"&&e.loop_id){const n=new Map(Z.value);n.set(e.loop_id,{...n.get(e.loop_id)??{},loop_id:e.loop_id,profile:e.profile??"custom",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??0,current_metric:e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]}),Z.value=n}if(e.type==="mdal_iteration"&&e.loop_id){const n=new Map(Z.value),a=e.metric_before??e.metric_after??0,s=e.metric_after??a,i=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:a,current_metric:s,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]},r={iteration:e.iteration??0,metric_before:a,metric_after:s,delta:e.delta??0,changes:"",failed_attempts:"",next_suggestion:"",elapsed_ms:0,cost_usd:null};n.set(e.loop_id,{...i,current_iteration:e.iteration??i.current_iteration,current_metric:s,history:[r,...i.history]}),Z.value=n}if((e.type==="mdal_completed"||e.type==="mdal_stopped")&&e.loop_id){const n=new Map(Z.value),a=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??e.metric_before??e.metric_after??0,current_metric:e.metric_after??e.metric_before??e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]};n.set(e.loop_id,{...a,current_iteration:e.iteration??a.current_iteration,current_metric:e.metric_after??a.current_metric,status:e.type==="mdal_completed"?"completed":"stopped"}),Z.value=n}}})}let Xt=null;function Br(){Xt||(Xt=setInterval(()=>{da(),hn()},1e4))}function qr(){Xt&&(clearInterval(Xt),Xt=null)}function b({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function at({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Gr(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function H({timestamp:t}){const e=Gr(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}const Ea=f(null);function yi(t){Ea.value=t}function rs(){Ea.value=null}const Rt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Jr(t){if(!t)return 0;const e=Rt.findIndex(n=>n.level===t);return e>=0?e:0}function Wr({keeper:t}){const e=Jr(t.autonomy_level),n=Rt[e]??Rt[0];if(!n)return null;const a=(e+1)/Rt.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Rt.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Rt.map((s,i)=>o`
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
            <strong><${H} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Fe(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Vr({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${s.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Fe(t.context_tokens)}</div>
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
  `}function Yr({keeper:t}){var v,l;const e=t.metrics_series??[];if(e.length<2){const p=(((v=t.context)==null?void 0:v.context_ratio)??0)*100,m=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${p.toFixed(1)}%;background:${m}"></div>
        </div>
        <span class="chart-pct">${p.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,i=e.length,r=e.map((p,m)=>{const g=s+m/(i-1)*(n-2*s),x=a-s-(p.context_ratio??0)*(a-2*s);return{x:g,y:x,p}}),c=r.map(({x:p,y:m})=>`${p.toFixed(1)},${m.toFixed(1)}`).join(" "),d=(((l=e[e.length-1])==null?void 0:l.context_ratio)??0)*100,u=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p})=>p.is_handoff).map(({x:p})=>o`
          <line x1="${p.toFixed(1)}" y1="${s}" x2="${p.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${u}" stroke-width="1.5"/>
        ${r.filter(({p})=>p.is_compaction).map(({x:p,y:m})=>o`
          <circle cx="${p.toFixed(1)}" cy="${m.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Cn=f("");function Qr({keeper:t}){var s,i,r,c;const e=Cn.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Cn.value}
        onInput=${d=>{Cn.value=d.target.value}}
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Fe(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Fe(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Fe(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Xr({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function Zr({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function tl({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function ls({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function An(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function el({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:An(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:An(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:An(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function nl({keeperName:t}){const[e,n]=Ne("Loading internal monologue..."),[a,s]=Ne(""),[i,r]=Ne([]),[c,d]=Ne(!1),u=async()=>{try{const l=await B("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof l=="string"?l:JSON.stringify(l,null,2))}catch(l){n("Failed to load: "+String(l))}};gt(()=>{u()},[t]);const v=async()=>{if(!a.trim())return;d(!0);const l=a;s(""),r(p=>[...p,{role:"You",text:l}]);try{const p=await B("masc_keeper_msg",{name:t,message:l});r(m=>[...m,{role:t,text:typeof p=="string"?p:JSON.stringify(p)}]),u()}catch(p){r(m=>[...m,{role:"System",text:"Error: "+String(p)}])}finally{d(!1)}};return o`
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
              onKeyDown=${l=>l.key==="Enter"&&!l.shiftKey&&v()}
              placeholder="Ping the agent..."
              disabled=${c}
              style="flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--text-primary); font-family: var(--font-body);"
            />
            <button 
              onClick=${v} 
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
  `}function al(){var e,n,a;const t=Ea.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&rs()}}
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
            <${at} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>rs()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Vr} keeper=${t} />

        ${""}
        <${Yr} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${b} title="Field Dictionary">
            <${Qr} keeper=${t} />
          <//>

          ${""}
          <${b} title="Profile">
            <${ls} traits=${t.traits??[]} label="Traits" />
            <${ls} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${H} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${b} title="Autonomy">
                <${Wr} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${b} title="TRPG Stats">
                <${Xr} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${b} title="Equipment (${t.inventory.length})">
                <${Zr} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${b} title="Relationships (${Object.keys(t.relationships).length})">
                <${tl} rels=${t.relationships} />
              <//>
            `:null}

          <${b} title="Runtime Signals">
            <${el} keeper=${t} />
          <//>

          <${b} title="Memory & Context">
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
        <${nl} keeperName=${t.name} />
      </div>
    </div>
  `:null}let sl=0;const xt=f([]);function h(t,e="success",n=4e3){const a=++sl;xt.value=[...xt.value,{id:a,message:t,type:e}],setTimeout(()=>{xt.value=xt.value.filter(s=>s.id!==a)},n)}function il(t){xt.value=xt.value.filter(e=>e.id!==t)}function ol(){const t=xt.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>il(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const rl="masc_dashboard_agent_name",qt=f(null),Ye=f(!1),_e=f(""),Qe=f([]),ge=f([]),Mt=f(""),Zt=f(!1);function bi(t){qt.value=t,Oa()}function cs(){qt.value=null,_e.value="",Qe.value=[],ge.value=[],Mt.value=""}function ll(){const t=qt.value;return t?Kt.value.find(e=>e.name===t)??null:null}function xi(t){return t?we.value.filter(e=>e.assignee===t):[]}async function Oa(){const t=qt.value;if(t){Ye.value=!0,_e.value="",Qe.value=[],ge.value=[];try{const e=await br(80);Qe.value=e.filter(s=>s.includes(t)).slice(0,20);const n=xi(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await xr(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));ge.value=a}catch(e){_e.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ye.value=!1}}}async function us(){var a;const t=qt.value,e=Mt.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(rl))==null?void 0:a.trim())||"dashboard";Zt.value=!0;try{await pi(n,`@${t} ${e}`),Mt.value="",h(`Mention sent to ${t}`,"success"),Oa()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";h(i,"error")}finally{Zt.value=!1}}function cl({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${at} status=${t.status} />
    </div>
  `}function ul({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function dl(){var s,i,r,c;const t=qt.value;if(!t)return null;const e=ll(),n=xi(t),a=Qe.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&cs()}}
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
                        <${at} status=${e.status} />
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
                ${(c=e==null?void 0:e.interests)==null?void 0:c.map(d=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${H} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Oa()}} disabled=${Ye.value}>
              ${Ye.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${cs}>Close</button>
          </div>
        </div>

        ${_e.value?o`<div class="council-error">${_e.value}</div>`:null}

        <div class="agent-detail-grid">
          <${b} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${cl} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${b} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((d,u)=>o`<div key=${u} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${b} title="Task History">
          ${ge.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${ge.value.map(d=>o`<${ul} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${b} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Mt.value}
              onInput=${d=>{Mt.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&us()}}
              disabled=${Zt.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{us()}}
              disabled=${Zt.value||Mt.value.trim()===""}
            >
              ${Zt.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Nt({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function pl({agent:t}){return o`
    <div class="agent" onClick=${()=>bi(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${at} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function vl(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function ml(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function ds(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function fl({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,a=Pr.value.get(t.name),s=Mr.value.has(t.name);return o`
    <div class="live-agent keeper-card ${s?"stale":""}" onClick=${()=>yi(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${at} status=${t.status} />
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
              <div class="keeper-ctx-fill ${ds(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${ds(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${vl(t.context_tokens)})`:null}
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
            <${H} timestamp=${t.last_heartbeat} />
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
          <div class="keeper-note-preview">${ml(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function ps(){var r,c,d,u,v;const t=wt.value,e=Kt.value,n=Bt.value,a=Ma.value,s=(r=t==null?void 0:t.monitoring)==null?void 0:r.board,i=(c=t==null?void 0:t.monitoring)==null?void 0:c.council;return o`
    <div class="stats-grid">
      <${Nt} label="Agents" value=${e.length} />
      <${Nt} label="Active" value=${gi.value.length} color="#4ade80" />
      <${Nt} label="Keepers" value=${n.length} color="#22d3ee" />
      <${Nt} label="Tasks" value=${we.value.length} />
      <${Nt} label="In Progress" value=${a.inProgress.length} color="#fbbf24" />
      <${Nt} label="Done" value=${a.done.length} color="#4ade80" />
    </div>

    ${s||i?o`
        <${b} title="Operations SLO" class="section">
          <div class="grid-2col">
            <div class="stat-card">
              <div class="stat-label">Board Feed</div>
              <div class="stat-value" style=${`color: ${ms(s==null?void 0:s.alert_level)}`}>
                ${vs(s==null?void 0:s.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${Re(s==null?void 0:s.last_activity_age_s)}</span>
                <span>SLO: ≤ ${Re(s==null?void 0:s.slo_target_age_s)}</span>
                <span>SLO Breach: ${s!=null&&s.slo_breached?"Yes":"No"}</span>
                <span>Posts (24h): ${(s==null?void 0:s.new_posts_24h)??0}</span>
                <span>Unanswered: ${(s==null?void 0:s.unanswered_posts)??0}</span>
              </div>
            </div>

            <div class="stat-card">
              <div class="stat-label">Council Feed</div>
              <div class="stat-value" style=${`color: ${ms(i==null?void 0:i.alert_level)}`}>
                ${vs(i==null?void 0:i.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${Re(i==null?void 0:i.last_activity_age_s)}</span>
                <span>Open Debates: ${(i==null?void 0:i.debates_open)??0}</span>
                <span>Pending Debates: ${(i==null?void 0:i.debates_pending)??0}</span>
                <span>Quorum Risk: ${(i==null?void 0:i.sessions_without_quorum)??0}</span>
                <span>SLO: ≤ ${Re(i==null?void 0:i.slo_target_quorum_age_s)}</span>
                <span>SLO Breach: ${i!=null&&i.slo_breached?"Yes":"No"}</span>
              </div>
            </div>
          </div>
        <//>
      `:null}

    <div class="grid-2col">
      <${b} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(l=>o`<${pl} key=${l.name} agent=${l} />`)}
        </div>
      <//>

      <${b} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(l=>o`<${fl} key=${l.name} keeper=${l} />`)}
        </div>
      <//>
    </div>

    ${Jt.value?o`
        <${b} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${Jt.value.running?"Running":"Stopped"}</span>
            ${Jt.value.goal?o`<span>Goal: ${Jt.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${b} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?o`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?o`<span>Project: ${t.project}</span>`:null}
            ${t.version?o`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${_l(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
            ${((d=t.data_quality)==null?void 0:d.board_contract_ok)===!1?o`<span class="pill pill-stale">Board Contract: Degraded</span>`:null}
            ${((u=t.data_quality)==null?void 0:u.council_feed_ok)===!1?o`<span class="pill pill-stale">Council Feed: Degraded</span>`:null}
            ${(v=t.data_quality)!=null&&v.last_sync_at?o`<span>Data Sync: <${H} timestamp=${t.data_quality.last_sync_at} /></span>`:null}
          </div>
        <//>
      `:null}
  `}function _l(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function Re(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function vs(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function ms(t){const e=(t??"").toLowerCase();return e==="ok"?"#4ade80":e==="warn"?"#fbbf24":e==="bad"?"#fb7185":"#94a3b8"}const Se=f(null),Xe=f(!1),$t=f(null),D=f(!1),Ze=f([]);let gl=1;function M(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function k(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function G(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ki(t){return typeof t=="boolean"?t:void 0}function $l(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function It(t,e=[]){if(Array.isArray(t))return t;if(!M(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function hl(t){return M(t)?{id:k(t.id),seq:G(t.seq),from:k(t.from)??k(t.from_agent)??"system",content:k(t.content)??"",timestamp:k(t.timestamp)??new Date().toISOString(),type:k(t.type)}:null}function yl(t){return M(t)?{room_id:k(t.room_id),current_room:k(t.current_room)??k(t.room),project:k(t.project),cluster:k(t.cluster),paused:ki(t.paused),pause_reason:k(t.pause_reason)??null,paused_by:k(t.paused_by)??null,paused_at:k(t.paused_at)??null}:{}}function fs(t){if(!M(t))return;const e=Object.entries(t).map(([n,a])=>{const s=k(a);return s?[n,s]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function bl(t){if(!M(t))return null;const e=M(t.status)?t.status:void 0,n=M(t.summary)?t.summary:M(e==null?void 0:e.summary)?e.summary:void 0,a=M(t.session)?t.session:M(e==null?void 0:e.session)?e.session:void 0,s=k(t.session_id)??k(n==null?void 0:n.session_id)??k(a==null?void 0:a.session_id);if(!s)return null;const i=fs(t.report_paths)??fs(e==null?void 0:e.report_paths),r=It(t.recent_events,["events"]).filter(M);return{session_id:s,status:k(t.status)??k(n==null?void 0:n.status)??k(a==null?void 0:a.status),progress_pct:G(t.progress_pct)??G(n==null?void 0:n.progress_pct),elapsed_sec:G(t.elapsed_sec)??G(n==null?void 0:n.elapsed_sec),remaining_sec:G(t.remaining_sec)??G(n==null?void 0:n.remaining_sec),done_delta_total:G(t.done_delta_total)??G(n==null?void 0:n.done_delta_total),summary:n,team_health:M(t.team_health)?t.team_health:M(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:M(t.communication_metrics)?t.communication_metrics:M(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:M(t.orchestration_state)?t.orchestration_state:M(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:M(t.cascade_metrics)?t.cascade_metrics:M(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:a,recent_events:r}}function xl(t){if(!M(t))return null;const e=k(t.name);if(!e)return null;const n=M(t.context)?t.context:void 0;return{name:e,agent_name:k(t.agent_name),status:k(t.status),autonomy_level:k(t.autonomy_level),context_ratio:G(t.context_ratio)??G(n==null?void 0:n.context_ratio),generation:G(t.generation),active_goal_ids:$l(t.active_goal_ids),last_autonomous_action_at:k(t.last_autonomous_action_at)??null,last_turn_ago_s:G(t.last_turn_ago_s),model:k(t.model)??k(t.active_model)??k(t.primary_model)}}function kl(t){if(!M(t))return null;const e=k(t.confirm_token)??k(t.token);return e?{confirm_token:e,actor:k(t.actor),action_type:k(t.action_type),target_type:k(t.target_type),target_id:k(t.target_id)??null,delegated_tool:k(t.delegated_tool),created_at:k(t.created_at),preview:t.preview}:null}function wl(t){const e=M(t)?t:{};return{room:yl(e.room),sessions:It(e.sessions,["items","sessions"]).map(bl).filter(n=>n!==null),keepers:It(e.keepers,["items","keepers"]).map(xl).filter(n=>n!==null),recent_messages:It(e.recent_messages,["messages"]).map(hl).filter(n=>n!==null),pending_confirms:It(e.pending_confirms,["items","confirms"]).map(kl).filter(n=>n!==null),available_actions:It(e.available_actions,["actions"]).filter(M).map(n=>({action_type:k(n.action_type)??"unknown",target_type:k(n.target_type)??"unknown",description:k(n.description),confirm_required:ki(n.confirm_required)}))}}function Ie(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function _s(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function tn(t){Ze.value=[{...t,id:gl++,at:new Date().toISOString()},...Ze.value].slice(0,20)}function wi(t){return t.confirm_required?Ie(t.preview)||"Confirmation required":Ie(t.result)||Ie(t.executed_action)||Ie(t.delegated_tool_result)||t.status}async function Ft(){Xe.value=!0,$t.value=null;try{const t=await Ho();Se.value=wl(t)}catch(t){$t.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Xe.value=!1}}async function Sl(t){D.value=!0,$t.value=null;try{const e=await Ko(t);return tn({actor:t.actor,action_type:t.action_type,target_label:_s(t),outcome:e.confirm_required?"preview":"executed",message:wi(e),delegated_tool:e.delegated_tool}),await Ft(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw $t.value=n,tn({actor:t.actor,action_type:t.action_type,target_label:_s(t),outcome:"error",message:n}),e}finally{D.value=!1}}async function Cl(t,e){D.value=!0,$t.value=null;try{const n=await Bo(t,e);return tn({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:wi(n),delegated_tool:n.delegated_tool}),await Ft(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw $t.value=a,tn({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{D.value=!1}}const Si="masc_dashboard_agent_name";function Al(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(Si))==null?void 0:a.trim())||"dashboard"}const yn=f(Al()),te=f(""),pa=f("Operator pause"),ee=f(""),en=f(""),va=f("2"),nn=f(""),Et=f("note"),an=f(""),sn=f(""),on=f(""),ma=f("2"),fa=f("Operator stop request"),_a=f(""),ne=f("");function Nl(t){const e=t.trim()||"dashboard";yn.value=e,localStorage.setItem(Si,e)}function gs(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Tl(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}async function Ct(t){const e=yn.value.trim()||"dashboard";try{const n=await Sl({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?h("Confirmation queued","warning"):h(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return h(a,"error"),null}}async function $s(){const t=te.value.trim();if(!t)return;await Ct({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(te.value="")}async function Rl(){await Ct({action_type:"room_pause",target_type:"room",payload:{reason:pa.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function Il(){await Ct({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function Ll(){const t=ee.value.trim();if(!t)return;await Ct({action_type:"task_inject",target_type:"room",payload:{title:t,description:en.value.trim()||"Injected from Ops tab",priority:Number.parseInt(va.value,10)||2},successMessage:"Task injection submitted"})&&(ee.value="",en.value="")}async function Pl(){var i;const t=Se.value,e=nn.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){h("Select a team session first","warning");return}const n={turn_kind:Et.value},a=an.value.trim();a&&(n.message=a),Et.value==="task"&&(n.task_title=sn.value.trim()||"Operator injected task",n.task_description=on.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(ma.value,10)||2),await Ct({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(an.value="",Et.value==="task"&&(sn.value="",on.value=""))}async function Dl(){var n;const t=Se.value,e=nn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){h("Select a team session first","warning");return}await Ct({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:fa.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function Ml(){var s;const t=Se.value,e=_a.value||((s=t==null?void 0:t.keepers[0])==null?void 0:s.name)||"",n=ne.value.trim();if(!e){h("Select a keeper first","warning");return}if(!n)return;await Ct({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(ne.value="")}async function El(t){const e=yn.value.trim()||"dashboard";try{await Cl(e,t),h("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";h(a,"error")}}function Ol(){var d;gt(()=>{Ft()},[]);const t=Se.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],s=(t==null?void 0:t.pending_confirms)??[],i=(t==null?void 0:t.recent_messages)??[],r=n.find(u=>u.session_id===nn.value)??n[0]??null,c=a.find(u=>u.name===_a.value)??a[0]??null;return o`
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
            value=${yn.value}
            onInput=${u=>Nl(u.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{Ft()}} disabled=${Xe.value||D.value}>
            ${Xe.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${$t.value?o`
        <section class="ops-banner error">${$t.value}</section>
      `:null}

      ${s.length>0?o`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <div class="ops-confirmation-list">
            ${s.map(u=>o`
              <article key=${u.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${u.action_type??"unknown"}</strong>
                  <span>${u.target_type??"target"}${u.target_id?`:${u.target_id}`:""}</span>
                  <span>${u.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${u.preview?o`<pre class="ops-code-block">${gs(u.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{El(u.confirm_token)}} disabled=${D.value}>
                    Confirm
                  </button>
                  <span class="ops-token">${u.confirm_token}</span>
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
              value=${te.value}
              onInput=${u=>{te.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&$s()}}
              disabled=${D.value}
            />
            <button class="control-btn" onClick=${()=>{$s()}} disabled=${D.value||te.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${pa.value}
              onInput=${u=>{pa.value=u.target.value}}
              disabled=${D.value}
            />
            <button class="control-btn ghost" onClick=${()=>{Rl()}} disabled=${D.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{Il()}} disabled=${D.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${ee.value}
            onInput=${u=>{ee.value=u.target.value}}
            disabled=${D.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${en.value}
            onInput=${u=>{en.value=u.target.value}}
            disabled=${D.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${va.value}
              onChange=${u=>{va.value=u.target.value}}
              disabled=${D.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{Ll()}} disabled=${D.value||ee.value.trim()===""}>
              Inject
            </button>
          </div>

          ${i.length>0?o`
            <div class="ops-section-head">Recent Messages</div>
            <div class="ops-feed-list">
              ${i.slice(0,6).map(u=>o`
                <article key=${u.seq??u.id??u.timestamp} class="ops-feed-item">
                  <div class="ops-feed-meta">
                    <strong>${u.from}</strong>
                    <span>${u.timestamp}</span>
                  </div>
                  <div class="ops-feed-content">${u.content}</div>
                </article>
              `)}
            </div>
          `:null}
        </section>

        <section class="card ops-panel">
          <div class="card-title">Team Sessions</div>
          <div class="ops-entity-list">
            ${n.length===0?o`<div class="ops-empty">No team sessions available.</div>`:n.map(u=>{var v;return o`
              <button
                key=${u.session_id}
                class="ops-entity-card ${(r==null?void 0:r.session_id)===u.session_id?"active":""}"
                onClick=${()=>{nn.value=u.session_id}}
              >
                <div class="ops-entity-title-row">
                  <strong>${u.session_id}</strong>
                  <span class="status-badge ${u.status??"idle"}">${u.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${Math.round(u.progress_pct??0)}%</span>
                  <span>${u.done_delta_total??0} done</span>
                  <span>${(v=u.team_health)!=null&&v.status?String(u.team_health.status):"health n/a"}</span>
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
                <pre class="ops-code-block compact">${gs(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Et.value}
              onChange=${u=>{Et.value=u.target.value}}
              disabled=${D.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{Pl()}} disabled=${D.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${an.value}
            onInput=${u=>{an.value=u.target.value}}
            disabled=${D.value||!r}
          ></textarea>
          ${Et.value==="task"?o`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${sn.value}
              onInput=${u=>{sn.value=u.target.value}}
              disabled=${D.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${on.value}
              onInput=${u=>{on.value=u.target.value}}
              disabled=${D.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${ma.value}
              onChange=${u=>{ma.value=u.target.value}}
              disabled=${D.value||!r}
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
              value=${fa.value}
              onInput=${u=>{fa.value=u.target.value}}
              disabled=${D.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{Dl()}} disabled=${D.value||!r}>
              Stop
            </button>
          </div>
        </section>

        <section class="card ops-panel">
          <div class="card-title">Keepers</div>
          <div class="ops-entity-list">
            ${a.length===0?o`<div class="ops-empty">No keepers available.</div>`:a.map(u=>o`
              <button
                key=${u.name}
                class="ops-entity-card ${(c==null?void 0:c.name)===u.name?"active":""}"
                onClick=${()=>{_a.value=u.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${u.name}</strong>
                  <span class="status-badge ${u.status??"idle"}">${u.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${u.model??"model n/a"}</span>
                  <span>${typeof u.context_ratio=="number"?`${Math.round(u.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${Tl(u.last_turn_ago_s)}</span>
                </div>
              </button>
            `)}
          </div>

          ${c?o`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${c.name}</div>
              <div class="ops-detail-meta">
                <span>Autonomy: ${c.autonomy_level??"n/a"}</span>
                <span>Generation: ${c.generation??0}</span>
                <span>Goals: ${((d=c.active_goal_ids)==null?void 0:d.length)??0}</span>
              </div>
            </div>
          `:null}

          <label class="control-label" for="ops-keeper-message">Keeper Message</label>
          <textarea
            id="ops-keeper-message"
            class="control-textarea"
            rows=${6}
            placeholder="Send a structured intervention or course correction"
            value=${ne.value}
            onInput=${u=>{ne.value=u.target.value}}
            disabled=${D.value||!c}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{Ml()}} disabled=${D.value||!c||ne.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${Ze.value.length===0?o`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:Ze.value.map(u=>o`
            <article key=${u.id} class="ops-log-entry ${u.outcome}">
              <div class="ops-log-head">
                <strong>${u.action_type}</strong>
                <span>${u.target_label}</span>
                <span>${u.at}</span>
              </div>
              <div class="ops-log-body">${u.message}</div>
            </article>
          `)}
        </div>
      </section>
    </section>
  `}const ga=f([]),$a=f([]),ae=f(""),rn=f(!1),se=f(!1),$e=f(""),ln=f(null),X=f(null),ha=f(!1);async function ya(){rn.value=!0,$e.value="";try{const[t,e]=await Promise.all([kr(),wr()]);ga.value=t,$a.value=e}catch(t){$e.value=t instanceof Error?t.message:"Failed to load council data"}finally{rn.value=!1}}async function hs(){const t=ae.value.trim();if(t){se.value=!0;try{const e=await Sr(t);ae.value="",h(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await ya()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";h(n,"error")}finally{se.value=!1}}}async function jl(t){ln.value=t,ha.value=!0,X.value=null;try{X.value=await Cr(t)}catch(e){$e.value=e instanceof Error?e.message:"Failed to load debate status",X.value=null}finally{ha.value=!1}}function zl({debate:t}){const e=ln.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>jl(t.id)}
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
  `}function Fl({session:t}){return o`
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
  `}function Ul(){var e;const t=(e=wt.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${H} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Hl(){var e,n;gt(()=>{ya()},[]);const t=((n=(e=wt.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${Ul} />
      <${b} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${ae.value}
            onInput=${a=>{ae.value=a.target.value}}
            onKeyDown=${a=>{a.key==="Enter"&&hs()}}
            disabled=${se.value}
          />
          <button
            class="control-btn secondary"
            onClick=${hs}
            disabled=${se.value||ae.value.trim()===""}
          >
            ${se.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${ya} disabled=${rn.value}>
            ${rn.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${$e.value?o`<div class="council-error">${$e.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${b} title="Debates" class="section">
          <div class="council-list">
            ${ga.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:ga.value.map(a=>o`<${zl} key=${a.id} debate=${a} />`)}
          </div>
        <//>

        <${b} title="Voting Sessions" class="section">
          <div class="council-list">
            ${$a.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:$a.value.map(a=>o`<${Fl} key=${a.id} session=${a} />`)}
          </div>
        <//>
      </div>

      <${b} title=${ln.value?`Debate Detail (${ln.value})`:"Debate Detail"} class="section">
        ${ha.value?o`<div class="loading-indicator">Loading debate detail...</div>`:X.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${X.value.status}</span>
                  <span>Total arguments: ${X.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${X.value.support_count}</span>
                  <span>Oppose: ${X.value.oppose_count}</span>
                  <span>Neutral: ${X.value.neutral_count}</span>
                </div>
                ${X.value.summary_text?o`<pre class="council-detail">${X.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Kl({text:t}){if(!t)return null;const e=Bl(t);return o`<div class="markdown-content">${e}</div>`}function Bl(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],c=s.slice(r.length).trim(),d=[];for(a++;a<e.length&&!e[a].startsWith(r);)d.push(e[a]),a++;a++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],c=s.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&r.push(c),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const u=e[a].replace("</think>","").trim();u&&r.push(u),a++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Nn(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${Nn(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${Nn(i.join(`
`))}</p>`)}return n}function Nn(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const ql=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],ba=f([]),ie=f(!1),xa=f(null),oe=f("");function Gl(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Jl=f(Gl()),re=f(!1);async function Ci(t){xa.value=t,ie.value=!0;try{const e=await Wo(t);if(xa.value!==t)return;ba.value=e.comments??[]}catch{}finally{ie.value=!1}}async function ys(t){const e=oe.value.trim();if(e){re.value=!0;try{await Vo(t,Jl.value,e),oe.value="",h("Comment posted","success"),await Ci(t),St()}catch{h("Failed to post comment","error")}finally{re.value=!1}}}function Wl(){const t=ra.value;return o`
    <div class="board-controls">
      ${ql.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{ra.value=e.id,St()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Tn(){var e;const t=(e=wt.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${H} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Ai({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Vl({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await di(t.id,n),St()}catch{h("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>xo(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${Ai} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${H} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function Yl({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${H} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Ql({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${oe.value}
        onInput=${e=>{oe.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&ys(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${re.value}
      />
      <button
        onClick=${()=>ys(t)}
        disabled=${re.value||oe.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${re.value?"...":"Post"}
      </button>
    </div>
  `}function Xl({post:t}){xa.value!==t.id&&!ie.value&&Ci(t.id);const e=async n=>{try{await di(t.id,n),St()}catch{h("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>gn("board")}>← Back to Board</button>
      <${b} title=${o`${t.title} <${Ai} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Kl} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${H} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${b} title="Comments (${ie.value?"...":ba.value.length})">
        ${ie.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Yl} comments=${ba.value} />`}
        <${Ql} postId=${t.id} />
      <//>
    </div>
  `}function Zl(){var s,i;const t=fi.value,e=ca.value,n=ot.value.postId,a=((i=(s=wt.value)==null?void 0:s.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(c=>c.id===n);return r?o`
          <${Tn} />
          <${Xl} post=${r} />
        `:o`
          <div>
            <${Tn} />
            <button class="back-btn" onClick=${()=>gn("board")}>← Back to Board</button>
            <div class="empty-state">
              ${a?"Post not available while board feed is degraded":"Post not found"}
            </div>
          </div>
        `}return o`
    <${Tn} />
    <${Wl} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${a?"No posts loaded (board feed degraded). Check board contract sync.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${Vl} key=${r.id} post=${r} />`)}
          </div>`}
  `}function tc(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function ec(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function bs(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function nc({row:t}){const e=new Date(t.timestamp),n=isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1});return o`
    <div class="term-row">
      <span class="term-time">${n}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-source ${t.source}">${t.source==="message"?"msg":"evt"}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function ac(){const t=mi.value.map(tc),e=Je.value.map(ec),n=[...t,...e].sort((a,s)=>bs(s.timestamp)-bs(a.timestamp)).slice(0,100);return o`
    <div class="section">
      <h2>Live Activity</h2>
      <div class="terminal-feed">
        ${n.length===0?o`<div class="empty-state">Waiting for events...</div>`:n.map(a=>o`<${nc} key=${a.id} row=${a} />`)}
      </div>
    </div>
  `}function Ni({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,i=2*Math.PI*a,r=i*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),o`
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
  `}const sc={born_at:{label:"Born",description:"Keeper 메타가 생성된 시각입니다.",sourcePath:"keepers[].created_at",interpretation:"최근 생성일수록 신규 Keeper입니다."},generation:{label:"Generation",description:"승계/핸드오프를 거치며 누적된 세대 번호입니다.",sourcePath:"keepers[].generation",interpretation:"값이 높을수록 세대 전환을 더 많이 경험했습니다."},status:{label:"Status",description:"현재 실행 상태입니다.",sourcePath:"keepers[].status",interpretation:"active/idle은 동작 중, offline/inactive는 비활성 상태입니다."},recent_activity:{label:"Recent",description:"가장 최근 변화/행동 요약입니다.",sourcePath:"keepers[].last_drift_reason | keepers[].last_proactive_reason | keepers[].memory_recent_note",formula:"first_non_null(last_drift_reason, last_proactive_reason, memory_recent_note)",interpretation:"최근 어떤 일을 했는지 한 줄로 파악합니다."},relations:{label:"Relations",description:"다른 Keeper와의 최근 상호작용 빈도입니다.",sourcePath:"keepers[].k2k_count, keepers[].k2k_mentions",formula:"k2k_count + top(k2k_mentions)",interpretation:"값이 높을수록 협업/호출이 잦습니다."},personality_change:{label:"Personality Change",description:"성향 변화 추세를 드리프트 지표로 요약한 값입니다.",sourcePath:"keepers[].drift_count_total, keepers[].metrics_window.goal_drift_avg",formula:"drift_count_total + goal_drift_avg",interpretation:"높을수록 최근 성향/목표 정렬 변화가 컸습니다."}};function ic(t){return sc[t]}function Tt({metric:t}){const e=ic(t);return o`
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
  `}function oc({agent:t}){return o`
    <button class="agent-card ${t.status}" onClick=${()=>bi(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${Ni} ratio=${t.context_ratio} />
        <${at} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function rc(t){return typeof t!="number"||Number.isNaN(t)?null:`${Math.round(t*100)}%`}function lc(t){var s,i,r;const e=(s=t.last_drift_reason)==null?void 0:s.trim();if(e)return e;const n=(i=t.last_proactive_reason)==null?void 0:i.trim();if(n)return n;const a=(r=t.memory_recent_note)==null?void 0:r.trim();return a||"—"}function cc(t){var a;const e=t.k2k_count??0,n=(a=t.k2k_mentions)==null?void 0:a[0];return n?`${e} · ${n.keeper}(${n.count})`:String(e)}function uc(t){var a;const e=t.drift_count_total??0,n=rc((a=t.metrics_window)==null?void 0:a.goal_drift_avg);return e===0&&!n?"Stable":n?`Drift ${e} · Δ${n}`:`Drift ${e}`}function dc({keeper:t}){var s;const e=lc(t),n=cc(t),a=uc(t);return o`
    <div class="live-agent keeper-card" onClick=${()=>yi(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${Ni} ratio=${t.context_ratio} />
        <${at} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Born <${Tt} metric="born_at" /></span>
            <strong class="keeper-core-value">
              ${t.created_at?o`<${H} timestamp=${t.created_at} />`:"—"}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Gen <${Tt} metric="generation" /></span>
            <strong class="keeper-core-value">${t.generation??"—"}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Status <${Tt} metric="status" /></span>
            <strong class="keeper-core-value">${t.status}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Relations <${Tt} metric="relations" /></span>
            <strong class="keeper-core-value">${n}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Recent <${Tt} metric="recent_activity" /></span>
            <strong class="keeper-core-value keeper-core-text">${e}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Personality <${Tt} metric="personality_change" /></span>
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
  `}function pc(){const t=Kt.value,e=Bt.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${dc} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${oc} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Rn({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${H} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function vc(){const{todo:t,inProgress:e,done:n}=Ma.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>o`<${Rn} key=${a.id} task=${a} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>o`<${Rn} key=${a.id} task=${a} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>o`<${Rn} key=${a.id} task=${a} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function mc(t){return t==null?"P3":t<=1?"P1":t===2?"P2":t>=4?"P4+":"P3"}function In({task:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.title}</div>
        <div class="council-sub">
          <span>${mc(t.priority)}</span>
          ${t.assignee?o`<span>Assignee: ${t.assignee}</span>`:o`<span>Unassigned</span>`}
          ${t.created_at?o`<span><${H} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </div>
  `}function fc(){const t=Ma.value,e=t.inProgress,n=t.todo,a=t.done,s=gi.value,i=n.filter(c=>(c.priority??3)<=2),r=n.filter(c=>!c.assignee);return o`
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
      <${b} title="Execution Queue" class="section">
        <div class="council-list">
          ${e.length===0?o`<div class="empty-state">No active execution tasks</div>`:e.slice(0,20).map(c=>o`<${In} key=${c.id} task=${c} />`)}
        </div>
      <//>

      <${b} title="Ready Queue" class="section">
        <div class="council-list">
          ${n.length===0?o`<div class="empty-state">No ready tasks</div>`:n.slice(0,20).map(c=>o`<${In} key=${c.id} task=${c} />`)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${b} title="Assignee Coverage" class="section">
        <div class="council-list">
          ${s.length===0?o`<div class="empty-state">No active agents</div>`:s.map(c=>o`
                <div class="council-row session">
                  <div class="council-row-main">
                    <div class="council-topic">${c.name}</div>
                    <div class="council-sub">
                      ${c.current_task?o`<span>${c.current_task}</span>`:o`<span>Idle</span>`}
                    </div>
                  </div>
                  <${at} status=${c.status} />
                </div>
              `)}
        </div>
      <//>

      <${b} title="Attention Needed" class="section">
        <div class="council-list">
          ${r.length===0?o`<div class="empty-state">No unassigned tasks</div>`:r.slice(0,20).map(c=>o`<${In} key=${c.id} task=${c} />`)}
        </div>
      <//>
    </div>
  `}function _c(t){const e=t.text;return e==="Joined"?{label:"agent_joined",color:"#4ade80"}:e==="Left"?{label:"agent_left",color:"#ef4444"}:e.startsWith("Task:")?{label:"task_update",color:"#fbbf24"}:e.startsWith("Heartbeat")?{label:"keeper_heartbeat",color:"#22d3ee"}:e.startsWith("Handoff")?{label:"keeper_handoff",color:"#a78bfa"}:e.startsWith("Compaction")?{label:"keeper_compaction",color:"#a78bfa"}:e.startsWith("Guardrail")?{label:"keeper_guardrail",color:"#fb7185"}:{label:"event",color:"#94a3b8"}}function gc({entry:t}){const e={event:"#94a3b8"},n=_c(t),a=e[n.label]??n.color,s=t.text,i=new Date(t.timestamp),r=Number.isNaN(i.getTime())?"00:00:00":i.toLocaleTimeString("en-US",{hour12:!1});return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${a}" title=${r}>${n.label}</span>
      <span class="journal-agent">${t.agent||"system"}</span>
      <span class="journal-data">${s}</span>
    </div>
  `}function $c(){const t=Je.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${gc} key=${n} entry=${e} />`)}
      </div>
    </div>
  `}const cn=f("all"),un=f("all"),Ti=nt(()=>{let t=$n.value;return cn.value!=="all"&&(t=t.filter(e=>e.horizon===cn.value)),un.value!=="all"&&(t=t.filter(e=>e.status===un.value)),t}),hc=nt(()=>{const t={short:[],mid:[],long:[]};for(const e of Ti.value){const n=t[e.horizon];n&&n.push(e)}return t});function yc(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function ja(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function Ue(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function bc({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Ue(t.horizon)}">
            ${ja(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${yc(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${H} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${at} status=${t.status} />
        <div class="goal-updated">
          <${H} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Ln({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return o`
    <${b} title="${ja(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>o`<${bc} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function xc(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${cn.value===t?"active":""}"
            onClick=${()=>{cn.value=t}}
          >
            ${t==="all"?"All":ja(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${un.value===t?"active":""}"
            onClick=${()=>{un.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function kc(){const t=$n.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${Ue("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Ue("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Ue("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function wc(){gt(()=>{Ve()},[]);const t=hc.value;return o`
    <div>
      <${b} title="Goals Overview" class="section">
        <${kc} />
        <${xc} />
        <div style="margin-top:8px;">
          <button class="control-btn ghost" onClick=${Ve} disabled=${Yt.value}>
            ${Yt.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      <//>

      ${Yt.value&&$n.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:Ti.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
            <${Ln} horizon="short" items=${t.short??[]} />
            <${Ln} horizon="mid" items=${t.mid??[]} />
            <${Ln} horizon="long" items=${t.long??[]} />
          `}
    </div>
  `}const Lt=f(""),Pn=f("ability_check"),Dn=f("10"),Mn=f("12"),Le=f(""),Pe=f("idle"),vt=f(""),De=f("keeper-late"),En=f("player"),On=f(""),W=f("idle"),jn=f(null),Me=f(""),zn=f(""),Fn=f("player"),Un=f(""),Hn=f(""),Kn=f(""),le=f("20"),Bn=f("20"),qn=f(""),Ee=f("idle"),ka=f(null),Ri=f("overview"),Gn=f("all"),Jn=f("all"),Wn=f("all"),Sc=12e4,bn=f(null),xs=f(Date.now());function Cc(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Ac(t,e){return e>0?Math.round(t/e*100):0}const Nc={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Tc={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Oe(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Rc(t){const e=t.trim().toLowerCase();return Nc[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Ic(t){const e=t.trim().toLowerCase();return Tc[e]??"상황에 따라 선택되는 전술 액션입니다."}function _t(t){return typeof t=="object"&&t!==null}function q(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function st(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function he(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const Lc=new Set(["str","dex","con","int","wis","cha"]);function Pc(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!_t(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,i])=>{const r=s.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){a[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){a[r]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function Dc(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(le.value.trim(),10);Number.isFinite(a)&&a>n&&(le.value=String(n))}function wa(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Mc(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Ec(t){Ri.value=t}function Ii(t){const e=bn.value;return e==null||e<=t}function Oc(t){const e=bn.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function dn(){bn.value=null}function Li(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function jc(t,e){Li(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(bn.value=Date.now()+Sc,h("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function He(t){return Ii(t)?(h("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Sa(t,e,n){return Li([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function zc({hp:t,max:e}){const n=Ac(t,e),a=Cc(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Fc({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Uc({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Pi({actor:t}){var d,u,v,l;const e=(d=t.archetype)==null?void 0:d.trim(),n=(u=t.persona)==null?void 0:u.trim(),a=(v=t.portrait)==null?void 0:v.trim(),s=(l=t.background)==null?void 0:l.trim(),i=t.traits??[],r=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([p,m])=>Number.isFinite(m)).filter(([p])=>!Lc.has(p.toLowerCase()));return o`
    <div class="trpg-actor">
      ${a?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${a}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${p=>{const m=p.target;m&&(m.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${at} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Uc} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${zc} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Fc} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Oe(e)}</div>`:null}
      ${s?o`<div class="trpg-actor-meta">Background: ${s}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([p,m])=>o`
                <span class="trpg-custom-stat-chip">${Oe(p)} ${m}</span>
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
                  <span class="trpg-annot-name">${Oe(p)}</span>
                  <span class="trpg-annot-desc">${Rc(p)}</span>
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
                  <span class="trpg-annot-name">${Oe(p)}</span>
                  <span class="trpg-annot-desc">${Ic(p)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Hc({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Di({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return o`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Mc(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${wa(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${H} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Kc({events:t}){const e="__none__",n=Gn.value,a=Jn.value,s=Wn.value,i=Array.from(new Set(t.map(wa).map(l=>l.trim()).filter(l=>l!==""))).sort((l,p)=>l.localeCompare(p)),r=Array.from(new Set(t.map(l=>(l.type??"").trim()).filter(l=>l!==""))).sort((l,p)=>l.localeCompare(p)),c=t.some(l=>(l.type??"").trim()===""),d=Array.from(new Set(t.map(l=>(l.phase??"").trim()).filter(l=>l!==""))).sort((l,p)=>l.localeCompare(p)),u=t.some(l=>(l.phase??"").trim()===""),v=t.filter(l=>{if(n!=="all"&&wa(l)!==n)return!1;const p=(l.type??"").trim(),m=(l.phase??"").trim();if(a===e){if(p!=="")return!1}else if(a!=="all"&&p!==a)return!1;if(s===e){if(m!=="")return!1}else if(s!=="all"&&m!==s)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${l=>{Gn.value=l.target.value}}>
          <option value="all">all</option>
          ${i.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${l=>{Jn.value=l.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${e}>(none)</option>`:null}
          ${r.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${l=>{Wn.value=l.target.value}}>
          <option value="all">all</option>
          ${u?o`<option value=${e}>(none)</option>`:null}
          ${d.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Gn.value="all",Jn.value="all",Wn.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${v.length} / 전체 ${t.length}
      </span>
    </div>
    <${Di} events=${v.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Bc({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function Mi({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function qc({state:t,nowMs:e}){var u;const n=ct.value||((u=t.session)==null?void 0:u.room)||"",a=Pe.value,s=t.party??[];if(!s.find(v=>v.id===Lt.value)&&s.length>0){const v=s[0];v&&(Lt.value=v.id)}const r=async()=>{var l,p;if(!n){h("Room ID가 비어 있습니다.","error");return}if(!He(e))return;const v=((l=t.current_round)==null?void 0:l.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(Sa("라운드 실행",n,v)){Pe.value="running";try{const m=await ur(n);ka.value=m,Pe.value="ok";const g=_t(m.summary)?m.summary:null,x=g?he(g,"advanced",!1):!1,A=g?q(g,"progress_reason",""):"";h(x?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${A?`: ${A}`:""}`,x?"success":"warning"),ut()}catch(m){ka.value=null,Pe.value="error";const g=m instanceof Error?m.message:"라운드 실행에 실패했습니다.";h(g,"error")}finally{dn()}}},c=async()=>{var l,p;if(!n||!He(e))return;const v=((l=t.current_round)==null?void 0:l.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(Sa("턴 강제 진행",n,v))try{await vr(n),h("턴을 다음 단계로 이동했습니다.","success"),ut()}catch{h("턴 이동에 실패했습니다.","error")}finally{dn()}},d=async()=>{if(!n||!He(e))return;const v=Lt.value.trim();if(!v){h("먼저 Actor를 선택하세요.","warning");return}const l=Number.parseInt(Dn.value,10),p=Number.parseInt(Mn.value,10);if(Number.isNaN(l)||Number.isNaN(p)){h("stat/dc는 숫자여야 합니다.","warning");return}const m=Number.parseInt(Le.value,10),g=Le.value.trim()===""||Number.isNaN(m)?void 0:m;try{await pr({roomId:n,actorId:v,action:Pn.value.trim()||"ability_check",statValue:l,dc:p,rawD20:g}),h("주사위 판정을 기록했습니다.","success"),ut()}catch{h("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${v=>{ct.value=v.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Lt.value}
            onChange=${v=>{Lt.value=v.target.value}}
          >
            <option value="">Actor 선택</option>
            ${s.map(v=>o`<option value=${v.id}>${v.name} (${v.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Pn.value}
              onInput=${v=>{Pn.value=v.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Dn.value}
              onInput=${v=>{Dn.value=v.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Mn.value}
              onInput=${v=>{Mn.value=v.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Le.value}
              onInput=${v=>{Le.value=v.target.value}}
              onKeyDown=${v=>{v.key==="Enter"&&d()}}
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
            <button class="trpg-run-btn secondary" onClick=${c}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${a!=="idle"?o`<div class="trpg-run-status ${a}">${a==="running"?"처리 중...":a==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function Gc({state:t}){var s;const e=ct.value||((s=t.session)==null?void 0:s.room)||"",n=Ee.value,a=async()=>{if(!e){h("Room ID가 비어 있습니다.","warning");return}const i=Me.value.trim(),r=zn.value.trim();if(!r&&!i){h("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(le.value.trim(),10),d=Number.parseInt(Bn.value.trim(),10),u=Number.isFinite(d)?Math.max(1,d):20,v=Number.isFinite(c)?Math.max(0,Math.min(u,c)):u;let l={};try{l=Pc(qn.value)}catch(p){h(p instanceof Error?p.message:"능력치 JSON 오류","error");return}Ee.value="spawning";try{const p=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,m=await mr(e,{actor_id:i||void 0,name:r||void 0,role:Fn.value,idempotencyKey:p,portrait:Hn.value.trim()||void 0,background:Kn.value.trim()||void 0,hp:v,max_hp:u,alive:v>0,stats:Object.keys(l).length>0?l:void 0}),g=typeof m.actor_id=="string"?m.actor_id.trim():"";if(!g)throw new Error("생성 응답에 actor_id가 없습니다.");const x=Un.value.trim();x&&await fr(e,g,x),Lt.value=g,vt.value=g,i||(Me.value=""),Ee.value="ok",h(`Actor 생성 완료: ${g}`,"success"),await ut()}catch(p){Ee.value="error",h(p instanceof Error?p.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${zn.value}
            onInput=${i=>{zn.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Fn.value}
            onChange=${i=>{Fn.value=i.target.value}}
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
            value=${Un.value}
            onInput=${i=>{Un.value=i.target.value}}
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
              value=${Me.value}
              onInput=${i=>{Me.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Hn.value}
              onInput=${i=>{Hn.value=i.target.value}}
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
              value=${le.value}
              onInput=${i=>{le.value=i.target.value}}
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
              value=${Bn.value}
              onInput=${i=>{const r=i.target.value;Bn.value=r,Dc(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Kn.value}
              onInput=${i=>{Kn.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${qn.value}
              onInput=${i=>{qn.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Jc({state:t,nowMs:e}){var p;const n=ct.value||((p=t.session)==null?void 0:p.room)||"",a=t.join_gate,s=jn.value,i=_t(s)?s:null,r=(t.party??[]).filter(m=>m.role!=="dm"),c=vt.value.trim(),d=r.some(m=>m.id===c),u=d?c:c?"__manual__":"",v=async()=>{const m=vt.value.trim(),g=De.value.trim();if(!n||!m){h("Room/Actor가 필요합니다.","warning");return}W.value="checking";try{const x=await _r(n,m,g||void 0);jn.value=x,W.value="ok",h("참가 가능 여부를 갱신했습니다.","success")}catch(x){W.value="error";const A=x instanceof Error?x.message:"참가 가능 여부 확인에 실패했습니다.";h(A,"error")}},l=async()=>{var T,N;const m=vt.value.trim(),g=De.value.trim(),x=On.value.trim();if(!n||!m||!g){h("Room/Actor/Keeper가 필요합니다.","warning");return}if(!He(e))return;const A=((T=t.current_round)==null?void 0:T.phase)??((N=t.session)==null?void 0:N.status)??"unknown";if(Sa("Mid-Join 승인 요청",n,A)){W.value="requesting";try{const E=await gr({room_id:n,actor_id:m,keeper_name:g,role:En.value,...x?{name:x}:{}});jn.value=E;const U=_t(E)?he(E,"granted",!1):!1,P=_t(E)?q(E,"reason_code",""):"";U?h("Mid-Join이 승인되었습니다.","success"):h(`Mid-Join이 거절되었습니다${P?`: ${P}`:""}`,"warning"),W.value=U?"ok":"error",ut()}catch(E){W.value="error";const U=E instanceof Error?E.message:"Mid-Join 요청에 실패했습니다.";h(U,"error")}finally{dn()}}};return o`
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
            value=${u}
            onChange=${m=>{const g=m.target.value;if(g==="__manual__"){(d||!c)&&(vt.value="");return}vt.value=g}}
          >
            <option value="">Actor 선택</option>
            ${r.map(m=>o`
              <option value=${m.id}>${m.name} (${m.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${u==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${vt.value}
                onInput=${m=>{vt.value=m.target.value}}
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
            value=${De.value}
            onInput=${m=>{De.value=m.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${En.value}
            onChange=${m=>{En.value=m.target.value}}
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
            value=${On.value}
            onInput=${m=>{On.value=m.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${v} disabled=${W.value==="checking"||W.value==="requesting"}>
              ${W.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${l} disabled=${W.value==="checking"||W.value==="requesting"}>
              ${W.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${he(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${st(i,"effective_score",0)}/${st(i,"required_points",0)}</span>
            ${q(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${q(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Ei({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Oi({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function ji(){const t=ka.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=_t(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(_t).slice(-8),i=t.canon_check,r=_t(i)?i:null,c=r&&Array.isArray(r.warnings)?r.warnings.filter(P=>typeof P=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(P=>typeof P=="string").slice(0,3):[],u=n?he(n,"advanced",!1):!1,v=n?q(n,"progress_reason",""):"",l=n?q(n,"progress_detail",""):"",p=n?st(n,"player_successes",0):0,m=n?st(n,"player_required_successes",0):0,g=n?he(n,"dm_success",!1):!1,x=n?st(n,"timeouts",0):0,A=n?st(n,"unavailable",0):0,T=n?st(n,"reprompts",0):0,N=n?st(n,"npc_attacks",0):0,E=n?st(n,"keeper_timeout_sec",0):0,U=n?st(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${u?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${u?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${g?"DM ok":"DM stalled"} / players ${p}/${m}
          </span>
        </div>
        ${v?o`<div style="margin-top:4px; font-size:12px;">${v}</div>`:null}
        ${l?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${l}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${N}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${E||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${U}</div></div>
      </div>

      ${s.length>0?o`
          <div class="trpg-round-list">
            ${s.map(P=>{const V=q(P,"status","unknown"),ht=q(P,"actor_id","-"),yt=q(P,"role","-"),Y=q(P,"reason",""),rt=q(P,"action_type",""),I=q(P,"reply","");return o`
                <div class="trpg-round-item ${V.includes("fallback")||V.includes("timeout")?"failed":"active"}">
                  <span>${ht} (${yt})</span>
                  <span style="margin-left:auto; font-size:11px;">${V}</span>
                  ${rt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${rt}</div>`:null}
                  ${Y?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${Y}</div>`:null}
                  ${I?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${I.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${q(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(P=>o`<div>violation: ${P}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(P=>o`<div>warning: ${P}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Wc({state:t,nowMs:e}){var r,c,d;const n=ct.value||((r=t.session)==null?void 0:r.room)||"",a=((c=t.current_round)==null?void 0:c.phase)??((d=t.session)==null?void 0:d.status)??"unknown",s=Ii(e),i=Oc(e);return o`
    <${b} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${s?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${s?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${s?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${s?o`<button class="trpg-run-btn recommend" onClick=${()=>jc(n,a)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{dn(),h("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Vc({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Ec(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Yc({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${b} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${b} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Di} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${b} title="맵" style="margin-top:16px;">
              <${Hc} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${b} title="현재 라운드">
          <${Oi} state=${t} />
        <//>

        <${b} title="기여도" style="margin-top:16px;">
          <${Ei} state=${t} />
        <//>

        <${b} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>o`<${Pi} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${b} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Mi} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Qc({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${b} title=${`이벤트 타임라인 (${e.length})`}>
          <${Kc} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${b} title="최근 라운드 결과">
          <${ji} />
        <//>

        <${b} title="현재 라운드" style="margin-top:16px;">
          <${Oi} state=${t} />
        <//>
      </div>
    </div>
  `}function Xc({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${Wc} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${b} title="조작 패널">
            <${qc} state=${t} nowMs=${e} />
          <//>

          <${b} title="Actor Spawn" style="margin-top:16px;">
            <${Gc} state=${t} />
          <//>

          <${b} title="Mid-Join Gate" style="margin-top:16px;">
            <${Jc} state=${t} nowMs=${e} />
          <//>

          <${b} title="최근 라운드 결과" style="margin-top:16px;">
            <${ji} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${b} title="기여도" style="margin-top:0;">
            <${Ei} state=${t} />
          <//>

          <${b} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>o`<${Pi} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${b} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Mi} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Zc(){var c,d,u,v,l;const t=_i.value,e=ua.value;if(gt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const p=window.setInterval(()=>{xs.value=Date.now()},1e3);return()=>{window.clearInterval(p)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>ut()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,i=Ri.value,r=xs.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${ct.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((u=t.session)==null?void 0:u.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>ut()}>새로고침</button>
      </div>

      <${Bc} outcome=${s} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((v=t.session)==null?void 0:v.status)??"active"}</div>
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

      <${Vc} active=${i} />

      ${i==="overview"?o`<${Yc} state=${t} />`:i==="timeline"?o`<${Qc} state=${t} />`:o`<${Xc} state=${t} nowMs=${r} />`}
    </div>
  `}const tu=nt(()=>{const t=Array.from(Z.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t}),eu=nt(()=>Array.from(Z.value.values()).filter(t=>t.status==="running").length),nu=nt(()=>Array.from(Z.value.values()).filter(t=>t.status==="completed").length);function Vn(t){switch(t){case"running":return"#fbbf24";case"completed":return"#4ade80";case"stopped":return"#94a3b8";case"error":return"#fb7185";default:return"#888"}}function zi(t){return`${t>=0?"+":""}${t.toFixed(4)}`}function au(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function su({history:t}){if(t.length===0)return o`<span class="mdal-spark-empty">No iterations yet</span>`;const n=[...t].reverse().map(d=>d.metric_after),a=Math.min(...n),i=Math.max(...n)-a||1,r="▁▂▃▄▅▆▇█",c=n.map(d=>{const u=Math.min(Math.floor((d-a)/i*7),7);return r[u]}).join("");return o`
    <span class="mdal-spark" title="Metric progression (${n.length} iterations)">
      ${c}
    </span>
  `}function iu({record:t}){const e=t.delta>0?"positive":t.delta<0?"negative":"neutral";return o`
    <div class="mdal-iter-row">
      <span class="mdal-iter-num">#${t.iteration}</span>
      <span class="mdal-iter-metric">${t.metric_before.toFixed(4)}</span>
      <span class="mdal-iter-arrow">\u2192</span>
      <span class="mdal-iter-metric">${t.metric_after.toFixed(4)}</span>
      <span class="mdal-iter-delta ${e}">${zi(t.delta)}</span>
      <span class="mdal-iter-time">${t.elapsed_ms}ms</span>
    </div>
  `}function ou({loop:t}){const e=t.current_metric-t.baseline_metric;return o`
    <${b} title=${`${t.loop_id}`} class="mdal-loop-card">
      <div class="mdal-loop-header">
        <div class="mdal-loop-badges">
          <${at} status=${t.status} />
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
            ${zi(e)}
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
          <span class="mdal-metric-value">${au(t.elapsed_seconds)}</span>
        </div>
      </div>

      <div class="mdal-spark-section">
        <span class="mdal-metric-label">Progress</span>
        <${su} history=${t.history} />
      </div>

      ${t.history.length>0?o`
        <details class="mdal-history-details">
          <summary>Iteration History (${t.history.length})</summary>
          <div class="mdal-iter-list">
            ${t.history.map(n=>o`<${iu} key=${n.iteration} record=${n} />`)}
          </div>
        </details>
      `:null}
    <//>
  `}function ru(){const t=tu.value,e=eu.value,n=nu.value,a=t.filter(s=>s.status==="stopped").length;return o`
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
        <div class="stat-value" style="color:${Vn("running")}">${e}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Completed</div>
        <div class="stat-value" style="color:${Vn("completed")}">${n}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Stopped</div>
        <div class="stat-value" style="color:${Vn("stopped")}">${a}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Total Loops</div>
        <div class="stat-value">${t.length}</div>
      </div>
    </div>

    <div class="council-grid">
      ${t.length===0?o`
          <${b} title="MDAL Loops" class="section">
            <div class="empty-state">
              No MDAL loops active. Start one with <code>masc_mdal_start</code>.
            </div>
          <//>
        `:t.map(s=>o`<${ou} key=${s.loop_id} loop=${s} />`)}
    </div>
  `}const za="masc_dashboard_agent_name";function lu(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(za);return e??n??"dashboard"}const et=f(lu()),ce=f(""),ue=f(""),pn=f(""),de=f(!1),Pt=f(!1),pe=f(!1),ve=f(!1),vn=f(!1),xn=f(!1);function Fa(t){const e=t.trim();et.value=e,e&&localStorage.setItem(za,e)}function cu(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Ca(){const t=et.value.trim();if(t){pe.value=!0;try{const e=await hr(t),n=cu(e);n&&Fa(n),xn.value=!0,h(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";h(n,"error")}finally{pe.value=!1}}}async function uu(){const t=et.value.trim();if(t){ve.value=!0;try{await vi(t),xn.value=!1,h(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";h(n,"error")}finally{ve.value=!1}}}async function du(){const t=et.value.trim();if(t)try{await vi(t)}catch{}localStorage.removeItem(za),Fa("dashboard"),xn.value=!1,await Ca()}async function pu(){const t=et.value.trim();if(t){vn.value=!0;try{await yr(t),h("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";h(n,"error")}finally{vn.value=!1}}}async function ks(){const t=et.value.trim(),e=ce.value.trim();if(!(!t||!e)){de.value=!0;try{await pi(t,e),ce.value="",h("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";h(a,"error")}finally{de.value=!1}}}async function vu(){const t=ue.value.trim(),e=pn.value.trim()||"Created from dashboard";if(t){Pt.value=!0;try{await $r(t,e,1),ue.value="",pn.value="",h("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";h(a,"error")}finally{Pt.value=!1}}}function mu(){return gt(()=>{Ca()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${et.value}
        onInput=${t=>Fa(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${ce.value}
          onInput=${t=>{ce.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&ks()}}
          disabled=${de.value}
        />
        <button
          class="control-btn"
          onClick=${ks}
          disabled=${de.value||ce.value.trim()===""||et.value.trim()===""}
        >
          ${de.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Ca()}}
          disabled=${pe.value||et.value.trim()===""}
        >
          ${pe.value?"Joining...":xn.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{uu()}}
          disabled=${ve.value||et.value.trim()===""}
        >
          ${ve.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{du()}}
          disabled=${pe.value||ve.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{pu()}}
          disabled=${vn.value||et.value.trim()===""}
        >
          ${vn.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${ue.value}
        onInput=${t=>{ue.value=t.target.value}}
        disabled=${Pt.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${pn.value}
        onInput=${t=>{pn.value=t.target.value}}
        disabled=${Pt.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${vu}
        disabled=${Pt.value||ue.value.trim()===""}
      >
        ${Pt.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function fu(){const t=jt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Pa.value} events</span>
    </div>
  `}function _u(){const t=ot.value.tab,e=jt.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${ni.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>gn(n.id)}
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
            <strong>${Kt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${Bt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${we.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${Pa.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{hn(),t==="ops"&&Ft(),t==="board"&&St(),t==="trpg"&&ut(),t==="goals"&&Ve(),t==="mdal"&&hi()}}
        >
          Refresh Now
        </button>
      </section>

      <${mu} />
    </aside>
  `}function gu(){switch(ot.value.tab){case"overview":return o`<${ps} />`;case"ops":return o`<${Ol} />`;case"council":return o`<${Hl} />`;case"board":return o`<${Zl} />`;case"execution":return o`<${fc} />`;case"activity":return o`<${ac} />`;case"agents":return o`<${pc} />`;case"tasks":return o`<${vc} />`;case"goals":return o`<${wc} />`;case"journal":return o`<${$c} />`;case"trpg":return o`<${Zc} />`;case"mdal":return o`<${ru} />`;default:return o`<${ps} />`}}function $u(){return gt(()=>{ko(),ii(),hn();const t=Kr();return Br(),()=>{Io(),t(),qr()}},[]),gt(()=>{const t=ot.value.tab;t==="ops"&&Ft(),t==="board"&&St(),t==="trpg"&&ut(),t==="goals"&&Ve(),t==="mdal"&&hi()},[ot.value.tab]),o`
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
          <${fu} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${wo} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${la.value&&!jt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${gu} />`}
        </main>
        <${_u} />
      </div>

      <${al} />
      <${dl} />
      <${ol} />
    </div>
  `}const ws=document.getElementById("app");ws&&io(o`<${$u} />`,ws);
