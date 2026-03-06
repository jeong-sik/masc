var Po=Object.defineProperty;var Mo=(t,e,n)=>e in t?Po(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Ft=(t,e,n)=>Mo(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var Mn,E,ci,ui,Nt,ba,di,pi,vi,ea,ys,bs,Re={},mi=[],Oo=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,On=Array.isArray;function pt(t,e){for(var n in e)t[n]=e[n];return t}function na(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function fi(t,e,n){var s,a,i,r={};for(i in e)i=="key"?s=e[i]:i=="ref"?a=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Mn.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return on(t,r,s,a,null)}function on(t,e,n,s,a){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++ci,__i:-1,__u:0};return a==null&&E.vnode!=null&&E.vnode(i),i}function Fe(t){return t.children}function ce(t,e){this.props=t,this.context=e}function Qt(t,e){if(e==null)return t.__?Qt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?Qt(t):null}function _i(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return _i(t)}}function ka(t){(!t.__d&&(t.__d=!0)&&Nt.push(t)&&!mn.__r++||ba!=E.debounceRendering)&&((ba=E.debounceRendering)||di)(mn)}function mn(){for(var t,e,n,s,a,i,r,l=1;Nt.length;)Nt.length>l&&Nt.sort(pi),t=Nt.shift(),l=Nt.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,i=[],r=[],e.__P&&((n=pt({},s)).__v=s.__v+1,E.vnode&&E.vnode(n),sa(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,i,a??Qt(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,hi(i,n,r),s.__e=s.__=null,n.__e!=a&&_i(n)));mn.__r=0}function gi(t,e,n,s,a,i,r,l,d,c,v){var u,p,m,g,k,N,L,A=s&&s.__k||mi,P=e.length;for(d=jo(n,e,A,d,P),u=0;u<P;u++)(m=n.__k[u])!=null&&(p=m.__i==-1?Re:A[m.__i]||Re,m.__i=u,N=sa(t,m,p,a,i,r,l,d,c,v),g=m.__e,m.ref&&p.ref!=m.ref&&(p.ref&&aa(p.ref,null,m),v.push(m.ref,m.__c||g,m)),k==null&&g!=null&&(k=g),(L=!!(4&m.__u))||p.__k===m.__k?d=$i(m,d,t,L):typeof m.type=="function"&&N!==void 0?d=N:g&&(d=g.nextSibling),m.__u&=-7);return n.__e=k,d}function jo(t,e,n,s,a){var i,r,l,d,c,v=n.length,u=v,p=0;for(t.__k=new Array(a),i=0;i<a;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=on(null,r,null,null,null):On(r)?r=t.__k[i]=on(Fe,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=on(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+p,r.__=t,r.__b=t.__b+1,l=null,(c=r.__i=Fo(r,n,d,u))!=-1&&(u--,(l=n[c])&&(l.__u|=2)),l==null||l.__v==null?(c==-1&&(a>v?p--:a<v&&p++),typeof r.type!="function"&&(r.__u|=4)):c!=d&&(c==d-1?p--:c==d+1?p++:(c>d?p--:p++,r.__u|=4))):t.__k[i]=null;if(u)for(i=0;i<v;i++)(l=n[i])!=null&&(2&l.__u)==0&&(l.__e==s&&(s=Qt(l)),bi(l,l));return s}function $i(t,e,n,s){var a,i;if(typeof t.type=="function"){for(a=t.__k,i=0;a&&i<a.length;i++)a[i]&&(a[i].__=t,e=$i(a[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=Qt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Fo(t,e,n,s){var a,i,r,l=t.key,d=t.type,c=e[n],v=c!=null&&(2&c.__u)==0;if(c===null&&l==null||v&&l==c.key&&d==c.type)return n;if(s>(v?1:0)){for(a=n-1,i=n+1;a>=0||i<e.length;)if((c=e[r=a>=0?a--:i++])!=null&&(2&c.__u)==0&&l==c.key&&d==c.type)return r}return-1}function xa(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Oo.test(e)?n:n+"px"}function We(t,e,n,s,a){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||xa(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||xa(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(vi,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=ea,t.addEventListener(e,i?bs:ys,i)):t.removeEventListener(e,i?bs:ys,i);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function wa(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=ea++;else if(e.t<n.u)return;return n(E.event?E.event(e):e)}}}function sa(t,e,n,s,a,i,r,l,d,c){var v,u,p,m,g,k,N,L,A,P,x,R,Q,At,Ct,X,dt,D=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[l=e.__e=n.__e]),(v=E.__b)&&v(e);t:if(typeof D=="function")try{if(L=e.props,A="prototype"in D&&D.prototype.render,P=(v=D.contextType)&&s[v.__c],x=v?P?P.props.value:v.__:s,n.__c?N=(u=e.__c=n.__c).__=u.__E:(A?e.__c=u=new D(L,x):(e.__c=u=new ce(L,x),u.constructor=D,u.render=Ho),P&&P.sub(u),u.state||(u.state={}),u.__n=s,p=u.__d=!0,u.__h=[],u._sb=[]),A&&u.__s==null&&(u.__s=u.state),A&&D.getDerivedStateFromProps!=null&&(u.__s==u.state&&(u.__s=pt({},u.__s)),pt(u.__s,D.getDerivedStateFromProps(L,u.__s))),m=u.props,g=u.state,u.__v=e,p)A&&D.getDerivedStateFromProps==null&&u.componentWillMount!=null&&u.componentWillMount(),A&&u.componentDidMount!=null&&u.__h.push(u.componentDidMount);else{if(A&&D.getDerivedStateFromProps==null&&L!==m&&u.componentWillReceiveProps!=null&&u.componentWillReceiveProps(L,x),e.__v==n.__v||!u.__e&&u.shouldComponentUpdate!=null&&u.shouldComponentUpdate(L,u.__s,x)===!1){for(e.__v!=n.__v&&(u.props=L,u.state=u.__s,u.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(H){H&&(H.__=e)}),R=0;R<u._sb.length;R++)u.__h.push(u._sb[R]);u._sb=[],u.__h.length&&r.push(u);break t}u.componentWillUpdate!=null&&u.componentWillUpdate(L,u.__s,x),A&&u.componentDidUpdate!=null&&u.__h.push(function(){u.componentDidUpdate(m,g,k)})}if(u.context=x,u.props=L,u.__P=t,u.__e=!1,Q=E.__r,At=0,A){for(u.state=u.__s,u.__d=!1,Q&&Q(e),v=u.render(u.props,u.state,u.context),Ct=0;Ct<u._sb.length;Ct++)u.__h.push(u._sb[Ct]);u._sb=[]}else do u.__d=!1,Q&&Q(e),v=u.render(u.props,u.state,u.context),u.state=u.__s;while(u.__d&&++At<25);u.state=u.__s,u.getChildContext!=null&&(s=pt(pt({},s),u.getChildContext())),A&&!p&&u.getSnapshotBeforeUpdate!=null&&(k=u.getSnapshotBeforeUpdate(m,g)),X=v,v!=null&&v.type===Fe&&v.key==null&&(X=yi(v.props.children)),l=gi(t,On(X)?X:[X],e,n,s,a,i,r,l,d,c),u.base=e.__e,e.__u&=-161,u.__h.length&&r.push(u),N&&(u.__E=u.__=null)}catch(H){if(e.__v=null,d||i!=null)if(H.then){for(e.__u|=d?160:128;l&&l.nodeType==8&&l.nextSibling;)l=l.nextSibling;i[i.indexOf(l)]=null,e.__e=l}else{for(dt=i.length;dt--;)na(i[dt]);ks(e)}else e.__e=n.__e,e.__k=n.__k,H.then||ks(e);E.__e(H,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):l=e.__e=zo(n.__e,e,n,s,a,i,r,d,c);return(v=E.diffed)&&v(e),128&e.__u?void 0:l}function ks(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(ks)}function hi(t,e,n){for(var s=0;s<n.length;s++)aa(n[s],n[++s],n[++s]);E.__c&&E.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(i){i.call(a)})}catch(i){E.__e(i,a.__v)}})}function yi(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:On(t)?t.map(yi):pt({},t)}function zo(t,e,n,s,a,i,r,l,d){var c,v,u,p,m,g,k,N=n.props||Re,L=e.props,A=e.type;if(A=="svg"?a="http://www.w3.org/2000/svg":A=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),i!=null){for(c=0;c<i.length;c++)if((m=i[c])&&"setAttribute"in m==!!A&&(A?m.localName==A:m.nodeType==3)){t=m,i[c]=null;break}}if(t==null){if(A==null)return document.createTextNode(L);t=document.createElementNS(a,A,L.is&&L),l&&(E.__m&&E.__m(e,i),l=!1),i=null}if(A==null)N===L||l&&t.data==L||(t.data=L);else{if(i=i&&Mn.call(t.childNodes),!l&&i!=null)for(N={},c=0;c<t.attributes.length;c++)N[(m=t.attributes[c]).name]=m.value;for(c in N)if(m=N[c],c!="children"){if(c=="dangerouslySetInnerHTML")u=m;else if(!(c in L)){if(c=="value"&&"defaultValue"in L||c=="checked"&&"defaultChecked"in L)continue;We(t,c,null,m,a)}}for(c in L)m=L[c],c=="children"?p=m:c=="dangerouslySetInnerHTML"?v=m:c=="value"?g=m:c=="checked"?k=m:l&&typeof m!="function"||N[c]===m||We(t,c,m,N[c],a);if(v)l||u&&(v.__html==u.__html||v.__html==t.innerHTML)||(t.innerHTML=v.__html),e.__k=[];else if(u&&(t.innerHTML=""),gi(e.type=="template"?t.content:t,On(p)?p:[p],e,n,s,A=="foreignObject"?"http://www.w3.org/1999/xhtml":a,i,r,i?i[0]:n.__k&&Qt(n,0),l,d),i!=null)for(c=i.length;c--;)na(i[c]);l||(c="value",A=="progress"&&g==null?t.removeAttribute("value"):g!=null&&(g!==t[c]||A=="progress"&&!g||A=="option"&&g!=N[c])&&We(t,c,g,N[c],a),c="checked",k!=null&&k!=t[c]&&We(t,c,k,N[c],a))}return t}function aa(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){E.__e(a,n)}}function bi(t,e,n){var s,a;if(E.unmount&&E.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||aa(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){E.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&bi(s[a],e,n||typeof t.type!="function");n||na(t.__e),t.__c=t.__=t.__e=void 0}function Ho(t,e,n){return this.constructor(t,n)}function Uo(t,e,n){var s,a,i,r;e==document&&(e=document.documentElement),E.__&&E.__(t,e),a=(s=!1)?null:e.__k,i=[],r=[],sa(e,t=e.__k=fi(Fe,null,[t]),a||Re,Re,e.namespaceURI,a?null:e.firstChild?Mn.call(e.childNodes):null,i,a?a.__e:e.firstChild,s,r),hi(i,t,r)}Mn=mi.slice,E={__e:function(t,e,n,s){for(var a,i,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((i=a.constructor)&&i.getDerivedStateFromError!=null&&(a.setState(i.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(l){t=l}throw t}},ci=0,ui=function(t){return t!=null&&t.constructor===void 0},ce.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=pt({},this.state),typeof t=="function"&&(t=t(pt({},n),this.props)),t&&pt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),ka(this))},ce.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),ka(this))},ce.prototype.render=Fe,Nt=[],di=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,pi=function(t,e){return t.__v.__b-e.__v.__b},mn.__r=0,vi=/(PointerCapture)$|Capture$/i,ea=0,ys=wa(!1),bs=wa(!0);var ki=function(t,e,n,s){var a;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],l=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?s[0]=l:r===4?s[1]=Object.assign(s[1]||{},l):r===5?(s[1]=s[1]||{})[e[++i]]=l:r===6?s[1][e[++i]]+=l+"":r?(a=t.apply(l,ki(t,l,n,["",null])),s.push(a),l[0]?e[0]|=2:(e[i-2]=0,e[i]=a)):s.push(l)}return s},Sa=new Map;function Ko(t){var e=Sa.get(this);return e||(e=new Map,Sa.set(this,e)),(e=ki(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,i=1,r="",l="",d=[0],c=function(p){i===1&&(p||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,p,r):i===3&&(p||r)?(d.push(3,p,r),i=2):i===2&&r==="..."&&p?d.push(4,p,0):i===2&&r&&!p?d.push(5,0,!0,r):i>=5&&((r||!p&&i===5)&&(d.push(i,0,r,a),i=6),p&&(d.push(i,p,0,a),i=6)),r=""},v=0;v<n.length;v++){v&&(i===1&&c(),c(v));for(var u=0;u<n[v].length;u++)s=n[v][u],i===1?s==="<"?(c(),d=[d],i=3):r+=s:i===4?r==="--"&&s===">"?(i=1,r=""):r=s+r[0]:l?s===l?l="":r+=s:s==='"'||s==="'"?l=s:s===">"?(c(),i=1):i&&(s==="="?(i=5,a=r,r=""):s==="/"&&(i<5||n[v][u+1]===">")?(c(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(c(),i=2):r+=s),i===3&&r==="!--"&&(i=4,d=d[0])}return c(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Ko.bind(fi),Le,F,qn,Aa,xs=0,xi=[],z=E,Ca=z.__b,Ta=z.__r,Na=z.diffed,Ra=z.__c,La=z.unmount,Ia=z.__;function ia(t,e){z.__h&&z.__h(F,t,xs||e),xs=0;var n=F.__H||(F.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function Ge(t){return xs=1,Bo(Ai,t)}function Bo(t,e,n){var s=ia(Le++,2);if(s.t=t,!s.__c&&(s.__=[Ai(void 0,e),function(l){var d=s.__N?s.__N[0]:s.__[0],c=s.t(d,l);d!==c&&(s.__N=[c,s.__[1]],s.__c.setState({}))}],s.__c=F,!F.__f)){var a=function(l,d,c){if(!s.__c.__H)return!0;var v=s.__c.__H.__.filter(function(p){return!!p.__c});if(v.every(function(p){return!p.__N}))return!i||i.call(this,l,d,c);var u=s.__c.props!==l;return v.forEach(function(p){if(p.__N){var m=p.__[0];p.__=p.__N,p.__N=void 0,m!==p.__[0]&&(u=!0)}}),i&&i.call(this,l,d,c)||u};F.__f=!0;var i=F.shouldComponentUpdate,r=F.componentWillUpdate;F.componentWillUpdate=function(l,d,c){if(this.__e){var v=i;i=void 0,a(l,d,c),i=v}r&&r.call(this,l,d,c)},F.shouldComponentUpdate=a}return s.__N||s.__}function xt(t,e){var n=ia(Le++,3);!z.__s&&Si(n.__H,e)&&(n.__=t,n.u=e,F.__H.__h.push(n))}function wi(t,e){var n=ia(Le++,7);return Si(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function qo(){for(var t;t=xi.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(rn),t.__H.__h.forEach(ws),t.__H.__h=[]}catch(e){t.__H.__h=[],z.__e(e,t.__v)}}z.__b=function(t){F=null,Ca&&Ca(t)},z.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Ia&&Ia(t,e)},z.__r=function(t){Ta&&Ta(t),Le=0;var e=(F=t.__c).__H;e&&(qn===F?(e.__h=[],F.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(rn),e.__h.forEach(ws),e.__h=[],Le=0)),qn=F},z.diffed=function(t){Na&&Na(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(xi.push(e)!==1&&Aa===z.requestAnimationFrame||((Aa=z.requestAnimationFrame)||Wo)(qo)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),qn=F=null},z.__c=function(t,e){e.some(function(n){try{n.__h.forEach(rn),n.__h=n.__h.filter(function(s){return!s.__||ws(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],z.__e(s,n.__v)}}),Ra&&Ra(t,e)},z.unmount=function(t){La&&La(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{rn(s)}catch(a){e=a}}),n.__H=void 0,e&&z.__e(e,n.__v))};var Da=typeof requestAnimationFrame=="function";function Wo(t){var e,n=function(){clearTimeout(s),Da&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);Da&&(e=requestAnimationFrame(n))}function rn(t){var e=F,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),F=e}function ws(t){var e=F;t.__c=t.__(),F=e}function Si(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}function Ai(t,e){return typeof e=="function"?e(t):e}var Go=Symbol.for("preact-signals");function jn(){if(bt>1)bt--;else{for(var t,e=!1;ue!==void 0;){var n=ue;for(ue=void 0,Ss++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&Ni(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(Ss=0,bt--,e)throw t}}function Jo(t){if(bt>0)return t();bt++;try{return t()}finally{jn()}}var I=void 0;function Ci(t){var e=I;I=void 0;try{return t()}finally{I=e}}var ue=void 0,bt=0,Ss=0,fn=0;function Ti(t){if(I!==void 0){var e=t.n;if(e===void 0||e.t!==I)return e={i:0,S:t,p:I.s,n:void 0,t:I,e:void 0,x:void 0,r:e},I.s!==void 0&&(I.s.n=e),I.s=e,t.n=e,32&I.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=I.s,e.n=void 0,I.s.n=e,I.s=e),e}}function U(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}U.prototype.brand=Go;U.prototype.h=function(){return!0};U.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:Ci(function(){var s;(s=e.W)==null||s.call(e)}))};U.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&Ci(function(){var a;(a=e.Z)==null||a.call(e)}))}};U.prototype.subscribe=function(t){var e=this;return ze(function(){var n=e.value,s=I;I=void 0;try{t(n)}finally{I=s}},{name:"sub"})};U.prototype.valueOf=function(){return this.value};U.prototype.toString=function(){return this.value+""};U.prototype.toJSON=function(){return this.value};U.prototype.peek=function(){var t=I;I=void 0;try{return this.value}finally{I=t}};Object.defineProperty(U.prototype,"value",{get:function(){var t=Ti(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Ss>100)throw new Error("Cycle detected");this.v=t,this.i++,fn++,bt++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{jn()}}}});function f(t,e){return new U(t,e)}function Ni(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function Ri(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Li(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function Et(t,e){U.call(this,void 0),this.x=t,this.s=void 0,this.g=fn-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}Et.prototype=new U;Et.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===fn))return!0;if(this.g=fn,this.f|=1,this.i>0&&!Ni(this))return this.f&=-2,!0;var t=I;try{Ri(this),I=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return I=t,Li(this),this.f&=-2,!0};Et.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}U.prototype.S.call(this,t)};Et.prototype.U=function(t){if(this.t!==void 0&&(U.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};Et.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(Et.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Ti(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function J(t,e){return new Et(t,e)}function Ii(t){var e=t.u;if(t.u=void 0,typeof e=="function"){bt++;var n=I;I=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,oa(t),s}finally{I=n,jn()}}}function oa(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,Ii(t)}function Vo(t){if(I!==this)throw new Error("Out-of-order effect");Li(this),I=t,this.f&=-2,8&this.f&&oa(this),jn()}function ee(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}ee.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};ee.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,Ii(this),Ri(this),bt++;var t=I;return I=this,Vo.bind(this,t)};ee.prototype.N=function(){2&this.f||(this.f|=2,this.o=ue,ue=this)};ee.prototype.d=function(){this.f|=8,1&this.f||oa(this)};ee.prototype.dispose=function(){this.d()};function ze(t,e){var n=new ee(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var Di,Je,Yo=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Ei=[];ze(function(){Di=this.N})();function ne(t,e){E[t]=e.bind(null,E[t]||function(){})}function _n(t){if(Je){var e=Je;Je=void 0,e()}Je=t&&t.S()}function Pi(t){var e=this,n=t.data,s=Xo(n);s.value=n;var a=wi(function(){for(var l=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var c=J(function(){var m=s.value.value;return m===0?0:m===!0?"":m||""}),v=J(function(){return!Array.isArray(c.value)&&!ui(c.value)}),u=ze(function(){if(this.N=Mi,v.value){var m=c.value;l.__v&&l.__v.__e&&l.__v.__e.nodeType===3&&(l.__v.__e.data=m)}}),p=e.__$u.d;return e.__$u.d=function(){u(),p.call(this)},[v,c]},[]),i=a[0],r=a[1];return i.value?r.peek():r.value}Pi.displayName="ReactiveTextNode";Object.defineProperties(U.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Pi},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});ne("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var i=s[a];i instanceof U&&(n||(e.__np=n={}),n[a]=i,s[a]=i.peek())}}t(e)});ne("__r",function(t,e){if(t(e),e.type!==Fe){_n();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,i){var r;return ze(function(){r=this},{name:i}),r.c=a,r})(function(){var a;Yo&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),_n(n)}});ne("__e",function(t,e,n,s){_n(),t(e,n,s)});ne("diffed",function(t,e){_n();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var i=n.U;if(i)for(var r in i){var l=i[r];l!==void 0&&!(r in s)&&(l.d(),i[r]=void 0)}else i={},n.U=i;for(var d in s){var c=i[d],v=s[d];c===void 0?(c=Qo(n,d,v),i[d]=c):c.o(v,a)}for(var u in s)a[u]=s[u]}}t(e)});function Qo(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,i=f(n),r=n.peek();return{o:function(l,d){i.value=l,r=l.peek()},d:ze(function(){this.N=Mi;var l=i.value.value;r!==l?(r=void 0,a?t[e]=l:l!=null&&(l!==!1||e[4]==="-")?t.setAttribute(e,l):t.removeAttribute(e)):r=void 0})}}ne("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var i=s[a];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var l=r.__$u;l&&(r.__$u=void 0,l.d())}}t(e)});ne("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});ce.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var l in this.props)if(!(l in t))return!0;return!1};function Xo(t,e){return wi(function(){return f(t,e)},[])}var Zo=function(t){queueMicrotask(function(){queueMicrotask(t)})};function tr(){Jo(function(){for(var t;t=Ei.shift();)Di.call(t)})}function Mi(){Ei.push(this)===1&&(E.requestAnimationFrame||Zo)(tr)}const er=["overview","board","activity","council","goals","execution","tasks","agents","ops","trpg"],Oi={tab:"overview",params:{},postId:null},nr={journal:"activity",mdal:"goals"};function Ea(t){return!!t&&er.includes(t)}function Pa(t){if(t)return nr[t]??t}function As(t){try{return decodeURIComponent(t)}catch{return t}}function Cs(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function sr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function ji(t,e){const n=Pa(t[0]),s=Pa(e.tab),a=Ea(n)?n:Ea(s)?s:"overview";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=As(t[2]):t[0]==="post"&&t[1]&&(i=As(t[1]))),{tab:a,params:e,postId:i}}function gn(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Oi;const n=As(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=Cs(a),r=sr(s);return ji(r,i)}function ar(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Oi,params:Cs(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Cs(e.replace(/^\?/,""));return ji(s,a)}function Fi(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const at=f(gn(window.location.hash));window.addEventListener("hashchange",()=>{at.value=gn(window.location.hash)});function Fn(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Fi(n)}function ir(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function or(){if(window.location.hash&&window.location.hash!=="#"){at.value=gn(window.location.hash);return}const t=ar(window.location.pathname,window.location.search);if(t){at.value=t;const e=Fi(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",at.value=gn(window.location.hash)}const Ts=[{id:"overview",label:"Overview",icon:"🏠"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"council",label:"Council",icon:"🏛️"},{id:"goals",label:"Planning",icon:"🎯"},{id:"execution",label:"Execution",icon:"🛠️"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"agents",label:"Agents",icon:"🤖"},{id:"ops",label:"Ops",icon:"🎮"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function rr(){const t=at.value.tab;return o`
    <div class="main-tab-bar">
      ${Ts.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Fn(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const Ma="masc_dashboard_sse_session_id",lr=1e3,cr=15e3,wt=f(!1),zn=f(0),zi=f(null),Xt=f([]);function ur(){let t=sessionStorage.getItem(Ma);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Ma,t)),t}const dr=200;function pr(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};Xt.value=[a,...Xt.value].slice(0,dr)}function Ns(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Oa(t,e){const n=Ns(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Z(t,e,n,s,a={}){pr(t,e,n,{eventType:s,...a})}let lt=null,Jt=null,Rs=0;function Hi(){Jt&&(clearTimeout(Jt),Jt=null)}function vr(){if(Jt)return;Rs++;const t=Math.min(Rs,5),e=Math.min(cr,lr*Math.pow(2,t));Jt=setTimeout(()=>{Jt=null,Ui()},e)}function Ui(){Hi(),lt&&(lt.close(),lt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",ur());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);lt=i,i.onopen=()=>{lt===i&&(Rs=0,wt.value=!0)},i.onerror=()=>{lt===i&&(wt.value=!1,i.close(),lt=null,vr())},i.onmessage=r=>{try{const l=JSON.parse(r.data);zn.value++,zi.value=l,mr(l)}catch{}}}function mr(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Z(n,"Joined","system","agent_joined");break;case"agent_left":Z(n,"Left","system","agent_left");break;case"broadcast":Z(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Z(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Z(n,Oa("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ns(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Z(n,Oa("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ns(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Z(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Z(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Z(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Z(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Z(n,e,"system","unknown")}}function fr(){Hi(),lt&&(lt.close(),lt=null),wt.value=!1}function Ki(){return new URLSearchParams(window.location.search)}function Bi(){const t=Ki(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function qi(){return{...Bi(),"Content-Type":"application/json"}}const _r=15e3,Wi=3e4,gr=6e4,ja=new Set([408,425,429,500,502,503,504]);class He extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Ft(this,"method");Ft(this,"path");Ft(this,"status");Ft(this,"statusText");Ft(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function ra(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new He({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function $r(){var e,n;const t=Ki();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function ft(t){const e=await ra(t,{headers:Bi()},_r);if(!e.ok)throw new He({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function hr(t){return new Promise(e=>setTimeout(e,t))}function yr(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function br(t){if(t instanceof He)return t.timeout||typeof t.status=="number"&&ja.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=yr(t.message);return e!==null&&ja.has(e)}async function Ue(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!br(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await hr(i),s+=1}}async function _t(t,e,n){const s=await ra(t,{method:"POST",headers:{...qi(),...n??{}},body:JSON.stringify(e)},Wi);if(!s.ok)throw new He({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function kr(t,e,n,s=Wi){const a=await ra(t,{method:"POST",headers:{...qi(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new He({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function xr(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function wr(t){var e,n,s,a,i,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((l=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function B(t,e){const n=await kr("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},gr),s=xr(n);return wr(s)}function Sr(t="compact"){return ft(`/api/v1/dashboard?mode=${t}`)}function Ar(){return ft("/api/v1/operator")}function Cr(t){return _t("/api/v1/operator/action",t)}function Tr(t,e){return _t("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const Nr=new Set(["lodge-system","team-session"]);function Zt(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Rr(t){return Nr.has(t.trim().toLowerCase())}function Lr(t){return t.filter(e=>!Rr(e.author))}function Ir(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Gi(t){if(!T(t))return null;const e=_(t.id,"").trim(),n=_(t.author,"").trim(),s=_(t.content,"").trim();if(!e||!n)return null;const a=C(t.score,0),i=C(t.votes_up,0),r=C(t.votes_down,0),l=C(t.votes,a||i-r),d=C(t.comment_count,C(t.reply_count,0)),c=(()=>{const g=t.flair;if(typeof g=="string"&&g.trim())return g.trim();if(T(g)){const N=_(g.name,"").trim();if(N)return N}return _(t.flair_name,"").trim()||void 0})(),v=_(t.created_at_iso,"").trim()||Zt(t.created_at),u=_(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Zt(t.updated_at):v),m=_(t.title,"").trim()||Ir(s);return{id:e,author:n,title:m,content:s,tags:[],votes:l,vote_balance:a,comment_count:d,created_at:v,updated_at:u,flair:c,hearth_count:C(t.hearth_count,0)}}function Dr(t){if(!T(t))return null;const e=_(t.id,"").trim(),n=_(t.post_id,"").trim(),s=_(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:_(t.content,""),created_at:Zt(t.created_at)}}async function Er(t,e){return Ue("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const s=n.toString(),a=await ft(`/api/v1/board${s?`?${s}`:""}`),i=Array.isArray(a.posts)?a.posts.map(Gi).filter(l=>l!==null):[];return{posts:e!=null&&e.excludeSystem?Lr(i):i}})}async function Pr(t){return Ue("fetchBoardPost",async()=>{const e=await ft(`/api/v1/board/${t}?format=flat`),n=T(e.post)?e.post:e,s=Gi(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(Dr).filter(r=>r!==null);return{...s,comments:i}})}function Ji(t,e){return _t("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:$r()})}function Mr(t,e,n){return _t("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Or(t){const e=_(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function K(...t){for(const e of t){const n=_(e,"");if(n.trim())return n.trim()}return""}function Fa(t){const e=Or(K(t.outcome,t.result,t.result_code));if(!e)return;const n=K(t.reason,t.reason_code,t.description,t.detail),s=K(t.summary,t.summary_ko,t.summary_en,t.note),a=K(t.details,t.details_text,t.text,t.note),i=K(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=K(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=K(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const u=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof u=="string"?[u]:Array.isArray(u)?u.map(p=>{if(typeof p=="string")return p.trim();if(T(p)){const m=_(p.summary,"").trim();if(m)return m;const g=_(p.text,"").trim();if(g)return g;const k=_(p.type,"").trim();return k||_(p.event_id,"").trim()}return""}).filter(p=>p.length>0):[]})(),c=(()=>{const u=C(t.turn,Number.NaN);if(Number.isFinite(u))return u;const p=C(t.turn_number,Number.NaN);if(Number.isFinite(p))return p;const m=C(t.current_turn,Number.NaN);if(Number.isFinite(m))return m;const g=C(t.round,Number.NaN);return Number.isFinite(g)?g:void 0})(),v=K(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:l||void 0,turn:c,phase:v||void 0}}function jr(t,e){const n=T(t.state)?t.state:{};if(_(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>T(r)?_(r.type,"")==="session.outcome":!1),i=T(n.session_outcome)?n.session_outcome:{};if(T(i)&&Object.keys(i).length>0){const r=Fa(i);if(r)return r}if(T(a))return Fa(T(a.payload)?a.payload:{})}function T(t){return typeof t=="object"&&t!==null}function _(t,e=""){return typeof t=="string"?t:e}function C(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function yt(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ls(t,e=!1){return typeof t=="boolean"?t:e}function ae(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(T(e)){const n=_(e.name,"").trim(),s=_(e.id,"").trim(),a=_(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Fr(t){const e={};if(!T(t)&&!Array.isArray(t))return e;if(T(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=_(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!T(n))continue;const s=K(n.to,n.target,n.actor_id,n.name,n.id),a=K(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function zr(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function V(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Hr=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Ur(t){const e=T(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(Hr.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function Kr(t,e){if(t!=="dice.rolled")return;const n=C(e.raw_d20,0),s=C(e.total,0),a=C(e.bonus,0),i=_(e.action,"roll"),r=C(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Br(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function qr(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Wr(t,e,n,s){const a=n||e||_(s.actor_id,"")||_(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=_(s.proposed_action,_(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=_(s.reply,_(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return _(s.reply,_(s.content,_(s.text,"Narration")));case"dice.rolled":{const i=_(s.action,"roll"),r=C(s.total,0),l=C(s.dc,0),d=_(s.label,""),c=a||"actor",v=l>0?` vs DC ${l}`:"",u=d?` (${d})`:"";return`${c} ${i}: ${r}${v}${u}`}case"turn.started":return`Turn ${C(s.turn,1)} started`;case"phase.changed":return`Phase: ${_(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${_(s.name,T(s.actor)?_(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${_(s.keeper_name,_(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${_(s.keeper_name,_(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${C(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${C(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||_(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||_(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${_(s.reason_code,"unknown")}`;case"memory.signal":{const i=T(s.entity_refs)?s.entity_refs:{},r=_(i.requested_tier,""),l=_(i.effective_tier,""),d=Ls(i.guardrail_applied,!1),c=_(s.summary_en,_(s.summary_ko,"Memory signal"));if(!r&&!l)return c;const v=r&&l?`${r}->${l}`:l||r;return`${c} [${v}${d?" (guardrail)":""}]`}case"world.event":{if(_(s.event_type,"")==="canon.check"){const r=_(s.status,"unknown"),l=_(s.contract_id,"n/a");return`Canon ${r}: ${l}`}return _(s.description,_(s.summary,"World event"))}case"combat.attack":return _(s.summary,_(s.result,"Attack resolved"));case"combat.defense":return _(s.summary,_(s.result,"Defense resolved"));case"session.outcome":return _(s.summary,_(s.outcome,"Session ended"));default:{const i=Br(s);return i?`${t}: ${i}`:t}}}function Gr(t,e){const n=T(t)?t:{},s=_(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=_(n.actor_name,"").trim()||e[a]||_(T(n.payload)?n.payload.actor_name:"",""),r=T(n.payload)?n.payload:{},l=_(n.ts,_(n.timestamp,new Date().toISOString())),d=_(n.phase,_(r.phase,"")),c=_(n.category,"");return{type:s,actor:i||a||_(r.actor_name,""),actor_id:a||_(r.actor_id,""),actor_name:i,seq:n.seq,room_id:_(n.room_id,""),phase:d||void 0,category:c||qr(s),visibility:_(n.visibility,_(r.visibility,"public")),event_id:_(n.event_id,""),content:Wr(s,a,i,r),dice_roll:Kr(s,r),timestamp:l}}function Jr(t,e,n){var X,dt;const s=_(t.room_id,"")||n||"default",a=T(t.state)?t.state:{},i=T(a.party)?a.party:{},r=T(a.actor_control)?a.actor_control:{},l=T(a.join_gate)?a.join_gate:{},d=T(a.contribution_ledger)?a.contribution_ledger:{},c=Object.entries(i).map(([D,H])=>{const $=T(H)?H:{},qe=V($,"max_hp",void 0,10),$a=V($,"hp",void 0,qe),xo=V($,"max_mp",void 0,0),wo=V($,"mp",void 0,0),So=V($,"level",void 0,1),Ao=V($,"xp",void 0,0),Co=Ls($.alive,$a>0),ha=r[D],ya=typeof ha=="string"?ha:void 0,To=zr($.role,D,ya),No=yt($.generation),Ro=K($.joined_at,$.joinedAt,$.started_at,$.startedAt),Lo=K($.claimed_at,$.claimedAt,$.assigned_at,$.assignedAt,$.assigned_time),Io=K($.last_seen,$.lastSeen,$.last_seen_at,$.lastSeenAt,$.last_active,$.lastActive),Do=K($.scene,$.current_scene,$.currentScene,$.world_scene,$.scene_name,$.sceneName),Eo=K($.location,$.current_location,$.currentLocation,$.position,$.zone,$.area);return{id:D,name:_($.name,D),role:To,keeper:ya,archetype:_($.archetype,""),persona:_($.persona,""),portrait:_($.portrait,"")||void 0,background:_($.background,"")||void 0,traits:ae($.traits),skills:ae($.skills),stats_raw:Ur($),status:Co?"active":"dead",generation:No,joined_at:Ro||void 0,claimed_at:Lo||void 0,last_seen:Io||void 0,scene:Do||void 0,location:Eo||void 0,inventory:ae($.inventory),notes:ae($.notes),relationships:Fr($.relationships),stats:{hp:$a,max_hp:qe,mp:wo,max_mp:xo,level:So,xp:Ao,strength:V($,"strength","str",10),dexterity:V($,"dexterity","dex",10),constitution:V($,"constitution","con",10),intelligence:V($,"intelligence","int",10),wisdom:V($,"wisdom","wis",10),charisma:V($,"charisma","cha",10)}}}),v=c.filter(D=>D.status!=="dead"),u=jr(t,e),p={phase_open:Ls(l.phase_open,!0),min_points:C(l.min_points,3),window:_(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},m=Object.entries(d).map(([D,H])=>{const $=T(H)?H:{};return{actor_id:D,score:C($.score,0),last_reason:_($.last_reason,"")||null,reasons:ae($.reasons)}}),g=c.reduce((D,H)=>(D[H.id]=H.name,D),{}),k=e.map(D=>Gr(D,g)),N=C(a.turn,1),L=_(a.phase,"round"),A=_(a.map,""),P=T(a.world)?a.world:{},x=A||_(P.ascii_map,_(P.map,"")),R=k.filter((D,H)=>{const $=e[H];if(!T($))return!1;const qe=T($.payload)?$.payload:{};return C(qe.turn,-1)===N}),Q=(R.length>0?R:k).slice(-12),At=_(a.status,"active");return{session:{id:s,room:s,status:At==="ended"?"ended":At==="paused"?"paused":"active",round:N,actors:v,created_at:((X=k[0])==null?void 0:X.timestamp)??new Date().toISOString()},current_round:{round_number:N,phase:L,events:Q,timestamp:((dt=k[k.length-1])==null?void 0:dt.timestamp)??new Date().toISOString()},map:x||void 0,join_gate:p,contribution_ledger:m,outcome:u,party:v,story_log:k,history:[]}}async function Vr(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await ft(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Yr(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([ft(`/api/v1/trpg/state${e}`),Vr(t)]);return Jr(n,s,t)}function Qr(t){return _t("/api/v1/trpg/rounds/run",{room_id:t})}function Xr(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Zr(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),_t("/api/v1/trpg/dice/roll",e)}function tl(t,e){const n=Xr();return _t("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function el(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),_t("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function nl(t,e,n){return _t("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function sl(t,e,n){const s=await B("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function al(t){const e=await B("trpg.mid_join.request",t);return JSON.parse(e)}async function Vi(t,e){await B("masc_broadcast",{agent_name:t,message:e})}async function il(t,e,n=1){await B("masc_add_task",{title:t,description:e,priority:n})}async function ol(t){return B("masc_join",{agent_name:t})}async function Yi(t){await B("masc_leave",{agent_name:t})}async function rl(t){await B("masc_heartbeat",{agent_name:t})}async function ll(t=40){return(await B("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function cl(t,e=20){return B("masc_task_history",{task_id:t,limit:e})}async function ul(){return Ue("fetchDebates",async()=>{const t=await ft("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!T(e))return null;const n=_(e.id,"").trim(),s=_(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,status:_(e.status,"open"),argument_count:C(e.argument_count,0),created_at:Zt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function dl(){return Ue("fetchCouncilSessions",async()=>{const t=await ft("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!T(e))return null;const n=_(e.id,"").trim(),s=_(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,initiator:_(e.initiator,"system"),votes:C(e.votes,0),quorum:C(e.quorum,0),state:_(e.state,"open"),created_at:Zt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function pl(t){const e=await B("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function vl(t){return Ue("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await ft(`/api/v1/council/debates/${e}/summary`);if(!T(n))return null;const s=_(n.id,"").trim();return s?{id:s,topic:_(n.topic,""),status:_(n.status,"open"),support_count:C(n.support_count,0),oppose_count:C(n.oppose_count,0),neutral_count:C(n.neutral_count,0),total_arguments:C(n.total_arguments,0),created_at:Zt(n.created_at_iso??n.created_at),summary_text:_(n.summary_text,"")}:null})}function ml(t){const e=_(t,"").trim().toLowerCase();return e.startsWith("error")?"error":e==="running"||e==="completed"||e==="stopped"?e:"running"}function fl(t){return T(t)?{iteration:yt(t.iteration)??0,metric_before:C(t.metric_before,0),metric_after:C(t.metric_after,0),delta:C(t.delta,0),changes:_(t.changes,""),failed_attempts:_(t.failed_attempts,""),next_suggestion:_(t.next_suggestion,""),elapsed_ms:yt(t.elapsed_ms)??0,cost_usd:typeof t.cost_usd=="number"&&Number.isFinite(t.cost_usd)?t.cost_usd:null}:null}function _l(t){if(!T(t))return null;const e=_(t.loop_id,"").trim();if(!e)return null;const n=Array.isArray(t.history)?t.history.map(fl).filter(s=>s!==null):[];return{loop_id:e,profile:_(t.profile,"custom"),status:ml(t.status),current_iteration:yt(t.iteration)??yt(t.current_iteration)??0,max_iterations:yt(t.max_iterations)??0,baseline_metric:C(t.baseline_metric,0),current_metric:C(t.current_metric,C(t.baseline_metric,0)),target:_(t.target,""),stagnation_streak:yt(t.stagnation_streak)??0,stagnation_limit:yt(t.stagnation_limit)??0,elapsed_seconds:C(t.elapsed_seconds,0),history:n}}function za(t){return t.trim().toLowerCase().includes("no mdal loop running")}async function gl(){try{const t=await B("masc_mdal_status",{}),e=JSON.parse(t),n=T(e)?_(e.error,"").trim():"";if(za(n))return{state:"idle"};if(n)return{state:"error",message:n};const s=_l(e);return s?{state:"ready",loop:s}:{state:"error",message:"Unexpected MDAL payload"}}catch(t){const e=t instanceof Error?t.message:"Unknown MDAL fetch error";return za(e)?{state:"idle"}:{state:"error",message:e}}}async function $l(){try{const t=await B("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Pt=f([]),gt=f([]),Ke=f([]),ut=f([]),Mt=f(null),le=f(null),Is=f(new Map),Ot=f([]),Ie=f("hot"),Rt=f(!0),Qi=f(null),vt=f(""),De=f([]),qt=f(!1),et=f(new Map),ln=f("unknown"),Ds=f(null),Es=f(!1),Ee=f(!1),Ps=f(!1),Wt=f(!1),hl=f(null),Ms=f(null),Xi=f(null),Zi=f(null),to=J(()=>Pt.value.filter(t=>t.status==="active"||t.status==="idle")),la=J(()=>{const t=gt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function yl(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const eo=J(()=>{const t=new Map;for(const e of ut.value)t.set(e.name,yl(e));return t}),bl=12e4;function kl(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}const no=J(()=>{const t=Date.now(),e=new Set,n=Is.value;for(const s of ut.value){const a=kl(s,n);a!=null&&t-a>bl&&e.add(s.name)}return e}),$n={},xl=5e3;function Os(){delete $n.compact,delete $n.full}function nt(t){return typeof t=="object"&&t!==null}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function S(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function de(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function so(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function wl(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Sl(t){if(!nt(t))return null;const e=b(t.name);return e?{name:e,status:so(t.status),current_task:b(t.current_task)??null,last_seen:b(t.last_seen),emoji:b(t.emoji),koreanName:b(t.koreanName)??b(t.korean_name),model:b(t.model),traits:de(t.traits),interests:de(t.interests),activityLevel:S(t.activityLevel)??S(t.activity_level),primaryValue:b(t.primaryValue)??b(t.primary_value)}:null}function Al(t){if(!nt(t))return null;const e=b(t.id),n=b(t.title);return!e||!n?null:{id:e,title:n,status:wl(t.status),priority:S(t.priority),assignee:b(t.assignee),description:b(t.description),created_at:b(t.created_at),updated_at:b(t.updated_at)}}function Cl(t){if(!nt(t))return null;const e=b(t.from)??b(t.from_agent)??"system",n=b(t.content)??"",s=b(t.timestamp)??new Date().toISOString();return{id:b(t.id),seq:S(t.seq),from:e,content:n,timestamp:s,type:b(t.type)}}function Tl(t){return Array.isArray(t)?t.map(e=>{if(!nt(e))return null;const n=S(e.ts_unix);if(n==null)return null;const s=nt(e.handoff)?e.handoff:null;return{ts:n,context_ratio:S(e.context_ratio)??0,context_tokens:S(e.context_tokens)??0,context_max:S(e.context_max)??0,latency_ms:S(e.latency_ms)??0,generation:S(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:S(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:S(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?S(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Nl(t){return(Array.isArray(t)?t:nt(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!nt(n))return null;const s=nt(n.agent)?n.agent:null,a=nt(n.context)?n.context:null,i=nt(n.metrics_window)?n.metrics_window:void 0,r=b(n.name);if(!r)return null;const l=S(n.context_ratio)??S(a==null?void 0:a.context_ratio),d=b(n.status)??b(s==null?void 0:s.status)??"offline",c=so(d),v=b(n.model)??b(n.active_model)??b(n.primary_model),u=de(n.skill_secondary),p=a?{source:b(a.source),context_ratio:S(a.context_ratio),context_tokens:S(a.context_tokens),context_max:S(a.context_max),message_count:S(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,m=s?{name:b(s.name),status:b(s.status),current_task:b(s.current_task)??null,last_seen:b(s.last_seen)}:void 0,g=Tl(n.metrics_series);return{name:r,emoji:b(n.emoji),koreanName:b(n.koreanName)??b(n.korean_name),agent_name:b(n.agent_name),trace_id:b(n.trace_id),model:v,primary_model:b(n.primary_model),active_model:b(n.active_model),next_model_hint:b(n.next_model_hint)??null,status:c,last_heartbeat:b(n.last_heartbeat)??b(s==null?void 0:s.last_seen),generation:S(n.generation),turn_count:S(n.turn_count)??S(n.total_turns),keeper_age_s:S(n.keeper_age_s),last_turn_ago_s:S(n.last_turn_ago_s),last_handoff_ago_s:S(n.last_handoff_ago_s),last_compaction_ago_s:S(n.last_compaction_ago_s),last_proactive_ago_s:S(n.last_proactive_ago_s),context_ratio:l,context_tokens:S(n.context_tokens)??S(a==null?void 0:a.context_tokens),context_max:S(n.context_max)??S(a==null?void 0:a.context_max),context_source:b(n.context_source)??b(a==null?void 0:a.source),context:p,traits:de(n.traits),interests:de(n.interests),primaryValue:b(n.primaryValue)??b(n.primary_value),activityLevel:S(n.activityLevel)??S(n.activity_level),memory_recent_note:b(n.memory_recent_note)??null,conversation_tail_count:S(n.conversation_tail_count),k2k_count:S(n.k2k_count),handoff_count_total:S(n.handoff_count_total)??S(n.trace_history_count),compaction_count:S(n.compaction_count),last_compaction_saved_tokens:S(n.last_compaction_saved_tokens),skill_primary:b(n.skill_primary)??null,skill_secondary:u,skill_reason:b(n.skill_reason)??null,metrics_series:g.length>0?g:void 0,metrics_window:i,agent:m}}).filter(n=>n!==null)}async function Hn(t="full"){var s,a,i;const e=Date.now(),n=$n[t];if(!(n&&e-n.time<xl)){Es.value=!0;try{const r=await Sr(t);$n[t]={data:r,time:e},Pt.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(Sl).filter(l=>l!==null),gt.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(Al).filter(l=>l!==null),Ke.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(Cl).filter(l=>l!==null),ut.value=Nl(r.keepers),Mt.value=nt(r.status)?r.status:null,le.value=r.perpetual??null,hl.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{Es.value=!1}}}async function ct(){Ee.value=!0;try{const t=await Er(Ie.value,{excludeSystem:Rt.value});Ot.value=t.posts??[],Ms.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Ee.value=!1}}async function mt(){var t;Ps.value=!0;try{const e=vt.value||((t=Mt.value)==null?void 0:t.room)||"default";vt.value||(vt.value=e);const n=await Yr(e);Qi.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Ps.value=!1}}async function pe(){qt.value=!0;try{const t=await $l();De.value=Array.isArray(t)?t:[],Xi.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{qt.value=!1}}async function ve(){const t=++Jn;Wt.value=!0;try{const e=await gl();if(t!==Jn)return;if(e.state==="error"){ln.value="error",Ds.value=e.message;return}if(Zi.value=new Date().toISOString(),Ds.value=null,e.state==="idle"){ln.value="idle";const i=new Map(et.value);for(const[r,l]of i.entries())l.status==="running"&&i.set(r,{...l,status:"stopped"});et.value=i;return}const n=e.loop;ln.value="ready";const s=new Map(et.value),a=s.get(n.loop_id);s.set(n.loop_id,{...a??{},...n,history:n.history.length>0?n.history:(a==null?void 0:a.history)??[]}),et.value=s}catch(e){console.error("MDAL fetch error:",e)}finally{t===Jn&&(Wt.value=!1)}}let Wn=null,Gn=null,Jn=0;function Rl(){return zi.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Is.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Is.value=n}if(Os(),Wn||(Wn=setTimeout(()=>{Hn(),Wn=null},500)),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&(Gn||(Gn=setTimeout(()=>{ct(),Gn=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Os(),e.type==="mdal_started"&&e.loop_id){const n=new Map(et.value);n.set(e.loop_id,{...n.get(e.loop_id)??{},loop_id:e.loop_id,profile:e.profile??"custom",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??0,current_metric:e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]}),et.value=n}if(e.type==="mdal_iteration"&&e.loop_id){const n=new Map(et.value),s=e.metric_before??e.metric_after??0,a=e.metric_after??s,i=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:s,current_metric:a,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]},r={iteration:e.iteration??0,metric_before:s,metric_after:a,delta:e.delta??0,changes:"",failed_attempts:"",next_suggestion:"",elapsed_ms:0,cost_usd:null};n.set(e.loop_id,{...i,current_iteration:e.iteration??i.current_iteration,current_metric:a,history:[r,...i.history]}),et.value=n}if((e.type==="mdal_completed"||e.type==="mdal_stopped")&&e.loop_id){const n=new Map(et.value),s=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??e.metric_before??e.metric_after??0,current_metric:e.metric_after??e.metric_before??e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]};n.set(e.loop_id,{...s,current_iteration:e.iteration??s.current_iteration,current_metric:e.metric_after??s.current_metric,status:e.type==="mdal_completed"?"completed":"stopped"}),et.value=n}}})}let me=null;function Ll(){me||(me=setInterval(()=>{Os(),Hn()},1e4))}function Il(){me&&(clearInterval(me),me=null)}function h({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function it({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Dl(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function O({timestamp:t}){const e=Dl(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function Tt(t){return(t??"").trim().toLowerCase()}function q(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function cn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Ve(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function ie(t){return t.last_heartbeat??Ve(t.last_turn_ago_s)??Ve(t.last_proactive_ago_s)??Ve(t.last_handoff_ago_s)??Ve(t.last_compaction_ago_s)}function El(t){const e=t.title.trim();return e||cn(t.content)}function Pl(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function ca(t,e,n,s,a={}){var P;const i=Tt(t),r=e.filter(x=>Tt(x.assignee)===i&&(x.status==="claimed"||x.status==="in_progress")).length,l=n.filter(x=>Tt(x.from)===i).sort((x,R)=>q(R.timestamp)-q(x.timestamp))[0],d=s.filter(x=>Tt(x.agent)===i||Tt(x.author)===i).sort((x,R)=>q(R.timestamp)-q(x.timestamp))[0],c=(a.boardPosts??[]).filter(x=>Tt(x.author)===i).sort((x,R)=>q(R.updated_at||R.created_at)-q(x.updated_at||x.created_at))[0],v=(a.keepers??[]).filter(x=>Tt(x.name)===i&&ie(x)!==null).sort((x,R)=>q(ie(R)??0)-q(ie(x)??0))[0],u=l?q(l.timestamp):0,p=d?q(d.timestamp):0,m=c?q(c.updated_at||c.created_at):0,g=v?q(ie(v)??0):0,k=a.lastSeen?q(a.lastSeen):0,N=((P=a.currentTask)==null?void 0:P.trim())||(r>0?`${r} claimed tasks`:null);if(u===0&&p===0&&m===0&&g===0&&k===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:N};const A=[l?{timestamp:l.timestamp,ts:u,text:cn(l.content)}:null,c?{timestamp:c.updated_at||c.created_at,ts:m,text:`Post: ${cn(El(c))}`}:null,v?{timestamp:ie(v),ts:g,text:Pl(v)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:p,text:cn(d.text)}:null].filter(x=>x!==null).sort((x,R)=>R.ts-x.ts)[0];return A&&A.ts>=k?{activeAssignedCount:r,lastActivityAt:A.timestamp,lastActivityText:A.text}:{activeAssignedCount:r,lastActivityAt:a.lastSeen??null,lastActivityText:N??"Presence heartbeat"}}const ua=f(null);function da(t){ua.value=t}function Ha(){ua.value=null}const Ut=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Ml(t){if(!t)return 0;const e=Ut.findIndex(n=>n.level===t);return e>=0?e:0}function Ol({keeper:t}){const e=Ml(t.autonomy_level),n=Ut[e]??Ut[0];if(!n)return null;const s=(e+1)/Ut.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Ut.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Ut.map((a,i)=>o`
            <span style="width:8px; height:8px; border-radius:50%; background:${i<=e?a.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?o`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${O} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function un(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function jl({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${un(t.context_tokens)}</div>
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
        <div class="kpi-value">${s}</div>
        <div class="kpi-label">Cost (USD)</div>
      </div>
    </div>
  `}function Fl({keeper:t}){var v,u;const e=t.metrics_series??[];if(e.length<2){const p=(((v=t.context)==null?void 0:v.context_ratio)??0)*100,m=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${p.toFixed(1)}%;background:${m}"></div>
        </div>
        <span class="chart-pct">${p.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((p,m)=>{const g=a+m/(i-1)*(n-2*a),k=s-a-(p.context_ratio??0)*(s-2*a);return{x:g,y:k,p}}),l=r.map(({x:p,y:m})=>`${p.toFixed(1)},${m.toFixed(1)}`).join(" "),d=(((u=e[e.length-1])==null?void 0:u.context_ratio)??0)*100,c=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p})=>p.is_handoff).map(({x:p})=>o`
          <line x1="${p.toFixed(1)}" y1="${a}" x2="${p.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${c}" stroke-width="1.5"/>
        ${r.filter(({p})=>p.is_compaction).map(({x:p,y:m})=>o`
          <circle cx="${p.toFixed(1)}" cy="${m.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Vn=f("");function zl({keeper:t}){var a,i,r,l;const e=Vn.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Vn.value}
        onInput=${d=>{Vn.value=d.target.value}}
      />
      ${s.map(d=>o`
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${un(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${un(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${un(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Hl({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(s=>o`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${s.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${s.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        Level ${t.level} — XP ${t.xp}
      </div>
    </div>
  `}function Ul({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Kl({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Ua({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Yn(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Bl({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Yn(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Yn(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Yn(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function ql({keeperName:t}){const[e,n]=Ge("Loading internal monologue..."),[s,a]=Ge(""),[i,r]=Ge([]),[l,d]=Ge(!1),c=async()=>{try{const u=await B("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof u=="string"?u:JSON.stringify(u,null,2))}catch(u){n("Failed to load: "+String(u))}};xt(()=>{c()},[t]);const v=async()=>{if(!s.trim())return;d(!0);const u=s;a(""),r(p=>[...p,{role:"You",text:u}]);try{const p=await B("masc_keeper_msg",{name:t,message:u});r(m=>[...m,{role:t,text:typeof p=="string"?p:JSON.stringify(p)}]),c()}catch(p){r(m=>[...m,{role:"System",text:"Error: "+String(p)}])}finally{d(!1)}};return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Inner Monologue</h3>
      
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <!-- Chat Area -->
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <div style="background: rgba(0,0,0,0.3); border: 1px solid var(--border); border-radius: 12px; height: 300px; overflow-y: auto; padding: 12px; display: flex; flex-direction: column; gap: 8px; font-size: 0.85rem;">
            ${i.length===0?o`<div style="color: var(--text-muted); font-style: italic;">No direct messages yet.</div>`:null}
            ${i.map(u=>o`
              <div style="padding: 8px; border-radius: 8px; background: ${u.role==="You"?"rgba(0, 240, 255, 0.1)":"rgba(255, 255, 255, 0.05)"}; border-left: 2px solid ${u.role==="You"?"var(--accent-cyan)":"var(--text-muted)"};">
                <strong style="color: ${u.role==="You"?"var(--accent-cyan)":"var(--text-primary)"}; display: block; margin-bottom: 4px;">${u.role}</strong>
                <span style="white-space: pre-wrap;">${u.text}</span>
              </div>
            `)}
          </div>
          <div style="display: flex; gap: 8px;">
            <input 
              type="text" 
              value=${s} 
              onInput=${u=>a(u.currentTarget.value)} 
              onKeyDown=${u=>u.key==="Enter"&&!u.shiftKey&&v()}
              placeholder="Ping the agent..."
              disabled=${l}
              style="flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--text-primary); font-family: var(--font-body);"
            />
            <button 
              onClick=${v} 
              disabled=${l||!s.trim()}
              style="background: var(--accent-cyan); color: #000; border: none; border-radius: 8px; padding: 8px 16px; font-weight: bold; cursor: pointer; opacity: ${l?.5:1};"
            >
              ${l?"Sending...":"Send"}
            </button>
          </div>
        </div>

        <!-- Monologue / Status Area -->
        <div style="background: #050810; border: 1px solid var(--card-border); border-radius: 12px; padding: 12px; height: 345px; overflow-y: auto; font-family: monospace; font-size: 0.75rem; color: var(--ok); white-space: pre-wrap; box-shadow: inset 0 0 15px rgba(0,0,0,0.8);">
          ${e}
        </div>
        
      </div>
    </div>
  `}function Wl(){var e,n,s;const t=ua.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Ha()}}
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
            <${it} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Ha()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${jl} keeper=${t} />

        ${""}
        <${Fl} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${h} title="Field Dictionary">
            <${zl} keeper=${t} />
          <//>

          ${""}
          <${h} title="Profile">
            <${Ua} traits=${t.traits??[]} label="Traits" />
            <${Ua} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${O} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${h} title="Autonomy">
                <${Ol} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${h} title="TRPG Stats">
                <${Hl} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${h} title="Equipment (${t.inventory.length})">
                <${Ul} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${h} title="Relationships (${Object.keys(t.relationships).length})">
                <${Kl} rels=${t.relationships} />
              <//>
            `:null}

          <${h} title="Runtime Signals">
            <${Bl} keeper=${t} />
          <//>

          <${h} title="Memory & Context">
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
                  ${t.context_max??((s=t.context)==null?void 0:s.context_max)??"-"}
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
        <${ql} keeperName=${t.name} />
      </div>
    </div>
  `:null}let Gl=0;const Lt=f([]);function y(t,e="success",n=4e3){const s=++Gl;Lt.value=[...Lt.value,{id:s,message:t,type:e}],setTimeout(()=>{Lt.value=Lt.value.filter(a=>a.id!==s)},n)}function Jl(t){Lt.value=Lt.value.filter(e=>e.id!==t)}function Vl(){const t=Lt.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Jl(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Yl="masc_dashboard_agent_name",se=f(null),hn=f(!1),Pe=f(""),yn=f([]),Me=f([]),Vt=f(""),fe=f(!1);function pa(t){se.value=t,va()}function Ka(){se.value=null,Pe.value="",yn.value=[],Me.value=[],Vt.value=""}function Ql(){const t=se.value;return t?Pt.value.find(e=>e.name===t)??null:null}function ao(t){return t?gt.value.filter(e=>e.assignee===t):[]}async function va(){const t=se.value;if(t){hn.value=!0,Pe.value="",yn.value=[],Me.value=[];try{const e=await ll(80);yn.value=e.filter(a=>a.includes(t)).slice(0,20);const n=ao(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await cl(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Me.value=s}catch(e){Pe.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{hn.value=!1}}}async function Ba(){var s;const t=se.value,e=Vt.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Yl))==null?void 0:s.trim())||"dashboard";fe.value=!0;try{await Vi(n,`@${t} ${e}`),Vt.value="",y(`Mention sent to ${t}`,"success"),va()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";y(i,"error")}finally{fe.value=!1}}function Xl({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${it} status=${t.status} />
    </div>
  `}function Zl({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function tc(){var a,i,r,l;const t=se.value;if(!t)return null;const e=Ql(),n=ao(t),s=yn.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Ka()}}
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
                        <${it} status=${e.status} />
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
            ${(((a=e==null?void 0:e.traits)==null?void 0:a.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(d=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(l=e==null?void 0:e.interests)==null?void 0:l.map(d=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${O} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{va()}} disabled=${hn.value}>
              ${hn.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Ka}>Close</button>
          </div>
        </div>

        ${Pe.value?o`<div class="council-error">${Pe.value}</div>`:null}

        <div class="agent-detail-grid">
          <${h} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${Xl} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${h} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((d,c)=>o`<div key=${c} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${h} title="Task History">
          ${Me.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Me.value.map(d=>o`<${Zl} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${h} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Vt.value}
              onInput=${d=>{Vt.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Ba()}}
              disabled=${fe.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Ba()}}
              disabled=${fe.value||Vt.value.trim()===""}
            >
              ${fe.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function zt({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function ec({agent:t}){const e=ca(t.name,gt.value,Ke.value,Xt.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ot.value,keepers:ut.value});return o`
    <div class="agent" onClick=${()=>pa(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${it} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
      ${!t.current_task&&e.activeAssignedCount>0?o`<span class="agent-task">${e.activeAssignedCount} claimed</span>`:null}
      ${e.lastActivityText?o`
            <span class="agent-activity-meta">
              ${e.lastActivityAt?o`<${O} timestamp=${e.lastActivityAt} /> · `:null}
              ${e.lastActivityText}
            </span>
          `:null}
    </div>
  `}function nc(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function qa(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function sc({keeper:t}){var r;const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=eo.value.get(t.name),a=no.value.has(t.name),i=((r=t.agent)==null?void 0:r.current_task)??"No current task";return o`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>da(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${it} status=${t.status} />
          ${s?o`<span class="pill pill-lifecycle pill-lifecycle-${s}">${s}</span>`:null}
          ${a?o`<span class="pill pill-stale">stale</span>`:null}
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
          ${t.skill_primary?o`<span class="pill pill-skill">${t.skill_primary}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>

        <!-- Row 2: Context bar -->
        ${e!=null?o`
          <div class="keeper-ctx-row">
            <div class="keeper-ctx-bar">
              <div class="keeper-ctx-fill ${qa(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${qa(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${nc(t.context_tokens)})`:null}
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
          </div>
        `:null}

        <div class="keeper-focus-row">${i}</div>

        <!-- Row 4: Heartbeat freshness -->
        ${t.last_heartbeat?o`
          <div class="keeper-heartbeat-row">
            <span class="keeper-heartbeat-dot ${t.status==="active"?"pulse":""}"></span>
            <${O} timestamp=${t.last_heartbeat} />
          </div>
        `:null}
      </div>
    </div>
  `}function Wa(){var r,l,d,c,v;const t=Mt.value,e=Pt.value,n=ut.value,s=la.value,a=(r=t==null?void 0:t.monitoring)==null?void 0:r.board,i=(l=t==null?void 0:t.monitoring)==null?void 0:l.council;return o`
    <div class="stats-grid">
      <${zt} label="Agents" value=${e.length} />
      <${zt} label="Active" value=${to.value.length} color="#4ade80" />
      <${zt} label="Keepers" value=${n.length} color="#22d3ee" />
      <${zt} label="Tasks" value=${gt.value.length} />
      <${zt} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${zt} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    ${a||i?o`
        <${h} title="Operations SLO" class="section">
          <div class="grid-2col">
            <div class="stat-card">
              <div class="stat-label">Board Feed</div>
              <div class="stat-value" style=${`color: ${Ja(a==null?void 0:a.alert_level)}`}>
                ${Ga(a==null?void 0:a.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${Ye(a==null?void 0:a.last_activity_age_s)}</span>
                <span>SLO: ≤ ${Ye(a==null?void 0:a.slo_target_age_s)}</span>
                <span>SLO Breach: ${a!=null&&a.slo_breached?"Yes":"No"}</span>
                <span>Posts (24h): ${(a==null?void 0:a.new_posts_24h)??0}</span>
                <span>Unanswered: ${(a==null?void 0:a.unanswered_posts)??0}</span>
              </div>
            </div>

            <div class="stat-card">
              <div class="stat-label">Council Feed</div>
              <div class="stat-value" style=${`color: ${Ja(i==null?void 0:i.alert_level)}`}>
                ${Ga(i==null?void 0:i.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${Ye(i==null?void 0:i.last_activity_age_s)}</span>
                <span>Open Debates: ${(i==null?void 0:i.debates_open)??0}</span>
                <span>Pending Debates: ${(i==null?void 0:i.debates_pending)??0}</span>
                <span>Quorum Risk: ${(i==null?void 0:i.sessions_without_quorum)??0}</span>
                <span>SLO: ≤ ${Ye(i==null?void 0:i.slo_target_quorum_age_s)}</span>
                <span>SLO Breach: ${i!=null&&i.slo_breached?"Yes":"No"}</span>
              </div>
            </div>
          </div>
        <//>
      `:null}

    <div class="grid-2col">
      <${h} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(u=>o`<${ec} key=${u.name} agent=${u} />`)}
        </div>
      <//>

      <${h} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(u=>o`<${sc} key=${u.name} keeper=${u} />`)}
        </div>
      <//>
    </div>

    ${le.value?o`
        <${h} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${le.value.running?"Running":"Stopped"}</span>
            ${le.value.goal?o`<span>Goal: ${le.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${h} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?o`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?o`<span>Project: ${t.project}</span>`:null}
            ${t.version?o`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${ac(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
            ${((d=t.data_quality)==null?void 0:d.board_contract_ok)===!1?o`<span class="pill pill-stale">Board Contract: Degraded</span>`:null}
            ${((c=t.data_quality)==null?void 0:c.council_feed_ok)===!1?o`<span class="pill pill-stale">Council Feed: Degraded</span>`:null}
            ${(v=t.data_quality)!=null&&v.last_sync_at?o`<span>Data Sync: <${O} timestamp=${t.data_quality.last_sync_at} /></span>`:null}
          </div>
        <//>
      `:null}
  `}function ac(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function Ye(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),s=e%60;return s>0?`${n}h ${s}m`:`${n}h`}function Ga(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function Ja(t){const e=(t??"").toLowerCase();return e==="ok"?"#4ade80":e==="warn"?"#fbbf24":e==="bad"?"#fb7185":"#94a3b8"}const Be=f(null),bn=f(!1),St=f(null),M=f(!1),kn=f([]);let ic=1;function j(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function w(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function G(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function io(t){return typeof t=="boolean"?t:void 0}function oc(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Kt(t,e=[]){if(Array.isArray(t))return t;if(!j(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function rc(t){return j(t)?{id:w(t.id),seq:G(t.seq),from:w(t.from)??w(t.from_agent)??"system",content:w(t.content)??"",timestamp:w(t.timestamp)??new Date().toISOString(),type:w(t.type)}:null}function lc(t){return j(t)?{room_id:w(t.room_id),current_room:w(t.current_room)??w(t.room),project:w(t.project),cluster:w(t.cluster),paused:io(t.paused),pause_reason:w(t.pause_reason)??null,paused_by:w(t.paused_by)??null,paused_at:w(t.paused_at)??null}:{}}function Va(t){if(!j(t))return;const e=Object.entries(t).map(([n,s])=>{const a=w(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function cc(t){if(!j(t))return null;const e=j(t.status)?t.status:void 0,n=j(t.summary)?t.summary:j(e==null?void 0:e.summary)?e.summary:void 0,s=j(t.session)?t.session:j(e==null?void 0:e.session)?e.session:void 0,a=w(t.session_id)??w(n==null?void 0:n.session_id)??w(s==null?void 0:s.session_id);if(!a)return null;const i=Va(t.report_paths)??Va(e==null?void 0:e.report_paths),r=Kt(t.recent_events,["events"]).filter(j);return{session_id:a,status:w(t.status)??w(n==null?void 0:n.status)??w(s==null?void 0:s.status),progress_pct:G(t.progress_pct)??G(n==null?void 0:n.progress_pct),elapsed_sec:G(t.elapsed_sec)??G(n==null?void 0:n.elapsed_sec),remaining_sec:G(t.remaining_sec)??G(n==null?void 0:n.remaining_sec),done_delta_total:G(t.done_delta_total)??G(n==null?void 0:n.done_delta_total),summary:n,team_health:j(t.team_health)?t.team_health:j(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:j(t.communication_metrics)?t.communication_metrics:j(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:j(t.orchestration_state)?t.orchestration_state:j(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:j(t.cascade_metrics)?t.cascade_metrics:j(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:s,recent_events:r}}function uc(t){if(!j(t))return null;const e=w(t.name);if(!e)return null;const n=j(t.context)?t.context:void 0;return{name:e,agent_name:w(t.agent_name),status:w(t.status),autonomy_level:w(t.autonomy_level),context_ratio:G(t.context_ratio)??G(n==null?void 0:n.context_ratio),generation:G(t.generation),active_goal_ids:oc(t.active_goal_ids),last_autonomous_action_at:w(t.last_autonomous_action_at)??null,last_turn_ago_s:G(t.last_turn_ago_s),model:w(t.model)??w(t.active_model)??w(t.primary_model)}}function dc(t){if(!j(t))return null;const e=w(t.confirm_token)??w(t.token);return e?{confirm_token:e,actor:w(t.actor),action_type:w(t.action_type),target_type:w(t.target_type),target_id:w(t.target_id)??null,delegated_tool:w(t.delegated_tool),created_at:w(t.created_at),preview:t.preview}:null}function pc(t){const e=j(t)?t:{};return{room:lc(e.room),sessions:Kt(e.sessions,["items","sessions"]).map(cc).filter(n=>n!==null),keepers:Kt(e.keepers,["items","keepers"]).map(uc).filter(n=>n!==null),recent_messages:Kt(e.recent_messages,["messages"]).map(rc).filter(n=>n!==null),pending_confirms:Kt(e.pending_confirms,["items","confirms"]).map(dc).filter(n=>n!==null),available_actions:Kt(e.available_actions,["actions"]).filter(j).map(n=>({action_type:w(n.action_type)??"unknown",target_type:w(n.target_type)??"unknown",description:w(n.description),confirm_required:io(n.confirm_required)}))}}function Qe(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Ya(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function xn(t){kn.value=[{...t,id:ic++,at:new Date().toISOString()},...kn.value].slice(0,20)}function oo(t){return t.confirm_required?Qe(t.preview)||"Confirmation required":Qe(t.result)||Qe(t.executed_action)||Qe(t.delegated_tool_result)||t.status}async function te(){bn.value=!0,St.value=null;try{const t=await Ar();Be.value=pc(t)}catch(t){St.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{bn.value=!1}}async function vc(t){M.value=!0,St.value=null;try{const e=await Cr(t);return xn({actor:t.actor,action_type:t.action_type,target_label:Ya(t),outcome:e.confirm_required?"preview":"executed",message:oo(e),delegated_tool:e.delegated_tool}),await te(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw St.value=n,xn({actor:t.actor,action_type:t.action_type,target_label:Ya(t),outcome:"error",message:n}),e}finally{M.value=!1}}async function mc(t,e){M.value=!0,St.value=null;try{const n=await Tr(t,e);return xn({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:oo(n),delegated_tool:n.delegated_tool}),await te(),n}catch(n){const s=n instanceof Error?n.message:"Operator confirmation failed";throw St.value=s,xn({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:s}),n}finally{M.value=!1}}const ro="masc_dashboard_agent_name";function fc(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(ro))==null?void 0:s.trim())||"dashboard"}const Un=f(fc()),_e=f(""),js=f("Operator pause"),ge=f(""),wn=f(""),Fs=f("2"),Sn=f(""),Yt=f("note"),An=f(""),Cn=f(""),Tn=f(""),zs=f("2"),Hs=f("Operator stop request"),Us=f(""),$e=f("");function _c(t){const e=t.trim()||"dashboard";Un.value=e,localStorage.setItem(ro,e)}function Qa(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function gc(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}async function jt(t){const e=Un.value.trim()||"dashboard";try{const n=await vc({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?y("Confirmation queued","warning"):y(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";return y(s,"error"),null}}async function Xa(){const t=_e.value.trim();if(!t)return;await jt({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(_e.value="")}async function $c(){await jt({action_type:"room_pause",target_type:"room",payload:{reason:js.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function hc(){await jt({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function yc(){const t=ge.value.trim();if(!t)return;await jt({action_type:"task_inject",target_type:"room",payload:{title:t,description:wn.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Fs.value,10)||2},successMessage:"Task injection submitted"})&&(ge.value="",wn.value="")}async function bc(){var i;const t=Be.value,e=Sn.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){y("Select a team session first","warning");return}const n={turn_kind:Yt.value},s=An.value.trim();s&&(n.message=s),Yt.value==="task"&&(n.task_title=Cn.value.trim()||"Operator injected task",n.task_description=Tn.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(zs.value,10)||2),await jt({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(An.value="",Yt.value==="task"&&(Cn.value="",Tn.value=""))}async function kc(){var n;const t=Be.value,e=Sn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){y("Select a team session first","warning");return}await jt({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Hs.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function xc(){var a;const t=Be.value,e=Us.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=$e.value.trim();if(!e){y("Select a keeper first","warning");return}if(!n)return;await jt({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&($e.value="")}async function wc(t){const e=Un.value.trim()||"dashboard";try{await mc(e,t),y("Confirmation executed","success")}catch(n){const s=n instanceof Error?n.message:"Confirmation failed";y(s,"error")}}function Sc(){var d;xt(()=>{te()},[]);const t=Be.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],s=(t==null?void 0:t.keepers)??[],a=(t==null?void 0:t.pending_confirms)??[],i=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===Sn.value)??n[0]??null,l=s.find(c=>c.name===Us.value)??s[0]??null;return o`
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
            value=${Un.value}
            onInput=${c=>_c(c.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{te()}} disabled=${bn.value||M.value}>
            ${bn.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${St.value?o`
        <section class="ops-banner error">${St.value}</section>
      `:null}

      ${a.length>0?o`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <div class="ops-confirmation-list">
            ${a.map(c=>o`
              <article key=${c.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${c.action_type??"unknown"}</strong>
                  <span>${c.target_type??"target"}${c.target_id?`:${c.target_id}`:""}</span>
                  <span>${c.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${c.preview?o`<pre class="ops-code-block">${Qa(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{wc(c.confirm_token)}} disabled=${M.value}>
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
              value=${_e.value}
              onInput=${c=>{_e.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&Xa()}}
              disabled=${M.value}
            />
            <button class="control-btn" onClick=${()=>{Xa()}} disabled=${M.value||_e.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${js.value}
              onInput=${c=>{js.value=c.target.value}}
              disabled=${M.value}
            />
            <button class="control-btn ghost" onClick=${()=>{$c()}} disabled=${M.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{hc()}} disabled=${M.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${ge.value}
            onInput=${c=>{ge.value=c.target.value}}
            disabled=${M.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${wn.value}
            onInput=${c=>{wn.value=c.target.value}}
            disabled=${M.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${Fs.value}
              onChange=${c=>{Fs.value=c.target.value}}
              disabled=${M.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{yc()}} disabled=${M.value||ge.value.trim()===""}>
              Inject
            </button>
          </div>

          ${i.length>0?o`
            <div class="ops-section-head">Recent Messages</div>
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
            ${n.length===0?o`<div class="ops-empty">No team sessions available.</div>`:n.map(c=>{var v;return o`
              <button
                key=${c.session_id}
                class="ops-entity-card ${(r==null?void 0:r.session_id)===c.session_id?"active":""}"
                onClick=${()=>{Sn.value=c.session_id}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.session_id}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${Math.round(c.progress_pct??0)}%</span>
                  <span>${c.done_delta_total??0} done</span>
                  <span>${(v=c.team_health)!=null&&v.status?String(c.team_health.status):"health n/a"}</span>
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
                <pre class="ops-code-block compact">${Qa(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Yt.value}
              onChange=${c=>{Yt.value=c.target.value}}
              disabled=${M.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{bc()}} disabled=${M.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${An.value}
            onInput=${c=>{An.value=c.target.value}}
            disabled=${M.value||!r}
          ></textarea>
          ${Yt.value==="task"?o`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${Cn.value}
              onInput=${c=>{Cn.value=c.target.value}}
              disabled=${M.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${Tn.value}
              onInput=${c=>{Tn.value=c.target.value}}
              disabled=${M.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${zs.value}
              onChange=${c=>{zs.value=c.target.value}}
              disabled=${M.value||!r}
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
              value=${Hs.value}
              onInput=${c=>{Hs.value=c.target.value}}
              disabled=${M.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{kc()}} disabled=${M.value||!r}>
              Stop
            </button>
          </div>
        </section>

        <section class="card ops-panel">
          <div class="card-title">Keepers</div>
          <div class="ops-entity-list">
            ${s.length===0?o`<div class="ops-empty">No keepers available.</div>`:s.map(c=>o`
              <button
                key=${c.name}
                class="ops-entity-card ${(l==null?void 0:l.name)===c.name?"active":""}"
                onClick=${()=>{Us.value=c.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.name}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${c.model??"model n/a"}</span>
                  <span>${typeof c.context_ratio=="number"?`${Math.round(c.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${gc(c.last_turn_ago_s)}</span>
                </div>
              </button>
            `)}
          </div>

          ${l?o`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${l.name}</div>
              <div class="ops-detail-meta">
                <span>Autonomy: ${l.autonomy_level??"n/a"}</span>
                <span>Generation: ${l.generation??0}</span>
                <span>Goals: ${((d=l.active_goal_ids)==null?void 0:d.length)??0}</span>
              </div>
            </div>
          `:null}

          <label class="control-label" for="ops-keeper-message">Keeper Message</label>
          <textarea
            id="ops-keeper-message"
            class="control-textarea"
            rows=${6}
            placeholder="Send a structured intervention or course correction"
            value=${$e.value}
            onInput=${c=>{$e.value=c.target.value}}
            disabled=${M.value||!l}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{xc()}} disabled=${M.value||!l||$e.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${kn.value.length===0?o`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:kn.value.map(c=>o`
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
  `}const Ks=f([]),Bs=f([]),he=f(""),Nn=f(!1),ye=f(!1),Oe=f(""),Rn=f(null),tt=f(null),qs=f(!1);async function Ws(){Nn.value=!0,Oe.value="";try{const[t,e]=await Promise.all([ul(),dl()]);Ks.value=t,Bs.value=e}catch(t){Oe.value=t instanceof Error?t.message:"Failed to load council data"}finally{Nn.value=!1}}async function Za(){const t=he.value.trim();if(t){ye.value=!0;try{const e=await pl(t);he.value="",y(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ws()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";y(n,"error")}finally{ye.value=!1}}}async function Ac(t){Rn.value=t,qs.value=!0,tt.value=null;try{tt.value=await vl(t)}catch(e){Oe.value=e instanceof Error?e.message:"Failed to load debate status",tt.value=null}finally{qs.value=!1}}function Cc({debate:t}){const e=Rn.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Ac(t.id)}
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
  `}function Tc({session:t}){return o`
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
  `}function Nc(){var e;const t=(e=Mt.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${O} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Rc(){var e,n;xt(()=>{Ws()},[]);const t=((n=(e=Mt.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${Nc} />
      <${h} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${he.value}
            onInput=${s=>{he.value=s.target.value}}
            onKeyDown=${s=>{s.key==="Enter"&&Za()}}
            disabled=${ye.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Za}
            disabled=${ye.value||he.value.trim()===""}
          >
            ${ye.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Ws} disabled=${Nn.value}>
            ${Nn.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Oe.value?o`<div class="council-error">${Oe.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${h} title="Debates" class="section">
          <div class="council-list">
            ${Ks.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:Ks.value.map(s=>o`<${Cc} key=${s.id} debate=${s} />`)}
          </div>
        <//>

        <${h} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Bs.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:Bs.value.map(s=>o`<${Tc} key=${s.id} session=${s} />`)}
          </div>
        <//>
      </div>

      <${h} title=${Rn.value?`Debate Detail (${Rn.value})`:"Debate Detail"} class="section">
        ${qs.value?o`<div class="loading-indicator">Loading debate detail...</div>`:tt.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${tt.value.status}</span>
                  <span>Total arguments: ${tt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${tt.value.support_count}</span>
                  <span>Oppose: ${tt.value.oppose_count}</span>
                  <span>Neutral: ${tt.value.neutral_count}</span>
                </div>
                ${tt.value.summary_text?o`<pre class="council-detail">${tt.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Lc({text:t}){if(!t)return null;const e=Ic(t);return o`<div class="markdown-content">${e}</div>`}function Ic(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${l?`language-${l}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const c=e[s].replace("</think>","").trim();c&&r.push(c),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Qn(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${Qn(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${Qn(i.join(`
`))}</p>`)}return n}function Qn(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const lo=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],dn=f(null),be=f([]),Dt=f(!1),It=f(null),ke=f("");function Dc(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Ec=f(Dc()),xe=f(!1);async function ma(t){It.value=t,dn.value=null,be.value=[],Dt.value=!0;try{const e=await Pr(t);if(It.value!==t)return;dn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},be.value=e.comments??[]}catch{It.value===t&&(dn.value=null,be.value=[])}finally{It.value===t&&(Dt.value=!1)}}async function ti(t){const e=ke.value.trim();if(e){xe.value=!0;try{await Mr(t,Ec.value,e),ke.value="",y("Comment posted","success"),await ma(t),ct()}catch{y("Failed to post comment","error")}finally{xe.value=!1}}}function Pc(){const t=Ie.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${lo.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{Ie.value=e.id,ct()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Rt.value?"is-active":""}"
          onClick=${()=>{Rt.value=!Rt.value,ct()}}
        >
          ${Rt.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${ct} disabled=${Ee.value}>
          ${Ee.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Xn(){var e;const t=(e=Mt.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${O} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function co({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Mc(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function ei(t){return t.updated_at!==t.created_at}function Zn(){var n;const t=((n=lo.find(s=>s.id===Ie.value))==null?void 0:n.label)??Ie.value,e=Ot.value.length;return o`
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
        <strong>${Rt.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Ms.value?o`<${O} timestamp=${Ms.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Oc({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Ji(t.id,n),ct()}catch{y("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>ir(t.id)}>
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
              <${co} flair=${t.flair} />
              ${ei(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${O} timestamp=${t.created_at} /></span>
            ${ei(t)?o`<span>Updated <${O} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${Mc(t.content)}</div>
      </div>
    </div>
  `}function jc({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${O} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Fc({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${ke.value}
        onInput=${e=>{ke.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&ti(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${xe.value}
      />
      <button
        onClick=${()=>ti(t)}
        disabled=${xe.value||ke.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${xe.value?"...":"Post"}
      </button>
    </div>
  `}function zc({post:t}){It.value!==t.id&&!Dt.value&&ma(t.id);const e=async n=>{try{await Ji(t.id,n),ct()}catch{y("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>Fn("board")}>← Back to Board</button>
      <${h} title=${o`${t.title} <${co} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Lc} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${O} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${h} title="Comments (${Dt.value?"...":be.value.length})">
        ${Dt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${jc} comments=${be.value} />`}
        <${Fc} postId=${t.id} />
      <//>
    </div>
  `}function Hc(){var a,i;const t=Ot.value,e=Ee.value,n=at.value.postId,s=((i=(a=Mt.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(l=>l.id===n)??(It.value===n?dn.value:null);return!r&&It.value!==n&&!Dt.value&&ma(n),r?o`
          <${Xn} />
          <${Zn} />
          <${zc} post=${r} />
        `:o`
          <div>
            <${Xn} />
            <${Zn} />
            <button class="back-btn" onClick=${()=>Fn("board")}>← Back to Board</button>
            ${Dt.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${s?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${Xn} />
    <${Zn} />
    <${Pc} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${s?"No posts loaded (board feed degraded). Check board contract sync.":Rt.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${Oc} key=${r.id} post=${r} />`)}
          </div>`}
  `}function Uc(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Kc(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Bc(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const uo=120,qc=12,Wc=16,Gc=12,Gs=f("all"),Jc={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Vc={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function Yc(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Qc(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:Uc(t),actor:Kc(t),content:Bc(t),timestamp:new Date(t.timestamp).toISOString()}}function Xc(t,e){var a;const n=(a=t.assignee)==null?void 0:a.trim(),s=t.updated_at??t.created_at;return!n||!s?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:s}}function Zc(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Xe(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Js(t){return t.last_heartbeat??Xe(t.last_turn_ago_s)??Xe(t.last_proactive_ago_s)??Xe(t.last_handoff_ago_s)??Xe(t.last_compaction_ago_s)}function tu(t,e){const n=Js(t);if(!n)return null;const s=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${s}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${s}`,timestamp:n}}function ot(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const Vs=J(()=>{const t=Ke.value.map(Yc),e=Xt.value.map(Qc),n=[...gt.value].sort((i,r)=>ot(r.updated_at??r.created_at??0)-ot(i.updated_at??i.created_at??0)).slice(0,qc).map(Xc).filter(i=>i!==null),s=[...Ot.value].sort((i,r)=>ot(r.updated_at||r.created_at)-ot(i.updated_at||i.created_at)).slice(0,Wc).map(Zc),a=[...ut.value].sort((i,r)=>ot(Js(r)??0)-ot(Js(i)??0)).slice(0,Gc).map(tu).filter(i=>i!==null);return[...t,...e,...n,...s,...a].sort((i,r)=>ot(r.timestamp)-ot(i.timestamp))}),eu=J(()=>{const t=Vs.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),nu=J(()=>{const t=Gs.value;return(t==="all"?Vs.value:Vs.value.filter(n=>n.kind===t)).slice(0,uo)}),su=J(()=>Pt.value.map(t=>({agent:t,motion:ca(t.name,gt.value,Ke.value,Xt.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ot.value,keepers:ut.value})})).sort((t,e)=>{const n=e.motion.activeAssignedCount-t.motion.activeAssignedCount;return n!==0?n:ot(e.motion.lastActivityAt??0)-ot(t.motion.lastActivityAt??0)}));function au(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function oe({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function iu({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${au(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Vc[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function ou(){const t=eu.value,e=nu.value,n=e[0],s=su.value;return o`
    <div class="stats-grid">
      <${oe} label="Visible rows" value=${e.length} />
      <${oe} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${oe} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${oe} label="Board signals" value=${t.board} color="#fbbf24" />
      <${oe} label="SSE events" value=${zn.value} color="#c084fc" />
    </div>

    <${h} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(a=>o`
            <button
              class="goal-filter-btn ${Gs.value===a?"active":""}"
              onClick=${()=>{Gs.value=a}}
            >
              ${Jc[a]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${wt.value?"":"pill-stale"}">
            ${wt.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${O} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${uo} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?o`<div class="empty-state">Waiting for live or snapshot signals...</div>`:e.map(a=>o`<${iu} key=${a.id} row=${a} />`)}
      </div>
    <//>

    <${h} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${s.length===0?o`<div class="empty-state">No active agents</div>`:s.map(({agent:a,motion:i})=>o`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${a.name}</div>
                  <div class="activity-motion-meta">
                    ${i.activeAssignedCount>0?`${i.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${i.lastActivityAt?o` · <${O} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function po({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${l}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${l}">${Math.round(t*100)}%</span>
    </div>
  `}const ts=600*1e3,ru=1200*1e3,ni=.8;function $t(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Ht(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function lu(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function cu(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function uu(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function du(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function pu(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function vu(t){var d,c;const e=ca(t.name,gt.value,Ke.value,Xt.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ot.value,keepers:ut.value}),n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-$t(n)):Number.POSITIVE_INFINITY,a=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let i="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):s>ru?(i="quiet",r="bad",l=a?"Working without a fresh signal":"No fresh agent signal"):a?(i="working",r=s>ts?"warn":"ok",l=s>ts?"Execution looks quiet for too long":"Task and live signal aligned"):s>ts?(i="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((c=t.current_task)==null?void 0:c.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function mu(t){const e=eo.value.get(t.name)??"idle",n=no.value.has(t.name),s=t.context_ratio??0;let a="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||s>=ni)&&(a="warning",i="warn",r=s>=ni?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:a,tone:i,focus:du(t),note:r}}function re({label:t,value:e,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function fu({item:t}){const e=t.kind==="agent"?()=>pa(t.agent.name):()=>da(t.keeper);return o`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?o`<span><${O} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </button>
  `}function _u({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>pa(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${po} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${it} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${lu(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${O} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
        ${e.last_seen?o`<span>Seen <${O} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?o`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function gu({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>da(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${po} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${it} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${cu(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${O} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${pu(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${uu(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function $u(){const t=[...Pt.value].map(vu).sort((d,c)=>{const v=Ht(c.tone)-Ht(d.tone);if(v!==0)return v;const u=c.activeTaskCount-d.activeTaskCount;return u!==0?u:$t(c.lastSignalAt)-$t(d.lastSignalAt)}),e=[...ut.value].map(mu).sort((d,c)=>{const v=Ht(c.tone)-Ht(d.tone);if(v!==0)return v;const u=(c.keeper.context_ratio??0)-(d.keeper.context_ratio??0);return u!==0?u:$t(c.keeper.last_heartbeat)-$t(d.keeper.last_heartbeat)}),n=t.filter(d=>d.state!=="offline").length,s=t.filter(d=>d.state==="working").length,a=t.filter(d=>d.lastSignalAt&&Date.now()-$t(d.lastSignalAt)<=12e4).length,i=t.filter(d=>d.tone!=="ok"),r=e.filter(d=>d.tone!=="ok"),l=[...r.map(d=>({kind:"keeper",key:`keeper-${d.keeper.name}`,tone:d.tone,title:d.keeper.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.keeper.last_heartbeat??null,keeper:d.keeper})),...i.map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agent:d.agent}))].sort((d,c)=>{const v=Ht(c.tone)-Ht(d.tone);return v!==0?v:$t(c.timestamp)-$t(d.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${re} label="Agents online" value=${n} color="#4ade80" caption="active + idle" />
        <${re} label="Working now" value=${s} color="#fbbf24" caption="task or claimed load" />
        <${re} label="Fresh signals" value=${a} color="#22d3ee" caption="within last 2 minutes" />
        <${re} label="Agent alerts" value=${i.length} color=${i.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${re} label="Keeper alerts" value=${r.length} color=${r.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${h} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${l.length===0?o`<div class="empty-state">No agent or keeper alerts right now</div>`:l.map(d=>o`<${fu} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${h} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(d=>o`<${gu} key=${d.keeper.name} row=${d} />`)}
          </div>
        <//>

        <${h} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Current task, recent signal, and quiet drift are surfaced together.</p>
          </div>
          <div class="monitor-list">
            ${t.length===0?o`<div class="empty-state">No agents registered</div>`:t.map(d=>o`<${_u} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>
    </div>
  `}function es({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${O} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function hu(){const{todo:t,inProgress:e,done:n}=la.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${es} key=${s.id} task=${s} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${es} key=${s.id} task=${s} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${es} key=${s.id} task=${s} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function yu(t){return t==null?"P3":t<=1?"P1":t===2?"P2":t>=4?"P4+":"P3"}function ns({task:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.title}</div>
        <div class="council-sub">
          <span>${yu(t.priority)}</span>
          ${t.assignee?o`<span>Assignee: ${t.assignee}</span>`:o`<span>Unassigned</span>`}
          ${t.created_at?o`<span><${O} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </div>
  `}function bu(){const t=la.value,e=t.inProgress,n=t.todo,s=t.done,a=to.value,i=n.filter(l=>(l.priority??3)<=2),r=n.filter(l=>!l.assignee);return o`
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
        <div class="stat-value" style="color:#4ade80">${s.length}</div>
      </div>
    </div>

    <div class="council-grid">
      <${h} title="Execution Queue" class="section">
        <div class="council-list">
          ${e.length===0?o`<div class="empty-state">No active execution tasks</div>`:e.slice(0,20).map(l=>o`<${ns} key=${l.id} task=${l} />`)}
        </div>
      <//>

      <${h} title="Ready Queue" class="section">
        <div class="council-list">
          ${n.length===0?o`<div class="empty-state">No ready tasks</div>`:n.slice(0,20).map(l=>o`<${ns} key=${l.id} task=${l} />`)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${h} title="Assignee Coverage" class="section">
        <div class="council-list">
          ${a.length===0?o`<div class="empty-state">No active agents</div>`:a.map(l=>o`
                <div class="council-row session">
                  <div class="council-row-main">
                    <div class="council-topic">${l.name}</div>
                    <div class="council-sub">
                      ${l.current_task?o`<span>${l.current_task}</span>`:o`<span>Idle</span>`}
                    </div>
                  </div>
                  <${it} status=${l.status} />
                </div>
              `)}
        </div>
      <//>

      <${h} title="Attention Needed" class="section">
        <div class="council-list">
          ${r.length===0?o`<div class="empty-state">No unassigned tasks</div>`:r.slice(0,20).map(l=>o`<${ns} key=${l.id} task=${l} />`)}
        </div>
      <//>
    </div>
  `}const Ln=f("all"),In=f("all"),Ys=J(()=>{let t=De.value;return Ln.value!=="all"&&(t=t.filter(e=>e.horizon===Ln.value)),In.value!=="all"&&(t=t.filter(e=>e.status===In.value)),t}),ku=J(()=>{const t={short:[],mid:[],long:[]};for(const e of Ys.value){const n=t[e.horizon];n&&n.push(e)}return t}),xu=J(()=>{const t=Array.from(et.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t});function wu(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function fa(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function pn(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Su(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function si(t){return t.toFixed(4)}function ai(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Au({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${pn(t.horizon)}">
            ${fa(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${wu(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${O} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${it} status=${t.status} />
        <div class="goal-updated">
          <${O} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function ii({label:t,timestamp:e,source:n,note:s}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${s?o`<div class="planning-freshness-source">${s}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${O} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function ss({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${h} title="${fa(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(s=>o`<${Au} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function Cu(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Ln.value===t?"active":""}"
            onClick=${()=>{Ln.value=t}}
          >
            ${t==="all"?"All":fa(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${In.value===t?"active":""}"
            onClick=${()=>{In.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Tu(){const t=De.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${pn("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${pn("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${pn("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Nu({loop:t}){const e=t.history[0];return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${it} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${si(t.baseline_metric)}</span>
          <span>Current ${si(t.current_metric)}</span>
          <span class=${ai(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${ai(t)}
          </span>
          <span>Elapsed ${Su(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${e?o`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function Ru(){xt(()=>{pe(),ve()},[]);const t=ku.value,e=xu.value,n=e.filter(r=>r.status==="running").length,s=De.value.filter(r=>r.status==="active").length,a=ln.value,i=a==="idle"?"No loop running":a==="error"?Ds.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${Ys.value.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Running loops</div>
          <div class="stat-value" style="color:#fbbf24">${n}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Known loops</div>
          <div class="stat-value">${e.length}</div>
        </div>
      </div>

      <${h} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>masc_mdal_status</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${pe} disabled=${qt.value}>
              ${qt.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${ve} disabled=${Wt.value}>
              ${Wt.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{pe(),ve()}}
              disabled=${qt.value||Wt.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${ii} label="Goals" timestamp=${Xi.value} source="masc_goal_list" />
          <${ii}
            label="MDAL loops"
            timestamp=${Zi.value}
            source="masc_mdal_status"
            note=${i}
          />
        </div>
      <//>

      <${h} title="Goal Pipeline" class="section">
        <${Tu} />
        <${Cu} />
      <//>

      ${qt.value&&De.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:Ys.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${ss} horizon="short" items=${t.short??[]} />
              <${ss} horizon="mid" items=${t.mid??[]} />
              <${ss} horizon="long" items=${t.long??[]} />
            `}

      <${h} title="MDAL Loops" class="section">
        ${Wt.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&a==="error"?o`
                <div class="empty-state">
                  MDAL snapshot could not be loaded right now. Check the backend tool contract or runtime health.
                </div>
              `:e.length===0&&a==="idle"?o`
                <div class="empty-state">
                  No loop is running right now. This section wakes up when <code>masc_mdal_start</code> exposes a live loop.
                </div>
              `:e.length===0?o`
                  <div class="empty-state">
                    No loop snapshot is visible yet. Refresh once the backend has reported a planning loop.
                  </div>
                `:o`
                <div class="planning-loop-list">
                  ${e.map(r=>o`<${Nu} key=${r.loop_id} loop=${r} />`)}
                </div>
              `}
      <//>
    </div>
  `}const Bt=f(""),as=f("ability_check"),is=f("10"),os=f("12"),Ze=f(""),tn=f("idle"),ht=f(""),en=f("keeper-late"),rs=f("player"),ls=f(""),Y=f("idle"),cs=f(null),nn=f(""),us=f(""),ds=f("player"),ps=f(""),vs=f(""),ms=f(""),we=f("20"),fs=f("20"),_s=f(""),sn=f("idle"),Qs=f(null),vo=f("overview"),gs=f("all"),$s=f("all"),hs=f("all"),Lu=12e4,Kn=f(null),oi=f(Date.now());function Iu(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Du(t,e){return e>0?Math.round(t/e*100):0}const Eu={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Pu={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function an(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Mu(t){const e=t.trim().toLowerCase();return Eu[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Ou(t){const e=t.trim().toLowerCase();return Pu[e]??"상황에 따라 선택되는 전술 액션입니다."}function kt(t){return typeof t=="object"&&t!==null}function W(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function rt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function je(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const ju=new Set(["str","dex","con","int","wis","cha"]);function Fu(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!kt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const r=a.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){s[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const l=Number.parseFloat(i.trim());if(Number.isFinite(l)){s[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function zu(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(we.value.trim(),10);Number.isFinite(s)&&s>n&&(we.value=String(n))}function Xs(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Hu(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Uu(t){vo.value=t}function mo(t){const e=Kn.value;return e==null||e<=t}function Ku(t){const e=Kn.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Dn(){Kn.value=null}function fo(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Bu(t,e){fo(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Kn.value=Date.now()+Lu,y("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function vn(t){return mo(t)?(y("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Zs(t,e,n){return fo([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function qu({hp:t,max:e}){const n=Du(t,e),s=Iu(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Wu({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Gu({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function _o({actor:t}){var d,c,v,u;const e=(d=t.archetype)==null?void 0:d.trim(),n=(c=t.persona)==null?void 0:c.trim(),s=(v=t.portrait)==null?void 0:v.trim(),a=(u=t.background)==null?void 0:u.trim(),i=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([p,m])=>Number.isFinite(m)).filter(([p])=>!ju.has(p.toLowerCase()));return o`
    <div class="trpg-actor">
      ${s?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${p=>{const m=p.target;m&&(m.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${it} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Gu} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${qu} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Wu} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${an(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([p,m])=>o`
                <span class="trpg-custom-stat-chip">${an(p)} ${m}</span>
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
                  <span class="trpg-annot-name">${an(p)}</span>
                  <span class="trpg-annot-desc">${Mu(p)}</span>
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
                  <span class="trpg-annot-name">${an(p)}</span>
                  <span class="trpg-annot-desc">${Ou(p)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Ju({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function go({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Hu(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Xs(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${O} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Vu({events:t}){const e="__none__",n=gs.value,s=$s.value,a=hs.value,i=Array.from(new Set(t.map(Xs).map(u=>u.trim()).filter(u=>u!==""))).sort((u,p)=>u.localeCompare(p)),r=Array.from(new Set(t.map(u=>(u.type??"").trim()).filter(u=>u!==""))).sort((u,p)=>u.localeCompare(p)),l=t.some(u=>(u.type??"").trim()===""),d=Array.from(new Set(t.map(u=>(u.phase??"").trim()).filter(u=>u!==""))).sort((u,p)=>u.localeCompare(p)),c=t.some(u=>(u.phase??"").trim()===""),v=t.filter(u=>{if(n!=="all"&&Xs(u)!==n)return!1;const p=(u.type??"").trim(),m=(u.phase??"").trim();if(s===e){if(p!=="")return!1}else if(s!=="all"&&p!==s)return!1;if(a===e){if(m!=="")return!1}else if(a!=="all"&&m!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${u=>{gs.value=u.target.value}}>
          <option value="all">all</option>
          ${i.map(u=>o`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${u=>{$s.value=u.target.value}}>
          <option value="all">all</option>
          ${l?o`<option value=${e}>(none)</option>`:null}
          ${r.map(u=>o`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${u=>{hs.value=u.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${e}>(none)</option>`:null}
          ${d.map(u=>o`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{gs.value="all",$s.value="all",hs.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${v.length} / 전체 ${t.length}
      </span>
    </div>
    <${go} events=${v.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Yu({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function $o({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function Qu({state:t,nowMs:e}){var c;const n=vt.value||((c=t.session)==null?void 0:c.room)||"",s=tn.value,a=t.party??[];if(!a.find(v=>v.id===Bt.value)&&a.length>0){const v=a[0];v&&(Bt.value=v.id)}const r=async()=>{var u,p;if(!n){y("Room ID가 비어 있습니다.","error");return}if(!vn(e))return;const v=((u=t.current_round)==null?void 0:u.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(Zs("라운드 실행",n,v)){tn.value="running";try{const m=await Qr(n);Qs.value=m,tn.value="ok";const g=kt(m.summary)?m.summary:null,k=g?je(g,"advanced",!1):!1,N=g?W(g,"progress_reason",""):"";y(k?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${N?`: ${N}`:""}`,k?"success":"warning"),mt()}catch(m){Qs.value=null,tn.value="error";const g=m instanceof Error?m.message:"라운드 실행에 실패했습니다.";y(g,"error")}finally{Dn()}}},l=async()=>{var u,p;if(!n||!vn(e))return;const v=((u=t.current_round)==null?void 0:u.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(Zs("턴 강제 진행",n,v))try{await tl(n),y("턴을 다음 단계로 이동했습니다.","success"),mt()}catch{y("턴 이동에 실패했습니다.","error")}finally{Dn()}},d=async()=>{if(!n||!vn(e))return;const v=Bt.value.trim();if(!v){y("먼저 Actor를 선택하세요.","warning");return}const u=Number.parseInt(is.value,10),p=Number.parseInt(os.value,10);if(Number.isNaN(u)||Number.isNaN(p)){y("stat/dc는 숫자여야 합니다.","warning");return}const m=Number.parseInt(Ze.value,10),g=Ze.value.trim()===""||Number.isNaN(m)?void 0:m;try{await Zr({roomId:n,actorId:v,action:as.value.trim()||"ability_check",statValue:u,dc:p,rawD20:g}),y("주사위 판정을 기록했습니다.","success"),mt()}catch{y("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${v=>{vt.value=v.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Bt.value}
            onChange=${v=>{Bt.value=v.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(v=>o`<option value=${v.id}>${v.name} (${v.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${as.value}
              onInput=${v=>{as.value=v.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${is.value}
              onInput=${v=>{is.value=v.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${os.value}
              onInput=${v=>{os.value=v.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Ze.value}
              onInput=${v=>{Ze.value=v.target.value}}
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
              disabled=${s==="running"}
            >
              ${s==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${l}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${s!=="idle"?o`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function Xu({state:t}){var a;const e=vt.value||((a=t.session)==null?void 0:a.room)||"",n=sn.value,s=async()=>{if(!e){y("Room ID가 비어 있습니다.","warning");return}const i=nn.value.trim(),r=us.value.trim();if(!r&&!i){y("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt(we.value.trim(),10),d=Number.parseInt(fs.value.trim(),10),c=Number.isFinite(d)?Math.max(1,d):20,v=Number.isFinite(l)?Math.max(0,Math.min(c,l)):c;let u={};try{u=Fu(_s.value)}catch(p){y(p instanceof Error?p.message:"능력치 JSON 오류","error");return}sn.value="spawning";try{const p=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,m=await el(e,{actor_id:i||void 0,name:r||void 0,role:ds.value,idempotencyKey:p,portrait:vs.value.trim()||void 0,background:ms.value.trim()||void 0,hp:v,max_hp:c,alive:v>0,stats:Object.keys(u).length>0?u:void 0}),g=typeof m.actor_id=="string"?m.actor_id.trim():"";if(!g)throw new Error("생성 응답에 actor_id가 없습니다.");const k=ps.value.trim();k&&await nl(e,g,k),Bt.value=g,ht.value=g,i||(nn.value=""),sn.value="ok",y(`Actor 생성 완료: ${g}`,"success"),await mt()}catch(p){sn.value="error",y(p instanceof Error?p.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${us.value}
            onInput=${i=>{us.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ds.value}
            onChange=${i=>{ds.value=i.target.value}}
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
            value=${ps.value}
            onInput=${i=>{ps.value=i.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn recommend" onClick=${s} disabled=${n==="spawning"}>
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
              value=${nn.value}
              onInput=${i=>{nn.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${vs.value}
              onInput=${i=>{vs.value=i.target.value}}
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
              value=${we.value}
              onInput=${i=>{we.value=i.target.value}}
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
              value=${fs.value}
              onInput=${i=>{const r=i.target.value;fs.value=r,zu(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ms.value}
              onInput=${i=>{ms.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${_s.value}
              onInput=${i=>{_s.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Zu({state:t,nowMs:e}){var p;const n=vt.value||((p=t.session)==null?void 0:p.room)||"",s=t.join_gate,a=cs.value,i=kt(a)?a:null,r=(t.party??[]).filter(m=>m.role!=="dm"),l=ht.value.trim(),d=r.some(m=>m.id===l),c=d?l:l?"__manual__":"",v=async()=>{const m=ht.value.trim(),g=en.value.trim();if(!n||!m){y("Room/Actor가 필요합니다.","warning");return}Y.value="checking";try{const k=await sl(n,m,g||void 0);cs.value=k,Y.value="ok",y("참가 가능 여부를 갱신했습니다.","success")}catch(k){Y.value="error";const N=k instanceof Error?k.message:"참가 가능 여부 확인에 실패했습니다.";y(N,"error")}},u=async()=>{var L,A;const m=ht.value.trim(),g=en.value.trim(),k=ls.value.trim();if(!n||!m||!g){y("Room/Actor/Keeper가 필요합니다.","warning");return}if(!vn(e))return;const N=((L=t.current_round)==null?void 0:L.phase)??((A=t.session)==null?void 0:A.status)??"unknown";if(Zs("Mid-Join 승인 요청",n,N)){Y.value="requesting";try{const P=await al({room_id:n,actor_id:m,keeper_name:g,role:rs.value,...k?{name:k}:{}});cs.value=P;const x=kt(P)?je(P,"granted",!1):!1,R=kt(P)?W(P,"reason_code",""):"";x?y("Mid-Join이 승인되었습니다.","success"):y(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),Y.value=x?"ok":"error",mt()}catch(P){Y.value="error";const x=P instanceof Error?P.message:"Mid-Join 요청에 실패했습니다.";y(x,"error")}finally{Dn()}}};return o`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${s!=null&&s.phase_open?"OPEN":"CLOSED"}</strong>
        ${s!=null&&s.window?o`<span style="margin-left:8px;">(${s.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(s==null?void 0:s.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
            value=${c}
            onChange=${m=>{const g=m.target.value;if(g==="__manual__"){(d||!l)&&(ht.value="");return}ht.value=g}}
          >
            <option value="">Actor 선택</option>
            ${r.map(m=>o`
              <option value=${m.id}>${m.name} (${m.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${c==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${ht.value}
                onInput=${m=>{ht.value=m.target.value}}
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
            value=${en.value}
            onInput=${m=>{en.value=m.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${rs.value}
            onChange=${m=>{rs.value=m.target.value}}
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
            value=${ls.value}
            onInput=${m=>{ls.value=m.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${v} disabled=${Y.value==="checking"||Y.value==="requesting"}>
              ${Y.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${u} disabled=${Y.value==="checking"||Y.value==="requesting"}>
              ${Y.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${je(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${rt(i,"effective_score",0)}/${rt(i,"required_points",0)}</span>
            ${W(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${W(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function ho({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function yo({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function bo(){const t=Qs.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=kt(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(kt).slice(-8),i=t.canon_check,r=kt(i)?i:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(R=>typeof R=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(R=>typeof R=="string").slice(0,3):[],c=n?je(n,"advanced",!1):!1,v=n?W(n,"progress_reason",""):"",u=n?W(n,"progress_detail",""):"",p=n?rt(n,"player_successes",0):0,m=n?rt(n,"player_required_successes",0):0,g=n?je(n,"dm_success",!1):!1,k=n?rt(n,"timeouts",0):0,N=n?rt(n,"unavailable",0):0,L=n?rt(n,"reprompts",0):0,A=n?rt(n,"npc_attacks",0):0,P=n?rt(n,"keeper_timeout_sec",0):0,x=n?rt(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${c?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${c?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${g?"DM ok":"DM stalled"} / players ${p}/${m}
          </span>
        </div>
        ${v?o`<div style="margin-top:4px; font-size:12px;">${v}</div>`:null}
        ${u?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${u}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${N}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${L}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${P||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${x}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(R=>{const Q=W(R,"status","unknown"),At=W(R,"actor_id","-"),Ct=W(R,"role","-"),X=W(R,"reason",""),dt=W(R,"action_type",""),D=W(R,"reply","");return o`
                <div class="trpg-round-item ${Q.includes("fallback")||Q.includes("timeout")?"failed":"active"}">
                  <span>${At} (${Ct})</span>
                  <span style="margin-left:auto; font-size:11px;">${Q}</span>
                  ${dt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${dt}</div>`:null}
                  ${X?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${X}</div>`:null}
                  ${D?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${D.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${W(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(R=>o`<div>violation: ${R}</div>`)}
                </div>`:null}
            ${l.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(R=>o`<div>warning: ${R}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function td({state:t,nowMs:e}){var r,l,d;const n=vt.value||((r=t.session)==null?void 0:r.room)||"",s=((l=t.current_round)==null?void 0:l.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=mo(e),i=Ku(e);return o`
    <${h} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>Bu(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Dn(),y("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function ed({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Uu(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function nd({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${h} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${h} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${go} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${h} title="맵" style="margin-top:16px;">
              <${Ju} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${h} title="현재 라운드">
          <${yo} state=${t} />
        <//>

        <${h} title="기여도" style="margin-top:16px;">
          <${ho} state=${t} />
        <//>

        <${h} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${_o} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${h} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${$o} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function sd({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${h} title=${`이벤트 타임라인 (${e.length})`}>
          <${Vu} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${h} title="최근 라운드 결과">
          <${bo} />
        <//>

        <${h} title="현재 라운드" style="margin-top:16px;">
          <${yo} state=${t} />
        <//>
      </div>
    </div>
  `}function ad({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${td} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${h} title="조작 패널">
            <${Qu} state=${t} nowMs=${e} />
          <//>

          <${h} title="Actor Spawn" style="margin-top:16px;">
            <${Xu} state=${t} />
          <//>

          <${h} title="Mid-Join Gate" style="margin-top:16px;">
            <${Zu} state=${t} nowMs=${e} />
          <//>

          <${h} title="최근 라운드 결과" style="margin-top:16px;">
            <${bo} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${h} title="기여도" style="margin-top:0;">
            <${ho} state=${t} />
          <//>

          <${h} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${_o} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${h} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${$o} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function id(){var l,d,c,v,u;const t=Qi.value,e=Ps.value;if(xt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const p=window.setInterval(()=>{oi.value=Date.now()},1e3);return()=>{window.clearInterval(p)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>mt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=vo.value,r=oi.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${vt.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((c=t.session)==null?void 0:c.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>mt()}>새로고침</button>
      </div>

      <${Yu} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((v=t.session)==null?void 0:v.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((u=t.current_round)==null?void 0:u.round_number)??0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${n.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Events</div>
          <div class="stat-value">${s.length}</div>
        </div>
      </div>

      <${ed} active=${i} />

      ${i==="overview"?o`<${nd} state=${t} />`:i==="timeline"?o`<${sd} state=${t} />`:o`<${ad} state=${t} nowMs=${r} />`}
    </div>
  `}const _a="masc_dashboard_agent_name";function od(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(_a);return e??n??"dashboard"}const st=f(od()),Se=f(""),Ae=f(""),En=f(""),Ce=f(!1),Gt=f(!1),Te=f(!1),Ne=f(!1),Pn=f(!1),Bn=f(!1);function ga(t){const e=t.trim();st.value=e,e&&localStorage.setItem(_a,e)}function rd(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function ta(){const t=st.value.trim();if(t){Te.value=!0;try{const e=await ol(t),n=rd(e);n&&ga(n),Bn.value=!0,y(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";y(n,"error")}finally{Te.value=!1}}}async function ld(){const t=st.value.trim();if(t){Ne.value=!0;try{await Yi(t),Bn.value=!1,y(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";y(n,"error")}finally{Ne.value=!1}}}async function cd(){const t=st.value.trim();if(t)try{await Yi(t)}catch{}localStorage.removeItem(_a),ga("dashboard"),Bn.value=!1,await ta()}async function ud(){const t=st.value.trim();if(t){Pn.value=!0;try{await rl(t),y("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";y(n,"error")}finally{Pn.value=!1}}}async function ri(){const t=st.value.trim(),e=Se.value.trim();if(!(!t||!e)){Ce.value=!0;try{await Vi(t,e),Se.value="",y("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";y(s,"error")}finally{Ce.value=!1}}}async function dd(){const t=Ae.value.trim(),e=En.value.trim()||"Created from dashboard";if(t){Gt.value=!0;try{await il(t,e,1),Ae.value="",En.value="",y("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";y(s,"error")}finally{Gt.value=!1}}}function pd(){return xt(()=>{ta()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${st.value}
        onInput=${t=>ga(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${Se.value}
          onInput=${t=>{Se.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&ri()}}
          disabled=${Ce.value}
        />
        <button
          class="control-btn"
          onClick=${ri}
          disabled=${Ce.value||Se.value.trim()===""||st.value.trim()===""}
        >
          ${Ce.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{ta()}}
          disabled=${Te.value||st.value.trim()===""}
        >
          ${Te.value?"Joining...":Bn.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{ld()}}
          disabled=${Ne.value||st.value.trim()===""}
        >
          ${Ne.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{cd()}}
          disabled=${Te.value||Ne.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{ud()}}
          disabled=${Pn.value||st.value.trim()===""}
        >
          ${Pn.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${Ae.value}
        onInput=${t=>{Ae.value=t.target.value}}
        disabled=${Gt.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${En.value}
        onInput=${t=>{En.value=t.target.value}}
        disabled=${Gt.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${dd}
        disabled=${Gt.value||Ae.value.trim()===""}
      >
        ${Gt.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}const ko={overview:"Room health, keeper pressure, and top-line execution status",board:"Human and agent discussion feed with system noise filtered by default",activity:"Unified live stream for messages, task changes, board events, and keeper events",council:"Debates, quorum status, and decision flow",goals:"Goals and MDAL loops in one planning surface with freshness signals",execution:"Queue readiness and assignee coverage",tasks:"Kanban-style task distribution",agents:"Live monitor for agent status, keeper pressure, and current execution focus",ops:"Guided operator controls for room, sessions, and keepers",trpg:"Narrative room control and state visibility"};function vd(){const t=wt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${zn.value} events</span>
    </div>
  `}function md(){const t=at.value.tab,e=wt.value,n=Ts.find(s=>s.id===t);return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${Ts.map(s=>o`
            <button
              class="rail-tab-btn ${t===s.id?"active":""}"
              onClick=${()=>Fn(s.id)}
            >
              ${s.icon} ${s.label}
            </button>
          `)}
        </div>
        <div class="rail-view-note">
          <div class="rail-view-note-label">Current focus</div>
          <strong>${(n==null?void 0:n.label)??t}</strong>
          <p>${ko[t]??"Live operational view"}</p>
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
            <strong>${Pt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${ut.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${gt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${zn.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Hn(),t==="ops"&&te(),t==="board"&&ct(),t==="trpg"&&mt(),t==="goals"&&(pe(),ve())}}
        >
          Refresh Now
        </button>
      </section>

      <${pd} />
    </aside>
  `}function fd(){switch(at.value.tab){case"overview":return o`<${Wa} />`;case"ops":return o`<${Sc} />`;case"council":return o`<${Rc} />`;case"board":return o`<${Hc} />`;case"execution":return o`<${bu} />`;case"activity":return o`<${ou} />`;case"agents":return o`<${$u} />`;case"tasks":return o`<${hu} />`;case"goals":return o`<${Ru} />`;case"trpg":return o`<${id} />`;default:return o`<${Wa} />`}}function _d(){xt(()=>{or(),Ui(),Hn(),ct();const e=Rl();return Ll(),()=>{fr(),e(),Il()}},[]),xt(()=>{const e=at.value.tab;e==="ops"&&te(),e==="board"&&ct(),e==="trpg"&&mt(),e==="goals"&&(pe(),ve())},[at.value.tab]);const t=at.value.tab;return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${ko[t]??"Decision and execution operations console"}</p>
        </div>
        <div class="header-right">
          <${vd} />
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${rr} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${Es.value&&!wt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${fd} />`}
        </main>
        <${md} />
      </div>

      <${Wl} />
      <${tc} />
      <${Vl} />
    </div>
  `}const li=document.getElementById("app");li&&Uo(o`<${_d} />`,li);
