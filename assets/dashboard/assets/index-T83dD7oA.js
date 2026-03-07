var gl=Object.defineProperty;var hl=(t,e,n)=>e in t?gl(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var be=(t,e,n)=>hl(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var Wa,j,Fo,jo,le,qi,Ko,Uo,Ho,bi,Ps,Es,xn={},Bo=[],$l=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Ga=Array.isArray;function Mt(t,e){for(var n in e)t[n]=e[n];return t}function ki(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function Wo(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Wa.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return sa(t,r,a,s,null)}function sa(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++Fo,__i:-1,__u:0};return s==null&&j.vnode!=null&&j.vnode(i),i}function In(t){return t.children}function en(t,e){this.props=t,this.context=e}function ze(t,e){if(e==null)return t.__?ze(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?ze(t):null}function Go(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return Go(t)}}function Fi(t){(!t.__d&&(t.__d=!0)&&le.push(t)&&!ma.__r++||qi!=j.debounceRendering)&&((qi=j.debounceRendering)||Ko)(ma)}function ma(){for(var t,e,n,a,s,i,r,u=1;le.length;)le.length>u&&le.sort(Uo),t=le.shift(),u=le.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=Mt({},a)).__v=a.__v+1,j.vnode&&j.vnode(n),xi(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??ze(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,Qo(i,n,r),a.__e=a.__=null,n.__e!=s&&Go(n)));ma.__r=0}function Jo(t,e,n,a,s,i,r,u,d,p,f){var l,c,m,$,k,A,R,T=a&&a.__k||Bo,I=e.length;for(d=yl(n,e,T,d,I),l=0;l<I;l++)(m=n.__k[l])!=null&&(c=m.__i==-1?xn:T[m.__i]||xn,m.__i=l,A=xi(t,m,c,s,i,r,u,d,p,f),$=m.__e,m.ref&&c.ref!=m.ref&&(c.ref&&Si(c.ref,null,m),f.push(m.ref,m.__c||$,m)),k==null&&$!=null&&(k=$),(R=!!(4&m.__u))||c.__k===m.__k?d=Vo(m,d,t,R):typeof m.type=="function"&&A!==void 0?d=A:$&&(d=$.nextSibling),m.__u&=-7);return n.__e=k,d}function yl(t,e,n,a,s){var i,r,u,d,p,f=n.length,l=f,c=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=sa(null,r,null,null,null):Ga(r)?r=t.__k[i]=sa(In,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=sa(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+c,r.__=t,r.__b=t.__b+1,u=null,(p=r.__i=bl(r,n,d,l))!=-1&&(l--,(u=n[p])&&(u.__u|=2)),u==null||u.__v==null?(p==-1&&(s>f?c--:s<f&&c++),typeof r.type!="function"&&(r.__u|=4)):p!=d&&(p==d-1?c--:p==d+1?c++:(p>d?c--:c++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<f;i++)(u=n[i])!=null&&(2&u.__u)==0&&(u.__e==a&&(a=ze(u)),Xo(u,u));return a}function Vo(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=Vo(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=ze(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function bl(t,e,n,a){var s,i,r,u=t.key,d=t.type,p=e[n],f=p!=null&&(2&p.__u)==0;if(p===null&&u==null||f&&u==p.key&&d==p.type)return n;if(a>(f?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((p=e[r=s>=0?s--:i++])!=null&&(2&p.__u)==0&&u==p.key&&d==p.type)return r}return-1}function ji(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||$l.test(e)?n:n+"px"}function Wn(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||ji(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||ji(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Ho,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=bi,t.addEventListener(e,i?Es:Ps,i)):t.removeEventListener(e,i?Es:Ps,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Ki(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=bi++;else if(e.t<n.u)return;return n(j.event?j.event(e):e)}}}function xi(t,e,n,a,s,i,r,u,d,p){var f,l,c,m,$,k,A,R,T,I,N,L,st,At,Tt,it,ft,O=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[u=e.__e=n.__e]),(f=j.__b)&&f(e);t:if(typeof O=="function")try{if(R=e.props,T="prototype"in O&&O.prototype.render,I=(f=O.contextType)&&a[f.__c],N=f?I?I.props.value:f.__:a,n.__c?A=(l=e.__c=n.__c).__=l.__E:(T?e.__c=l=new O(R,N):(e.__c=l=new en(R,N),l.constructor=O,l.render=xl),I&&I.sub(l),l.state||(l.state={}),l.__n=a,c=l.__d=!0,l.__h=[],l._sb=[]),T&&l.__s==null&&(l.__s=l.state),T&&O.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=Mt({},l.__s)),Mt(l.__s,O.getDerivedStateFromProps(R,l.__s))),m=l.props,$=l.state,l.__v=e,c)T&&O.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),T&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(T&&O.getDerivedStateFromProps==null&&R!==m&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(R,N),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(R,l.__s,N)===!1){for(e.__v!=n.__v&&(l.props=R,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(V){V&&(V.__=e)}),L=0;L<l._sb.length;L++)l.__h.push(l._sb[L]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(R,l.__s,N),T&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(m,$,k)})}if(l.context=N,l.props=R,l.__P=t,l.__e=!1,st=j.__r,At=0,T){for(l.state=l.__s,l.__d=!1,st&&st(e),f=l.render(l.props,l.state,l.context),Tt=0;Tt<l._sb.length;Tt++)l.__h.push(l._sb[Tt]);l._sb=[]}else do l.__d=!1,st&&st(e),f=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++At<25);l.state=l.__s,l.getChildContext!=null&&(a=Mt(Mt({},a),l.getChildContext())),T&&!c&&l.getSnapshotBeforeUpdate!=null&&(k=l.getSnapshotBeforeUpdate(m,$)),it=f,f!=null&&f.type===In&&f.key==null&&(it=Yo(f.props.children)),u=Jo(t,Ga(it)?it:[it],e,n,a,s,i,r,u,d,p),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),A&&(l.__E=l.__=null)}catch(V){if(e.__v=null,d||i!=null)if(V.then){for(e.__u|=d?160:128;u&&u.nodeType==8&&u.nextSibling;)u=u.nextSibling;i[i.indexOf(u)]=null,e.__e=u}else{for(ft=i.length;ft--;)ki(i[ft]);Is(e)}else e.__e=n.__e,e.__k=n.__k,V.then||Is(e);j.__e(V,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):u=e.__e=kl(n.__e,e,n,a,s,i,r,d,p);return(f=j.diffed)&&f(e),128&e.__u?void 0:u}function Is(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(Is)}function Qo(t,e,n){for(var a=0;a<n.length;a++)Si(n[a],n[++a],n[++a]);j.__c&&j.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){j.__e(i,s.__v)}})}function Yo(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Ga(t)?t.map(Yo):Mt({},t)}function kl(t,e,n,a,s,i,r,u,d){var p,f,l,c,m,$,k,A=n.props||xn,R=e.props,T=e.type;if(T=="svg"?s="http://www.w3.org/2000/svg":T=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(p=0;p<i.length;p++)if((m=i[p])&&"setAttribute"in m==!!T&&(T?m.localName==T:m.nodeType==3)){t=m,i[p]=null;break}}if(t==null){if(T==null)return document.createTextNode(R);t=document.createElementNS(s,T,R.is&&R),u&&(j.__m&&j.__m(e,i),u=!1),i=null}if(T==null)A===R||u&&t.data==R||(t.data=R);else{if(i=i&&Wa.call(t.childNodes),!u&&i!=null)for(A={},p=0;p<t.attributes.length;p++)A[(m=t.attributes[p]).name]=m.value;for(p in A)if(m=A[p],p!="children"){if(p=="dangerouslySetInnerHTML")l=m;else if(!(p in R)){if(p=="value"&&"defaultValue"in R||p=="checked"&&"defaultChecked"in R)continue;Wn(t,p,null,m,s)}}for(p in R)m=R[p],p=="children"?c=m:p=="dangerouslySetInnerHTML"?f=m:p=="value"?$=m:p=="checked"?k=m:u&&typeof m!="function"||A[p]===m||Wn(t,p,m,A[p],s);if(f)u||l&&(f.__html==l.__html||f.__html==t.innerHTML)||(t.innerHTML=f.__html),e.__k=[];else if(l&&(t.innerHTML=""),Jo(e.type=="template"?t.content:t,Ga(c)?c:[c],e,n,a,T=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&ze(n,0),u,d),i!=null)for(p=i.length;p--;)ki(i[p]);u||(p="value",T=="progress"&&$==null?t.removeAttribute("value"):$!=null&&($!==t[p]||T=="progress"&&!$||T=="option"&&$!=A[p])&&Wn(t,p,$,A[p],s),p="checked",k!=null&&k!=t[p]&&Wn(t,p,k,A[p],s))}return t}function Si(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){j.__e(s,n)}}function Xo(t,e,n){var a,s;if(j.unmount&&j.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||Si(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){j.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&Xo(a[s],e,n||typeof t.type!="function");n||ki(t.__e),t.__c=t.__=t.__e=void 0}function xl(t,e,n){return this.constructor(t,n)}function Sl(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),j.__&&j.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],xi(e,t=e.__k=Wo(In,null,[t]),s||xn,xn,e.namespaceURI,s?null:e.firstChild?Wa.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),Qo(i,t,r)}Wa=Bo.slice,j={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(u){t=u}throw t}},Fo=0,jo=function(t){return t!=null&&t.constructor===void 0},en.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=Mt({},this.state),typeof t=="function"&&(t=t(Mt({},n),this.props)),t&&Mt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),Fi(this))},en.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),Fi(this))},en.prototype.render=In,le=[],Ko=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Uo=function(t,e){return t.__v.__b-e.__v.__b},ma.__r=0,Ho=/(PointerCapture)$|Capture$/i,bi=0,Ps=Ki(!1),Es=Ki(!0);var Zo=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],u=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=u:r===4?a[1]=Object.assign(a[1]||{},u):r===5?(a[1]=a[1]||{})[e[++i]]=u:r===6?a[1][e[++i]]+=u+"":r?(s=t.apply(u,Zo(t,u,n,["",null])),a.push(s),u[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(u)}return a},Ui=new Map;function wl(t){var e=Ui.get(this);return e||(e=new Map,Ui.set(this,e)),(e=Zo(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",u="",d=[0],p=function(c){i===1&&(c||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,c,r):i===3&&(c||r)?(d.push(3,c,r),i=2):i===2&&r==="..."&&c?d.push(4,c,0):i===2&&r&&!c?d.push(5,0,!0,r):i>=5&&((r||!c&&i===5)&&(d.push(i,0,r,s),i=6),c&&(d.push(i,c,0,s),i=6)),r=""},f=0;f<n.length;f++){f&&(i===1&&p(),p(f));for(var l=0;l<n[f].length;l++)a=n[f][l],i===1?a==="<"?(p(),d=[d],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:u?a===u?u="":r+=a:a==='"'||a==="'"?u=a:a===">"?(p(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[f][l+1]===">")?(p(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(p(),i=2):r+=a),i===3&&r==="!--"&&(i=4,d=d[0])}return p(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=wl.bind(Wo),Sn,J,ts,Hi,Os=0,tr=[],Y=j,Bi=Y.__b,Wi=Y.__r,Gi=Y.diffed,Ji=Y.__c,Vi=Y.unmount,Qi=Y.__;function wi(t,e){Y.__h&&Y.__h(J,t,Os||e),Os=0;var n=J.__H||(J.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function er(t){return Os=1,Al(sr,t)}function Al(t,e,n){var a=wi(Sn++,2);if(a.t=t,!a.__c&&(a.__=[sr(void 0,e),function(u){var d=a.__N?a.__N[0]:a.__[0],p=a.t(d,u);d!==p&&(a.__N=[p,a.__[1]],a.__c.setState({}))}],a.__c=J,!J.__f)){var s=function(u,d,p){if(!a.__c.__H)return!0;var f=a.__c.__H.__.filter(function(c){return!!c.__c});if(f.every(function(c){return!c.__N}))return!i||i.call(this,u,d,p);var l=a.__c.props!==u;return f.forEach(function(c){if(c.__N){var m=c.__[0];c.__=c.__N,c.__N=void 0,m!==c.__[0]&&(l=!0)}}),i&&i.call(this,u,d,p)||l};J.__f=!0;var i=J.shouldComponentUpdate,r=J.componentWillUpdate;J.componentWillUpdate=function(u,d,p){if(this.__e){var f=i;i=void 0,s(u,d,p),i=f}r&&r.call(this,u,d,p)},J.shouldComponentUpdate=s}return a.__N||a.__}function ht(t,e){var n=wi(Sn++,3);!Y.__s&&ar(n.__H,e)&&(n.__=t,n.u=e,J.__H.__h.push(n))}function nr(t,e){var n=wi(Sn++,7);return ar(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Tl(){for(var t;t=tr.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(ia),t.__H.__h.forEach(Ms),t.__H.__h=[]}catch(e){t.__H.__h=[],Y.__e(e,t.__v)}}Y.__b=function(t){J=null,Bi&&Bi(t)},Y.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Qi&&Qi(t,e)},Y.__r=function(t){Wi&&Wi(t),Sn=0;var e=(J=t.__c).__H;e&&(ts===J?(e.__h=[],J.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(ia),e.__h.forEach(Ms),e.__h=[],Sn=0)),ts=J},Y.diffed=function(t){Gi&&Gi(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(tr.push(e)!==1&&Hi===Y.requestAnimationFrame||((Hi=Y.requestAnimationFrame)||Cl)(Tl)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),ts=J=null},Y.__c=function(t,e){e.some(function(n){try{n.__h.forEach(ia),n.__h=n.__h.filter(function(a){return!a.__||Ms(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],Y.__e(a,n.__v)}}),Ji&&Ji(t,e)},Y.unmount=function(t){Vi&&Vi(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{ia(a)}catch(s){e=s}}),n.__H=void 0,e&&Y.__e(e,n.__v))};var Yi=typeof requestAnimationFrame=="function";function Cl(t){var e,n=function(){clearTimeout(a),Yi&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);Yi&&(e=requestAnimationFrame(n))}function ia(t){var e=J,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),J=e}function Ms(t){var e=J;t.__c=t.__(),J=e}function ar(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}function sr(t,e){return typeof e=="function"?e(t):e}var Nl=Symbol.for("preact-signals");function Ja(){if(Qt>1)Qt--;else{for(var t,e=!1;nn!==void 0;){var n=nn;for(nn=void 0,zs++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&rr(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(zs=0,Qt--,e)throw t}}function Rl(t){if(Qt>0)return t();Qt++;try{return t()}finally{Ja()}}var F=void 0;function ir(t){var e=F;F=void 0;try{return t()}finally{F=e}}var nn=void 0,Qt=0,zs=0,fa=0;function or(t){if(F!==void 0){var e=t.n;if(e===void 0||e.t!==F)return e={i:0,S:t,p:F.s,n:void 0,t:F,e:void 0,x:void 0,r:e},F.s!==void 0&&(F.s.n=e),F.s=e,t.n=e,32&F.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=F.s,e.n=void 0,F.s.n=e,F.s=e),e}}function X(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}X.prototype.brand=Nl;X.prototype.h=function(){return!0};X.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:ir(function(){var a;(a=e.W)==null||a.call(e)}))};X.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&ir(function(){var s;(s=e.Z)==null||s.call(e)}))}};X.prototype.subscribe=function(t){var e=this;return On(function(){var n=e.value,a=F;F=void 0;try{t(n)}finally{F=a}},{name:"sub"})};X.prototype.valueOf=function(){return this.value};X.prototype.toString=function(){return this.value+""};X.prototype.toJSON=function(){return this.value};X.prototype.peek=function(){var t=F;F=void 0;try{return this.value}finally{F=t}};Object.defineProperty(X.prototype,"value",{get:function(){var t=or(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(zs>100)throw new Error("Cycle detected");this.v=t,this.i++,fa++,Qt++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Ja()}}}});function _(t,e){return new X(t,e)}function rr(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function lr(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function cr(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function fe(t,e){X.call(this,void 0),this.x=t,this.s=void 0,this.g=fa-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}fe.prototype=new X;fe.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===fa))return!0;if(this.g=fa,this.f|=1,this.i>0&&!rr(this))return this.f&=-2,!0;var t=F;try{lr(this),F=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return F=t,cr(this),this.f&=-2,!0};fe.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}X.prototype.S.call(this,t)};fe.prototype.U=function(t){if(this.t!==void 0&&(X.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};fe.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(fe.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=or(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function vt(t,e){return new fe(t,e)}function ur(t){var e=t.u;if(t.u=void 0,typeof e=="function"){Qt++;var n=F;F=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,Ai(t),a}finally{F=n,Ja()}}}function Ai(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,ur(t)}function Dl(t){if(F!==this)throw new Error("Out-of-order effect");cr(this),F=t,this.f&=-2,8&this.f&&Ai(this),Ja()}function Ue(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Ue.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Ue.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,ur(this),lr(this),Qt++;var t=F;return F=this,Dl.bind(this,t)};Ue.prototype.N=function(){2&this.f||(this.f|=2,this.o=nn,nn=this)};Ue.prototype.d=function(){this.f|=8,1&this.f||Ai(this)};Ue.prototype.dispose=function(){this.d()};function On(t,e){var n=new Ue(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var dr,Gn,Ll=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,pr=[];On(function(){dr=this.N})();function He(t,e){j[t]=e.bind(null,j[t]||function(){})}function _a(t){if(Gn){var e=Gn;Gn=void 0,e()}Gn=t&&t.S()}function vr(t){var e=this,n=t.data,a=El(n);a.value=n;var s=nr(function(){for(var u=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var p=vt(function(){var m=a.value.value;return m===0?0:m===!0?"":m||""}),f=vt(function(){return!Array.isArray(p.value)&&!jo(p.value)}),l=On(function(){if(this.N=mr,f.value){var m=p.value;u.__v&&u.__v.__e&&u.__v.__e.nodeType===3&&(u.__v.__e.data=m)}}),c=e.__$u.d;return e.__$u.d=function(){l(),c.call(this)},[f,p]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}vr.displayName="ReactiveTextNode";Object.defineProperties(X.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:vr},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});He("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof X&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});He("__r",function(t,e){if(t(e),e.type!==In){_a();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return On(function(){r=this},{name:i}),r.c=s,r})(function(){var s;Ll&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),_a(n)}});He("__e",function(t,e,n,a){_a(),t(e,n,a)});He("diffed",function(t,e){_a();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var u=i[r];u!==void 0&&!(r in a)&&(u.d(),i[r]=void 0)}else i={},n.U=i;for(var d in a){var p=i[d],f=a[d];p===void 0?(p=Pl(n,d,f),i[d]=p):p.o(f,s)}for(var l in a)s[l]=a[l]}}t(e)});function Pl(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=_(n),r=n.peek();return{o:function(u,d){i.value=u,r=u.peek()},d:On(function(){this.N=mr;var u=i.value.value;r!==u?(r=void 0,s?t[e]=u:u!=null&&(u!==!1||e[4]==="-")?t.setAttribute(e,u):t.removeAttribute(e)):r=void 0})}}He("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var u=r.__$u;u&&(r.__$u=void 0,u.d())}}t(e)});He("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});en.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var u in this.props)if(!(u in t))return!0;return!1};function El(t,e){return nr(function(){return _(t,e)},[])}var Il=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Ol(){Rl(function(){for(var t;t=pr.shift();)dr.call(t)})}function mr(){pr.push(this)===1&&(j.requestAnimationFrame||Il)(Ol)}const Ml=["command","overview","board","activity","council","goals","execution","tasks","agents","ops","trpg"],fr={tab:"overview",params:{},postId:null},zl={journal:"activity",mdal:"goals"};function Xi(t){return!!t&&Ml.includes(t)}function Zi(t){if(t)return zl[t]??t}function qs(t){try{return decodeURIComponent(t)}catch{return t}}function Fs(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function ql(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function _r(t,e){const n=Zi(t[0]),a=Zi(e.tab),s=Xi(n)?n:Xi(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=qs(t[2]):t[0]==="post"&&t[1]&&(i=qs(t[1]))),{tab:s,params:e,postId:i}}function ga(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return fr;const n=qs(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const u=n.indexOf("?");u>=0&&(a=n.slice(0,u),s=n.slice(u+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=Fs(s),r=ql(a);return _r(r,i)}function Fl(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...fr,params:Fs(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=Fs(e.replace(/^\?/,""));return _r(a,s)}function gr(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const Pt=_(ga(window.location.hash));window.addEventListener("hashchange",()=>{Pt.value=ga(window.location.hash)});function bt(t,e){const n={tab:t,params:{},postId:null};window.location.hash=gr(n)}function jl(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Kl(){if(window.location.hash&&window.location.hash!=="#"){Pt.value=ga(window.location.hash);return}const t=Fl(window.location.pathname,window.location.search);if(t){Pt.value=t;const e=gr(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",Pt.value=ga(window.location.hash)}const to="masc_dashboard_sse_session_id",Ul=1e3,Hl=15e3,Ft=_(!1),Mn=_(0),hr=_(null),te=_([]);function Bl(){let t=sessionStorage.getItem(to);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(to,t)),t}const Wl=200;function Gl(t,e,n="system",a={}){const s={agent:t,text:e,timestamp:Date.now(),kind:n,...a};te.value=[s,...te.value].slice(0,Wl)}function js(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function eo(t,e){const n=js(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function $t(t,e,n,a,s={}){Gl(t,e,n,{eventType:a,...s})}let Lt=null,Pe=null,Ks=0;function $r(){Pe&&(clearTimeout(Pe),Pe=null)}function Jl(){if(Pe)return;Ks++;const t=Math.min(Ks,5),e=Math.min(Hl,Ul*Math.pow(2,t));Pe=setTimeout(()=>{Pe=null,yr()},e)}function yr(){$r(),Lt&&(Lt.close(),Lt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",Bl());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);Lt=i,i.onopen=()=>{Lt===i&&(Ks=0,Ft.value=!0)},i.onerror=()=>{Lt===i&&(Ft.value=!1,i.close(),Lt=null,Jl())},i.onmessage=r=>{try{const u=JSON.parse(r.data);Mn.value++,hr.value=u,Vl(u)}catch{}}}function Vl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":$t(n,"Joined","system","agent_joined");break;case"agent_left":$t(n,"Left","system","agent_left");break;case"broadcast":$t(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":$t(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":$t(n,eo("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:js(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":$t(n,eo("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:js(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":$t(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":$t(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":$t(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":$t(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:$t(n,e,"system","unknown")}}function Ql(){$r(),Lt&&(Lt.close(),Lt=null),Ft.value=!1}function br(){return new URLSearchParams(window.location.search)}function kr(){const t=br(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function xr(){return{...kr(),"Content-Type":"application/json"}}const Yl=15e3,Ti=3e4,Xl=6e4,no=new Set([408,425,429,500,502,503,504]);class zn extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,i=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);be(this,"method");be(this,"path");be(this,"status");be(this,"statusText");be(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function Ci(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new zn({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(s)}}function Zl(){var e,n;const t=br();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function xt(t){const e=await Ci(t,{headers:kr()},Yl);if(!e.ok)throw new zn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function tc(t){return new Promise(e=>setTimeout(e,t))}function ec(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function nc(t){if(t instanceof zn)return t.timeout||typeof t.status=="number"&&no.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=ec(t.message);return e!==null&&no.has(e)}async function Be(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!nc(s)||a>=n)throw s;const i=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${i}ms`,s),await tc(i),a+=1}}async function It(t,e,n,a=Ti){const s=await Ci(t,{method:"POST",headers:{...xr(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new zn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function ac(t,e,n,a=Ti){const s=await Ci(t,{method:"POST",headers:{...xr(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new zn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function sc(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function ic(t){var e,n,a,s,i,r,u;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(d)}return((u=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:u.text)??""}async function mt(t,e){const n=await ac("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Xl),a=sc(n);return ic(a)}function oc(t="compact"){return xt(`/api/v1/dashboard?mode=${t}`)}function rc(t={}){return Be("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return xt(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function lc(){return xt("/api/v1/operator")}function cc(){return xt("/api/v1/command-plane")}function uc(t,e){return It(t,e)}function dc(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return Ti}}function qn(t){return It("/api/v1/operator/action",t,void 0,dc(t))}function pc(t,e){return It("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const vc=new Set(["lodge-system","team-session"]);function qe(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function mc(t){return vc.has(t.trim().toLowerCase())}function fc(t){return t.filter(e=>!mc(e.author))}function _c(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Sr(t){if(!E(t))return null;const e=g(t.id,"").trim(),n=g(t.author,"").trim(),a=g(t.content,"").trim();if(!e||!n)return null;const s=z(t.score,0),i=z(t.votes_up,0),r=z(t.votes_down,0),u=z(t.votes,s||i-r),d=z(t.comment_count,z(t.reply_count,0)),p=(()=>{const $=t.flair;if(typeof $=="string"&&$.trim())return $.trim();if(E($)){const A=g($.name,"").trim();if(A)return A}return g(t.flair_name,"").trim()||void 0})(),f=g(t.created_at_iso,"").trim()||qe(t.created_at),l=g(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?qe(t.updated_at):f),m=g(t.title,"").trim()||_c(a);return{id:e,author:n,title:m,content:a,tags:[],votes:u,vote_balance:s,comment_count:d,created_at:f,updated_at:l,flair:p,hearth_count:z(t.hearth_count,0)}}function gc(t){if(!E(t))return null;const e=g(t.id,"").trim(),n=g(t.post_id,"").trim(),a=g(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:g(t.content,""),created_at:qe(t.created_at)}}async function hc(t,e){return Be("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),s=await xt(`/api/v1/board${a?`?${a}`:""}`),i=Array.isArray(s.posts)?s.posts.map(Sr).filter(u=>u!==null):[];return{posts:e!=null&&e.excludeSystem?fc(i):i}})}async function $c(t){return Be("fetchBoardPost",async()=>{const e=await xt(`/api/v1/board/${t}?format=flat`),n=E(e.post)?e.post:e,a=Sr(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(gc).filter(r=>r!==null);return{...a,comments:i}})}function wr(t,e){return It("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Zl()})}function yc(t,e,n){return It("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function bc(t){const e=g(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function nt(...t){for(const e of t){const n=g(e,"");if(n.trim())return n.trim()}return""}function ao(t){const e=bc(nt(t.outcome,t.result,t.result_code));if(!e)return;const n=nt(t.reason,t.reason_code,t.description,t.detail),a=nt(t.summary,t.summary_ko,t.summary_en,t.note),s=nt(t.details,t.details_text,t.text,t.note),i=nt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=nt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),u=nt(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const l=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof l=="string"?[l]:Array.isArray(l)?l.map(c=>{if(typeof c=="string")return c.trim();if(E(c)){const m=g(c.summary,"").trim();if(m)return m;const $=g(c.text,"").trim();if($)return $;const k=g(c.type,"").trim();return k||g(c.event_id,"").trim()}return""}).filter(c=>c.length>0):[]})(),p=(()=>{const l=z(t.turn,Number.NaN);if(Number.isFinite(l))return l;const c=z(t.turn_number,Number.NaN);if(Number.isFinite(c))return c;const m=z(t.current_turn,Number.NaN);if(Number.isFinite(m))return m;const $=z(t.round,Number.NaN);return Number.isFinite($)?$:void 0})(),f=nt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:u||void 0,turn:p,phase:f||void 0}}function kc(t,e){const n=E(t.state)?t.state:{};if(g(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>E(r)?g(r.type,"")==="session.outcome":!1),i=E(n.session_outcome)?n.session_outcome:{};if(E(i)&&Object.keys(i).length>0){const r=ao(i);if(r)return r}if(E(s))return ao(E(s.payload)?s.payload:{})}function E(t){return typeof t=="object"&&t!==null}function g(t,e=""){return typeof t=="string"?t:e}function z(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function xc(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Us(t,e=!1){return typeof t=="boolean"?t:e}function Ve(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(E(e)){const n=g(e.name,"").trim(),a=g(e.id,"").trim(),s=g(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function Sc(t){const e={};if(!E(t)&&!Array.isArray(t))return e;if(E(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),i=g(a,"").trim();!s||!i||(e[s]=i)}),e;for(const n of t){if(!E(n))continue;const a=nt(n.to,n.target,n.actor_id,n.name,n.id),s=nt(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function wc(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function _t(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}const Ac=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Tc(t){const e=E(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const i=a.trim();i&&(Ac.has(i.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[i]=s))}),n}function Cc(t,e){if(t!=="dice.rolled")return;const n=z(e.raw_d20,0),a=z(e.total,0),s=z(e.bonus,0),i=g(e.action,"roll"),r=z(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function Nc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Rc(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Dc(t,e,n,a){const s=n||e||g(a.actor_id,"")||g(a.actor_name,"");switch(t){case"turn.action.proposed":{const i=g(a.proposed_action,g(a.reply,""));return i?`${s||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=g(a.reply,g(a.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return g(a.reply,g(a.content,g(a.text,"Narration")));case"dice.rolled":{const i=g(a.action,"roll"),r=z(a.total,0),u=z(a.dc,0),d=g(a.label,""),p=s||"actor",f=u>0?` vs DC ${u}`:"",l=d?` (${d})`:"";return`${p} ${i}: ${r}${f}${l}`}case"turn.started":return`Turn ${z(a.turn,1)} started`;case"phase.changed":return`Phase: ${g(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${g(a.name,E(a.actor)?g(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${g(a.keeper_name,g(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${g(a.keeper_name,g(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${z(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${z(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||g(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||g(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${g(a.reason_code,"unknown")}`;case"memory.signal":{const i=E(a.entity_refs)?a.entity_refs:{},r=g(i.requested_tier,""),u=g(i.effective_tier,""),d=Us(i.guardrail_applied,!1),p=g(a.summary_en,g(a.summary_ko,"Memory signal"));if(!r&&!u)return p;const f=r&&u?`${r}->${u}`:u||r;return`${p} [${f}${d?" (guardrail)":""}]`}case"world.event":{if(g(a.event_type,"")==="canon.check"){const r=g(a.status,"unknown"),u=g(a.contract_id,"n/a");return`Canon ${r}: ${u}`}return g(a.description,g(a.summary,"World event"))}case"combat.attack":return g(a.summary,g(a.result,"Attack resolved"));case"combat.defense":return g(a.summary,g(a.result,"Defense resolved"));case"session.outcome":return g(a.summary,g(a.outcome,"Session ended"));default:{const i=Nc(a);return i?`${t}: ${i}`:t}}}function Lc(t,e){const n=E(t)?t:{},a=g(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=g(n.actor_name,"").trim()||e[s]||g(E(n.payload)?n.payload.actor_name:"",""),r=E(n.payload)?n.payload:{},u=g(n.ts,g(n.timestamp,new Date().toISOString())),d=g(n.phase,g(r.phase,"")),p=g(n.category,"");return{type:a,actor:i||s||g(r.actor_name,""),actor_id:s||g(r.actor_id,""),actor_name:i,seq:n.seq,room_id:g(n.room_id,""),phase:d||void 0,category:p||Rc(a),visibility:g(n.visibility,g(r.visibility,"public")),event_id:g(n.event_id,""),content:Dc(a,s,i,r),dice_roll:Cc(a,r),timestamp:u}}function Pc(t,e,n){var it,ft;const a=g(t.room_id,"")||n||"default",s=E(t.state)?t.state:{},i=E(s.party)?s.party:{},r=E(s.actor_control)?s.actor_control:{},u=E(s.join_gate)?s.join_gate:{},d=E(s.contribution_ledger)?s.contribution_ledger:{},p=Object.entries(i).map(([O,V])=>{const y=E(V)?V:{},oe=_t(y,"max_hp",void 0,10),Je=_t(y,"hp",void 0,oe),jn=_t(y,"max_mp",void 0,0),Kn=_t(y,"mp",void 0,0),Un=_t(y,"level",void 0,1),Hn=_t(y,"xp",void 0,0),Bn=Us(y.alive,Je>0),v=r[O],C=typeof v=="string"?v:void 0,q=wc(y.role,O,C),Z=xc(y.generation),M=nt(y.joined_at,y.joinedAt,y.started_at,y.startedAt),ot=nt(y.claimed_at,y.claimedAt,y.assigned_at,y.assignedAt,y.assigned_time),Q=nt(y.last_seen,y.lastSeen,y.last_seen_at,y.lastSeenAt,y.last_active,y.lastActive),G=nt(y.scene,y.current_scene,y.currentScene,y.world_scene,y.scene_name,y.sceneName),rt=nt(y.location,y.current_location,y.currentLocation,y.position,y.zone,y.area);return{id:O,name:g(y.name,O),role:q,keeper:C,archetype:g(y.archetype,""),persona:g(y.persona,""),portrait:g(y.portrait,"")||void 0,background:g(y.background,"")||void 0,traits:Ve(y.traits),skills:Ve(y.skills),stats_raw:Tc(y),status:Bn?"active":"dead",generation:Z,joined_at:M||void 0,claimed_at:ot||void 0,last_seen:Q||void 0,scene:G||void 0,location:rt||void 0,inventory:Ve(y.inventory),notes:Ve(y.notes),relationships:Sc(y.relationships),stats:{hp:Je,max_hp:oe,mp:Kn,max_mp:jn,level:Un,xp:Hn,strength:_t(y,"strength","str",10),dexterity:_t(y,"dexterity","dex",10),constitution:_t(y,"constitution","con",10),intelligence:_t(y,"intelligence","int",10),wisdom:_t(y,"wisdom","wis",10),charisma:_t(y,"charisma","cha",10)}}}),f=p.filter(O=>O.status!=="dead"),l=kc(t,e),c={phase_open:Us(u.phase_open,!0),min_points:z(u.min_points,3),window:g(u.window,"round_boundary_only"),last_opened_turn:typeof u.last_opened_turn=="number"?u.last_opened_turn:null,last_closed_turn:typeof u.last_closed_turn=="number"?u.last_closed_turn:null},m=Object.entries(d).map(([O,V])=>{const y=E(V)?V:{};return{actor_id:O,score:z(y.score,0),last_reason:g(y.last_reason,"")||null,reasons:Ve(y.reasons)}}),$=p.reduce((O,V)=>(O[V.id]=V.name,O),{}),k=e.map(O=>Lc(O,$)),A=z(s.turn,1),R=g(s.phase,"round"),T=g(s.map,""),I=E(s.world)?s.world:{},N=T||g(I.ascii_map,g(I.map,"")),L=k.filter((O,V)=>{const y=e[V];if(!E(y))return!1;const oe=E(y.payload)?y.payload:{};return z(oe.turn,-1)===A}),st=(L.length>0?L:k).slice(-12),At=g(s.status,"active");return{session:{id:a,room:a,status:At==="ended"?"ended":At==="paused"?"paused":"active",round:A,actors:f,created_at:((it=k[0])==null?void 0:it.timestamp)??new Date().toISOString()},current_round:{round_number:A,phase:R,events:st,timestamp:((ft=k[k.length-1])==null?void 0:ft.timestamp)??new Date().toISOString()},map:N||void 0,join_gate:c,contribution_ledger:m,outcome:l,party:f,story_log:k,history:[]}}async function Ec(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await xt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Ic(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([xt(`/api/v1/trpg/state${e}`),Ec(t)]);return Pc(n,a,t)}function Oc(t){return It("/api/v1/trpg/rounds/run",{room_id:t})}function Mc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function zc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),It("/api/v1/trpg/dice/roll",e)}function qc(t,e){const n=Mc();return It("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Fc(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),It("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function jc(t,e,n){return It("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Kc(t,e,n){const a=await mt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function Uc(t){const e=await mt("trpg.mid_join.request",t);return JSON.parse(e)}async function Ar(t,e){await mt("masc_broadcast",{agent_name:t,message:e})}async function Hc(t,e,n=1){await mt("masc_add_task",{title:t,description:e,priority:n})}async function Bc(t){return mt("masc_join",{agent_name:t})}async function Tr(t){await mt("masc_leave",{agent_name:t})}async function Wc(t){await mt("masc_heartbeat",{agent_name:t})}async function Gc(t=40){return(await mt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Jc(t,e=20){return mt("masc_task_history",{task_id:t,limit:e})}async function Vc(){return Be("fetchDebates",async()=>{const t=await xt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!E(e))return null;const n=g(e.id,"").trim(),a=g(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:g(e.status,"open"),argument_count:z(e.argument_count,0),created_at:qe(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Qc(){return Be("fetchCouncilSessions",async()=>{const t=await xt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!E(e))return null;const n=g(e.id,"").trim(),a=g(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:g(e.initiator,"system"),votes:z(e.votes,0),quorum:z(e.quorum,0),state:g(e.state,"open"),created_at:qe(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Yc(t){const e=await mt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Xc(t){return Be("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await xt(`/api/v1/council/debates/${e}/summary`);if(!E(n))return null;const a=g(n.id,"").trim();return a?{id:a,topic:g(n.topic,""),status:g(n.status,"open"),support_count:z(n.support_count,0),oppose_count:z(n.oppose_count,0),neutral_count:z(n.neutral_count,0),total_arguments:z(n.total_arguments,0),created_at:qe(n.created_at_iso??n.created_at),summary_text:g(n.summary_text,"")}:null})}function Zc(t,e,n){return mt("masc_keeper_msg",{name:t,message:e})}async function tu(){try{const t=await mt("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const an=_(""),jt=_({}),at=_({}),Hs=_({}),Bs=_({}),Ws=_({}),Gs=_({}),Kt=_({});function et(t,e,n){t.value={...t.value,[e]:n}}function Ht(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function U(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function kt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ne(t){return typeof t=="boolean"?t:void 0}function Js(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Vs(t){return Array.isArray(t)?t.map(e=>U(e)).filter(e=>!!e):[]}function eu(t){var n;const e=(n=U(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function nu(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function es(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Ht(a))continue;const s=U(a.name);if(!s)continue;const i=U(a[e]);e==="summary"?n.push({name:s,summary:i}):n.push({name:s,reason:i})}return n}function au(t){if(!Ht(t))return null;const e=U(t.name);return e?{name:e,trigger:U(t.trigger),outcome:U(t.outcome),summary:U(t.summary),reason:U(t.reason)}:null}function su(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function iu(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Cr(t,e,n){return U(t)??iu(e,n)}function Nr(t,e){return typeof t=="boolean"?t:e==="recover"}function ha(t){if(!Ht(t))return null;const e=U(t.health_state),n=U(t.next_action_path),a=U(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:U(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:Js(t.last_reply_at),last_reply_preview:U(t.last_reply_preview)??null,last_error:U(t.last_error)??null,next_eligible_at_s:kt(t.next_eligible_at_s)??null,recoverable:Nr(t.recoverable,n),summary:Cr(t.summary,e,U(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Ni(t){return Ht(t)?{hour:kt(t.hour),checked:kt(t.checked)??0,acted:kt(t.acted)??0,acted_names:Vs(t.acted_names),activity_report:U(t.activity_report),quiet_hours_overridden:Ne(t.quiet_hours_overridden),skipped_reason:U(t.skipped_reason),acted_rows:es(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:es(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:es(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(au).filter(e=>e!==null):[]}:null}function ou(t){return Ht(t)?{enabled:Ne(t.enabled)??!1,interval_s:kt(t.interval_s)??0,quiet_start:kt(t.quiet_start),quiet_end:kt(t.quiet_end),quiet_active:Ne(t.quiet_active),use_planner:Ne(t.use_planner),delegate_llm:Ne(t.delegate_llm),agent_count:kt(t.agent_count),agents:Vs(t.agents),last_tick_ago_s:kt(t.last_tick_ago_s)??null,last_tick_ago:U(t.last_tick_ago),total_ticks:kt(t.total_ticks),total_checkins:kt(t.total_checkins),last_skip_reason:U(t.last_skip_reason)??null,last_tick_result:Ni(t.last_tick_result),active_self_heartbeats:Vs(t.active_self_heartbeats)}:null}function ru(t){return Ht(t)?{status:t.status,diagnostic:ha(t.diagnostic)}:null}function lu(t){return Ht(t)?{recovered:Ne(t.recovered)??!1,skipped_reason:U(t.skipped_reason)??null,before:ha(t.before),after:ha(t.after),down:t.down,up:t.up}:null}function cu(t,e){var T,I;if(!(t!=null&&t.name))return null;const n=U((T=t.agent)==null?void 0:T.status)??U(t.status)??"unknown",a=U((I=t.agent)==null?void 0:I.error)??null,s=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,u=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,p=t.proactive_cooldown_sec??0,f=t.last_proactive_ago_s??null,l=d&&f!=null?Math.max(0,p-f):null,c=r<=0||u==null?"never":u>900?"stale":"fresh",m=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,$=a??(s&&!i?"keeper keepalive is not running":null),k=n==="offline"||n==="inactive"?"offline":$?"degraded":c==="stale"?"stale":c==="never"?"idle":"healthy",A=$?su($):e!=null&&e.quiet_active&&c!=="fresh"?"quiet_hours":s&&!i?"disabled":r<=0?"never_started":l!=null&&l>0?"min_gap":c==="fresh"||c==="stale"?"no_recent_activity":"unknown",R=k==="offline"||k==="degraded"||k==="stale"?"recover":A==="quiet_hours"?"manual_lodge_poke":A==="unknown"?"probe":"direct_message";return{health_state:k,quiet_reason:A,next_action_path:R,last_reply_status:c,last_reply_at:m,last_reply_preview:null,last_error:$,next_eligible_at_s:l!=null&&l>0?l:null,recoverable:Nr(void 0,R),summary:Cr(void 0,k,A),keepalive_running:i}}function uu(t,e){if(!Ht(t))return null;const n=eu(t.role),a=U(t.content)??U(t.preview);if(!a)return null;const s=Js(t.ts_unix)??Js(t.timestamp);return{id:`${n}-${s??"entry"}-${e}`,role:n,label:nu(n),text:a,timestamp:s,delivery:"history"}}function du(t,e,n){const a=Ht(n)?n:null,s=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((i,r)=>uu(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:ha(a==null?void 0:a.diagnostic),history:s,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function so(t,e){const n=at.value[t]??[];at.value={...at.value,[t]:[...n,e].slice(-50)}}function pu(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function vu(t,e){const a=(at.value[t]??[]).filter(s=>s.delivery!=="history"&&!e.some(i=>pu(s,i)));at.value={...at.value,[t]:[...e,...a].slice(-50)}}function Va(t,e){jt.value={...jt.value,[t]:e},vu(t,e.history)}function io(t,e){const n=jt.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Va(t,{...n,diagnostic:{...a,...e}})}async function Ri(){Fe();try{await _e()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function oa(t){an.value=t.trim()}async function Rr(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&jt.value[n])return jt.value[n];et(Hs,n,!0),et(Kt,n,null);try{const a=await mt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let s=null;try{s=JSON.parse(a)}catch{s=null}const i=du(n,a,s);return Va(n,i),i}catch(a){const s=a instanceof Error?a.message:`Failed to inspect ${n}`;return et(Kt,n,s),null}finally{et(Hs,n,!1)}}async function mu(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const s=`local-${Date.now()}`;so(n,{id:s,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),et(Bs,n,!0),et(Kt,n,null);try{const i=await Zc(n,a);at.value={...at.value,[n]:(at.value[n]??[]).map(r=>r.id===s?{...r,delivery:"delivered"}:r)},so(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),io(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await Ri()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw at.value={...at.value,[n]:(at.value[n]??[]).map(u=>u.id===s?{...u,delivery:"error",error:r}:u)},io(n,{last_reply_status:"error",last_error:r}),et(Kt,n,r),i}finally{et(Bs,n,!1)}}async function fu(t,e){const n=t.trim();if(!n)return null;et(Ws,n,!0),et(Kt,n,null);try{const a=await qn({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),s=ru(a.result),i=(s==null?void 0:s.diagnostic)??null;if(i){const r=jt.value[n];Va(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??at.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await Ri(),i}catch(a){const s=a instanceof Error?a.message:`Failed to probe ${n}`;throw et(Kt,n,s),a}finally{et(Ws,n,!1)}}async function _u(t,e){const n=t.trim();if(!n)return null;et(Gs,n,!0),et(Kt,n,null);try{const a=await qn({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),s=lu(a.result),i=(s==null?void 0:s.after)??null;if(i){const r=jt.value[n];Va(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??at.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await Ri(),i}catch(a){const s=a instanceof Error?a.message:`Failed to recover ${n}`;throw et(Kt,n,s),a}finally{et(Gs,n,!1)}}const ae=_([]),Ot=_([]),me=_([]),St=_([]),se=_(null),tn=_(null),Qs=_(new Map),Ut=_([]),wn=_("hot"),ce=_(!0),Dr=_(null),zt=_(""),An=_([]),Re=_(!1),Lr=_(new Map),Ys=_("unknown"),Xs=_(null),Zs=_(!1),Tn=_(!1),ti=_(!1),De=_(!1),gu=_(null),ei=_(null),Pr=_(null),Er=_(null),hu=vt(()=>ae.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle")),Ir=vt(()=>{const t=Ot.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function $u(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const s=a.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const Or=vt(()=>{const t=new Map;for(const e of St.value)t.set(e.name,$u(e));return t}),yu=12e4;function bu(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const s=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof s=="number"?Date.now()-s*1e3:null}const Mr=vt(()=>{const t=Date.now(),e=new Set,n=Qs.value;for(const a of St.value){const s=bu(a,n);s!=null&&t-s>yu&&e.add(a.name)}return e}),$a={},ku=5e3;function Fe(){delete $a.compact,delete $a.full}function lt(t){return typeof t=="object"&&t!==null}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function S(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function sn(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function xu(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function zr(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Su(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function wu(t){if(!lt(t))return null;const e=b(t.name);return e?{name:e,status:zr(t.status),current_task:b(t.current_task)??null,last_seen:b(t.last_seen),emoji:b(t.emoji),koreanName:b(t.koreanName)??b(t.korean_name),model:b(t.model),traits:sn(t.traits),interests:sn(t.interests),activityLevel:S(t.activityLevel)??S(t.activity_level),primaryValue:b(t.primaryValue)??b(t.primary_value)}:null}function Au(t){if(!lt(t))return null;const e=b(t.id),n=b(t.title);return!e||!n?null:{id:e,title:n,status:Su(t.status),priority:S(t.priority),assignee:b(t.assignee),description:b(t.description),created_at:b(t.created_at),updated_at:b(t.updated_at)}}function Tu(t){if(!lt(t))return null;const e=b(t.from)??b(t.from_agent)??"system",n=b(t.content)??"",a=b(t.timestamp)??new Date().toISOString();return{id:b(t.id),seq:S(t.seq),from:e,content:n,timestamp:a,type:b(t.type)}}function Cu(t){return Array.isArray(t)?t.map(e=>{if(!lt(e))return null;const n=S(e.ts_unix);if(n==null)return null;const a=lt(e.handoff)?e.handoff:null;return{ts:n,context_ratio:S(e.context_ratio)??0,context_tokens:S(e.context_tokens)??0,context_max:S(e.context_max)??0,latency_ms:S(e.latency_ms)??0,generation:S(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:S(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:S(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?S(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function oo(t){if(!lt(t))return null;const e=b(t.health_state),n=b(t.next_action_path),a=b(t.last_reply_status);if(!e||!n||!a)return null;const s=b(t.quiet_reason)??null,i=b(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":s==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":s==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":s==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:s,next_action_path:n,last_reply_status:a,last_reply_at:xu(t.last_reply_at)??b(t.last_reply_at)??null,last_reply_preview:b(t.last_reply_preview)??null,last_error:b(t.last_error)??null,next_eligible_at_s:S(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:i,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Nu(t,e){return(Array.isArray(t)?t:lt(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!lt(a))return null;const s=lt(a.agent)?a.agent:null,i=lt(a.context)?a.context:null,r=lt(a.metrics_window)?a.metrics_window:void 0,u=b(a.name);if(!u)return null;const d=S(a.context_ratio)??S(i==null?void 0:i.context_ratio),p=b(a.status)??b(s==null?void 0:s.status)??"offline",f=zr(p),l=b(a.model)??b(a.active_model)??b(a.primary_model),c=sn(a.skill_secondary),m=i?{source:b(i.source),context_ratio:S(i.context_ratio),context_tokens:S(i.context_tokens),context_max:S(i.context_max),message_count:S(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,$=s?{name:b(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:b(s.error),status:b(s.status),current_task:b(s.current_task)??null,last_seen:b(s.last_seen),last_seen_ago_s:S(s.last_seen_ago_s),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0,k=Cu(a.metrics_series),A={name:u,emoji:b(a.emoji),koreanName:b(a.koreanName)??b(a.korean_name),agent_name:b(a.agent_name),trace_id:b(a.trace_id),model:l,primary_model:b(a.primary_model),active_model:b(a.active_model),next_model_hint:b(a.next_model_hint)??null,status:f,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:S(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:S(a.proactive_idle_sec),proactive_cooldown_sec:S(a.proactive_cooldown_sec),last_heartbeat:b(a.last_heartbeat)??b(s==null?void 0:s.last_seen),generation:S(a.generation),turn_count:S(a.turn_count)??S(a.total_turns),keeper_age_s:S(a.keeper_age_s),last_turn_ago_s:S(a.last_turn_ago_s),last_handoff_ago_s:S(a.last_handoff_ago_s),last_compaction_ago_s:S(a.last_compaction_ago_s),last_proactive_ago_s:S(a.last_proactive_ago_s),context_ratio:d,context_tokens:S(a.context_tokens)??S(i==null?void 0:i.context_tokens),context_max:S(a.context_max)??S(i==null?void 0:i.context_max),context_source:b(a.context_source)??b(i==null?void 0:i.source),context:m,traits:sn(a.traits),interests:sn(a.interests),primaryValue:b(a.primaryValue)??b(a.primary_value),activityLevel:S(a.activityLevel)??S(a.activity_level),memory_recent_note:b(a.memory_recent_note)??null,conversation_tail_count:S(a.conversation_tail_count),k2k_count:S(a.k2k_count),handoff_count_total:S(a.handoff_count_total)??S(a.trace_history_count),compaction_count:S(a.compaction_count),last_compaction_saved_tokens:S(a.last_compaction_saved_tokens),diagnostic:oo(a.diagnostic),skill_primary:b(a.skill_primary)??null,skill_secondary:c,skill_reason:b(a.skill_reason)??null,metrics_series:k.length>0?k:void 0,metrics_window:r,agent:$};return A.diagnostic=oo(a.diagnostic)??cu(A,(e==null?void 0:e.lodge)??null),A}).filter(a=>a!==null)}function Ru(t){return lt(t)?{...t,lodge:ou(t.lodge)??void 0}:null}function Du(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function Lu(t){if(!lt(t))return null;const e=S(t.iteration);if(e==null)return null;const n=S(t.metric_before)??0,a=S(t.metric_after)??n;return{iteration:e,metric_before:n,metric_after:a,delta:S(t.delta)??a-n,changes:b(t.changes)??"",failed_attempts:b(t.failed_attempts)??"",next_suggestion:b(t.next_suggestion)??"",elapsed_ms:S(t.elapsed_ms)??0,cost_usd:S(t.cost_usd)??null}}function Pu(t){var i,r;if(!lt(t))return null;const e=b(t.loop_id);if(!e)return null;const n=S(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(Lu).filter(u=>u!==null):[],s=S(t.current_metric)??((i=a[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:b(t.profile)??"unknown",status:Du(t.status),current_iteration:S(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:S(t.max_iterations)??0,baseline_metric:n,current_metric:s,target:b(t.target)??"",stagnation_streak:S(t.stagnation_streak)??0,stagnation_limit:S(t.stagnation_limit)??0,elapsed_seconds:S(t.elapsed_seconds)??0,history:a}}async function _e(t="full"){var a,s,i;const e=Date.now(),n=$a[t];if(!(n&&e-n.time<ku)){Zs.value=!0;try{const r=await oc(t);$a[t]={data:r,time:e},ae.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(wu).filter(d=>d!==null),Ot.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(Au).filter(d=>d!==null),me.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(Tu).filter(d=>d!==null);const u=Ru(r.status);se.value=u,St.value=Nu(r.keepers,u),tn.value=r.perpetual??null,gu.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{Zs.value=!1}}}async function Et(){Tn.value=!0;try{const t=await hc(wn.value,{excludeSystem:ce.value});Ut.value=t.posts??[],ei.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Tn.value=!1}}async function qt(){var t;ti.value=!0;try{const e=zt.value||((t=se.value)==null?void 0:t.room)||"default";zt.value||(zt.value=e);const n=await Ic(e);Dr.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ti.value=!1}}async function on(){Re.value=!0;try{const t=await tu();An.value=Array.isArray(t)?t:[],Pr.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Re.value=!1}}async function Ee(){De.value=!0;try{const t=await rc(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const a of e){const s=Pu(a);s&&n.set(s.loop_id,s)}Lr.value=n,Er.value=new Date().toISOString(),Xs.value=null,Ys.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),Ys.value="error",Xs.value=t instanceof Error?t.message:String(t)}finally{De.value=!1}}let ns=null,as=null,ss=null;function Eu(){ss||(ss=setTimeout(()=>{Ee(),ss=null},350))}function Iu(){return hr.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Qs.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Qs.value=n}Fe(),ns||(ns=setTimeout(()=>{_e(),ns=null},500)),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&(as||(as=setTimeout(()=>{Et(),as=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Fe(),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&Eu()}})}let rn=null;function Ou(){rn||(rn=setInterval(()=>{Fe(),_e()},1e4))}function Mu(){rn&&(clearInterval(rn),rn=null)}function w({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function wt({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function zu(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function K({timestamp:t}){const e=zu(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function re(t){return(t??"").trim().toLowerCase()}function ct(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ra(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Jn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Qe(t){return t.last_heartbeat??Jn(t.last_turn_ago_s)??Jn(t.last_proactive_ago_s)??Jn(t.last_handoff_ago_s)??Jn(t.last_compaction_ago_s)}function qu(t){const e=t.title.trim();return e||ra(t.content)}function Fu(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Cn(t,e,n,a,s={}){var I;const i=re(t),r=e.filter(N=>re(N.assignee)===i&&(N.status==="claimed"||N.status==="in_progress")).length,u=n.filter(N=>re(N.from)===i).sort((N,L)=>ct(L.timestamp)-ct(N.timestamp))[0],d=a.filter(N=>re(N.agent)===i||re(N.author)===i).sort((N,L)=>ct(L.timestamp)-ct(N.timestamp))[0],p=(s.boardPosts??[]).filter(N=>re(N.author)===i).sort((N,L)=>ct(L.updated_at||L.created_at)-ct(N.updated_at||N.created_at))[0],f=(s.keepers??[]).filter(N=>re(N.name)===i&&Qe(N)!==null).sort((N,L)=>ct(Qe(L)??0)-ct(Qe(N)??0))[0],l=u?ct(u.timestamp):0,c=d?ct(d.timestamp):0,m=p?ct(p.updated_at||p.created_at):0,$=f?ct(Qe(f)??0):0,k=s.lastSeen?ct(s.lastSeen):0,A=((I=s.currentTask)==null?void 0:I.trim())||(r>0?`${r} claimed tasks`:null);if(l===0&&c===0&&m===0&&$===0&&k===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:A};const T=[u?{timestamp:u.timestamp,ts:l,text:ra(u.content)}:null,p?{timestamp:p.updated_at||p.created_at,ts:m,text:`Post: ${ra(qu(p))}`}:null,f?{timestamp:Qe(f),ts:$,text:Fu(f)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:c,text:ra(d.text)}:null].filter(N=>N!==null).sort((N,L)=>L.ts-N.ts)[0];return T&&T.ts>=k?{activeAssignedCount:r,lastActivityAt:T.timestamp,lastActivityText:T.text}:{activeAssignedCount:r,lastActivityAt:s.lastSeen??null,lastActivityText:A??"Presence heartbeat"}}let ju=0;const ue=_([]);function x(t,e="success",n=4e3){const a=++ju;ue.value=[...ue.value,{id:a,message:t,type:e}],setTimeout(()=>{ue.value=ue.value.filter(s=>s.id!==a)},n)}function Ku(t){ue.value=ue.value.filter(e=>e.id!==t)}function Uu(){const t=ue.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Ku(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}function Hu(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Bu(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Wu(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function ro(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function qr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Gu(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Fr(t){if(!t)return null;const e=jt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function jr({keeper:t,showRawStatus:e=!1}){if(ht(()=>{t!=null&&t.name&&Rr(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=jt.value[t.name],a=Fr(t),s=Hs.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${Hu(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${Bu((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${s?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?o` · ${qr(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?o` · next eligible ${Gu(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?o`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Kr({keeperName:t,placeholder:e}){const[n,a]=er("");ht(()=>{t&&Rr(t)},[t]);const s=at.value[t]??[],i=Bs.value[t]??!1,r=Kt.value[t],u=async()=>{const d=n.trim();if(!(!t||!d)){a("");try{await mu(t,d)}catch(p){const f=p instanceof Error?p.message:`Failed to message ${t}`;x(f,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${s.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:s.map(d=>o`
              <div class="keeper-conversation-item" key=${d.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${ro(d)}`}>${d.label}</span>
                  <span class=${`keeper-role-chip ${ro(d)}`}>${Wu(d)}</span>
                  ${d.timestamp?o`<span class="keeper-conversation-time">${qr(d.timestamp)}</span>`:null}
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
  `}function Ur({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=Fr(e),s=Ws.value[e.name]??!1,i=Gs.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message",u=(a==null?void 0:a.recoverable)??r==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{fu(e.name,t).catch(d=>{const p=d instanceof Error?d.message:`Failed to probe ${e.name}`;x(p,"error")})}}
        disabled=${s||!t.trim()}
      >
        ${s?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{_u(e.name,t).catch(d=>{const p=d instanceof Error?d.message:`Failed to recover ${e.name}`;x(p,"error")})}}
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
  `}const Di=_(null);function ya(t){Di.value=t,oa(t.name)}function lo(){Di.value=null}const we=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Ju(t){if(!t)return 0;const e=we.findIndex(n=>n.level===t);return e>=0?e:0}function Vu({keeper:t}){const e=Ju(t.autonomy_level),n=we[e]??we[0];if(!n)return null;const a=(e+1)/we.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${we.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${we.map((s,i)=>o`
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
  `}function la(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Qu({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${s.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${la(t.context_tokens)}</div>
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
  `}function Yu({keeper:t}){var f,l;const e=t.metrics_series??[];if(e.length<2){const c=(((f=t.context)==null?void 0:f.context_ratio)??0)*100,m=c>85?"#ef4444":c>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${c.toFixed(1)}%;background:${m}"></div>
        </div>
        <span class="chart-pct">${c.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,i=e.length,r=e.map((c,m)=>{const $=s+m/(i-1)*(n-2*s),k=a-s-(c.context_ratio??0)*(a-2*s);return{x:$,y:k,p:c}}),u=r.map(({x:c,y:m})=>`${c.toFixed(1)},${m.toFixed(1)}`).join(" "),d=(((l=e[e.length-1])==null?void 0:l.context_ratio)??0)*100,p=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
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
    </div>`}const is=_("");function Xu({keeper:t}){var s,i,r,u;const e=is.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${is.value}
        onInput=${d=>{is.value=d.target.value}}
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${la(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${la(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${la(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((u=t.context)==null?void 0:u.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Zu({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function td({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function ed({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function co({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function os(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function nd({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:os(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:os(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:os(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function Hr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function ad(){try{const t=await qn({actor:Hr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Ni(t.result);Fe(),await _e(),e!=null&&e.skipped_reason?x(e.skipped_reason,"warning"):x(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";x(e,"error")}}function sd({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${jr} keeper=${t} />
          <${Ur}
            actor=${Hr()}
            keeper=${t}
            onPokeLodge=${()=>{ad()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Kr}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function id(){var e,n,a;const t=Di.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&lo()}}
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
            onClick=${()=>lo()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Qu} keeper=${t} />

        ${""}
        <${Yu} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${w} title="Field Dictionary">
            <${Xu} keeper=${t} />
          <//>

          ${""}
          <${w} title="Profile">
            <${co} traits=${t.traits??[]} label="Traits" />
            <${co} traits=${t.interests??[]} label="Interests" />
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
              <${w} title="Autonomy">
                <${Vu} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${w} title="TRPG Stats">
                <${Zu} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${w} title="Equipment (${t.inventory.length})">
                <${td} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${w} title="Relationships (${Object.keys(t.relationships).length})">
                <${ed} rels=${t.relationships} />
              <//>
            `:null}

          <${w} title="Runtime Signals">
            <${nd} keeper=${t} />
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
        <${sd} keeper=${t} />
      </div>
    </div>
  `:null}const od="masc_dashboard_agent_name",We=_(null),ba=_(!1),Nn=_(""),ka=_([]),Rn=_([]),Ie=_(""),ln=_(!1);function Oe(t){We.value=t,Li()}function uo(){We.value=null,Nn.value="",ka.value=[],Rn.value=[],Ie.value=""}function rd(){const t=We.value;return t?ae.value.find(e=>e.name===t)??null:null}function Br(t){return t?Ot.value.filter(e=>e.assignee===t):[]}async function Li(){const t=We.value;if(t){ba.value=!0,Nn.value="",ka.value=[],Rn.value=[];try{const e=await Gc(80);ka.value=e.filter(s=>s.includes(t)).slice(0,20);const n=Br(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await Jc(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));Rn.value=a}catch(e){Nn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{ba.value=!1}}}async function po(){var a;const t=We.value,e=Ie.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(od))==null?void 0:a.trim())||"dashboard";ln.value=!0;try{await Ar(n,`@${t} ${e}`),Ie.value="",x(`Mention sent to ${t}`,"success"),Li()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";x(i,"error")}finally{ln.value=!1}}function ld({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${wt} status=${t.status} />
    </div>
  `}function cd({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function ud(){var s,i,r,u;const t=We.value;if(!t)return null;const e=rd(),n=Br(t),a=ka.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&uo()}}
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
            <button class="control-btn ghost" onClick=${()=>{Li()}} disabled=${ba.value}>
              ${ba.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${uo}>Close</button>
          </div>
        </div>

        ${Nn.value?o`<div class="council-error">${Nn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${w} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${ld} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${w} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((d,p)=>o`<div key=${p} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${w} title="Task History">
          ${Rn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Rn.value.map(d=>o`<${cd} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${w} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Ie.value}
              onInput=${d=>{Ie.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&po()}}
              disabled=${ln.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{po()}}
              disabled=${ln.value||Ie.value.trim()===""}
            >
              ${ln.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const rs=600*1e3,ls=1200*1e3,vo=.8;function Ct(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Bt(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function mo(t){return(t??"").trim().toLowerCase()}function Wt(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function Ae(t){return typeof t!="number"||Number.isNaN(t)?3:t}function dd(t){const e=Ae(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}function ke(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function Vn(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function fo(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function _o(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function pd(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function cs(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function vd(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function md(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function fd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function _d(t){return t?t.enabled?t.quiet_active?`Quiet hours ${fo(t.quiet_start)}-${fo(t.quiet_end)} KST are active.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${_o(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${_o(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function go(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function xe({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function gd({item:t}){return o`
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
  `}function us({tone:t,title:e,subtitle:n,meta:a,focus:s,onClick:i}){return o`
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
  `}function ho(){var N,L,st,At,Tt,it,ft,O,V,y,oe,Je,jn,Kn,Un,Hn,Bn;const t=se.value,e=ae.value,n=Ot.value,a=St.value,s=Ir.value,i=(N=t==null?void 0:t.monitoring)==null?void 0:N.board,r=(L=t==null?void 0:t.monitoring)==null?void 0:L.council,u=Ft.value,d=new Map(e.map(v=>[mo(v.name),v])),p=e.map(v=>{var zi;const C=Cn(v.name,n,me.value,te.value,{currentTask:v.current_task,lastSeen:v.last_seen,boardPosts:Ut.value,keepers:a}),q=C.lastActivityAt??v.last_seen??null,Z=q?Math.max(0,Date.now()-Ct(q)):Number.POSITIVE_INFINITY,M=C.activeAssignedCount,ot=!!((zi=v.current_task)!=null&&zi.trim()),Q=ot||M>0;let G="ok",rt="Fresh and ready",$e=!1,ye=!1;return v.status==="offline"||v.status==="inactive"?(G=Q?"bad":"warn",rt=Q?"Load without an available owner":"Offline"):Q&&Z>ls?(G="bad",rt="Execution is stale"):M>0&&!ot?(G="warn",rt="Claimed work has no current_task",ye=!0):ot&&M===0?(G="warn",rt="current_task has no claimed work",ye=!0):!Q&&Z<=rs?(G="ok",rt="Dispatchable now",$e=!0):!Q&&Z>ls?(G="warn",rt="Idle but not freshly active"):Q&&Z>rs&&(G="warn",rt="Execution is getting quiet"),{agent:v,lastSignalAt:q,activeTaskCount:M,tone:G,note:rt,focus:Wt(v.current_task)??C.lastActivityText??($e?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:$e,drift:ye}}).sort((v,C)=>{const q=Bt(C.tone)-Bt(v.tone);return q!==0?q:Ct(C.lastSignalAt)-Ct(v.lastSignalAt)}),f=a.map(v=>{var G;const C=Or.value.get(v.name)??"idle",q=Mr.value.has(v.name),Z=v.context_ratio??0,M=v.diagnostic??null;let ot="ok",Q="Healthy keeper";return q||v.status==="offline"||C==="handoff-imminent"||(M==null?void 0:M.health_state)==="offline"||(M==null?void 0:M.health_state)==="degraded"?(ot="bad",Q=Wt(M==null?void 0:M.summary,56)??(q?"Heartbeat stale":C==="handoff-imminent"?"Handoff imminent":(M==null?void 0:M.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((M==null?void 0:M.health_state)==="stale"||Z>=vo||C==="preparing"||C==="compacting")&&(ot="warn",Q=Wt(M==null?void 0:M.summary,56)??(Z>=vo?"High context pressure":`Lifecycle ${C}`)),{keeper:v,tone:ot,note:Q,focus:Wt(M==null?void 0:M.summary,120)??Wt((G=v.agent)==null?void 0:G.current_task)??v.skill_primary??v.last_proactive_reason??v.memory_recent_note??"No active focus",timestamp:v.last_heartbeat??null}}).sort((v,C)=>{const q=Bt(C.tone)-Bt(v.tone);return q!==0?q:Ct(C.timestamp)-Ct(v.timestamp)}),l=n.filter(v=>v.status==="todo"||v.status==="claimed"||v.status==="in_progress").map(v=>{var $e,ye;const C=v.assignee?d.get(mo(v.assignee))??null:null,q=C?Cn(C.name,n,me.value,te.value,{currentTask:C.current_task,lastSeen:C.last_seen,boardPosts:Ut.value,keepers:a}):null,Z=(q==null?void 0:q.lastActivityAt)??(C==null?void 0:C.last_seen)??null,M=Z?Math.max(0,Date.now()-Ct(Z)):Number.POSITIVE_INFINITY,ot=v.status==="claimed"||v.status==="in_progress";let Q="ok",G="Covered",rt=!1;return v.assignee?!C||C.status==="offline"||C.status==="inactive"?(Q="bad",G="Assigned owner is unavailable",rt=!0):ot&&M>ls?(Q="bad",G="Execution has lost a fresh signal"):ot&&M>rs?(Q="warn",G="Execution is drifting quiet"):v.status==="todo"&&Ae(v.priority)<=2&&!(($e=C.current_task)!=null&&$e.trim())&&((q==null?void 0:q.activeAssignedCount)??0)===0?(Q="ok",G="Ready for dispatch"):ot&&!((ye=C.current_task)!=null&&ye.trim())&&(Q="warn",G="Owner focus is not explicit"):(Q=Ae(v.priority)<=2?"bad":"warn",G=ot?"Active work has no owner":"Ready work has no owner",rt=!0),{task:v,owner:C,lastSignalAt:Z,tone:Q,note:G,focus:Wt(C==null?void 0:C.current_task)??(q==null?void 0:q.lastActivityText)??Wt(v.description)??"Needs operator attention.",ownerGap:rt}}).sort((v,C)=>{const q=Bt(C.tone)-Bt(v.tone);if(q!==0)return q;const Z=Ae(v.task.priority)-Ae(C.task.priority);return Z!==0?Z:Ct(C.lastSignalAt??C.task.updated_at??C.task.created_at)-Ct(v.lastSignalAt??v.task.updated_at??v.task.created_at)}),c=l.filter(v=>v.task.status==="todo"&&Ae(v.task.priority)<=2),m=l.filter(v=>v.ownerGap).length,$=p.filter(v=>v.dispatchable),k=p.filter(v=>v.drift||v.tone!=="ok"),A=f.filter(v=>v.tone!=="ok"),R=t!=null&&t.paused?"bad":((st=t==null?void 0:t.data_quality)==null?void 0:st.board_contract_ok)===!1||((At=t==null?void 0:t.data_quality)==null?void 0:At.council_feed_ok)===!1?"warn":u?"ok":"warn",T=[];t!=null&&t.paused&&T.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((Tt=t.data_quality)==null?void 0:Tt.last_sync_at)??null,action:()=>bt("ops")}),u||T.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:()=>bt("activity")}),ke(i==null?void 0:i.alert_level)!=="ok"&&T.push({key:"board-monitor",tone:ke(i==null?void 0:i.alert_level),title:"Board feed needs attention",detail:`Freshness ${cs(i==null?void 0:i.last_activity_age_s)} · ${(i==null?void 0:i.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>bt("board")}),ke(r==null?void 0:r.alert_level)!=="ok"&&T.push({key:"council-monitor",tone:ke(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${cs(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>bt("council")}),(((it=t==null?void 0:t.data_quality)==null?void 0:it.board_contract_ok)===!1||((ft=t==null?void 0:t.data_quality)==null?void 0:ft.council_feed_ok)===!1)&&T.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((O=t.data_quality)==null?void 0:O.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((V=t.data_quality)==null?void 0:V.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((y=t.data_quality)==null?void 0:y.last_sync_at)??null,action:()=>bt("ops")});const I=[...T,...l.filter(v=>v.tone!=="ok").slice(0,3).map(v=>({key:`task-${v.task.id}`,tone:v.tone,title:v.task.title,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt??v.task.updated_at??v.task.created_at??null,action:()=>bt("execution")})),...A.slice(0,2).map(v=>({key:`keeper-${v.keeper.name}`,tone:v.tone,title:v.keeper.name,detail:`${v.note} · ${v.focus}`,timestamp:v.timestamp,action:()=>ya(v.keeper)})),...k.slice(0,2).map(v=>({key:`agent-${v.agent.name}`,tone:v.tone,title:v.agent.name,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt,action:()=>Oe(v.agent.name)}))].sort((v,C)=>{const q=Bt(C.tone)-Bt(v.tone);return q!==0?q:Ct(C.timestamp)-Ct(v.timestamp)}).slice(0,8);return o`
    <div class="stats-grid">
      <${xe}
        label="Room State"
        value=${t!=null&&t.paused?"Paused":"Running"}
        color=${Vn(R)}
        caption=${(t==null?void 0:t.room)??(t==null?void 0:t.project)??"default room"}
      />
      <${xe}
        label="Urgent Queue"
        value=${c.length}
        color=${c.length>0?"#fb7185":"#4ade80"}
        caption="todo tasks at P1/P2"
      />
      <${xe}
        label="Active Work"
        value=${s.inProgress.length}
        color="#fbbf24"
        caption="claimed + in progress"
      />
      <${xe}
        label="Dispatchable"
        value=${$.length}
        color="#22d3ee"
        caption="fresh agents with no load"
      />
      <${xe}
        label="Keeper Pressure"
        value=${A.length}
        color=${A.length>0?"#fbbf24":"#4ade80"}
        caption="stale or high-context keepers"
      />
      <${xe}
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
          <div class="monitor-stat-caption">${Mn.value} events seen in this session</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Board Feed</div>
          <div class="stat-value" style=${`color:${Vn(ke(i==null?void 0:i.alert_level))}`}>${go(i==null?void 0:i.alert_level)}</div>
          <div class="monitor-stat-caption">Freshness ${cs(i==null?void 0:i.last_activity_age_s)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Council Feed</div>
          <div class="stat-value" style=${`color:${Vn(ke(r==null?void 0:r.alert_level))}`}>${go(r==null?void 0:r.alert_level)}</div>
          <div class="monitor-stat-caption">${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Runtime</div>
          <div class="stat-value" style=${`color:${Vn(R)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${pd((t==null?void 0:t.uptime_seconds)??0)}</div>
        </div>
      </div>
      <div class="overview-note-stack">
        <div class="overview-inline-note">
          ${(oe=t==null?void 0:t.data_quality)!=null&&oe.last_sync_at?o`Last sync <${K} timestamp=${t.data_quality.last_sync_at} />`:o`No sync metadata yet`}
        </div>
        <div class="overview-inline-note">
          ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
        </div>
        <div class="overview-inline-note">${_d(t==null?void 0:t.lodge)}</div>
        ${(Je=t==null?void 0:t.lodge)!=null&&Je.last_skip_reason?o`<div class="overview-inline-note">Last Lodge skip: ${t.lodge.last_skip_reason}</div>`:null}
      </div>
    <//>

    <div class="grid-2col">
      <${w} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs intervention right now</h2>
          <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
        </div>
        <div class="monitor-alert-list">
          ${I.length===0?o`<div class="empty-state">No immediate intervention required</div>`:I.map(v=>o`<${gd} key=${v.key} item=${v} />`)}
        </div>
      <//>

      <${w} title="Dispatch Window" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who can pick up work next</h2>
          <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${$.length===0?o`<div class="empty-state">No fully dispatchable agents right now</div>`:$.slice(0,5).map(v=>o`
                <${us}
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
      <${w} title="Execution Pulse" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Priority work and ownership drift</h2>
          <p class="monitor-subheadline">Urgent ready tasks and active execution issues stay visible without duplicating the full Execution surface.</p>
        </div>
        <div class="monitor-list">
          ${l.length===0?o`<div class="empty-state">No active or ready tasks</div>`:l.slice(0,6).map(v=>o`
                <${us}
                  key=${v.task.id}
                  tone=${v.tone}
                  title=${v.task.title}
                  subtitle=${`${dd(v.task.priority)} · ${v.note}`}
                  meta=${[v.task.assignee?`Owner ${v.task.assignee}`:"Unassigned",v.lastSignalAt?`Signal ${new Date(v.lastSignalAt).toLocaleTimeString()}`:"No live signal",v.task.updated_at?`Touched ${new Date(v.task.updated_at).toLocaleTimeString()}`:"No task timestamp"]}
                  focus=${v.focus}
                  onClick=${()=>bt("execution")}
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
          ${A.length===0?o`<div class="empty-state">No keeper pressure signals right now</div>`:A.slice(0,5).map(v=>{var C;return o`
                <${us}
                  key=${v.keeper.name}
                  tone=${v.tone}
                  title=${v.keeper.name}
                  subtitle=${(C=v.keeper.diagnostic)!=null&&C.health_state?`${v.note} · ${v.keeper.diagnostic.health_state}`:v.note}
                  meta=${[v.timestamp?`Heartbeat ${new Date(v.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof v.keeper.context_ratio=="number"?Math.round(v.keeper.context_ratio*100):0}%`,v.keeper.model?`Model ${v.keeper.model}`:"model n/a",v.keeper.diagnostic?`${md(v.keeper.diagnostic.quiet_reason)} · next ${fd(v.keeper.diagnostic.next_action_path)} · reply ${v.keeper.diagnostic.last_reply_status}`:"Diagnostic unavailable"]}
                  focus=${v.focus}
                  onClick=${()=>ya(v.keeper)}
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
          ${k.length===0?o`<div class="empty-state">No agent drift or stale load right now</div>`:k.slice(0,5).map(v=>o`
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
            ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${hu.value.length} · Total tasks ${n.length}
          </div>
          <div class="overview-inline-note">
            ${tn.value?`Perpetual runtime ${tn.value.running?"running":"stopped"}${tn.value.goal?` · ${Wt(tn.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
          </div>
          <div class="overview-inline-note">
            Lodge ${(jn=t==null?void 0:t.lodge)!=null&&jn.enabled?"enabled":"disabled"} · Last tick ${((Kn=t==null?void 0:t.lodge)==null?void 0:Kn.last_tick_ago)??"never"} · Self heartbeats ${((Hn=(Un=t==null?void 0:t.lodge)==null?void 0:Un.active_self_heartbeats)==null?void 0:Hn.length)??0}${(Bn=t==null?void 0:t.lodge)!=null&&Bn.last_skip_reason?` · Skip ${t.lodge.last_skip_reason}`:""}
          </div>
          <div class="overview-inline-note">
            ${a.length>0?`Hot keepers: ${A.length} · Highest context ${vd(Math.max(...a.map(v=>v.context_tokens??0)))}`:"No keepers registered"}
          </div>
        </div>
      <//>
    </div>
  `}const ge=_(null),xa=_(!1),Sa=_(null),ni=_(null),wa=_(null),Pi=_("operations");function B(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function h(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function P(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function $o(t){return typeof t=="boolean"?t:void 0}function Yt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function hd(t){if(B(t))return{policy_class:h(t.policy_class),approval_class:h(t.approval_class),tool_allowlist:Yt(t.tool_allowlist),model_allowlist:Yt(t.model_allowlist),requires_human_for:Yt(t.requires_human_for),autonomy_level:h(t.autonomy_level),escalation_timeout_sec:P(t.escalation_timeout_sec),kill_switch:$o(t.kill_switch),frozen:$o(t.frozen)}}function $d(t){if(B(t))return{headcount_cap:P(t.headcount_cap),active_operation_cap:P(t.active_operation_cap),max_cost_usd:P(t.max_cost_usd),max_tokens:P(t.max_tokens)}}function Wr(t){if(!B(t))return null;const e=h(t.unit_id),n=h(t.label),a=h(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:h(t.parent_unit_id)??null,leader_id:h(t.leader_id)??null,roster:Yt(t.roster),capability_profile:Yt(t.capability_profile),source:h(t.source),created_at:h(t.created_at),updated_at:h(t.updated_at),policy:hd(t.policy),budget:$d(t.budget)}}function Gr(t){if(!B(t))return null;const e=Wr(t.unit);return e?{unit:e,leader_status:h(t.leader_status),roster_total:P(t.roster_total),roster_live:P(t.roster_live),active_operation_count:P(t.active_operation_count),health:h(t.health),reasons:Yt(t.reasons),children:Array.isArray(t.children)?t.children.map(Gr).filter(n=>n!==null):[]}:null}function yd(t){if(B(t))return{total_units:P(t.total_units),company_count:P(t.company_count),platoon_count:P(t.platoon_count),squad_count:P(t.squad_count),leaf_agent_unit_count:P(t.leaf_agent_unit_count),live_agent_count:P(t.live_agent_count),managed_unit_count:P(t.managed_unit_count),active_operation_count:P(t.active_operation_count)}}function bd(t){const e=B(t)?t:{};return{version:h(e.version),generated_at:h(e.generated_at),source:h(e.source),summary:yd(e.summary),units:Array.isArray(e.units)?e.units.map(Gr).filter(n=>n!==null):[]}}function Jr(t){if(!B(t))return null;const e=h(t.operation_id),n=h(t.objective),a=h(t.assigned_unit_id),s=h(t.trace_id),i=h(t.status);return!e||!n||!a||!s||!i?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:h(t.autonomy_level),policy_class:h(t.policy_class),budget_class:h(t.budget_class),detachment_session_id:h(t.detachment_session_id)??null,trace_id:s,checkpoint_ref:h(t.checkpoint_ref)??null,active_goal_ids:Yt(t.active_goal_ids),note:h(t.note)??null,created_by:h(t.created_by),source:h(t.source),status:i,created_at:h(t.created_at),updated_at:h(t.updated_at)}}function kd(t){if(!B(t))return null;const e=Jr(t.operation);return e?{operation:e,assigned_unit_label:h(t.assigned_unit_label)}:null}function xd(t){const e=B(t)?t:{},n=B(e.summary)?e.summary:void 0;return{version:h(e.version),generated_at:h(e.generated_at),summary:n?{total:P(n.total),active:P(n.active),paused:P(n.paused),managed:P(n.managed),projected:P(n.projected)}:void 0,operations:Array.isArray(e.operations)?e.operations.map(kd).filter(a=>a!==null):[]}}function Sd(t){if(!B(t))return null;const e=h(t.detachment_id),n=h(t.operation_id),a=h(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:h(t.leader_id)??null,roster:Yt(t.roster),session_id:h(t.session_id)??null,checkpoint_ref:h(t.checkpoint_ref)??null,runtime_kind:h(t.runtime_kind)??null,runtime_ref:h(t.runtime_ref)??null,source:h(t.source),status:h(t.status),last_event_at:h(t.last_event_at)??null,last_progress_at:h(t.last_progress_at)??null,heartbeat_deadline:h(t.heartbeat_deadline)??null,created_at:h(t.created_at),updated_at:h(t.updated_at)}}function wd(t){if(!B(t))return null;const e=Sd(t.detachment);return e?{detachment:e,assigned_unit_label:h(t.assigned_unit_label),operation:Jr(t.operation)}:null}function Ad(t){const e=B(t)?t:{},n=B(e.summary)?e.summary:void 0;return{version:h(e.version),generated_at:h(e.generated_at),summary:n?{total:P(n.total),active:P(n.active),projected:P(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(wd).filter(a=>a!==null):[]}}function Td(t){if(!B(t))return null;const e=h(t.decision_id),n=h(t.trace_id),a=h(t.requested_action),s=h(t.scope_type),i=h(t.scope_id);return!e||!n||!a||!s||!i?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:s,scope_id:i,operation_id:h(t.operation_id)??null,target_unit_id:h(t.target_unit_id)??null,requested_by:h(t.requested_by),status:h(t.status),reason:h(t.reason)??null,source:h(t.source),detail:t.detail,created_at:h(t.created_at),decided_at:h(t.decided_at)??null,expires_at:h(t.expires_at)??null}}function Cd(t){const e=B(t)?t:{},n=B(e.summary)?e.summary:void 0;return{version:h(e.version),generated_at:h(e.generated_at),summary:n?{total:P(n.total),pending:P(n.pending),approved:P(n.approved),denied:P(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(Td).filter(a=>a!==null):[]}}function Nd(t){if(!B(t))return null;const e=Wr(t.unit);return e?{unit:e,roster_total:P(t.roster_total),roster_live:P(t.roster_live),headcount_cap:P(t.headcount_cap),active_operations:P(t.active_operations),active_operation_cap:P(t.active_operation_cap),utilization:P(t.utilization)}:null}function Rd(t){const e=B(t)?t:{};return{version:h(e.version),generated_at:h(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(Nd).filter(n=>n!==null):[]}}function Dd(t){if(!B(t))return null;const e=h(t.alert_id);return e?{alert_id:e,severity:h(t.severity),kind:h(t.kind),scope_type:h(t.scope_type),scope_id:h(t.scope_id),title:h(t.title),detail:h(t.detail),timestamp:h(t.timestamp)}:null}function Ld(t){const e=B(t)?t:{},n=B(e.summary)?e.summary:void 0;return{version:h(e.version),generated_at:h(e.generated_at),summary:n?{total:P(n.total),bad:P(n.bad),warn:P(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Dd).filter(a=>a!==null):[]}}function Pd(t){if(!B(t))return null;const e=h(t.event_id),n=h(t.trace_id),a=h(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:h(t.operation_id)??null,unit_id:h(t.unit_id)??null,actor:h(t.actor)??null,source:h(t.source),timestamp:h(t.timestamp),detail:t.detail}}function Ed(t){const e=B(t)?t:{};return{version:h(e.version),generated_at:h(e.generated_at),events:Array.isArray(e.events)?e.events.map(Pd).filter(n=>n!==null):[]}}function Id(t){const e=B(t)?t:{};return{version:h(e.version),generated_at:h(e.generated_at),topology:bd(e.topology),operations:xd(e.operations),detachments:Ad(e.detachments),alerts:Ld(e.alerts),decisions:Cd(e.decisions),capacity:Rd(e.capacity),traces:Ed(e.traces)}}function Od(t){Pi.value=t}async function Dn(){xa.value=!0,Sa.value=null;try{const t=await cc();ge.value=Id(t)}catch(t){Sa.value=t instanceof Error?t.message:"Failed to load command plane snapshot"}finally{xa.value=!1}}async function ie(t,e,n){ni.value=t,wa.value=null;try{await uc(e,n),await Dn()}catch(a){throw wa.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{ni.value=null}}function Md(t){return ie(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function zd(t){return ie(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function qd(t){return ie(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Fd(t={}){return ie("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function jd(t){return ie(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Kd(t){return ie(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Ud(t,e){return ie(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Hd(t,e){return ie(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}function Bd(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function je(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Wd(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Gd(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function ee(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}function Jd(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function tt(t){return ni.value===t}async function Xt(t){try{await t()}catch{}}function Vd(){var i;const t=ge.value,e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,a=t==null?void 0:t.decisions.summary,s=t==null?void 0:t.alerts.summary;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>Units</span><strong>${(e==null?void 0:e.total_units)??0}</strong><small>${(e==null?void 0:e.managed_unit_count)??0} managed</small></div>
      <div class="monitor-stat-card"><span>Ops</span><strong>${(n==null?void 0:n.active)??0}</strong><small>${((i=t==null?void 0:t.detachments.summary)==null?void 0:i.active)??0} detachments</small></div>
      <div class="monitor-stat-card"><span>Approvals</span><strong>${(a==null?void 0:a.pending)??0}</strong><small>${(a==null?void 0:a.total)??0} tracked</small></div>
      <div class="monitor-stat-card"><span>Alerts</span><strong>${(s==null?void 0:s.bad)??0}</strong><small>${(s==null?void 0:s.warn)??0} warn</small></div>
    </div>
  `}function Qd(){return o`
    <div class="command-surface-tabs">
      ${["operations","topology","alerts","trace","control"].map(e=>o`
        <button
          class="command-surface-tab ${Pi.value===e?"active":""}"
          onClick=${()=>Od(e)}
        >
          ${e}
        </button>
      `)}
    </div>
  `}function Vr({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,s=t.active_operation_count??0,i=t.unit.policy;return o`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${Jd(t.unit.kind)}</span>
            <span class="command-chip ${ee(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(r=>o`<${Vr} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Yd({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,s=`recall:${e.operation_id}`;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${ee(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${je(e.updated_at)}</span>
      </div>
      ${e.checkpoint_ref?o`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        ${e.source==="managed"&&e.status==="active"?o`
              <button class="control-btn ghost" disabled=${tt(n)} onClick=${()=>Xt(()=>Md(e.operation_id))}>
                ${tt(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${tt(s)} onClick=${()=>Xt(()=>qd(e.operation_id))}>
                ${tt(s)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?o`
              <button class="control-btn ghost" disabled=${tt(a)} onClick=${()=>Xt(()=>zd(e.operation_id))}>
                ${tt(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Xd({card:t}){var n;const e=t.detachment;return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${ee(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${je(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Gd(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${je(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?o`<span class="command-tag ${Wd(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Zd({alert:t}){return o`
    <article class="command-alert ${ee(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${ee(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${je(t.timestamp)}</span>
      </div>
      ${t.detail?o`<p>${t.detail}</p>`:null}
    </article>
  `}function tp({event:t}){return o`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${je(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${Bd(t.detail)}</pre>
    </article>
  `}function ep({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return o`
    <article class="command-card ${ee(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${ee(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${je(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${tt(e)} onClick=${()=>Xt(()=>jd(t.decision_id))}>
                ${tt(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${tt(n)} onClick=${()=>Xt(()=>Kd(t.decision_id))}>
                ${tt(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?o`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function np({row:t}){var u,d,p;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,s=!!((u=e.policy)!=null&&u.frozen),i=!!((d=e.policy)!=null&&d.kill_switch),r=Math.round((t.utilization??0)*100);return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${ee(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
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
        <button class="control-btn ghost" disabled=${tt(n)} onClick=${()=>Xt(()=>Ud(e.unit_id,!s))}>
          ${tt(n)?"Applying…":s?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${tt(a)} onClick=${()=>Xt(()=>Hd(e.unit_id,!i))}>
          ${tt(a)?"Applying…":i?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function ap(){const t=ge.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?o`<div class="command-card-stack">
              ${t.operations.operations.map(e=>o`<${Yd} card=${e} />`)}
            </div>`:o`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>o`<${Xd} card=${e} />`)}
            </div>`:o`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function sp(){const t=ge.value;return o`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${t&&t.topology.units.length>0?o`${t.topology.units.map(e=>o`<${Vr} node=${e} />`)}`:o`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `}function ip(){const t=ge.value;return o`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${t&&t.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>o`<${Zd} alert=${e} />`)}
          </div>`:o`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `}function op(){const t=ge.value;return o`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${t&&t.traces.events.length>0?o`<div class="command-trace-stack">
            ${t.traces.events.map(e=>o`<${tp} event=${e} />`)}
          </div>`:o`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `}function rp(){const t=ge.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${t&&t.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>o`<${ep} decision=${e} />`)}
            </div>`:o`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${t&&t.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>o`<${np} row=${e} />`)}
            </div>`:o`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `}function lp(){switch(Pi.value){case"topology":return o`<${sp} />`;case"alerts":return o`<${ip} />`;case"trace":return o`<${op} />`;case"control":return o`<${rp} />`;case"operations":default:return o`<${ap} />`}}function cp(){return ht(()=>{Dn()},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Xt(()=>Fd())}}
            disabled=${tt("dispatch:tick")}
          >
            ${tt("dispatch:tick")?"Reconciling…":"Run Tick"}
          </button>
          <button class="control-btn ghost" onClick=${()=>{Dn()}} disabled=${xa.value}>
            ${xa.value?"Refreshing…":"Refresh"}
          </button>
        </div>
      </div>

      ${Sa.value?o`<div class="empty-state error">${Sa.value}</div>`:null}
      ${wa.value?o`<div class="empty-state error">${wa.value}</div>`:null}

      <${Vd} />
      <${Qd} />
      <${lp} />
    </section>
  `}const Fn=_(null),Aa=_(!1),ne=_(null),H=_(!1),Ta=_([]);let up=1;function W(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function D(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function dt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Qr(t){return typeof t=="boolean"?t:void 0}function dp(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Te(t,e=[]){if(Array.isArray(t))return t;if(!W(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function pp(t){return W(t)?{id:D(t.id),seq:dt(t.seq),from:D(t.from)??D(t.from_agent)??"system",content:D(t.content)??"",timestamp:D(t.timestamp)??new Date().toISOString(),type:D(t.type)}:null}function vp(t){return W(t)?{room_id:D(t.room_id),current_room:D(t.current_room)??D(t.room),project:D(t.project),cluster:D(t.cluster),paused:Qr(t.paused),pause_reason:D(t.pause_reason)??null,paused_by:D(t.paused_by)??null,paused_at:D(t.paused_at)??null}:{}}function yo(t){if(!W(t))return;const e=Object.entries(t).map(([n,a])=>{const s=D(a);return s?[n,s]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function mp(t){if(!W(t))return null;const e=W(t.status)?t.status:void 0,n=W(t.summary)?t.summary:W(e==null?void 0:e.summary)?e.summary:void 0,a=W(t.session)?t.session:W(e==null?void 0:e.session)?e.session:void 0,s=D(t.session_id)??D(n==null?void 0:n.session_id)??D(a==null?void 0:a.session_id);if(!s)return null;const i=yo(t.report_paths)??yo(e==null?void 0:e.report_paths),r=Te(t.recent_events,["events"]).filter(W);return{session_id:s,status:D(t.status)??D(n==null?void 0:n.status)??D(a==null?void 0:a.status),progress_pct:dt(t.progress_pct)??dt(n==null?void 0:n.progress_pct),elapsed_sec:dt(t.elapsed_sec)??dt(n==null?void 0:n.elapsed_sec),remaining_sec:dt(t.remaining_sec)??dt(n==null?void 0:n.remaining_sec),done_delta_total:dt(t.done_delta_total)??dt(n==null?void 0:n.done_delta_total),summary:n,team_health:W(t.team_health)?t.team_health:W(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:W(t.communication_metrics)?t.communication_metrics:W(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:W(t.orchestration_state)?t.orchestration_state:W(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:W(t.cascade_metrics)?t.cascade_metrics:W(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:a,recent_events:r}}function fp(t){if(!W(t))return null;const e=D(t.name);if(!e)return null;const n=W(t.context)?t.context:void 0;return{name:e,agent_name:D(t.agent_name),status:D(t.status),autonomy_level:D(t.autonomy_level),context_ratio:dt(t.context_ratio)??dt(n==null?void 0:n.context_ratio),generation:dt(t.generation),active_goal_ids:dp(t.active_goal_ids),last_autonomous_action_at:D(t.last_autonomous_action_at)??null,last_turn_ago_s:dt(t.last_turn_ago_s),model:D(t.model)??D(t.active_model)??D(t.primary_model)}}function _p(t){if(!W(t))return null;const e=D(t.confirm_token)??D(t.token);return e?{confirm_token:e,actor:D(t.actor),action_type:D(t.action_type),target_type:D(t.target_type),target_id:D(t.target_id)??null,delegated_tool:D(t.delegated_tool),created_at:D(t.created_at),preview:t.preview}:null}function gp(t){const e=W(t)?t:{};return{room:vp(e.room),sessions:Te(e.sessions,["items","sessions"]).map(mp).filter(n=>n!==null),keepers:Te(e.keepers,["items","keepers"]).map(fp).filter(n=>n!==null),recent_messages:Te(e.recent_messages,["messages"]).map(pp).filter(n=>n!==null),pending_confirms:Te(e.pending_confirms,["items","confirms"]).map(_p).filter(n=>n!==null),available_actions:Te(e.available_actions,["actions"]).filter(W).map(n=>({action_type:D(n.action_type)??"unknown",target_type:D(n.target_type)??"unknown",description:D(n.description),confirm_required:Qr(n.confirm_required)}))}}function Qn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function bo(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Ca(t){Ta.value=[{...t,id:up++,at:new Date().toISOString()},...Ta.value].slice(0,20)}function Yr(t){return t.confirm_required?Qn(t.preview)||"Confirmation required":Qn(t.result)||Qn(t.executed_action)||Qn(t.delegated_tool_result)||t.status}async function Ke(){Aa.value=!0,ne.value=null;try{const t=await lc();Fn.value=gp(t)}catch(t){ne.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Aa.value=!1}}async function hp(t){H.value=!0,ne.value=null;try{const e=await qn(t);return Ca({actor:t.actor,action_type:t.action_type,target_label:bo(t),outcome:e.confirm_required?"preview":"executed",message:Yr(e),delegated_tool:e.delegated_tool}),await Ke(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw ne.value=n,Ca({actor:t.actor,action_type:t.action_type,target_label:bo(t),outcome:"error",message:n}),e}finally{H.value=!1}}async function $p(t,e){H.value=!0,ne.value=null;try{const n=await pc(t,e);return Ca({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Yr(n),delegated_tool:n.delegated_tool}),await Ke(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw ne.value=a,Ca({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{H.value=!1}}const Xr="masc_dashboard_agent_name";function yp(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(Xr))==null?void 0:a.trim())||"dashboard"}const Qa=_(yp()),cn=_(""),ai=_("Operator pause"),un=_(""),Na=_(""),si=_("2"),Ra=_(""),Me=_("note"),Da=_(""),La=_(""),Pa=_(""),ii=_("2"),oi=_("Operator stop request"),ri=_(""),dn=_("");function bp(t){const e=t.trim()||"dashboard";Qa.value=e,localStorage.setItem(Xr,e)}function ko(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function kp(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function Ea(t){return typeof t=="string"?t.trim().toLowerCase():""}function xp(t){var a;const e=Ea(t.status);if(e==="paused")return"bad";const n=Ea((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function xo(t){const e=Ea(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function he(t){const e=Qa.value.trim()||"dashboard";try{const n=await hp({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?x("Confirmation queued","warning"):x(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return x(a,"error"),null}}async function So(){const t=cn.value.trim();if(!t)return;await he({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(cn.value="")}async function Sp(){await he({action_type:"room_pause",target_type:"room",payload:{reason:ai.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function wp(){await he({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function Ap(){const t=un.value.trim();if(!t)return;await he({action_type:"task_inject",target_type:"room",payload:{title:t,description:Na.value.trim()||"Injected from Ops tab",priority:Number.parseInt(si.value,10)||2},successMessage:"Task injection submitted"})&&(un.value="",Na.value="")}async function Tp(){var i;const t=Fn.value,e=Ra.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){x("Select a team session first","warning");return}const n={turn_kind:Me.value},a=Da.value.trim();a&&(n.message=a),Me.value==="task"&&(n.task_title=La.value.trim()||"Operator injected task",n.task_description=Pa.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(ii.value,10)||2),await he({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(Da.value="",Me.value==="task"&&(La.value="",Pa.value=""))}async function Cp(){var n;const t=Fn.value,e=Ra.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){x("Select a team session first","warning");return}await he({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:oi.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function Np(){var s;const t=Fn.value,e=ri.value||((s=t==null?void 0:t.keepers[0])==null?void 0:s.name)||"",n=dn.value.trim();if(!e){x("Select a keeper first","warning");return}if(!n)return;await he({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(dn.value="")}async function Rp(t){const e=Qa.value.trim()||"dashboard";try{await $p(e,t),x("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";x(a,"error")}}function Dp(){var l;ht(()=>{Ke()},[]);const t=Fn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],s=(t==null?void 0:t.pending_confirms)??[],i=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===Ra.value)??n[0]??null,u=a.find(c=>c.name===ri.value)??a[0]??null,d=n.filter(c=>xp(c)!=="ok"),p=a.filter(c=>xo(c)!=="ok"),f=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:s.length,detail:s.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:s.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:d.length,detail:d.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:d.some(c=>Ea(c.status)==="paused")?"bad":d.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:p.length,detail:p.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:p.some(c=>xo(c)==="bad")?"bad":p.length>0?"warn":"ok"}];return o`
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
            value=${Qa.value}
            onInput=${c=>bp(c.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{Ke()}} disabled=${Aa.value||H.value}>
            ${Aa.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${ne.value?o`
        <section class="ops-banner error">${ne.value}</section>
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
                ${c.preview?o`<pre class="ops-code-block">${ko(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Rp(c.confirm_token)}} disabled=${H.value}>
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
              onKeyDown=${c=>{c.key==="Enter"&&So()}}
              disabled=${H.value}
            />
            <button class="control-btn" onClick=${()=>{So()}} disabled=${H.value||cn.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${ai.value}
              onInput=${c=>{ai.value=c.target.value}}
              disabled=${H.value}
            />
            <button class="control-btn ghost" onClick=${()=>{Sp()}} disabled=${H.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{wp()}} disabled=${H.value}>
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
            value=${Na.value}
            onInput=${c=>{Na.value=c.target.value}}
            disabled=${H.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${si.value}
              onChange=${c=>{si.value=c.target.value}}
              disabled=${H.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{Ap()}} disabled=${H.value||un.value.trim()===""}>
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
                onClick=${()=>{Ra.value=c.session_id}}
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
                <pre class="ops-code-block compact">${ko(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Me.value}
              onChange=${c=>{Me.value=c.target.value}}
              disabled=${H.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{Tp()}} disabled=${H.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${Da.value}
            onInput=${c=>{Da.value=c.target.value}}
            disabled=${H.value||!r}
          ></textarea>
          ${Me.value==="task"?o`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${La.value}
              onInput=${c=>{La.value=c.target.value}}
              disabled=${H.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${Pa.value}
              onInput=${c=>{Pa.value=c.target.value}}
              disabled=${H.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${ii.value}
              onChange=${c=>{ii.value=c.target.value}}
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
              value=${oi.value}
              onInput=${c=>{oi.value=c.target.value}}
              disabled=${H.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{Cp()}} disabled=${H.value||!r}>
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
                onClick=${()=>{ri.value=c.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.name}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${c.model??"model n/a"}</span>
                  <span>${typeof c.context_ratio=="number"?`${Math.round(c.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${kp(c.last_turn_ago_s)}</span>
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
            <button class="control-btn" onClick=${()=>{Np()}} disabled=${H.value||!u||dn.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${Ta.value.length===0?o`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:Ta.value.map(c=>o`
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
  `}const li=_([]),ci=_([]),pn=_(""),Ia=_(!1),vn=_(!1),Ln=_(""),Oa=_(null),yt=_(null),ui=_(!1);async function di(){Ia.value=!0,Ln.value="";try{const[t,e]=await Promise.all([Vc(),Qc()]);li.value=t,ci.value=e}catch(t){Ln.value=t instanceof Error?t.message:"Failed to load council data"}finally{Ia.value=!1}}async function wo(){const t=pn.value.trim();if(t){vn.value=!0;try{const e=await Yc(t);pn.value="",x(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await di()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";x(n,"error")}finally{vn.value=!1}}}async function Lp(t){Oa.value=t,ui.value=!0,yt.value=null;try{yt.value=await Xc(t)}catch(e){Ln.value=e instanceof Error?e.message:"Failed to load debate status",yt.value=null}finally{ui.value=!1}}function Pp({debate:t}){const e=Oa.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Lp(t.id)}
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
  `}function Ep({session:t}){return o`
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
  `}function Ip(){var e;const t=(e=se.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${K} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Op(){var e,n;ht(()=>{di()},[]);const t=((n=(e=se.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${Ip} />
      <${w} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${pn.value}
            onInput=${a=>{pn.value=a.target.value}}
            onKeyDown=${a=>{a.key==="Enter"&&wo()}}
            disabled=${vn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${wo}
            disabled=${vn.value||pn.value.trim()===""}
          >
            ${vn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${di} disabled=${Ia.value}>
            ${Ia.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Ln.value?o`<div class="council-error">${Ln.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${w} title="Debates" class="section">
          <div class="council-list">
            ${li.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:li.value.map(a=>o`<${Pp} key=${a.id} debate=${a} />`)}
          </div>
        <//>

        <${w} title="Voting Sessions" class="section">
          <div class="council-list">
            ${ci.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:ci.value.map(a=>o`<${Ep} key=${a.id} session=${a} />`)}
          </div>
        <//>
      </div>

      <${w} title=${Oa.value?`Debate Detail (${Oa.value})`:"Debate Detail"} class="section">
        ${ui.value?o`<div class="loading-indicator">Loading debate detail...</div>`:yt.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${yt.value.status}</span>
                  <span>Total arguments: ${yt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${yt.value.support_count}</span>
                  <span>Oppose: ${yt.value.oppose_count}</span>
                  <span>Neutral: ${yt.value.neutral_count}</span>
                </div>
                ${yt.value.summary_text?o`<pre class="council-detail">${yt.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Mp({text:t}){if(!t)return null;const e=zp(t);return o`<div class="markdown-content">${e}</div>`}function zp(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],u=s.slice(r.length).trim(),d=[];for(a++;a<e.length&&!e[a].startsWith(r);)d.push(e[a]),a++;a++,n.push(o`<pre><code class=${u?`language-${u}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],u=s.trim().replace(/^<think>/,"").trim();for(u&&u!=="</think>"&&r.push(u),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const p=e[a].replace("</think>","").trim();p&&r.push(p),a++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${ds(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${ds(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${ds(i.join(`
`))}</p>`)}return n}function ds(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const Zr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],ca=_(null),mn=_([]),pe=_(!1),de=_(null),fn=_("");function qp(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Fp=_(qp()),_n=_(!1);async function Ei(t){de.value=t,ca.value=null,mn.value=[],pe.value=!0;try{const e=await $c(t);if(de.value!==t)return;ca.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},mn.value=e.comments??[]}catch{de.value===t&&(ca.value=null,mn.value=[])}finally{de.value===t&&(pe.value=!1)}}async function Ao(t){const e=fn.value.trim();if(e){_n.value=!0;try{await yc(t,Fp.value,e),fn.value="",x("Comment posted","success"),await Ei(t),Et()}catch{x("Failed to post comment","error")}finally{_n.value=!1}}}function jp(){const t=wn.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Zr.map(e=>o`
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
  `}function ps(){var e;const t=(e=se.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${K} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function tl({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Kp(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function To(t){return t.updated_at!==t.created_at}function vs(){var n;const t=((n=Zr.find(a=>a.id===wn.value))==null?void 0:n.label)??wn.value,e=Ut.value.length;return o`
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
        <strong>${ei.value?o`<${K} timestamp=${ei.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Up({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await wr(t.id,n),Et()}catch{x("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>jl(t.id)}>
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
              <${tl} flair=${t.flair} />
              ${To(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${K} timestamp=${t.created_at} /></span>
            ${To(t)?o`<span>Updated <${K} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${Kp(t.content)}</div>
      </div>
    </div>
  `}function Hp({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${K} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Bp({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${fn.value}
        onInput=${e=>{fn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Ao(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${_n.value}
      />
      <button
        onClick=${()=>Ao(t)}
        disabled=${_n.value||fn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${_n.value?"...":"Post"}
      </button>
    </div>
  `}function Wp({post:t}){de.value!==t.id&&!pe.value&&Ei(t.id);const e=async n=>{try{await wr(t.id,n),Et()}catch{x("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>bt("board")}>← Back to Board</button>
      <${w} title=${o`${t.title} <${tl} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Mp} text=${t.content} />
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

      <${w} title="Comments (${pe.value?"...":mn.value.length})">
        ${pe.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Hp} comments=${mn.value} />`}
        <${Bp} postId=${t.id} />
      <//>
    </div>
  `}function Gp(){var s,i;const t=Ut.value,e=Tn.value,n=Pt.value.postId,a=((i=(s=se.value)==null?void 0:s.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(u=>u.id===n)??(de.value===n?ca.value:null);return!r&&de.value!==n&&!pe.value&&Ei(n),r?o`
          <${ps} />
          <${vs} />
          <${Wp} post=${r} />
        `:o`
          <div>
            <${ps} />
            <${vs} />
            <button class="back-btn" onClick=${()=>bt("board")}>← Back to Board</button>
            ${pe.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${a?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${ps} />
    <${vs} />
    <${jp} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${a?"No posts loaded (board feed degraded). Check board contract sync.":ce.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${Up} key=${r.id} post=${r} />`)}
          </div>`}
  `}function Jp(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Vp(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Qp(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const el=120,Yp=12,Xp=16,Zp=12,pi=_("all"),tv={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},ev={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function nv(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function av(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:Jp(t),actor:Vp(t),content:Qp(t),timestamp:new Date(t.timestamp).toISOString()}}function sv(t,e){var s;const n=(s=t.assignee)==null?void 0:s.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function iv(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Yn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function vi(t){return t.last_heartbeat??Yn(t.last_turn_ago_s)??Yn(t.last_proactive_ago_s)??Yn(t.last_handoff_ago_s)??Yn(t.last_compaction_ago_s)}function ov(t,e){const n=vi(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function Nt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const mi=vt(()=>{const t=me.value.map(nv),e=te.value.map(av),n=[...Ot.value].sort((i,r)=>Nt(r.updated_at??r.created_at??0)-Nt(i.updated_at??i.created_at??0)).slice(0,Yp).map(sv).filter(i=>i!==null),a=[...Ut.value].sort((i,r)=>Nt(r.updated_at||r.created_at)-Nt(i.updated_at||i.created_at)).slice(0,Xp).map(iv),s=[...St.value].sort((i,r)=>Nt(vi(r)??0)-Nt(vi(i)??0)).slice(0,Zp).map(ov).filter(i=>i!==null);return[...t,...e,...n,...a,...s].sort((i,r)=>Nt(r.timestamp)-Nt(i.timestamp))}),rv=vt(()=>{const t=mi.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),lv=vt(()=>{const t=pi.value;return(t==="all"?mi.value:mi.value.filter(n=>n.kind===t)).slice(0,el)}),cv=vt(()=>ae.value.map(t=>({agent:t,motion:Cn(t.name,Ot.value,me.value,te.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ut.value,keepers:St.value})})).sort((t,e)=>{const n=e.motion.activeAssignedCount-t.motion.activeAssignedCount;return n!==0?n:Nt(e.motion.lastActivityAt??0)-Nt(t.motion.lastActivityAt??0)}));function uv(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function Ye({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function dv({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${uv(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${ev[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function pv(){const t=rv.value,e=lv.value,n=e[0],a=cv.value;return o`
    <div class="stats-grid">
      <${Ye} label="Visible rows" value=${e.length} />
      <${Ye} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${Ye} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${Ye} label="Board signals" value=${t.board} color="#fbbf24" />
      <${Ye} label="SSE events" value=${Mn.value} color="#c084fc" />
    </div>

    <${w} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(s=>o`
            <button
              class="goal-filter-btn ${pi.value===s?"active":""}"
              onClick=${()=>{pi.value=s}}
            >
              ${tv[s]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${Ft.value?"":"pill-stale"}">
            ${Ft.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${K} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${el} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?o`<div class="empty-state">Waiting for live or snapshot signals...</div>`:e.map(s=>o`<${dv} key=${s.id} row=${s} />`)}
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
                    ${i.lastActivityAt?o` · <${K} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function nl({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,i=2*Math.PI*a,r=i*((100-t*100)/100);let u="mitosis-safe";return t>=.8?u="mitosis-critical":t>=.5&&(u="mitosis-warn"),o`
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
  `}const ms=600*1e3,vv=1200*1e3,Co=.8;function Jt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Se(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function mv(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function fv(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function _v(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function gv(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function hv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function $v(t){var d,p;const e=Cn(t.name,Ot.value,me.value,te.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ut.value,keepers:St.value}),n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-Jt(n)):Number.POSITIVE_INFINITY,s=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let i="watching",r="ok",u="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",u=n?"Offline or inactive":"No recent presence"):a>vv?(i="quiet",r="bad",u=s?"Working without a fresh signal":"No fresh agent signal"):s?(i="working",r=a>ms?"warn":"ok",u=a>ms?"Execution looks quiet for too long":"Task and live signal aligned"):a>ms?(i="quiet",r="warn",u="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",u="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((p=t.current_task)==null?void 0:p.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:u}}function yv(t){const e=Or.value.get(t.name)??"idle",n=Mr.value.has(t.name),a=t.context_ratio??0;let s="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(s="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=Co)&&(s="warning",i="warn",r=a>=Co?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:s,tone:i,focus:gv(t),note:r}}function Xe({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function bv({item:t}){const e=t.kind==="agent"?()=>Oe(t.agent.name):()=>ya(t.keeper);return o`
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
  `}function kv({row:t}){const{agent:e,motion:n}=t;return o`
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
        <${nl} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${wt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${mv(t.state)}</span>
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
  `}function xv({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>ya(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${nl} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${wt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${fv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${K} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${hv(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${_v(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function Sv(){const t=[...ae.value].map($v).sort((d,p)=>{const f=Se(p.tone)-Se(d.tone);if(f!==0)return f;const l=p.activeTaskCount-d.activeTaskCount;return l!==0?l:Jt(p.lastSignalAt)-Jt(d.lastSignalAt)}),e=[...St.value].map(yv).sort((d,p)=>{const f=Se(p.tone)-Se(d.tone);if(f!==0)return f;const l=(p.keeper.context_ratio??0)-(d.keeper.context_ratio??0);return l!==0?l:Jt(p.keeper.last_heartbeat)-Jt(d.keeper.last_heartbeat)}),n=t.filter(d=>d.state!=="offline").length,a=t.filter(d=>d.state==="working").length,s=t.filter(d=>d.lastSignalAt&&Date.now()-Jt(d.lastSignalAt)<=12e4).length,i=t.filter(d=>d.tone!=="ok"),r=e.filter(d=>d.tone!=="ok"),u=[...r.map(d=>({kind:"keeper",key:`keeper-${d.keeper.name}`,tone:d.tone,title:d.keeper.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.keeper.last_heartbeat??null,keeper:d.keeper})),...i.map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agent:d.agent}))].sort((d,p)=>{const f=Se(p.tone)-Se(d.tone);return f!==0?f:Jt(p.timestamp)-Jt(d.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Xe} label="Agents online" value=${n} color="#4ade80" caption="active + idle" />
        <${Xe} label="Working now" value=${a} color="#fbbf24" caption="task or claimed load" />
        <${Xe} label="Fresh signals" value=${s} color="#22d3ee" caption="within last 2 minutes" />
        <${Xe} label="Agent alerts" value=${i.length} color=${i.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${Xe} label="Keeper alerts" value=${r.length} color=${r.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${w} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${u.length===0?o`<div class="empty-state">No agent or keeper alerts right now</div>`:u.map(d=>o`<${bv} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${w} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(d=>o`<${xv} key=${d.keeper.name} row=${d} />`)}
          </div>
        <//>

        <${w} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Current task, recent signal, and quiet drift are surfaced together.</p>
          </div>
          <div class="monitor-list">
            ${t.length===0?o`<div class="empty-state">No agents registered</div>`:t.map(d=>o`<${kv} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>
    </div>
  `}function fs({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${K} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function wv(){const{todo:t,inProgress:e,done:n}=Ir.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>o`<${fs} key=${a.id} task=${a} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>o`<${fs} key=${a.id} task=${a} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>o`<${fs} key=${a.id} task=${a} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}const Ma=600*1e3,ua=1200*1e3;function Ya(t){return(t??"").trim().toLowerCase()}function Rt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ve(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function Gt(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Pn(t){return typeof t!="number"||Number.isNaN(t)?3:t}function al(t){const e=Pn(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}function sl(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function il(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function Av(t){return t.updated_at??t.created_at??null}function Tv(t){const e=new Map;for(const n of t)e.set(Ya(n.name),Cn(n.name,Ot.value,me.value,te.value,{currentTask:n.current_task,lastSeen:n.last_seen,boardPosts:Ut.value,keepers:St.value}));return e}function No(t,e,n){var A,R;const a=Ya(t.assignee),s=a?e.get(a)??null:null,i=s?n.get(a)??null:null,r=(i==null?void 0:i.lastActivityAt)??(s==null?void 0:s.last_seen)??null,u=r?Math.max(0,Date.now()-Rt(r)):Number.POSITIVE_INFINITY,d=ve(t.description),p=ve(s==null?void 0:s.current_task)??(i==null?void 0:i.lastActivityText)??null,f=t.status==="claimed"||t.status==="in_progress";let l="ok",c="Fresh owner coverage",m=p??d??t.id,$=!1,k=!1;return t.status==="todo"?t.assignee?s?s.status==="offline"||s.status==="inactive"?($=!0,l="bad",c="Assigned owner is offline",m="Queue item is blocked until ownership changes."):u>Ma?(l="warn",c="Owner exists but live signal is quiet",m=p??"Owner may need a nudge before pickup."):((i==null?void 0:i.activeAssignedCount)??0)>0||(A=s.current_task)!=null&&A.trim()?(l="warn",c="Owner is already carrying active work",m=p??`${(i==null?void 0:i.activeAssignedCount)??0} active tasks already assigned.`):(c="Ready and covered by a fresh operator",m=p??d??"This can be picked up immediately."):($=!0,l="bad",c="Assigned owner is not present in the room",m="Reassign or bring the owner back online."):($=!0,l=Pn(t.priority)<=2?"bad":"warn",c=Pn(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",m="Assign an agent before this queue item slips."):f&&(t.assignee?s?s.status==="offline"||s.status==="inactive"?($=!0,l="bad",c="Assigned owner is offline",m=p??"Execution has no live operator right now."):u>ua?(k=!0,l="bad",c="Assigned owner has gone quiet",m=p??"Fresh operator signal is missing."):u>Ma?(k=!0,l="warn",c="Execution has been quiet for too long",m=p??"Check whether this work is blocked."):(R=s.current_task)!=null&&R.trim()?(c="Execution has fresh owner coverage",m=p??d??t.id):(l="warn",c=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",m=p??"Task state and agent focus are drifting apart."):($=!0,l="bad",c="Assigned owner is not active in the room",m="Execution is orphaned until ownership is restored."):($=!0,l="bad",c="Active work has no assignee",m="Claim or reassign this task immediately.")),{task:t,assigneeAgent:s,motion:i,tone:l,note:c,focus:m,lastSignalAt:r,lastTouchedAt:Av(t),ownerGap:$,quiet:k}}function Cv(t,e){var c;const n=e.get(Ya(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,s=a?Math.max(0,Date.now()-Rt(a)):Number.POSITIVE_INFINITY,i=!!((c=t.current_task)!=null&&c.trim()),r=n.activeAssignedCount,u=i||r>0;let d="loaded",p="ok",f="Healthy active load",l=ve(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(d="offline",p="bad",f="Agent is unavailable"):u&&s>ua?(d="quiet",p="bad",f="Working without a fresh signal"):r>0&&!i?(d="drift",p="warn",f="Claimed work exists but current_task is empty",l=`${r} active tasks need explicit focus.`):i&&r===0?(d="drift",p="warn",f="current_task has no matching claimed work",l=ve(t.current_task)??"Task metadata and operator state drifted."):!u&&s<=Ma?(d="dispatchable",p="ok",f="Fresh signal and no active load",l=n.lastActivityText??"Ready for assignment."):u?s>Ma&&(d="loaded",p="warn",f="Execution load is healthy but slightly quiet",l=ve(t.current_task)??`${r} active tasks in flight.`):(d="quiet",p=s>ua?"bad":"warn",f=s>ua?"No fresh signal while idle":"Reachable, but not freshly active",l=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:p,state:d,note:f,focus:l,lastSignalAt:a,activeTaskCount:r}}function Ze({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Nv({item:t}){return o`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?al(t.taskRow.task.priority):il(t.agentRow.state)}
        </span>
        ${t.kind==="task"?o`<span>${sl(t.taskRow.task.status)}</span>`:o`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?o`<span><${K} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </div>
  `}function Ro({row:t}){var e;return o`
    <div class="execution-task-row ${t.tone}">
      <div class="monitor-row-header">
        <span class="monitor-pill ${t.tone}">${al(t.task.priority)}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.task.title}</span>
            <span class="monitor-sub">${t.task.id}</span>
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        ${t.assigneeAgent?o`<${wt} status=${t.assigneeAgent.status} />`:o`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${sl(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?o`<span>Owner ${t.task.assignee}</span>`:o`<span>Unassigned</span>`}
        ${t.lastTouchedAt?o`<span>Touched <${K} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?o`<span>Signal <${K} timestamp=${t.lastSignalAt} /></span>`:o`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&ve(t.assigneeAgent.current_task)!==t.focus?o`<div class="monitor-footnote">Owner focus: ${ve(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function Rv({row:t}){const{agent:e}=t;return o`
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
        <span class="monitor-pill ${t.tone}">${il(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${K} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
  `}function Dv(){const t=ae.value,e=Ot.value,n=new Map(t.map(l=>[Ya(l.name),l])),a=Tv(t),s=e.filter(l=>l.status==="claimed"||l.status==="in_progress").map(l=>No(l,n,a)).sort((l,c)=>{const m=Gt(c.tone)-Gt(l.tone);return m!==0?m:Rt(c.lastSignalAt??c.lastTouchedAt)-Rt(l.lastSignalAt??l.lastTouchedAt)}),i=e.filter(l=>l.status==="todo").map(l=>No(l,n,a)).sort((l,c)=>{const m=Gt(c.tone)-Gt(l.tone);if(m!==0)return m;const $=Pn(l.task.priority)-Pn(c.task.priority);return $!==0?$:Rt(l.lastTouchedAt)-Rt(c.lastTouchedAt)}),r=t.map(l=>Cv(l,a)).filter(l=>l.state==="dispatchable"||l.state==="drift"||l.state==="quiet").sort((l,c)=>{if(l.state==="dispatchable"&&c.state!=="dispatchable")return-1;if(c.state==="dispatchable"&&l.state!=="dispatchable")return 1;const m=Gt(c.tone)-Gt(l.tone);return m!==0?m:Rt(c.lastSignalAt)-Rt(l.lastSignalAt)}),u=[...s.filter(l=>l.tone!=="ok").map(l=>({kind:"task",key:`active-${l.task.id}`,tone:l.tone,title:l.task.title,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastSignalAt??l.lastTouchedAt,taskRow:l})),...i.filter(l=>l.tone==="bad").map(l=>({kind:"task",key:`ready-${l.task.id}`,tone:l.tone,title:l.task.title,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastTouchedAt,taskRow:l})),...r.filter(l=>l.state==="drift"||l.tone==="bad").map(l=>({kind:"agent",key:`agent-${l.agent.name}`,tone:l.tone,title:l.agent.name,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastSignalAt,agentRow:l}))].sort((l,c)=>{const m=Gt(c.tone)-Gt(l.tone);return m!==0?m:Rt(c.timestamp)-Rt(l.timestamp)}).slice(0,8),d=r.filter(l=>l.state==="dispatchable"),p=[...s,...i].filter(l=>l.ownerGap),f=s.filter(l=>l.quiet);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Ze} label="Active work" value=${s.length} color="#fbbf24" caption="claimed + in progress" />
        <${Ze} label="Needs intervention" value=${u.length} color=${u.length>0?"#fb7185":"#4ade80"} caption="stalled or drifting now" />
        <${Ze} label="Ownership gaps" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="missing or unavailable owners" />
        <${Ze} label="Dispatchable agents" value=${d.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${Ze} label="Quiet execution" value=${f.length} color=${f.length>0?"#fbbf24":"#4ade80"} caption="active tasks with aging signals" />
      </div>

      <${w} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${u.length===0?o`<div class="empty-state">No active execution risks right now</div>`:u.map(l=>o`<${Nv} key=${l.key} item=${l} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${w} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${i.length===0?o`<div class="empty-state">No ready tasks in the queue</div>`:i.slice(0,10).map(l=>o`<${Ro} key=${l.task.id} row=${l} />`)}
          </div>
        <//>

        <${w} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?o`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(l=>o`<${Rv} key=${l.agent.name} row=${l} />`)}
          </div>
        <//>
      </div>

      <${w} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${s.length===0?o`<div class="empty-state">No active execution tasks</div>`:s.map(l=>o`<${Ro} key=${l.task.id} row=${l} />`)}
        </div>
      <//>
    </div>
  `}const za=_("all"),qa=_("all"),fi=vt(()=>{let t=An.value;return za.value!=="all"&&(t=t.filter(e=>e.horizon===za.value)),qa.value!=="all"&&(t=t.filter(e=>e.status===qa.value)),t}),Lv=vt(()=>{const t={short:[],mid:[],long:[]};for(const e of fi.value){const n=t[e.horizon];n&&n.push(e)}return t}),Pv=vt(()=>{const t=Array.from(Lr.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Ev(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Ii(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function da(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Iv(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Do(t){return t.toFixed(4)}function Lo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Ov({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${da(t.horizon)}">
            ${Ii(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Ev(t.priority)}</span>
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
  `}function Po({label:t,timestamp:e,source:n,note:a}){return o`
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
  `}function _s({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return o`
    <${w} title="${Ii(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>o`<${Ov} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function Mv(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${za.value===t?"active":""}"
            onClick=${()=>{za.value=t}}
          >
            ${t==="all"?"All":Ii(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${qa.value===t?"active":""}"
            onClick=${()=>{qa.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function zv(){const t=An.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${da("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${da("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${da("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function qv({loop:t}){const e=t.history[0];return o`
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
          <span>Baseline ${Do(t.baseline_metric)}</span>
          <span>Current ${Do(t.current_metric)}</span>
          <span class=${Lo(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Lo(t)}
          </span>
          <span>Elapsed ${Iv(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${e?o`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function Fv(){ht(()=>{on(),Ee()},[]);const t=Lv.value,e=Pv.value,n=e.filter(r=>r.status==="running").length,a=An.value.filter(r=>r.status==="active").length,s=Ys.value,i=s==="idle"?"No loop running":s==="error"?Xs.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${a}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${fi.value.length}</div>
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

      <${w} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>/api/v1/mdal/loops</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${on} disabled=${Re.value}>
              ${Re.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${Ee} disabled=${De.value}>
              ${De.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{on(),Ee()}}
              disabled=${Re.value||De.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Po} label="Goals" timestamp=${Pr.value} source="masc_goal_list" />
          <${Po}
            label="MDAL loops"
            timestamp=${Er.value}
            source="/api/v1/mdal/loops"
            note=${i}
          />
        </div>
      <//>

      <${w} title="Goal Pipeline" class="section">
        <${zv} />
        <${Mv} />
      <//>

      ${Re.value&&An.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:fi.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${_s} horizon="short" items=${t.short??[]} />
              <${_s} horizon="mid" items=${t.mid??[]} />
              <${_s} horizon="long" items=${t.long??[]} />
            `}

      <${w} title="MDAL Loops" class="section">
        ${De.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&s==="error"?o`
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
                  ${e.map(r=>o`<${qv} key=${r.loop_id} loop=${r} />`)}
                </div>
              `}
      <//>
    </div>
  `}const Ce=_(""),gs=_("ability_check"),hs=_("10"),$s=_("12"),Xn=_(""),Zn=_("idle"),Vt=_(""),ta=_("keeper-late"),ys=_("player"),bs=_(""),gt=_("idle"),ks=_(null),ea=_(""),xs=_(""),Ss=_("player"),ws=_(""),As=_(""),Ts=_(""),gn=_("20"),Cs=_("20"),Ns=_(""),na=_("idle"),_i=_(null),ol=_("overview"),Rs=_("all"),Ds=_("all"),Ls=_("all"),jv=12e4,Xa=_(null),Eo=_(Date.now());function Kv(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Uv(t,e){return e>0?Math.round(t/e*100):0}const Hv={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Bv={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function aa(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Wv(t){const e=t.trim().toLowerCase();return Hv[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Gv(t){const e=t.trim().toLowerCase();return Bv[e]??"상황에 따라 선택되는 전술 액션입니다."}function Zt(t){return typeof t=="object"&&t!==null}function ut(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function Dt(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function En(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const Jv=new Set(["str","dex","con","int","wis","cha"]);function Vv(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!Zt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,i])=>{const r=s.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){a[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const u=Number.parseFloat(i.trim());if(Number.isFinite(u)){a[r]=Math.max(0,Math.trunc(u));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function Qv(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(gn.value.trim(),10);Number.isFinite(a)&&a>n&&(gn.value=String(n))}function gi(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Yv(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Xv(t){ol.value=t}function rl(t){const e=Xa.value;return e==null||e<=t}function Zv(t){const e=Xa.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Fa(){Xa.value=null}function ll(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function tm(t,e){ll(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Xa.value=Date.now()+jv,x("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function pa(t){return rl(t)?(x("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function hi(t,e,n){return ll([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function em({hp:t,max:e}){const n=Uv(t,e),a=Kv(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function nm({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function am({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function cl({actor:t}){var d,p,f,l;const e=(d=t.archetype)==null?void 0:d.trim(),n=(p=t.persona)==null?void 0:p.trim(),a=(f=t.portrait)==null?void 0:f.trim(),s=(l=t.background)==null?void 0:l.trim(),i=t.traits??[],r=t.skills??[],u=Object.entries(t.stats_raw??{}).filter(([c,m])=>Number.isFinite(m)).filter(([c])=>!Jv.has(c.toLowerCase()));return o`
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
        <${am} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${em} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${nm} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${aa(e)}</div>`:null}
      ${s?o`<div class="trpg-actor-meta">Background: ${s}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${u.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${u.map(([c,m])=>o`
                <span class="trpg-custom-stat-chip">${aa(c)} ${m}</span>
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
                  <span class="trpg-annot-name">${aa(c)}</span>
                  <span class="trpg-annot-desc">${Wv(c)}</span>
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
                  <span class="trpg-annot-name">${aa(c)}</span>
                  <span class="trpg-annot-desc">${Gv(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function sm({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function ul({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return o`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Yv(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${gi(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${K} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function im({events:t}){const e="__none__",n=Rs.value,a=Ds.value,s=Ls.value,i=Array.from(new Set(t.map(gi).map(l=>l.trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),r=Array.from(new Set(t.map(l=>(l.type??"").trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),u=t.some(l=>(l.type??"").trim()===""),d=Array.from(new Set(t.map(l=>(l.phase??"").trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),p=t.some(l=>(l.phase??"").trim()===""),f=t.filter(l=>{if(n!=="all"&&gi(l)!==n)return!1;const c=(l.type??"").trim(),m=(l.phase??"").trim();if(a===e){if(c!=="")return!1}else if(a!=="all"&&c!==a)return!1;if(s===e){if(m!=="")return!1}else if(s!=="all"&&m!==s)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${l=>{Rs.value=l.target.value}}>
          <option value="all">all</option>
          ${i.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${l=>{Ds.value=l.target.value}}>
          <option value="all">all</option>
          ${u?o`<option value=${e}>(none)</option>`:null}
          ${r.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${l=>{Ls.value=l.target.value}}>
          <option value="all">all</option>
          ${p?o`<option value=${e}>(none)</option>`:null}
          ${d.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Rs.value="all",Ds.value="all",Ls.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${f.length} / 전체 ${t.length}
      </span>
    </div>
    <${ul} events=${f.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function om({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function dl({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function rm({state:t,nowMs:e}){var p;const n=zt.value||((p=t.session)==null?void 0:p.room)||"",a=Zn.value,s=t.party??[];if(!s.find(f=>f.id===Ce.value)&&s.length>0){const f=s[0];f&&(Ce.value=f.id)}const r=async()=>{var l,c;if(!n){x("Room ID가 비어 있습니다.","error");return}if(!pa(e))return;const f=((l=t.current_round)==null?void 0:l.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(hi("라운드 실행",n,f)){Zn.value="running";try{const m=await Oc(n);_i.value=m,Zn.value="ok";const $=Zt(m.summary)?m.summary:null,k=$?En($,"advanced",!1):!1,A=$?ut($,"progress_reason",""):"";x(k?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${A?`: ${A}`:""}`,k?"success":"warning"),qt()}catch(m){_i.value=null,Zn.value="error";const $=m instanceof Error?m.message:"라운드 실행에 실패했습니다.";x($,"error")}finally{Fa()}}},u=async()=>{var l,c;if(!n||!pa(e))return;const f=((l=t.current_round)==null?void 0:l.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(hi("턴 강제 진행",n,f))try{await qc(n),x("턴을 다음 단계로 이동했습니다.","success"),qt()}catch{x("턴 이동에 실패했습니다.","error")}finally{Fa()}},d=async()=>{if(!n||!pa(e))return;const f=Ce.value.trim();if(!f){x("먼저 Actor를 선택하세요.","warning");return}const l=Number.parseInt(hs.value,10),c=Number.parseInt($s.value,10);if(Number.isNaN(l)||Number.isNaN(c)){x("stat/dc는 숫자여야 합니다.","warning");return}const m=Number.parseInt(Xn.value,10),$=Xn.value.trim()===""||Number.isNaN(m)?void 0:m;try{await zc({roomId:n,actorId:f,action:gs.value.trim()||"ability_check",statValue:l,dc:c,rawD20:$}),x("주사위 판정을 기록했습니다.","success"),qt()}catch{x("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${f=>{zt.value=f.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Ce.value}
            onChange=${f=>{Ce.value=f.target.value}}
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
              value=${gs.value}
              onInput=${f=>{gs.value=f.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${hs.value}
              onInput=${f=>{hs.value=f.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${$s.value}
              onInput=${f=>{$s.value=f.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Xn.value}
              onInput=${f=>{Xn.value=f.target.value}}
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
  `}function lm({state:t}){var s;const e=zt.value||((s=t.session)==null?void 0:s.room)||"",n=na.value,a=async()=>{if(!e){x("Room ID가 비어 있습니다.","warning");return}const i=ea.value.trim(),r=xs.value.trim();if(!r&&!i){x("이름 또는 Actor ID를 입력하세요.","warning");return}const u=Number.parseInt(gn.value.trim(),10),d=Number.parseInt(Cs.value.trim(),10),p=Number.isFinite(d)?Math.max(1,d):20,f=Number.isFinite(u)?Math.max(0,Math.min(p,u)):p;let l={};try{l=Vv(Ns.value)}catch(c){x(c instanceof Error?c.message:"능력치 JSON 오류","error");return}na.value="spawning";try{const c=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,m=await Fc(e,{actor_id:i||void 0,name:r||void 0,role:Ss.value,idempotencyKey:c,portrait:As.value.trim()||void 0,background:Ts.value.trim()||void 0,hp:f,max_hp:p,alive:f>0,stats:Object.keys(l).length>0?l:void 0}),$=typeof m.actor_id=="string"?m.actor_id.trim():"";if(!$)throw new Error("생성 응답에 actor_id가 없습니다.");const k=ws.value.trim();k&&await jc(e,$,k),Ce.value=$,Vt.value=$,i||(ea.value=""),na.value="ok",x(`Actor 생성 완료: ${$}`,"success"),await qt()}catch(c){na.value="error",x(c instanceof Error?c.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${xs.value}
            onInput=${i=>{xs.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ss.value}
            onChange=${i=>{Ss.value=i.target.value}}
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
            value=${ws.value}
            onInput=${i=>{ws.value=i.target.value}}
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
              value=${ea.value}
              onInput=${i=>{ea.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${As.value}
              onInput=${i=>{As.value=i.target.value}}
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
              value=${Cs.value}
              onInput=${i=>{const r=i.target.value;Cs.value=r,Qv(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Ts.value}
              onInput=${i=>{Ts.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Ns.value}
              onInput=${i=>{Ns.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function cm({state:t,nowMs:e}){var c;const n=zt.value||((c=t.session)==null?void 0:c.room)||"",a=t.join_gate,s=ks.value,i=Zt(s)?s:null,r=(t.party??[]).filter(m=>m.role!=="dm"),u=Vt.value.trim(),d=r.some(m=>m.id===u),p=d?u:u?"__manual__":"",f=async()=>{const m=Vt.value.trim(),$=ta.value.trim();if(!n||!m){x("Room/Actor가 필요합니다.","warning");return}gt.value="checking";try{const k=await Kc(n,m,$||void 0);ks.value=k,gt.value="ok",x("참가 가능 여부를 갱신했습니다.","success")}catch(k){gt.value="error";const A=k instanceof Error?k.message:"참가 가능 여부 확인에 실패했습니다.";x(A,"error")}},l=async()=>{var R,T;const m=Vt.value.trim(),$=ta.value.trim(),k=bs.value.trim();if(!n||!m||!$){x("Room/Actor/Keeper가 필요합니다.","warning");return}if(!pa(e))return;const A=((R=t.current_round)==null?void 0:R.phase)??((T=t.session)==null?void 0:T.status)??"unknown";if(hi("Mid-Join 승인 요청",n,A)){gt.value="requesting";try{const I=await Uc({room_id:n,actor_id:m,keeper_name:$,role:ys.value,...k?{name:k}:{}});ks.value=I;const N=Zt(I)?En(I,"granted",!1):!1,L=Zt(I)?ut(I,"reason_code",""):"";N?x("Mid-Join이 승인되었습니다.","success"):x(`Mid-Join이 거절되었습니다${L?`: ${L}`:""}`,"warning"),gt.value=N?"ok":"error",qt()}catch(I){gt.value="error";const N=I instanceof Error?I.message:"Mid-Join 요청에 실패했습니다.";x(N,"error")}finally{Fa()}}};return o`
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
            onChange=${m=>{const $=m.target.value;if($==="__manual__"){(d||!u)&&(Vt.value="");return}Vt.value=$}}
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
                value=${Vt.value}
                onInput=${m=>{Vt.value=m.target.value}}
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
            value=${ta.value}
            onInput=${m=>{ta.value=m.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ys.value}
            onChange=${m=>{ys.value=m.target.value}}
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
            value=${bs.value}
            onInput=${m=>{bs.value=m.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${f} disabled=${gt.value==="checking"||gt.value==="requesting"}>
              ${gt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${l} disabled=${gt.value==="checking"||gt.value==="requesting"}>
              ${gt.value==="requesting"?"Requesting...":"Request Join"}
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
  `}function pl({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function vl({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function ml(){const t=_i.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=Zt(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(Zt).slice(-8),i=t.canon_check,r=Zt(i)?i:null,u=r&&Array.isArray(r.warnings)?r.warnings.filter(L=>typeof L=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(L=>typeof L=="string").slice(0,3):[],p=n?En(n,"advanced",!1):!1,f=n?ut(n,"progress_reason",""):"",l=n?ut(n,"progress_detail",""):"",c=n?Dt(n,"player_successes",0):0,m=n?Dt(n,"player_required_successes",0):0,$=n?En(n,"dm_success",!1):!1,k=n?Dt(n,"timeouts",0):0,A=n?Dt(n,"unavailable",0):0,R=n?Dt(n,"reprompts",0):0,T=n?Dt(n,"npc_attacks",0):0,I=n?Dt(n,"keeper_timeout_sec",0):0,N=n?Dt(n,"roll_audit_count",0):0;return o`
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
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${R}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${I||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${N}</div></div>
      </div>

      ${s.length>0?o`
          <div class="trpg-round-list">
            ${s.map(L=>{const st=ut(L,"status","unknown"),At=ut(L,"actor_id","-"),Tt=ut(L,"role","-"),it=ut(L,"reason",""),ft=ut(L,"action_type",""),O=ut(L,"reply","");return o`
                <div class="trpg-round-item ${st.includes("fallback")||st.includes("timeout")?"failed":"active"}">
                  <span>${At} (${Tt})</span>
                  <span style="margin-left:auto; font-size:11px;">${st}</span>
                  ${ft?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${ft}</div>`:null}
                  ${it?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${it}</div>`:null}
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
  `}function um({state:t,nowMs:e}){var r,u,d;const n=zt.value||((r=t.session)==null?void 0:r.room)||"",a=((u=t.current_round)==null?void 0:u.phase)??((d=t.session)==null?void 0:d.status)??"unknown",s=rl(e),i=Zv(e);return o`
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
          ${s?o`<button class="trpg-run-btn recommend" onClick=${()=>tm(n,a)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Fa(),x("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function dm({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Xv(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function pm({state:t}){const e=t.party??[],n=t.story_log??[];return o`
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
          <${ul} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${w} title="맵" style="margin-top:16px;">
              <${sm} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${w} title="현재 라운드">
          <${vl} state=${t} />
        <//>

        <${w} title="기여도" style="margin-top:16px;">
          <${pl} state=${t} />
        <//>

        <${w} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>o`<${cl} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${dl} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function vm({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${w} title=${`이벤트 타임라인 (${e.length})`}>
          <${im} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${w} title="최근 라운드 결과">
          <${ml} />
        <//>

        <${w} title="현재 라운드" style="margin-top:16px;">
          <${vl} state=${t} />
        <//>
      </div>
    </div>
  `}function mm({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${um} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${w} title="조작 패널">
            <${rm} state=${t} nowMs=${e} />
          <//>

          <${w} title="Actor Spawn" style="margin-top:16px;">
            <${lm} state=${t} />
          <//>

          <${w} title="Mid-Join Gate" style="margin-top:16px;">
            <${cm} state=${t} nowMs=${e} />
          <//>

          <${w} title="최근 라운드 결과" style="margin-top:16px;">
            <${ml} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${w} title="기여도" style="margin-top:0;">
            <${pl} state=${t} />
          <//>

          <${w} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>o`<${cl} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${dl} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function fm(){var u,d,p,f,l;const t=Dr.value,e=ti.value;if(ht(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const c=window.setInterval(()=>{Eo.value=Date.now()},1e3);return()=>{window.clearInterval(c)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>qt()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,i=ol.value,r=Eo.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${zt.value||((u=t.session)==null?void 0:u.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((p=t.session)==null?void 0:p.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>qt()}>새로고침</button>
      </div>

      <${om} outcome=${s} />

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

      <${dm} active=${i} />

      ${i==="overview"?o`<${pm} state=${t} />`:i==="timeline"?o`<${vm} state=${t} />`:o`<${mm} state=${t} nowMs=${r} />`}
    </div>
  `}const Oi="masc_dashboard_agent_name";function _m(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Oi);return e??n??"dashboard"}const pt=_(_m()),hn=_(""),$n=_(""),ja=_(""),fl=_(null),Ka=_(null),yn=_(!1),Le=_(!1),bn=_(!1),kn=_(!1),Ua=_(!1),Ha=_(!1),Za=_(!1);function Ba(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function va(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function _l(t){return!t||t.length===0?"none":t.join(", ")}function gm(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Ba(t.quiet_start)}-${Ba(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${va(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${va(t.interval_s)}.`:`Lodge ticks every ${va(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function Ge(){Fe();try{await _e()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function Mi(t){const e=t.trim();pt.value=e,e&&localStorage.setItem(Oi,e)}function hm(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function $i(){const t=pt.value.trim();if(t){bn.value=!0;try{const e=await Bc(t),n=hm(e);n&&Mi(n),Za.value=!0,await Ge(),x(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";x(n,"error")}finally{bn.value=!1}}}async function $m(){const t=pt.value.trim();if(t){kn.value=!0;try{await Tr(t),Za.value=!1,await Ge(),x(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";x(n,"error")}finally{kn.value=!1}}}async function ym(){const t=pt.value.trim();if(t)try{await Tr(t)}catch{}localStorage.removeItem(Oi),Mi("dashboard"),Za.value=!1,await $i()}async function bm(){const t=pt.value.trim();if(t){Ua.value=!0;try{await Wc(t),await Ge(),x("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";x(n,"error")}finally{Ua.value=!1}}}async function Io(){const t=pt.value.trim(),e=hn.value.trim();if(!(!t||!e)){yn.value=!0;try{await Ar(t,e),hn.value="",await Ge(),x("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";x(a,"error")}finally{yn.value=!1}}}async function km(){const t=$n.value.trim(),e=ja.value.trim()||"Created from dashboard";if(t){Le.value=!0;try{await Hc(t,e,1),$n.value="",ja.value="",await Ge(),x("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";x(a,"error")}finally{Le.value=!1}}}async function Oo(){const t=pt.value.trim()||"dashboard";Ha.value=!0,Ka.value=null;try{const e=await qn({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=Ni(e.result);fl.value=n,await Ge(),n!=null&&n.skipped_reason?x(n.skipped_reason,"warning"):x(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";Ka.value=n,x(n,"error")}finally{Ha.value=!1}}function xm({runtime:t}){var s,i;const e=fl.value??(t==null?void 0:t.last_tick_result)??null;if(Ka.value)return o`<div class="control-result-box is-error">${Ka.value}</div>`;if(!e)return o`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((s=e.skipped_rows)==null?void 0:s.slice(0,3))??[],a=((i=e.passed_rows)==null?void 0:i.slice(0,3))??[];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?o`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${_l(e.acted_names)}</div>
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
  `}function Sm(t){return t.find(n=>n.name===an.value)??t[0]??null}function wm(){var a,s;const t=St.value,e=((a=se.value)==null?void 0:a.lodge)??null,n=Sm(t);return ht(()=>{$i()},[]),ht(()=>{var r;const i=((r=t[0])==null?void 0:r.name)??"";if(!an.value&&i){oa(i);return}an.value&&!t.some(u=>u.name===an.value)&&oa(i)},[t.map(i=>i.name).join("|")]),o`
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
          onInput=${i=>Mi(i.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{$i()}}
            disabled=${bn.value||pt.value.trim()===""}
          >
            ${bn.value?"Joining...":Za.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{$m()}}
            disabled=${kn.value||pt.value.trim()===""}
          >
            ${kn.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{ym()}}
            disabled=${bn.value||kn.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{bm()}}
            disabled=${Ua.value||pt.value.trim()===""}
          >
            ${Ua.value?"Pinging...":"Heartbeat"}
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
            onKeyDown=${i=>{i.key==="Enter"&&Io()}}
            disabled=${yn.value}
          />
          <button
            class="control-btn"
            onClick=${()=>{Io()}}
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
          onInput=${i=>{oa(i.target.value)}}
          disabled=${t.length===0}
        >
          ${t.length===0?o`<option value="">No keepers available</option>`:t.map(i=>o`<option value=${i.name}>${i.name}</option>`)}
        </select>

        <${jr} keeper=${n} />
        <${Ur}
          actor=${pt.value.trim()||"dashboard"}
          keeper=${n}
          onPokeLodge=${()=>{Oo()}}
        />
        <${Kr}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${gm(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${va(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${Ba(e==null?void 0:e.quiet_start)}-${Ba(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${_l((s=e==null?void 0:e.last_tick_result)==null?void 0:s.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?o`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{Oo()}}
            disabled=${Ha.value}
          >
            ${Ha.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${xm} runtime=${e} />
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
          disabled=${Le.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${ja.value}
          onInput=${i=>{ja.value=i.target.value}}
          disabled=${Le.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{km()}}
          disabled=${Le.value||$n.value.trim()===""}
        >
          ${Le.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const Mo=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],yi=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"execution",label:"Execution",icon:"🛠️",group:"observe",description:"Intervention queue for stalled work, ownership gaps, and execution drift"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"activity",label:"Activity",icon:"📊",group:"observe",description:"Unified live stream for messages, task changes, board events, and keeper events"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"council",label:"Council",icon:"🏛️",group:"coordinate",description:"Debates, quorum status, and decision flow"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals and MDAL loops in one planning surface with freshness signals"},{id:"tasks",label:"Tasks",icon:"📋",group:"coordinate",description:"Kanban-style task distribution"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],zo="masc_dashboard_quick_actions_open";function Am(){const t=Ft.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Mn.value} events</span>
    </div>
  `}function Tm(){const t=Pt.value.tab,e=Ft.value,n=yi.find(r=>r.id===t),a=Mo.find(r=>r.id===(n==null?void 0:n.group)),[s,i]=er(()=>{const r=localStorage.getItem(zo);return r!=="0"});return ht(()=>{localStorage.setItem(zo,s?"1":"0")},[s]),o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${a?o`<span class="rail-section-chip">${a.label}</span>`:null}
        </div>
        ${Mo.map(r=>o`
          <div class="rail-nav-group" key=${r.id}>
            <div class="rail-group-label">${r.label}</div>
            <div class="rail-group-copy">${r.description}</div>
            <div class="rail-tab-list">
              ${yi.filter(u=>u.group===r.id).map(u=>o`
                  <button
                    class="rail-tab-btn ${t===u.id?"active":""}"
                    onClick=${()=>bt(u.id)}
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
            <strong>${ae.value.length}</strong>
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
            <strong>${Mn.value}</strong>
          </div>
        </div>
        <div class="rail-snapshot-copy">
          <span>Connection ${e?"healthy":"recovering"}</span>
          <span>${(a==null?void 0:a.label)??"Observe"} workspace active</span>
        </div>
        <div class="rail-inline-actions">
          <button
            class="rail-refresh-btn"
            onClick=${()=>{_e(),t==="command"&&Dn(),t==="ops"&&Ke(),t==="board"&&Et(),t==="trpg"&&qt(),t==="goals"&&(on(),Ee())}}
          >
            Refresh Now
          </button>
          <button class="rail-secondary-btn" onClick=${()=>bt("ops")}>
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
        ${s?o`<div class="rail-fold-body"><${wm} /></div>`:o`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function Cm(){switch(Pt.value.tab){case"command":return o`<${cp} />`;case"overview":return o`<${ho} />`;case"ops":return o`<${Dp} />`;case"council":return o`<${Op} />`;case"board":return o`<${Gp} />`;case"execution":return o`<${Dv} />`;case"activity":return o`<${pv} />`;case"agents":return o`<${Sv} />`;case"tasks":return o`<${wv} />`;case"goals":return o`<${Fv} />`;case"trpg":return o`<${fm} />`;default:return o`<${ho} />`}}function Nm(){ht(()=>{Kl(),yr(),_e(),Et();const n=Iu();return Ou(),()=>{Ql(),n(),Mu()}},[]),ht(()=>{const n=Pt.value.tab;n==="command"&&Dn(),n==="ops"&&Ke(),n==="board"&&Et(),n==="trpg"&&qt(),n==="goals"&&(on(),Ee())},[Pt.value.tab]);const t=Pt.value.tab,e=yi.find(n=>n.id===t);return o`
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
          <${Am} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Tm} />
        <main class="dashboard-main">
          ${Zs.value&&!Ft.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${Cm} />`}
        </main>
      </div>

      <${id} />
      <${ud} />
      <${Uu} />
    </div>
  `}const qo=document.getElementById("app");qo&&Sl(o`<${Nm} />`,qo);
