var xr=Object.defineProperty;var wr=(t,e,n)=>e in t?xr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Gt=(t,e,n)=>wr(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var es,I,Ki,Hi,Ot,Va,Ui,Bi,Wi,Ta,zs,qs,Ke={},Gi=[],Sr=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,ns=Array.isArray;function gt(t,e){for(var n in e)t[n]=e[n];return t}function Ca(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function Ji(t,e,n){var s,a,i,r={};for(i in e)i=="key"?s=e[i]:i=="ref"?a=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?es.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return $n(t,r,s,a,null)}function $n(t,e,n,s,a){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++Ki,__i:-1,__u:0};return a==null&&I.vnode!=null&&I.vnode(i),i}function Qe(t){return t.children}function ye(t,e){this.props=t,this.context=e}function oe(t,e){if(e==null)return t.__?oe(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?oe(t):null}function Vi(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return Vi(t)}}function Ya(t){(!t.__d&&(t.__d=!0)&&Ot.push(t)&&!Cn.__r++||Va!=I.debounceRendering)&&((Va=I.debounceRendering)||Ui)(Cn)}function Cn(){for(var t,e,n,s,a,i,r,l=1;Ot.length;)Ot.length>l&&Ot.sort(Bi),t=Ot.shift(),l=Ot.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,i=[],r=[],e.__P&&((n=gt({},s)).__v=s.__v+1,I.vnode&&I.vnode(n),Na(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,i,a??oe(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,Xi(i,n,r),s.__e=s.__=null,n.__e!=a&&Vi(n)));Cn.__r=0}function Yi(t,e,n,s,a,i,r,l,u,c,p){var d,v,f,g,k,x,R,A=s&&s.__k||Gi,P=e.length;for(u=Ar(n,e,A,u,P),d=0;d<P;d++)(f=n.__k[d])!=null&&(v=f.__i==-1?Ke:A[f.__i]||Ke,f.__i=d,x=Na(t,f,v,a,i,r,l,u,c,p),g=f.__e,f.ref&&v.ref!=f.ref&&(v.ref&&Ra(v.ref,null,f),p.push(f.ref,f.__c||g,f)),k==null&&g!=null&&(k=g),(R=!!(4&f.__u))||v.__k===f.__k?u=Qi(f,u,t,R):typeof f.type=="function"&&x!==void 0?u=x:g&&(u=g.nextSibling),f.__u&=-7);return n.__e=k,u}function Ar(t,e,n,s,a){var i,r,l,u,c,p=n.length,d=p,v=0;for(t.__k=new Array(a),i=0;i<a;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=$n(null,r,null,null,null):ns(r)?r=t.__k[i]=$n(Qe,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=$n(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,u=i+v,r.__=t,r.__b=t.__b+1,l=null,(c=r.__i=Tr(r,n,u,d))!=-1&&(d--,(l=n[c])&&(l.__u|=2)),l==null||l.__v==null?(c==-1&&(a>p?v--:a<p&&v++),typeof r.type!="function"&&(r.__u|=4)):c!=u&&(c==u-1?v--:c==u+1?v++:(c>u?v--:v++,r.__u|=4))):t.__k[i]=null;if(d)for(i=0;i<p;i++)(l=n[i])!=null&&(2&l.__u)==0&&(l.__e==s&&(s=oe(l)),to(l,l));return s}function Qi(t,e,n,s){var a,i;if(typeof t.type=="function"){for(a=t.__k,i=0;a&&i<a.length;i++)a[i]&&(a[i].__=t,e=Qi(a[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=oe(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Tr(t,e,n,s){var a,i,r,l=t.key,u=t.type,c=e[n],p=c!=null&&(2&c.__u)==0;if(c===null&&l==null||p&&l==c.key&&u==c.type)return n;if(s>(p?1:0)){for(a=n-1,i=n+1;a>=0||i<e.length;)if((c=e[r=a>=0?a--:i++])!=null&&(2&c.__u)==0&&l==c.key&&u==c.type)return r}return-1}function Qa(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Sr.test(e)?n:n+"px"}function on(t,e,n,s,a){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||Qa(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||Qa(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Wi,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=Ta,t.addEventListener(e,i?qs:zs,i)):t.removeEventListener(e,i?qs:zs,i);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Xa(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Ta++;else if(e.t<n.u)return;return n(I.event?I.event(e):e)}}}function Na(t,e,n,s,a,i,r,l,u,c){var p,d,v,f,g,k,x,R,A,P,S,L,nt,Et,It,st,_t,E=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(u=!!(32&n.__u),i=[l=e.__e=n.__e]),(p=I.__b)&&p(e);t:if(typeof E=="function")try{if(R=e.props,A="prototype"in E&&E.prototype.render,P=(p=E.contextType)&&s[p.__c],S=p?P?P.props.value:p.__:s,n.__c?x=(d=e.__c=n.__c).__=d.__E:(A?e.__c=d=new E(R,S):(e.__c=d=new ye(R,S),d.constructor=E,d.render=Nr),P&&P.sub(d),d.state||(d.state={}),d.__n=s,v=d.__d=!0,d.__h=[],d._sb=[]),A&&d.__s==null&&(d.__s=d.state),A&&E.getDerivedStateFromProps!=null&&(d.__s==d.state&&(d.__s=gt({},d.__s)),gt(d.__s,E.getDerivedStateFromProps(R,d.__s))),f=d.props,g=d.state,d.__v=e,v)A&&E.getDerivedStateFromProps==null&&d.componentWillMount!=null&&d.componentWillMount(),A&&d.componentDidMount!=null&&d.__h.push(d.componentDidMount);else{if(A&&E.getDerivedStateFromProps==null&&R!==f&&d.componentWillReceiveProps!=null&&d.componentWillReceiveProps(R,S),e.__v==n.__v||!d.__e&&d.shouldComponentUpdate!=null&&d.shouldComponentUpdate(R,d.__s,S)===!1){for(e.__v!=n.__v&&(d.props=R,d.state=d.__s,d.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(K){K&&(K.__=e)}),L=0;L<d._sb.length;L++)d.__h.push(d._sb[L]);d._sb=[],d.__h.length&&r.push(d);break t}d.componentWillUpdate!=null&&d.componentWillUpdate(R,d.__s,S),A&&d.componentDidUpdate!=null&&d.__h.push(function(){d.componentDidUpdate(f,g,k)})}if(d.context=S,d.props=R,d.__P=t,d.__e=!1,nt=I.__r,Et=0,A){for(d.state=d.__s,d.__d=!1,nt&&nt(e),p=d.render(d.props,d.state,d.context),It=0;It<d._sb.length;It++)d.__h.push(d._sb[It]);d._sb=[]}else do d.__d=!1,nt&&nt(e),p=d.render(d.props,d.state,d.context),d.state=d.__s;while(d.__d&&++Et<25);d.state=d.__s,d.getChildContext!=null&&(s=gt(gt({},s),d.getChildContext())),A&&!v&&d.getSnapshotBeforeUpdate!=null&&(k=d.getSnapshotBeforeUpdate(f,g)),st=p,p!=null&&p.type===Qe&&p.key==null&&(st=Zi(p.props.children)),l=Yi(t,ns(st)?st:[st],e,n,s,a,i,r,l,u,c),d.base=e.__e,e.__u&=-161,d.__h.length&&r.push(d),x&&(d.__E=d.__=null)}catch(K){if(e.__v=null,u||i!=null)if(K.then){for(e.__u|=u?160:128;l&&l.nodeType==8&&l.nextSibling;)l=l.nextSibling;i[i.indexOf(l)]=null,e.__e=l}else{for(_t=i.length;_t--;)Ca(i[_t]);Ks(e)}else e.__e=n.__e,e.__k=n.__k,K.then||Ks(e);I.__e(K,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):l=e.__e=Cr(n.__e,e,n,s,a,i,r,u,c);return(p=I.diffed)&&p(e),128&e.__u?void 0:l}function Ks(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(Ks)}function Xi(t,e,n){for(var s=0;s<n.length;s++)Ra(n[s],n[++s],n[++s]);I.__c&&I.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(i){i.call(a)})}catch(i){I.__e(i,a.__v)}})}function Zi(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:ns(t)?t.map(Zi):gt({},t)}function Cr(t,e,n,s,a,i,r,l,u){var c,p,d,v,f,g,k,x=n.props||Ke,R=e.props,A=e.type;if(A=="svg"?a="http://www.w3.org/2000/svg":A=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),i!=null){for(c=0;c<i.length;c++)if((f=i[c])&&"setAttribute"in f==!!A&&(A?f.localName==A:f.nodeType==3)){t=f,i[c]=null;break}}if(t==null){if(A==null)return document.createTextNode(R);t=document.createElementNS(a,A,R.is&&R),l&&(I.__m&&I.__m(e,i),l=!1),i=null}if(A==null)x===R||l&&t.data==R||(t.data=R);else{if(i=i&&es.call(t.childNodes),!l&&i!=null)for(x={},c=0;c<t.attributes.length;c++)x[(f=t.attributes[c]).name]=f.value;for(c in x)if(f=x[c],c!="children"){if(c=="dangerouslySetInnerHTML")d=f;else if(!(c in R)){if(c=="value"&&"defaultValue"in R||c=="checked"&&"defaultChecked"in R)continue;on(t,c,null,f,a)}}for(c in R)f=R[c],c=="children"?v=f:c=="dangerouslySetInnerHTML"?p=f:c=="value"?g=f:c=="checked"?k=f:l&&typeof f!="function"||x[c]===f||on(t,c,f,x[c],a);if(p)l||d&&(p.__html==d.__html||p.__html==t.innerHTML)||(t.innerHTML=p.__html),e.__k=[];else if(d&&(t.innerHTML=""),Yi(e.type=="template"?t.content:t,ns(v)?v:[v],e,n,s,A=="foreignObject"?"http://www.w3.org/1999/xhtml":a,i,r,i?i[0]:n.__k&&oe(n,0),l,u),i!=null)for(c=i.length;c--;)Ca(i[c]);l||(c="value",A=="progress"&&g==null?t.removeAttribute("value"):g!=null&&(g!==t[c]||A=="progress"&&!g||A=="option"&&g!=x[c])&&on(t,c,g,x[c],a),c="checked",k!=null&&k!=t[c]&&on(t,c,k,x[c],a))}return t}function Ra(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){I.__e(a,n)}}function to(t,e,n){var s,a;if(I.unmount&&I.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||Ra(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){I.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&to(s[a],e,n||typeof t.type!="function");n||Ca(t.__e),t.__c=t.__=t.__e=void 0}function Nr(t,e,n){return this.constructor(t,n)}function Rr(t,e,n){var s,a,i,r;e==document&&(e=document.documentElement),I.__&&I.__(t,e),a=(s=!1)?null:e.__k,i=[],r=[],Na(e,t=e.__k=Ji(Qe,null,[t]),a||Ke,Ke,e.namespaceURI,a?null:e.firstChild?es.call(e.childNodes):null,i,a?a.__e:e.firstChild,s,r),Xi(i,t,r)}es=Gi.slice,I={__e:function(t,e,n,s){for(var a,i,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((i=a.constructor)&&i.getDerivedStateFromError!=null&&(a.setState(i.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(l){t=l}throw t}},Ki=0,Hi=function(t){return t!=null&&t.constructor===void 0},ye.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=gt({},this.state),typeof t=="function"&&(t=t(gt({},n),this.props)),t&&gt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),Ya(this))},ye.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),Ya(this))},ye.prototype.render=Qe,Ot=[],Ui=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Bi=function(t,e){return t.__v.__b-e.__v.__b},Cn.__r=0,Wi=/(PointerCapture)$|Capture$/i,Ta=0,zs=Xa(!1),qs=Xa(!0);var eo=function(t,e,n,s){var a;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],l=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?s[0]=l:r===4?s[1]=Object.assign(s[1]||{},l):r===5?(s[1]=s[1]||{})[e[++i]]=l:r===6?s[1][e[++i]]+=l+"":r?(a=t.apply(l,eo(t,l,n,["",null])),s.push(a),l[0]?e[0]|=2:(e[i-2]=0,e[i]=a)):s.push(l)}return s},Za=new Map;function Lr(t){var e=Za.get(this);return e||(e=new Map,Za.set(this,e)),(e=eo(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,i=1,r="",l="",u=[0],c=function(v){i===1&&(v||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?u.push(0,v,r):i===3&&(v||r)?(u.push(3,v,r),i=2):i===2&&r==="..."&&v?u.push(4,v,0):i===2&&r&&!v?u.push(5,0,!0,r):i>=5&&((r||!v&&i===5)&&(u.push(i,0,r,a),i=6),v&&(u.push(i,v,0,a),i=6)),r=""},p=0;p<n.length;p++){p&&(i===1&&c(),c(p));for(var d=0;d<n[p].length;d++)s=n[p][d],i===1?s==="<"?(c(),u=[u],i=3):r+=s:i===4?r==="--"&&s===">"?(i=1,r=""):r=s+r[0]:l?s===l?l="":r+=s:s==='"'||s==="'"?l=s:s===">"?(c(),i=1):i&&(s==="="?(i=5,a=r,r=""):s==="/"&&(i<5||n[p][d+1]===">")?(c(),i===3&&(u=u[0]),i=u,(u=u[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(c(),i=2):r+=s),i===3&&r==="!--"&&(i=4,u=u[0])}return c(),u})(t)),e),arguments,[])).length>1?e:e[0]}var o=Lr.bind(Ji),He,z,us,ti,Hs=0,no=[],q=I,ei=q.__b,ni=q.__r,si=q.diffed,ai=q.__c,ii=q.unmount,oi=q.__;function La(t,e){q.__h&&q.__h(z,t,Hs||e),Hs=0;var n=z.__H||(z.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function Dr(t){return Hs=1,Pr(io,t)}function Pr(t,e,n){var s=La(He++,2);if(s.t=t,!s.__c&&(s.__=[io(void 0,e),function(l){var u=s.__N?s.__N[0]:s.__[0],c=s.t(u,l);u!==c&&(s.__N=[c,s.__[1]],s.__c.setState({}))}],s.__c=z,!z.__f)){var a=function(l,u,c){if(!s.__c.__H)return!0;var p=s.__c.__H.__.filter(function(v){return!!v.__c});if(p.every(function(v){return!v.__N}))return!i||i.call(this,l,u,c);var d=s.__c.props!==l;return p.forEach(function(v){if(v.__N){var f=v.__[0];v.__=v.__N,v.__N=void 0,f!==v.__[0]&&(d=!0)}}),i&&i.call(this,l,u,c)||d};z.__f=!0;var i=z.shouldComponentUpdate,r=z.componentWillUpdate;z.componentWillUpdate=function(l,u,c){if(this.__e){var p=i;i=void 0,a(l,u,c),i=p}r&&r.call(this,l,u,c)},z.shouldComponentUpdate=a}return s.__N||s.__}function ft(t,e){var n=La(He++,3);!q.__s&&ao(n.__H,e)&&(n.__=t,n.u=e,z.__H.__h.push(n))}function so(t,e){var n=La(He++,7);return ao(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Er(){for(var t;t=no.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(hn),t.__H.__h.forEach(Us),t.__H.__h=[]}catch(e){t.__H.__h=[],q.__e(e,t.__v)}}q.__b=function(t){z=null,ei&&ei(t)},q.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),oi&&oi(t,e)},q.__r=function(t){ni&&ni(t),He=0;var e=(z=t.__c).__H;e&&(us===z?(e.__h=[],z.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(hn),e.__h.forEach(Us),e.__h=[],He=0)),us=z},q.diffed=function(t){si&&si(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(no.push(e)!==1&&ti===q.requestAnimationFrame||((ti=q.requestAnimationFrame)||Ir)(Er)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),us=z=null},q.__c=function(t,e){e.some(function(n){try{n.__h.forEach(hn),n.__h=n.__h.filter(function(s){return!s.__||Us(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],q.__e(s,n.__v)}}),ai&&ai(t,e)},q.unmount=function(t){ii&&ii(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{hn(s)}catch(a){e=a}}),n.__H=void 0,e&&q.__e(e,n.__v))};var ri=typeof requestAnimationFrame=="function";function Ir(t){var e,n=function(){clearTimeout(s),ri&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);ri&&(e=requestAnimationFrame(n))}function hn(t){var e=z,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),z=e}function Us(t){var e=z;t.__c=t.__(),z=e}function ao(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}function io(t,e){return typeof e=="function"?e(t):e}var Mr=Symbol.for("preact-signals");function ss(){if(Nt>1)Nt--;else{for(var t,e=!1;be!==void 0;){var n=be;for(be=void 0,Bs++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&lo(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(Bs=0,Nt--,e)throw t}}function Or(t){if(Nt>0)return t();Nt++;try{return t()}finally{ss()}}var D=void 0;function oo(t){var e=D;D=void 0;try{return t()}finally{D=e}}var be=void 0,Nt=0,Bs=0,Nn=0;function ro(t){if(D!==void 0){var e=t.n;if(e===void 0||e.t!==D)return e={i:0,S:t,p:D.s,n:void 0,t:D,e:void 0,x:void 0,r:e},D.s!==void 0&&(D.s.n=e),D.s=e,t.n=e,32&D.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=D.s,e.n=void 0,D.s.n=e,D.s=e),e}}function H(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}H.prototype.brand=Mr;H.prototype.h=function(){return!0};H.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:oo(function(){var s;(s=e.W)==null||s.call(e)}))};H.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&oo(function(){var a;(a=e.Z)==null||a.call(e)}))}};H.prototype.subscribe=function(t){var e=this;return Xe(function(){var n=e.value,s=D;D=void 0;try{t(n)}finally{D=s}},{name:"sub"})};H.prototype.valueOf=function(){return this.value};H.prototype.toString=function(){return this.value+""};H.prototype.toJSON=function(){return this.value};H.prototype.peek=function(){var t=D;D=void 0;try{return this.value}finally{D=t}};Object.defineProperty(H.prototype,"value",{get:function(){var t=ro(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Bs>100)throw new Error("Cycle detected");this.v=t,this.i++,Nn++,Nt++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{ss()}}}});function m(t,e){return new H(t,e)}function lo(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function co(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function uo(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function Kt(t,e){H.call(this,void 0),this.x=t,this.s=void 0,this.g=Nn-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}Kt.prototype=new H;Kt.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===Nn))return!0;if(this.g=Nn,this.f|=1,this.i>0&&!lo(this))return this.f&=-2,!0;var t=D;try{co(this),D=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return D=t,uo(this),this.f&=-2,!0};Kt.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}H.prototype.S.call(this,t)};Kt.prototype.U=function(t){if(this.t!==void 0&&(H.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};Kt.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(Kt.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=ro(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function X(t,e){return new Kt(t,e)}function po(t){var e=t.u;if(t.u=void 0,typeof e=="function"){Nt++;var n=D;D=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,Da(t),s}finally{D=n,ss()}}}function Da(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,po(t)}function jr(t){if(D!==this)throw new Error("Out-of-order effect");uo(this),D=t,this.f&=-2,8&this.f&&Da(this),ss()}function de(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}de.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};de.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,po(this),co(this),Nt++;var t=D;return D=this,jr.bind(this,t)};de.prototype.N=function(){2&this.f||(this.f|=2,this.o=be,be=this)};de.prototype.d=function(){this.f|=8,1&this.f||Da(this)};de.prototype.dispose=function(){this.d()};function Xe(t,e){var n=new de(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var vo,rn,Fr=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,mo=[];Xe(function(){vo=this.N})();function pe(t,e){I[t]=e.bind(null,I[t]||function(){})}function Rn(t){if(rn){var e=rn;rn=void 0,e()}rn=t&&t.S()}function fo(t){var e=this,n=t.data,s=qr(n);s.value=n;var a=so(function(){for(var l=e,u=e.__v;u=u.__;)if(u.__c){u.__c.__$f|=4;break}var c=X(function(){var f=s.value.value;return f===0?0:f===!0?"":f||""}),p=X(function(){return!Array.isArray(c.value)&&!Hi(c.value)}),d=Xe(function(){if(this.N=_o,p.value){var f=c.value;l.__v&&l.__v.__e&&l.__v.__e.nodeType===3&&(l.__v.__e.data=f)}}),v=e.__$u.d;return e.__$u.d=function(){d(),v.call(this)},[p,c]},[]),i=a[0],r=a[1];return i.value?r.peek():r.value}fo.displayName="ReactiveTextNode";Object.defineProperties(H.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:fo},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});pe("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var i=s[a];i instanceof H&&(n||(e.__np=n={}),n[a]=i,s[a]=i.peek())}}t(e)});pe("__r",function(t,e){if(t(e),e.type!==Qe){Rn();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,i){var r;return Xe(function(){r=this},{name:i}),r.c=a,r})(function(){var a;Fr&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),Rn(n)}});pe("__e",function(t,e,n,s){Rn(),t(e,n,s)});pe("diffed",function(t,e){Rn();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var i=n.U;if(i)for(var r in i){var l=i[r];l!==void 0&&!(r in s)&&(l.d(),i[r]=void 0)}else i={},n.U=i;for(var u in s){var c=i[u],p=s[u];c===void 0?(c=zr(n,u,p),i[u]=c):c.o(p,a)}for(var d in s)a[d]=s[d]}}t(e)});function zr(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,i=m(n),r=n.peek();return{o:function(l,u){i.value=l,r=l.peek()},d:Xe(function(){this.N=_o;var l=i.value.value;r!==l?(r=void 0,a?t[e]=l:l!=null&&(l!==!1||e[4]==="-")?t.setAttribute(e,l):t.removeAttribute(e)):r=void 0})}}pe("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var i=s[a];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var l=r.__$u;l&&(r.__$u=void 0,l.d())}}t(e)});pe("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});ye.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var l in this.props)if(!(l in t))return!0;return!1};function qr(t,e){return so(function(){return m(t,e)},[])}var Kr=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Hr(){Or(function(){for(var t;t=mo.shift();)vo.call(t)})}function _o(){mo.push(this)===1&&(I.requestAnimationFrame||Kr)(Hr)}const Ur=["overview","board","activity","council","goals","execution","tasks","agents","ops","trpg"],go={tab:"overview",params:{},postId:null},Br={journal:"activity",mdal:"goals"};function li(t){return!!t&&Ur.includes(t)}function ci(t){if(t)return Br[t]??t}function Ws(t){try{return decodeURIComponent(t)}catch{return t}}function Gs(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Wr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function $o(t,e){const n=ci(t[0]),s=ci(e.tab),a=li(n)?n:li(s)?s:"overview";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Ws(t[2]):t[0]==="post"&&t[1]&&(i=Ws(t[1]))),{tab:a,params:e,postId:i}}function Ln(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return go;const n=Ws(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=Gs(a),r=Wr(s);return $o(r,i)}function Gr(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...go,params:Gs(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Gs(e.replace(/^\?/,""));return $o(s,a)}function ho(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const lt=m(Ln(window.location.hash));window.addEventListener("hashchange",()=>{lt.value=Ln(window.location.hash)});function as(t,e){const n={tab:t,params:{},postId:null};window.location.hash=ho(n)}function Jr(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Vr(){if(window.location.hash&&window.location.hash!=="#"){lt.value=Ln(window.location.hash);return}const t=Gr(window.location.pathname,window.location.search);if(t){lt.value=t;const e=ho(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",lt.value=Ln(window.location.hash)}const Js=[{id:"overview",label:"Overview",icon:"🏠"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"council",label:"Council",icon:"🏛️"},{id:"goals",label:"Planning",icon:"🎯"},{id:"execution",label:"Execution",icon:"🛠️"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"agents",label:"Agents",icon:"🤖"},{id:"ops",label:"Ops",icon:"🎮"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function Yr(){const t=lt.value.tab;return o`
    <div class="main-tab-bar">
      ${Js.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>as(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const ui="masc_dashboard_sse_session_id",Qr=1e3,Xr=15e3,Lt=m(!1),is=m(0),yo=m(null),re=m([]);function Zr(){let t=sessionStorage.getItem(ui);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(ui,t)),t}const tl=200;function el(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};re.value=[a,...re.value].slice(0,tl)}function Vs(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function di(t,e){const n=Vs(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function at(t,e,n,s,a={}){el(t,e,n,{eventType:s,...a})}let vt=null,se=null,Ys=0;function bo(){se&&(clearTimeout(se),se=null)}function nl(){if(se)return;Ys++;const t=Math.min(Ys,5),e=Math.min(Xr,Qr*Math.pow(2,t));se=setTimeout(()=>{se=null,ko()},e)}function ko(){bo(),vt&&(vt.close(),vt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Zr());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);vt=i,i.onopen=()=>{vt===i&&(Ys=0,Lt.value=!0)},i.onerror=()=>{vt===i&&(Lt.value=!1,i.close(),vt=null,nl())},i.onmessage=r=>{try{const l=JSON.parse(r.data);is.value++,yo.value=l,sl(l)}catch{}}}function sl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":at(n,"Joined","system","agent_joined");break;case"agent_left":at(n,"Left","system","agent_left");break;case"broadcast":at(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":at(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":at(n,di("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Vs(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":at(n,di("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Vs(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":at(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":at(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":at(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":at(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:at(n,e,"system","unknown")}}function al(){bo(),vt&&(vt.close(),vt=null),Lt.value=!1}function xo(){return new URLSearchParams(window.location.search)}function wo(){const t=xo(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function So(){return{...wo(),"Content-Type":"application/json"}}const il=15e3,Ao=3e4,ol=6e4,pi=new Set([408,425,429,500,502,503,504]);class Ze extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Gt(this,"method");Gt(this,"path");Gt(this,"status");Gt(this,"statusText");Gt(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function Pa(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Ze({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function rl(){var e,n;const t=xo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function kt(t){const e=await Pa(t,{headers:wo()},il);if(!e.ok)throw new Ze({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function ll(t){return new Promise(e=>setTimeout(e,t))}function cl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function ul(t){if(t instanceof Ze)return t.timeout||typeof t.status=="number"&&pi.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=cl(t.message);return e!==null&&pi.has(e)}async function tn(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!ul(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await ll(i),s+=1}}async function xt(t,e,n){const s=await Pa(t,{method:"POST",headers:{...So(),...n??{}},body:JSON.stringify(e)},Ao);if(!s.ok)throw new Ze({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function dl(t,e,n,s=Ao){const a=await Pa(t,{method:"POST",headers:{...So(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Ze({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function pl(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function vl(t){var e,n,s,a,i,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const u=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(u)}return((l=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function G(t,e){const n=await dl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},ol),s=pl(n);return vl(s)}function ml(t="compact"){return kt(`/api/v1/dashboard?mode=${t}`)}function fl(){return kt("/api/v1/operator")}function en(t){return xt("/api/v1/operator/action",t)}function _l(t,e){return xt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const gl=new Set(["lodge-system","team-session"]);function le(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function $l(t){return gl.has(t.trim().toLowerCase())}function hl(t){return t.filter(e=>!$l(e.author))}function yl(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function To(t){if(!N(t))return null;const e=_(t.id,"").trim(),n=_(t.author,"").trim(),s=_(t.content,"").trim();if(!e||!n)return null;const a=C(t.score,0),i=C(t.votes_up,0),r=C(t.votes_down,0),l=C(t.votes,a||i-r),u=C(t.comment_count,C(t.reply_count,0)),c=(()=>{const g=t.flair;if(typeof g=="string"&&g.trim())return g.trim();if(N(g)){const x=_(g.name,"").trim();if(x)return x}return _(t.flair_name,"").trim()||void 0})(),p=_(t.created_at_iso,"").trim()||le(t.created_at),d=_(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?le(t.updated_at):p),f=_(t.title,"").trim()||yl(s);return{id:e,author:n,title:f,content:s,tags:[],votes:l,vote_balance:a,comment_count:u,created_at:p,updated_at:d,flair:c,hearth_count:C(t.hearth_count,0)}}function bl(t){if(!N(t))return null;const e=_(t.id,"").trim(),n=_(t.post_id,"").trim(),s=_(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:_(t.content,""),created_at:le(t.created_at)}}async function kl(t,e){return tn("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const s=n.toString(),a=await kt(`/api/v1/board${s?`?${s}`:""}`),i=Array.isArray(a.posts)?a.posts.map(To).filter(l=>l!==null):[];return{posts:e!=null&&e.excludeSystem?hl(i):i}})}async function xl(t){return tn("fetchBoardPost",async()=>{const e=await kt(`/api/v1/board/${t}?format=flat`),n=N(e.post)?e.post:e,s=To(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(bl).filter(r=>r!==null);return{...s,comments:i}})}function Co(t,e){return xt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:rl()})}function wl(t,e,n){return xt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Sl(t){const e=_(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function B(...t){for(const e of t){const n=_(e,"");if(n.trim())return n.trim()}return""}function vi(t){const e=Sl(B(t.outcome,t.result,t.result_code));if(!e)return;const n=B(t.reason,t.reason_code,t.description,t.detail),s=B(t.summary,t.summary_ko,t.summary_en,t.note),a=B(t.details,t.details_text,t.text,t.note),i=B(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=B(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=B(t.raw_reason,t.raw_reason_code,t.error_message),u=(()=>{const d=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof d=="string"?[d]:Array.isArray(d)?d.map(v=>{if(typeof v=="string")return v.trim();if(N(v)){const f=_(v.summary,"").trim();if(f)return f;const g=_(v.text,"").trim();if(g)return g;const k=_(v.type,"").trim();return k||_(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),c=(()=>{const d=C(t.turn,Number.NaN);if(Number.isFinite(d))return d;const v=C(t.turn_number,Number.NaN);if(Number.isFinite(v))return v;const f=C(t.current_turn,Number.NaN);if(Number.isFinite(f))return f;const g=C(t.round,Number.NaN);return Number.isFinite(g)?g:void 0})(),p=B(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:u.length>0?u:void 0,raw_reason:l||void 0,turn:c,phase:p||void 0}}function Al(t,e){const n=N(t.state)?t.state:{};if(_(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>N(r)?_(r.type,"")==="session.outcome":!1),i=N(n.session_outcome)?n.session_outcome:{};if(N(i)&&Object.keys(i).length>0){const r=vi(i);if(r)return r}if(N(a))return vi(N(a.payload)?a.payload:{})}function N(t){return typeof t=="object"&&t!==null}function _(t,e=""){return typeof t=="string"?t:e}function C(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Ct(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Qs(t,e=!1){return typeof t=="boolean"?t:e}function fe(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(N(e)){const n=_(e.name,"").trim(),s=_(e.id,"").trim(),a=_(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Tl(t){const e={};if(!N(t)&&!Array.isArray(t))return e;if(N(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=_(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!N(n))continue;const s=B(n.to,n.target,n.actor_id,n.name,n.id),a=B(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Cl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function Z(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Nl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Rl(t){const e=N(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(Nl.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function Ll(t,e){if(t!=="dice.rolled")return;const n=C(e.raw_d20,0),s=C(e.total,0),a=C(e.bonus,0),i=_(e.action,"roll"),r=C(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Dl(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Pl(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function El(t,e,n,s){const a=n||e||_(s.actor_id,"")||_(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=_(s.proposed_action,_(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=_(s.reply,_(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return _(s.reply,_(s.content,_(s.text,"Narration")));case"dice.rolled":{const i=_(s.action,"roll"),r=C(s.total,0),l=C(s.dc,0),u=_(s.label,""),c=a||"actor",p=l>0?` vs DC ${l}`:"",d=u?` (${u})`:"";return`${c} ${i}: ${r}${p}${d}`}case"turn.started":return`Turn ${C(s.turn,1)} started`;case"phase.changed":return`Phase: ${_(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${_(s.name,N(s.actor)?_(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${_(s.keeper_name,_(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${_(s.keeper_name,_(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${C(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${C(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||_(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||_(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${_(s.reason_code,"unknown")}`;case"memory.signal":{const i=N(s.entity_refs)?s.entity_refs:{},r=_(i.requested_tier,""),l=_(i.effective_tier,""),u=Qs(i.guardrail_applied,!1),c=_(s.summary_en,_(s.summary_ko,"Memory signal"));if(!r&&!l)return c;const p=r&&l?`${r}->${l}`:l||r;return`${c} [${p}${u?" (guardrail)":""}]`}case"world.event":{if(_(s.event_type,"")==="canon.check"){const r=_(s.status,"unknown"),l=_(s.contract_id,"n/a");return`Canon ${r}: ${l}`}return _(s.description,_(s.summary,"World event"))}case"combat.attack":return _(s.summary,_(s.result,"Attack resolved"));case"combat.defense":return _(s.summary,_(s.result,"Defense resolved"));case"session.outcome":return _(s.summary,_(s.outcome,"Session ended"));default:{const i=Dl(s);return i?`${t}: ${i}`:t}}}function Il(t,e){const n=N(t)?t:{},s=_(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=_(n.actor_name,"").trim()||e[a]||_(N(n.payload)?n.payload.actor_name:"",""),r=N(n.payload)?n.payload:{},l=_(n.ts,_(n.timestamp,new Date().toISOString())),u=_(n.phase,_(r.phase,"")),c=_(n.category,"");return{type:s,actor:i||a||_(r.actor_name,""),actor_id:a||_(r.actor_id,""),actor_name:i,seq:n.seq,room_id:_(n.room_id,""),phase:u||void 0,category:c||Pl(s),visibility:_(n.visibility,_(r.visibility,"public")),event_id:_(n.event_id,""),content:El(s,a,i,r),dice_roll:Ll(s,r),timestamp:l}}function Ml(t,e,n){var st,_t;const s=_(t.room_id,"")||n||"default",a=N(t.state)?t.state:{},i=N(a.party)?a.party:{},r=N(a.actor_control)?a.actor_control:{},l=N(a.join_gate)?a.join_gate:{},u=N(a.contribution_ledger)?a.contribution_ledger:{},c=Object.entries(i).map(([E,K])=>{const $=N(K)?K:{},an=Z($,"max_hp",void 0,10),Wa=Z($,"hp",void 0,an),dr=Z($,"max_mp",void 0,0),pr=Z($,"mp",void 0,0),vr=Z($,"level",void 0,1),mr=Z($,"xp",void 0,0),fr=Qs($.alive,Wa>0),Ga=r[E],Ja=typeof Ga=="string"?Ga:void 0,_r=Cl($.role,E,Ja),gr=Ct($.generation),$r=B($.joined_at,$.joinedAt,$.started_at,$.startedAt),hr=B($.claimed_at,$.claimedAt,$.assigned_at,$.assignedAt,$.assigned_time),yr=B($.last_seen,$.lastSeen,$.last_seen_at,$.lastSeenAt,$.last_active,$.lastActive),br=B($.scene,$.current_scene,$.currentScene,$.world_scene,$.scene_name,$.sceneName),kr=B($.location,$.current_location,$.currentLocation,$.position,$.zone,$.area);return{id:E,name:_($.name,E),role:_r,keeper:Ja,archetype:_($.archetype,""),persona:_($.persona,""),portrait:_($.portrait,"")||void 0,background:_($.background,"")||void 0,traits:fe($.traits),skills:fe($.skills),stats_raw:Rl($),status:fr?"active":"dead",generation:gr,joined_at:$r||void 0,claimed_at:hr||void 0,last_seen:yr||void 0,scene:br||void 0,location:kr||void 0,inventory:fe($.inventory),notes:fe($.notes),relationships:Tl($.relationships),stats:{hp:Wa,max_hp:an,mp:pr,max_mp:dr,level:vr,xp:mr,strength:Z($,"strength","str",10),dexterity:Z($,"dexterity","dex",10),constitution:Z($,"constitution","con",10),intelligence:Z($,"intelligence","int",10),wisdom:Z($,"wisdom","wis",10),charisma:Z($,"charisma","cha",10)}}}),p=c.filter(E=>E.status!=="dead"),d=Al(t,e),v={phase_open:Qs(l.phase_open,!0),min_points:C(l.min_points,3),window:_(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},f=Object.entries(u).map(([E,K])=>{const $=N(K)?K:{};return{actor_id:E,score:C($.score,0),last_reason:_($.last_reason,"")||null,reasons:fe($.reasons)}}),g=c.reduce((E,K)=>(E[K.id]=K.name,E),{}),k=e.map(E=>Il(E,g)),x=C(a.turn,1),R=_(a.phase,"round"),A=_(a.map,""),P=N(a.world)?a.world:{},S=A||_(P.ascii_map,_(P.map,"")),L=k.filter((E,K)=>{const $=e[K];if(!N($))return!1;const an=N($.payload)?$.payload:{};return C(an.turn,-1)===x}),nt=(L.length>0?L:k).slice(-12),Et=_(a.status,"active");return{session:{id:s,room:s,status:Et==="ended"?"ended":Et==="paused"?"paused":"active",round:x,actors:p,created_at:((st=k[0])==null?void 0:st.timestamp)??new Date().toISOString()},current_round:{round_number:x,phase:R,events:nt,timestamp:((_t=k[k.length-1])==null?void 0:_t.timestamp)??new Date().toISOString()},map:S||void 0,join_gate:v,contribution_ledger:f,outcome:d,party:p,story_log:k,history:[]}}async function Ol(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await kt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function jl(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([kt(`/api/v1/trpg/state${e}`),Ol(t)]);return Ml(n,s,t)}function Fl(t){return xt("/api/v1/trpg/rounds/run",{room_id:t})}function zl(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function ql(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),xt("/api/v1/trpg/dice/roll",e)}function Kl(t,e){const n=zl();return xt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Hl(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),xt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function Ul(t,e,n){return xt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Bl(t,e,n){const s=await G("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Wl(t){const e=await G("trpg.mid_join.request",t);return JSON.parse(e)}async function No(t,e){await G("masc_broadcast",{agent_name:t,message:e})}async function Gl(t,e,n=1){await G("masc_add_task",{title:t,description:e,priority:n})}async function Jl(t){return G("masc_join",{agent_name:t})}async function Ro(t){await G("masc_leave",{agent_name:t})}async function Vl(t){await G("masc_heartbeat",{agent_name:t})}async function Yl(t=40){return(await G("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Ql(t,e=20){return G("masc_task_history",{task_id:t,limit:e})}async function Xl(){return tn("fetchDebates",async()=>{const t=await kt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!N(e))return null;const n=_(e.id,"").trim(),s=_(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,status:_(e.status,"open"),argument_count:C(e.argument_count,0),created_at:le(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Zl(){return tn("fetchCouncilSessions",async()=>{const t=await kt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!N(e))return null;const n=_(e.id,"").trim(),s=_(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,initiator:_(e.initiator,"system"),votes:C(e.votes,0),quorum:C(e.quorum,0),state:_(e.state,"open"),created_at:le(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function tc(t){const e=await G("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function ec(t){return tn("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await kt(`/api/v1/council/debates/${e}/summary`);if(!N(n))return null;const s=_(n.id,"").trim();return s?{id:s,topic:_(n.topic,""),status:_(n.status,"open"),support_count:C(n.support_count,0),oppose_count:C(n.oppose_count,0),neutral_count:C(n.neutral_count,0),total_arguments:C(n.total_arguments,0),created_at:le(n.created_at_iso??n.created_at),summary_text:_(n.summary_text,"")}:null})}function nc(t,e,n){return G("masc_keeper_msg",{name:t,message:e})}function sc(t){const e=_(t,"").trim().toLowerCase();return e.startsWith("error")?"error":e==="running"||e==="completed"||e==="stopped"?e:"running"}function ac(t){return N(t)?{iteration:Ct(t.iteration)??0,metric_before:C(t.metric_before,0),metric_after:C(t.metric_after,0),delta:C(t.delta,0),changes:_(t.changes,""),failed_attempts:_(t.failed_attempts,""),next_suggestion:_(t.next_suggestion,""),elapsed_ms:Ct(t.elapsed_ms)??0,cost_usd:typeof t.cost_usd=="number"&&Number.isFinite(t.cost_usd)?t.cost_usd:null}:null}function ic(t){if(!N(t))return null;const e=_(t.loop_id,"").trim();if(!e)return null;const n=Array.isArray(t.history)?t.history.map(ac).filter(s=>s!==null):[];return{loop_id:e,profile:_(t.profile,"custom"),status:sc(t.status),current_iteration:Ct(t.iteration)??Ct(t.current_iteration)??0,max_iterations:Ct(t.max_iterations)??0,baseline_metric:C(t.baseline_metric,0),current_metric:C(t.current_metric,C(t.baseline_metric,0)),target:_(t.target,""),stagnation_streak:Ct(t.stagnation_streak)??0,stagnation_limit:Ct(t.stagnation_limit)??0,elapsed_seconds:C(t.elapsed_seconds,0),history:n}}function mi(t){return t.trim().toLowerCase().includes("no mdal loop running")}async function oc(){try{const t=await G("masc_mdal_status",{}),e=JSON.parse(t),n=N(e)?_(e.error,"").trim():"";if(mi(n))return{state:"idle"};if(n)return{state:"error",message:n};const s=ic(e);return s?{state:"ready",loop:s}:{state:"error",message:"Unexpected MDAL payload"}}catch(t){const e=t instanceof Error?t.message:"Unknown MDAL fetch error";return mi(e)?{state:"idle"}:{state:"error",message:e}}}async function rc(){try{const t=await G("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const ke=m(""),yt=m({}),W=m({}),Xs=m({}),Zs=m({}),ta=m({}),ea=m({}),bt=m({});function U(t,e,n){t.value={...t.value,[e]:n}}function wt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function M(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function ot(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Zt(t){return typeof t=="boolean"?t:void 0}function na(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function sa(t){return Array.isArray(t)?t.map(e=>M(e)).filter(e=>!!e):[]}function lc(t){var n;const e=(n=M(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function cc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function ds(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!wt(s))continue;const a=M(s.name);if(!a)continue;const i=M(s[e]);e==="summary"?n.push({name:a,summary:i}):n.push({name:a,reason:i})}return n}function uc(t){if(!wt(t))return null;const e=M(t.name);return e?{name:e,trigger:M(t.trigger),outcome:M(t.outcome),summary:M(t.summary),reason:M(t.reason)}:null}function dc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function pc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Dn(t){if(!wt(t))return null;const e=M(t.health_state),n=M(t.next_action_path),s=M(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:M(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:na(t.last_reply_at),last_reply_preview:M(t.last_reply_preview)??null,last_error:M(t.last_error)??null,next_eligible_at_s:ot(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,summary:M(t.summary),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Ea(t){return wt(t)?{hour:ot(t.hour),checked:ot(t.checked)??0,acted:ot(t.acted)??0,acted_names:sa(t.acted_names),activity_report:M(t.activity_report),quiet_hours_overridden:Zt(t.quiet_hours_overridden),skipped_reason:M(t.skipped_reason),acted_rows:ds(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:ds(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:ds(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(uc).filter(e=>e!==null):[]}:null}function vc(t){return wt(t)?{enabled:Zt(t.enabled)??!1,interval_s:ot(t.interval_s)??0,quiet_start:ot(t.quiet_start),quiet_end:ot(t.quiet_end),quiet_active:Zt(t.quiet_active),use_planner:Zt(t.use_planner),delegate_llm:Zt(t.delegate_llm),agent_count:ot(t.agent_count),agents:sa(t.agents),last_tick_ago_s:ot(t.last_tick_ago_s)??null,last_tick_ago:M(t.last_tick_ago),total_ticks:ot(t.total_ticks),total_checkins:ot(t.total_checkins),last_skip_reason:M(t.last_skip_reason)??null,last_tick_result:Ea(t.last_tick_result),active_self_heartbeats:sa(t.active_self_heartbeats)}:null}function mc(t){return wt(t)?{status:t.status,diagnostic:Dn(t.diagnostic)}:null}function fc(t){return wt(t)?{recovered:Zt(t.recovered)??!1,skipped_reason:M(t.skipped_reason)??null,before:Dn(t.before),after:Dn(t.after),down:t.down,up:t.up}:null}function _c(t,e){var A,P;if(!(t!=null&&t.name))return null;const n=M((A=t.agent)==null?void 0:A.status)??M(t.status)??"unknown",s=M((P=t.agent)==null?void 0:P.error)??null,a=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,l=t.last_turn_ago_s??null,u=t.proactive_enabled??!1,c=t.proactive_cooldown_sec??0,p=t.last_proactive_ago_s??null,d=u&&p!=null?Math.max(0,c-p):null,v=r<=0||l==null?"never":l>900?"stale":"fresh",f=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,g=s??(a&&!i?"keeper keepalive is not running":null),k=n==="offline"||n==="inactive"?"offline":g?"degraded":v==="stale"?"stale":v==="never"?"idle":"healthy",x=g?dc(g):e!=null&&e.quiet_active&&v!=="fresh"?"quiet_hours":a&&!i?"disabled":r<=0?"never_started":d!=null&&d>0?"min_gap":v==="fresh"||v==="stale"?"no_recent_activity":"unknown",R=k==="offline"||k==="degraded"||k==="stale"?"recover":x==="quiet_hours"?"manual_lodge_poke":x==="unknown"?"probe":"direct_message";return{health_state:k,quiet_reason:x,next_action_path:R,last_reply_status:v,last_reply_at:f,last_reply_preview:null,last_error:g,next_eligible_at_s:d!=null&&d>0?d:null,recoverable:R==="recover",summary:pc(k,x),keepalive_running:i}}function gc(t,e){if(!wt(t))return null;const n=lc(t.role),s=M(t.content)??M(t.preview);if(!s)return null;const a=na(t.ts_unix)??na(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:cc(n),text:s,timestamp:a,delivery:"history"}}function $c(t,e,n){const s=wt(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((i,r)=>gc(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:Dn(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function fi(t,e){const n=W.value[t]??[];W.value={...W.value,[t]:[...n,e].slice(-50)}}function hc(t,e){W.value={...W.value,[t]:e.slice(-50)}}function os(t,e){yt.value={...yt.value,[t]:e},hc(t,e.history)}function _i(t,e){const n=yt.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};os(t,{...n,diagnostic:{...s,...e}})}async function Ia(){ce();try{await Bt()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function yn(t){ke.value=t.trim()}async function Lo(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&yt.value[n])return yt.value[n];U(Xs,n,!0),U(bt,n,null);try{const s=await G("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const i=$c(n,s,a);return os(n,i),i}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return U(bt,n,a),null}finally{U(Xs,n,!1)}}async function yc(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;fi(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),U(Zs,n,!0),U(bt,n,null);try{const i=await nc(n,s);W.value={...W.value,[n]:(W.value[n]??[]).map(r=>r.id===a?{...r,delivery:"delivered"}:r)},fi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),_i(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await Ia()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw W.value={...W.value,[n]:(W.value[n]??[]).map(l=>l.id===a?{...l,delivery:"error",error:r}:l)},_i(n,{last_reply_status:"error",last_error:r}),U(bt,n,r),i}finally{U(Zs,n,!1)}}async function bc(t,e){const n=t.trim();if(!n)return null;U(ta,n,!0),U(bt,n,null);try{const s=await en({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=mc(s.result),i=(a==null?void 0:a.diagnostic)??null;if(i){const r=yt.value[n];os(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??W.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Ia(),i}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw U(bt,n,a),s}finally{U(ta,n,!1)}}async function kc(t,e){const n=t.trim();if(!n)return null;U(ea,n,!0),U(bt,n,null);try{const s=await en({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=fc(s.result),i=(a==null?void 0:a.after)??null;if(i){const r=yt.value[n];os(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??W.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Ia(),i}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw U(bt,n,a),s}finally{U(ea,n,!1)}}const Ht=m([]),St=m([]),nn=m([]),ct=m([]),Pt=m(null),he=m(null),aa=m(new Map),Ut=m([]),Ue=m("hot"),jt=m(!0),Do=m(null),$t=m(""),Be=m([]),te=m(!1),rt=m(new Map),bn=m("unknown"),ia=m(null),oa=m(!1),We=m(!1),ra=m(!1),ee=m(!1),xc=m(null),la=m(null),Po=m(null),Eo=m(null),Io=X(()=>Ht.value.filter(t=>t.status==="active"||t.status==="idle")),Ma=X(()=>{const t=St.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function wc(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const Mo=X(()=>{const t=new Map;for(const e of ct.value)t.set(e.name,wc(e));return t}),Sc=12e4;function Ac(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}const Oo=X(()=>{const t=Date.now(),e=new Set,n=aa.value;for(const s of ct.value){const a=Ac(s,n);a!=null&&t-a>Sc&&e.add(s.name)}return e}),Pn={},Tc=5e3;function ce(){delete Pn.compact,delete Pn.full}function et(t){return typeof t=="object"&&t!==null}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function w(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function xe(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Cc(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function jo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function Nc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Rc(t){if(!et(t))return null;const e=y(t.name);return e?{name:e,status:jo(t.status),current_task:y(t.current_task)??null,last_seen:y(t.last_seen),emoji:y(t.emoji),koreanName:y(t.koreanName)??y(t.korean_name),model:y(t.model),traits:xe(t.traits),interests:xe(t.interests),activityLevel:w(t.activityLevel)??w(t.activity_level),primaryValue:y(t.primaryValue)??y(t.primary_value)}:null}function Lc(t){if(!et(t))return null;const e=y(t.id),n=y(t.title);return!e||!n?null:{id:e,title:n,status:Nc(t.status),priority:w(t.priority),assignee:y(t.assignee),description:y(t.description),created_at:y(t.created_at),updated_at:y(t.updated_at)}}function Dc(t){if(!et(t))return null;const e=y(t.from)??y(t.from_agent)??"system",n=y(t.content)??"",s=y(t.timestamp)??new Date().toISOString();return{id:y(t.id),seq:w(t.seq),from:e,content:n,timestamp:s,type:y(t.type)}}function Pc(t){return Array.isArray(t)?t.map(e=>{if(!et(e))return null;const n=w(e.ts_unix);if(n==null)return null;const s=et(e.handoff)?e.handoff:null;return{ts:n,context_ratio:w(e.context_ratio)??0,context_tokens:w(e.context_tokens)??0,context_max:w(e.context_max)??0,latency_ms:w(e.latency_ms)??0,generation:w(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:w(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:w(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?w(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function gi(t){if(!et(t))return null;const e=y(t.health_state),n=y(t.next_action_path),s=y(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:y(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:Cc(t.last_reply_at)??y(t.last_reply_at)??null,last_reply_preview:y(t.last_reply_preview)??null,last_error:y(t.last_error)??null,next_eligible_at_s:w(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,summary:y(t.summary),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Ec(t,e){return(Array.isArray(t)?t:et(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!et(s))return null;const a=et(s.agent)?s.agent:null,i=et(s.context)?s.context:null,r=et(s.metrics_window)?s.metrics_window:void 0,l=y(s.name);if(!l)return null;const u=w(s.context_ratio)??w(i==null?void 0:i.context_ratio),c=y(s.status)??y(a==null?void 0:a.status)??"offline",p=jo(c),d=y(s.model)??y(s.active_model)??y(s.primary_model),v=xe(s.skill_secondary),f=i?{source:y(i.source),context_ratio:w(i.context_ratio),context_tokens:w(i.context_tokens),context_max:w(i.context_max),message_count:w(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,g=a?{name:y(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:y(a.error),status:y(a.status),current_task:y(a.current_task)??null,last_seen:y(a.last_seen),last_seen_ago_s:w(a.last_seen_ago_s),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,k=Pc(s.metrics_series),x={name:l,emoji:y(s.emoji),koreanName:y(s.koreanName)??y(s.korean_name),agent_name:y(s.agent_name),trace_id:y(s.trace_id),model:d,primary_model:y(s.primary_model),active_model:y(s.active_model),next_model_hint:y(s.next_model_hint)??null,status:p,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:w(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:w(s.proactive_idle_sec),proactive_cooldown_sec:w(s.proactive_cooldown_sec),last_heartbeat:y(s.last_heartbeat)??y(a==null?void 0:a.last_seen),generation:w(s.generation),turn_count:w(s.turn_count)??w(s.total_turns),keeper_age_s:w(s.keeper_age_s),last_turn_ago_s:w(s.last_turn_ago_s),last_handoff_ago_s:w(s.last_handoff_ago_s),last_compaction_ago_s:w(s.last_compaction_ago_s),last_proactive_ago_s:w(s.last_proactive_ago_s),context_ratio:u,context_tokens:w(s.context_tokens)??w(i==null?void 0:i.context_tokens),context_max:w(s.context_max)??w(i==null?void 0:i.context_max),context_source:y(s.context_source)??y(i==null?void 0:i.source),context:f,traits:xe(s.traits),interests:xe(s.interests),primaryValue:y(s.primaryValue)??y(s.primary_value),activityLevel:w(s.activityLevel)??w(s.activity_level),memory_recent_note:y(s.memory_recent_note)??null,conversation_tail_count:w(s.conversation_tail_count),k2k_count:w(s.k2k_count),handoff_count_total:w(s.handoff_count_total)??w(s.trace_history_count),compaction_count:w(s.compaction_count),last_compaction_saved_tokens:w(s.last_compaction_saved_tokens),diagnostic:gi(s.diagnostic),skill_primary:y(s.skill_primary)??null,skill_secondary:v,skill_reason:y(s.skill_reason)??null,metrics_series:k.length>0?k:void 0,metrics_window:r,agent:g};return x.diagnostic=gi(s.diagnostic)??_c(x,(e==null?void 0:e.lodge)??null),x}).filter(s=>s!==null)}function Ic(t){return et(t)?{...t,lodge:vc(t.lodge)??void 0}:null}async function Bt(t="full"){var s,a,i;const e=Date.now(),n=Pn[t];if(!(n&&e-n.time<Tc)){oa.value=!0;try{const r=await ml(t);Pn[t]={data:r,time:e},Ht.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(Rc).filter(u=>u!==null),St.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(Lc).filter(u=>u!==null),nn.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(Dc).filter(u=>u!==null);const l=Ic(r.status);Pt.value=l,ct.value=Ec(r.keepers,l),he.value=r.perpetual??null,xc.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{oa.value=!1}}}async function mt(){We.value=!0;try{const t=await kl(Ue.value,{excludeSystem:jt.value});Ut.value=t.posts??[],la.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{We.value=!1}}async function ht(){var t;ra.value=!0;try{const e=$t.value||((t=Pt.value)==null?void 0:t.room)||"default";$t.value||($t.value=e);const n=await jl(e);Do.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ra.value=!1}}async function we(){te.value=!0;try{const t=await rc();Be.value=Array.isArray(t)?t:[],Po.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{te.value=!1}}async function Se(){const t=++ms;ee.value=!0;try{const e=await oc();if(t!==ms)return;if(e.state==="error"){bn.value="error",ia.value=e.message;return}if(Eo.value=new Date().toISOString(),ia.value=null,e.state==="idle"){bn.value="idle";const i=new Map(rt.value);for(const[r,l]of i.entries())l.status==="running"&&i.set(r,{...l,status:"stopped"});rt.value=i;return}const n=e.loop;bn.value="ready";const s=new Map(rt.value),a=s.get(n.loop_id);s.set(n.loop_id,{...a??{},...n,history:n.history.length>0?n.history:(a==null?void 0:a.history)??[]}),rt.value=s}catch(e){console.error("MDAL fetch error:",e)}finally{t===ms&&(ee.value=!1)}}let ps=null,vs=null,ms=0;function Mc(){return yo.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(aa.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),aa.value=n}if(ce(),ps||(ps=setTimeout(()=>{Bt(),ps=null},500)),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&(vs||(vs=setTimeout(()=>{mt(),vs=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ce(),e.type==="mdal_started"&&e.loop_id){const n=new Map(rt.value);n.set(e.loop_id,{...n.get(e.loop_id)??{},loop_id:e.loop_id,profile:e.profile??"custom",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??0,current_metric:e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]}),rt.value=n}if(e.type==="mdal_iteration"&&e.loop_id){const n=new Map(rt.value),s=e.metric_before??e.metric_after??0,a=e.metric_after??s,i=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:s,current_metric:a,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]},r={iteration:e.iteration??0,metric_before:s,metric_after:a,delta:e.delta??0,changes:"",failed_attempts:"",next_suggestion:"",elapsed_ms:0,cost_usd:null};n.set(e.loop_id,{...i,current_iteration:e.iteration??i.current_iteration,current_metric:a,history:[r,...i.history]}),rt.value=n}if((e.type==="mdal_completed"||e.type==="mdal_stopped")&&e.loop_id){const n=new Map(rt.value),s=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??e.metric_before??e.metric_after??0,current_metric:e.metric_after??e.metric_before??e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]};n.set(e.loop_id,{...s,current_iteration:e.iteration??s.current_iteration,current_metric:e.metric_after??s.current_metric,status:e.type==="mdal_completed"?"completed":"stopped"}),rt.value=n}}})}let Ae=null;function Oc(){Ae||(Ae=setInterval(()=>{ce(),Bt()},1e4))}function jc(){Ae&&(clearInterval(Ae),Ae=null)}function b({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function ut({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Fc(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function j({timestamp:t}){const e=Fc(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function Mt(t){return(t??"").trim().toLowerCase()}function J(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function kn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function ln(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function _e(t){return t.last_heartbeat??ln(t.last_turn_ago_s)??ln(t.last_proactive_ago_s)??ln(t.last_handoff_ago_s)??ln(t.last_compaction_ago_s)}function zc(t){const e=t.title.trim();return e||kn(t.content)}function qc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Oa(t,e,n,s,a={}){var P;const i=Mt(t),r=e.filter(S=>Mt(S.assignee)===i&&(S.status==="claimed"||S.status==="in_progress")).length,l=n.filter(S=>Mt(S.from)===i).sort((S,L)=>J(L.timestamp)-J(S.timestamp))[0],u=s.filter(S=>Mt(S.agent)===i||Mt(S.author)===i).sort((S,L)=>J(L.timestamp)-J(S.timestamp))[0],c=(a.boardPosts??[]).filter(S=>Mt(S.author)===i).sort((S,L)=>J(L.updated_at||L.created_at)-J(S.updated_at||S.created_at))[0],p=(a.keepers??[]).filter(S=>Mt(S.name)===i&&_e(S)!==null).sort((S,L)=>J(_e(L)??0)-J(_e(S)??0))[0],d=l?J(l.timestamp):0,v=u?J(u.timestamp):0,f=c?J(c.updated_at||c.created_at):0,g=p?J(_e(p)??0):0,k=a.lastSeen?J(a.lastSeen):0,x=((P=a.currentTask)==null?void 0:P.trim())||(r>0?`${r} claimed tasks`:null);if(d===0&&v===0&&f===0&&g===0&&k===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:x};const A=[l?{timestamp:l.timestamp,ts:d,text:kn(l.content)}:null,c?{timestamp:c.updated_at||c.created_at,ts:f,text:`Post: ${kn(zc(c))}`}:null,p?{timestamp:_e(p),ts:g,text:qc(p)}:null,u?{timestamp:new Date(u.timestamp).toISOString(),ts:v,text:kn(u.text)}:null].filter(S=>S!==null).sort((S,L)=>L.ts-S.ts)[0];return A&&A.ts>=k?{activeAssignedCount:r,lastActivityAt:A.timestamp,lastActivityText:A.text}:{activeAssignedCount:r,lastActivityAt:a.lastSeen??null,lastActivityText:x??"Presence heartbeat"}}let Kc=0;const Ft=m([]);function h(t,e="success",n=4e3){const s=++Kc;Ft.value=[...Ft.value,{id:s,message:t,type:e}],setTimeout(()=>{Ft.value=Ft.value.filter(a=>a.id!==s)},n)}function Hc(t){Ft.value=Ft.value.filter(e=>e.id!==t)}function Uc(){const t=Ft.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Hc(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}function Bc(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Wc(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Gc(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function $i(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Fo(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Jc(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function zo(t){if(!t)return null;const e=yt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function qo({keeper:t,showRawStatus:e=!1}){if(ft(()=>{t!=null&&t.name&&Lo(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=yt.value[t.name],s=zo(t),a=Xs.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Bc(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Wc((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?o` · ${Fo(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?o` · next eligible ${Jc(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?o`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Ko({keeperName:t,placeholder:e}){const[n,s]=Dr("");ft(()=>{t&&Lo(t)},[t]);const a=W.value[t]??[],i=Zs.value[t]??!1,r=bt.value[t],l=async()=>{const u=n.trim();if(!(!t||!u)){s("");try{await yc(t,u)}catch(c){const p=c instanceof Error?c.message:`Failed to message ${t}`;h(p,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(u=>o`
              <div class="keeper-conversation-item" key=${u.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${$i(u)}`}>${u.label}</span>
                  <span class=${`keeper-role-chip ${$i(u)}`}>${Gc(u)}</span>
                  ${u.timestamp?o`<span class="keeper-conversation-time">${Fo(u.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${u.text}</div>
                ${u.error?o`<div class="keeper-conversation-error">${u.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${u=>{s(u.target.value)}}
          disabled=${i||!t}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{l()}}
            disabled=${i||n.trim()===""||!t}
          >
            ${i?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${r?o`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function Ho({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=zo(e),a=ta.value[e.name]??!1,i=ea.value[e.name]??!1,r=(s==null?void 0:s.next_action_path)??"direct_message";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{bc(e.name,t).catch(l=>{const u=l instanceof Error?l.message:`Failed to probe ${e.name}`;h(u,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{kc(e.name,t).catch(l=>{const u=l instanceof Error?l.message:`Failed to recover ${e.name}`;h(u,"error")})}}
        disabled=${i||!(s!=null&&s.recoverable)||!t.trim()}
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
  `}const ja=m(null);function Fa(t){ja.value=t,yn(t.name)}function hi(){ja.value=null}const Yt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Vc(t){if(!t)return 0;const e=Yt.findIndex(n=>n.level===t);return e>=0?e:0}function Yc({keeper:t}){const e=Vc(t.autonomy_level),n=Yt[e]??Yt[0];if(!n)return null;const s=(e+1)/Yt.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Yt.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Yt.map((a,i)=>o`
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
            <strong><${j} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function xn(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Qc({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${xn(t.context_tokens)}</div>
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
  `}function Xc({keeper:t}){var p,d;const e=t.metrics_series??[];if(e.length<2){const v=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,f=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${f}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((v,f)=>{const g=a+f/(i-1)*(n-2*a),k=s-a-(v.context_ratio??0)*(s-2*a);return{x:g,y:k,p:v}}),l=r.map(({x:v,y:f})=>`${v.toFixed(1)},${f.toFixed(1)}`).join(" "),u=(((d=e[e.length-1])==null?void 0:d.context_ratio)??0)*100,c=u>85?"#ef4444":u>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:v})=>v.is_handoff).map(({x:v})=>o`
          <line x1="${v.toFixed(1)}" y1="${a}" x2="${v.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${c}" stroke-width="1.5"/>
        ${r.filter(({p:v})=>v.is_compaction).map(({x:v,y:f})=>o`
          <circle cx="${v.toFixed(1)}" cy="${f.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${u.toFixed(1)}%</span>
    </div>`}const fs=m("");function Zc({keeper:t}){var a,i,r,l;const e=fs.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(u=>u.title.toLowerCase().includes(e)||u.key.includes(e)||u.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${fs.value}
        onInput=${u=>{fs.value=u.target.value}}
      />
      ${s.map(u=>o`
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${xn(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${xn(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${xn(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function tu({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function eu({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function nu({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function yi({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function _s(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function su({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:_s(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:_s(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:_s(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Uo(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function au(){try{const t=await en({actor:Uo(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Ea(t.result);ce(),await Bt(),e!=null&&e.skipped_reason?h(e.skipped_reason,"warning"):h(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";h(e,"error")}}function iu({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${qo} keeper=${t} />
          <${Ho}
            actor=${Uo()}
            keeper=${t}
            onPokeLodge=${()=>{au()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Ko}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function ou(){var e,n,s;const t=ja.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&hi()}}
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
            <${ut} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>hi()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Qc} keeper=${t} />

        ${""}
        <${Xc} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${b} title="Field Dictionary">
            <${Zc} keeper=${t} />
          <//>

          ${""}
          <${b} title="Profile">
            <${yi} traits=${t.traits??[]} label="Traits" />
            <${yi} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${j} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${b} title="Autonomy">
                <${Yc} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${b} title="TRPG Stats">
                <${tu} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${b} title="Equipment (${t.inventory.length})">
                <${eu} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${b} title="Relationships (${Object.keys(t.relationships).length})">
                <${nu} rels=${t.relationships} />
              <//>
            `:null}

          <${b} title="Runtime Signals">
            <${su} keeper=${t} />
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
        <${iu} keeper=${t} />
      </div>
    </div>
  `:null}const ru="masc_dashboard_agent_name",ve=m(null),En=m(!1),Ge=m(""),In=m([]),Je=m([]),ae=m(""),Te=m(!1);function za(t){ve.value=t,qa()}function bi(){ve.value=null,Ge.value="",In.value=[],Je.value=[],ae.value=""}function lu(){const t=ve.value;return t?Ht.value.find(e=>e.name===t)??null:null}function Bo(t){return t?St.value.filter(e=>e.assignee===t):[]}async function qa(){const t=ve.value;if(t){En.value=!0,Ge.value="",In.value=[],Je.value=[];try{const e=await Yl(80);In.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Bo(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await Ql(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Je.value=s}catch(e){Ge.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{En.value=!1}}}async function ki(){var s;const t=ve.value,e=ae.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(ru))==null?void 0:s.trim())||"dashboard";Te.value=!0;try{await No(n,`@${t} ${e}`),ae.value="",h(`Mention sent to ${t}`,"success"),qa()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";h(i,"error")}finally{Te.value=!1}}function cu({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${ut} status=${t.status} />
    </div>
  `}function uu({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function du(){var a,i,r,l;const t=ve.value;if(!t)return null;const e=lu(),n=Bo(t),s=In.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${u=>{u.target.classList.contains("agent-detail-overlay")&&bi()}}
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
                        <${ut} status=${e.status} />
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
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(u=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(l=e==null?void 0:e.interests)==null?void 0:l.map(u=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${j} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{qa()}} disabled=${En.value}>
              ${En.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${bi}>Close</button>
          </div>
        </div>

        ${Ge.value?o`<div class="council-error">${Ge.value}</div>`:null}

        <div class="agent-detail-grid">
          <${b} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(u=>o`<${cu} key=${u.id} task=${u} />`)}</div>`}
          <//>

          <${b} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((u,c)=>o`<div key=${c} class="agent-activity-line">${u}</div>`)}</div>`}
          <//>
        </div>

        <${b} title="Task History">
          ${Je.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Je.value.map(u=>o`<${uu} key=${u.taskId} row=${u} />`)}</div>`}
        <//>

        <${b} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${ae.value}
              onInput=${u=>{ae.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&ki()}}
              disabled=${Te.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{ki()}}
              disabled=${Te.value||ae.value.trim()===""}
            >
              ${Te.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Jt({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function pu({agent:t}){const e=Oa(t.name,St.value,nn.value,re.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ut.value,keepers:ct.value});return o`
    <div class="agent" onClick=${()=>za(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${ut} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
      ${!t.current_task&&e.activeAssignedCount>0?o`<span class="agent-task">${e.activeAssignedCount} claimed</span>`:null}
      ${e.lastActivityText?o`
            <span class="agent-activity-meta">
              ${e.lastActivityAt?o`<${j} timestamp=${e.lastActivityAt} /> · `:null}
              ${e.lastActivityText}
            </span>
          `:null}
    </div>
  `}function vu(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function xi(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function mu(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function fu(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function _u({keeper:t}){var l;const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=Mo.value.get(t.name),a=Oo.value.has(t.name),i=((l=t.agent)==null?void 0:l.current_task)??"No current task",r=t.diagnostic??null;return o`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>Fa(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${ut} status=${t.status} />
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
              <div class="keeper-ctx-fill ${xi(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${xi(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${vu(t.context_tokens)})`:null}
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
        ${r?o`
              <div class="keeper-diagnostic-row">
                <span class="pill">${r.health_state}</span>
                <span class="pill">${mu(r.quiet_reason)}</span>
                <span class="pill">next ${fu(r.next_action_path)}</span>
                <span class="keeper-diagnostic-copy">reply ${r.last_reply_status}</span>
              </div>
            `:null}

        <!-- Row 4: Heartbeat freshness -->
        ${t.last_heartbeat?o`
          <div class="keeper-heartbeat-row">
            <span class="keeper-heartbeat-dot ${t.status==="active"?"pulse":""}"></span>
            <${j} timestamp=${t.last_heartbeat} />
          </div>
        `:null}
      </div>
    </div>
  `}function Mn(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function ca(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),s=e%60;return s>0?`${n}h ${s}m`:`${n}h`}function gu(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Mn(t.quiet_start)}-${Mn(t.quiet_end)} KST are active. Scheduled ticks may appear asleep until the window ends.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${ca(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${ca(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function $u({lodge:t}){var s,a,i;const e=((a=(s=t==null?void 0:t.last_tick_result)==null?void 0:s.acted_names)==null?void 0:a.join(", "))||"none",n=((i=t==null?void 0:t.active_self_heartbeats)==null?void 0:i.length)??0;return o`
    <${b} title="Lodge Runtime" class="section">
      <div class=${`lodge-banner ${t!=null&&t.enabled?"is-enabled":"is-disabled"}`}>
        <div class="lodge-banner-meta">
          <span class=${`pill lodge-banner-pill ${t!=null&&t.enabled?"is-on":"is-off"}`}>
            ${t!=null&&t.enabled?"enabled":"disabled"}
          </span>
          <span class="pill">every ${ca(t==null?void 0:t.interval_s)}</span>
          <span class="pill">quiet ${Mn(t==null?void 0:t.quiet_start)}-${Mn(t==null?void 0:t.quiet_end)} KST</span>
          <span class="pill">${t!=null&&t.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${t!=null&&t.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${t!=null&&t.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>
        <div class="lodge-banner-copy">${gu(t)}</div>
        <div class="lodge-banner-copy">
          Last tick: ${(t==null?void 0:t.last_tick_ago)??"never"} · Last acted: ${e} · Self-heartbeats: ${n}
        </div>
        ${t!=null&&t.last_skip_reason?o`<div class="lodge-banner-copy">Last skip reason: ${t.last_skip_reason}</div>`:null}
      </div>
    <//>
  `}function wi(){var r,l,u,c,p;const t=Pt.value,e=Ht.value,n=ct.value,s=Ma.value,a=(r=t==null?void 0:t.monitoring)==null?void 0:r.board,i=(l=t==null?void 0:t.monitoring)==null?void 0:l.council;return o`
    <div class="stats-grid">
      <${Jt} label="Agents" value=${e.length} />
      <${Jt} label="Active" value=${Io.value.length} color="#4ade80" />
      <${Jt} label="Keepers" value=${n.length} color="#22d3ee" />
      <${Jt} label="Tasks" value=${St.value.length} />
      <${Jt} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${Jt} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    <${$u} lodge=${t==null?void 0:t.lodge} />

    ${a||i?o`
        <${b} title="Operations SLO" class="section">
          <div class="grid-2col">
            <div class="stat-card">
              <div class="stat-label">Board Feed</div>
              <div class="stat-value" style=${`color: ${Ai(a==null?void 0:a.alert_level)}`}>
                ${Si(a==null?void 0:a.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${cn(a==null?void 0:a.last_activity_age_s)}</span>
                <span>SLO: ≤ ${cn(a==null?void 0:a.slo_target_age_s)}</span>
                <span>SLO Breach: ${a!=null&&a.slo_breached?"Yes":"No"}</span>
                <span>Posts (24h): ${(a==null?void 0:a.new_posts_24h)??0}</span>
                <span>Unanswered: ${(a==null?void 0:a.unanswered_posts)??0}</span>
              </div>
            </div>

            <div class="stat-card">
              <div class="stat-label">Council Feed</div>
              <div class="stat-value" style=${`color: ${Ai(i==null?void 0:i.alert_level)}`}>
                ${Si(i==null?void 0:i.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${cn(i==null?void 0:i.last_activity_age_s)}</span>
                <span>Open Debates: ${(i==null?void 0:i.debates_open)??0}</span>
                <span>Pending Debates: ${(i==null?void 0:i.debates_pending)??0}</span>
                <span>Quorum Risk: ${(i==null?void 0:i.sessions_without_quorum)??0}</span>
                <span>SLO: ≤ ${cn(i==null?void 0:i.slo_target_quorum_age_s)}</span>
                <span>SLO Breach: ${i!=null&&i.slo_breached?"Yes":"No"}</span>
              </div>
            </div>
          </div>
        <//>
      `:null}

    <div class="grid-2col">
      <${b} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(d=>o`<${pu} key=${d.name} agent=${d} />`)}
        </div>
      <//>

      <${b} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(d=>o`<${_u} key=${d.name} keeper=${d} />`)}
        </div>
      <//>
    </div>

    ${he.value?o`
        <${b} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${he.value.running?"Running":"Stopped"}</span>
            ${he.value.goal?o`<span>Goal: ${he.value.goal}</span>`:null}
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
            <span>Uptime: ${hu(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
            ${((u=t.data_quality)==null?void 0:u.board_contract_ok)===!1?o`<span class="pill pill-stale">Board Contract: Degraded</span>`:null}
            ${((c=t.data_quality)==null?void 0:c.council_feed_ok)===!1?o`<span class="pill pill-stale">Council Feed: Degraded</span>`:null}
            ${(p=t.data_quality)!=null&&p.last_sync_at?o`<span>Data Sync: <${j} timestamp=${t.data_quality.last_sync_at} /></span>`:null}
          </div>
        <//>
      `:null}
  `}function hu(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function cn(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),s=e%60;return s>0?`${n}h ${s}m`:`${n}h`}function Si(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function Ai(t){const e=(t??"").toLowerCase();return e==="ok"?"#4ade80":e==="warn"?"#fbbf24":e==="bad"?"#fb7185":"#94a3b8"}const sn=m(null),On=m(!1),Dt=m(null),O=m(!1),jn=m([]);let yu=1;function F(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function T(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function Y(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Wo(t){return typeof t=="boolean"?t:void 0}function bu(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Qt(t,e=[]){if(Array.isArray(t))return t;if(!F(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function ku(t){return F(t)?{id:T(t.id),seq:Y(t.seq),from:T(t.from)??T(t.from_agent)??"system",content:T(t.content)??"",timestamp:T(t.timestamp)??new Date().toISOString(),type:T(t.type)}:null}function xu(t){return F(t)?{room_id:T(t.room_id),current_room:T(t.current_room)??T(t.room),project:T(t.project),cluster:T(t.cluster),paused:Wo(t.paused),pause_reason:T(t.pause_reason)??null,paused_by:T(t.paused_by)??null,paused_at:T(t.paused_at)??null}:{}}function Ti(t){if(!F(t))return;const e=Object.entries(t).map(([n,s])=>{const a=T(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function wu(t){if(!F(t))return null;const e=F(t.status)?t.status:void 0,n=F(t.summary)?t.summary:F(e==null?void 0:e.summary)?e.summary:void 0,s=F(t.session)?t.session:F(e==null?void 0:e.session)?e.session:void 0,a=T(t.session_id)??T(n==null?void 0:n.session_id)??T(s==null?void 0:s.session_id);if(!a)return null;const i=Ti(t.report_paths)??Ti(e==null?void 0:e.report_paths),r=Qt(t.recent_events,["events"]).filter(F);return{session_id:a,status:T(t.status)??T(n==null?void 0:n.status)??T(s==null?void 0:s.status),progress_pct:Y(t.progress_pct)??Y(n==null?void 0:n.progress_pct),elapsed_sec:Y(t.elapsed_sec)??Y(n==null?void 0:n.elapsed_sec),remaining_sec:Y(t.remaining_sec)??Y(n==null?void 0:n.remaining_sec),done_delta_total:Y(t.done_delta_total)??Y(n==null?void 0:n.done_delta_total),summary:n,team_health:F(t.team_health)?t.team_health:F(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:F(t.communication_metrics)?t.communication_metrics:F(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:F(t.orchestration_state)?t.orchestration_state:F(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:F(t.cascade_metrics)?t.cascade_metrics:F(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:s,recent_events:r}}function Su(t){if(!F(t))return null;const e=T(t.name);if(!e)return null;const n=F(t.context)?t.context:void 0;return{name:e,agent_name:T(t.agent_name),status:T(t.status),autonomy_level:T(t.autonomy_level),context_ratio:Y(t.context_ratio)??Y(n==null?void 0:n.context_ratio),generation:Y(t.generation),active_goal_ids:bu(t.active_goal_ids),last_autonomous_action_at:T(t.last_autonomous_action_at)??null,last_turn_ago_s:Y(t.last_turn_ago_s),model:T(t.model)??T(t.active_model)??T(t.primary_model)}}function Au(t){if(!F(t))return null;const e=T(t.confirm_token)??T(t.token);return e?{confirm_token:e,actor:T(t.actor),action_type:T(t.action_type),target_type:T(t.target_type),target_id:T(t.target_id)??null,delegated_tool:T(t.delegated_tool),created_at:T(t.created_at),preview:t.preview}:null}function Tu(t){const e=F(t)?t:{};return{room:xu(e.room),sessions:Qt(e.sessions,["items","sessions"]).map(wu).filter(n=>n!==null),keepers:Qt(e.keepers,["items","keepers"]).map(Su).filter(n=>n!==null),recent_messages:Qt(e.recent_messages,["messages"]).map(ku).filter(n=>n!==null),pending_confirms:Qt(e.pending_confirms,["items","confirms"]).map(Au).filter(n=>n!==null),available_actions:Qt(e.available_actions,["actions"]).filter(F).map(n=>({action_type:T(n.action_type)??"unknown",target_type:T(n.target_type)??"unknown",description:T(n.description),confirm_required:Wo(n.confirm_required)}))}}function un(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Ci(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Fn(t){jn.value=[{...t,id:yu++,at:new Date().toISOString()},...jn.value].slice(0,20)}function Go(t){return t.confirm_required?un(t.preview)||"Confirmation required":un(t.result)||un(t.executed_action)||un(t.delegated_tool_result)||t.status}async function ue(){On.value=!0,Dt.value=null;try{const t=await fl();sn.value=Tu(t)}catch(t){Dt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{On.value=!1}}async function Cu(t){O.value=!0,Dt.value=null;try{const e=await en(t);return Fn({actor:t.actor,action_type:t.action_type,target_label:Ci(t),outcome:e.confirm_required?"preview":"executed",message:Go(e),delegated_tool:e.delegated_tool}),await ue(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw Dt.value=n,Fn({actor:t.actor,action_type:t.action_type,target_label:Ci(t),outcome:"error",message:n}),e}finally{O.value=!1}}async function Nu(t,e){O.value=!0,Dt.value=null;try{const n=await _l(t,e);return Fn({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Go(n),delegated_tool:n.delegated_tool}),await ue(),n}catch(n){const s=n instanceof Error?n.message:"Operator confirmation failed";throw Dt.value=s,Fn({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:s}),n}finally{O.value=!1}}const Jo="masc_dashboard_agent_name";function Ru(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Jo))==null?void 0:s.trim())||"dashboard"}const rs=m(Ru()),Ce=m(""),ua=m("Operator pause"),Ne=m(""),zn=m(""),da=m("2"),qn=m(""),ie=m("note"),Kn=m(""),Hn=m(""),Un=m(""),pa=m("2"),va=m("Operator stop request"),ma=m(""),Re=m("");function Lu(t){const e=t.trim()||"dashboard";rs.value=e,localStorage.setItem(Jo,e)}function Ni(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Du(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}async function Wt(t){const e=rs.value.trim()||"dashboard";try{const n=await Cu({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?h("Confirmation queued","warning"):h(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";return h(s,"error"),null}}async function Ri(){const t=Ce.value.trim();if(!t)return;await Wt({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(Ce.value="")}async function Pu(){await Wt({action_type:"room_pause",target_type:"room",payload:{reason:ua.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function Eu(){await Wt({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function Iu(){const t=Ne.value.trim();if(!t)return;await Wt({action_type:"task_inject",target_type:"room",payload:{title:t,description:zn.value.trim()||"Injected from Ops tab",priority:Number.parseInt(da.value,10)||2},successMessage:"Task injection submitted"})&&(Ne.value="",zn.value="")}async function Mu(){var i;const t=sn.value,e=qn.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){h("Select a team session first","warning");return}const n={turn_kind:ie.value},s=Kn.value.trim();s&&(n.message=s),ie.value==="task"&&(n.task_title=Hn.value.trim()||"Operator injected task",n.task_description=Un.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(pa.value,10)||2),await Wt({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(Kn.value="",ie.value==="task"&&(Hn.value="",Un.value=""))}async function Ou(){var n;const t=sn.value,e=qn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){h("Select a team session first","warning");return}await Wt({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:va.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function ju(){var a;const t=sn.value,e=ma.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=Re.value.trim();if(!e){h("Select a keeper first","warning");return}if(!n)return;await Wt({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(Re.value="")}async function Fu(t){const e=rs.value.trim()||"dashboard";try{await Nu(e,t),h("Confirmation executed","success")}catch(n){const s=n instanceof Error?n.message:"Confirmation failed";h(s,"error")}}function zu(){var u;ft(()=>{ue()},[]);const t=sn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],s=(t==null?void 0:t.keepers)??[],a=(t==null?void 0:t.pending_confirms)??[],i=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===qn.value)??n[0]??null,l=s.find(c=>c.name===ma.value)??s[0]??null;return o`
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
            value=${rs.value}
            onInput=${c=>Lu(c.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{ue()}} disabled=${On.value||O.value}>
            ${On.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${Dt.value?o`
        <section class="ops-banner error">${Dt.value}</section>
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
                ${c.preview?o`<pre class="ops-code-block">${Ni(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Fu(c.confirm_token)}} disabled=${O.value}>
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
              value=${Ce.value}
              onInput=${c=>{Ce.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&Ri()}}
              disabled=${O.value}
            />
            <button class="control-btn" onClick=${()=>{Ri()}} disabled=${O.value||Ce.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${ua.value}
              onInput=${c=>{ua.value=c.target.value}}
              disabled=${O.value}
            />
            <button class="control-btn ghost" onClick=${()=>{Pu()}} disabled=${O.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{Eu()}} disabled=${O.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${Ne.value}
            onInput=${c=>{Ne.value=c.target.value}}
            disabled=${O.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${zn.value}
            onInput=${c=>{zn.value=c.target.value}}
            disabled=${O.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${da.value}
              onChange=${c=>{da.value=c.target.value}}
              disabled=${O.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{Iu()}} disabled=${O.value||Ne.value.trim()===""}>
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
            ${n.length===0?o`<div class="ops-empty">No team sessions available.</div>`:n.map(c=>{var p;return o`
              <button
                key=${c.session_id}
                class="ops-entity-card ${(r==null?void 0:r.session_id)===c.session_id?"active":""}"
                onClick=${()=>{qn.value=c.session_id}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.session_id}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${Math.round(c.progress_pct??0)}%</span>
                  <span>${c.done_delta_total??0} done</span>
                  <span>${(p=c.team_health)!=null&&p.status?String(c.team_health.status):"health n/a"}</span>
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
                <pre class="ops-code-block compact">${Ni(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${ie.value}
              onChange=${c=>{ie.value=c.target.value}}
              disabled=${O.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{Mu()}} disabled=${O.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${Kn.value}
            onInput=${c=>{Kn.value=c.target.value}}
            disabled=${O.value||!r}
          ></textarea>
          ${ie.value==="task"?o`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${Hn.value}
              onInput=${c=>{Hn.value=c.target.value}}
              disabled=${O.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${Un.value}
              onInput=${c=>{Un.value=c.target.value}}
              disabled=${O.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${pa.value}
              onChange=${c=>{pa.value=c.target.value}}
              disabled=${O.value||!r}
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
              value=${va.value}
              onInput=${c=>{va.value=c.target.value}}
              disabled=${O.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{Ou()}} disabled=${O.value||!r}>
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
                onClick=${()=>{ma.value=c.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.name}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${c.model??"model n/a"}</span>
                  <span>${typeof c.context_ratio=="number"?`${Math.round(c.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${Du(c.last_turn_ago_s)}</span>
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
                <span>Goals: ${((u=l.active_goal_ids)==null?void 0:u.length)??0}</span>
              </div>
            </div>
          `:null}

          <label class="control-label" for="ops-keeper-message">Keeper Message</label>
          <textarea
            id="ops-keeper-message"
            class="control-textarea"
            rows=${6}
            placeholder="Send a structured intervention or course correction"
            value=${Re.value}
            onInput=${c=>{Re.value=c.target.value}}
            disabled=${O.value||!l}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{ju()}} disabled=${O.value||!l||Re.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${jn.value.length===0?o`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:jn.value.map(c=>o`
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
  `}const fa=m([]),_a=m([]),Le=m(""),Bn=m(!1),De=m(!1),Ve=m(""),Wn=m(null),it=m(null),ga=m(!1);async function $a(){Bn.value=!0,Ve.value="";try{const[t,e]=await Promise.all([Xl(),Zl()]);fa.value=t,_a.value=e}catch(t){Ve.value=t instanceof Error?t.message:"Failed to load council data"}finally{Bn.value=!1}}async function Li(){const t=Le.value.trim();if(t){De.value=!0;try{const e=await tc(t);Le.value="",h(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await $a()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";h(n,"error")}finally{De.value=!1}}}async function qu(t){Wn.value=t,ga.value=!0,it.value=null;try{it.value=await ec(t)}catch(e){Ve.value=e instanceof Error?e.message:"Failed to load debate status",it.value=null}finally{ga.value=!1}}function Ku({debate:t}){const e=Wn.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>qu(t.id)}
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
  `}function Hu({session:t}){return o`
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
  `}function Uu(){var e;const t=(e=Pt.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${j} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Bu(){var e,n;ft(()=>{$a()},[]);const t=((n=(e=Pt.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${Uu} />
      <${b} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Le.value}
            onInput=${s=>{Le.value=s.target.value}}
            onKeyDown=${s=>{s.key==="Enter"&&Li()}}
            disabled=${De.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Li}
            disabled=${De.value||Le.value.trim()===""}
          >
            ${De.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${$a} disabled=${Bn.value}>
            ${Bn.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Ve.value?o`<div class="council-error">${Ve.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${b} title="Debates" class="section">
          <div class="council-list">
            ${fa.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:fa.value.map(s=>o`<${Ku} key=${s.id} debate=${s} />`)}
          </div>
        <//>

        <${b} title="Voting Sessions" class="section">
          <div class="council-list">
            ${_a.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:_a.value.map(s=>o`<${Hu} key=${s.id} session=${s} />`)}
          </div>
        <//>
      </div>

      <${b} title=${Wn.value?`Debate Detail (${Wn.value})`:"Debate Detail"} class="section">
        ${ga.value?o`<div class="loading-indicator">Loading debate detail...</div>`:it.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${it.value.status}</span>
                  <span>Total arguments: ${it.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${it.value.support_count}</span>
                  <span>Oppose: ${it.value.oppose_count}</span>
                  <span>Neutral: ${it.value.neutral_count}</span>
                </div>
                ${it.value.summary_text?o`<pre class="council-detail">${it.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Wu({text:t}){if(!t)return null;const e=Gu(t);return o`<div class="markdown-content">${e}</div>`}function Gu(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),u=[];for(s++;s<e.length&&!e[s].startsWith(r);)u.push(e[s]),s++;s++,n.push(o`<pre><code class=${l?`language-${l}`:""}>${u.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const c=e[s].replace("</think>","").trim();c&&r.push(c),s++}const u=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${gs(u)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${gs(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${gs(i.join(`
`))}</p>`)}return n}function gs(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Vo=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],wn=m(null),Pe=m([]),qt=m(!1),zt=m(null),Ee=m("");function Ju(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Vu=m(Ju()),Ie=m(!1);async function Ka(t){zt.value=t,wn.value=null,Pe.value=[],qt.value=!0;try{const e=await xl(t);if(zt.value!==t)return;wn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},Pe.value=e.comments??[]}catch{zt.value===t&&(wn.value=null,Pe.value=[])}finally{zt.value===t&&(qt.value=!1)}}async function Di(t){const e=Ee.value.trim();if(e){Ie.value=!0;try{await wl(t,Vu.value,e),Ee.value="",h("Comment posted","success"),await Ka(t),mt()}catch{h("Failed to post comment","error")}finally{Ie.value=!1}}}function Yu(){const t=Ue.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Vo.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{Ue.value=e.id,mt()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${jt.value?"is-active":""}"
          onClick=${()=>{jt.value=!jt.value,mt()}}
        >
          ${jt.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${mt} disabled=${We.value}>
          ${We.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function $s(){var e;const t=(e=Pt.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${j} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Yo({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Qu(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Pi(t){return t.updated_at!==t.created_at}function hs(){var n;const t=((n=Vo.find(s=>s.id===Ue.value))==null?void 0:n.label)??Ue.value,e=Ut.value.length;return o`
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
        <strong>${jt.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${la.value?o`<${j} timestamp=${la.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Xu({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Co(t.id,n),mt()}catch{h("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Jr(t.id)}>
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
              <${Yo} flair=${t.flair} />
              ${Pi(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${j} timestamp=${t.created_at} /></span>
            ${Pi(t)?o`<span>Updated <${j} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${Qu(t.content)}</div>
      </div>
    </div>
  `}function Zu({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${j} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function td({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Ee.value}
        onInput=${e=>{Ee.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Di(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Ie.value}
      />
      <button
        onClick=${()=>Di(t)}
        disabled=${Ie.value||Ee.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Ie.value?"...":"Post"}
      </button>
    </div>
  `}function ed({post:t}){zt.value!==t.id&&!qt.value&&Ka(t.id);const e=async n=>{try{await Co(t.id,n),mt()}catch{h("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>as("board")}>← Back to Board</button>
      <${b} title=${o`${t.title} <${Yo} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Wu} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${j} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${b} title="Comments (${qt.value?"...":Pe.value.length})">
        ${qt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Zu} comments=${Pe.value} />`}
        <${td} postId=${t.id} />
      <//>
    </div>
  `}function nd(){var a,i;const t=Ut.value,e=We.value,n=lt.value.postId,s=((i=(a=Pt.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(l=>l.id===n)??(zt.value===n?wn.value:null);return!r&&zt.value!==n&&!qt.value&&Ka(n),r?o`
          <${$s} />
          <${hs} />
          <${ed} post=${r} />
        `:o`
          <div>
            <${$s} />
            <${hs} />
            <button class="back-btn" onClick=${()=>as("board")}>← Back to Board</button>
            ${qt.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${s?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${$s} />
    <${hs} />
    <${Yu} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${s?"No posts loaded (board feed degraded). Check board contract sync.":jt.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${Xu} key=${r.id} post=${r} />`)}
          </div>`}
  `}function sd(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function ad(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function id(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const Qo=120,od=12,rd=16,ld=12,ha=m("all"),cd={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},ud={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function dd(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function pd(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:sd(t),actor:ad(t),content:id(t),timestamp:new Date(t.timestamp).toISOString()}}function vd(t,e){var a;const n=(a=t.assignee)==null?void 0:a.trim(),s=t.updated_at??t.created_at;return!n||!s?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:s}}function md(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function dn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function ya(t){return t.last_heartbeat??dn(t.last_turn_ago_s)??dn(t.last_proactive_ago_s)??dn(t.last_handoff_ago_s)??dn(t.last_compaction_ago_s)}function fd(t,e){const n=ya(t);if(!n)return null;const s=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${s}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${s}`,timestamp:n}}function dt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const ba=X(()=>{const t=nn.value.map(dd),e=re.value.map(pd),n=[...St.value].sort((i,r)=>dt(r.updated_at??r.created_at??0)-dt(i.updated_at??i.created_at??0)).slice(0,od).map(vd).filter(i=>i!==null),s=[...Ut.value].sort((i,r)=>dt(r.updated_at||r.created_at)-dt(i.updated_at||i.created_at)).slice(0,rd).map(md),a=[...ct.value].sort((i,r)=>dt(ya(r)??0)-dt(ya(i)??0)).slice(0,ld).map(fd).filter(i=>i!==null);return[...t,...e,...n,...s,...a].sort((i,r)=>dt(r.timestamp)-dt(i.timestamp))}),_d=X(()=>{const t=ba.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),gd=X(()=>{const t=ha.value;return(t==="all"?ba.value:ba.value.filter(n=>n.kind===t)).slice(0,Qo)}),$d=X(()=>Ht.value.map(t=>({agent:t,motion:Oa(t.name,St.value,nn.value,re.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ut.value,keepers:ct.value})})).sort((t,e)=>{const n=e.motion.activeAssignedCount-t.motion.activeAssignedCount;return n!==0?n:dt(e.motion.lastActivityAt??0)-dt(t.motion.lastActivityAt??0)}));function hd(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function ge({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function yd({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${hd(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${ud[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function bd(){const t=_d.value,e=gd.value,n=e[0],s=$d.value;return o`
    <div class="stats-grid">
      <${ge} label="Visible rows" value=${e.length} />
      <${ge} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${ge} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${ge} label="Board signals" value=${t.board} color="#fbbf24" />
      <${ge} label="SSE events" value=${is.value} color="#c084fc" />
    </div>

    <${b} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(a=>o`
            <button
              class="goal-filter-btn ${ha.value===a?"active":""}"
              onClick=${()=>{ha.value=a}}
            >
              ${cd[a]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${Lt.value?"":"pill-stale"}">
            ${Lt.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${j} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${Qo} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?o`<div class="empty-state">Waiting for live or snapshot signals...</div>`:e.map(a=>o`<${yd} key=${a.id} row=${a} />`)}
      </div>
    <//>

    <${b} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${s.length===0?o`<div class="empty-state">No active agents</div>`:s.map(({agent:a,motion:i})=>o`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${a.name}</div>
                  <div class="activity-motion-meta">
                    ${i.activeAssignedCount>0?`${i.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${i.lastActivityAt?o` · <${j} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function Xo({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),o`
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
  `}const ys=600*1e3,kd=1200*1e3,Ei=.8;function At(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Vt(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function xd(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function wd(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Sd(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Ad(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Td(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Cd(t){var u,c;const e=Oa(t.name,St.value,nn.value,re.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ut.value,keepers:ct.value}),n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-At(n)):Number.POSITIVE_INFINITY,a=!!((u=t.current_task)!=null&&u.trim())||e.activeAssignedCount>0;let i="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):s>kd?(i="quiet",r="bad",l=a?"Working without a fresh signal":"No fresh agent signal"):a?(i="working",r=s>ys?"warn":"ok",l=s>ys?"Execution looks quiet for too long":"Task and live signal aligned"):s>ys?(i="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((c=t.current_task)==null?void 0:c.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function Nd(t){const e=Mo.value.get(t.name)??"idle",n=Oo.value.has(t.name),s=t.context_ratio??0;let a="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||s>=Ei)&&(a="warning",i="warn",r=s>=Ei?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:a,tone:i,focus:Ad(t),note:r}}function $e({label:t,value:e,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function Rd({item:t}){const e=t.kind==="agent"?()=>za(t.agent.name):()=>Fa(t.keeper);return o`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?o`<span><${j} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </button>
  `}function Ld({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>za(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Xo} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${ut} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${xd(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${j} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
        ${e.last_seen?o`<span>Seen <${j} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?o`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function Dd({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>Fa(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Xo} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${ut} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${wd(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${j} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${Td(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Sd(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function Pd(){const t=[...Ht.value].map(Cd).sort((u,c)=>{const p=Vt(c.tone)-Vt(u.tone);if(p!==0)return p;const d=c.activeTaskCount-u.activeTaskCount;return d!==0?d:At(c.lastSignalAt)-At(u.lastSignalAt)}),e=[...ct.value].map(Nd).sort((u,c)=>{const p=Vt(c.tone)-Vt(u.tone);if(p!==0)return p;const d=(c.keeper.context_ratio??0)-(u.keeper.context_ratio??0);return d!==0?d:At(c.keeper.last_heartbeat)-At(u.keeper.last_heartbeat)}),n=t.filter(u=>u.state!=="offline").length,s=t.filter(u=>u.state==="working").length,a=t.filter(u=>u.lastSignalAt&&Date.now()-At(u.lastSignalAt)<=12e4).length,i=t.filter(u=>u.tone!=="ok"),r=e.filter(u=>u.tone!=="ok"),l=[...r.map(u=>({kind:"keeper",key:`keeper-${u.keeper.name}`,tone:u.tone,title:u.keeper.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.keeper.last_heartbeat??null,keeper:u.keeper})),...i.map(u=>({kind:"agent",key:`agent-${u.agent.name}`,tone:u.tone,title:u.agent.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.lastSignalAt,agent:u.agent}))].sort((u,c)=>{const p=Vt(c.tone)-Vt(u.tone);return p!==0?p:At(c.timestamp)-At(u.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${$e} label="Agents online" value=${n} color="#4ade80" caption="active + idle" />
        <${$e} label="Working now" value=${s} color="#fbbf24" caption="task or claimed load" />
        <${$e} label="Fresh signals" value=${a} color="#22d3ee" caption="within last 2 minutes" />
        <${$e} label="Agent alerts" value=${i.length} color=${i.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${$e} label="Keeper alerts" value=${r.length} color=${r.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${b} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${l.length===0?o`<div class="empty-state">No agent or keeper alerts right now</div>`:l.map(u=>o`<${Rd} key=${u.key} item=${u} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${b} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(u=>o`<${Dd} key=${u.keeper.name} row=${u} />`)}
          </div>
        <//>

        <${b} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Current task, recent signal, and quiet drift are surfaced together.</p>
          </div>
          <div class="monitor-list">
            ${t.length===0?o`<div class="empty-state">No agents registered</div>`:t.map(u=>o`<${Ld} key=${u.agent.name} row=${u} />`)}
          </div>
        <//>
      </div>
    </div>
  `}function bs({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${j} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Ed(){const{todo:t,inProgress:e,done:n}=Ma.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${bs} key=${s.id} task=${s} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${bs} key=${s.id} task=${s} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${bs} key=${s.id} task=${s} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function Id(t){return t==null?"P3":t<=1?"P1":t===2?"P2":t>=4?"P4+":"P3"}function ks({task:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.title}</div>
        <div class="council-sub">
          <span>${Id(t.priority)}</span>
          ${t.assignee?o`<span>Assignee: ${t.assignee}</span>`:o`<span>Unassigned</span>`}
          ${t.created_at?o`<span><${j} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </div>
  `}function Md(){const t=Ma.value,e=t.inProgress,n=t.todo,s=t.done,a=Io.value,i=n.filter(l=>(l.priority??3)<=2),r=n.filter(l=>!l.assignee);return o`
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
      <${b} title="Execution Queue" class="section">
        <div class="council-list">
          ${e.length===0?o`<div class="empty-state">No active execution tasks</div>`:e.slice(0,20).map(l=>o`<${ks} key=${l.id} task=${l} />`)}
        </div>
      <//>

      <${b} title="Ready Queue" class="section">
        <div class="council-list">
          ${n.length===0?o`<div class="empty-state">No ready tasks</div>`:n.slice(0,20).map(l=>o`<${ks} key=${l.id} task=${l} />`)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${b} title="Assignee Coverage" class="section">
        <div class="council-list">
          ${a.length===0?o`<div class="empty-state">No active agents</div>`:a.map(l=>o`
                <div class="council-row session">
                  <div class="council-row-main">
                    <div class="council-topic">${l.name}</div>
                    <div class="council-sub">
                      ${l.current_task?o`<span>${l.current_task}</span>`:o`<span>Idle</span>`}
                    </div>
                  </div>
                  <${ut} status=${l.status} />
                </div>
              `)}
        </div>
      <//>

      <${b} title="Attention Needed" class="section">
        <div class="council-list">
          ${r.length===0?o`<div class="empty-state">No unassigned tasks</div>`:r.slice(0,20).map(l=>o`<${ks} key=${l.id} task=${l} />`)}
        </div>
      <//>
    </div>
  `}const Gn=m("all"),Jn=m("all"),ka=X(()=>{let t=Be.value;return Gn.value!=="all"&&(t=t.filter(e=>e.horizon===Gn.value)),Jn.value!=="all"&&(t=t.filter(e=>e.status===Jn.value)),t}),Od=X(()=>{const t={short:[],mid:[],long:[]};for(const e of ka.value){const n=t[e.horizon];n&&n.push(e)}return t}),jd=X(()=>{const t=Array.from(rt.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Fd(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Ha(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function Sn(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function zd(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Ii(t){return t.toFixed(4)}function Mi(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function qd({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Sn(t.horizon)}">
            ${Ha(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Fd(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${j} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${ut} status=${t.status} />
        <div class="goal-updated">
          <${j} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Oi({label:t,timestamp:e,source:n,note:s}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${s?o`<div class="planning-freshness-source">${s}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${j} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function xs({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${b} title="${Ha(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(s=>o`<${qd} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function Kd(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Gn.value===t?"active":""}"
            onClick=${()=>{Gn.value=t}}
          >
            ${t==="all"?"All":Ha(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Jn.value===t?"active":""}"
            onClick=${()=>{Jn.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Hd(){const t=Be.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${Sn("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Sn("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Sn("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Ud({loop:t}){const e=t.history[0];return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${ut} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Ii(t.baseline_metric)}</span>
          <span>Current ${Ii(t.current_metric)}</span>
          <span class=${Mi(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Mi(t)}
          </span>
          <span>Elapsed ${zd(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${e?o`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function Bd(){ft(()=>{we(),Se()},[]);const t=Od.value,e=jd.value,n=e.filter(r=>r.status==="running").length,s=Be.value.filter(r=>r.status==="active").length,a=bn.value,i=a==="idle"?"No loop running":a==="error"?ia.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${ka.value.length}</div>
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

      <${b} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>masc_mdal_status</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${we} disabled=${te.value}>
              ${te.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${Se} disabled=${ee.value}>
              ${ee.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{we(),Se()}}
              disabled=${te.value||ee.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Oi} label="Goals" timestamp=${Po.value} source="masc_goal_list" />
          <${Oi}
            label="MDAL loops"
            timestamp=${Eo.value}
            source="masc_mdal_status"
            note=${i}
          />
        </div>
      <//>

      <${b} title="Goal Pipeline" class="section">
        <${Hd} />
        <${Kd} />
      <//>

      ${te.value&&Be.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:ka.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${xs} horizon="short" items=${t.short??[]} />
              <${xs} horizon="mid" items=${t.mid??[]} />
              <${xs} horizon="long" items=${t.long??[]} />
            `}

      <${b} title="MDAL Loops" class="section">
        ${ee.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&a==="error"?o`
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
                  ${e.map(r=>o`<${Ud} key=${r.loop_id} loop=${r} />`)}
                </div>
              `}
      <//>
    </div>
  `}const Xt=m(""),ws=m("ability_check"),Ss=m("10"),As=m("12"),pn=m(""),vn=m("idle"),Tt=m(""),mn=m("keeper-late"),Ts=m("player"),Cs=m(""),tt=m("idle"),Ns=m(null),fn=m(""),Rs=m(""),Ls=m("player"),Ds=m(""),Ps=m(""),Es=m(""),Me=m("20"),Is=m("20"),Ms=m(""),_n=m("idle"),xa=m(null),Zo=m("overview"),Os=m("all"),js=m("all"),Fs=m("all"),Wd=12e4,ls=m(null),ji=m(Date.now());function Gd(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Jd(t,e){return e>0?Math.round(t/e*100):0}const Vd={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Yd={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function gn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Qd(t){const e=t.trim().toLowerCase();return Vd[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Xd(t){const e=t.trim().toLowerCase();return Yd[e]??"상황에 따라 선택되는 전술 액션입니다."}function Rt(t){return typeof t=="object"&&t!==null}function V(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function pt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Ye(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const Zd=new Set(["str","dex","con","int","wis","cha"]);function tp(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!Rt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const r=a.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){s[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const l=Number.parseFloat(i.trim());if(Number.isFinite(l)){s[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function ep(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(Me.value.trim(),10);Number.isFinite(s)&&s>n&&(Me.value=String(n))}function wa(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function np(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function sp(t){Zo.value=t}function tr(t){const e=ls.value;return e==null||e<=t}function ap(t){const e=ls.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Vn(){ls.value=null}function er(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function ip(t,e){er(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(ls.value=Date.now()+Wd,h("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function An(t){return tr(t)?(h("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Sa(t,e,n){return er([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function op({hp:t,max:e}){const n=Jd(t,e),s=Gd(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function rp({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function lp({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function nr({actor:t}){var u,c,p,d;const e=(u=t.archetype)==null?void 0:u.trim(),n=(c=t.persona)==null?void 0:c.trim(),s=(p=t.portrait)==null?void 0:p.trim(),a=(d=t.background)==null?void 0:d.trim(),i=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([v,f])=>Number.isFinite(f)).filter(([v])=>!Zd.has(v.toLowerCase()));return o`
    <div class="trpg-actor">
      ${s?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${v=>{const f=v.target;f&&(f.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${ut} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${lp} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${op} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${rp} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${gn(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([v,f])=>o`
                <span class="trpg-custom-stat-chip">${gn(v)} ${f}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(v=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${gn(v)}</span>
                  <span class="trpg-annot-desc">${Qd(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(v=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${gn(v)}</span>
                  <span class="trpg-annot-desc">${Xd(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function cp({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function sr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${np(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${wa(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${j} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function up({events:t}){const e="__none__",n=Os.value,s=js.value,a=Fs.value,i=Array.from(new Set(t.map(wa).map(d=>d.trim()).filter(d=>d!==""))).sort((d,v)=>d.localeCompare(v)),r=Array.from(new Set(t.map(d=>(d.type??"").trim()).filter(d=>d!==""))).sort((d,v)=>d.localeCompare(v)),l=t.some(d=>(d.type??"").trim()===""),u=Array.from(new Set(t.map(d=>(d.phase??"").trim()).filter(d=>d!==""))).sort((d,v)=>d.localeCompare(v)),c=t.some(d=>(d.phase??"").trim()===""),p=t.filter(d=>{if(n!=="all"&&wa(d)!==n)return!1;const v=(d.type??"").trim(),f=(d.phase??"").trim();if(s===e){if(v!=="")return!1}else if(s!=="all"&&v!==s)return!1;if(a===e){if(f!=="")return!1}else if(a!=="all"&&f!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${d=>{Os.value=d.target.value}}>
          <option value="all">all</option>
          ${i.map(d=>o`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${d=>{js.value=d.target.value}}>
          <option value="all">all</option>
          ${l?o`<option value=${e}>(none)</option>`:null}
          ${r.map(d=>o`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${d=>{Fs.value=d.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${e}>(none)</option>`:null}
          ${u.map(d=>o`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Os.value="all",js.value="all",Fs.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${p.length} / 전체 ${t.length}
      </span>
    </div>
    <${sr} events=${p.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function dp({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function ar({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function pp({state:t,nowMs:e}){var c;const n=$t.value||((c=t.session)==null?void 0:c.room)||"",s=vn.value,a=t.party??[];if(!a.find(p=>p.id===Xt.value)&&a.length>0){const p=a[0];p&&(Xt.value=p.id)}const r=async()=>{var d,v;if(!n){h("Room ID가 비어 있습니다.","error");return}if(!An(e))return;const p=((d=t.current_round)==null?void 0:d.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(Sa("라운드 실행",n,p)){vn.value="running";try{const f=await Fl(n);xa.value=f,vn.value="ok";const g=Rt(f.summary)?f.summary:null,k=g?Ye(g,"advanced",!1):!1,x=g?V(g,"progress_reason",""):"";h(k?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${x?`: ${x}`:""}`,k?"success":"warning"),ht()}catch(f){xa.value=null,vn.value="error";const g=f instanceof Error?f.message:"라운드 실행에 실패했습니다.";h(g,"error")}finally{Vn()}}},l=async()=>{var d,v;if(!n||!An(e))return;const p=((d=t.current_round)==null?void 0:d.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(Sa("턴 강제 진행",n,p))try{await Kl(n),h("턴을 다음 단계로 이동했습니다.","success"),ht()}catch{h("턴 이동에 실패했습니다.","error")}finally{Vn()}},u=async()=>{if(!n||!An(e))return;const p=Xt.value.trim();if(!p){h("먼저 Actor를 선택하세요.","warning");return}const d=Number.parseInt(Ss.value,10),v=Number.parseInt(As.value,10);if(Number.isNaN(d)||Number.isNaN(v)){h("stat/dc는 숫자여야 합니다.","warning");return}const f=Number.parseInt(pn.value,10),g=pn.value.trim()===""||Number.isNaN(f)?void 0:f;try{await ql({roomId:n,actorId:p,action:ws.value.trim()||"ability_check",statValue:d,dc:v,rawD20:g}),h("주사위 판정을 기록했습니다.","success"),ht()}catch{h("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${p=>{$t.value=p.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Xt.value}
            onChange=${p=>{Xt.value=p.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(p=>o`<option value=${p.id}>${p.name} (${p.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${ws.value}
              onInput=${p=>{ws.value=p.target.value}}
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
              value=${pn.value}
              onInput=${p=>{pn.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&u()}}
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
  `}function vp({state:t}){var a;const e=$t.value||((a=t.session)==null?void 0:a.room)||"",n=_n.value,s=async()=>{if(!e){h("Room ID가 비어 있습니다.","warning");return}const i=fn.value.trim(),r=Rs.value.trim();if(!r&&!i){h("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt(Me.value.trim(),10),u=Number.parseInt(Is.value.trim(),10),c=Number.isFinite(u)?Math.max(1,u):20,p=Number.isFinite(l)?Math.max(0,Math.min(c,l)):c;let d={};try{d=tp(Ms.value)}catch(v){h(v instanceof Error?v.message:"능력치 JSON 오류","error");return}_n.value="spawning";try{const v=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,f=await Hl(e,{actor_id:i||void 0,name:r||void 0,role:Ls.value,idempotencyKey:v,portrait:Ps.value.trim()||void 0,background:Es.value.trim()||void 0,hp:p,max_hp:c,alive:p>0,stats:Object.keys(d).length>0?d:void 0}),g=typeof f.actor_id=="string"?f.actor_id.trim():"";if(!g)throw new Error("생성 응답에 actor_id가 없습니다.");const k=Ds.value.trim();k&&await Ul(e,g,k),Xt.value=g,Tt.value=g,i||(fn.value=""),_n.value="ok",h(`Actor 생성 완료: ${g}`,"success"),await ht()}catch(v){_n.value="error",h(v instanceof Error?v.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Rs.value}
            onInput=${i=>{Rs.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ls.value}
            onChange=${i=>{Ls.value=i.target.value}}
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
              value=${fn.value}
              onInput=${i=>{fn.value=i.target.value}}
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
              value=${Me.value}
              onInput=${i=>{Me.value=i.target.value}}
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
              onInput=${i=>{const r=i.target.value;Is.value=r,ep(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Es.value}
              onInput=${i=>{Es.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Ms.value}
              onInput=${i=>{Ms.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function mp({state:t,nowMs:e}){var v;const n=$t.value||((v=t.session)==null?void 0:v.room)||"",s=t.join_gate,a=Ns.value,i=Rt(a)?a:null,r=(t.party??[]).filter(f=>f.role!=="dm"),l=Tt.value.trim(),u=r.some(f=>f.id===l),c=u?l:l?"__manual__":"",p=async()=>{const f=Tt.value.trim(),g=mn.value.trim();if(!n||!f){h("Room/Actor가 필요합니다.","warning");return}tt.value="checking";try{const k=await Bl(n,f,g||void 0);Ns.value=k,tt.value="ok",h("참가 가능 여부를 갱신했습니다.","success")}catch(k){tt.value="error";const x=k instanceof Error?k.message:"참가 가능 여부 확인에 실패했습니다.";h(x,"error")}},d=async()=>{var R,A;const f=Tt.value.trim(),g=mn.value.trim(),k=Cs.value.trim();if(!n||!f||!g){h("Room/Actor/Keeper가 필요합니다.","warning");return}if(!An(e))return;const x=((R=t.current_round)==null?void 0:R.phase)??((A=t.session)==null?void 0:A.status)??"unknown";if(Sa("Mid-Join 승인 요청",n,x)){tt.value="requesting";try{const P=await Wl({room_id:n,actor_id:f,keeper_name:g,role:Ts.value,...k?{name:k}:{}});Ns.value=P;const S=Rt(P)?Ye(P,"granted",!1):!1,L=Rt(P)?V(P,"reason_code",""):"";S?h("Mid-Join이 승인되었습니다.","success"):h(`Mid-Join이 거절되었습니다${L?`: ${L}`:""}`,"warning"),tt.value=S?"ok":"error",ht()}catch(P){tt.value="error";const S=P instanceof Error?P.message:"Mid-Join 요청에 실패했습니다.";h(S,"error")}finally{Vn()}}};return o`
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
            onChange=${f=>{const g=f.target.value;if(g==="__manual__"){(u||!l)&&(Tt.value="");return}Tt.value=g}}
          >
            <option value="">Actor 선택</option>
            ${r.map(f=>o`
              <option value=${f.id}>${f.name} (${f.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${c==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Tt.value}
                onInput=${f=>{Tt.value=f.target.value}}
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
            value=${mn.value}
            onInput=${f=>{mn.value=f.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ts.value}
            onChange=${f=>{Ts.value=f.target.value}}
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
            value=${Cs.value}
            onInput=${f=>{Cs.value=f.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${p} disabled=${tt.value==="checking"||tt.value==="requesting"}>
              ${tt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${d} disabled=${tt.value==="checking"||tt.value==="requesting"}>
              ${tt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Ye(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${pt(i,"effective_score",0)}/${pt(i,"required_points",0)}</span>
            ${V(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${V(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function ir({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function or({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function rr(){const t=xa.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=Rt(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(Rt).slice(-8),i=t.canon_check,r=Rt(i)?i:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(L=>typeof L=="string").slice(0,3):[],u=r&&Array.isArray(r.violations)?r.violations.filter(L=>typeof L=="string").slice(0,3):[],c=n?Ye(n,"advanced",!1):!1,p=n?V(n,"progress_reason",""):"",d=n?V(n,"progress_detail",""):"",v=n?pt(n,"player_successes",0):0,f=n?pt(n,"player_required_successes",0):0,g=n?Ye(n,"dm_success",!1):!1,k=n?pt(n,"timeouts",0):0,x=n?pt(n,"unavailable",0):0,R=n?pt(n,"reprompts",0):0,A=n?pt(n,"npc_attacks",0):0,P=n?pt(n,"keeper_timeout_sec",0):0,S=n?pt(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${c?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${c?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${g?"DM ok":"DM stalled"} / players ${v}/${f}
          </span>
        </div>
        ${p?o`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${d?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${d}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${R}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${P||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${S}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(L=>{const nt=V(L,"status","unknown"),Et=V(L,"actor_id","-"),It=V(L,"role","-"),st=V(L,"reason",""),_t=V(L,"action_type",""),E=V(L,"reply","");return o`
                <div class="trpg-round-item ${nt.includes("fallback")||nt.includes("timeout")?"failed":"active"}">
                  <span>${Et} (${It})</span>
                  <span style="margin-left:auto; font-size:11px;">${nt}</span>
                  ${_t?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${_t}</div>`:null}
                  ${st?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${st}</div>`:null}
                  ${E?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${E.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${V(r,"status","unknown")}</strong>
            </div>
            ${u.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${u.map(L=>o`<div>violation: ${L}</div>`)}
                </div>`:null}
            ${l.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(L=>o`<div>warning: ${L}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function fp({state:t,nowMs:e}){var r,l,u;const n=$t.value||((r=t.session)==null?void 0:r.room)||"",s=((l=t.current_round)==null?void 0:l.phase)??((u=t.session)==null?void 0:u.status)??"unknown",a=tr(e),i=ap(e);return o`
    <${b} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>ip(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Vn(),h("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function _p({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>sp(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function gp({state:t}){const e=t.party??[],n=t.story_log??[];return o`
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
          <${sr} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${b} title="맵" style="margin-top:16px;">
              <${cp} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${b} title="현재 라운드">
          <${or} state=${t} />
        <//>

        <${b} title="기여도" style="margin-top:16px;">
          <${ir} state=${t} />
        <//>

        <${b} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${nr} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${b} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${ar} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function $p({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${b} title=${`이벤트 타임라인 (${e.length})`}>
          <${up} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${b} title="최근 라운드 결과">
          <${rr} />
        <//>

        <${b} title="현재 라운드" style="margin-top:16px;">
          <${or} state=${t} />
        <//>
      </div>
    </div>
  `}function hp({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${fp} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${b} title="조작 패널">
            <${pp} state=${t} nowMs=${e} />
          <//>

          <${b} title="Actor Spawn" style="margin-top:16px;">
            <${vp} state=${t} />
          <//>

          <${b} title="Mid-Join Gate" style="margin-top:16px;">
            <${mp} state=${t} nowMs=${e} />
          <//>

          <${b} title="최근 라운드 결과" style="margin-top:16px;">
            <${rr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${b} title="기여도" style="margin-top:0;">
            <${ir} state=${t} />
          <//>

          <${b} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${nr} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${b} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${ar} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function yp(){var l,u,c,p,d;const t=Do.value,e=ra.value;if(ft(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const v=window.setInterval(()=>{ji.value=Date.now()},1e3);return()=>{window.clearInterval(v)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>ht()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=Zo.value,r=ji.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${$t.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((u=t.current_round)==null?void 0:u.phase)??((c=t.session)==null?void 0:c.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>ht()}>새로고침</button>
      </div>

      <${dp} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((p=t.session)==null?void 0:p.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((d=t.current_round)==null?void 0:d.round_number)??0}</div>
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

      <${_p} active=${i} />

      ${i==="overview"?o`<${gp} state=${t} />`:i==="timeline"?o`<${$p} state=${t} />`:o`<${hp} state=${t} nowMs=${r} />`}
    </div>
  `}const Ua="masc_dashboard_agent_name";function bp(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Ua);return e??n??"dashboard"}const Q=m(bp()),Oe=m(""),je=m(""),Yn=m(""),lr=m(null),Qn=m(null),Fe=m(!1),ne=m(!1),ze=m(!1),qe=m(!1),Xn=m(!1),Zn=m(!1),cs=m(!1);function ts(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function Tn(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function cr(t){return!t||t.length===0?"none":t.join(", ")}function kp(t){return t?t.enabled?t.quiet_active?`Quiet hours ${ts(t.quiet_start)}-${ts(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${Tn(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${Tn(t.interval_s)}.`:`Lodge ticks every ${Tn(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function me(){ce();try{await Bt()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function Ba(t){const e=t.trim();Q.value=e,e&&localStorage.setItem(Ua,e)}function xp(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Aa(){const t=Q.value.trim();if(t){ze.value=!0;try{const e=await Jl(t),n=xp(e);n&&Ba(n),cs.value=!0,await me(),h(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";h(n,"error")}finally{ze.value=!1}}}async function wp(){const t=Q.value.trim();if(t){qe.value=!0;try{await Ro(t),cs.value=!1,await me(),h(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";h(n,"error")}finally{qe.value=!1}}}async function Sp(){const t=Q.value.trim();if(t)try{await Ro(t)}catch{}localStorage.removeItem(Ua),Ba("dashboard"),cs.value=!1,await Aa()}async function Ap(){const t=Q.value.trim();if(t){Xn.value=!0;try{await Vl(t),await me(),h("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";h(n,"error")}finally{Xn.value=!1}}}async function Fi(){const t=Q.value.trim(),e=Oe.value.trim();if(!(!t||!e)){Fe.value=!0;try{await No(t,e),Oe.value="",await me(),h("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";h(s,"error")}finally{Fe.value=!1}}}async function Tp(){const t=je.value.trim(),e=Yn.value.trim()||"Created from dashboard";if(t){ne.value=!0;try{await Gl(t,e,1),je.value="",Yn.value="",await me(),h("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";h(s,"error")}finally{ne.value=!1}}}async function zi(){const t=Q.value.trim()||"dashboard";Zn.value=!0,Qn.value=null;try{const e=await en({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=Ea(e.result);lr.value=n,await me(),n!=null&&n.skipped_reason?h(n.skipped_reason,"warning"):h(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";Qn.value=n,h(n,"error")}finally{Zn.value=!1}}function Cp({runtime:t}){var a,i;const e=lr.value??(t==null?void 0:t.last_tick_result)??null;if(Qn.value)return o`<div class="control-result-box is-error">${Qn.value}</div>`;if(!e)return o`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((a=e.skipped_rows)==null?void 0:a.slice(0,3))??[],s=((i=e.passed_rows)==null?void 0:i.slice(0,3))??[];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?o`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${cr(e.acted_names)}</div>
      ${e.skipped_reason?o`<div class="control-status-copy">${e.skipped_reason}</div>`:null}
      ${e.activity_report?o`<pre class="control-transcript-text">${e.activity_report}</pre>`:null}
      ${n.length>0?o`
            <div class="control-result-list">
              ${n.map(r=>o`<div>${r.name}: ${r.reason??"skipped"}</div>`)}
            </div>
          `:null}
      ${s.length>0?o`
            <div class="control-result-list">
              ${s.map(r=>o`<div>${r.name}: ${r.reason??"passed"}</div>`)}
            </div>
          `:null}
    </div>
  `}function Np(t){return t.find(n=>n.name===ke.value)??t[0]??null}function Rp(){var s,a;const t=ct.value,e=((s=Pt.value)==null?void 0:s.lodge)??null,n=Np(t);return ft(()=>{Aa()},[]),ft(()=>{var r;const i=((r=t[0])==null?void 0:r.name)??"";if(!ke.value&&i){yn(i);return}ke.value&&!t.some(l=>l.name===ke.value)&&yn(i)},[t.map(i=>i.name).join("|")]),o`
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
          value=${Q.value}
          onInput=${i=>Ba(i.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Aa()}}
            disabled=${ze.value||Q.value.trim()===""}
          >
            ${ze.value?"Joining...":cs.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{wp()}}
            disabled=${qe.value||Q.value.trim()===""}
          >
            ${qe.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Sp()}}
            disabled=${ze.value||qe.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Ap()}}
            disabled=${Xn.value||Q.value.trim()===""}
          >
            ${Xn.value?"Pinging...":"Heartbeat"}
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
            value=${Oe.value}
            onInput=${i=>{Oe.value=i.target.value}}
            onKeyDown=${i=>{i.key==="Enter"&&Fi()}}
            disabled=${Fe.value}
          />
          <button
            class="control-btn"
            onClick=${()=>{Fi()}}
            disabled=${Fe.value||Oe.value.trim()===""||Q.value.trim()===""}
          >
            ${Fe.value?"Sending...":"Send"}
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
          onInput=${i=>{yn(i.target.value)}}
          disabled=${t.length===0}
        >
          ${t.length===0?o`<option value="">No keepers available</option>`:t.map(i=>o`<option value=${i.name}>${i.name}</option>`)}
        </select>

        <${qo} keeper=${n} />
        <${Ho}
          actor=${Q.value.trim()||"dashboard"}
          keeper=${n}
          onPokeLodge=${()=>{zi()}}
        />
        <${Ko}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${kp(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${Tn(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${ts(e==null?void 0:e.quiet_start)}-${ts(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${cr((a=e==null?void 0:e.last_tick_result)==null?void 0:a.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?o`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{zi()}}
            disabled=${Zn.value}
          >
            ${Zn.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${Cp} runtime=${e} />
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
          value=${je.value}
          onInput=${i=>{je.value=i.target.value}}
          disabled=${ne.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${Yn.value}
          onInput=${i=>{Yn.value=i.target.value}}
          disabled=${ne.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{Tp()}}
          disabled=${ne.value||je.value.trim()===""}
        >
          ${ne.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const ur={overview:"Room health, keeper pressure, and top-line execution status",board:"Human and agent discussion feed with system noise filtered by default",activity:"Unified live stream for messages, task changes, board events, and keeper events",council:"Debates, quorum status, and decision flow",goals:"Goals and MDAL loops in one planning surface with freshness signals",execution:"Queue readiness and assignee coverage",tasks:"Kanban-style task distribution",agents:"Live monitor for agent status, keeper pressure, and current execution focus",ops:"Guided operator controls for room, sessions, and keepers",trpg:"Narrative room control and state visibility"};function Lp(){const t=Lt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${is.value} events</span>
    </div>
  `}function Dp(){const t=lt.value.tab,e=Lt.value,n=Js.find(s=>s.id===t);return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${Js.map(s=>o`
            <button
              class="rail-tab-btn ${t===s.id?"active":""}"
              onClick=${()=>as(s.id)}
            >
              ${s.icon} ${s.label}
            </button>
          `)}
        </div>
        <div class="rail-view-note">
          <div class="rail-view-note-label">Current focus</div>
          <strong>${(n==null?void 0:n.label)??t}</strong>
          <p>${ur[t]??"Live operational view"}</p>
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
            <strong>${Ht.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${ct.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${St.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${is.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Bt(),t==="ops"&&ue(),t==="board"&&mt(),t==="trpg"&&ht(),t==="goals"&&(we(),Se())}}
        >
          Refresh Now
        </button>
      </section>

      <${Rp} />
    </aside>
  `}function Pp(){switch(lt.value.tab){case"overview":return o`<${wi} />`;case"ops":return o`<${zu} />`;case"council":return o`<${Bu} />`;case"board":return o`<${nd} />`;case"execution":return o`<${Md} />`;case"activity":return o`<${bd} />`;case"agents":return o`<${Pd} />`;case"tasks":return o`<${Ed} />`;case"goals":return o`<${Bd} />`;case"trpg":return o`<${yp} />`;default:return o`<${wi} />`}}function Ep(){ft(()=>{Vr(),ko(),Bt(),mt();const e=Mc();return Oc(),()=>{al(),e(),jc()}},[]),ft(()=>{const e=lt.value.tab;e==="ops"&&ue(),e==="board"&&mt(),e==="trpg"&&ht(),e==="goals"&&(we(),Se())},[lt.value.tab]);const t=lt.value.tab;return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${ur[t]??"Decision and execution operations console"}</p>
        </div>
        <div class="header-right">
          <${Lp} />
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${Yr} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${oa.value&&!Lt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${Pp} />`}
        </main>
        <${Dp} />
      </div>

      <${ou} />
      <${du} />
      <${Uc} />
    </div>
  `}const qi=document.getElementById("app");qi&&Rr(o`<${Ep} />`,qi);
