(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const o of i.addedNodes)o.tagName==="LINK"&&o.rel==="modulepreload"&&s(o)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var Oe,N,ws,Ss,ot,Gn,Cs,As,Ts,Rn,on,ln,Qt={},Ns=[],za=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Fe=Array.isArray;function et(t,e){for(var n in e)t[n]=e[n];return t}function Ln(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function Rs(t,e,n){var s,a,i,o={};for(i in e)i=="key"?s=e[i]:i=="ref"?a=e[i]:o[i]=e[i];if(arguments.length>2&&(o.children=arguments.length>3?Oe.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)o[i]===void 0&&(o[i]=t.defaultProps[i]);return $e(t,o,s,a,null)}function $e(t,e,n,s,a){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++ws,__i:-1,__u:0};return a==null&&N.vnode!=null&&N.vnode(i),i}function se(t){return t.children}function Pt(t,e){this.props=t,this.context=e}function ht(t,e){if(e==null)return t.__?ht(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?ht(t):null}function Ls(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return Ls(t)}}function Vn(t){(!t.__d&&(t.__d=!0)&&ot.push(t)&&!xe.__r++||Gn!=N.debounceRendering)&&((Gn=N.debounceRendering)||Cs)(xe)}function xe(){for(var t,e,n,s,a,i,o,l=1;ot.length;)ot.length>l&&ot.sort(As),t=ot.shift(),l=ot.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,i=[],o=[],e.__P&&((n=et({},s)).__v=s.__v+1,N.vnode&&N.vnode(n),En(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,i,a??ht(s),!!(32&s.__u),o),n.__v=s.__v,n.__.__k[n.__i]=n,Ps(i,n,o),s.__e=s.__=null,n.__e!=a&&Ls(n)));xe.__r=0}function Es(t,e,n,s,a,i,o,l,u,d,p){var c,v,f,y,k,R,S,w=s&&s.__k||Ns,O=e.length;for(u=Ha(n,e,w,u,O),c=0;c<O;c++)(f=n.__k[c])!=null&&(v=f.__i==-1?Qt:w[f.__i]||Qt,f.__i=c,R=En(t,f,v,a,i,o,l,u,d,p),y=f.__e,f.ref&&v.ref!=f.ref&&(v.ref&&Dn(v.ref,null,f),p.push(f.ref,f.__c||y,f)),k==null&&y!=null&&(k=y),(S=!!(4&f.__u))||v.__k===f.__k?u=Ds(f,u,t,S):typeof f.type=="function"&&R!==void 0?u=R:y&&(u=y.nextSibling),f.__u&=-7);return n.__e=k,u}function Ha(t,e,n,s,a){var i,o,l,u,d,p=n.length,c=p,v=0;for(t.__k=new Array(a),i=0;i<a;i++)(o=e[i])!=null&&typeof o!="boolean"&&typeof o!="function"?(typeof o=="string"||typeof o=="number"||typeof o=="bigint"||o.constructor==String?o=t.__k[i]=$e(null,o,null,null,null):Fe(o)?o=t.__k[i]=$e(se,{children:o},null,null,null):o.constructor===void 0&&o.__b>0?o=t.__k[i]=$e(o.type,o.props,o.key,o.ref?o.ref:null,o.__v):t.__k[i]=o,u=i+v,o.__=t,o.__b=t.__b+1,l=null,(d=o.__i=Ua(o,n,u,c))!=-1&&(c--,(l=n[d])&&(l.__u|=2)),l==null||l.__v==null?(d==-1&&(a>p?v--:a<p&&v++),typeof o.type!="function"&&(o.__u|=4)):d!=u&&(d==u-1?v--:d==u+1?v++:(d>u?v--:v++,o.__u|=4))):t.__k[i]=null;if(c)for(i=0;i<p;i++)(l=n[i])!=null&&(2&l.__u)==0&&(l.__e==s&&(s=ht(l)),js(l,l));return s}function Ds(t,e,n,s){var a,i;if(typeof t.type=="function"){for(a=t.__k,i=0;a&&i<a.length;i++)a[i]&&(a[i].__=t,e=Ds(a[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=ht(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Ua(t,e,n,s){var a,i,o,l=t.key,u=t.type,d=e[n],p=d!=null&&(2&d.__u)==0;if(d===null&&l==null||p&&l==d.key&&u==d.type)return n;if(s>(p?1:0)){for(a=n-1,i=n+1;a>=0||i<e.length;)if((d=e[o=a>=0?a--:i++])!=null&&(2&d.__u)==0&&l==d.key&&u==d.type)return o}return-1}function Yn(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||za.test(e)?n:n+"px"}function ce(t,e,n,s,a){var i,o;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||Yn(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||Yn(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Ts,"$1")),o=e.toLowerCase(),e=o in t||e=="onFocusOut"||e=="onFocusIn"?o.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=Rn,t.addEventListener(e,i?ln:on,i)):t.removeEventListener(e,i?ln:on,i);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Xn(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Rn++;else if(e.t<n.u)return;return n(N.event?N.event(e):e)}}}function En(t,e,n,s,a,i,o,l,u,d){var p,c,v,f,y,k,R,S,w,O,H,L,$,Q,rt,W,tt,T=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(u=!!(32&n.__u),i=[l=e.__e=n.__e]),(p=N.__b)&&p(e);t:if(typeof T=="function")try{if(S=e.props,w="prototype"in T&&T.prototype.render,O=(p=T.contextType)&&s[p.__c],H=p?O?O.props.value:p.__:s,n.__c?R=(c=e.__c=n.__c).__=c.__E:(w?e.__c=c=new T(S,H):(e.__c=c=new Pt(S,H),c.constructor=T,c.render=Ka),O&&O.sub(c),c.state||(c.state={}),c.__n=s,v=c.__d=!0,c.__h=[],c._sb=[]),w&&c.__s==null&&(c.__s=c.state),w&&T.getDerivedStateFromProps!=null&&(c.__s==c.state&&(c.__s=et({},c.__s)),et(c.__s,T.getDerivedStateFromProps(S,c.__s))),f=c.props,y=c.state,c.__v=e,v)w&&T.getDerivedStateFromProps==null&&c.componentWillMount!=null&&c.componentWillMount(),w&&c.componentDidMount!=null&&c.__h.push(c.componentDidMount);else{if(w&&T.getDerivedStateFromProps==null&&S!==f&&c.componentWillReceiveProps!=null&&c.componentWillReceiveProps(S,H),e.__v==n.__v||!c.__e&&c.shouldComponentUpdate!=null&&c.shouldComponentUpdate(S,c.__s,H)===!1){for(e.__v!=n.__v&&(c.props=S,c.state=c.__s,c.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(I){I&&(I.__=e)}),L=0;L<c._sb.length;L++)c.__h.push(c._sb[L]);c._sb=[],c.__h.length&&o.push(c);break t}c.componentWillUpdate!=null&&c.componentWillUpdate(S,c.__s,H),w&&c.componentDidUpdate!=null&&c.__h.push(function(){c.componentDidUpdate(f,y,k)})}if(c.context=H,c.props=S,c.__P=t,c.__e=!1,$=N.__r,Q=0,w){for(c.state=c.__s,c.__d=!1,$&&$(e),p=c.render(c.props,c.state,c.context),rt=0;rt<c._sb.length;rt++)c.__h.push(c._sb[rt]);c._sb=[]}else do c.__d=!1,$&&$(e),p=c.render(c.props,c.state,c.context),c.state=c.__s;while(c.__d&&++Q<25);c.state=c.__s,c.getChildContext!=null&&(s=et(et({},s),c.getChildContext())),w&&!v&&c.getSnapshotBeforeUpdate!=null&&(k=c.getSnapshotBeforeUpdate(f,y)),W=p,p!=null&&p.type===se&&p.key==null&&(W=Is(p.props.children)),l=Es(t,Fe(W)?W:[W],e,n,s,a,i,o,l,u,d),c.base=e.__e,e.__u&=-161,c.__h.length&&o.push(c),R&&(c.__E=c.__=null)}catch(I){if(e.__v=null,u||i!=null)if(I.then){for(e.__u|=u?160:128;l&&l.nodeType==8&&l.nextSibling;)l=l.nextSibling;i[i.indexOf(l)]=null,e.__e=l}else{for(tt=i.length;tt--;)Ln(i[tt]);cn(e)}else e.__e=n.__e,e.__k=n.__k,I.then||cn(e);N.__e(I,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):l=e.__e=Ba(n.__e,e,n,s,a,i,o,u,d);return(p=N.diffed)&&p(e),128&e.__u?void 0:l}function cn(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(cn)}function Ps(t,e,n){for(var s=0;s<n.length;s++)Dn(n[s],n[++s],n[++s]);N.__c&&N.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(i){i.call(a)})}catch(i){N.__e(i,a.__v)}})}function Is(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Fe(t)?t.map(Is):et({},t)}function Ba(t,e,n,s,a,i,o,l,u){var d,p,c,v,f,y,k,R=n.props||Qt,S=e.props,w=e.type;if(w=="svg"?a="http://www.w3.org/2000/svg":w=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),i!=null){for(d=0;d<i.length;d++)if((f=i[d])&&"setAttribute"in f==!!w&&(w?f.localName==w:f.nodeType==3)){t=f,i[d]=null;break}}if(t==null){if(w==null)return document.createTextNode(S);t=document.createElementNS(a,w,S.is&&S),l&&(N.__m&&N.__m(e,i),l=!1),i=null}if(w==null)R===S||l&&t.data==S||(t.data=S);else{if(i=i&&Oe.call(t.childNodes),!l&&i!=null)for(R={},d=0;d<t.attributes.length;d++)R[(f=t.attributes[d]).name]=f.value;for(d in R)if(f=R[d],d!="children"){if(d=="dangerouslySetInnerHTML")c=f;else if(!(d in S)){if(d=="value"&&"defaultValue"in S||d=="checked"&&"defaultChecked"in S)continue;ce(t,d,null,f,a)}}for(d in S)f=S[d],d=="children"?v=f:d=="dangerouslySetInnerHTML"?p=f:d=="value"?y=f:d=="checked"?k=f:l&&typeof f!="function"||R[d]===f||ce(t,d,f,R[d],a);if(p)l||c&&(p.__html==c.__html||p.__html==t.innerHTML)||(t.innerHTML=p.__html),e.__k=[];else if(c&&(t.innerHTML=""),Es(e.type=="template"?t.content:t,Fe(v)?v:[v],e,n,s,w=="foreignObject"?"http://www.w3.org/1999/xhtml":a,i,o,i?i[0]:n.__k&&ht(n,0),l,u),i!=null)for(d=i.length;d--;)Ln(i[d]);l||(d="value",w=="progress"&&y==null?t.removeAttribute("value"):y!=null&&(y!==t[d]||w=="progress"&&!y||w=="option"&&y!=R[d])&&ce(t,d,y,R[d],a),d="checked",k!=null&&k!=t[d]&&ce(t,d,k,R[d],a))}return t}function Dn(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){N.__e(a,n)}}function js(t,e,n){var s,a;if(N.unmount&&N.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||Dn(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){N.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&js(s[a],e,n||typeof t.type!="function");n||Ln(t.__e),t.__c=t.__=t.__e=void 0}function Ka(t,e,n){return this.constructor(t,n)}function qa(t,e,n){var s,a,i,o;e==document&&(e=document.documentElement),N.__&&N.__(t,e),a=(s=!1)?null:e.__k,i=[],o=[],En(e,t=e.__k=Rs(se,null,[t]),a||Qt,Qt,e.namespaceURI,a?null:e.firstChild?Oe.call(e.childNodes):null,i,a?a.__e:e.firstChild,s,o),Ps(i,t,o)}Oe=Ns.slice,N={__e:function(t,e,n,s){for(var a,i,o;e=e.__;)if((a=e.__c)&&!a.__)try{if((i=a.constructor)&&i.getDerivedStateFromError!=null&&(a.setState(i.getDerivedStateFromError(t)),o=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),o=a.__d),o)return a.__E=a}catch(l){t=l}throw t}},ws=0,Ss=function(t){return t!=null&&t.constructor===void 0},Pt.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=et({},this.state),typeof t=="function"&&(t=t(et({},n),this.props)),t&&et(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),Vn(this))},Pt.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),Vn(this))},Pt.prototype.render=se,ot=[],Cs=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,As=function(t,e){return t.__v.__b-e.__v.__b},xe.__r=0,Ts=/(PointerCapture)$|Capture$/i,Rn=0,on=Xn(!1),ln=Xn(!0);var Ms=function(t,e,n,s){var a;e[0]=0;for(var i=1;i<e.length;i++){var o=e[i++],l=e[i]?(e[0]|=o?1:2,n[e[i++]]):e[++i];o===3?s[0]=l:o===4?s[1]=Object.assign(s[1]||{},l):o===5?(s[1]=s[1]||{})[e[++i]]=l:o===6?s[1][e[++i]]+=l+"":o?(a=t.apply(l,Ms(t,l,n,["",null])),s.push(a),l[0]?e[0]|=2:(e[i-2]=0,e[i]=a)):s.push(l)}return s},Zn=new Map;function Wa(t){var e=Zn.get(this);return e||(e=new Map,Zn.set(this,e)),(e=Ms(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,i=1,o="",l="",u=[0],d=function(v){i===1&&(v||(o=o.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?u.push(0,v,o):i===3&&(v||o)?(u.push(3,v,o),i=2):i===2&&o==="..."&&v?u.push(4,v,0):i===2&&o&&!v?u.push(5,0,!0,o):i>=5&&((o||!v&&i===5)&&(u.push(i,0,o,a),i=6),v&&(u.push(i,v,0,a),i=6)),o=""},p=0;p<n.length;p++){p&&(i===1&&d(),d(p));for(var c=0;c<n[p].length;c++)s=n[p][c],i===1?s==="<"?(d(),u=[u],i=3):o+=s:i===4?o==="--"&&s===">"?(i=1,o=""):o=s+o[0]:l?s===l?l="":o+=s:s==='"'||s==="'"?l=s:s===">"?(d(),i=1):i&&(s==="="?(i=5,a=o,o=""):s==="/"&&(i<5||n[p][c+1]===">")?(d(),i===3&&(u=u[0]),i=u,(u=u[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(d(),i=2):o+=s),i===3&&o==="!--"&&(i=4,u=u[0])}return d(),u})(t)),e),arguments,[])).length>1?e:e[0]}var r=Wa.bind(Rs),te,D,Ke,Qn,un=0,Os=[],P=N,ts=P.__b,es=P.__r,ns=P.diffed,ss=P.__c,as=P.unmount,is=P.__;function Pn(t,e){P.__h&&P.__h(D,t,un||e),un=0;var n=D.__H||(D.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function ue(t){return un=1,Ja(Hs,t)}function Ja(t,e,n){var s=Pn(te++,2);if(s.t=t,!s.__c&&(s.__=[Hs(void 0,e),function(l){var u=s.__N?s.__N[0]:s.__[0],d=s.t(u,l);u!==d&&(s.__N=[d,s.__[1]],s.__c.setState({}))}],s.__c=D,!D.__f)){var a=function(l,u,d){if(!s.__c.__H)return!0;var p=s.__c.__H.__.filter(function(v){return!!v.__c});if(p.every(function(v){return!v.__N}))return!i||i.call(this,l,u,d);var c=s.__c.props!==l;return p.forEach(function(v){if(v.__N){var f=v.__[0];v.__=v.__N,v.__N=void 0,f!==v.__[0]&&(c=!0)}}),i&&i.call(this,l,u,d)||c};D.__f=!0;var i=D.shouldComponentUpdate,o=D.componentWillUpdate;D.componentWillUpdate=function(l,u,d){if(this.__e){var p=i;i=void 0,a(l,u,d),i=p}o&&o.call(this,l,u,d)},D.shouldComponentUpdate=a}return s.__N||s.__}function yt(t,e){var n=Pn(te++,3);!P.__s&&zs(n.__H,e)&&(n.__=t,n.u=e,D.__H.__h.push(n))}function Fs(t,e){var n=Pn(te++,7);return zs(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Ga(){for(var t;t=Os.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(he),t.__H.__h.forEach(dn),t.__H.__h=[]}catch(e){t.__H.__h=[],P.__e(e,t.__v)}}P.__b=function(t){D=null,ts&&ts(t)},P.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),is&&is(t,e)},P.__r=function(t){es&&es(t),te=0;var e=(D=t.__c).__H;e&&(Ke===D?(e.__h=[],D.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(he),e.__h.forEach(dn),e.__h=[],te=0)),Ke=D},P.diffed=function(t){ns&&ns(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(Os.push(e)!==1&&Qn===P.requestAnimationFrame||((Qn=P.requestAnimationFrame)||Va)(Ga)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Ke=D=null},P.__c=function(t,e){e.some(function(n){try{n.__h.forEach(he),n.__h=n.__h.filter(function(s){return!s.__||dn(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],P.__e(s,n.__v)}}),ss&&ss(t,e)},P.unmount=function(t){as&&as(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{he(s)}catch(a){e=a}}),n.__H=void 0,e&&P.__e(e,n.__v))};var rs=typeof requestAnimationFrame=="function";function Va(t){var e,n=function(){clearTimeout(s),rs&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);rs&&(e=requestAnimationFrame(n))}function he(t){var e=D,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),D=e}function dn(t){var e=D;t.__c=t.__(),D=e}function zs(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}function Hs(t,e){return typeof e=="function"?e(t):e}var Ya=Symbol.for("preact-signals");function ze(){if(nt>1)nt--;else{for(var t,e=!1;It!==void 0;){var n=It;for(It=void 0,pn++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&Ks(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(pn=0,nt--,e)throw t}}function Xa(t){if(nt>0)return t();nt++;try{return t()}finally{ze()}}var C=void 0;function Us(t){var e=C;C=void 0;try{return t()}finally{C=e}}var It=void 0,nt=0,pn=0,we=0;function Bs(t){if(C!==void 0){var e=t.n;if(e===void 0||e.t!==C)return e={i:0,S:t,p:C.s,n:void 0,t:C,e:void 0,x:void 0,r:e},C.s!==void 0&&(C.s.n=e),C.s=e,t.n=e,32&C.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=C.s,e.n=void 0,C.s.n=e,C.s=e),e}}function M(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}M.prototype.brand=Ya;M.prototype.h=function(){return!0};M.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:Us(function(){var s;(s=e.W)==null||s.call(e)}))};M.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&Us(function(){var a;(a=e.Z)==null||a.call(e)}))}};M.prototype.subscribe=function(t){var e=this;return ae(function(){var n=e.value,s=C;C=void 0;try{t(n)}finally{C=s}},{name:"sub"})};M.prototype.valueOf=function(){return this.value};M.prototype.toString=function(){return this.value+""};M.prototype.toJSON=function(){return this.value};M.prototype.peek=function(){var t=C;C=void 0;try{return this.value}finally{C=t}};Object.defineProperty(M.prototype,"value",{get:function(){var t=Bs(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(pn>100)throw new Error("Cycle detected");this.v=t,this.i++,we++,nt++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{ze()}}}});function m(t,e){return new M(t,e)}function Ks(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function qs(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Ws(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function ct(t,e){M.call(this,void 0),this.x=t,this.s=void 0,this.g=we-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}ct.prototype=new M;ct.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===we))return!0;if(this.g=we,this.f|=1,this.i>0&&!Ks(this))return this.f&=-2,!0;var t=C;try{qs(this),C=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return C=t,Ws(this),this.f&=-2,!0};ct.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}M.prototype.S.call(this,t)};ct.prototype.U=function(t){if(this.t!==void 0&&(M.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};ct.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(ct.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Bs(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function bt(t,e){return new ct(t,e)}function Js(t){var e=t.u;if(t.u=void 0,typeof e=="function"){nt++;var n=C;C=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,In(t),s}finally{C=n,ze()}}}function In(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,Js(t)}function Za(t){if(C!==this)throw new Error("Out-of-order effect");Ws(this),C=t,this.f&=-2,8&this.f&&In(this),ze()}function Ct(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Ct.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Ct.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,Js(this),qs(this),nt++;var t=C;return C=this,Za.bind(this,t)};Ct.prototype.N=function(){2&this.f||(this.f|=2,this.o=It,It=this)};Ct.prototype.d=function(){this.f|=8,1&this.f||In(this)};Ct.prototype.dispose=function(){this.d()};function ae(t,e){var n=new Ct(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var Gs,de,Qa=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Vs=[];ae(function(){Gs=this.N})();function At(t,e){N[t]=e.bind(null,N[t]||function(){})}function Se(t){if(de){var e=de;de=void 0,e()}de=t&&t.S()}function Ys(t){var e=this,n=t.data,s=ei(n);s.value=n;var a=Fs(function(){for(var l=e,u=e.__v;u=u.__;)if(u.__c){u.__c.__$f|=4;break}var d=bt(function(){var f=s.value.value;return f===0?0:f===!0?"":f||""}),p=bt(function(){return!Array.isArray(d.value)&&!Ss(d.value)}),c=ae(function(){if(this.N=Xs,p.value){var f=d.value;l.__v&&l.__v.__e&&l.__v.__e.nodeType===3&&(l.__v.__e.data=f)}}),v=e.__$u.d;return e.__$u.d=function(){c(),v.call(this)},[p,d]},[]),i=a[0],o=a[1];return i.value?o.peek():o.value}Ys.displayName="ReactiveTextNode";Object.defineProperties(M.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Ys},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});At("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var i=s[a];i instanceof M&&(n||(e.__np=n={}),n[a]=i,s[a]=i.peek())}}t(e)});At("__r",function(t,e){if(t(e),e.type!==se){Se();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,i){var o;return ae(function(){o=this},{name:i}),o.c=a,o})(function(){var a;Qa&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),Se(n)}});At("__e",function(t,e,n,s){Se(),t(e,n,s)});At("diffed",function(t,e){Se();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var i=n.U;if(i)for(var o in i){var l=i[o];l!==void 0&&!(o in s)&&(l.d(),i[o]=void 0)}else i={},n.U=i;for(var u in s){var d=i[u],p=s[u];d===void 0?(d=ti(n,u,p),i[u]=d):d.o(p,a)}for(var c in s)a[c]=s[c]}}t(e)});function ti(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,i=m(n),o=n.peek();return{o:function(l,u){i.value=l,o=l.peek()},d:ae(function(){this.N=Xs;var l=i.value.value;o!==l?(o=void 0,a?t[e]=l:l!=null&&(l!==!1||e[4]==="-")?t.setAttribute(e,l):t.removeAttribute(e)):o=void 0})}}At("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var i=s[a];i&&i.d()}}}e.__np=void 0}else{var o=e.__c;if(o){var l=o.__$u;l&&(o.__$u=void 0,l.d())}}t(e)});At("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});Pt.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var o in t)if(o!=="__source"&&t[o]!==this.props[o])return!0;for(var l in this.props)if(!(l in t))return!0;return!1};function ei(t,e){return Fs(function(){return m(t,e)},[])}var ni=function(t){queueMicrotask(function(){queueMicrotask(t)})};function si(){Xa(function(){for(var t;t=Vs.shift();)Gs.call(t)})}function Xs(){Vs.push(this)===1&&(N.requestAnimationFrame||ni)(si)}const ai=["overview","board","activity","agents","tasks","journal","trpg","council"],Zs={tab:"overview",params:{},postId:null};function os(t){return!!t&&ai.includes(t)}function vn(t){try{return decodeURIComponent(t)}catch{return t}}function fn(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function ii(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Qs(t,e){const n=t[0],s=e.tab,a=os(n)?n:os(s)?s:"overview";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=vn(t[2]):t[0]==="post"&&t[1]&&(i=vn(t[1]))),{tab:a,params:e,postId:i}}function Ce(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Zs;const n=vn(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=fn(a),o=ii(s);return Qs(o,i)}function ri(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Zs,params:fn(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=fn(e.replace(/^\?/,""));return Qs(s,a)}function ta(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const Z=m(Ce(window.location.hash));window.addEventListener("hashchange",()=>{Z.value=Ce(window.location.hash)});function He(t,e){const n={tab:t,params:{},postId:null};window.location.hash=ta(n)}function oi(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function li(){if(window.location.hash&&window.location.hash!=="#"){Z.value=Ce(window.location.hash);return}const t=ri(window.location.pathname,window.location.search);if(t){Z.value=t;const e=ta(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",Z.value=Ce(window.location.hash)}const ci=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function ui(){const t=Z.value.tab;return r`
    <div class="main-tab-bar">
      ${ci.map(e=>r`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>He(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const ls="masc_dashboard_sse_session_id",di=1e3,pi=15e3,kt=m(!1),jn=m(0),ea=m(null),Ae=m([]);function vi(){let t=sessionStorage.getItem(ls);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(ls,t)),t}const fi=200;function J(t,e){const n={agent:t,text:e,timestamp:Date.now()};Ae.value=[n,...Ae.value].slice(0,fi)}let X=null,_t=null,mn=0;function na(){_t&&(clearTimeout(_t),_t=null)}function mi(){if(_t)return;mn++;const t=Math.min(mn,5),e=Math.min(pi,di*Math.pow(2,t));_t=setTimeout(()=>{_t=null,sa()},e)}function sa(){na(),X&&(X.close(),X=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",vi());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);X=i,i.onopen=()=>{X===i&&(mn=0,kt.value=!0)},i.onerror=()=>{X===i&&(kt.value=!1,i.close(),X=null,mi())},i.onmessage=o=>{try{const l=JSON.parse(o.data);jn.value++,ea.value=l,_i(l)}catch{}}}function _i(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":J(n,"Joined");break;case"agent_left":J(n,"Left");break;case"broadcast":J(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":J(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":J(n,"New post");break;case"board_comment":J(n,"New comment");break;case"keeper_heartbeat":J(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":J(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":J(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":J(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:J(n,e)}}function gi(){na(),X&&(X.close(),X=null),kt.value=!1}function aa(){return new URLSearchParams(window.location.search)}function ia(){const t=aa(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function ra(){return{...ia(),"Content-Type":"application/json"}}const $i=15e3,oa=3e4,hi=6e4;async function Mn(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const o=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Error(`${o} ${t}: timeout after ${n}ms`)}throw i}finally{clearTimeout(a)}}function yi(){var e,n;const t=aa();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function ie(t){const e=await Mn(t,{headers:ia()},$i);if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function re(t,e){const n=await Mn(t,{method:"POST",headers:ra(),body:JSON.stringify(e)},oa);if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function bi(t,e,n,s=oa){const a=await Mn(t,{method:"POST",headers:{...ra(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Error(`POST ${t}: ${a.status} ${a.statusText}`);return a.text()}function ki(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function xi(t){var e,n,s,a,i,o,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const u=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(u)}return((l=(o=(i=t.result)==null?void 0:i.content)==null?void 0:o[0])==null?void 0:l.text)??""}async function z(t,e){const n=await bi("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},hi),s=ki(n);return xi(s)}function la(t){const e=t.trim();if(!e)return[];const n=JSON.parse(e);return Array.isArray(n)?n:[]}function wi(t="compact"){return ie(`/api/v1/dashboard?mode=${t}`)}function Si(t){const n=new URLSearchParams().toString();return ie(`/api/v1/board${n?`?${n}`:""}`)}function Ci(t){return ie(`/api/v1/board/${t}`)}function ca(t,e){return re("/api/v1/tools/masc_board_vote",{post_id:t,vote:e,voter:yi()})}function Ai(t,e,n){return re("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Ti(t){const e=_(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function F(...t){for(const e of t){const n=_(e,"");if(n.trim())return n.trim()}return""}function cs(t){const e=Ti(F(t.outcome,t.result,t.result_code));if(!e)return;const n=F(t.reason,t.reason_code,t.description,t.detail),s=F(t.summary,t.summary_ko,t.summary_en,t.note),a=F(t.details,t.details_text,t.text,t.note),i=F(t.winner,t.winner_name,t.actor_winner,t.winner_actor),o=F(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=F(t.raw_reason,t.raw_reason_code,t.error_message),u=(()=>{const c=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof c=="string"?[c]:Array.isArray(c)?c.map(v=>{if(typeof v=="string")return v.trim();if(E(v)){const f=_(v.summary,"").trim();if(f)return f;const y=_(v.text,"").trim();if(y)return y;const k=_(v.type,"").trim();return k||_(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),d=(()=>{const c=j(t.turn,Number.NaN);if(Number.isFinite(c))return c;const v=j(t.turn_number,Number.NaN);if(Number.isFinite(v))return v;const f=j(t.current_turn,Number.NaN);if(Number.isFinite(f))return f;const y=j(t.round,Number.NaN);return Number.isFinite(y)?y:void 0})(),p=F(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:o||void 0,evidence:u.length>0?u:void 0,raw_reason:l||void 0,turn:d,phase:p||void 0}}function Ni(t,e){const n=E(t.state)?t.state:{};if(_(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(o=>E(o)?_(o.type,"")==="session.outcome":!1),i=E(n.session_outcome)?n.session_outcome:{};if(E(i)&&Object.keys(i).length>0){const o=cs(i);if(o)return o}if(E(a))return cs(E(a.payload)?a.payload:{})}function E(t){return typeof t=="object"&&t!==null}function _(t,e=""){return typeof t=="string"?t:e}function j(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Ri(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function _n(t,e=!1){return typeof t=="boolean"?t:e}function Lt(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(E(e)){const n=_(e.name,"").trim(),s=_(e.id,"").trim(),a=_(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Li(t){const e={};if(!E(t)&&!Array.isArray(t))return e;if(E(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=_(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!E(n))continue;const s=F(n.to,n.target,n.actor_id,n.name,n.id),a=F(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Ei(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function K(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}function Di(t,e){if(t!=="dice.rolled")return;const n=j(e.raw_d20,0),s=j(e.total,0),a=j(e.bonus,0),i=_(e.action,"roll"),o=j(e.dc,0);return{notation:o>0?`${i} (DC ${o})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Pi(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Ii(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function ji(t,e,n,s){const a=n||e||_(s.actor_id,"")||_(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=_(s.proposed_action,_(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=_(s.reply,_(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return _(s.reply,_(s.content,_(s.text,"Narration")));case"dice.rolled":{const i=_(s.action,"roll"),o=j(s.total,0),l=j(s.dc,0),u=_(s.label,""),d=a||"actor",p=l>0?` vs DC ${l}`:"",c=u?` (${u})`:"";return`${d} ${i}: ${o}${p}${c}`}case"turn.started":return`Turn ${j(s.turn,1)} started`;case"phase.changed":return`Phase: ${_(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${_(s.name,a||"unknown")}`;case"actor.claimed":return`${_(s.keeper_name,_(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${_(s.keeper_name,_(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${j(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${j(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||_(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||_(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${_(s.reason_code,"unknown")}`;case"memory.signal":{const i=E(s.entity_refs)?s.entity_refs:{},o=_(i.requested_tier,""),l=_(i.effective_tier,""),u=_n(i.guardrail_applied,!1),d=_(s.summary_en,_(s.summary_ko,"Memory signal"));if(!o&&!l)return d;const p=o&&l?`${o}->${l}`:l||o;return`${d} [${p}${u?" (guardrail)":""}]`}case"world.event":{if(_(s.event_type,"")==="canon.check"){const o=_(s.status,"unknown"),l=_(s.contract_id,"n/a");return`Canon ${o}: ${l}`}return _(s.description,_(s.summary,"World event"))}case"combat.attack":return _(s.summary,_(s.result,"Attack resolved"));case"combat.defense":return _(s.summary,_(s.result,"Defense resolved"));case"session.outcome":return _(s.summary,_(s.outcome,"Session ended"));default:{const i=Pi(s);return i?`${t}: ${i}`:t}}}function Mi(t,e){const n=E(t)?t:{},s=_(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=_(n.actor_name,"").trim()||e[a]||_(E(n.payload)?n.payload.actor_name:"",""),o=E(n.payload)?n.payload:{},l=_(n.ts,_(n.timestamp,new Date().toISOString())),u=_(n.phase,_(o.phase,"")),d=_(n.category,"");return{type:s,actor:i||a||_(o.actor_name,""),actor_id:a||_(o.actor_id,""),actor_name:i,seq:n.seq,room_id:_(n.room_id,""),phase:u||void 0,category:d||Ii(s),visibility:_(n.visibility,_(o.visibility,"public")),event_id:_(n.event_id,""),content:ji(s,a,i,o),dice_roll:Di(s,o),timestamp:l}}function Oi(t,e,n){var W,tt;const s=_(t.room_id,"")||n||"default",a=E(t.state)?t.state:{},i=E(a.party)?a.party:{},o=E(a.actor_control)?a.actor_control:{},l=E(a.join_gate)?a.join_gate:{},u=E(a.contribution_ledger)?a.contribution_ledger:{},d=Object.entries(i).map(([T,I])=>{const g=E(I)?I:{},le=K(g,"max_hp",void 0,10),qn=K(g,"hp",void 0,le),Ta=K(g,"max_mp",void 0,0),Na=K(g,"mp",void 0,0),Ra=K(g,"level",void 0,1),La=K(g,"xp",void 0,0),Ea=_n(g.alive,qn>0),Wn=o[T],Jn=typeof Wn=="string"?Wn:void 0,Da=Ei(g.role,T,Jn),Pa=Ri(g.generation),Ia=F(g.joined_at,g.joinedAt,g.started_at,g.startedAt),ja=F(g.claimed_at,g.claimedAt,g.assigned_at,g.assignedAt,g.assigned_time),Ma=F(g.last_seen,g.lastSeen,g.last_seen_at,g.lastSeenAt,g.last_active,g.lastActive),Oa=F(g.scene,g.current_scene,g.currentScene,g.world_scene,g.scene_name,g.sceneName),Fa=F(g.location,g.current_location,g.currentLocation,g.position,g.zone,g.area);return{id:T,name:_(g.name,T),role:Da,keeper:Jn,archetype:_(g.archetype,""),persona:_(g.persona,""),traits:Lt(g.traits),skills:Lt(g.skills),status:Ea?"active":"dead",generation:Pa,joined_at:Ia||void 0,claimed_at:ja||void 0,last_seen:Ma||void 0,scene:Oa||void 0,location:Fa||void 0,inventory:Lt(g.inventory),notes:Lt(g.notes),relationships:Li(g.relationships),stats:{hp:qn,max_hp:le,mp:Na,max_mp:Ta,level:Ra,xp:La,strength:K(g,"strength","str",10),dexterity:K(g,"dexterity","dex",10),constitution:K(g,"constitution","con",10),intelligence:K(g,"intelligence","int",10),wisdom:K(g,"wisdom","wis",10),charisma:K(g,"charisma","cha",10)}}}),p=d.filter(T=>T.status!=="dead"),c=Ni(t,e),v={phase_open:_n(l.phase_open,!0),min_points:j(l.min_points,3),window:_(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},f=Object.entries(u).map(([T,I])=>{const g=E(I)?I:{};return{actor_id:T,score:j(g.score,0),last_reason:_(g.last_reason,"")||null,reasons:Lt(g.reasons)}}),y=d.reduce((T,I)=>(T[I.id]=I.name,T),{}),k=e.map(T=>Mi(T,y)),R=j(a.turn,1),S=_(a.phase,"round"),w=_(a.map,""),O=E(a.world)?a.world:{},H=w||_(O.ascii_map,_(O.map,"")),L=k.filter((T,I)=>{const g=e[I];if(!E(g))return!1;const le=E(g.payload)?g.payload:{};return j(le.turn,-1)===R}),$=(L.length>0?L:k).slice(-12),Q=_(a.status,"active");return{session:{id:s,room:s,status:Q==="ended"?"ended":Q==="paused"?"paused":"active",round:R,actors:p,created_at:((W=k[0])==null?void 0:W.timestamp)??new Date().toISOString()},current_round:{round_number:R,phase:S,events:$,timestamp:((tt=k[k.length-1])==null?void 0:tt.timestamp)??new Date().toISOString()},map:H||void 0,join_gate:v,contribution_ledger:f,outcome:c,party:p,story_log:k,history:[]}}async function Fi(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await ie(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function zi(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([ie(`/api/v1/trpg/state${e}`),Fi(t)]);return Oi(n,s,t)}function ua(t){return re("/api/v1/trpg/rounds/run",{room_id:t})}function Hi(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Ui(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),re("/api/v1/trpg/dice/roll",e)}function Bi(t,e){const n=Hi();return re("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}async function Ki(t,e,n){const s=await z("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function qi(t){const e=await z("trpg.mid_join.request",t);return JSON.parse(e)}async function da(t,e){await z("masc_broadcast",{agent_name:t,message:e})}async function Wi(t,e,n=1){await z("masc_add_task",{title:t,description:e,priority:n})}async function Ji(t){return z("masc_join",{agent_name:t})}async function pa(t){await z("masc_leave",{agent_name:t})}async function Gi(t){await z("masc_heartbeat",{agent_name:t})}async function Vi(t=40){return(await z("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Yi(t,e=20){return z("masc_task_history",{task_id:t,limit:e})}async function Xi(){const t=await z("masc_debates",{});return la(t)}async function Zi(){const t=await z("masc_sessions",{});return la(t)}async function Qi(t){const e=await z("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}function tr(t){return z("masc_debate_status",{debate_id:t})}const Tt=m([]),oe=m([]),va=m([]),Nt=m([]),On=m(null),Et=m(null),gn=m(new Map),fa=m([]),us=m("hot"),Fn=m(null),gt=m(""),$n=m(!1),hn=m(!1),yn=m(!1),er=bt(()=>Tt.value.filter(t=>t.status==="active"||t.status==="idle")),ma=bt(()=>{const t=oe.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function nr(t){var a;const e=t.metrics_series;if(!e||e.length===0){const i=((a=t.status)==null?void 0:a.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const s=n.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const sr=bt(()=>{const t=new Map;for(const e of Nt.value)t.set(e.name,nr(e));return t}),ar=12e4,ir=bt(()=>{const t=Date.now(),e=new Set,n=gn.value;for(const s of Nt.value){const a=n.get(s.name);a!=null&&t-a>ar&&e.add(s.name)}return e}),Te={},rr=5e3;function bn(){delete Te.compact,delete Te.full}function G(t){return typeof t=="object"&&t!==null}function h(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function x(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function jt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function _a(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function or(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function lr(t){if(!G(t))return null;const e=h(t.name);return e?{name:e,status:_a(t.status),current_task:h(t.current_task)??null,last_seen:h(t.last_seen),emoji:h(t.emoji),koreanName:h(t.koreanName)??h(t.korean_name),model:h(t.model),traits:jt(t.traits),interests:jt(t.interests),activityLevel:x(t.activityLevel)??x(t.activity_level),primaryValue:h(t.primaryValue)??h(t.primary_value)}:null}function cr(t){if(!G(t))return null;const e=h(t.id),n=h(t.title);return!e||!n?null:{id:e,title:n,status:or(t.status),priority:x(t.priority),assignee:h(t.assignee),description:h(t.description),created_at:h(t.created_at),updated_at:h(t.updated_at)}}function ur(t){if(!G(t))return null;const e=h(t.from)??h(t.from_agent)??"system",n=h(t.content)??"",s=h(t.timestamp)??new Date().toISOString();return{id:h(t.id),seq:x(t.seq),from:e,content:n,timestamp:s,type:h(t.type)}}function dr(t){return Array.isArray(t)?t.map(e=>{if(!G(e))return null;const n=x(e.ts_unix);if(n==null)return null;const s=G(e.handoff)?e.handoff:null;return{ts:n,context_ratio:x(e.context_ratio)??0,context_tokens:x(e.context_tokens)??0,context_max:x(e.context_max)??0,latency_ms:x(e.latency_ms)??0,generation:x(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:x(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:x(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?x(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function pr(t){return(Array.isArray(t)?t:G(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!G(n))return null;const s=G(n.agent)?n.agent:null,a=G(n.context)?n.context:null,i=G(n.metrics_window)?n.metrics_window:void 0,o=h(n.name);if(!o)return null;const l=x(n.context_ratio)??x(a==null?void 0:a.context_ratio),u=h(n.status)??h(s==null?void 0:s.status)??"offline",d=_a(u),p=h(n.model)??h(n.active_model)??h(n.primary_model),c=jt(n.skill_secondary),v=a?{source:h(a.source),context_ratio:x(a.context_ratio),context_tokens:x(a.context_tokens),context_max:x(a.context_max),message_count:x(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,f=s?{name:h(s.name),status:h(s.status),current_task:h(s.current_task)??null,last_seen:h(s.last_seen)}:void 0,y=dr(n.metrics_series);return{name:o,emoji:h(n.emoji),koreanName:h(n.koreanName)??h(n.korean_name),agent_name:h(n.agent_name),trace_id:h(n.trace_id),model:p,primary_model:h(n.primary_model),active_model:h(n.active_model),next_model_hint:h(n.next_model_hint)??null,status:d,last_heartbeat:h(n.last_heartbeat)??h(s==null?void 0:s.last_seen),generation:x(n.generation),turn_count:x(n.turn_count)??x(n.total_turns),context_ratio:l,context_tokens:x(n.context_tokens)??x(a==null?void 0:a.context_tokens),context_max:x(n.context_max)??x(a==null?void 0:a.context_max),context_source:h(n.context_source)??h(a==null?void 0:a.source),context:v,traits:jt(n.traits),interests:jt(n.interests),primaryValue:h(n.primaryValue)??h(n.primary_value),activityLevel:x(n.activityLevel)??x(n.activity_level),memory_recent_note:h(n.memory_recent_note)??null,conversation_tail_count:x(n.conversation_tail_count),k2k_count:x(n.k2k_count),handoff_count_total:x(n.handoff_count_total)??x(n.trace_history_count),compaction_count:x(n.compaction_count),last_compaction_saved_tokens:x(n.last_compaction_saved_tokens),skill_primary:h(n.skill_primary)??null,skill_secondary:c,skill_reason:h(n.skill_reason)??null,metrics_series:y.length>0?y:void 0,metrics_window:i,agent:f}}).filter(n=>n!==null)}async function Ue(t="full"){var s,a,i;const e=Date.now(),n=Te[t];if(!(n&&e-n.time<rr)){$n.value=!0;try{const o=await wi(t);Te[t]={data:o,time:e},Tt.value=(Array.isArray((s=o.agents)==null?void 0:s.agents)?o.agents.agents:[]).map(lr).filter(l=>l!==null),oe.value=(Array.isArray((a=o.tasks)==null?void 0:a.tasks)?o.tasks.tasks:[]).map(cr).filter(l=>l!==null),va.value=(Array.isArray((i=o.messages)==null?void 0:i.messages)?o.messages.messages:[]).map(ur).filter(l=>l!==null),Nt.value=pr(o.keepers),On.value=G(o.status)?o.status:null,Et.value=o.perpetual??null}catch(o){console.error("Dashboard fetch error:",o)}finally{$n.value=!1}}}async function ut(){hn.value=!0;try{const t=await Si();fa.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{hn.value=!1}}async function st(){var t;yn.value=!0;try{const e=gt.value||((t=On.value)==null?void 0:t.room)||"default";gt.value||(gt.value=e);const n=await zi(e);Fn.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{yn.value=!1}}let qe=null,We=null;function vr(){return ea.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(gn.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),gn.value=n}bn(),qe||(qe=setTimeout(()=>{Ue(),qe=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(We||(We=setTimeout(()=>{ut(),We=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&bn()}})}let Mt=null;function fr(){Mt||(Mt=setInterval(()=>{bn(),Ue()},1e4))}function mr(){Mt&&(clearInterval(Mt),Mt=null)}function A({title:t,class:e,children:n}){return r`
    <div class="card ${e??""}">
      ${t?r`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function it({status:t,label:e}){return r`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function _r(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function B({timestamp:t}){const e=_r(t);return r`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}const zn=m(null);function ga(t){zn.value=t}function ds(){zn.value=null}function ye(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function gr({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return r`
    <div class="keeper-kpis">
      ${a.map(i=>r`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?r`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ye(t.context_tokens)}</div>
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
  `}function $r({keeper:t}){var p,c;const e=t.metrics_series??[];if(e.length<2){const v=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,f=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return r`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${f}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,o=e.map((v,f)=>{const y=a+f/(i-1)*(n-2*a),k=s-a-(v.context_ratio??0)*(s-2*a);return{x:y,y:k,p:v}}),l=o.map(({x:v,y:f})=>`${v.toFixed(1)},${f.toFixed(1)}`).join(" "),u=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,d=u>85?"#ef4444":u>70?"#f59e0b":"#22c55e";return r`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${o.filter(({p:v})=>v.is_handoff).map(({x:v})=>r`
          <line x1="${v.toFixed(1)}" y1="${a}" x2="${v.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${d}" stroke-width="1.5"/>
        ${o.filter(({p:v})=>v.is_compaction).map(({x:v,y:f})=>r`
          <circle cx="${v.toFixed(1)}" cy="${f.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${u.toFixed(1)}%</span>
    </div>`}const Je=m("");function hr({keeper:t}){var a,i,o,l;const e=Je.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(u=>u.title.toLowerCase().includes(e)||u.key.includes(e)||u.value.toLowerCase().includes(e)):n;return r`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Je.value}
        onInput=${u=>{Je.value=u.target.value}}
      />
      ${s.map(u=>r`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${u.title}</span>
          <span class="keeper-field-key">${u.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${u.value}</span>
        </div>
      `)}
      ${t.trace_id?r`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${t.trace_id}</span></div>`:""}
      ${t.agent_name?r`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${t.agent_name}</span></div>`:""}
      ${t.primary_model?r`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.primary_model}</span></div>`:""}
      ${t.active_model?r`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.active_model}</span></div>`:""}
      ${t.next_model_hint?r`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.next_model_hint}</span></div>`:""}
      ${t.skill_primary?r`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_primary}</span></div>`:""}
      ${t.skill_secondary?r`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_secondary}</span></div>`:""}
      ${t.skill_reason?r`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_reason}</span></div>`:""}
      ${t.context_source?r`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${t.context_source}</span></div>`:""}
      ${t.context_tokens!=null?r`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ye(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?r`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ye(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?r`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?r`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?r`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?r`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?r`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?r`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ye(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((o=t.context)==null?void 0:o.message_count)!=null?r`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?r`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function yr({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return r`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(s=>r`
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
  `}function br({items:t}){return t.length===0?r`<div class="empty-state" style="font-size:13px">No equipment</div>`:r`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>r`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function kr({rels:t}){const e=Object.entries(t);return e.length===0?r`<div class="empty-state" style="font-size:13px">No relationships</div>`:r`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>r`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function ps({traits:t,label:e}){return t.length===0?null:r`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>r`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Ge(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function xr({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Ge(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Ge(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Ge(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return r`
    <div class="keeper-signal-list">
      ${n.map(s=>r`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function wr({keeperName:t}){const[e,n]=ue("Loading internal monologue..."),[s,a]=ue(""),[i,o]=ue([]),[l,u]=ue(!1),d=async()=>{try{const c=await z("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof c=="string"?c:JSON.stringify(c,null,2))}catch(c){n("Failed to load: "+String(c))}};yt(()=>{d()},[t]);const p=async()=>{if(!s.trim())return;u(!0);const c=s;a(""),o(v=>[...v,{role:"You",text:c}]);try{const v=await z("masc_keeper_msg",{name:t,message:c});o(f=>[...f,{role:t,text:typeof v=="string"?v:JSON.stringify(v)}]),d()}catch(v){o(f=>[...f,{role:"System",text:"Error: "+String(v)}])}finally{u(!1)}};return r`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Inner Monologue</h3>
      
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <!-- Chat Area -->
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <div style="background: rgba(0,0,0,0.3); border: 1px solid var(--border); border-radius: 12px; height: 300px; overflow-y: auto; padding: 12px; display: flex; flex-direction: column; gap: 8px; font-size: 0.85rem;">
            ${i.length===0?r`<div style="color: var(--text-muted); font-style: italic;">No direct messages yet.</div>`:null}
            ${i.map(c=>r`
              <div style="padding: 8px; border-radius: 8px; background: ${c.role==="You"?"rgba(0, 240, 255, 0.1)":"rgba(255, 255, 255, 0.05)"}; border-left: 2px solid ${c.role==="You"?"var(--accent-cyan)":"var(--text-muted)"};">
                <strong style="color: ${c.role==="You"?"var(--accent-cyan)":"var(--text-primary)"}; display: block; margin-bottom: 4px;">${c.role}</strong>
                <span style="white-space: pre-wrap;">${c.text}</span>
              </div>
            `)}
          </div>
          <div style="display: flex; gap: 8px;">
            <input 
              type="text" 
              value=${s} 
              onInput=${c=>a(c.target.value)} 
              onKeyDown=${c=>c.key==="Enter"&&!c.shiftKey&&p()}
              placeholder="Ping the agent..."
              disabled=${l}
              style="flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--text-primary); font-family: var(--font-body);"
            />
            <button 
              onClick=${p} 
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
  `}function Sr(){var e,n,s;const t=zn.value;return t?r`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&ds()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?r`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${it} status=${t.status} />
            ${t.model?r`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>ds()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${gr} keeper=${t} />

        ${""}
        <${$r} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${A} title="Field Dictionary">
            <${hr} keeper=${t} />
          <//>

          ${""}
          <${A} title="Profile">
            <${ps} traits=${t.traits??[]} label="Traits" />
            <${ps} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?r`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?r`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?r`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?r`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${B} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.trpg_stats?r`
              <${A} title="TRPG Stats">
                <${yr} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?r`
              <${A} title="Equipment (${t.inventory.length})">
                <${br} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?r`
              <${A} title="Relationships (${Object.keys(t.relationships).length})">
                <${kr} rels=${t.relationships} />
              <//>
            `:null}

          <${A} title="Runtime Signals">
            <${xr} keeper=${t} />
          <//>

          <${A} title="Memory & Context">
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
              ${t.memory_recent_note?r`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:r`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${wr} keeperName=${t.name} />
      </div>
    </div>
  `:null}let Cr=0;const lt=m([]);function b(t,e="success",n=4e3){const s=++Cr;lt.value=[...lt.value,{id:s,message:t,type:e}],setTimeout(()=>{lt.value=lt.value.filter(a=>a.id!==s)},n)}function Ar(t){lt.value=lt.value.filter(e=>e.id!==t)}function Tr(){const t=lt.value;return t.length===0?null:r`
    <div class="toast-container">
      ${t.map(e=>r`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Ar(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Nr="masc_dashboard_agent_name",Rt=m(null),Ne=m(!1),ee=m(""),Re=m([]),ne=m([]),$t=m(""),Ot=m(!1);function $a(t){Rt.value=t,Hn()}function vs(){Rt.value=null,ee.value="",Re.value=[],ne.value=[],$t.value=""}function Rr(){const t=Rt.value;return t?Tt.value.find(e=>e.name===t)??null:null}function ha(t){return t?oe.value.filter(e=>e.assignee===t):[]}async function Hn(){const t=Rt.value;if(t){Ne.value=!0,ee.value="",Re.value=[],ne.value=[];try{const e=await Vi(80);Re.value=e.filter(a=>a.includes(t)).slice(0,20);const n=ha(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await Yi(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const o=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${o}`}}}));ne.value=s}catch(e){ee.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ne.value=!1}}}async function fs(){var s;const t=Rt.value,e=$t.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Nr))==null?void 0:s.trim())||"dashboard";Ot.value=!0;try{await da(n,`@${t} ${e}`),$t.value="",b(`Mention sent to ${t}`,"success"),Hn()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";b(i,"error")}finally{Ot.value=!1}}function Lr({task:t}){return r`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${it} status=${t.status} />
    </div>
  `}function Er({row:t}){return r`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Dr(){var a,i,o,l;const t=Rt.value;if(!t)return null;const e=Rr(),n=ha(t),s=Re.value;return r`
    <div
      class="agent-detail-overlay"
      onClick=${u=>{u.target.classList.contains("agent-detail-overlay")&&vs()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${e!=null&&e.emoji?r`<span style="font-size:2rem">${e.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${t}
                  ${e!=null&&e.koreanName?r`<span style="font-size:0.75em;color:#888">(${e.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${e?r`
                        <${it} status=${e.status} />
                        ${e.model?r`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                        ${e.primaryValue?r`<span style="font-size:0.75rem;color:#a78bfa">${e.primaryValue}</span>`:""}
                      `:r`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(e==null?void 0:e.activityLevel)!=null?r`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(e.activityLevel*10,100)}%;height:100%;background:${e.activityLevel>=8?"#22c55e":e.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${e.activityLevel}/10</span>
              </div>
            `:""}
            ${(((a=e==null?void 0:e.traits)==null?void 0:a.length)??0)>0?r`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(u=>r`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            ${(((o=e==null?void 0:e.interests)==null?void 0:o.length)??0)>0?r`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(l=e==null?void 0:e.interests)==null?void 0:l.map(u=>r`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?r`
                    ${e.current_task?r`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?r`<span>Last seen: <${B} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Hn()}} disabled=${Ne.value}>
              ${Ne.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${vs}>Close</button>
          </div>
        </div>

        ${ee.value?r`<div class="council-error">${ee.value}</div>`:null}

        <div class="agent-detail-grid">
          <${A} title="Assigned Tasks">
            ${n.length===0?r`<div class="empty-state">No assigned tasks</div>`:r`<div class="agent-detail-task-list">${n.map(u=>r`<${Lr} key=${u.id} task=${u} />`)}</div>`}
          <//>

          <${A} title="Recent Activity">
            ${s.length===0?r`<div class="empty-state">No recent room activity match</div>`:r`<div class="agent-activity-list">${s.map((u,d)=>r`<div key=${d} class="agent-activity-line">${u}</div>`)}</div>`}
          <//>
        </div>

        <${A} title="Task History">
          ${ne.value.length===0?r`<div class="empty-state">No task history loaded</div>`:r`<div class="agent-history-list">${ne.value.map(u=>r`<${Er} key=${u.taskId} row=${u} />`)}</div>`}
        <//>

        <${A} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${$t.value}
              onInput=${u=>{$t.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&fs()}}
              disabled=${Ot.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{fs()}}
              disabled=${Ot.value||$t.value.trim()===""}
            >
              ${Ot.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function dt({label:t,value:e,color:n}){return r`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function Pr({agent:t}){return r`
    <div class="agent" onClick=${()=>$a(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${it} status=${t.status} />
      ${t.current_task?r`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function Ir(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function jr(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function ms(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function Mr({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=sr.value.get(t.name),a=ir.value.has(t.name);return r`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>ga(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${it} status=${t.status} />
          ${s?r`<span class="pill pill-lifecycle pill-lifecycle-${s}">${s}</span>`:null}
          ${a?r`<span class="pill pill-stale">stale</span>`:null}
          ${t.model?r`<span class="pill">${t.model}</span>`:null}
          ${t.skill_primary?r`<span class="pill pill-skill">${t.skill_primary}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>

        <!-- Row 2: Context bar -->
        ${e!=null?r`
          <div class="keeper-ctx-row">
            <div class="keeper-ctx-bar">
              <div class="keeper-ctx-fill ${ms(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${ms(e)}">
              ${n}%
              ${t.context_tokens!=null?r` (${Ir(t.context_tokens)})`:null}
            </span>
          </div>
        `:null}

        <!-- Row 3: Operational metrics -->
        ${t.generation!=null?r`
          <div class="keeper-metrics-row">
            <span>Gen ${t.generation}</span>
            <span>T${t.turn_count??0}</span>
            ${(t.handoff_count_total??0)>0?r`<span class="keeper-metric-hl">↻${t.handoff_count_total}</span>`:null}
            ${(t.compaction_count??0)>0?r`<span class="keeper-metric-compact">◆${t.compaction_count}</span>`:null}
            ${(t.k2k_count??0)>0?r`<span>K2K:${t.k2k_count}</span>`:null}
            ${(t.conversation_tail_count??0)>0?r`<span>💬${t.conversation_tail_count}</span>`:null}
          </div>
        `:null}

        <!-- Row 4: Heartbeat freshness -->
        ${t.last_heartbeat?r`
          <div class="keeper-heartbeat-row">
            <span class="keeper-heartbeat-dot ${t.status==="active"?"pulse":""}"></span>
            <${B} timestamp=${t.last_heartbeat} />
          </div>
        `:null}

        <!-- Row 5: Trait chips -->
        ${t.traits&&t.traits.length>0?r`
          <div class="keeper-trait-row">
            ${t.traits.slice(0,3).map(i=>r`<span class="keeper-trait-chip">${i}</span>`)}
            ${t.traits.length>3?r`<span class="keeper-trait-more">+${t.traits.length-3}</span>`:null}
          </div>
        `:null}

        <!-- Row 6: Memory note preview -->
        ${t.memory_recent_note?r`
          <div class="keeper-note-preview">${jr(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function _s(){const t=On.value,e=Tt.value,n=Nt.value,s=ma.value;return r`
    <div class="stats-grid">
      <${dt} label="Agents" value=${e.length} />
      <${dt} label="Active" value=${er.value.length} color="#4ade80" />
      <${dt} label="Keepers" value=${n.length} color="#22d3ee" />
      <${dt} label="Tasks" value=${oe.value.length} />
      <${dt} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${dt} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${A} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?r`<div class="empty-state">No agents connected</div>`:e.map(a=>r`<${Pr} key=${a.name} agent=${a} />`)}
        </div>
      <//>

      <${A} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?r`<div class="empty-state">No keepers active</div>`:n.map(a=>r`<${Mr} key=${a.name} keeper=${a} />`)}
        </div>
      <//>
    </div>

    ${Et.value?r`
        <${A} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${Et.value.running?"Running":"Stopped"}</span>
            ${Et.value.goal?r`<span>Goal: ${Et.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?r`
        <${A} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?r`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?r`<span>Project: ${t.project}</span>`:null}
            ${t.version?r`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${Or(t.uptime_seconds??0)}</span>
            ${t.paused?r`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?r`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?r`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
          </div>
        <//>
      `:null}
  `}function Or(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}const kn=m([]),xn=m([]),Ft=m(""),Le=m(!1),zt=m(!1),Ee=m(""),De=m(null),Ht=m(""),wn=m(!1);async function Sn(){Le.value=!0,Ee.value="";try{const[t,e]=await Promise.all([Xi(),Zi()]);kn.value=t,xn.value=e}catch(t){Ee.value=t instanceof Error?t.message:"Failed to load council data"}finally{Le.value=!1}}async function gs(){const t=Ft.value.trim();if(t){zt.value=!0;try{const e=await Qi(t);Ft.value="",b(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Sn()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";b(n,"error")}finally{zt.value=!1}}}async function Fr(t){De.value=t,wn.value=!0,Ht.value="";try{Ht.value=await tr(t)}catch(e){Ht.value=e instanceof Error?e.message:"Failed to load debate status"}finally{wn.value=!1}}function zr({debate:t}){const e=De.value===t.id;return r`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Fr(t.id)}
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
  `}function Hr({session:t}){return r`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function Ur(){return yt(()=>{Sn()},[]),r`
    <div>
      <${A} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Ft.value}
            onInput=${t=>{Ft.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&gs()}}
            disabled=${zt.value}
          />
          <button
            class="control-btn secondary"
            onClick=${gs}
            disabled=${zt.value||Ft.value.trim()===""}
          >
            ${zt.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Sn} disabled=${Le.value}>
            ${Le.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Ee.value?r`<div class="council-error">${Ee.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${A} title="Debates" class="section">
          <div class="council-list">
            ${kn.value.length===0?r`<div class="empty-state">No debates yet</div>`:kn.value.map(t=>r`<${zr} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${A} title="Voting Sessions" class="section">
          <div class="council-list">
            ${xn.value.length===0?r`<div class="empty-state">No active sessions</div>`:xn.value.map(t=>r`<${Hr} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${A} title=${De.value?`Debate Detail (${De.value})`:"Debate Detail"} class="section">
        ${wn.value?r`<div class="loading-indicator">Loading debate detail...</div>`:Ht.value?r`<pre class="council-detail">${Ht.value}</pre>`:r`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Br({text:t}){if(!t)return null;const e=Kr(t);return r`<div class="markdown-content">${e}</div>`}function Kr(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const o=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(o.length).trim(),u=[];for(s++;s<e.length&&!e[s].startsWith(o);)u.push(e[s]),s++;s++,n.push(r`<pre><code class=${l?`language-${l}`:""}>${u.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const o=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&o.push(l),s++;s<e.length&&!e[s].includes("</think>");)o.push(e[s]),s++;if(s<e.length){const d=e[s].replace("</think>","").trim();d&&o.push(d),s++}const u=o.join(`
`).trim();n.push(r`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ve(u)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const o=[];for(;s<e.length&&e[s].startsWith("> ");)o.push(e[s].slice(2)),s++;n.push(r`<blockquote>${Ve(o.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const o=e[s];if(o.trim()===""||/^(`{3,}|~{3,})/.test(o)||o.startsWith("> ")||o.trim().startsWith("<think>"))break;i.push(o),s++}i.length>0&&n.push(r`<p>${Ve(i.join(`
`))}</p>`)}return n}function Ve(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(r`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(r`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(r`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(r`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const qr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Ut=m([]),Bt=m(!1),Kt=m(""),Wr=m("dashboard-user"),qt=m(!1);async function ya(t){Bt.value=!0,Ut.value=[];try{const e=await Ci(t);Ut.value=e.comments??[]}catch{}finally{Bt.value=!1}}async function $s(t){const e=Kt.value.trim();if(e){qt.value=!0;try{await Ai(t,Wr.value,e),Kt.value="",b("Comment posted","success"),await ya(t),ut()}catch{b("Failed to post comment","error")}finally{qt.value=!1}}}function Jr(){const t=us.value;return r`
    <div class="board-controls">
      ${qr.map(e=>r`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{us.value=e.id,ut()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function ba({flair:t}){return t?r`<span class="post-flair ${t}">${t}</span>`:null}function Gr({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await ca(t.id,n),ut()}catch{b("Failed to vote","error")}};return r`
    <div class="board-post" onClick=${()=>oi(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${ba} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${B} timestamp=${t.created_at} />
          ${t.comment_count>0?r`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?r`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function Vr({comments:t}){return t.length===0?r`<div class="empty-state" style="font-size:13px">No comments yet</div>`:r`
    <div class="comment-thread">
      ${t.map(e=>r`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${B} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Yr({postId:t}){return r`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Kt.value}
        onInput=${e=>{Kt.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&$s(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${qt.value}
      />
      <button
        onClick=${()=>$s(t)}
        disabled=${qt.value||Kt.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${qt.value?"...":"Post"}
      </button>
    </div>
  `}function Xr({post:t}){Ut.value.length===0&&!Bt.value&&ya(t.id);const e=async n=>{try{await ca(t.id,n),ut()}catch{b("Failed to vote","error")}};return r`
    <div>
      <button class="back-btn" onClick=${()=>He("board")}>← Back to Board</button>
      <${A} title=${r`${t.title} <${ba} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Br} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${B} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?r`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${A} title="Comments (${Bt.value?"...":Ut.value.length})">
        ${Bt.value?r`<div class="loading-indicator">Loading comments...</div>`:r`<${Vr} comments=${Ut.value} />`}
        <${Yr} postId=${t.id} />
      <//>
    </div>
  `}function Zr(){const t=fa.value,e=hn.value,n=Z.value.postId;if(n){const s=t.find(a=>a.id===n);return s?r`<${Xr} post=${s} />`:r`
          <div>
            <button class="back-btn" onClick=${()=>He("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return r`
    <${Jr} />
    ${e?r`<div class="loading-indicator">Loading board...</div>`:t.length===0?r`<div class="empty-state">No posts yet</div>`:r`<div class="board-post-list">
            ${t.map(s=>r`<${Gr} key=${s.id} post=${s} />`)}
          </div>`}
  `}function Qr(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function to(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function hs(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function eo({row:t}){const e=new Date(t.timestamp),n=isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1});return r`
    <div class="term-row">
      <span class="term-time">${n}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-source ${t.source}">${t.source==="message"?"msg":"evt"}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function no(){const t=va.value.map(Qr),e=Ae.value.map(to),n=[...t,...e].sort((s,a)=>hs(a.timestamp)-hs(s.timestamp)).slice(0,100);return r`
    <div class="section">
      <h2 style="color: var(--accent); text-shadow: 0 0 10px rgba(0,240,255,0.5); margin-bottom: 16px; font-family: monospace;">> LIVE_ACTIVITY_STREAM</h2>
      <div class="terminal-feed">
        ${n.length===0?r`<div class="empty-state" style="font-family: monospace; color: var(--ok);">> Waiting for signal...</div>`:n.map(s=>r`<${eo} key=${s.id} row=${s} />`)}
      </div>
    </div>
  `}function ka({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,o=i*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),r`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${l}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${o}" 
        />
      </svg>
      <span class="mitosis-text ${l}">${Math.round(t*100)}%</span>
    </div>
  `}const so={born_at:{label:"Born",description:"Keeper 메타가 생성된 시각입니다.",sourcePath:"keepers[].created_at",interpretation:"최근 생성일수록 신규 Keeper입니다."},generation:{label:"Generation",description:"승계/핸드오프를 거치며 누적된 세대 번호입니다.",sourcePath:"keepers[].generation",interpretation:"값이 높을수록 세대 전환을 더 많이 경험했습니다."},status:{label:"Status",description:"현재 실행 상태입니다.",sourcePath:"keepers[].status",interpretation:"active/idle은 동작 중, offline/inactive는 비활성 상태입니다."},recent_activity:{label:"Recent",description:"가장 최근 변화/행동 요약입니다.",sourcePath:"keepers[].last_drift_reason | keepers[].last_proactive_reason | keepers[].memory_recent_note",formula:"first_non_null(last_drift_reason, last_proactive_reason, memory_recent_note)",interpretation:"최근 어떤 일을 했는지 한 줄로 파악합니다."},relations:{label:"Relations",description:"다른 Keeper와의 최근 상호작용 빈도입니다.",sourcePath:"keepers[].k2k_count, keepers[].k2k_mentions",formula:"k2k_count + top(k2k_mentions)",interpretation:"값이 높을수록 협업/호출이 잦습니다."},personality_change:{label:"Personality Change",description:"성향 변화 추세를 드리프트 지표로 요약한 값입니다.",sourcePath:"keepers[].drift_count_total, keepers[].metrics_window.goal_drift_avg",formula:"drift_count_total + goal_drift_avg",interpretation:"높을수록 최근 성향/목표 정렬 변화가 컸습니다."}};function ao(t){return so[t]}function pt({metric:t}){const e=ao(t);return r`
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
        ${e.formula?r`<span><code>formula:</code> ${e.formula}</span>`:null}
        <span><code>source:</code> ${e.sourcePath}</span>
        ${e.interpretation?r`<span>${e.interpretation}</span>`:null}
      </span>
    </span>
  `}function io({agent:t}){return r`
    <button class="agent-card ${t.status}" onClick=${()=>$a(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?r`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${ka} ratio=${t.context_ratio} />
        <${it} status=${t.status} />
      </div>
      ${t.current_task?r`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?r`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function ro(t){return typeof t!="number"||Number.isNaN(t)?null:`${Math.round(t*100)}%`}function oo(t){var a,i,o;const e=(a=t.last_drift_reason)==null?void 0:a.trim();if(e)return e;const n=(i=t.last_proactive_reason)==null?void 0:i.trim();if(n)return n;const s=(o=t.memory_recent_note)==null?void 0:o.trim();return s||"—"}function lo(t){var s;const e=t.k2k_count??0,n=(s=t.k2k_mentions)==null?void 0:s[0];return n?`${e} · ${n.keeper}(${n.count})`:String(e)}function co(t){var s;const e=t.drift_count_total??0,n=ro((s=t.metrics_window)==null?void 0:s.goal_drift_avg);return e===0&&!n?"Stable":n?`Drift ${e} · Δ${n}`:`Drift ${e}`}function uo({keeper:t}){var a;const e=oo(t),n=lo(t),s=co(t);return r`
    <div class="live-agent keeper-card" onClick=${()=>ga(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${ka} ratio=${t.context_ratio} />
        <${it} status=${t.status} />
          ${t.model?r`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?r`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Born <${pt} metric="born_at" /></span>
            <strong class="keeper-core-value">
              ${t.created_at?r`<${B} timestamp=${t.created_at} />`:"—"}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Gen <${pt} metric="generation" /></span>
            <strong class="keeper-core-value">${t.generation??"—"}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Status <${pt} metric="status" /></span>
            <strong class="keeper-core-value">${t.status}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Relations <${pt} metric="relations" /></span>
            <strong class="keeper-core-value">${n}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Recent <${pt} metric="recent_activity" /></span>
            <strong class="keeper-core-value keeper-core-text">${e}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Personality <${pt} metric="personality_change" /></span>
            <strong class="keeper-core-value">${s}</strong>
          </div>
        </div>

        <!-- Inner Information Section -->
        <div class="keeper-inner-info">
          ${(a=t.agent)!=null&&a.current_task?r`
            <div class="keeper-detail-row">
              <span class="keeper-label">Task</span>
              <span class="keeper-value">${t.agent.current_task}</span>
            </div>
          `:null}
          ${t.will?r`
            <div class="keeper-detail-row">
              <span class="keeper-label">Will (의지)</span>
              <span class="keeper-value">${t.will}</span>
            </div>
          `:null}
          ${t.needs?r`
            <div class="keeper-detail-row">
              <span class="keeper-label">Needs (니즈)</span>
              <span class="keeper-value">${t.needs}</span>
            </div>
          `:null}
          ${t.desires?r`
            <div class="keeper-detail-row">
              <span class="keeper-label">Desires (욕구)</span>
              <span class="keeper-value">${t.desires}</span>
            </div>
          `:null}
          ${t.memory_recent_note?r`
            <div class="keeper-detail-row">
              <span class="keeper-label">Memory Note</span>
              <span class="keeper-value memory-note">"${t.memory_recent_note}"</span>
            </div>
          `:null}
        </div>
      </div>
    </div>
  `}function po(){const t=Tt.value,e=Nt.value;return r`
    <div>
      ${e.length>0?r`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>r`<${uo} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?r`<div class="empty-state">No agents registered</div>`:r`
            <div class="agent-grid">
              ${t.map(n=>r`<${io} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Ye({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return r`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?r`<${B} timestamp=${t.created_at} />`:r`<span>-</span>`}
        ${t.assignee?r`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function vo(){const{todo:t,inProgress:e,done:n}=ma.value;return r`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?r`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>r`<${Ye} key=${s.id} task=${s} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?r`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>r`<${Ye} key=${s.id} task=${s} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?r`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>r`<${Ye} key=${s.id} task=${s} />`)}
        ${n.length>20?r`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function fo({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",s=t.message??t.content??t.status??"";return r`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${s}</span>
    </div>
  `}function mo(){const t=Ae.value;return r`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?r`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>r`<${fo} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const ft=m(""),xt=m(""),pe=m(""),Xe=m("all"),ve=m(!1),wt=m(!1),Un=m(""),be=m(!1),Wt=m(0),Cn=m(null),Ze=m("ability_check"),Qe=m("10"),tn=m("12"),fe=m(""),me=m("idle"),_e=m(""),ge=m("keeper-late"),en=m("player"),nn=m(""),q=m("idle"),sn=m(null),Pe=m(null);function _o(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function go(t,e){return e>0?Math.round(t/e*100):0}const $o={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},ho={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Jt(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function xa(t){const e=t.trim().toLowerCase();return $o[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function wa(t){const e=t.trim().toLowerCase();return ho[e]??"상황에 따라 선택되는 전술 액션입니다."}function at(t){return typeof t=="object"&&t!==null}function Dt(t){return typeof t=="string"?t.trim():""}function vt(t){const e=t.trim();return e&&(/[A-Z]/.test(e)&&!e.includes(" ")?e.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():e.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())}function ys(t){return t.trim().toLowerCase().replace(/[\s_-]+/g," ").replace(/\s+/g," ")}function yo(t){const e=new Set,n=[];for(const s of t){const a=s.trim();if(!a)continue;const i=a.toLowerCase();e.has(i)||(e.add(i),n.push(a))}return n}function U(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Y(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function St(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}function Sa(t,e){const n=e.trim();if(n)return t.find(s=>s.id===n)}function An(t,e){const n=(t.actor_id??"").trim();if(n)return n;const s=(t.actor??"").trim(),a=(t.actor_name??s??"").trim();if(!a)return"";const i=e.find(p=>p.name===a);if(i)return i.id;const o=a.toLowerCase(),l=e.find(p=>p.name.toLowerCase()===o);if(l)return l.id;const u=e.find(p=>p.name.replace(/[\s_-]+/g,"").toLowerCase()===a.replace(/[\s_-]+/g,"").toLowerCase());if(u)return u.id;const d=e.find(p=>ys(p.name).includes(ys(a)));return(d==null?void 0:d.id)??""}function an(t){const e=t.type.trim().toLowerCase();return e?t.category?t.category.trim().toLowerCase():e.includes("dice.")?"dice":e.includes("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Tn(t){const e=t.trim();e&&(xt.value=xt.value===e?"":e)}function ke(){xt.value=""}function Ie(){const t=Cn.value;t&&(clearInterval(t),Cn.value=null),wt.value=!1,Un.value="",be.value=!1,Wt.value=0}async function bs(t){if(!(!wt.value||be.value)&&Un.value===t){be.value=!0;try{const e=await ua(t);Pe.value=e;const n=at(e.summary)?e.summary:null,s=n?St(n,"advanced",!1):!1;if(Wt.value=0,await st(),!s){const a=n?U(n,"progress_reason",""):"session stalled";b(`Auto run stopped: ${a||"session stalled"}`,"warning"),Ie()}}catch(e){const n=Wt.value+1;if(Wt.value=n,n>=3){b("Auto run stopped: repeated round failures","error"),Ie();return}const s=e instanceof Error?e.message:"Round failed";b(`Auto run retry (${n}/3): ${s}`,"warning")}finally{be.value=!1}}}function bo(t){!t||wt.value||(Un.value=t,wt.value=!0,Wt.value=0,bs(t),Cn.value=setInterval(()=>{bs(t)},1500))}function ko(t){return t?Object.entries(t).filter(([e,n])=>e.trim()!==""&&n.trim()!=="").sort(([e],[n])=>e.localeCompare(n)):[]}function rn(t,e="n/a"){return t?r`<${B} timestamp=${t} />`:e}function xo(t,e){if(e){if(e.winner_actor_id){const n=Sa(t,e.winner_actor_id);return n?n.name:e.winner_actor_id}if(e.winner)return e.winner}}function wo(t,e){const s=((t==null?void 0:t.evidence)??[]).map(i=>Dt(i)).map(i=>{if(!i)return"";const o=(e.story_log??[]).find(l=>l.event_id===i||Dt(l.content).toLowerCase().includes(i.toLowerCase()));return o?Dt(o.content):i}).filter(Boolean),a=(e.story_log??[]).filter(i=>i.type==="session.outcome").map(i=>Dt(i.content)).filter(Boolean);return yo([...s,...a])}function Ca({hp:t,max:e}){const n=go(t,e),s=_o(t,e);return r`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Aa({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return r`
    <div class="trpg-actor-stats">
      ${e.map(n=>r`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function So({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return r`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Co({actor:t}){var c,v,f,y;const e=(c=t.archetype)==null?void 0:c.trim(),n=(v=t.persona)==null?void 0:v.trim(),s=t.traits??[],a=t.skills??[],i=(f=t.scene)==null?void 0:f.trim(),o=(y=t.location)==null?void 0:y.trim(),l=t.generation,d=[l==null?"":`Gen ${l}`,i?`Scene: ${i}`:"",o?`Loc: ${o}`:""].filter(Boolean),p=t.id===xt.value;return r`
    <div
      class="trpg-actor trpg-actor-clickable ${p?"trpg-actor-selected":""}"
      role="button"
      tabindex="0"
      onClick=${()=>{Tn(t.id)}}
      onKeyDown=${k=>{(k.key==="Enter"||k.key===" ")&&(k.preventDefault(),Tn(t.id))}}
    >
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${it} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${So} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?r`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?r`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Ca} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Aa} stats=${t.stats} />
          </div>
        `:null}
      ${e?r`<div class="trpg-actor-meta">Archetype: ${Jt(e)}</div>`:null}
      ${d.length>0?r`<div class="trpg-actor-meta">${d.join(" · ")}</div>`:null}
      ${n?r`<div class="trpg-actor-persona">${n}</div>`:null}
      ${s.length>0?r`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${s.map(k=>r`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Jt(k)}</span>
                  <span class="trpg-annot-desc">${xa(k)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${a.length>0?r`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${a.map(k=>r`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Jt(k)}</span>
                  <span class="trpg-annot-desc">${wa(k)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Ao(){var S,w,O,H,L;const t=Fn.value;if(!t)return null;const e=Sa(t.party??[],xt.value);if(!e)return null;const n=t.story_log??[],s=t.party??[],a=n.filter($=>An($,s)===e.id).slice(-9),i=a.filter($=>$.type==="actor.claimed"||$.type==="actor.released"||$.type==="actor.spawned"),o=a.filter($=>$.type==="turn.action.proposed"||$.type==="turn.action.resolved"||$.type==="narration.posted").slice(-4),l=(t.contribution_ledger??[]).find($=>$.actor_id===e.id),u=e.role?e.role.toUpperCase():"Unknown",d=e.inventory??[],p=e.notes??[],c=ko(e.relationships),v=(S=e.joined_at)==null?void 0:S.trim(),f=(w=e.claimed_at)==null?void 0:w.trim(),y=(O=e.last_seen)==null?void 0:O.trim(),k=(H=e.scene)==null?void 0:H.trim(),R=(L=e.location)==null?void 0:L.trim();return r`
    <div
      class="trpg-actor-overlay"
      tabIndex={-1}
      onClick=${$=>{$.target.classList.contains("trpg-actor-overlay")&&ke()}}
      onKeyDown=${$=>{$.key==="Escape"&&($.preventDefault(),ke())}}
    >
      <div class="trpg-actor-detail">
        <div class="trpg-actor-detail-header">
          <div>
            <div class="trpg-actor-name trpg-actor-detail-name">${e.name}</div>
            <div class="trpg-actor-detail-meta">
              <span class="trpg-detail-kv"><strong>ID</strong> ${e.id}</span>
              <span class="trpg-detail-kv"><strong>Role</strong> ${u}</span>
              <span class="trpg-detail-kv"><strong>Status</strong> ${e.status}</span>
              <span class="trpg-detail-kv">
                <strong>Generation</strong>
                ${e.generation==null?"unknown":e.generation}
              </span>
              <span class="trpg-detail-kv"><strong>Keeper</strong> ${e.keeper||"unassigned"}</span>
              <span class="trpg-detail-kv"><strong>Joined</strong> ${rn(v)}</span>
              <span class="trpg-detail-kv"><strong>Claimed</strong> ${rn(f)}</span>
              <span class="trpg-detail-kv"><strong>Last seen</strong> ${rn(y)}</span>
              <span class="trpg-detail-kv">
                <strong>Scene / Loc</strong>
                ${k||R?`${k??"-"} / ${R??"-"}`:"n/a"}
              </span>
              ${l?r`<span>contribution: ${l.score}</span>`:null}
            </div>
            ${e.persona?r`<div class="trpg-actor-persona">${e.persona}</div>`:null}
          </div>
          <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
            <button
              class="control-btn secondary"
              onClick=${()=>{ft.value=e.id,b("Actor selected for controls","success")}}
            >
              Set as action actor
            </button>
            <button class="control-btn ghost" onClick=${ke}>Close</button>
          </div>
        </div>

        ${e.stats?r`
          <div style="margin-top:8px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#9ca3af; margin-bottom:8px;">
              HP ${e.stats.hp}/${e.stats.max_hp}
              ${e.stats.max_mp>0?r`<span style="margin-left:8px;">MP ${e.stats.mp}/${e.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${e.stats.level}</span>
            </div>
            <${Ca} hp=${e.stats.hp} max=${e.stats.max_hp} />
            <${Aa} stats=${e.stats} />
          </div>
        `:null}

        ${i.length>0?r`
            <details class="trpg-detail-section">
              <summary class="trpg-detail-summary">Keeper history</summary>
              <div>
                <div class="trpg-story">
                  ${i.map($=>r`
                    <div class="trpg-event">
                      <div class="trpg-event-main">
                        <span class="trpg-event-text">${Dt($.content)}</span>
                      </div>
                      <div class="trpg-event-meta-row">
                        <span class="trpg-event-ts">
                          <${B} timestamp=${$.timestamp} />
                        </span>
                      </div>
                    </div>
                  `)}
                </div>
              </div>
            </details>
          `:null}

        ${l?r`
            <details class="trpg-detail-section">
              <summary class="trpg-detail-summary">Contribution</summary>
              <div>
                <div class="trpg-detail-kv-group">
                  <span class="trpg-detail-kv"><strong>Score</strong> ${l.score}</span>
                  ${l.last_reason?r`<span class="trpg-detail-kv"><strong>Last reason</strong> ${l.last_reason}</span>`:null}
                </div>
                ${(l.reasons??[]).length>0?r`
                    <details class="trpg-detail-section" style="margin-top:6px;">
                      <summary class="trpg-detail-summary">Contribution reasons</summary>
                      <div class="trpg-annot-list">
                        ${(l.reasons??[]).map($=>r`
                          <span class="trpg-annot-chip">
                            <span class="trpg-annot-name">Reason</span>
                            <span class="trpg-annot-desc">${$}</span>
                          </span>
                        `)}
                      </div>
                    </details>
                  `:null}
              </div>
            </details>
          `:null}

        ${d.length>0?r`
            <details class="trpg-detail-section">
              <summary class="trpg-detail-summary">Inventory (${d.length})</summary>
              <div class="trpg-detail-kv-group">
                ${d.map($=>r`<span class="trpg-detail-kv">${$}</span>`)}
              </div>
            </details>
          `:null}

        ${p.length>0?r`
            <details class="trpg-detail-section">
              <summary class="trpg-detail-summary">Notes</summary>
              <div class="trpg-annot-list">
                ${p.map($=>r`
                  <span class="trpg-annot-chip">
                    <span class="trpg-annot-name">note</span>
                    <span class="trpg-annot-desc">${$}</span>
                  </span>
                `)}
              </div>
            </details>
          `:null}

        ${c.length>0?r`
            <details class="trpg-detail-section">
              <summary class="trpg-detail-summary">Relationships</summary>
              <div class="trpg-annot-list">
                ${c.map(([$,Q])=>r`
                  <span class="trpg-annot-chip">
                    <span class="trpg-annot-name">${$}</span>
                    <span class="trpg-annot-desc">${Q}</span>
                  </span>
                `)}
              </div>
            </details>
          `:null}

        ${o.length>0?r`
            <details class="trpg-detail-section">
              <summary class="trpg-detail-summary">Recent dialog/actions</summary>
              <div>
                <div class="trpg-story">
                  ${o.map($=>r`
                    <div class="trpg-event">
                      <div class="trpg-event-main">
                        <strong>${$.actor_name||$.actor||"System"}</strong>
                        <span class="trpg-event-text">${$.content??""}</span>
                      </div>
                      <div class="trpg-event-meta-row">
                        <span class="trpg-event-ts">
                          <${B} timestamp=${$.timestamp} />
                        </span>
                      </div>
                    </div>
                  `)}
                </div>
              </div>
            </details>
          `:null}

        ${(e.traits??[]).length>0?r`
            <details class="trpg-detail-section">
              <summary class="trpg-detail-summary">Traits</summary>
              <div>
                <div class="trpg-annot-list">
                  ${(e.traits??[]).map($=>r`
                    <span class="trpg-annot-chip trait">
                      <span class="trpg-annot-name">${Jt($)}</span>
                      <span class="trpg-annot-desc">${xa($)}</span>
                    </span>
                  `)}
                </div>
              </div>
            </details>
          `:null}

        ${(e.skills??[]).length>0?r`
            <details class="trpg-detail-section">
              <summary class="trpg-detail-summary">Skills</summary>
              <div>
                <div class="trpg-annot-list">
                  ${(e.skills??[]).map($=>r`
                    <span class="trpg-annot-chip skill">
                      <span class="trpg-annot-name">${Jt($)}</span>
                      <span class="trpg-annot-desc">${wa($)}</span>
                    </span>
                  `)}
                </div>
              </div>
            </details>
          `:null}

        <details class="trpg-detail-section" open>
          <summary class="trpg-detail-summary">Recent events (${a.length})</summary>
          <div>
            ${a.length===0?r`<div class="empty-state" style="font-size:12px">No recent events</div>`:r`
                <div class="trpg-story">
                  ${a.map($=>r`
                    <div class="trpg-event">
                      <div class="trpg-event-main">
                        <strong>${$.actor_name||$.actor||"System"}</strong>
                        ${" "}
                        <span class="trpg-event-text">${$.content??""}</span>
                      </div>
                      <div class="trpg-event-meta-row">
                        <span class="trpg-event-ts">
                          <${B} timestamp=${$.timestamp} />
                        </span>
                      </div>
                    </div>
                  `)}
                </div>
              `}
          </div>
        </details>
      </div>
    </div>
  `}function To({mapStr:t}){return r`<pre class="trpg-map">${t}</pre>`}function No({events:t,parties:e}){const n=pe.value,s=Xe.value,a=Array.from(new Set(t.map(u=>an(u)).filter(Boolean))).sort();if(!(t.length>0))return r`<div class="empty-state" style="font-size:13px">No story events yet</div>`;const l=t.filter(u=>{const d=an(u),p=An(u,e);return!(n&&p!==n||s!=="all"&&d!==s)}).slice(-40);return r`
    <div>
      <div class="trpg-story-toolbar">
        <div class="trpg-story-filter">
          <label for="trpg-story-actor-filter">Actor</label>
          <select
            id="trpg-story-actor-filter"
            value=${n}
            onChange=${u=>{pe.value=u.target.value}}
          >
            <option value="">All actors</option>
            ${e.map(u=>r`<option value=${u.id}>${u.name}</option>`)}
          </select>
        </div>
        <div class="trpg-story-filter">
          <label for="trpg-story-category-filter">Category</label>
          <select
            id="trpg-story-category-filter"
            value=${s}
            onChange=${u=>{Xe.value=u.target.value}}
          >
            <option value="all">All</option>
            ${a.map(u=>r`<option value=${u}>${u}</option>`)}
          </select>
        </div>
        <button
          class="control-btn ghost"
          onClick=${()=>{pe.value="",Xe.value="all"}}
        >
          Reset filter
        </button>
        <button
          class="control-btn secondary"
          onClick=${()=>{ve.value=!ve.value}}
          title="Show/hide debug metadata"
        >
          Debug log: ${ve.value?"ON":"OFF"}
        </button>
      </div>

      ${l.length===0?r`<div class="empty-state" style="font-size:13px">No events match current filters.</div>`:r`
          <div class="trpg-story">
            ${l.map((u,d)=>{var y;const p=an(u),c=An(u,e),v=u.actor_name||u.actor||c||"System",f=c&&c===n&&n||c===xt.value;return r`
                  <div key=${d} class="trpg-event ${u.type??""}">
                    <div class="trpg-event-main">
                    ${c?r`
                        <button
                          class="trpg-event-actor ${f?"active":""}"
                          onClick=${()=>{pe.value=n===c?"":c,Tn(c)}}
                        >
                          ${v}
                        </button>
                      `:r`<strong>${v}</strong>`}
                    ${" "}
                    ${u.dice_roll?r`<span class="trpg-dice">[${u.dice_roll.notation}: ${(y=u.dice_roll.rolls)==null?void 0:y.join(",")} = ${u.dice_roll.total}${u.dice_roll.modifier?` +${u.dice_roll.modifier}`:""}]</span>${" "}`:null}
                    <span class="trpg-event-text">${u.content??""}</span>
                  </div>
                  ${ve.value?r`
                      <div class="trpg-event-meta-row">
                        <span class="trpg-event-meta">[${p}]</span>
                        <span class="trpg-event-ts">
                          <${B} timestamp=${u.timestamp} />
                        </span>
                      </div>
                    `:null}
                </div>
              `})}
          </div>
        `}
    </div>
  `}function Ro({outcome:t,state:e}){if(!t)return null;const n=e.party??[],s=xo(n,t),a=wo(t,e),i=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",o=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",l=[s?`승자: ${s}`:null,t.reason?`원인: ${vt(t.reason)}`:null,t.phase?`페이즈: ${vt(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return r`
    <div class="trpg-session-outcome">
      <div class="trpg-outcome-title">Session Outcome</div>
      <div class="trpg-outcome-status" style=${`color:${o};`}>${i}</div>
      ${l?r`<div class="trpg-outcome-meta">${l}</div>`:null}
      ${t!=null&&t.summary||t!=null&&t.details||t!=null&&t.raw_reason||t.reason?r`
          <div class="trpg-outcome-body">
            ${t!=null&&t.summary?r`<p><strong>요약:</strong> ${vt(t==null?void 0:t.summary)}</p>`:null}
            ${t!=null&&t.details?r`<p><strong>세부:</strong> ${vt(t==null?void 0:t.details)}</p>`:null}
            ${t!=null&&t.raw_reason?r`<p><strong>원인 근거:</strong> ${vt(t==null?void 0:t.raw_reason)}</p>`:null}
            ${t.reason?r`<p><strong>원인 코드:</strong> ${vt(t.reason)}</p>`:null}
          </div>
        `:null}
      ${a.length>0?r`
          <div class="trpg-outcome-evidence">
            <div class="trpg-annot-title">근거 이벤트</div>
            ${a.map(u=>r`<div class="trpg-outcome-evidence-item">${u}</div>`)}
          </div>
        `:null}
    </div>
  `}function Lo({state:t}){const e=t.history??[];return e.length===0?null:r`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>r`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function Eo({state:t}){var d;const e=gt.value||((d=t.session)==null?void 0:d.room)||"",n=me.value,s=t.party??[];if(!s.find(p=>p.id===ft.value)&&s.length>0){const p=s[0];p&&(ft.value=p.id)}const i=async()=>{if(!e){b("No room set","error");return}me.value="running";try{const p=await ua(e);Pe.value=p,me.value="ok";const c=at(p.summary)?p.summary:null,v=c?St(c,"advanced",!1):!1,f=c?U(c,"progress_reason",""):"";b(v?"Round advanced":`Round stalled${f?`: ${f}`:""}`,v?"success":"warning"),st()}catch(p){Pe.value=null,me.value="error";const c=p instanceof Error?p.message:"Round failed";b(c,"error")}},o=async()=>{if(e)try{await Bi(e),b("Turn advanced","success"),st()}catch{b("Advance failed","error")}},l=async()=>{if(!e)return;const p=ft.value.trim();if(!p){b("Select actor first","warning");return}const c=Number.parseInt(Qe.value,10),v=Number.parseInt(tn.value,10);if(Number.isNaN(c)||Number.isNaN(v)){b("Stat/DC must be numbers","warning");return}const f=Number.parseInt(fe.value,10),y=fe.value.trim()===""||Number.isNaN(f)?void 0:f;try{await Ui({roomId:e,actorId:p,action:Ze.value.trim()||"ability_check",statValue:c,dc:v,rawD20:y}),b("Dice rolled","success"),st()}catch{b("Dice roll failed","error")}},u=()=>{if(wt.value){Ie();return}if(!e){b("No room set","error");return}bo(e),b("Auto run started","success")};return r`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${e}
            onInput=${p=>{gt.value=p.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${ft.value}
            onChange=${p=>{ft.value=p.target.value}}
          >
            <option value="">Select actor</option>
            ${s.map(p=>r`<option value=${p.id}>${p.name} (${p.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Ze.value}
              onInput=${p=>{Ze.value=p.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Qe.value}
              onInput=${p=>{Qe.value=p.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${tn.value}
              onInput=${p=>{tn.value=p.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${fe.value}
              onInput=${p=>{fe.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&l()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${l}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${i}
              disabled=${n==="running"}
            >
              ${n==="running"?"Running...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${u}>
              ${wt.value?"Stop Auto Run":"Auto Run"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${o}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${n!=="idle"?r`<div class="trpg-run-status ${n}">${n==="running"?"Processing...":n==="ok"?"Done":"Failed"}</div>`:null}
    </div>
  `}function Do({state:t}){var l;const e=gt.value||((l=t.session)==null?void 0:l.room)||"",n=t.join_gate,s=sn.value,a=at(s)?s:null,i=async()=>{const u=_e.value.trim(),d=ge.value.trim();if(!e||!u){b("Room/Actor is required","warning");return}q.value="checking";try{const p=await Ki(e,u,d||void 0);sn.value=p,q.value="ok",b("Eligibility updated","success")}catch(p){q.value="error";const c=p instanceof Error?p.message:"Eligibility check failed";b(c,"error")}},o=async()=>{const u=_e.value.trim(),d=ge.value.trim(),p=nn.value.trim();if(!e||!u||!d){b("Room/Actor/Keeper is required","warning");return}q.value="requesting";try{const c=await qi({room_id:e,actor_id:u,keeper_name:d,role:en.value,...p?{name:p}:{}});sn.value=c;const v=at(c)?St(c,"granted",!1):!1,f=at(c)?U(c,"reason_code",""):"";v?b("Mid-join granted","success"):b(`Mid-join rejected${f?`: ${f}`:""}`,"warning"),q.value=v?"ok":"error",st()}catch(c){q.value="error";const v=c instanceof Error?c.message:"Mid-join request failed";b(v,"error")}};return r`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${n!=null&&n.phase_open?"OPEN":"CLOSED"}</strong>
        ${n!=null&&n.window?r`<span style="margin-left:8px;">(${n.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(n==null?void 0:n.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <input
            id="trpg-join-actor-input"
            name="trpg-join-actor-input"
            type="text"
            value=${_e.value}
            onInput=${u=>{_e.value=u.target.value}}
            placeholder="player-xyz"
          />
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            id="trpg-join-keeper-input"
            name="trpg-join-keeper-input"
            type="text"
            value=${ge.value}
            onInput=${u=>{ge.value=u.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${en.value}
            onChange=${u=>{en.value=u.target.value}}
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
            value=${nn.value}
            onInput=${u=>{nn.value=u.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${i} disabled=${q.value==="checking"||q.value==="requesting"}>
              ${q.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${o} disabled=${q.value==="checking"||q.value==="requesting"}>
              ${q.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${a?r`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${St(a,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Y(a,"effective_score",0)}/${Y(a,"required_points",0)}</span>
            ${U(a,"reason_code","")?r`<span style="margin-left:8px;">Reason: ${U(a,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Po({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?r`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:r`
    <div class="trpg-round-list">
      ${e.map(n=>r`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?r`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Io({state:t}){var n;const e=t.current_round;return e?r`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?r`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function jo(){const t=Pe.value;if(!t)return r`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=at(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(at).slice(-8),i=t.canon_check,o=at(i)?i:null,l=o&&Array.isArray(o.warnings)?o.warnings.filter(L=>typeof L=="string").slice(0,3):[],u=o&&Array.isArray(o.violations)?o.violations.filter(L=>typeof L=="string").slice(0,3):[],d=n?St(n,"advanced",!1):!1,p=n?U(n,"progress_reason",""):"",c=n?U(n,"progress_detail",""):"",v=n?Y(n,"player_successes",0):0,f=n?Y(n,"player_required_successes",0):0,y=n?St(n,"dm_success",!1):!1,k=n?Y(n,"timeouts",0):0,R=n?Y(n,"unavailable",0):0,S=n?Y(n,"reprompts",0):0,w=n?Y(n,"npc_attacks",0):0,O=n?Y(n,"keeper_timeout_sec",0):0,H=n?Y(n,"roll_audit_count",0):0;return r`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${d?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${d?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${y?"DM ok":"DM stalled"} / players ${v}/${f}
          </span>
        </div>
        ${p?r`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${c?r`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${c}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${R}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${O||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${H}</div></div>
      </div>

      ${a.length>0?r`
          <div class="trpg-round-list">
            ${a.map(L=>{const $=U(L,"status","unknown"),Q=U(L,"actor_id","-"),rt=U(L,"role","-"),W=U(L,"reason",""),tt=U(L,"action_type",""),T=U(L,"reply","");return r`
                <div class="trpg-round-item ${$.includes("fallback")||$.includes("timeout")?"failed":"active"}">
                  <span>${Q} (${rt})</span>
                  <span style="margin-left:auto; font-size:11px;">${$}</span>
                  ${tt?r`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${tt}</div>`:null}
                  ${W?r`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${W}</div>`:null}
                  ${T?r`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${T.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${o?r`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${U(o,"status","unknown")}</strong>
            </div>
            ${u.length>0?r`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${u.map(L=>r`<div>violation: ${L}</div>`)}
                </div>`:null}
            ${l.length>0?r`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(L=>r`<div>warning: ${L}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Mo(){var i,o;const t=Fn.value,e=yn.value;if(yt(()=>{const l=u=>{u.key==="Escape"&&ke()};return window.addEventListener("keydown",l),()=>{window.removeEventListener("keydown",l),Ie()}},[]),e&&!t)return r`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return r`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>st()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome;return r`
    <div>
      <${Ro} outcome=${a} state=${t} />

      ${""}
      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((i=t.session)==null?void 0:i.status)??"Active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((o=t.current_round)==null?void 0:o.round_number)??0}</div>
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

      ${""}
      <${Io} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          <${Ao} />

          ${""}
          <${A} title="Story Log (${s.length})">
            <${No} events=${s} parties=${n} />
          <//>

          ${""}
          ${t.map?r`
              <${A} title="Map" style="margin-top:16px;">
                <${To} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${A} title="Controls">
            <${Eo} state=${t} />
          <//>

          <${A} title="Last Round Result" style="margin-top:16px;">
            <${jo} />
          <//>

          ${""}
          <${A} title="Mid-Join Gate" style="margin-top:16px;">
            <${Do} state=${t} />
          <//>

          ${""}
          <${A} title="Contribution" style="margin-top:16px;">
            <${Po} state=${t} />
          <//>

          ${""}
          <${A} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(l=>r`<${Co} key=${l.id??l.name} actor=${l} />`)}
              ${n.length===0?r`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?r`
              <${A} title="History (${t.history.length})" style="margin-top:16px;">
                <${Lo} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const Bn="masc_dashboard_agent_name";function Oo(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Bn);return e??n??"dashboard"}const V=m(Oo()),Gt=m(""),Vt=m(""),je=m(""),Yt=m(!1),mt=m(!1),Xt=m(!1),Zt=m(!1),Me=m(!1),Be=m(!1);function Kn(t){const e=t.trim();V.value=e,e&&localStorage.setItem(Bn,e)}function Fo(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Nn(){const t=V.value.trim();if(t){Xt.value=!0;try{const e=await Ji(t),n=Fo(e);n&&Kn(n),Be.value=!0,b(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";b(n,"error")}finally{Xt.value=!1}}}async function zo(){const t=V.value.trim();if(t){Zt.value=!0;try{await pa(t),Be.value=!1,b(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";b(n,"error")}finally{Zt.value=!1}}}async function Ho(){const t=V.value.trim();if(t)try{await pa(t)}catch{}localStorage.removeItem(Bn),Kn("dashboard"),Be.value=!1,await Nn()}async function Uo(){const t=V.value.trim();if(t){Me.value=!0;try{await Gi(t),b("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";b(n,"error")}finally{Me.value=!1}}}async function ks(){const t=V.value.trim(),e=Gt.value.trim();if(!(!t||!e)){Yt.value=!0;try{await da(t,e),Gt.value="",b("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";b(s,"error")}finally{Yt.value=!1}}}async function Bo(){const t=Vt.value.trim(),e=je.value.trim()||"Created from dashboard";if(t){mt.value=!0;try{await Wi(t,e,1),Vt.value="",je.value="",b("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";b(s,"error")}finally{mt.value=!1}}}function Ko(){return yt(()=>{Nn()},[]),r`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${V.value}
        onInput=${t=>Kn(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${Gt.value}
          onInput=${t=>{Gt.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&ks()}}
          disabled=${Yt.value}
        />
        <button
          class="control-btn"
          onClick=${ks}
          disabled=${Yt.value||Gt.value.trim()===""||V.value.trim()===""}
        >
          ${Yt.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Nn()}}
          disabled=${Xt.value||V.value.trim()===""}
        >
          ${Xt.value?"Joining...":Be.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{zo()}}
          disabled=${Zt.value||V.value.trim()===""}
        >
          ${Zt.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Ho()}}
          disabled=${Xt.value||Zt.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Uo()}}
          disabled=${Me.value||V.value.trim()===""}
        >
          ${Me.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${Vt.value}
        onInput=${t=>{Vt.value=t.target.value}}
        disabled=${mt.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${je.value}
        onInput=${t=>{je.value=t.target.value}}
        disabled=${mt.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${Bo}
        disabled=${mt.value||Vt.value.trim()===""}
      >
        ${mt.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function qo(){const t=kt.value;return r`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${jn.value} events</span>
    </div>
  `}const Wo=[{id:"overview",label:"Overview"},{id:"council",label:"Council"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function Jo(){const t=Z.value.tab,e=kt.value;return r`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${Wo.map(n=>r`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>He(n.id)}
            >
              ${n.label}
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
            <strong>${Tt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${Nt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${oe.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${jn.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Ue(),t==="board"&&ut(),t==="trpg"&&st()}}
        >
          Refresh Now
        </button>
      </section>

      <${Ko} />
    </aside>
  `}function Go(){switch(Z.value.tab){case"overview":return r`<${_s} />`;case"council":return r`<${Ur} />`;case"board":return r`<${Zr} />`;case"activity":return r`<${no} />`;case"agents":return r`<${po} />`;case"tasks":return r`<${vo} />`;case"journal":return r`<${mo} />`;case"trpg":return r`<${Mo} />`;default:return r`<${_s} />`}}function Vo(){return yt(()=>{li(),sa(),Ue();const t=vr();return fr(),()=>{gi(),t(),mr()}},[]),yt(()=>{const t=Z.value.tab;t==="board"&&ut(),t==="trpg"&&st()},[Z.value.tab]),r`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">Real-time multi-agent operations console</p>
        </div>
        <div class="header-right">
          <${qo} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${ui} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${$n.value&&!kt.value?r`<div class="loading-indicator">Loading dashboard...</div>`:r`<${Go} />`}
        </main>
        <${Jo} />
      </div>

      <${Sr} />
      <${Dr} />
      <${Tr} />
    </div>
  `}const xs=document.getElementById("app");xs&&qa(r`<${Vo} />`,xs);
