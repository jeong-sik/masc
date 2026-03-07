var _l=Object.defineProperty;var gl=(t,e,n)=>e in t?_l(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var xe=(t,e,n)=>gl(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var Va,j,jo,Ko,le,qi,Uo,Ho,Bo,xi,Ms,Os,xn={},Wo=[],hl=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Qa=Array.isArray;function zt(t,e){for(var n in e)t[n]=e[n];return t}function Si(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function Go(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Va.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return oa(t,r,a,s,null)}function oa(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++jo,__i:-1,__u:0};return s==null&&j.vnode!=null&&j.vnode(i),i}function In(t){return t.children}function tn(t,e){this.props=t,this.context=e}function Fe(t,e){if(e==null)return t.__?Fe(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?Fe(t):null}function Jo(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return Jo(t)}}function ji(t){(!t.__d&&(t.__d=!0)&&le.push(t)&&!ga.__r++||qi!=j.debounceRendering)&&((qi=j.debounceRendering)||Uo)(ga)}function ga(){for(var t,e,n,a,s,i,r,u=1;le.length;)le.length>u&&le.sort(Ho),t=le.shift(),u=le.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=zt({},a)).__v=a.__v+1,j.vnode&&j.vnode(n),wi(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??Fe(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,Yo(i,n,r),a.__e=a.__=null,n.__e!=s&&Jo(n)));ga.__r=0}function Vo(t,e,n,a,s,i,r,u,d,p,f){var l,c,m,$,b,w,R,A=a&&a.__k||Wo,M=e.length;for(d=$l(n,e,A,d,M),l=0;l<M;l++)(m=n.__k[l])!=null&&(c=m.__i==-1?xn:A[m.__i]||xn,m.__i=l,w=wi(t,m,c,s,i,r,u,d,p,f),$=m.__e,m.ref&&c.ref!=m.ref&&(c.ref&&Ai(c.ref,null,m),f.push(m.ref,m.__c||$,m)),b==null&&$!=null&&(b=$),(R=!!(4&m.__u))||c.__k===m.__k?d=Qo(m,d,t,R):typeof m.type=="function"&&w!==void 0?d=w:$&&(d=$.nextSibling),m.__u&=-7);return n.__e=b,d}function $l(t,e,n,a,s){var i,r,u,d,p,f=n.length,l=f,c=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=oa(null,r,null,null,null):Qa(r)?r=t.__k[i]=oa(In,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=oa(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+c,r.__=t,r.__b=t.__b+1,u=null,(p=r.__i=yl(r,n,d,l))!=-1&&(l--,(u=n[p])&&(u.__u|=2)),u==null||u.__v==null?(p==-1&&(s>f?c--:s<f&&c++),typeof r.type!="function"&&(r.__u|=4)):p!=d&&(p==d-1?c--:p==d+1?c++:(p>d?c--:c++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<f;i++)(u=n[i])!=null&&(2&u.__u)==0&&(u.__e==a&&(a=Fe(u)),Zo(u,u));return a}function Qo(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=Qo(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=Fe(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function yl(t,e,n,a){var s,i,r,u=t.key,d=t.type,p=e[n],f=p!=null&&(2&p.__u)==0;if(p===null&&u==null||f&&u==p.key&&d==p.type)return n;if(a>(f?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((p=e[r=s>=0?s--:i++])!=null&&(2&p.__u)==0&&u==p.key&&d==p.type)return r}return-1}function Ki(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||hl.test(e)?n:n+"px"}function Jn(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||Ki(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||Ki(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Bo,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=xi,t.addEventListener(e,i?Os:Ms,i)):t.removeEventListener(e,i?Os:Ms,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Ui(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=xi++;else if(e.t<n.u)return;return n(j.event?j.event(e):e)}}}function wi(t,e,n,a,s,i,r,u,d,p){var f,l,c,m,$,b,w,R,A,M,C,L,at,At,Tt,st,mt,O=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[u=e.__e=n.__e]),(f=j.__b)&&f(e);t:if(typeof O=="function")try{if(R=e.props,A="prototype"in O&&O.prototype.render,M=(f=O.contextType)&&a[f.__c],C=f?M?M.props.value:f.__:a,n.__c?w=(l=e.__c=n.__c).__=l.__E:(A?e.__c=l=new O(R,C):(e.__c=l=new tn(R,C),l.constructor=O,l.render=kl),M&&M.sub(l),l.state||(l.state={}),l.__n=a,c=l.__d=!0,l.__h=[],l._sb=[]),A&&l.__s==null&&(l.__s=l.state),A&&O.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=zt({},l.__s)),zt(l.__s,O.getDerivedStateFromProps(R,l.__s))),m=l.props,$=l.state,l.__v=e,c)A&&O.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),A&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(A&&O.getDerivedStateFromProps==null&&R!==m&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(R,C),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(R,l.__s,C)===!1){for(e.__v!=n.__v&&(l.props=R,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(V){V&&(V.__=e)}),L=0;L<l._sb.length;L++)l.__h.push(l._sb[L]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(R,l.__s,C),A&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(m,$,b)})}if(l.context=C,l.props=R,l.__P=t,l.__e=!1,at=j.__r,At=0,A){for(l.state=l.__s,l.__d=!1,at&&at(e),f=l.render(l.props,l.state,l.context),Tt=0;Tt<l._sb.length;Tt++)l.__h.push(l._sb[Tt]);l._sb=[]}else do l.__d=!1,at&&at(e),f=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++At<25);l.state=l.__s,l.getChildContext!=null&&(a=zt(zt({},a),l.getChildContext())),A&&!c&&l.getSnapshotBeforeUpdate!=null&&(b=l.getSnapshotBeforeUpdate(m,$)),st=f,f!=null&&f.type===In&&f.key==null&&(st=Xo(f.props.children)),u=Vo(t,Qa(st)?st:[st],e,n,a,s,i,r,u,d,p),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),w&&(l.__E=l.__=null)}catch(V){if(e.__v=null,d||i!=null)if(V.then){for(e.__u|=d?160:128;u&&u.nodeType==8&&u.nextSibling;)u=u.nextSibling;i[i.indexOf(u)]=null,e.__e=u}else{for(mt=i.length;mt--;)Si(i[mt]);zs(e)}else e.__e=n.__e,e.__k=n.__k,V.then||zs(e);j.__e(V,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):u=e.__e=bl(n.__e,e,n,a,s,i,r,d,p);return(f=j.diffed)&&f(e),128&e.__u?void 0:u}function zs(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(zs)}function Yo(t,e,n){for(var a=0;a<n.length;a++)Ai(n[a],n[++a],n[++a]);j.__c&&j.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){j.__e(i,s.__v)}})}function Xo(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Qa(t)?t.map(Xo):zt({},t)}function bl(t,e,n,a,s,i,r,u,d){var p,f,l,c,m,$,b,w=n.props||xn,R=e.props,A=e.type;if(A=="svg"?s="http://www.w3.org/2000/svg":A=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(p=0;p<i.length;p++)if((m=i[p])&&"setAttribute"in m==!!A&&(A?m.localName==A:m.nodeType==3)){t=m,i[p]=null;break}}if(t==null){if(A==null)return document.createTextNode(R);t=document.createElementNS(s,A,R.is&&R),u&&(j.__m&&j.__m(e,i),u=!1),i=null}if(A==null)w===R||u&&t.data==R||(t.data=R);else{if(i=i&&Va.call(t.childNodes),!u&&i!=null)for(w={},p=0;p<t.attributes.length;p++)w[(m=t.attributes[p]).name]=m.value;for(p in w)if(m=w[p],p!="children"){if(p=="dangerouslySetInnerHTML")l=m;else if(!(p in R)){if(p=="value"&&"defaultValue"in R||p=="checked"&&"defaultChecked"in R)continue;Jn(t,p,null,m,s)}}for(p in R)m=R[p],p=="children"?c=m:p=="dangerouslySetInnerHTML"?f=m:p=="value"?$=m:p=="checked"?b=m:u&&typeof m!="function"||w[p]===m||Jn(t,p,m,w[p],s);if(f)u||l&&(f.__html==l.__html||f.__html==t.innerHTML)||(t.innerHTML=f.__html),e.__k=[];else if(l&&(t.innerHTML=""),Vo(e.type=="template"?t.content:t,Qa(c)?c:[c],e,n,a,A=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&Fe(n,0),u,d),i!=null)for(p=i.length;p--;)Si(i[p]);u||(p="value",A=="progress"&&$==null?t.removeAttribute("value"):$!=null&&($!==t[p]||A=="progress"&&!$||A=="option"&&$!=w[p])&&Jn(t,p,$,w[p],s),p="checked",b!=null&&b!=t[p]&&Jn(t,p,b,w[p],s))}return t}function Ai(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){j.__e(s,n)}}function Zo(t,e,n){var a,s;if(j.unmount&&j.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||Ai(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){j.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&Zo(a[s],e,n||typeof t.type!="function");n||Si(t.__e),t.__c=t.__=t.__e=void 0}function kl(t,e,n){return this.constructor(t,n)}function xl(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),j.__&&j.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],wi(e,t=e.__k=Go(In,null,[t]),s||xn,xn,e.namespaceURI,s?null:e.firstChild?Va.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),Yo(i,t,r)}Va=Wo.slice,j={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(u){t=u}throw t}},jo=0,Ko=function(t){return t!=null&&t.constructor===void 0},tn.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=zt({},this.state),typeof t=="function"&&(t=t(zt({},n),this.props)),t&&zt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),ji(this))},tn.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),ji(this))},tn.prototype.render=In,le=[],Uo=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Ho=function(t,e){return t.__v.__b-e.__v.__b},ga.__r=0,Bo=/(PointerCapture)$|Capture$/i,xi=0,Ms=Ui(!1),Os=Ui(!0);var tr=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],u=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=u:r===4?a[1]=Object.assign(a[1]||{},u):r===5?(a[1]=a[1]||{})[e[++i]]=u:r===6?a[1][e[++i]]+=u+"":r?(s=t.apply(u,tr(t,u,n,["",null])),a.push(s),u[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(u)}return a},Hi=new Map;function Sl(t){var e=Hi.get(this);return e||(e=new Map,Hi.set(this,e)),(e=tr(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",u="",d=[0],p=function(c){i===1&&(c||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,c,r):i===3&&(c||r)?(d.push(3,c,r),i=2):i===2&&r==="..."&&c?d.push(4,c,0):i===2&&r&&!c?d.push(5,0,!0,r):i>=5&&((r||!c&&i===5)&&(d.push(i,0,r,s),i=6),c&&(d.push(i,c,0,s),i=6)),r=""},f=0;f<n.length;f++){f&&(i===1&&p(),p(f));for(var l=0;l<n[f].length;l++)a=n[f][l],i===1?a==="<"?(p(),d=[d],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:u?a===u?u="":r+=a:a==='"'||a==="'"?u=a:a===">"?(p(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[f][l+1]===">")?(p(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(p(),i=2):r+=a),i===3&&r==="!--"&&(i=4,d=d[0])}return p(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Sl.bind(Go),Sn,J,as,Bi,Fs=0,er=[],Y=j,Wi=Y.__b,Gi=Y.__r,Ji=Y.diffed,Vi=Y.__c,Qi=Y.unmount,Yi=Y.__;function Ti(t,e){Y.__h&&Y.__h(J,t,Fs||e),Fs=0;var n=J.__H||(J.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function nr(t){return Fs=1,wl(ir,t)}function wl(t,e,n){var a=Ti(Sn++,2);if(a.t=t,!a.__c&&(a.__=[ir(void 0,e),function(u){var d=a.__N?a.__N[0]:a.__[0],p=a.t(d,u);d!==p&&(a.__N=[p,a.__[1]],a.__c.setState({}))}],a.__c=J,!J.__f)){var s=function(u,d,p){if(!a.__c.__H)return!0;var f=a.__c.__H.__.filter(function(c){return!!c.__c});if(f.every(function(c){return!c.__N}))return!i||i.call(this,u,d,p);var l=a.__c.props!==u;return f.forEach(function(c){if(c.__N){var m=c.__[0];c.__=c.__N,c.__N=void 0,m!==c.__[0]&&(l=!0)}}),i&&i.call(this,u,d,p)||l};J.__f=!0;var i=J.shouldComponentUpdate,r=J.componentWillUpdate;J.componentWillUpdate=function(u,d,p){if(this.__e){var f=i;i=void 0,s(u,d,p),i=f}r&&r.call(this,u,d,p)},J.shouldComponentUpdate=s}return a.__N||a.__}function xt(t,e){var n=Ti(Sn++,3);!Y.__s&&sr(n.__H,e)&&(n.__=t,n.u=e,J.__H.__h.push(n))}function ar(t,e){var n=Ti(Sn++,7);return sr(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Al(){for(var t;t=er.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(ra),t.__H.__h.forEach(qs),t.__H.__h=[]}catch(e){t.__H.__h=[],Y.__e(e,t.__v)}}Y.__b=function(t){J=null,Wi&&Wi(t)},Y.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Yi&&Yi(t,e)},Y.__r=function(t){Gi&&Gi(t),Sn=0;var e=(J=t.__c).__H;e&&(as===J?(e.__h=[],J.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(ra),e.__h.forEach(qs),e.__h=[],Sn=0)),as=J},Y.diffed=function(t){Ji&&Ji(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(er.push(e)!==1&&Bi===Y.requestAnimationFrame||((Bi=Y.requestAnimationFrame)||Tl)(Al)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),as=J=null},Y.__c=function(t,e){e.some(function(n){try{n.__h.forEach(ra),n.__h=n.__h.filter(function(a){return!a.__||qs(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],Y.__e(a,n.__v)}}),Vi&&Vi(t,e)},Y.unmount=function(t){Qi&&Qi(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{ra(a)}catch(s){e=s}}),n.__H=void 0,e&&Y.__e(e,n.__v))};var Xi=typeof requestAnimationFrame=="function";function Tl(t){var e,n=function(){clearTimeout(a),Xi&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);Xi&&(e=requestAnimationFrame(n))}function ra(t){var e=J,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),J=e}function qs(t){var e=J;t.__c=t.__(),J=e}function sr(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}function ir(t,e){return typeof e=="function"?e(t):e}var Cl=Symbol.for("preact-signals");function Ya(){if(Xt>1)Xt--;else{for(var t,e=!1;en!==void 0;){var n=en;for(en=void 0,js++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&lr(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(js=0,Xt--,e)throw t}}function Nl(t){if(Xt>0)return t();Xt++;try{return t()}finally{Ya()}}var q=void 0;function or(t){var e=q;q=void 0;try{return t()}finally{q=e}}var en=void 0,Xt=0,js=0,ha=0;function rr(t){if(q!==void 0){var e=t.n;if(e===void 0||e.t!==q)return e={i:0,S:t,p:q.s,n:void 0,t:q,e:void 0,x:void 0,r:e},q.s!==void 0&&(q.s.n=e),q.s=e,t.n=e,32&q.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=q.s,e.n=void 0,q.s.n=e,q.s=e),e}}function X(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}X.prototype.brand=Cl;X.prototype.h=function(){return!0};X.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:or(function(){var a;(a=e.W)==null||a.call(e)}))};X.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&or(function(){var s;(s=e.Z)==null||s.call(e)}))}};X.prototype.subscribe=function(t){var e=this;return Mn(function(){var n=e.value,a=q;q=void 0;try{t(n)}finally{q=a}},{name:"sub"})};X.prototype.valueOf=function(){return this.value};X.prototype.toString=function(){return this.value+""};X.prototype.toJSON=function(){return this.value};X.prototype.peek=function(){var t=q;q=void 0;try{return this.value}finally{q=t}};Object.defineProperty(X.prototype,"value",{get:function(){var t=rr(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(js>100)throw new Error("Cycle detected");this.v=t,this.i++,ha++,Xt++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Ya()}}}});function _(t,e){return new X(t,e)}function lr(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function cr(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function ur(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function _e(t,e){X.call(this,void 0),this.x=t,this.s=void 0,this.g=ha-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}_e.prototype=new X;_e.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===ha))return!0;if(this.g=ha,this.f|=1,this.i>0&&!lr(this))return this.f&=-2,!0;var t=q;try{cr(this),q=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return q=t,ur(this),this.f&=-2,!0};_e.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}X.prototype.S.call(this,t)};_e.prototype.U=function(t){if(this.t!==void 0&&(X.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};_e.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(_e.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=rr(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function vt(t,e){return new _e(t,e)}function dr(t){var e=t.u;if(t.u=void 0,typeof e=="function"){Xt++;var n=q;q=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,Ci(t),a}finally{q=n,Ya()}}}function Ci(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,dr(t)}function Rl(t){if(q!==this)throw new Error("Out-of-order effect");ur(this),q=t,this.f&=-2,8&this.f&&Ci(this),Ya()}function Ue(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Ue.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Ue.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,dr(this),cr(this),Xt++;var t=q;return q=this,Rl.bind(this,t)};Ue.prototype.N=function(){2&this.f||(this.f|=2,this.o=en,en=this)};Ue.prototype.d=function(){this.f|=8,1&this.f||Ci(this)};Ue.prototype.dispose=function(){this.d()};function Mn(t,e){var n=new Ue(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var pr,Vn,Dl=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,vr=[];Mn(function(){pr=this.N})();function He(t,e){j[t]=e.bind(null,j[t]||function(){})}function $a(t){if(Vn){var e=Vn;Vn=void 0,e()}Vn=t&&t.S()}function mr(t){var e=this,n=t.data,a=Pl(n);a.value=n;var s=ar(function(){for(var u=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var p=vt(function(){var m=a.value.value;return m===0?0:m===!0?"":m||""}),f=vt(function(){return!Array.isArray(p.value)&&!Ko(p.value)}),l=Mn(function(){if(this.N=fr,f.value){var m=p.value;u.__v&&u.__v.__e&&u.__v.__e.nodeType===3&&(u.__v.__e.data=m)}}),c=e.__$u.d;return e.__$u.d=function(){l(),c.call(this)},[f,p]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}mr.displayName="ReactiveTextNode";Object.defineProperties(X.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:mr},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});He("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof X&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});He("__r",function(t,e){if(t(e),e.type!==In){$a();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return Mn(function(){r=this},{name:i}),r.c=s,r})(function(){var s;Dl&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),$a(n)}});He("__e",function(t,e,n,a){$a(),t(e,n,a)});He("diffed",function(t,e){$a();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var u=i[r];u!==void 0&&!(r in a)&&(u.d(),i[r]=void 0)}else i={},n.U=i;for(var d in a){var p=i[d],f=a[d];p===void 0?(p=Ll(n,d,f),i[d]=p):p.o(f,s)}for(var l in a)s[l]=a[l]}}t(e)});function Ll(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=_(n),r=n.peek();return{o:function(u,d){i.value=u,r=u.peek()},d:Mn(function(){this.N=fr;var u=i.value.value;r!==u?(r=void 0,s?t[e]=u:u!=null&&(u!==!1||e[4]==="-")?t.setAttribute(e,u):t.removeAttribute(e)):r=void 0})}}He("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var u=r.__$u;u&&(r.__$u=void 0,u.d())}}t(e)});He("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});tn.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var u in this.props)if(!(u in t))return!0;return!1};function Pl(t,e){return ar(function(){return _(t,e)},[])}var El=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Il(){Nl(function(){for(var t;t=vr.shift();)pr.call(t)})}function fr(){vr.push(this)===1&&(j.requestAnimationFrame||El)(Il)}const Ml=["command","overview","board","activity","council","goals","execution","tasks","agents","ops","trpg"],_r={tab:"overview",params:{},postId:null},Ol={journal:"activity",mdal:"goals"};function Zi(t){return!!t&&Ml.includes(t)}function to(t){if(t)return Ol[t]??t}function Ks(t){try{return decodeURIComponent(t)}catch{return t}}function Us(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function zl(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function gr(t,e){const n=to(t[0]),a=to(e.tab),s=Zi(n)?n:Zi(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Ks(t[2]):t[0]==="post"&&t[1]&&(i=Ks(t[1]))),{tab:s,params:e,postId:i}}function ya(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return _r;const n=Ks(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const u=n.indexOf("?");u>=0&&(a=n.slice(0,u),s=n.slice(u+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=Us(s),r=zl(a);return gr(r,i)}function Fl(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{..._r,params:Us(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=Us(e.replace(/^\?/,""));return gr(a,s)}function hr(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const Pt=_(ya(window.location.hash));window.addEventListener("hashchange",()=>{Pt.value=ya(window.location.hash)});function yt(t,e){const n={tab:t,params:{},postId:null};window.location.hash=hr(n)}function ql(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function jl(){if(window.location.hash&&window.location.hash!=="#"){Pt.value=ya(window.location.hash);return}const t=Fl(window.location.pathname,window.location.search);if(t){Pt.value=t;const e=hr(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",Pt.value=ya(window.location.hash)}const eo="masc_dashboard_sse_session_id",Kl=1e3,Ul=15e3,jt=_(!1),On=_(0),$r=_(null),ee=_([]);function Hl(){let t=sessionStorage.getItem(eo);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(eo,t)),t}const Bl=200;function Wl(t,e,n="system",a={}){const s={agent:t,text:e,timestamp:Date.now(),kind:n,...a};ee.value=[s,...ee.value].slice(0,Bl)}function Hs(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function no(t,e){const n=Hs(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function ht(t,e,n,a,s={}){Wl(t,e,n,{eventType:a,...s})}let Lt=null,Ie=null,Bs=0;function yr(){Ie&&(clearTimeout(Ie),Ie=null)}function Gl(){if(Ie)return;Bs++;const t=Math.min(Bs,5),e=Math.min(Ul,Kl*Math.pow(2,t));Ie=setTimeout(()=>{Ie=null,br()},e)}function br(){yr(),Lt&&(Lt.close(),Lt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",Hl());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);Lt=i,i.onopen=()=>{Lt===i&&(Bs=0,jt.value=!0)},i.onerror=()=>{Lt===i&&(jt.value=!1,i.close(),Lt=null,Gl())},i.onmessage=r=>{try{const u=JSON.parse(r.data);On.value++,$r.value=u,Jl(u)}catch{}}}function Jl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":ht(n,"Joined","system","agent_joined");break;case"agent_left":ht(n,"Left","system","agent_left");break;case"broadcast":ht(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":ht(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":ht(n,no("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Hs(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":ht(n,no("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Hs(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":ht(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":ht(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":ht(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":ht(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:ht(n,e,"system","unknown")}}function Vl(){yr(),Lt&&(Lt.close(),Lt=null),jt.value=!1}function kr(){return new URLSearchParams(window.location.search)}function xr(){const t=kr(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Sr(){return{...xr(),"Content-Type":"application/json"}}const Ql=15e3,wr=3e4,Yl=6e4,ao=new Set([408,425,429,500,502,503,504]);class zn extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,i=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);xe(this,"method");xe(this,"path");xe(this,"status");xe(this,"statusText");xe(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function Ni(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new zn({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(s)}}function Xl(){var e,n;const t=kr();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function It(t){const e=await Ni(t,{headers:xr()},Ql);if(!e.ok)throw new zn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Zl(t){return new Promise(e=>setTimeout(e,t))}function tc(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function ec(t){if(t instanceof zn)return t.timeout||typeof t.status=="number"&&ao.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=tc(t.message);return e!==null&&ao.has(e)}async function Fn(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!ec(s)||a>=n)throw s;const i=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${i}ms`,s),await Zl(i),a+=1}}async function Mt(t,e,n){const a=await Ni(t,{method:"POST",headers:{...Sr(),...n??{}},body:JSON.stringify(e)},wr);if(!a.ok)throw new zn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function nc(t,e,n,a=wr){const s=await Ni(t,{method:"POST",headers:{...Sr(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new zn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function ac(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function sc(t){var e,n,a,s,i,r,u;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(d)}return((u=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:u.text)??""}async function lt(t,e){const n=await nc("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Yl),a=ac(n);return sc(a)}function ic(t="compact"){return It(`/api/v1/dashboard?mode=${t}`)}function oc(){return It("/api/v1/operator")}function rc(){return It("/api/v1/command-plane")}function lc(t,e){return Mt(t,e)}function qn(t){return Mt("/api/v1/operator/action",t)}function cc(t,e){return Mt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const uc=new Set(["lodge-system","team-session"]);function qe(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function dc(t){return uc.has(t.trim().toLowerCase())}function pc(t){return t.filter(e=>!dc(e.author))}function vc(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Ar(t){if(!E(t))return null;const e=g(t.id,"").trim(),n=g(t.author,"").trim(),a=g(t.content,"").trim();if(!e||!n)return null;const s=P(t.score,0),i=P(t.votes_up,0),r=P(t.votes_down,0),u=P(t.votes,s||i-r),d=P(t.comment_count,P(t.reply_count,0)),p=(()=>{const $=t.flair;if(typeof $=="string"&&$.trim())return $.trim();if(E($)){const w=g($.name,"").trim();if(w)return w}return g(t.flair_name,"").trim()||void 0})(),f=g(t.created_at_iso,"").trim()||qe(t.created_at),l=g(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?qe(t.updated_at):f),m=g(t.title,"").trim()||vc(a);return{id:e,author:n,title:m,content:a,tags:[],votes:u,vote_balance:s,comment_count:d,created_at:f,updated_at:l,flair:p,hearth_count:P(t.hearth_count,0)}}function mc(t){if(!E(t))return null;const e=g(t.id,"").trim(),n=g(t.post_id,"").trim(),a=g(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:g(t.content,""),created_at:qe(t.created_at)}}async function fc(t,e){return Fn("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),s=await It(`/api/v1/board${a?`?${a}`:""}`),i=Array.isArray(s.posts)?s.posts.map(Ar).filter(u=>u!==null):[];return{posts:e!=null&&e.excludeSystem?pc(i):i}})}async function _c(t){return Fn("fetchBoardPost",async()=>{const e=await It(`/api/v1/board/${t}?format=flat`),n=E(e.post)?e.post:e,a=Ar(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(mc).filter(r=>r!==null);return{...a,comments:i}})}function Tr(t,e){return Mt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Xl()})}function gc(t,e,n){return Mt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function hc(t){const e=g(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function et(...t){for(const e of t){const n=g(e,"");if(n.trim())return n.trim()}return""}function so(t){const e=hc(et(t.outcome,t.result,t.result_code));if(!e)return;const n=et(t.reason,t.reason_code,t.description,t.detail),a=et(t.summary,t.summary_ko,t.summary_en,t.note),s=et(t.details,t.details_text,t.text,t.note),i=et(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=et(t.winner_actor_id,t.winner_actor,t.actor_winner_id),u=et(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const l=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof l=="string"?[l]:Array.isArray(l)?l.map(c=>{if(typeof c=="string")return c.trim();if(E(c)){const m=g(c.summary,"").trim();if(m)return m;const $=g(c.text,"").trim();if($)return $;const b=g(c.type,"").trim();return b||g(c.event_id,"").trim()}return""}).filter(c=>c.length>0):[]})(),p=(()=>{const l=P(t.turn,Number.NaN);if(Number.isFinite(l))return l;const c=P(t.turn_number,Number.NaN);if(Number.isFinite(c))return c;const m=P(t.current_turn,Number.NaN);if(Number.isFinite(m))return m;const $=P(t.round,Number.NaN);return Number.isFinite($)?$:void 0})(),f=et(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:u||void 0,turn:p,phase:f||void 0}}function $c(t,e){const n=E(t.state)?t.state:{};if(g(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>E(r)?g(r.type,"")==="session.outcome":!1),i=E(n.session_outcome)?n.session_outcome:{};if(E(i)&&Object.keys(i).length>0){const r=so(i);if(r)return r}if(E(s))return so(E(s.payload)?s.payload:{})}function E(t){return typeof t=="object"&&t!==null}function g(t,e=""){return typeof t=="string"?t:e}function P(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Yt(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ws(t,e=!1){return typeof t=="boolean"?t:e}function Je(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(E(e)){const n=g(e.name,"").trim(),a=g(e.id,"").trim(),s=g(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function yc(t){const e={};if(!E(t)&&!Array.isArray(t))return e;if(E(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),i=g(a,"").trim();!s||!i||(e[s]=i)}),e;for(const n of t){if(!E(n))continue;const a=et(n.to,n.target,n.actor_id,n.name,n.id),s=et(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function bc(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function ft(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}const kc=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function xc(t){const e=E(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const i=a.trim();i&&(kc.has(i.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[i]=s))}),n}function Sc(t,e){if(t!=="dice.rolled")return;const n=P(e.raw_d20,0),a=P(e.total,0),s=P(e.bonus,0),i=g(e.action,"roll"),r=P(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function wc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Ac(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Tc(t,e,n,a){const s=n||e||g(a.actor_id,"")||g(a.actor_name,"");switch(t){case"turn.action.proposed":{const i=g(a.proposed_action,g(a.reply,""));return i?`${s||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=g(a.reply,g(a.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return g(a.reply,g(a.content,g(a.text,"Narration")));case"dice.rolled":{const i=g(a.action,"roll"),r=P(a.total,0),u=P(a.dc,0),d=g(a.label,""),p=s||"actor",f=u>0?` vs DC ${u}`:"",l=d?` (${d})`:"";return`${p} ${i}: ${r}${f}${l}`}case"turn.started":return`Turn ${P(a.turn,1)} started`;case"phase.changed":return`Phase: ${g(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${g(a.name,E(a.actor)?g(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${g(a.keeper_name,g(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${g(a.keeper_name,g(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${P(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${P(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||g(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||g(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${g(a.reason_code,"unknown")}`;case"memory.signal":{const i=E(a.entity_refs)?a.entity_refs:{},r=g(i.requested_tier,""),u=g(i.effective_tier,""),d=Ws(i.guardrail_applied,!1),p=g(a.summary_en,g(a.summary_ko,"Memory signal"));if(!r&&!u)return p;const f=r&&u?`${r}->${u}`:u||r;return`${p} [${f}${d?" (guardrail)":""}]`}case"world.event":{if(g(a.event_type,"")==="canon.check"){const r=g(a.status,"unknown"),u=g(a.contract_id,"n/a");return`Canon ${r}: ${u}`}return g(a.description,g(a.summary,"World event"))}case"combat.attack":return g(a.summary,g(a.result,"Attack resolved"));case"combat.defense":return g(a.summary,g(a.result,"Defense resolved"));case"session.outcome":return g(a.summary,g(a.outcome,"Session ended"));default:{const i=wc(a);return i?`${t}: ${i}`:t}}}function Cc(t,e){const n=E(t)?t:{},a=g(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=g(n.actor_name,"").trim()||e[s]||g(E(n.payload)?n.payload.actor_name:"",""),r=E(n.payload)?n.payload:{},u=g(n.ts,g(n.timestamp,new Date().toISOString())),d=g(n.phase,g(r.phase,"")),p=g(n.category,"");return{type:a,actor:i||s||g(r.actor_name,""),actor_id:s||g(r.actor_id,""),actor_name:i,seq:n.seq,room_id:g(n.room_id,""),phase:d||void 0,category:p||Ac(a),visibility:g(n.visibility,g(r.visibility,"public")),event_id:g(n.event_id,""),content:Tc(a,s,i,r),dice_roll:Sc(a,r),timestamp:u}}function Nc(t,e,n){var st,mt;const a=g(t.room_id,"")||n||"default",s=E(t.state)?t.state:{},i=E(s.party)?s.party:{},r=E(s.actor_control)?s.actor_control:{},u=E(s.join_gate)?s.join_gate:{},d=E(s.contribution_ledger)?s.contribution_ledger:{},p=Object.entries(i).map(([O,V])=>{const y=E(V)?V:{},oe=ft(y,"max_hp",void 0,10),Ge=ft(y,"hp",void 0,oe),Un=ft(y,"max_mp",void 0,0),Hn=ft(y,"mp",void 0,0),Bn=ft(y,"level",void 0,1),Wn=ft(y,"xp",void 0,0),Gn=Ws(y.alive,Ge>0),v=r[O],T=typeof v=="string"?v:void 0,F=bc(y.role,O,T),Z=Yt(y.generation),z=et(y.joined_at,y.joinedAt,y.started_at,y.startedAt),it=et(y.claimed_at,y.claimedAt,y.assigned_at,y.assignedAt,y.assigned_time),Q=et(y.last_seen,y.lastSeen,y.last_seen_at,y.lastSeenAt,y.last_active,y.lastActive),G=et(y.scene,y.current_scene,y.currentScene,y.world_scene,y.scene_name,y.sceneName),ot=et(y.location,y.current_location,y.currentLocation,y.position,y.zone,y.area);return{id:O,name:g(y.name,O),role:F,keeper:T,archetype:g(y.archetype,""),persona:g(y.persona,""),portrait:g(y.portrait,"")||void 0,background:g(y.background,"")||void 0,traits:Je(y.traits),skills:Je(y.skills),stats_raw:xc(y),status:Gn?"active":"dead",generation:Z,joined_at:z||void 0,claimed_at:it||void 0,last_seen:Q||void 0,scene:G||void 0,location:ot||void 0,inventory:Je(y.inventory),notes:Je(y.notes),relationships:yc(y.relationships),stats:{hp:Ge,max_hp:oe,mp:Hn,max_mp:Un,level:Bn,xp:Wn,strength:ft(y,"strength","str",10),dexterity:ft(y,"dexterity","dex",10),constitution:ft(y,"constitution","con",10),intelligence:ft(y,"intelligence","int",10),wisdom:ft(y,"wisdom","wis",10),charisma:ft(y,"charisma","cha",10)}}}),f=p.filter(O=>O.status!=="dead"),l=$c(t,e),c={phase_open:Ws(u.phase_open,!0),min_points:P(u.min_points,3),window:g(u.window,"round_boundary_only"),last_opened_turn:typeof u.last_opened_turn=="number"?u.last_opened_turn:null,last_closed_turn:typeof u.last_closed_turn=="number"?u.last_closed_turn:null},m=Object.entries(d).map(([O,V])=>{const y=E(V)?V:{};return{actor_id:O,score:P(y.score,0),last_reason:g(y.last_reason,"")||null,reasons:Je(y.reasons)}}),$=p.reduce((O,V)=>(O[V.id]=V.name,O),{}),b=e.map(O=>Cc(O,$)),w=P(s.turn,1),R=g(s.phase,"round"),A=g(s.map,""),M=E(s.world)?s.world:{},C=A||g(M.ascii_map,g(M.map,"")),L=b.filter((O,V)=>{const y=e[V];if(!E(y))return!1;const oe=E(y.payload)?y.payload:{};return P(oe.turn,-1)===w}),at=(L.length>0?L:b).slice(-12),At=g(s.status,"active");return{session:{id:a,room:a,status:At==="ended"?"ended":At==="paused"?"paused":"active",round:w,actors:f,created_at:((st=b[0])==null?void 0:st.timestamp)??new Date().toISOString()},current_round:{round_number:w,phase:R,events:at,timestamp:((mt=b[b.length-1])==null?void 0:mt.timestamp)??new Date().toISOString()},map:C||void 0,join_gate:c,contribution_ledger:m,outcome:l,party:f,story_log:b,history:[]}}async function Rc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await It(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Dc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([It(`/api/v1/trpg/state${e}`),Rc(t)]);return Nc(n,a,t)}function Lc(t){return Mt("/api/v1/trpg/rounds/run",{room_id:t})}function Pc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Ec(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Mt("/api/v1/trpg/dice/roll",e)}function Ic(t,e){const n=Pc();return Mt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Mc(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Mt("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function Oc(t,e,n){return Mt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function zc(t,e,n){const a=await lt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function Fc(t){const e=await lt("trpg.mid_join.request",t);return JSON.parse(e)}async function Cr(t,e){await lt("masc_broadcast",{agent_name:t,message:e})}async function qc(t,e,n=1){await lt("masc_add_task",{title:t,description:e,priority:n})}async function jc(t){return lt("masc_join",{agent_name:t})}async function Nr(t){await lt("masc_leave",{agent_name:t})}async function Kc(t){await lt("masc_heartbeat",{agent_name:t})}async function Uc(t=40){return(await lt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Hc(t,e=20){return lt("masc_task_history",{task_id:t,limit:e})}async function Bc(){return Fn("fetchDebates",async()=>{const t=await It("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!E(e))return null;const n=g(e.id,"").trim(),a=g(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:g(e.status,"open"),argument_count:P(e.argument_count,0),created_at:qe(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Wc(){return Fn("fetchCouncilSessions",async()=>{const t=await It("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!E(e))return null;const n=g(e.id,"").trim(),a=g(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:g(e.initiator,"system"),votes:P(e.votes,0),quorum:P(e.quorum,0),state:g(e.state,"open"),created_at:qe(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Gc(t){const e=await lt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Jc(t){return Fn("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await It(`/api/v1/council/debates/${e}/summary`);if(!E(n))return null;const a=g(n.id,"").trim();return a?{id:a,topic:g(n.topic,""),status:g(n.status,"open"),support_count:P(n.support_count,0),oppose_count:P(n.oppose_count,0),neutral_count:P(n.neutral_count,0),total_arguments:P(n.total_arguments,0),created_at:qe(n.created_at_iso??n.created_at),summary_text:g(n.summary_text,"")}:null})}function Vc(t,e,n){return lt("masc_keeper_msg",{name:t,message:e})}function Qc(t){const e=g(t,"").trim().toLowerCase();return e.startsWith("error")?"error":e==="running"||e==="completed"||e==="stopped"?e:"running"}function Yc(t){return E(t)?{iteration:Yt(t.iteration)??0,metric_before:P(t.metric_before,0),metric_after:P(t.metric_after,0),delta:P(t.delta,0),changes:g(t.changes,""),failed_attempts:g(t.failed_attempts,""),next_suggestion:g(t.next_suggestion,""),elapsed_ms:Yt(t.elapsed_ms)??0,cost_usd:typeof t.cost_usd=="number"&&Number.isFinite(t.cost_usd)?t.cost_usd:null}:null}function Xc(t){if(!E(t))return null;const e=g(t.loop_id,"").trim();if(!e)return null;const n=Array.isArray(t.history)?t.history.map(Yc).filter(a=>a!==null):[];return{loop_id:e,profile:g(t.profile,"custom"),status:Qc(t.status),current_iteration:Yt(t.iteration)??Yt(t.current_iteration)??0,max_iterations:Yt(t.max_iterations)??0,baseline_metric:P(t.baseline_metric,0),current_metric:P(t.current_metric,P(t.baseline_metric,0)),target:g(t.target,""),stagnation_streak:Yt(t.stagnation_streak)??0,stagnation_limit:Yt(t.stagnation_limit)??0,elapsed_seconds:P(t.elapsed_seconds,0),history:n}}function io(t){return t.trim().toLowerCase().includes("no mdal loop running")}async function Zc(){try{const t=await lt("masc_mdal_status",{}),e=JSON.parse(t),n=E(e)?g(e.error,"").trim():"";if(io(n))return{state:"idle"};if(n)return{state:"error",message:n};const a=Xc(e);return a?{state:"ready",loop:a}:{state:"error",message:"Unexpected MDAL payload"}}catch(t){const e=t instanceof Error?t.message:"Unknown MDAL fetch error";return io(e)?{state:"idle"}:{state:"error",message:e}}}async function tu(){try{const t=await lt("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const nn=_(""),Kt=_({}),nt=_({}),Gs=_({}),Js=_({}),Vs=_({}),Qs=_({}),Ut=_({});function tt(t,e,n){t.value={...t.value,[e]:n}}function Bt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function U(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function bt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function De(t){return typeof t=="boolean"?t:void 0}function Ys(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Xs(t){return Array.isArray(t)?t.map(e=>U(e)).filter(e=>!!e):[]}function eu(t){var n;const e=(n=U(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function nu(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function ss(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Bt(a))continue;const s=U(a.name);if(!s)continue;const i=U(a[e]);e==="summary"?n.push({name:s,summary:i}):n.push({name:s,reason:i})}return n}function au(t){if(!Bt(t))return null;const e=U(t.name);return e?{name:e,trigger:U(t.trigger),outcome:U(t.outcome),summary:U(t.summary),reason:U(t.reason)}:null}function su(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function iu(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function ba(t){if(!Bt(t))return null;const e=U(t.health_state),n=U(t.next_action_path),a=U(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:U(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:Ys(t.last_reply_at),last_reply_preview:U(t.last_reply_preview)??null,last_error:U(t.last_error)??null,next_eligible_at_s:bt(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,summary:U(t.summary),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Ri(t){return Bt(t)?{hour:bt(t.hour),checked:bt(t.checked)??0,acted:bt(t.acted)??0,acted_names:Xs(t.acted_names),activity_report:U(t.activity_report),quiet_hours_overridden:De(t.quiet_hours_overridden),skipped_reason:U(t.skipped_reason),acted_rows:ss(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:ss(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:ss(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(au).filter(e=>e!==null):[]}:null}function ou(t){return Bt(t)?{enabled:De(t.enabled)??!1,interval_s:bt(t.interval_s)??0,quiet_start:bt(t.quiet_start),quiet_end:bt(t.quiet_end),quiet_active:De(t.quiet_active),use_planner:De(t.use_planner),delegate_llm:De(t.delegate_llm),agent_count:bt(t.agent_count),agents:Xs(t.agents),last_tick_ago_s:bt(t.last_tick_ago_s)??null,last_tick_ago:U(t.last_tick_ago),total_ticks:bt(t.total_ticks),total_checkins:bt(t.total_checkins),last_skip_reason:U(t.last_skip_reason)??null,last_tick_result:Ri(t.last_tick_result),active_self_heartbeats:Xs(t.active_self_heartbeats)}:null}function ru(t){return Bt(t)?{status:t.status,diagnostic:ba(t.diagnostic)}:null}function lu(t){return Bt(t)?{recovered:De(t.recovered)??!1,skipped_reason:U(t.skipped_reason)??null,before:ba(t.before),after:ba(t.after),down:t.down,up:t.up}:null}function cu(t,e){var A,M;if(!(t!=null&&t.name))return null;const n=U((A=t.agent)==null?void 0:A.status)??U(t.status)??"unknown",a=U((M=t.agent)==null?void 0:M.error)??null,s=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,u=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,p=t.proactive_cooldown_sec??0,f=t.last_proactive_ago_s??null,l=d&&f!=null?Math.max(0,p-f):null,c=r<=0||u==null?"never":u>900?"stale":"fresh",m=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,$=a??(s&&!i?"keeper keepalive is not running":null),b=n==="offline"||n==="inactive"?"offline":$?"degraded":c==="stale"?"stale":c==="never"?"idle":"healthy",w=$?su($):e!=null&&e.quiet_active&&c!=="fresh"?"quiet_hours":s&&!i?"disabled":r<=0?"never_started":l!=null&&l>0?"min_gap":c==="fresh"||c==="stale"?"no_recent_activity":"unknown",R=b==="offline"||b==="degraded"||b==="stale"?"recover":w==="quiet_hours"?"manual_lodge_poke":w==="unknown"?"probe":"direct_message";return{health_state:b,quiet_reason:w,next_action_path:R,last_reply_status:c,last_reply_at:m,last_reply_preview:null,last_error:$,next_eligible_at_s:l!=null&&l>0?l:null,recoverable:R==="recover",summary:iu(b,w),keepalive_running:i}}function uu(t,e){if(!Bt(t))return null;const n=eu(t.role),a=U(t.content)??U(t.preview);if(!a)return null;const s=Ys(t.ts_unix)??Ys(t.timestamp);return{id:`${n}-${s??"entry"}-${e}`,role:n,label:nu(n),text:a,timestamp:s,delivery:"history"}}function du(t,e,n){const a=Bt(n)?n:null,s=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((i,r)=>uu(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:ba(a==null?void 0:a.diagnostic),history:s,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function oo(t,e){const n=nt.value[t]??[];nt.value={...nt.value,[t]:[...n,e].slice(-50)}}function pu(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function vu(t,e){const a=(nt.value[t]??[]).filter(s=>s.delivery!=="history"&&!e.some(i=>pu(s,i)));nt.value={...nt.value,[t]:[...e,...a].slice(-50)}}function Xa(t,e){Kt.value={...Kt.value,[t]:e},vu(t,e.history)}function ro(t,e){const n=Kt.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Xa(t,{...n,diagnostic:{...a,...e}})}async function Di(){je();try{await ge()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function la(t){nn.value=t.trim()}async function Rr(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Kt.value[n])return Kt.value[n];tt(Gs,n,!0),tt(Ut,n,null);try{const a=await lt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let s=null;try{s=JSON.parse(a)}catch{s=null}const i=du(n,a,s);return Xa(n,i),i}catch(a){const s=a instanceof Error?a.message:`Failed to inspect ${n}`;return tt(Ut,n,s),null}finally{tt(Gs,n,!1)}}async function mu(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const s=`local-${Date.now()}`;oo(n,{id:s,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),tt(Js,n,!0),tt(Ut,n,null);try{const i=await Vc(n,a);nt.value={...nt.value,[n]:(nt.value[n]??[]).map(r=>r.id===s?{...r,delivery:"delivered"}:r)},oo(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),ro(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await Di()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw nt.value={...nt.value,[n]:(nt.value[n]??[]).map(u=>u.id===s?{...u,delivery:"error",error:r}:u)},ro(n,{last_reply_status:"error",last_error:r}),tt(Ut,n,r),i}finally{tt(Js,n,!1)}}async function fu(t,e){const n=t.trim();if(!n)return null;tt(Vs,n,!0),tt(Ut,n,null);try{const a=await qn({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),s=ru(a.result),i=(s==null?void 0:s.diagnostic)??null;if(i){const r=Kt.value[n];Xa(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??nt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await Di(),i}catch(a){const s=a instanceof Error?a.message:`Failed to probe ${n}`;throw tt(Ut,n,s),a}finally{tt(Vs,n,!1)}}async function _u(t,e){const n=t.trim();if(!n)return null;tt(Qs,n,!0),tt(Ut,n,null);try{const a=await qn({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),s=lu(a.result),i=(s==null?void 0:s.after)??null;if(i){const r=Kt.value[n];Xa(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??nt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await Di(),i}catch(a){const s=a instanceof Error?a.message:`Failed to recover ${n}`;throw tt(Ut,n,s),a}finally{tt(Qs,n,!1)}}const se=_([]),Ot=_([]),fe=_([]),St=_([]),ie=_(null),Ze=_(null),Zs=_(new Map),Ht=_([]),wn=_("hot"),ce=_(!0),Dr=_(null),Ft=_(""),An=_([]),Le=_(!1),kt=_(new Map),ca=_("unknown"),ti=_(null),ei=_(!1),Tn=_(!1),ni=_(!1),Pe=_(!1),gu=_(null),ai=_(null),Lr=_(null),Pr=_(null),hu=vt(()=>se.value.filter(t=>t.status==="active"||t.status==="idle")),Er=vt(()=>{const t=Ot.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function $u(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const s=a.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const Ir=vt(()=>{const t=new Map;for(const e of St.value)t.set(e.name,$u(e));return t}),yu=12e4;function bu(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const s=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof s=="number"?Date.now()-s*1e3:null}const Mr=vt(()=>{const t=Date.now(),e=new Set,n=Zs.value;for(const a of St.value){const s=bu(a,n);s!=null&&t-s>yu&&e.add(a.name)}return e}),ka={},ku=5e3;function je(){delete ka.compact,delete ka.full}function gt(t){return typeof t=="object"&&t!==null}function x(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function N(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function an(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function xu(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Or(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function Su(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function wu(t){if(!gt(t))return null;const e=x(t.name);return e?{name:e,status:Or(t.status),current_task:x(t.current_task)??null,last_seen:x(t.last_seen),emoji:x(t.emoji),koreanName:x(t.koreanName)??x(t.korean_name),model:x(t.model),traits:an(t.traits),interests:an(t.interests),activityLevel:N(t.activityLevel)??N(t.activity_level),primaryValue:x(t.primaryValue)??x(t.primary_value)}:null}function Au(t){if(!gt(t))return null;const e=x(t.id),n=x(t.title);return!e||!n?null:{id:e,title:n,status:Su(t.status),priority:N(t.priority),assignee:x(t.assignee),description:x(t.description),created_at:x(t.created_at),updated_at:x(t.updated_at)}}function Tu(t){if(!gt(t))return null;const e=x(t.from)??x(t.from_agent)??"system",n=x(t.content)??"",a=x(t.timestamp)??new Date().toISOString();return{id:x(t.id),seq:N(t.seq),from:e,content:n,timestamp:a,type:x(t.type)}}function Cu(t){return Array.isArray(t)?t.map(e=>{if(!gt(e))return null;const n=N(e.ts_unix);if(n==null)return null;const a=gt(e.handoff)?e.handoff:null;return{ts:n,context_ratio:N(e.context_ratio)??0,context_tokens:N(e.context_tokens)??0,context_max:N(e.context_max)??0,latency_ms:N(e.latency_ms)??0,generation:N(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:N(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:N(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?N(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function lo(t){if(!gt(t))return null;const e=x(t.health_state),n=x(t.next_action_path),a=x(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:x(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:xu(t.last_reply_at)??x(t.last_reply_at)??null,last_reply_preview:x(t.last_reply_preview)??null,last_error:x(t.last_error)??null,next_eligible_at_s:N(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,summary:x(t.summary),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Nu(t,e){return(Array.isArray(t)?t:gt(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!gt(a))return null;const s=gt(a.agent)?a.agent:null,i=gt(a.context)?a.context:null,r=gt(a.metrics_window)?a.metrics_window:void 0,u=x(a.name);if(!u)return null;const d=N(a.context_ratio)??N(i==null?void 0:i.context_ratio),p=x(a.status)??x(s==null?void 0:s.status)??"offline",f=Or(p),l=x(a.model)??x(a.active_model)??x(a.primary_model),c=an(a.skill_secondary),m=i?{source:x(i.source),context_ratio:N(i.context_ratio),context_tokens:N(i.context_tokens),context_max:N(i.context_max),message_count:N(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,$=s?{name:x(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:x(s.error),status:x(s.status),current_task:x(s.current_task)??null,last_seen:x(s.last_seen),last_seen_ago_s:N(s.last_seen_ago_s),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0,b=Cu(a.metrics_series),w={name:u,emoji:x(a.emoji),koreanName:x(a.koreanName)??x(a.korean_name),agent_name:x(a.agent_name),trace_id:x(a.trace_id),model:l,primary_model:x(a.primary_model),active_model:x(a.active_model),next_model_hint:x(a.next_model_hint)??null,status:f,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:N(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:N(a.proactive_idle_sec),proactive_cooldown_sec:N(a.proactive_cooldown_sec),last_heartbeat:x(a.last_heartbeat)??x(s==null?void 0:s.last_seen),generation:N(a.generation),turn_count:N(a.turn_count)??N(a.total_turns),keeper_age_s:N(a.keeper_age_s),last_turn_ago_s:N(a.last_turn_ago_s),last_handoff_ago_s:N(a.last_handoff_ago_s),last_compaction_ago_s:N(a.last_compaction_ago_s),last_proactive_ago_s:N(a.last_proactive_ago_s),context_ratio:d,context_tokens:N(a.context_tokens)??N(i==null?void 0:i.context_tokens),context_max:N(a.context_max)??N(i==null?void 0:i.context_max),context_source:x(a.context_source)??x(i==null?void 0:i.source),context:m,traits:an(a.traits),interests:an(a.interests),primaryValue:x(a.primaryValue)??x(a.primary_value),activityLevel:N(a.activityLevel)??N(a.activity_level),memory_recent_note:x(a.memory_recent_note)??null,conversation_tail_count:N(a.conversation_tail_count),k2k_count:N(a.k2k_count),handoff_count_total:N(a.handoff_count_total)??N(a.trace_history_count),compaction_count:N(a.compaction_count),last_compaction_saved_tokens:N(a.last_compaction_saved_tokens),diagnostic:lo(a.diagnostic),skill_primary:x(a.skill_primary)??null,skill_secondary:c,skill_reason:x(a.skill_reason)??null,metrics_series:b.length>0?b:void 0,metrics_window:r,agent:$};return w.diagnostic=lo(a.diagnostic)??cu(w,(e==null?void 0:e.lodge)??null),w}).filter(a=>a!==null)}function Ru(t){return gt(t)?{...t,lodge:ou(t.lodge)??void 0}:null}async function ge(t="full"){var a,s,i;const e=Date.now(),n=ka[t];if(!(n&&e-n.time<ku)){ei.value=!0;try{const r=await ic(t);ka[t]={data:r,time:e},se.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(wu).filter(d=>d!==null),Ot.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(Au).filter(d=>d!==null),fe.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(Tu).filter(d=>d!==null);const u=Ru(r.status);ie.value=u,St.value=Nu(r.keepers,u),Ze.value=r.perpetual??null,gu.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{ei.value=!1}}}async function Et(){Tn.value=!0;try{const t=await fc(wn.value,{excludeSystem:ce.value});Ht.value=t.posts??[],ai.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Tn.value=!1}}async function qt(){var t;ni.value=!0;try{const e=Ft.value||((t=ie.value)==null?void 0:t.room)||"default";Ft.value||(Ft.value=e);const n=await Dc(e);Dr.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ni.value=!1}}async function sn(){Le.value=!0;try{const t=await tu();An.value=Array.isArray(t)?t:[],Lr.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Le.value=!1}}async function on(){const t=++rs;Pe.value=!0;try{const e=await Zc();if(t!==rs)return;if(e.state==="error"){ca.value="error",ti.value=e.message;return}if(Pr.value=new Date().toISOString(),ti.value=null,e.state==="idle"){ca.value="idle";const i=new Map(kt.value);for(const[r,u]of i.entries())u.status==="running"&&i.set(r,{...u,status:"stopped"});kt.value=i;return}const n=e.loop;ca.value="ready";const a=new Map(kt.value),s=a.get(n.loop_id);a.set(n.loop_id,{...s??{},...n,history:n.history.length>0?n.history:(s==null?void 0:s.history)??[]}),kt.value=a}catch(e){console.error("MDAL fetch error:",e)}finally{t===rs&&(Pe.value=!1)}}let is=null,os=null,rs=0;function Du(){return $r.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Zs.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Zs.value=n}if(je(),is||(is=setTimeout(()=>{ge(),is=null},500)),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&(os||(os=setTimeout(()=>{Et(),os=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&je(),e.type==="mdal_started"&&e.loop_id){const n=new Map(kt.value);n.set(e.loop_id,{...n.get(e.loop_id)??{},loop_id:e.loop_id,profile:e.profile??"custom",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??0,current_metric:e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]}),kt.value=n}if(e.type==="mdal_iteration"&&e.loop_id){const n=new Map(kt.value),a=e.metric_before??e.metric_after??0,s=e.metric_after??a,i=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:a,current_metric:s,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]},r={iteration:e.iteration??0,metric_before:a,metric_after:s,delta:e.delta??0,changes:"",failed_attempts:"",next_suggestion:"",elapsed_ms:0,cost_usd:null};n.set(e.loop_id,{...i,current_iteration:e.iteration??i.current_iteration,current_metric:s,history:[r,...i.history]}),kt.value=n}if((e.type==="mdal_completed"||e.type==="mdal_stopped")&&e.loop_id){const n=new Map(kt.value),a=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??e.metric_before??e.metric_after??0,current_metric:e.metric_after??e.metric_before??e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]};n.set(e.loop_id,{...a,current_iteration:e.iteration??a.current_iteration,current_metric:e.metric_after??a.current_metric,status:e.type==="mdal_completed"?"completed":"stopped"}),kt.value=n}}})}let rn=null;function Lu(){rn||(rn=setInterval(()=>{je(),ge()},1e4))}function Pu(){rn&&(clearInterval(rn),rn=null)}function S({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function wt({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Eu(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function K({timestamp:t}){const e=Eu(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function re(t){return(t??"").trim().toLowerCase()}function ct(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ua(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Qn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ve(t){return t.last_heartbeat??Qn(t.last_turn_ago_s)??Qn(t.last_proactive_ago_s)??Qn(t.last_handoff_ago_s)??Qn(t.last_compaction_ago_s)}function Iu(t){const e=t.title.trim();return e||ua(t.content)}function Mu(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Cn(t,e,n,a,s={}){var M;const i=re(t),r=e.filter(C=>re(C.assignee)===i&&(C.status==="claimed"||C.status==="in_progress")).length,u=n.filter(C=>re(C.from)===i).sort((C,L)=>ct(L.timestamp)-ct(C.timestamp))[0],d=a.filter(C=>re(C.agent)===i||re(C.author)===i).sort((C,L)=>ct(L.timestamp)-ct(C.timestamp))[0],p=(s.boardPosts??[]).filter(C=>re(C.author)===i).sort((C,L)=>ct(L.updated_at||L.created_at)-ct(C.updated_at||C.created_at))[0],f=(s.keepers??[]).filter(C=>re(C.name)===i&&Ve(C)!==null).sort((C,L)=>ct(Ve(L)??0)-ct(Ve(C)??0))[0],l=u?ct(u.timestamp):0,c=d?ct(d.timestamp):0,m=p?ct(p.updated_at||p.created_at):0,$=f?ct(Ve(f)??0):0,b=s.lastSeen?ct(s.lastSeen):0,w=((M=s.currentTask)==null?void 0:M.trim())||(r>0?`${r} claimed tasks`:null);if(l===0&&c===0&&m===0&&$===0&&b===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:w};const A=[u?{timestamp:u.timestamp,ts:l,text:ua(u.content)}:null,p?{timestamp:p.updated_at||p.created_at,ts:m,text:`Post: ${ua(Iu(p))}`}:null,f?{timestamp:Ve(f),ts:$,text:Mu(f)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:c,text:ua(d.text)}:null].filter(C=>C!==null).sort((C,L)=>L.ts-C.ts)[0];return A&&A.ts>=b?{activeAssignedCount:r,lastActivityAt:A.timestamp,lastActivityText:A.text}:{activeAssignedCount:r,lastActivityAt:s.lastSeen??null,lastActivityText:w??"Presence heartbeat"}}let Ou=0;const ue=_([]);function k(t,e="success",n=4e3){const a=++Ou;ue.value=[...ue.value,{id:a,message:t,type:e}],setTimeout(()=>{ue.value=ue.value.filter(s=>s.id!==a)},n)}function zu(t){ue.value=ue.value.filter(e=>e.id!==t)}function Fu(){const t=ue.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>zu(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}function qu(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function ju(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Ku(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function co(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function zr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Uu(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Fr(t){if(!t)return null;const e=Kt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function qr({keeper:t,showRawStatus:e=!1}){if(xt(()=>{t!=null&&t.name&&Rr(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Kt.value[t.name],a=Fr(t),s=Gs.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${qu(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${ju((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${s?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?o` · ${zr(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?o` · next eligible ${Uu(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?o`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function jr({keeperName:t,placeholder:e}){const[n,a]=nr("");xt(()=>{t&&Rr(t)},[t]);const s=nt.value[t]??[],i=Js.value[t]??!1,r=Ut.value[t],u=async()=>{const d=n.trim();if(!(!t||!d)){a("");try{await mu(t,d)}catch(p){const f=p instanceof Error?p.message:`Failed to message ${t}`;k(f,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${s.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:s.map(d=>o`
              <div class="keeper-conversation-item" key=${d.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${co(d)}`}>${d.label}</span>
                  <span class=${`keeper-role-chip ${co(d)}`}>${Ku(d)}</span>
                  ${d.timestamp?o`<span class="keeper-conversation-time">${zr(d.timestamp)}</span>`:null}
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
  `}function Kr({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=Fr(e),s=Vs.value[e.name]??!1,i=Qs.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{fu(e.name,t).catch(u=>{const d=u instanceof Error?u.message:`Failed to probe ${e.name}`;k(d,"error")})}}
        disabled=${s||!t.trim()}
      >
        ${s?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{_u(e.name,t).catch(u=>{const d=u instanceof Error?u.message:`Failed to recover ${e.name}`;k(d,"error")})}}
        disabled=${i||!(a!=null&&a.recoverable)||!t.trim()}
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
  `}const Li=_(null);function xa(t){Li.value=t,la(t.name)}function uo(){Li.value=null}const Te=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Hu(t){if(!t)return 0;const e=Te.findIndex(n=>n.level===t);return e>=0?e:0}function Bu({keeper:t}){const e=Hu(t.autonomy_level),n=Te[e]??Te[0];if(!n)return null;const a=(e+1)/Te.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Te.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Te.map((s,i)=>o`
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
            <strong><${K} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function da(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Wu({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${s.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${da(t.context_tokens)}</div>
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
  `}function Gu({keeper:t}){var f,l;const e=t.metrics_series??[];if(e.length<2){const c=(((f=t.context)==null?void 0:f.context_ratio)??0)*100,m=c>85?"#ef4444":c>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${c.toFixed(1)}%;background:${m}"></div>
        </div>
        <span class="chart-pct">${c.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,i=e.length,r=e.map((c,m)=>{const $=s+m/(i-1)*(n-2*s),b=a-s-(c.context_ratio??0)*(a-2*s);return{x:$,y:b,p:c}}),u=r.map(({x:c,y:m})=>`${c.toFixed(1)},${m.toFixed(1)}`).join(" "),d=(((l=e[e.length-1])==null?void 0:l.context_ratio)??0)*100,p=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:c})=>c.is_handoff).map(({x:c})=>o`
          <line x1="${c.toFixed(1)}" y1="${s}" x2="${c.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${u}" fill="none" stroke="${p}" stroke-width="1.5"/>
        ${r.filter(({p:c})=>c.is_compaction).map(({x:c,y:m})=>o`
          <circle cx="${c.toFixed(1)}" cy="${m.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const ls=_("");function Ju({keeper:t}){var s,i,r,u;const e=ls.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ls.value}
        onInput=${d=>{ls.value=d.target.value}}
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${da(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${da(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${da(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((u=t.context)==null?void 0:u.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Vu({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function Qu({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Yu({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function po({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function cs(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Xu({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:cs(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:cs(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:cs(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function Ur(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Zu(){try{const t=await qn({actor:Ur(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Ri(t.result);je(),await ge(),e!=null&&e.skipped_reason?k(e.skipped_reason,"warning"):k(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";k(e,"error")}}function td({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${qr} keeper=${t} />
          <${Kr}
            actor=${Ur()}
            keeper=${t}
            onPokeLodge=${()=>{Zu()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${jr}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function ed(){var e,n,a;const t=Li.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&uo()}}
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
            <${wt} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>uo()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Wu} keeper=${t} />

        ${""}
        <${Gu} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${S} title="Field Dictionary">
            <${Ju} keeper=${t} />
          <//>

          ${""}
          <${S} title="Profile">
            <${po} traits=${t.traits??[]} label="Traits" />
            <${po} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${K} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${S} title="Autonomy">
                <${Bu} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${S} title="TRPG Stats">
                <${Vu} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${S} title="Equipment (${t.inventory.length})">
                <${Qu} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${S} title="Relationships (${Object.keys(t.relationships).length})">
                <${Yu} rels=${t.relationships} />
              <//>
            `:null}

          <${S} title="Runtime Signals">
            <${Xu} keeper=${t} />
          <//>

          <${S} title="Memory & Context">
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
        <${td} keeper=${t} />
      </div>
    </div>
  `:null}const nd="masc_dashboard_agent_name",Be=_(null),Sa=_(!1),Nn=_(""),wa=_([]),Rn=_([]),Me=_(""),ln=_(!1);function Oe(t){Be.value=t,Pi()}function vo(){Be.value=null,Nn.value="",wa.value=[],Rn.value=[],Me.value=""}function ad(){const t=Be.value;return t?se.value.find(e=>e.name===t)??null:null}function Hr(t){return t?Ot.value.filter(e=>e.assignee===t):[]}async function Pi(){const t=Be.value;if(t){Sa.value=!0,Nn.value="",wa.value=[],Rn.value=[];try{const e=await Uc(80);wa.value=e.filter(s=>s.includes(t)).slice(0,20);const n=Hr(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await Hc(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));Rn.value=a}catch(e){Nn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Sa.value=!1}}}async function mo(){var a;const t=Be.value,e=Me.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(nd))==null?void 0:a.trim())||"dashboard";ln.value=!0;try{await Cr(n,`@${t} ${e}`),Me.value="",k(`Mention sent to ${t}`,"success"),Pi()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";k(i,"error")}finally{ln.value=!1}}function sd({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${wt} status=${t.status} />
    </div>
  `}function id({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function od(){var s,i,r,u;const t=Be.value;if(!t)return null;const e=ad(),n=Hr(t),a=wa.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&vo()}}
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
                        <${wt} status=${e.status} />
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
                    ${e.last_seen?o`<span>Last seen: <${K} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Pi()}} disabled=${Sa.value}>
              ${Sa.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${vo}>Close</button>
          </div>
        </div>

        ${Nn.value?o`<div class="council-error">${Nn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${S} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${sd} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${S} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((d,p)=>o`<div key=${p} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${S} title="Task History">
          ${Rn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Rn.value.map(d=>o`<${id} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${S} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Me.value}
              onInput=${d=>{Me.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&mo()}}
              disabled=${ln.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{mo()}}
              disabled=${ln.value||Me.value.trim()===""}
            >
              ${ln.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const us=600*1e3,ds=1200*1e3,fo=.8;function Ct(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Wt(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function _o(t){return(t??"").trim().toLowerCase()}function Gt(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function Ce(t){return typeof t!="number"||Number.isNaN(t)?3:t}function rd(t){const e=Ce(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}function Se(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function Yn(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function go(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function ho(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function ld(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function ps(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function cd(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function ud(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function dd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function pd(t){return t?t.enabled?t.quiet_active?`Quiet hours ${go(t.quiet_start)}-${go(t.quiet_end)} KST are active.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${ho(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${ho(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function $o(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function we({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function vd({item:t}){return o`
    <button class="monitor-alert ${t.tone}" onClick=${t.action}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.detail}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">${t.tone==="bad"?"Act now":t.tone==="warn"?"Watch":"Stable"}</span>
        ${t.timestamp?o`<span><${K} timestamp=${t.timestamp} /></span>`:null}
      </div>
    </button>
  `}function vs({tone:t,title:e,subtitle:n,meta:a,focus:s,onClick:i}){return o`
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
  `}function yo(){var C,L,at,At,Tt,st,mt,O,V,y,oe,Ge,Un,Hn,Bn,Wn,Gn;const t=ie.value,e=se.value,n=Ot.value,a=St.value,s=Er.value,i=(C=t==null?void 0:t.monitoring)==null?void 0:C.board,r=(L=t==null?void 0:t.monitoring)==null?void 0:L.council,u=jt.value,d=new Map(e.map(v=>[_o(v.name),v])),p=e.map(v=>{var Fi;const T=Cn(v.name,n,fe.value,ee.value,{currentTask:v.current_task,lastSeen:v.last_seen,boardPosts:Ht.value,keepers:a}),F=T.lastActivityAt??v.last_seen??null,Z=F?Math.max(0,Date.now()-Ct(F)):Number.POSITIVE_INFINITY,z=T.activeAssignedCount,it=!!((Fi=v.current_task)!=null&&Fi.trim()),Q=it||z>0;let G="ok",ot="Fresh and ready",be=!1,ke=!1;return v.status==="offline"||v.status==="inactive"?(G=Q?"bad":"warn",ot=Q?"Load without an available owner":"Offline"):Q&&Z>ds?(G="bad",ot="Execution is stale"):z>0&&!it?(G="warn",ot="Claimed work has no current_task",ke=!0):it&&z===0?(G="warn",ot="current_task has no claimed work",ke=!0):!Q&&Z<=us?(G="ok",ot="Dispatchable now",be=!0):!Q&&Z>ds?(G="warn",ot="Idle but not freshly active"):Q&&Z>us&&(G="warn",ot="Execution is getting quiet"),{agent:v,lastSignalAt:F,activeTaskCount:z,tone:G,note:ot,focus:Gt(v.current_task)??T.lastActivityText??(be?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:be,drift:ke}}).sort((v,T)=>{const F=Wt(T.tone)-Wt(v.tone);return F!==0?F:Ct(T.lastSignalAt)-Ct(v.lastSignalAt)}),f=a.map(v=>{var G;const T=Ir.value.get(v.name)??"idle",F=Mr.value.has(v.name),Z=v.context_ratio??0,z=v.diagnostic??null;let it="ok",Q="Healthy keeper";return F||v.status==="offline"||T==="handoff-imminent"||(z==null?void 0:z.health_state)==="offline"||(z==null?void 0:z.health_state)==="degraded"?(it="bad",Q=Gt(z==null?void 0:z.summary,56)??(F?"Heartbeat stale":T==="handoff-imminent"?"Handoff imminent":(z==null?void 0:z.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((z==null?void 0:z.health_state)==="stale"||Z>=fo||T==="preparing"||T==="compacting")&&(it="warn",Q=Gt(z==null?void 0:z.summary,56)??(Z>=fo?"High context pressure":`Lifecycle ${T}`)),{keeper:v,tone:it,note:Q,focus:Gt(z==null?void 0:z.summary,120)??Gt((G=v.agent)==null?void 0:G.current_task)??v.skill_primary??v.last_proactive_reason??v.memory_recent_note??"No active focus",timestamp:v.last_heartbeat??null}}).sort((v,T)=>{const F=Wt(T.tone)-Wt(v.tone);return F!==0?F:Ct(T.timestamp)-Ct(v.timestamp)}),l=n.filter(v=>v.status==="todo"||v.status==="claimed"||v.status==="in_progress").map(v=>{var be,ke;const T=v.assignee?d.get(_o(v.assignee))??null:null,F=T?Cn(T.name,n,fe.value,ee.value,{currentTask:T.current_task,lastSeen:T.last_seen,boardPosts:Ht.value,keepers:a}):null,Z=(F==null?void 0:F.lastActivityAt)??(T==null?void 0:T.last_seen)??null,z=Z?Math.max(0,Date.now()-Ct(Z)):Number.POSITIVE_INFINITY,it=v.status==="claimed"||v.status==="in_progress";let Q="ok",G="Covered",ot=!1;return v.assignee?!T||T.status==="offline"||T.status==="inactive"?(Q="bad",G="Assigned owner is unavailable",ot=!0):it&&z>ds?(Q="bad",G="Execution has lost a fresh signal"):it&&z>us?(Q="warn",G="Execution is drifting quiet"):v.status==="todo"&&Ce(v.priority)<=2&&!((be=T.current_task)!=null&&be.trim())&&((F==null?void 0:F.activeAssignedCount)??0)===0?(Q="ok",G="Ready for dispatch"):it&&!((ke=T.current_task)!=null&&ke.trim())&&(Q="warn",G="Owner focus is not explicit"):(Q=Ce(v.priority)<=2?"bad":"warn",G=it?"Active work has no owner":"Ready work has no owner",ot=!0),{task:v,owner:T,lastSignalAt:Z,tone:Q,note:G,focus:Gt(T==null?void 0:T.current_task)??(F==null?void 0:F.lastActivityText)??Gt(v.description)??"Needs operator attention.",ownerGap:ot}}).sort((v,T)=>{const F=Wt(T.tone)-Wt(v.tone);if(F!==0)return F;const Z=Ce(v.task.priority)-Ce(T.task.priority);return Z!==0?Z:Ct(T.lastSignalAt??T.task.updated_at??T.task.created_at)-Ct(v.lastSignalAt??v.task.updated_at??v.task.created_at)}),c=l.filter(v=>v.task.status==="todo"&&Ce(v.task.priority)<=2),m=l.filter(v=>v.ownerGap).length,$=p.filter(v=>v.dispatchable),b=p.filter(v=>v.drift||v.tone!=="ok"),w=f.filter(v=>v.tone!=="ok"),R=t!=null&&t.paused?"bad":((at=t==null?void 0:t.data_quality)==null?void 0:at.board_contract_ok)===!1||((At=t==null?void 0:t.data_quality)==null?void 0:At.council_feed_ok)===!1?"warn":u?"ok":"warn",A=[];t!=null&&t.paused&&A.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((Tt=t.data_quality)==null?void 0:Tt.last_sync_at)??null,action:()=>yt("ops")}),u||A.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:()=>yt("activity")}),Se(i==null?void 0:i.alert_level)!=="ok"&&A.push({key:"board-monitor",tone:Se(i==null?void 0:i.alert_level),title:"Board feed needs attention",detail:`Freshness ${ps(i==null?void 0:i.last_activity_age_s)} · ${(i==null?void 0:i.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>yt("board")}),Se(r==null?void 0:r.alert_level)!=="ok"&&A.push({key:"council-monitor",tone:Se(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${ps(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>yt("council")}),(((st=t==null?void 0:t.data_quality)==null?void 0:st.board_contract_ok)===!1||((mt=t==null?void 0:t.data_quality)==null?void 0:mt.council_feed_ok)===!1)&&A.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((O=t.data_quality)==null?void 0:O.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((V=t.data_quality)==null?void 0:V.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((y=t.data_quality)==null?void 0:y.last_sync_at)??null,action:()=>yt("ops")});const M=[...A,...l.filter(v=>v.tone!=="ok").slice(0,3).map(v=>({key:`task-${v.task.id}`,tone:v.tone,title:v.task.title,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt??v.task.updated_at??v.task.created_at??null,action:()=>yt("execution")})),...w.slice(0,2).map(v=>({key:`keeper-${v.keeper.name}`,tone:v.tone,title:v.keeper.name,detail:`${v.note} · ${v.focus}`,timestamp:v.timestamp,action:()=>xa(v.keeper)})),...b.slice(0,2).map(v=>({key:`agent-${v.agent.name}`,tone:v.tone,title:v.agent.name,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt,action:()=>Oe(v.agent.name)}))].sort((v,T)=>{const F=Wt(T.tone)-Wt(v.tone);return F!==0?F:Ct(T.timestamp)-Ct(v.timestamp)}).slice(0,8);return o`
    <div class="stats-grid">
      <${we}
        label="Room State"
        value=${t!=null&&t.paused?"Paused":"Running"}
        color=${Yn(R)}
        caption=${(t==null?void 0:t.room)??(t==null?void 0:t.project)??"default room"}
      />
      <${we}
        label="Urgent Queue"
        value=${c.length}
        color=${c.length>0?"#fb7185":"#4ade80"}
        caption="todo tasks at P1/P2"
      />
      <${we}
        label="Active Work"
        value=${s.inProgress.length}
        color="#fbbf24"
        caption="claimed + in progress"
      />
      <${we}
        label="Dispatchable"
        value=${$.length}
        color="#22d3ee"
        caption="fresh agents with no load"
      />
      <${we}
        label="Keeper Pressure"
        value=${w.length}
        color=${w.length>0?"#fbbf24":"#4ade80"}
        caption="stale or high-context keepers"
      />
      <${we}
        label="Owner Gaps"
        value=${m}
        color=${m>0?"#fb7185":"#4ade80"}
        caption="tasks missing a live owner"
      />
    </div>

    <${S} title="Room Health" class="section">
      <div class="monitor-section-head">
        <h2 class="monitor-headline">Operational health at a glance</h2>
        <p class="monitor-subheadline">The Overview now prioritizes room state, feed freshness, and immediate intervention signals over full entity dumps.</p>
      </div>
      <div class="overview-health-grid">
        <div class="stat-card">
          <div class="stat-label">Live Feed</div>
          <div class="stat-value" style=${`color:${u?"#4ade80":"#fbbf24"}`}>${u?"Online":"Retrying"}</div>
          <div class="monitor-stat-caption">${On.value} events seen in this session</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Board Feed</div>
          <div class="stat-value" style=${`color:${Yn(Se(i==null?void 0:i.alert_level))}`}>${$o(i==null?void 0:i.alert_level)}</div>
          <div class="monitor-stat-caption">Freshness ${ps(i==null?void 0:i.last_activity_age_s)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Council Feed</div>
          <div class="stat-value" style=${`color:${Yn(Se(r==null?void 0:r.alert_level))}`}>${$o(r==null?void 0:r.alert_level)}</div>
          <div class="monitor-stat-caption">${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Runtime</div>
          <div class="stat-value" style=${`color:${Yn(R)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${ld((t==null?void 0:t.uptime_seconds)??0)}</div>
        </div>
      </div>
      <div class="overview-note-stack">
        <div class="overview-inline-note">
          ${(oe=t==null?void 0:t.data_quality)!=null&&oe.last_sync_at?o`Last sync <${K} timestamp=${t.data_quality.last_sync_at} />`:o`No sync metadata yet`}
        </div>
        <div class="overview-inline-note">
          ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
        </div>
        <div class="overview-inline-note">${pd(t==null?void 0:t.lodge)}</div>
        ${(Ge=t==null?void 0:t.lodge)!=null&&Ge.last_skip_reason?o`<div class="overview-inline-note">Last Lodge skip: ${t.lodge.last_skip_reason}</div>`:null}
      </div>
    <//>

    <div class="grid-2col">
      <${S} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs intervention right now</h2>
          <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
        </div>
        <div class="monitor-alert-list">
          ${M.length===0?o`<div class="empty-state">No immediate intervention required</div>`:M.map(v=>o`<${vd} key=${v.key} item=${v} />`)}
        </div>
      <//>

      <${S} title="Dispatch Window" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who can pick up work next</h2>
          <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${$.length===0?o`<div class="empty-state">No fully dispatchable agents right now</div>`:$.slice(0,5).map(v=>o`
                <${vs}
                  key=${v.agent.name}
                  tone=${v.tone}
                  title=${v.agent.name}
                  subtitle=${v.note}
                  meta=${[v.lastSignalAt?`Signal ${new Date(v.lastSignalAt).toLocaleTimeString()}`:"No recent signal",v.agent.model??"model n/a",v.agent.koreanName??"room agent"]}
                  focus=${v.focus}
                  onClick=${()=>Oe(v.agent.name)}
                />
              `)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${S} title="Execution Pulse" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Priority work and ownership drift</h2>
          <p class="monitor-subheadline">Urgent ready tasks and active execution issues stay visible without duplicating the full Execution surface.</p>
        </div>
        <div class="monitor-list">
          ${l.length===0?o`<div class="empty-state">No active or ready tasks</div>`:l.slice(0,6).map(v=>o`
                <${vs}
                  key=${v.task.id}
                  tone=${v.tone}
                  title=${v.task.title}
                  subtitle=${`${rd(v.task.priority)} · ${v.note}`}
                  meta=${[v.task.assignee?`Owner ${v.task.assignee}`:"Unassigned",v.lastSignalAt?`Signal ${new Date(v.lastSignalAt).toLocaleTimeString()}`:"No live signal",v.task.updated_at?`Touched ${new Date(v.task.updated_at).toLocaleTimeString()}`:"No task timestamp"]}
                  focus=${v.focus}
                  onClick=${()=>yt("execution")}
                />
              `)}
        </div>
      <//>

      <${S} title="Keeper Pressure" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Long-running keepers under pressure</h2>
          <p class="monitor-subheadline">Only keepers with real pressure stay in the Overview. The full keeper census still lives in the Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${w.length===0?o`<div class="empty-state">No keeper pressure signals right now</div>`:w.slice(0,5).map(v=>{var T;return o`
                <${vs}
                  key=${v.keeper.name}
                  tone=${v.tone}
                  title=${v.keeper.name}
                  subtitle=${(T=v.keeper.diagnostic)!=null&&T.health_state?`${v.note} · ${v.keeper.diagnostic.health_state}`:v.note}
                  meta=${[v.timestamp?`Heartbeat ${new Date(v.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof v.keeper.context_ratio=="number"?Math.round(v.keeper.context_ratio*100):0}%`,v.keeper.model?`Model ${v.keeper.model}`:"model n/a",v.keeper.diagnostic?`${ud(v.keeper.diagnostic.quiet_reason)} · next ${dd(v.keeper.diagnostic.next_action_path)} · reply ${v.keeper.diagnostic.last_reply_status}`:"Diagnostic unavailable"]}
                  focus=${v.focus}
                  onClick=${()=>xa(v.keeper)}
                />
              `})}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${S} title="Agent Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Agents with drift or aging load</h2>
          <p class="monitor-subheadline">This is the short list. Use the Agents tab when you need the full live monitor.</p>
        </div>
        <div class="monitor-list">
          ${b.length===0?o`<div class="empty-state">No agent drift or stale load right now</div>`:b.slice(0,5).map(v=>o`
                <button class="monitor-row ${v.tone}" onClick=${()=>Oe(v.agent.name)}>
                  <div class="monitor-row-header">
                    <div class="monitor-row-title">
                      <div class="monitor-name-line">
                        <span class="monitor-title">${v.agent.name}</span>
                        ${v.agent.koreanName?o`<span class="monitor-sub">${v.agent.koreanName}</span>`:null}
                      </div>
                      <div class="monitor-note">${v.note}</div>
                    </div>
                    <${wt} status=${v.agent.status} />
                    <span class="monitor-pill ${v.tone}">${v.dispatchable?"Ready":v.drift?"Drift":"Watch"}</span>
                  </div>
                  <div class="monitor-meta">
                    ${v.lastSignalAt?o`<span>Signal <${K} timestamp=${v.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
                    <span>${v.activeTaskCount>0?`${v.activeTaskCount} active tasks`:"No active tasks"}</span>
                    ${v.agent.model?o`<span>${v.agent.model}</span>`:null}
                  </div>
                  <div class="monitor-focus">${v.focus}</div>
                </button>
              `)}
        </div>
      <//>

      <${S} title="Runtime Notes" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Secondary runtime context</h2>
          <p class="monitor-subheadline">This stays below the triage queue so operators can scan first and drill later.</p>
        </div>
        <div class="overview-note-stack">
          <div class="overview-inline-note">
            Room ${(t==null?void 0:t.room)??"default"}${t!=null&&t.cluster?` · Cluster ${t.cluster}`:""}${t!=null&&t.project?` · Project ${t.project}`:""}
          </div>
          <div class="overview-inline-note">
            ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${hu.value.length} · Total tasks ${n.length}
          </div>
          <div class="overview-inline-note">
            ${Ze.value?`Perpetual runtime ${Ze.value.running?"running":"stopped"}${Ze.value.goal?` · ${Gt(Ze.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
          </div>
          <div class="overview-inline-note">
            Lodge ${(Un=t==null?void 0:t.lodge)!=null&&Un.enabled?"enabled":"disabled"} · Last tick ${((Hn=t==null?void 0:t.lodge)==null?void 0:Hn.last_tick_ago)??"never"} · Self heartbeats ${((Wn=(Bn=t==null?void 0:t.lodge)==null?void 0:Bn.active_self_heartbeats)==null?void 0:Wn.length)??0}${(Gn=t==null?void 0:t.lodge)!=null&&Gn.last_skip_reason?` · Skip ${t.lodge.last_skip_reason}`:""}
          </div>
          <div class="overview-inline-note">
            ${a.length>0?`Hot keepers: ${w.length} · Highest context ${cd(Math.max(...a.map(v=>v.context_tokens??0)))}`:"No keepers registered"}
          </div>
        </div>
      <//>
    </div>
  `}const he=_(null),Aa=_(!1),Ta=_(null),si=_(null),Ca=_(null),Ei=_("operations");function B(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function h(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function I(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function bo(t){return typeof t=="boolean"?t:void 0}function Zt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function md(t){if(B(t))return{policy_class:h(t.policy_class),approval_class:h(t.approval_class),tool_allowlist:Zt(t.tool_allowlist),model_allowlist:Zt(t.model_allowlist),requires_human_for:Zt(t.requires_human_for),autonomy_level:h(t.autonomy_level),escalation_timeout_sec:I(t.escalation_timeout_sec),kill_switch:bo(t.kill_switch),frozen:bo(t.frozen)}}function fd(t){if(B(t))return{headcount_cap:I(t.headcount_cap),active_operation_cap:I(t.active_operation_cap),max_cost_usd:I(t.max_cost_usd),max_tokens:I(t.max_tokens)}}function Br(t){if(!B(t))return null;const e=h(t.unit_id),n=h(t.label),a=h(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:h(t.parent_unit_id)??null,leader_id:h(t.leader_id)??null,roster:Zt(t.roster),capability_profile:Zt(t.capability_profile),source:h(t.source),created_at:h(t.created_at),updated_at:h(t.updated_at),policy:md(t.policy),budget:fd(t.budget)}}function Wr(t){if(!B(t))return null;const e=Br(t.unit);return e?{unit:e,leader_status:h(t.leader_status),roster_total:I(t.roster_total),roster_live:I(t.roster_live),active_operation_count:I(t.active_operation_count),health:h(t.health),reasons:Zt(t.reasons),children:Array.isArray(t.children)?t.children.map(Wr).filter(n=>n!==null):[]}:null}function _d(t){if(B(t))return{total_units:I(t.total_units),company_count:I(t.company_count),platoon_count:I(t.platoon_count),squad_count:I(t.squad_count),leaf_agent_unit_count:I(t.leaf_agent_unit_count),live_agent_count:I(t.live_agent_count),managed_unit_count:I(t.managed_unit_count),active_operation_count:I(t.active_operation_count)}}function gd(t){const e=B(t)?t:{};return{version:h(e.version),generated_at:h(e.generated_at),source:h(e.source),summary:_d(e.summary),units:Array.isArray(e.units)?e.units.map(Wr).filter(n=>n!==null):[]}}function Gr(t){if(!B(t))return null;const e=h(t.operation_id),n=h(t.objective),a=h(t.assigned_unit_id),s=h(t.trace_id),i=h(t.status);return!e||!n||!a||!s||!i?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:h(t.autonomy_level),policy_class:h(t.policy_class),budget_class:h(t.budget_class),detachment_session_id:h(t.detachment_session_id)??null,trace_id:s,checkpoint_ref:h(t.checkpoint_ref)??null,active_goal_ids:Zt(t.active_goal_ids),note:h(t.note)??null,created_by:h(t.created_by),source:h(t.source),status:i,created_at:h(t.created_at),updated_at:h(t.updated_at)}}function hd(t){if(!B(t))return null;const e=Gr(t.operation);return e?{operation:e,assigned_unit_label:h(t.assigned_unit_label)}:null}function $d(t){const e=B(t)?t:{},n=B(e.summary)?e.summary:void 0;return{version:h(e.version),generated_at:h(e.generated_at),summary:n?{total:I(n.total),active:I(n.active),paused:I(n.paused),managed:I(n.managed),projected:I(n.projected)}:void 0,operations:Array.isArray(e.operations)?e.operations.map(hd).filter(a=>a!==null):[]}}function yd(t){if(!B(t))return null;const e=h(t.detachment_id),n=h(t.operation_id),a=h(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:h(t.leader_id)??null,roster:Zt(t.roster),session_id:h(t.session_id)??null,checkpoint_ref:h(t.checkpoint_ref)??null,source:h(t.source),status:h(t.status),last_event_at:h(t.last_event_at)??null,created_at:h(t.created_at),updated_at:h(t.updated_at)}}function bd(t){if(!B(t))return null;const e=yd(t.detachment);return e?{detachment:e,assigned_unit_label:h(t.assigned_unit_label),operation:Gr(t.operation)}:null}function kd(t){const e=B(t)?t:{},n=B(e.summary)?e.summary:void 0;return{version:h(e.version),generated_at:h(e.generated_at),summary:n?{total:I(n.total),active:I(n.active),projected:I(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(bd).filter(a=>a!==null):[]}}function xd(t){if(!B(t))return null;const e=h(t.decision_id),n=h(t.trace_id),a=h(t.requested_action),s=h(t.scope_type),i=h(t.scope_id);return!e||!n||!a||!s||!i?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:s,scope_id:i,operation_id:h(t.operation_id)??null,target_unit_id:h(t.target_unit_id)??null,requested_by:h(t.requested_by),status:h(t.status),reason:h(t.reason)??null,source:h(t.source),detail:t.detail,created_at:h(t.created_at),decided_at:h(t.decided_at)??null,expires_at:h(t.expires_at)??null}}function Sd(t){const e=B(t)?t:{},n=B(e.summary)?e.summary:void 0;return{version:h(e.version),generated_at:h(e.generated_at),summary:n?{total:I(n.total),pending:I(n.pending),approved:I(n.approved),denied:I(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(xd).filter(a=>a!==null):[]}}function wd(t){if(!B(t))return null;const e=Br(t.unit);return e?{unit:e,roster_total:I(t.roster_total),roster_live:I(t.roster_live),headcount_cap:I(t.headcount_cap),active_operations:I(t.active_operations),active_operation_cap:I(t.active_operation_cap),utilization:I(t.utilization)}:null}function Ad(t){const e=B(t)?t:{};return{version:h(e.version),generated_at:h(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(wd).filter(n=>n!==null):[]}}function Td(t){if(!B(t))return null;const e=h(t.alert_id);return e?{alert_id:e,severity:h(t.severity),kind:h(t.kind),scope_type:h(t.scope_type),scope_id:h(t.scope_id),title:h(t.title),detail:h(t.detail),timestamp:h(t.timestamp)}:null}function Cd(t){const e=B(t)?t:{},n=B(e.summary)?e.summary:void 0;return{version:h(e.version),generated_at:h(e.generated_at),summary:n?{total:I(n.total),bad:I(n.bad),warn:I(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Td).filter(a=>a!==null):[]}}function Nd(t){if(!B(t))return null;const e=h(t.event_id),n=h(t.trace_id),a=h(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:h(t.operation_id)??null,unit_id:h(t.unit_id)??null,actor:h(t.actor)??null,source:h(t.source),timestamp:h(t.timestamp),detail:t.detail}}function Rd(t){const e=B(t)?t:{};return{version:h(e.version),generated_at:h(e.generated_at),events:Array.isArray(e.events)?e.events.map(Nd).filter(n=>n!==null):[]}}function Dd(t){const e=B(t)?t:{};return{version:h(e.version),generated_at:h(e.generated_at),topology:gd(e.topology),operations:$d(e.operations),detachments:kd(e.detachments),alerts:Cd(e.alerts),decisions:Sd(e.decisions),capacity:Ad(e.capacity),traces:Rd(e.traces)}}function Ld(t){Ei.value=t}async function Dn(){Aa.value=!0,Ta.value=null;try{const t=await rc();he.value=Dd(t)}catch(t){Ta.value=t instanceof Error?t.message:"Failed to load command plane snapshot"}finally{Aa.value=!1}}async function $e(t,e,n){si.value=t,Ca.value=null;try{await lc(e,n),await Dn()}catch(a){throw Ca.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{si.value=null}}function Pd(t){return $e(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Ed(t){return $e(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Id(t){return $e(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Md(t){return $e(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Od(t){return $e(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function zd(t,e){return $e(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Fd(t,e){return $e(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}function qd(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function jn(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function ne(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}function jd(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function rt(t){return si.value===t}async function pe(t){try{await t()}catch{}}function Kd(){var i;const t=he.value,e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,a=t==null?void 0:t.decisions.summary,s=t==null?void 0:t.alerts.summary;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>Units</span><strong>${(e==null?void 0:e.total_units)??0}</strong><small>${(e==null?void 0:e.managed_unit_count)??0} managed</small></div>
      <div class="monitor-stat-card"><span>Ops</span><strong>${(n==null?void 0:n.active)??0}</strong><small>${((i=t==null?void 0:t.detachments.summary)==null?void 0:i.active)??0} detachments</small></div>
      <div class="monitor-stat-card"><span>Approvals</span><strong>${(a==null?void 0:a.pending)??0}</strong><small>${(a==null?void 0:a.total)??0} tracked</small></div>
      <div class="monitor-stat-card"><span>Alerts</span><strong>${(s==null?void 0:s.bad)??0}</strong><small>${(s==null?void 0:s.warn)??0} warn</small></div>
    </div>
  `}function Ud(){return o`
    <div class="command-surface-tabs">
      ${["operations","topology","alerts","trace","control"].map(e=>o`
        <button
          class="command-surface-tab ${Ei.value===e?"active":""}"
          onClick=${()=>Ld(e)}
        >
          ${e}
        </button>
      `)}
    </div>
  `}function Jr({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,s=t.active_operation_count??0,i=t.unit.policy;return o`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${jd(t.unit.kind)}</span>
            <span class="command-chip ${ne(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(r=>o`<${Jr} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Hd({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,s=`recall:${e.operation_id}`;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${ne(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${jn(e.updated_at)}</span>
      </div>
      ${e.checkpoint_ref?o`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        ${e.source==="managed"&&e.status==="active"?o`
              <button class="control-btn ghost" disabled=${rt(n)} onClick=${()=>pe(()=>Pd(e.operation_id))}>
                ${rt(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${rt(s)} onClick=${()=>pe(()=>Id(e.operation_id))}>
                ${rt(s)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?o`
              <button class="control-btn ghost" disabled=${rt(a)} onClick=${()=>pe(()=>Ed(e.operation_id))}>
                ${rt(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Bd({card:t}){var n;const e=t.detachment;return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${ne(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Updated</span><span>${jn(e.updated_at)}</span>
      </div>
    </article>
  `}function Wd({alert:t}){return o`
    <article class="command-alert ${ne(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${ne(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${jn(t.timestamp)}</span>
      </div>
      ${t.detail?o`<p>${t.detail}</p>`:null}
    </article>
  `}function Gd({event:t}){return o`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${jn(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${qd(t.detail)}</pre>
    </article>
  `}function Jd({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return o`
    <article class="command-card ${ne(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${ne(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${jn(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${rt(e)} onClick=${()=>pe(()=>Md(t.decision_id))}>
                ${rt(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${rt(n)} onClick=${()=>pe(()=>Od(t.decision_id))}>
                ${rt(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?o`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function Vd({row:t}){var u,d,p;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,s=!!((u=e.policy)!=null&&u.frozen),i=!!((d=e.policy)!=null&&d.kill_switch),r=Math.round((t.utilization??0)*100);return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${ne(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((p=e.policy)==null?void 0:p.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${s?"yes":"no"}</span>
        <span>Kill Switch</span><span>${i?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${rt(n)} onClick=${()=>pe(()=>zd(e.unit_id,!s))}>
          ${rt(n)?"Applying…":s?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${rt(a)} onClick=${()=>pe(()=>Fd(e.unit_id,!i))}>
          ${rt(a)?"Applying…":i?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Qd(){const t=he.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?o`<div class="command-card-stack">
              ${t.operations.operations.map(e=>o`<${Hd} card=${e} />`)}
            </div>`:o`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>o`<${Bd} card=${e} />`)}
            </div>`:o`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Yd(){const t=he.value;return o`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${t&&t.topology.units.length>0?o`${t.topology.units.map(e=>o`<${Jr} node=${e} />`)}`:o`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `}function Xd(){const t=he.value;return o`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${t&&t.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>o`<${Wd} alert=${e} />`)}
          </div>`:o`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `}function Zd(){const t=he.value;return o`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${t&&t.traces.events.length>0?o`<div class="command-trace-stack">
            ${t.traces.events.map(e=>o`<${Gd} event=${e} />`)}
          </div>`:o`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `}function tp(){const t=he.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${t&&t.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>o`<${Jd} decision=${e} />`)}
            </div>`:o`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${t&&t.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>o`<${Vd} row=${e} />`)}
            </div>`:o`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `}function ep(){switch(Ei.value){case"topology":return o`<${Yd} />`;case"alerts":return o`<${Xd} />`;case"trace":return o`<${Zd} />`;case"control":return o`<${tp} />`;case"operations":default:return o`<${Qd} />`}}function np(){return xt(()=>{Dn()},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button class="control-btn ghost" onClick=${()=>{Dn()}} disabled=${Aa.value}>
            ${Aa.value?"Refreshing…":"Refresh"}
          </button>
        </div>
      </div>

      ${Ta.value?o`<div class="empty-state error">${Ta.value}</div>`:null}
      ${Ca.value?o`<div class="empty-state error">${Ca.value}</div>`:null}

      <${Kd} />
      <${Ud} />
      <${ep} />
    </section>
  `}const Kn=_(null),Na=_(!1),ae=_(null),H=_(!1),Ra=_([]);let ap=1;function W(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function D(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function dt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Vr(t){return typeof t=="boolean"?t:void 0}function sp(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Ne(t,e=[]){if(Array.isArray(t))return t;if(!W(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function ip(t){return W(t)?{id:D(t.id),seq:dt(t.seq),from:D(t.from)??D(t.from_agent)??"system",content:D(t.content)??"",timestamp:D(t.timestamp)??new Date().toISOString(),type:D(t.type)}:null}function op(t){return W(t)?{room_id:D(t.room_id),current_room:D(t.current_room)??D(t.room),project:D(t.project),cluster:D(t.cluster),paused:Vr(t.paused),pause_reason:D(t.pause_reason)??null,paused_by:D(t.paused_by)??null,paused_at:D(t.paused_at)??null}:{}}function ko(t){if(!W(t))return;const e=Object.entries(t).map(([n,a])=>{const s=D(a);return s?[n,s]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function rp(t){if(!W(t))return null;const e=W(t.status)?t.status:void 0,n=W(t.summary)?t.summary:W(e==null?void 0:e.summary)?e.summary:void 0,a=W(t.session)?t.session:W(e==null?void 0:e.session)?e.session:void 0,s=D(t.session_id)??D(n==null?void 0:n.session_id)??D(a==null?void 0:a.session_id);if(!s)return null;const i=ko(t.report_paths)??ko(e==null?void 0:e.report_paths),r=Ne(t.recent_events,["events"]).filter(W);return{session_id:s,status:D(t.status)??D(n==null?void 0:n.status)??D(a==null?void 0:a.status),progress_pct:dt(t.progress_pct)??dt(n==null?void 0:n.progress_pct),elapsed_sec:dt(t.elapsed_sec)??dt(n==null?void 0:n.elapsed_sec),remaining_sec:dt(t.remaining_sec)??dt(n==null?void 0:n.remaining_sec),done_delta_total:dt(t.done_delta_total)??dt(n==null?void 0:n.done_delta_total),summary:n,team_health:W(t.team_health)?t.team_health:W(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:W(t.communication_metrics)?t.communication_metrics:W(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:W(t.orchestration_state)?t.orchestration_state:W(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:W(t.cascade_metrics)?t.cascade_metrics:W(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:a,recent_events:r}}function lp(t){if(!W(t))return null;const e=D(t.name);if(!e)return null;const n=W(t.context)?t.context:void 0;return{name:e,agent_name:D(t.agent_name),status:D(t.status),autonomy_level:D(t.autonomy_level),context_ratio:dt(t.context_ratio)??dt(n==null?void 0:n.context_ratio),generation:dt(t.generation),active_goal_ids:sp(t.active_goal_ids),last_autonomous_action_at:D(t.last_autonomous_action_at)??null,last_turn_ago_s:dt(t.last_turn_ago_s),model:D(t.model)??D(t.active_model)??D(t.primary_model)}}function cp(t){if(!W(t))return null;const e=D(t.confirm_token)??D(t.token);return e?{confirm_token:e,actor:D(t.actor),action_type:D(t.action_type),target_type:D(t.target_type),target_id:D(t.target_id)??null,delegated_tool:D(t.delegated_tool),created_at:D(t.created_at),preview:t.preview}:null}function up(t){const e=W(t)?t:{};return{room:op(e.room),sessions:Ne(e.sessions,["items","sessions"]).map(rp).filter(n=>n!==null),keepers:Ne(e.keepers,["items","keepers"]).map(lp).filter(n=>n!==null),recent_messages:Ne(e.recent_messages,["messages"]).map(ip).filter(n=>n!==null),pending_confirms:Ne(e.pending_confirms,["items","confirms"]).map(cp).filter(n=>n!==null),available_actions:Ne(e.available_actions,["actions"]).filter(W).map(n=>({action_type:D(n.action_type)??"unknown",target_type:D(n.target_type)??"unknown",description:D(n.description),confirm_required:Vr(n.confirm_required)}))}}function Xn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function xo(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Da(t){Ra.value=[{...t,id:ap++,at:new Date().toISOString()},...Ra.value].slice(0,20)}function Qr(t){return t.confirm_required?Xn(t.preview)||"Confirmation required":Xn(t.result)||Xn(t.executed_action)||Xn(t.delegated_tool_result)||t.status}async function Ke(){Na.value=!0,ae.value=null;try{const t=await oc();Kn.value=up(t)}catch(t){ae.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Na.value=!1}}async function dp(t){H.value=!0,ae.value=null;try{const e=await qn(t);return Da({actor:t.actor,action_type:t.action_type,target_label:xo(t),outcome:e.confirm_required?"preview":"executed",message:Qr(e),delegated_tool:e.delegated_tool}),await Ke(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw ae.value=n,Da({actor:t.actor,action_type:t.action_type,target_label:xo(t),outcome:"error",message:n}),e}finally{H.value=!1}}async function pp(t,e){H.value=!0,ae.value=null;try{const n=await cc(t,e);return Da({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Qr(n),delegated_tool:n.delegated_tool}),await Ke(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw ae.value=a,Da({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{H.value=!1}}const Yr="masc_dashboard_agent_name";function vp(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(Yr))==null?void 0:a.trim())||"dashboard"}const Za=_(vp()),cn=_(""),ii=_("Operator pause"),un=_(""),La=_(""),oi=_("2"),Pa=_(""),ze=_("note"),Ea=_(""),Ia=_(""),Ma=_(""),ri=_("2"),li=_("Operator stop request"),ci=_(""),dn=_("");function mp(t){const e=t.trim()||"dashboard";Za.value=e,localStorage.setItem(Yr,e)}function So(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function fp(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function Oa(t){return typeof t=="string"?t.trim().toLowerCase():""}function _p(t){var a;const e=Oa(t.status);if(e==="paused")return"bad";const n=Oa((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function wo(t){const e=Oa(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function ye(t){const e=Za.value.trim()||"dashboard";try{const n=await dp({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?k("Confirmation queued","warning"):k(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return k(a,"error"),null}}async function Ao(){const t=cn.value.trim();if(!t)return;await ye({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(cn.value="")}async function gp(){await ye({action_type:"room_pause",target_type:"room",payload:{reason:ii.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function hp(){await ye({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function $p(){const t=un.value.trim();if(!t)return;await ye({action_type:"task_inject",target_type:"room",payload:{title:t,description:La.value.trim()||"Injected from Ops tab",priority:Number.parseInt(oi.value,10)||2},successMessage:"Task injection submitted"})&&(un.value="",La.value="")}async function yp(){var i;const t=Kn.value,e=Pa.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){k("Select a team session first","warning");return}const n={turn_kind:ze.value},a=Ea.value.trim();a&&(n.message=a),ze.value==="task"&&(n.task_title=Ia.value.trim()||"Operator injected task",n.task_description=Ma.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(ri.value,10)||2),await ye({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(Ea.value="",ze.value==="task"&&(Ia.value="",Ma.value=""))}async function bp(){var n;const t=Kn.value,e=Pa.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){k("Select a team session first","warning");return}await ye({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:li.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function kp(){var s;const t=Kn.value,e=ci.value||((s=t==null?void 0:t.keepers[0])==null?void 0:s.name)||"",n=dn.value.trim();if(!e){k("Select a keeper first","warning");return}if(!n)return;await ye({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(dn.value="")}async function xp(t){const e=Za.value.trim()||"dashboard";try{await pp(e,t),k("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";k(a,"error")}}function Sp(){var l;xt(()=>{Ke()},[]);const t=Kn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],s=(t==null?void 0:t.pending_confirms)??[],i=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===Pa.value)??n[0]??null,u=a.find(c=>c.name===ci.value)??a[0]??null,d=n.filter(c=>_p(c)!=="ok"),p=a.filter(c=>wo(c)!=="ok"),f=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:s.length,detail:s.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:s.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:d.length,detail:d.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:d.some(c=>Oa(c.status)==="paused")?"bad":d.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:p.length,detail:p.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:p.some(c=>wo(c)==="bad")?"bad":p.length>0?"warn":"ok"}];return o`
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
            value=${Za.value}
            onInput=${c=>mp(c.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{Ke()}} disabled=${Na.value||H.value}>
            ${Na.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${ae.value?o`
        <section class="ops-banner error">${ae.value}</section>
      `:null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Action Priority</h2>
          <p class="monitor-subheadline">Ops is the command surface. These four signals explain when to intervene before you drop into a specific control panel.</p>
        </div>
        <div class="ops-priority-grid">
          ${f.map(c=>o`
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
                ${c.preview?o`<pre class="ops-code-block">${So(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{xp(c.confirm_token)}} disabled=${H.value}>
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
              value=${cn.value}
              onInput=${c=>{cn.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&Ao()}}
              disabled=${H.value}
            />
            <button class="control-btn" onClick=${()=>{Ao()}} disabled=${H.value||cn.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${ii.value}
              onInput=${c=>{ii.value=c.target.value}}
              disabled=${H.value}
            />
            <button class="control-btn ghost" onClick=${()=>{gp()}} disabled=${H.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{hp()}} disabled=${H.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${un.value}
            onInput=${c=>{un.value=c.target.value}}
            disabled=${H.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${La.value}
            onInput=${c=>{La.value=c.target.value}}
            disabled=${H.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${oi.value}
              onChange=${c=>{oi.value=c.target.value}}
              disabled=${H.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{$p()}} disabled=${H.value||un.value.trim()===""}>
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
                onClick=${()=>{Pa.value=c.session_id}}
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
                <pre class="ops-code-block compact">${So(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${ze.value}
              onChange=${c=>{ze.value=c.target.value}}
              disabled=${H.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{yp()}} disabled=${H.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${Ea.value}
            onInput=${c=>{Ea.value=c.target.value}}
            disabled=${H.value||!r}
          ></textarea>
          ${ze.value==="task"?o`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${Ia.value}
              onInput=${c=>{Ia.value=c.target.value}}
              disabled=${H.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${Ma.value}
              onInput=${c=>{Ma.value=c.target.value}}
              disabled=${H.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${ri.value}
              onChange=${c=>{ri.value=c.target.value}}
              disabled=${H.value||!r}
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
              value=${li.value}
              onInput=${c=>{li.value=c.target.value}}
              disabled=${H.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{bp()}} disabled=${H.value||!r}>
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
                onClick=${()=>{ci.value=c.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.name}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${c.model??"model n/a"}</span>
                  <span>${typeof c.context_ratio=="number"?`${Math.round(c.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${fp(c.last_turn_ago_s)}</span>
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
            value=${dn.value}
            onInput=${c=>{dn.value=c.target.value}}
            disabled=${H.value||!u}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{kp()}} disabled=${H.value||!u||dn.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${Ra.value.length===0?o`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:Ra.value.map(c=>o`
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
  `}const ui=_([]),di=_([]),pn=_(""),za=_(!1),vn=_(!1),Ln=_(""),Fa=_(null),$t=_(null),pi=_(!1);async function vi(){za.value=!0,Ln.value="";try{const[t,e]=await Promise.all([Bc(),Wc()]);ui.value=t,di.value=e}catch(t){Ln.value=t instanceof Error?t.message:"Failed to load council data"}finally{za.value=!1}}async function To(){const t=pn.value.trim();if(t){vn.value=!0;try{const e=await Gc(t);pn.value="",k(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await vi()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";k(n,"error")}finally{vn.value=!1}}}async function wp(t){Fa.value=t,pi.value=!0,$t.value=null;try{$t.value=await Jc(t)}catch(e){Ln.value=e instanceof Error?e.message:"Failed to load debate status",$t.value=null}finally{pi.value=!1}}function Ap({debate:t}){const e=Fa.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>wp(t.id)}
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
  `}function Tp({session:t}){return o`
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
  `}function Cp(){var e;const t=(e=ie.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${K} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Np(){var e,n;xt(()=>{vi()},[]);const t=((n=(e=ie.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${Cp} />
      <${S} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${pn.value}
            onInput=${a=>{pn.value=a.target.value}}
            onKeyDown=${a=>{a.key==="Enter"&&To()}}
            disabled=${vn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${To}
            disabled=${vn.value||pn.value.trim()===""}
          >
            ${vn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${vi} disabled=${za.value}>
            ${za.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Ln.value?o`<div class="council-error">${Ln.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${S} title="Debates" class="section">
          <div class="council-list">
            ${ui.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:ui.value.map(a=>o`<${Ap} key=${a.id} debate=${a} />`)}
          </div>
        <//>

        <${S} title="Voting Sessions" class="section">
          <div class="council-list">
            ${di.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:di.value.map(a=>o`<${Tp} key=${a.id} session=${a} />`)}
          </div>
        <//>
      </div>

      <${S} title=${Fa.value?`Debate Detail (${Fa.value})`:"Debate Detail"} class="section">
        ${pi.value?o`<div class="loading-indicator">Loading debate detail...</div>`:$t.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${$t.value.status}</span>
                  <span>Total arguments: ${$t.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${$t.value.support_count}</span>
                  <span>Oppose: ${$t.value.oppose_count}</span>
                  <span>Neutral: ${$t.value.neutral_count}</span>
                </div>
                ${$t.value.summary_text?o`<pre class="council-detail">${$t.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Rp({text:t}){if(!t)return null;const e=Dp(t);return o`<div class="markdown-content">${e}</div>`}function Dp(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],u=s.slice(r.length).trim(),d=[];for(a++;a<e.length&&!e[a].startsWith(r);)d.push(e[a]),a++;a++,n.push(o`<pre><code class=${u?`language-${u}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],u=s.trim().replace(/^<think>/,"").trim();for(u&&u!=="</think>"&&r.push(u),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const p=e[a].replace("</think>","").trim();p&&r.push(p),a++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${ms(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${ms(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${ms(i.join(`
`))}</p>`)}return n}function ms(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const Xr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],pa=_(null),mn=_([]),ve=_(!1),de=_(null),fn=_("");function Lp(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Pp=_(Lp()),_n=_(!1);async function Ii(t){de.value=t,pa.value=null,mn.value=[],ve.value=!0;try{const e=await _c(t);if(de.value!==t)return;pa.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},mn.value=e.comments??[]}catch{de.value===t&&(pa.value=null,mn.value=[])}finally{de.value===t&&(ve.value=!1)}}async function Co(t){const e=fn.value.trim();if(e){_n.value=!0;try{await gc(t,Pp.value,e),fn.value="",k("Comment posted","success"),await Ii(t),Et()}catch{k("Failed to post comment","error")}finally{_n.value=!1}}}function Ep(){const t=wn.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Xr.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{wn.value=e.id,Et()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${ce.value?"is-active":""}"
          onClick=${()=>{ce.value=!ce.value,Et()}}
        >
          ${ce.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Et} disabled=${Tn.value}>
          ${Tn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function fs(){var e;const t=(e=ie.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${K} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Zr({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Ip(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function No(t){return t.updated_at!==t.created_at}function _s(){var n;const t=((n=Xr.find(a=>a.id===wn.value))==null?void 0:n.label)??wn.value,e=Ht.value.length;return o`
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
        <strong>${ce.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${ai.value?o`<${K} timestamp=${ai.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Mp({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Tr(t.id,n),Et()}catch{k("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>ql(t.id)}>
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
              <${Zr} flair=${t.flair} />
              ${No(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${K} timestamp=${t.created_at} /></span>
            ${No(t)?o`<span>Updated <${K} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${Ip(t.content)}</div>
      </div>
    </div>
  `}function Op({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${K} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function zp({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${fn.value}
        onInput=${e=>{fn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Co(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${_n.value}
      />
      <button
        onClick=${()=>Co(t)}
        disabled=${_n.value||fn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${_n.value?"...":"Post"}
      </button>
    </div>
  `}function Fp({post:t}){de.value!==t.id&&!ve.value&&Ii(t.id);const e=async n=>{try{await Tr(t.id,n),Et()}catch{k("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>yt("board")}>← Back to Board</button>
      <${S} title=${o`${t.title} <${Zr} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Rp} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${K} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${S} title="Comments (${ve.value?"...":mn.value.length})">
        ${ve.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Op} comments=${mn.value} />`}
        <${zp} postId=${t.id} />
      <//>
    </div>
  `}function qp(){var s,i;const t=Ht.value,e=Tn.value,n=Pt.value.postId,a=((i=(s=ie.value)==null?void 0:s.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(u=>u.id===n)??(de.value===n?pa.value:null);return!r&&de.value!==n&&!ve.value&&Ii(n),r?o`
          <${fs} />
          <${_s} />
          <${Fp} post=${r} />
        `:o`
          <div>
            <${fs} />
            <${_s} />
            <button class="back-btn" onClick=${()=>yt("board")}>← Back to Board</button>
            ${ve.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${a?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${fs} />
    <${_s} />
    <${Ep} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${a?"No posts loaded (board feed degraded). Check board contract sync.":ce.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${Mp} key=${r.id} post=${r} />`)}
          </div>`}
  `}function jp(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Kp(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Up(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const tl=120,Hp=12,Bp=16,Wp=12,mi=_("all"),Gp={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Jp={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function Vp(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Qp(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:jp(t),actor:Kp(t),content:Up(t),timestamp:new Date(t.timestamp).toISOString()}}function Yp(t,e){var s;const n=(s=t.assignee)==null?void 0:s.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function Xp(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Zn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function fi(t){return t.last_heartbeat??Zn(t.last_turn_ago_s)??Zn(t.last_proactive_ago_s)??Zn(t.last_handoff_ago_s)??Zn(t.last_compaction_ago_s)}function Zp(t,e){const n=fi(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function Nt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const _i=vt(()=>{const t=fe.value.map(Vp),e=ee.value.map(Qp),n=[...Ot.value].sort((i,r)=>Nt(r.updated_at??r.created_at??0)-Nt(i.updated_at??i.created_at??0)).slice(0,Hp).map(Yp).filter(i=>i!==null),a=[...Ht.value].sort((i,r)=>Nt(r.updated_at||r.created_at)-Nt(i.updated_at||i.created_at)).slice(0,Bp).map(Xp),s=[...St.value].sort((i,r)=>Nt(fi(r)??0)-Nt(fi(i)??0)).slice(0,Wp).map(Zp).filter(i=>i!==null);return[...t,...e,...n,...a,...s].sort((i,r)=>Nt(r.timestamp)-Nt(i.timestamp))}),tv=vt(()=>{const t=_i.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),ev=vt(()=>{const t=mi.value;return(t==="all"?_i.value:_i.value.filter(n=>n.kind===t)).slice(0,tl)}),nv=vt(()=>se.value.map(t=>({agent:t,motion:Cn(t.name,Ot.value,fe.value,ee.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ht.value,keepers:St.value})})).sort((t,e)=>{const n=e.motion.activeAssignedCount-t.motion.activeAssignedCount;return n!==0?n:Nt(e.motion.lastActivityAt??0)-Nt(t.motion.lastActivityAt??0)}));function av(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function Qe({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function sv({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${av(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Jp[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function iv(){const t=tv.value,e=ev.value,n=e[0],a=nv.value;return o`
    <div class="stats-grid">
      <${Qe} label="Visible rows" value=${e.length} />
      <${Qe} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${Qe} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${Qe} label="Board signals" value=${t.board} color="#fbbf24" />
      <${Qe} label="SSE events" value=${On.value} color="#c084fc" />
    </div>

    <${S} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(s=>o`
            <button
              class="goal-filter-btn ${mi.value===s?"active":""}"
              onClick=${()=>{mi.value=s}}
            >
              ${Gp[s]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${jt.value?"":"pill-stale"}">
            ${jt.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${K} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${tl} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?o`<div class="empty-state">Waiting for live or snapshot signals...</div>`:e.map(s=>o`<${sv} key=${s.id} row=${s} />`)}
      </div>
    <//>

    <${S} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${a.length===0?o`<div class="empty-state">No active agents</div>`:a.map(({agent:s,motion:i})=>o`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${s.name}</div>
                  <div class="activity-motion-meta">
                    ${i.activeAssignedCount>0?`${i.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${i.lastActivityAt?o` · <${K} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function el({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,i=2*Math.PI*a,r=i*((100-t*100)/100);let u="mitosis-safe";return t>=.8?u="mitosis-critical":t>=.5&&(u="mitosis-warn"),o`
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
  `}const gs=600*1e3,ov=1200*1e3,Ro=.8;function Vt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Ae(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function rv(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function lv(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function cv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function uv(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function dv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function pv(t){var d,p;const e=Cn(t.name,Ot.value,fe.value,ee.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ht.value,keepers:St.value}),n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-Vt(n)):Number.POSITIVE_INFINITY,s=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let i="watching",r="ok",u="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",u=n?"Offline or inactive":"No recent presence"):a>ov?(i="quiet",r="bad",u=s?"Working without a fresh signal":"No fresh agent signal"):s?(i="working",r=a>gs?"warn":"ok",u=a>gs?"Execution looks quiet for too long":"Task and live signal aligned"):a>gs?(i="quiet",r="warn",u="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",u="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((p=t.current_task)==null?void 0:p.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:u}}function vv(t){const e=Ir.value.get(t.name)??"idle",n=Mr.value.has(t.name),a=t.context_ratio??0;let s="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(s="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=Ro)&&(s="warning",i="warn",r=a>=Ro?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:s,tone:i,focus:uv(t),note:r}}function Ye({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function mv({item:t}){const e=t.kind==="agent"?()=>Oe(t.agent.name):()=>xa(t.keeper);return o`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?o`<span><${K} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </button>
  `}function fv({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>Oe(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${el} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${wt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${rv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${K} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
        ${e.last_seen?o`<span>Seen <${K} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?o`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function _v({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>xa(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${el} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${wt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${lv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${K} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${dv(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${cv(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function gv(){const t=[...se.value].map(pv).sort((d,p)=>{const f=Ae(p.tone)-Ae(d.tone);if(f!==0)return f;const l=p.activeTaskCount-d.activeTaskCount;return l!==0?l:Vt(p.lastSignalAt)-Vt(d.lastSignalAt)}),e=[...St.value].map(vv).sort((d,p)=>{const f=Ae(p.tone)-Ae(d.tone);if(f!==0)return f;const l=(p.keeper.context_ratio??0)-(d.keeper.context_ratio??0);return l!==0?l:Vt(p.keeper.last_heartbeat)-Vt(d.keeper.last_heartbeat)}),n=t.filter(d=>d.state!=="offline").length,a=t.filter(d=>d.state==="working").length,s=t.filter(d=>d.lastSignalAt&&Date.now()-Vt(d.lastSignalAt)<=12e4).length,i=t.filter(d=>d.tone!=="ok"),r=e.filter(d=>d.tone!=="ok"),u=[...r.map(d=>({kind:"keeper",key:`keeper-${d.keeper.name}`,tone:d.tone,title:d.keeper.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.keeper.last_heartbeat??null,keeper:d.keeper})),...i.map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agent:d.agent}))].sort((d,p)=>{const f=Ae(p.tone)-Ae(d.tone);return f!==0?f:Vt(p.timestamp)-Vt(d.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Ye} label="Agents online" value=${n} color="#4ade80" caption="active + idle" />
        <${Ye} label="Working now" value=${a} color="#fbbf24" caption="task or claimed load" />
        <${Ye} label="Fresh signals" value=${s} color="#22d3ee" caption="within last 2 minutes" />
        <${Ye} label="Agent alerts" value=${i.length} color=${i.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${Ye} label="Keeper alerts" value=${r.length} color=${r.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${S} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${u.length===0?o`<div class="empty-state">No agent or keeper alerts right now</div>`:u.map(d=>o`<${mv} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${S} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(d=>o`<${_v} key=${d.keeper.name} row=${d} />`)}
          </div>
        <//>

        <${S} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Current task, recent signal, and quiet drift are surfaced together.</p>
          </div>
          <div class="monitor-list">
            ${t.length===0?o`<div class="empty-state">No agents registered</div>`:t.map(d=>o`<${fv} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>
    </div>
  `}function hs({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${K} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function hv(){const{todo:t,inProgress:e,done:n}=Er.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>o`<${hs} key=${a.id} task=${a} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>o`<${hs} key=${a.id} task=${a} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>o`<${hs} key=${a.id} task=${a} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}const qa=600*1e3,va=1200*1e3;function ts(t){return(t??"").trim().toLowerCase()}function Rt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function me(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function Jt(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Pn(t){return typeof t!="number"||Number.isNaN(t)?3:t}function nl(t){const e=Pn(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}function al(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function sl(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function $v(t){return t.updated_at??t.created_at??null}function yv(t){const e=new Map;for(const n of t)e.set(ts(n.name),Cn(n.name,Ot.value,fe.value,ee.value,{currentTask:n.current_task,lastSeen:n.last_seen,boardPosts:Ht.value,keepers:St.value}));return e}function Do(t,e,n){var w,R;const a=ts(t.assignee),s=a?e.get(a)??null:null,i=s?n.get(a)??null:null,r=(i==null?void 0:i.lastActivityAt)??(s==null?void 0:s.last_seen)??null,u=r?Math.max(0,Date.now()-Rt(r)):Number.POSITIVE_INFINITY,d=me(t.description),p=me(s==null?void 0:s.current_task)??(i==null?void 0:i.lastActivityText)??null,f=t.status==="claimed"||t.status==="in_progress";let l="ok",c="Fresh owner coverage",m=p??d??t.id,$=!1,b=!1;return t.status==="todo"?t.assignee?s?s.status==="offline"||s.status==="inactive"?($=!0,l="bad",c="Assigned owner is offline",m="Queue item is blocked until ownership changes."):u>qa?(l="warn",c="Owner exists but live signal is quiet",m=p??"Owner may need a nudge before pickup."):((i==null?void 0:i.activeAssignedCount)??0)>0||(w=s.current_task)!=null&&w.trim()?(l="warn",c="Owner is already carrying active work",m=p??`${(i==null?void 0:i.activeAssignedCount)??0} active tasks already assigned.`):(c="Ready and covered by a fresh operator",m=p??d??"This can be picked up immediately."):($=!0,l="bad",c="Assigned owner is not present in the room",m="Reassign or bring the owner back online."):($=!0,l=Pn(t.priority)<=2?"bad":"warn",c=Pn(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",m="Assign an agent before this queue item slips."):f&&(t.assignee?s?s.status==="offline"||s.status==="inactive"?($=!0,l="bad",c="Assigned owner is offline",m=p??"Execution has no live operator right now."):u>va?(b=!0,l="bad",c="Assigned owner has gone quiet",m=p??"Fresh operator signal is missing."):u>qa?(b=!0,l="warn",c="Execution has been quiet for too long",m=p??"Check whether this work is blocked."):(R=s.current_task)!=null&&R.trim()?(c="Execution has fresh owner coverage",m=p??d??t.id):(l="warn",c=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",m=p??"Task state and agent focus are drifting apart."):($=!0,l="bad",c="Assigned owner is not active in the room",m="Execution is orphaned until ownership is restored."):($=!0,l="bad",c="Active work has no assignee",m="Claim or reassign this task immediately.")),{task:t,assigneeAgent:s,motion:i,tone:l,note:c,focus:m,lastSignalAt:r,lastTouchedAt:$v(t),ownerGap:$,quiet:b}}function bv(t,e){var c;const n=e.get(ts(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,s=a?Math.max(0,Date.now()-Rt(a)):Number.POSITIVE_INFINITY,i=!!((c=t.current_task)!=null&&c.trim()),r=n.activeAssignedCount,u=i||r>0;let d="loaded",p="ok",f="Healthy active load",l=me(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(d="offline",p="bad",f="Agent is unavailable"):u&&s>va?(d="quiet",p="bad",f="Working without a fresh signal"):r>0&&!i?(d="drift",p="warn",f="Claimed work exists but current_task is empty",l=`${r} active tasks need explicit focus.`):i&&r===0?(d="drift",p="warn",f="current_task has no matching claimed work",l=me(t.current_task)??"Task metadata and operator state drifted."):!u&&s<=qa?(d="dispatchable",p="ok",f="Fresh signal and no active load",l=n.lastActivityText??"Ready for assignment."):u?s>qa&&(d="loaded",p="warn",f="Execution load is healthy but slightly quiet",l=me(t.current_task)??`${r} active tasks in flight.`):(d="quiet",p=s>va?"bad":"warn",f=s>va?"No fresh signal while idle":"Reachable, but not freshly active",l=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:p,state:d,note:f,focus:l,lastSignalAt:a,activeTaskCount:r}}function Xe({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function kv({item:t}){return o`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?nl(t.taskRow.task.priority):sl(t.agentRow.state)}
        </span>
        ${t.kind==="task"?o`<span>${al(t.taskRow.task.status)}</span>`:o`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?o`<span><${K} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </div>
  `}function Lo({row:t}){var e;return o`
    <div class="execution-task-row ${t.tone}">
      <div class="monitor-row-header">
        <span class="monitor-pill ${t.tone}">${nl(t.task.priority)}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.task.title}</span>
            <span class="monitor-sub">${t.task.id}</span>
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        ${t.assigneeAgent?o`<${wt} status=${t.assigneeAgent.status} />`:o`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${al(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?o`<span>Owner ${t.task.assignee}</span>`:o`<span>Unassigned</span>`}
        ${t.lastTouchedAt?o`<span>Touched <${K} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?o`<span>Signal <${K} timestamp=${t.lastSignalAt} /></span>`:o`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&me(t.assigneeAgent.current_task)!==t.focus?o`<div class="monitor-footnote">Owner focus: ${me(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function xv({row:t}){const{agent:e}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>Oe(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${wt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${sl(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${K} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
  `}function Sv(){const t=se.value,e=Ot.value,n=new Map(t.map(l=>[ts(l.name),l])),a=yv(t),s=e.filter(l=>l.status==="claimed"||l.status==="in_progress").map(l=>Do(l,n,a)).sort((l,c)=>{const m=Jt(c.tone)-Jt(l.tone);return m!==0?m:Rt(c.lastSignalAt??c.lastTouchedAt)-Rt(l.lastSignalAt??l.lastTouchedAt)}),i=e.filter(l=>l.status==="todo").map(l=>Do(l,n,a)).sort((l,c)=>{const m=Jt(c.tone)-Jt(l.tone);if(m!==0)return m;const $=Pn(l.task.priority)-Pn(c.task.priority);return $!==0?$:Rt(l.lastTouchedAt)-Rt(c.lastTouchedAt)}),r=t.map(l=>bv(l,a)).filter(l=>l.state==="dispatchable"||l.state==="drift"||l.state==="quiet").sort((l,c)=>{if(l.state==="dispatchable"&&c.state!=="dispatchable")return-1;if(c.state==="dispatchable"&&l.state!=="dispatchable")return 1;const m=Jt(c.tone)-Jt(l.tone);return m!==0?m:Rt(c.lastSignalAt)-Rt(l.lastSignalAt)}),u=[...s.filter(l=>l.tone!=="ok").map(l=>({kind:"task",key:`active-${l.task.id}`,tone:l.tone,title:l.task.title,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastSignalAt??l.lastTouchedAt,taskRow:l})),...i.filter(l=>l.tone==="bad").map(l=>({kind:"task",key:`ready-${l.task.id}`,tone:l.tone,title:l.task.title,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastTouchedAt,taskRow:l})),...r.filter(l=>l.state==="drift"||l.tone==="bad").map(l=>({kind:"agent",key:`agent-${l.agent.name}`,tone:l.tone,title:l.agent.name,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastSignalAt,agentRow:l}))].sort((l,c)=>{const m=Jt(c.tone)-Jt(l.tone);return m!==0?m:Rt(c.timestamp)-Rt(l.timestamp)}).slice(0,8),d=r.filter(l=>l.state==="dispatchable"),p=[...s,...i].filter(l=>l.ownerGap),f=s.filter(l=>l.quiet);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Xe} label="Active work" value=${s.length} color="#fbbf24" caption="claimed + in progress" />
        <${Xe} label="Needs intervention" value=${u.length} color=${u.length>0?"#fb7185":"#4ade80"} caption="stalled or drifting now" />
        <${Xe} label="Ownership gaps" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="missing or unavailable owners" />
        <${Xe} label="Dispatchable agents" value=${d.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${Xe} label="Quiet execution" value=${f.length} color=${f.length>0?"#fbbf24":"#4ade80"} caption="active tasks with aging signals" />
      </div>

      <${S} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${u.length===0?o`<div class="empty-state">No active execution risks right now</div>`:u.map(l=>o`<${kv} key=${l.key} item=${l} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${S} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${i.length===0?o`<div class="empty-state">No ready tasks in the queue</div>`:i.slice(0,10).map(l=>o`<${Lo} key=${l.task.id} row=${l} />`)}
          </div>
        <//>

        <${S} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?o`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(l=>o`<${xv} key=${l.agent.name} row=${l} />`)}
          </div>
        <//>
      </div>

      <${S} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${s.length===0?o`<div class="empty-state">No active execution tasks</div>`:s.map(l=>o`<${Lo} key=${l.task.id} row=${l} />`)}
        </div>
      <//>
    </div>
  `}const ja=_("all"),Ka=_("all"),gi=vt(()=>{let t=An.value;return ja.value!=="all"&&(t=t.filter(e=>e.horizon===ja.value)),Ka.value!=="all"&&(t=t.filter(e=>e.status===Ka.value)),t}),wv=vt(()=>{const t={short:[],mid:[],long:[]};for(const e of gi.value){const n=t[e.horizon];n&&n.push(e)}return t}),Av=vt(()=>{const t=Array.from(kt.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Tv(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Mi(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ma(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Cv(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Po(t){return t.toFixed(4)}function Eo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Nv({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ma(t.horizon)}">
            ${Mi(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Tv(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${K} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${wt} status=${t.status} />
        <div class="goal-updated">
          <${K} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Io({label:t,timestamp:e,source:n,note:a}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${a?o`<div class="planning-freshness-source">${a}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${K} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function $s({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return o`
    <${S} title="${Mi(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>o`<${Nv} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function Rv(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${ja.value===t?"active":""}"
            onClick=${()=>{ja.value=t}}
          >
            ${t==="all"?"All":Mi(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Ka.value===t?"active":""}"
            onClick=${()=>{Ka.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Dv(){const t=An.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${ma("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ma("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ma("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Lv({loop:t}){const e=t.history[0];return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${wt} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Po(t.baseline_metric)}</span>
          <span>Current ${Po(t.current_metric)}</span>
          <span class=${Eo(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Eo(t)}
          </span>
          <span>Elapsed ${Cv(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${e?o`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function Pv(){xt(()=>{sn(),on()},[]);const t=wv.value,e=Av.value,n=e.filter(r=>r.status==="running").length,a=An.value.filter(r=>r.status==="active").length,s=ca.value,i=s==="idle"?"No loop running":s==="error"?ti.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${a}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${gi.value.length}</div>
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

      <${S} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>masc_mdal_status</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${sn} disabled=${Le.value}>
              ${Le.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${on} disabled=${Pe.value}>
              ${Pe.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{sn(),on()}}
              disabled=${Le.value||Pe.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Io} label="Goals" timestamp=${Lr.value} source="masc_goal_list" />
          <${Io}
            label="MDAL loops"
            timestamp=${Pr.value}
            source="masc_mdal_status"
            note=${i}
          />
        </div>
      <//>

      <${S} title="Goal Pipeline" class="section">
        <${Dv} />
        <${Rv} />
      <//>

      ${Le.value&&An.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:gi.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${$s} horizon="short" items=${t.short??[]} />
              <${$s} horizon="mid" items=${t.mid??[]} />
              <${$s} horizon="long" items=${t.long??[]} />
            `}

      <${S} title="MDAL Loops" class="section">
        ${Pe.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&s==="error"?o`
                <div class="empty-state">
                  MDAL snapshot could not be loaded right now. Check the backend tool contract or runtime health.
                </div>
              `:e.length===0&&s==="idle"?o`
                <div class="empty-state">
                  No loop is running right now. This section wakes up when <code>masc_mdal_start</code> exposes a live loop.
                </div>
              `:e.length===0?o`
                  <div class="empty-state">
                    No loop snapshot is visible yet. Refresh once the backend has reported a planning loop.
                  </div>
                `:o`
                <div class="planning-loop-list">
                  ${e.map(r=>o`<${Lv} key=${r.loop_id} loop=${r} />`)}
                </div>
              `}
      <//>
    </div>
  `}const Re=_(""),ys=_("ability_check"),bs=_("10"),ks=_("12"),ta=_(""),ea=_("idle"),Qt=_(""),na=_("keeper-late"),xs=_("player"),Ss=_(""),_t=_("idle"),ws=_(null),aa=_(""),As=_(""),Ts=_("player"),Cs=_(""),Ns=_(""),Rs=_(""),gn=_("20"),Ds=_("20"),Ls=_(""),sa=_("idle"),hi=_(null),il=_("overview"),Ps=_("all"),Es=_("all"),Is=_("all"),Ev=12e4,es=_(null),Mo=_(Date.now());function Iv(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Mv(t,e){return e>0?Math.round(t/e*100):0}const Ov={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},zv={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function ia(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Fv(t){const e=t.trim().toLowerCase();return Ov[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function qv(t){const e=t.trim().toLowerCase();return zv[e]??"상황에 따라 선택되는 전술 액션입니다."}function te(t){return typeof t=="object"&&t!==null}function ut(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function Dt(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function En(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const jv=new Set(["str","dex","con","int","wis","cha"]);function Kv(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!te(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,i])=>{const r=s.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){a[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const u=Number.parseFloat(i.trim());if(Number.isFinite(u)){a[r]=Math.max(0,Math.trunc(u));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function Uv(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(gn.value.trim(),10);Number.isFinite(a)&&a>n&&(gn.value=String(n))}function $i(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Hv(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Bv(t){il.value=t}function ol(t){const e=es.value;return e==null||e<=t}function Wv(t){const e=es.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ua(){es.value=null}function rl(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Gv(t,e){rl(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(es.value=Date.now()+Ev,k("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function fa(t){return ol(t)?(k("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function yi(t,e,n){return rl([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Jv({hp:t,max:e}){const n=Mv(t,e),a=Iv(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Vv({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Qv({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function ll({actor:t}){var d,p,f,l;const e=(d=t.archetype)==null?void 0:d.trim(),n=(p=t.persona)==null?void 0:p.trim(),a=(f=t.portrait)==null?void 0:f.trim(),s=(l=t.background)==null?void 0:l.trim(),i=t.traits??[],r=t.skills??[],u=Object.entries(t.stats_raw??{}).filter(([c,m])=>Number.isFinite(m)).filter(([c])=>!jv.has(c.toLowerCase()));return o`
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
        <${wt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Qv} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Jv} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Vv} stats=${t.stats} />
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
                  <span class="trpg-annot-desc">${Fv(c)}</span>
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
                  <span class="trpg-annot-desc">${qv(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Yv({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function cl({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return o`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Hv(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${$i(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${K} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Xv({events:t}){const e="__none__",n=Ps.value,a=Es.value,s=Is.value,i=Array.from(new Set(t.map($i).map(l=>l.trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),r=Array.from(new Set(t.map(l=>(l.type??"").trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),u=t.some(l=>(l.type??"").trim()===""),d=Array.from(new Set(t.map(l=>(l.phase??"").trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),p=t.some(l=>(l.phase??"").trim()===""),f=t.filter(l=>{if(n!=="all"&&$i(l)!==n)return!1;const c=(l.type??"").trim(),m=(l.phase??"").trim();if(a===e){if(c!=="")return!1}else if(a!=="all"&&c!==a)return!1;if(s===e){if(m!=="")return!1}else if(s!=="all"&&m!==s)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${l=>{Ps.value=l.target.value}}>
          <option value="all">all</option>
          ${i.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${l=>{Es.value=l.target.value}}>
          <option value="all">all</option>
          ${u?o`<option value=${e}>(none)</option>`:null}
          ${r.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${l=>{Is.value=l.target.value}}>
          <option value="all">all</option>
          ${p?o`<option value=${e}>(none)</option>`:null}
          ${d.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Ps.value="all",Es.value="all",Is.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${f.length} / 전체 ${t.length}
      </span>
    </div>
    <${cl} events=${f.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Zv({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function ul({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function tm({state:t,nowMs:e}){var p;const n=Ft.value||((p=t.session)==null?void 0:p.room)||"",a=ea.value,s=t.party??[];if(!s.find(f=>f.id===Re.value)&&s.length>0){const f=s[0];f&&(Re.value=f.id)}const r=async()=>{var l,c;if(!n){k("Room ID가 비어 있습니다.","error");return}if(!fa(e))return;const f=((l=t.current_round)==null?void 0:l.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(yi("라운드 실행",n,f)){ea.value="running";try{const m=await Lc(n);hi.value=m,ea.value="ok";const $=te(m.summary)?m.summary:null,b=$?En($,"advanced",!1):!1,w=$?ut($,"progress_reason",""):"";k(b?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${w?`: ${w}`:""}`,b?"success":"warning"),qt()}catch(m){hi.value=null,ea.value="error";const $=m instanceof Error?m.message:"라운드 실행에 실패했습니다.";k($,"error")}finally{Ua()}}},u=async()=>{var l,c;if(!n||!fa(e))return;const f=((l=t.current_round)==null?void 0:l.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(yi("턴 강제 진행",n,f))try{await Ic(n),k("턴을 다음 단계로 이동했습니다.","success"),qt()}catch{k("턴 이동에 실패했습니다.","error")}finally{Ua()}},d=async()=>{if(!n||!fa(e))return;const f=Re.value.trim();if(!f){k("먼저 Actor를 선택하세요.","warning");return}const l=Number.parseInt(bs.value,10),c=Number.parseInt(ks.value,10);if(Number.isNaN(l)||Number.isNaN(c)){k("stat/dc는 숫자여야 합니다.","warning");return}const m=Number.parseInt(ta.value,10),$=ta.value.trim()===""||Number.isNaN(m)?void 0:m;try{await Ec({roomId:n,actorId:f,action:ys.value.trim()||"ability_check",statValue:l,dc:c,rawD20:$}),k("주사위 판정을 기록했습니다.","success"),qt()}catch{k("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${f=>{Ft.value=f.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Re.value}
            onChange=${f=>{Re.value=f.target.value}}
          >
            <option value="">Actor 선택</option>
            ${s.map(f=>o`<option value=${f.id}>${f.name} (${f.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${ys.value}
              onInput=${f=>{ys.value=f.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${bs.value}
              onInput=${f=>{bs.value=f.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${ks.value}
              onInput=${f=>{ks.value=f.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ta.value}
              onInput=${f=>{ta.value=f.target.value}}
              onKeyDown=${f=>{f.key==="Enter"&&d()}}
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
  `}function em({state:t}){var s;const e=Ft.value||((s=t.session)==null?void 0:s.room)||"",n=sa.value,a=async()=>{if(!e){k("Room ID가 비어 있습니다.","warning");return}const i=aa.value.trim(),r=As.value.trim();if(!r&&!i){k("이름 또는 Actor ID를 입력하세요.","warning");return}const u=Number.parseInt(gn.value.trim(),10),d=Number.parseInt(Ds.value.trim(),10),p=Number.isFinite(d)?Math.max(1,d):20,f=Number.isFinite(u)?Math.max(0,Math.min(p,u)):p;let l={};try{l=Kv(Ls.value)}catch(c){k(c instanceof Error?c.message:"능력치 JSON 오류","error");return}sa.value="spawning";try{const c=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,m=await Mc(e,{actor_id:i||void 0,name:r||void 0,role:Ts.value,idempotencyKey:c,portrait:Ns.value.trim()||void 0,background:Rs.value.trim()||void 0,hp:f,max_hp:p,alive:f>0,stats:Object.keys(l).length>0?l:void 0}),$=typeof m.actor_id=="string"?m.actor_id.trim():"";if(!$)throw new Error("생성 응답에 actor_id가 없습니다.");const b=Cs.value.trim();b&&await Oc(e,$,b),Re.value=$,Qt.value=$,i||(aa.value=""),sa.value="ok",k(`Actor 생성 완료: ${$}`,"success"),await qt()}catch(c){sa.value="error",k(c instanceof Error?c.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${As.value}
            onInput=${i=>{As.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ts.value}
            onChange=${i=>{Ts.value=i.target.value}}
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
            value=${Cs.value}
            onInput=${i=>{Cs.value=i.target.value}}
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
              value=${Ns.value}
              onInput=${i=>{Ns.value=i.target.value}}
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
              value=${gn.value}
              onInput=${i=>{gn.value=i.target.value}}
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
              value=${Ds.value}
              onInput=${i=>{const r=i.target.value;Ds.value=r,Uv(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Rs.value}
              onInput=${i=>{Rs.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Ls.value}
              onInput=${i=>{Ls.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function nm({state:t,nowMs:e}){var c;const n=Ft.value||((c=t.session)==null?void 0:c.room)||"",a=t.join_gate,s=ws.value,i=te(s)?s:null,r=(t.party??[]).filter(m=>m.role!=="dm"),u=Qt.value.trim(),d=r.some(m=>m.id===u),p=d?u:u?"__manual__":"",f=async()=>{const m=Qt.value.trim(),$=na.value.trim();if(!n||!m){k("Room/Actor가 필요합니다.","warning");return}_t.value="checking";try{const b=await zc(n,m,$||void 0);ws.value=b,_t.value="ok",k("참가 가능 여부를 갱신했습니다.","success")}catch(b){_t.value="error";const w=b instanceof Error?b.message:"참가 가능 여부 확인에 실패했습니다.";k(w,"error")}},l=async()=>{var R,A;const m=Qt.value.trim(),$=na.value.trim(),b=Ss.value.trim();if(!n||!m||!$){k("Room/Actor/Keeper가 필요합니다.","warning");return}if(!fa(e))return;const w=((R=t.current_round)==null?void 0:R.phase)??((A=t.session)==null?void 0:A.status)??"unknown";if(yi("Mid-Join 승인 요청",n,w)){_t.value="requesting";try{const M=await Fc({room_id:n,actor_id:m,keeper_name:$,role:xs.value,...b?{name:b}:{}});ws.value=M;const C=te(M)?En(M,"granted",!1):!1,L=te(M)?ut(M,"reason_code",""):"";C?k("Mid-Join이 승인되었습니다.","success"):k(`Mid-Join이 거절되었습니다${L?`: ${L}`:""}`,"warning"),_t.value=C?"ok":"error",qt()}catch(M){_t.value="error";const C=M instanceof Error?M.message:"Mid-Join 요청에 실패했습니다.";k(C,"error")}finally{Ua()}}};return o`
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
            value=${p}
            onChange=${m=>{const $=m.target.value;if($==="__manual__"){(d||!u)&&(Qt.value="");return}Qt.value=$}}
          >
            <option value="">Actor 선택</option>
            ${r.map(m=>o`
              <option value=${m.id}>${m.name} (${m.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${p==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Qt.value}
                onInput=${m=>{Qt.value=m.target.value}}
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
            value=${xs.value}
            onChange=${m=>{xs.value=m.target.value}}
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
            value=${Ss.value}
            onInput=${m=>{Ss.value=m.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${f} disabled=${_t.value==="checking"||_t.value==="requesting"}>
              ${_t.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${l} disabled=${_t.value==="checking"||_t.value==="requesting"}>
              ${_t.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${En(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Dt(i,"effective_score",0)}/${Dt(i,"required_points",0)}</span>
            ${ut(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${ut(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function dl({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function pl({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function vl(){const t=hi.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=te(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(te).slice(-8),i=t.canon_check,r=te(i)?i:null,u=r&&Array.isArray(r.warnings)?r.warnings.filter(L=>typeof L=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(L=>typeof L=="string").slice(0,3):[],p=n?En(n,"advanced",!1):!1,f=n?ut(n,"progress_reason",""):"",l=n?ut(n,"progress_detail",""):"",c=n?Dt(n,"player_successes",0):0,m=n?Dt(n,"player_required_successes",0):0,$=n?En(n,"dm_success",!1):!1,b=n?Dt(n,"timeouts",0):0,w=n?Dt(n,"unavailable",0):0,R=n?Dt(n,"reprompts",0):0,A=n?Dt(n,"npc_attacks",0):0,M=n?Dt(n,"keeper_timeout_sec",0):0,C=n?Dt(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${p?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${p?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${$?"DM ok":"DM stalled"} / players ${c}/${m}
          </span>
        </div>
        ${f?o`<div style="margin-top:4px; font-size:12px;">${f}</div>`:null}
        ${l?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${l}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${b}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${R}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${M||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${C}</div></div>
      </div>

      ${s.length>0?o`
          <div class="trpg-round-list">
            ${s.map(L=>{const at=ut(L,"status","unknown"),At=ut(L,"actor_id","-"),Tt=ut(L,"role","-"),st=ut(L,"reason",""),mt=ut(L,"action_type",""),O=ut(L,"reply","");return o`
                <div class="trpg-round-item ${at.includes("fallback")||at.includes("timeout")?"failed":"active"}">
                  <span>${At} (${Tt})</span>
                  <span style="margin-left:auto; font-size:11px;">${at}</span>
                  ${mt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${mt}</div>`:null}
                  ${st?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${st}</div>`:null}
                  ${O?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${O.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ut(r,"status","unknown")}</strong>
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
  `}function am({state:t,nowMs:e}){var r,u,d;const n=Ft.value||((r=t.session)==null?void 0:r.room)||"",a=((u=t.current_round)==null?void 0:u.phase)??((d=t.session)==null?void 0:d.status)??"unknown",s=ol(e),i=Wv(e);return o`
    <${S} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${s?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${s?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${s?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${s?o`<button class="trpg-run-btn recommend" onClick=${()=>Gv(n,a)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Ua(),k("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function sm({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Bv(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function im({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${S} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${S} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${cl} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${S} title="맵" style="margin-top:16px;">
              <${Yv} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${S} title="현재 라운드">
          <${pl} state=${t} />
        <//>

        <${S} title="기여도" style="margin-top:16px;">
          <${dl} state=${t} />
        <//>

        <${S} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>o`<${ll} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${S} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${ul} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function om({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${S} title=${`이벤트 타임라인 (${e.length})`}>
          <${Xv} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${S} title="최근 라운드 결과">
          <${vl} />
        <//>

        <${S} title="현재 라운드" style="margin-top:16px;">
          <${pl} state=${t} />
        <//>
      </div>
    </div>
  `}function rm({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${am} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${S} title="조작 패널">
            <${tm} state=${t} nowMs=${e} />
          <//>

          <${S} title="Actor Spawn" style="margin-top:16px;">
            <${em} state=${t} />
          <//>

          <${S} title="Mid-Join Gate" style="margin-top:16px;">
            <${nm} state=${t} nowMs=${e} />
          <//>

          <${S} title="최근 라운드 결과" style="margin-top:16px;">
            <${vl} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${S} title="기여도" style="margin-top:0;">
            <${dl} state=${t} />
          <//>

          <${S} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>o`<${ll} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${S} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${ul} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function lm(){var u,d,p,f,l;const t=Dr.value,e=ni.value;if(xt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const c=window.setInterval(()=>{Mo.value=Date.now()},1e3);return()=>{window.clearInterval(c)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>qt()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,i=il.value,r=Mo.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Ft.value||((u=t.session)==null?void 0:u.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((p=t.session)==null?void 0:p.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>qt()}>새로고침</button>
      </div>

      <${Zv} outcome=${s} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((f=t.session)==null?void 0:f.status)??"active"}</div>
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

      <${sm} active=${i} />

      ${i==="overview"?o`<${im} state=${t} />`:i==="timeline"?o`<${om} state=${t} />`:o`<${rm} state=${t} nowMs=${r} />`}
    </div>
  `}const Oi="masc_dashboard_agent_name";function cm(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Oi);return e??n??"dashboard"}const pt=_(cm()),hn=_(""),$n=_(""),Ha=_(""),ml=_(null),Ba=_(null),yn=_(!1),Ee=_(!1),bn=_(!1),kn=_(!1),Wa=_(!1),Ga=_(!1),ns=_(!1);function Ja(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function _a(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function fl(t){return!t||t.length===0?"none":t.join(", ")}function um(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Ja(t.quiet_start)}-${Ja(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${_a(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${_a(t.interval_s)}.`:`Lodge ticks every ${_a(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function We(){je();try{await ge()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function zi(t){const e=t.trim();pt.value=e,e&&localStorage.setItem(Oi,e)}function dm(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function bi(){const t=pt.value.trim();if(t){bn.value=!0;try{const e=await jc(t),n=dm(e);n&&zi(n),ns.value=!0,await We(),k(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";k(n,"error")}finally{bn.value=!1}}}async function pm(){const t=pt.value.trim();if(t){kn.value=!0;try{await Nr(t),ns.value=!1,await We(),k(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";k(n,"error")}finally{kn.value=!1}}}async function vm(){const t=pt.value.trim();if(t)try{await Nr(t)}catch{}localStorage.removeItem(Oi),zi("dashboard"),ns.value=!1,await bi()}async function mm(){const t=pt.value.trim();if(t){Wa.value=!0;try{await Kc(t),await We(),k("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";k(n,"error")}finally{Wa.value=!1}}}async function Oo(){const t=pt.value.trim(),e=hn.value.trim();if(!(!t||!e)){yn.value=!0;try{await Cr(t,e),hn.value="",await We(),k("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";k(a,"error")}finally{yn.value=!1}}}async function fm(){const t=$n.value.trim(),e=Ha.value.trim()||"Created from dashboard";if(t){Ee.value=!0;try{await qc(t,e,1),$n.value="",Ha.value="",await We(),k("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";k(a,"error")}finally{Ee.value=!1}}}async function zo(){const t=pt.value.trim()||"dashboard";Ga.value=!0,Ba.value=null;try{const e=await qn({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=Ri(e.result);ml.value=n,await We(),n!=null&&n.skipped_reason?k(n.skipped_reason,"warning"):k(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";Ba.value=n,k(n,"error")}finally{Ga.value=!1}}function _m({runtime:t}){var s,i;const e=ml.value??(t==null?void 0:t.last_tick_result)??null;if(Ba.value)return o`<div class="control-result-box is-error">${Ba.value}</div>`;if(!e)return o`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((s=e.skipped_rows)==null?void 0:s.slice(0,3))??[],a=((i=e.passed_rows)==null?void 0:i.slice(0,3))??[];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?o`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${fl(e.acted_names)}</div>
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
  `}function gm(t){return t.find(n=>n.name===nn.value)??t[0]??null}function hm(){var a,s;const t=St.value,e=((a=ie.value)==null?void 0:a.lodge)??null,n=gm(t);return xt(()=>{bi()},[]),xt(()=>{var r;const i=((r=t[0])==null?void 0:r.name)??"";if(!nn.value&&i){la(i);return}nn.value&&!t.some(u=>u.name===nn.value)&&la(i)},[t.map(i=>i.name).join("|")]),o`
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
          value=${pt.value}
          onInput=${i=>zi(i.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{bi()}}
            disabled=${bn.value||pt.value.trim()===""}
          >
            ${bn.value?"Joining...":ns.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{pm()}}
            disabled=${kn.value||pt.value.trim()===""}
          >
            ${kn.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{vm()}}
            disabled=${bn.value||kn.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{mm()}}
            disabled=${Wa.value||pt.value.trim()===""}
          >
            ${Wa.value?"Pinging...":"Heartbeat"}
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
            value=${hn.value}
            onInput=${i=>{hn.value=i.target.value}}
            onKeyDown=${i=>{i.key==="Enter"&&Oo()}}
            disabled=${yn.value}
          />
          <button
            class="control-btn"
            onClick=${()=>{Oo()}}
            disabled=${yn.value||hn.value.trim()===""||pt.value.trim()===""}
          >
            ${yn.value?"Sending...":"Send"}
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

        <${qr} keeper=${n} />
        <${Kr}
          actor=${pt.value.trim()||"dashboard"}
          keeper=${n}
          onPokeLodge=${()=>{zo()}}
        />
        <${jr}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${um(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${_a(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${Ja(e==null?void 0:e.quiet_start)}-${Ja(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${fl((s=e==null?void 0:e.last_tick_result)==null?void 0:s.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?o`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{zo()}}
            disabled=${Ga.value}
          >
            ${Ga.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${_m} runtime=${e} />
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
          value=${$n.value}
          onInput=${i=>{$n.value=i.target.value}}
          disabled=${Ee.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${Ha.value}
          onInput=${i=>{Ha.value=i.target.value}}
          disabled=${Ee.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{fm()}}
          disabled=${Ee.value||$n.value.trim()===""}
        >
          ${Ee.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const Fo=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],ki=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"execution",label:"Execution",icon:"🛠️",group:"observe",description:"Intervention queue for stalled work, ownership gaps, and execution drift"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"activity",label:"Activity",icon:"📊",group:"observe",description:"Unified live stream for messages, task changes, board events, and keeper events"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"council",label:"Council",icon:"🏛️",group:"coordinate",description:"Debates, quorum status, and decision flow"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals and MDAL loops in one planning surface with freshness signals"},{id:"tasks",label:"Tasks",icon:"📋",group:"coordinate",description:"Kanban-style task distribution"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}];function $m(){const t=jt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${On.value} events</span>
    </div>
  `}function ym(){const t=Pt.value.tab,e=jt.value,n=ki.find(r=>r.id===t),a=Fo.find(r=>r.id===(n==null?void 0:n.group)),[s,i]=nr(!1);return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${a?o`<span class="rail-section-chip">${a.label}</span>`:null}
        </div>
        ${Fo.map(r=>o`
          <div class="rail-nav-group" key=${r.id}>
            <div class="rail-group-label">${r.label}</div>
            <div class="rail-group-copy">${r.description}</div>
            <div class="rail-tab-list">
              ${ki.filter(u=>u.group===r.id).map(u=>o`
                  <button
                    class="rail-tab-btn ${t===u.id?"active":""}"
                    onClick=${()=>yt(u.id)}
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
            <strong>${se.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Keepers</span>
            <strong>${St.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Tasks</span>
            <strong>${Ot.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Events</span>
            <strong>${On.value}</strong>
          </div>
        </div>
        <div class="rail-snapshot-copy">
          <span>Connection ${e?"healthy":"recovering"}</span>
          <span>${(a==null?void 0:a.label)??"Observe"} workspace active</span>
        </div>
        <div class="rail-inline-actions">
          <button
            class="rail-refresh-btn"
            onClick=${()=>{ge(),t==="command"&&Dn(),t==="ops"&&Ke(),t==="board"&&Et(),t==="trpg"&&qt(),t==="goals"&&(sn(),on())}}
          >
            Refresh Now
          </button>
          <button class="rail-secondary-btn" onClick=${()=>yt("ops")}>
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
        ${s?o`<div class="rail-fold-body"><${hm} /></div>`:o`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function bm(){switch(Pt.value.tab){case"command":return o`<${np} />`;case"overview":return o`<${yo} />`;case"ops":return o`<${Sp} />`;case"council":return o`<${Np} />`;case"board":return o`<${qp} />`;case"execution":return o`<${Sv} />`;case"activity":return o`<${iv} />`;case"agents":return o`<${gv} />`;case"tasks":return o`<${hv} />`;case"goals":return o`<${Pv} />`;case"trpg":return o`<${lm} />`;default:return o`<${yo} />`}}function km(){xt(()=>{jl(),br(),ge(),Et();const n=Du();return Lu(),()=>{Vl(),n(),Pu()}},[]),xt(()=>{const n=Pt.value.tab;n==="command"&&Dn(),n==="ops"&&Ke(),n==="board"&&Et(),n==="trpg"&&qt(),n==="goals"&&(sn(),on())},[Pt.value.tab]);const t=Pt.value.tab,e=ki.find(n=>n.id===t);return o`
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
          <${$m} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${ym} />
        <main class="dashboard-main">
          ${ei.value&&!jt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${bm} />`}
        </main>
      </div>

      <${ed} />
      <${od} />
      <${Fu} />
    </div>
  `}const qo=document.getElementById("app");qo&&xl(o`<${km} />`,qo);
