(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))i(s);new MutationObserver(s=>{for(const a of s)if(a.type==="childList")for(const o of a.addedNodes)o.tagName==="LINK"&&o.rel==="modulepreload"&&i(o)}).observe(document,{childList:!0,subtree:!0});function n(s){const a={};return s.integrity&&(a.integrity=s.integrity),s.referrerPolicy&&(a.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?a.credentials="include":s.crossOrigin==="anonymous"?a.credentials="omit":a.credentials="same-origin",a}function i(s){if(s.ep)return;s.ep=!0;const a=n(s);fetch(s.href,a)}})();var Ct,$,Ne,Re,j,re,Le,Ee,De,te,Bt,Ft,at={},Me=[],xn=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Tt=Array.isArray;function R(t,e){for(var n in e)t[n]=e[n];return t}function ee(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function je(t,e,n){var i,s,a,o={};for(a in e)a=="key"?i=e[a]:a=="ref"?s=e[a]:o[a]=e[a];if(arguments.length>2&&(o.children=arguments.length>3?Ct.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(a in t.defaultProps)o[a]===void 0&&(o[a]=t.defaultProps[a]);return ht(t,o,i,s,null)}function ht(t,e,n,i,s){var a={type:t,props:e,key:n,ref:i,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++Ne,__i:-1,__u:0};return s==null&&$.vnode!=null&&$.vnode(a),a}function ot(t){return t.children}function Q(t,e){this.props=t,this.context=e}function W(t,e){if(e==null)return t.__?W(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?W(t):null}function Ie(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return Ie(t)}}function le(t){(!t.__d&&(t.__d=!0)&&j.push(t)&&!gt.__r++||re!=$.debounceRendering)&&((re=$.debounceRendering)||Le)(gt)}function gt(){for(var t,e,n,i,s,a,o,c=1;j.length;)j.length>c&&j.sort(Ee),t=j.shift(),c=j.length,t.__d&&(n=void 0,i=void 0,s=(i=(e=t).__v).__e,a=[],o=[],e.__P&&((n=R({},i)).__v=i.__v+1,$.vnode&&$.vnode(n),ne(e.__P,n,i,e.__n,e.__P.namespaceURI,32&i.__u?[s]:null,a,s??W(i),!!(32&i.__u),o),n.__v=i.__v,n.__.__k[n.__i]=n,He(a,n,o),i.__e=i.__=null,n.__e!=s&&Ie(n)));gt.__r=0}function Oe(t,e,n,i,s,a,o,c,d,u,p){var l,f,v,x,C,k,g,m=i&&i.__k||Me,L=e.length;for(d=kn(n,e,m,d,L),l=0;l<L;l++)(v=n.__k[l])!=null&&(f=v.__i==-1?at:m[v.__i]||at,v.__i=l,k=ne(t,v,f,s,a,o,c,d,u,p),x=v.__e,v.ref&&f.ref!=v.ref&&(f.ref&&ie(f.ref,null,v),p.push(v.ref,v.__c||x,v)),C==null&&x!=null&&(C=x),(g=!!(4&v.__u))||f.__k===v.__k?d=Ue(v,d,t,g):typeof v.type=="function"&&k!==void 0?d=k:x&&(d=x.nextSibling),v.__u&=-7);return n.__e=C,d}function kn(t,e,n,i,s){var a,o,c,d,u,p=n.length,l=p,f=0;for(t.__k=new Array(s),a=0;a<s;a++)(o=e[a])!=null&&typeof o!="boolean"&&typeof o!="function"?(typeof o=="string"||typeof o=="number"||typeof o=="bigint"||o.constructor==String?o=t.__k[a]=ht(null,o,null,null,null):Tt(o)?o=t.__k[a]=ht(ot,{children:o},null,null,null):o.constructor===void 0&&o.__b>0?o=t.__k[a]=ht(o.type,o.props,o.key,o.ref?o.ref:null,o.__v):t.__k[a]=o,d=a+f,o.__=t,o.__b=t.__b+1,c=null,(u=o.__i=wn(o,n,d,l))!=-1&&(l--,(c=n[u])&&(c.__u|=2)),c==null||c.__v==null?(u==-1&&(s>p?f--:s<p&&f++),typeof o.type!="function"&&(o.__u|=4)):u!=d&&(u==d-1?f--:u==d+1?f++:(u>d?f--:f++,o.__u|=4))):t.__k[a]=null;if(l)for(a=0;a<p;a++)(c=n[a])!=null&&(2&c.__u)==0&&(c.__e==i&&(i=W(c)),Be(c,c));return i}function Ue(t,e,n,i){var s,a;if(typeof t.type=="function"){for(s=t.__k,a=0;s&&a<s.length;a++)s[a]&&(s[a].__=t,e=Ue(s[a],e,n,i));return e}t.__e!=e&&(i&&(e&&t.type&&!e.parentNode&&(e=W(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function wn(t,e,n,i){var s,a,o,c=t.key,d=t.type,u=e[n],p=u!=null&&(2&u.__u)==0;if(u===null&&c==null||p&&c==u.key&&d==u.type)return n;if(i>(p?1:0)){for(s=n-1,a=n+1;s>=0||a<e.length;)if((u=e[o=s>=0?s--:a++])!=null&&(2&u.__u)==0&&c==u.key&&d==u.type)return o}return-1}function ce(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||xn.test(e)?n:n+"px"}function vt(t,e,n,i,s){var a,o;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof i=="string"&&(t.style.cssText=i=""),i)for(e in i)n&&e in n||ce(t.style,e,"");if(n)for(e in n)i&&n[e]==i[e]||ce(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")a=e!=(e=e.replace(De,"$1")),o=e.toLowerCase(),e=o in t||e=="onFocusOut"||e=="onFocusIn"?o.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+a]=n,n?i?n.u=i.u:(n.u=te,t.addEventListener(e,a?Ft:Bt,a)):t.removeEventListener(e,a?Ft:Bt,a);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function ue(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=te++;else if(e.t<n.u)return;return n($.event?$.event(e):e)}}}function ne(t,e,n,i,s,a,o,c,d,u){var p,l,f,v,x,C,k,g,m,L,D,ut,J,oe,dt,X,Dt,T=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),a=[c=e.__e=n.__e]),(p=$.__b)&&p(e);t:if(typeof T=="function")try{if(g=e.props,m="prototype"in T&&T.prototype.render,L=(p=T.contextType)&&i[p.__c],D=p?L?L.props.value:p.__:i,n.__c?k=(l=e.__c=n.__c).__=l.__E:(m?e.__c=l=new T(g,D):(e.__c=l=new Q(g,D),l.constructor=T,l.render=Cn),L&&L.sub(l),l.state||(l.state={}),l.__n=i,f=l.__d=!0,l.__h=[],l._sb=[]),m&&l.__s==null&&(l.__s=l.state),m&&T.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=R({},l.__s)),R(l.__s,T.getDerivedStateFromProps(g,l.__s))),v=l.props,x=l.state,l.__v=e,f)m&&T.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),m&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(m&&T.getDerivedStateFromProps==null&&g!==v&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(g,D),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(g,l.__s,D)===!1){for(e.__v!=n.__v&&(l.props=g,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(z){z&&(z.__=e)}),ut=0;ut<l._sb.length;ut++)l.__h.push(l._sb[ut]);l._sb=[],l.__h.length&&o.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(g,l.__s,D),m&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(v,x,C)})}if(l.context=D,l.props=g,l.__P=t,l.__e=!1,J=$.__r,oe=0,m){for(l.state=l.__s,l.__d=!1,J&&J(e),p=l.render(l.props,l.state,l.context),dt=0;dt<l._sb.length;dt++)l.__h.push(l._sb[dt]);l._sb=[]}else do l.__d=!1,J&&J(e),p=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++oe<25);l.state=l.__s,l.getChildContext!=null&&(i=R(R({},i),l.getChildContext())),m&&!f&&l.getSnapshotBeforeUpdate!=null&&(C=l.getSnapshotBeforeUpdate(v,x)),X=p,p!=null&&p.type===ot&&p.key==null&&(X=ze(p.props.children)),c=Oe(t,Tt(X)?X:[X],e,n,i,s,a,o,c,d,u),l.base=e.__e,e.__u&=-161,l.__h.length&&o.push(l),k&&(l.__E=l.__=null)}catch(z){if(e.__v=null,d||a!=null)if(z.then){for(e.__u|=d?160:128;c&&c.nodeType==8&&c.nextSibling;)c=c.nextSibling;a[a.indexOf(c)]=null,e.__e=c}else{for(Dt=a.length;Dt--;)ee(a[Dt]);qt(e)}else e.__e=n.__e,e.__k=n.__k,z.then||qt(e);$.__e(z,e,n)}else a==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):c=e.__e=Sn(n.__e,e,n,i,s,a,o,d,u);return(p=$.diffed)&&p(e),128&e.__u?void 0:c}function qt(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(qt)}function He(t,e,n){for(var i=0;i<n.length;i++)ie(n[i],n[++i],n[++i]);$.__c&&$.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(a){a.call(s)})}catch(a){$.__e(a,s.__v)}})}function ze(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Tt(t)?t.map(ze):R({},t)}function Sn(t,e,n,i,s,a,o,c,d){var u,p,l,f,v,x,C,k=n.props||at,g=e.props,m=e.type;if(m=="svg"?s="http://www.w3.org/2000/svg":m=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),a!=null){for(u=0;u<a.length;u++)if((v=a[u])&&"setAttribute"in v==!!m&&(m?v.localName==m:v.nodeType==3)){t=v,a[u]=null;break}}if(t==null){if(m==null)return document.createTextNode(g);t=document.createElementNS(s,m,g.is&&g),c&&($.__m&&$.__m(e,a),c=!1),a=null}if(m==null)k===g||c&&t.data==g||(t.data=g);else{if(a=a&&Ct.call(t.childNodes),!c&&a!=null)for(k={},u=0;u<t.attributes.length;u++)k[(v=t.attributes[u]).name]=v.value;for(u in k)if(v=k[u],u!="children"){if(u=="dangerouslySetInnerHTML")l=v;else if(!(u in g)){if(u=="value"&&"defaultValue"in g||u=="checked"&&"defaultChecked"in g)continue;vt(t,u,null,v,s)}}for(u in g)v=g[u],u=="children"?f=v:u=="dangerouslySetInnerHTML"?p=v:u=="value"?x=v:u=="checked"?C=v:c&&typeof v!="function"||k[u]===v||vt(t,u,v,k[u],s);if(p)c||l&&(p.__html==l.__html||p.__html==t.innerHTML)||(t.innerHTML=p.__html),e.__k=[];else if(l&&(t.innerHTML=""),Oe(e.type=="template"?t.content:t,Tt(f)?f:[f],e,n,i,m=="foreignObject"?"http://www.w3.org/1999/xhtml":s,a,o,a?a[0]:n.__k&&W(n,0),c,d),a!=null)for(u=a.length;u--;)ee(a[u]);c||(u="value",m=="progress"&&x==null?t.removeAttribute("value"):x!=null&&(x!==t[u]||m=="progress"&&!x||m=="option"&&x!=k[u])&&vt(t,u,x,k[u],s),u="checked",C!=null&&C!=t[u]&&vt(t,u,C,k[u],s))}return t}function ie(t,e,n){try{if(typeof t=="function"){var i=typeof t.__u=="function";i&&t.__u(),i&&e==null||(t.__u=t(e))}else t.current=e}catch(s){$.__e(s,n)}}function Be(t,e,n){var i,s;if($.unmount&&$.unmount(t),(i=t.ref)&&(i.current&&i.current!=t.__e||ie(i,null,e)),(i=t.__c)!=null){if(i.componentWillUnmount)try{i.componentWillUnmount()}catch(a){$.__e(a,e)}i.base=i.__P=null}if(i=t.__k)for(s=0;s<i.length;s++)i[s]&&Be(i[s],e,n||typeof t.type!="function");n||ee(t.__e),t.__c=t.__=t.__e=void 0}function Cn(t,e,n){return this.constructor(t,n)}function Tn(t,e,n){var i,s,a,o;e==document&&(e=document.documentElement),$.__&&$.__(t,e),s=(i=!1)?null:e.__k,a=[],o=[],ne(e,t=e.__k=je(ot,null,[t]),s||at,at,e.namespaceURI,s?null:e.firstChild?Ct.call(e.childNodes):null,a,s?s.__e:e.firstChild,i,o),He(a,t,o)}Ct=Me.slice,$={__e:function(t,e,n,i){for(var s,a,o;e=e.__;)if((s=e.__c)&&!s.__)try{if((a=s.constructor)&&a.getDerivedStateFromError!=null&&(s.setState(a.getDerivedStateFromError(t)),o=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,i||{}),o=s.__d),o)return s.__E=s}catch(c){t=c}throw t}},Ne=0,Re=function(t){return t!=null&&t.constructor===void 0},Q.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=R({},this.state),typeof t=="function"&&(t=t(R({},n),this.props)),t&&R(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),le(this))},Q.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),le(this))},Q.prototype.render=ot,j=[],Le=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Ee=function(t,e){return t.__v.__b-e.__v.__b},gt.__r=0,De=/(PointerCapture)$|Capture$/i,te=0,Bt=ue(!1),Ft=ue(!0);var Fe=function(t,e,n,i){var s;e[0]=0;for(var a=1;a<e.length;a++){var o=e[a++],c=e[a]?(e[0]|=o?1:2,n[e[a++]]):e[++a];o===3?i[0]=c:o===4?i[1]=Object.assign(i[1]||{},c):o===5?(i[1]=i[1]||{})[e[++a]]=c:o===6?i[1][e[++a]]+=c+"":o?(s=t.apply(c,Fe(t,c,n,["",null])),i.push(s),c[0]?e[0]|=2:(e[a-2]=0,e[a]=s)):i.push(c)}return i},de=new Map;function Pn(t){var e=de.get(this);return e||(e=new Map,de.set(this,e)),(e=Fe(this,e.get(t)||(e.set(t,e=(function(n){for(var i,s,a=1,o="",c="",d=[0],u=function(f){a===1&&(f||(o=o.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,f,o):a===3&&(f||o)?(d.push(3,f,o),a=2):a===2&&o==="..."&&f?d.push(4,f,0):a===2&&o&&!f?d.push(5,0,!0,o):a>=5&&((o||!f&&a===5)&&(d.push(a,0,o,s),a=6),f&&(d.push(a,f,0,s),a=6)),o=""},p=0;p<n.length;p++){p&&(a===1&&u(),u(p));for(var l=0;l<n[p].length;l++)i=n[p][l],a===1?i==="<"?(u(),d=[d],a=3):o+=i:a===4?o==="--"&&i===">"?(a=1,o=""):o=i+o[0]:c?i===c?c="":o+=i:i==='"'||i==="'"?c=i:i===">"?(u(),a=1):a&&(i==="="?(a=5,s=o,o=""):i==="/"&&(a<5||n[p][l+1]===">")?(u(),a===3&&(d=d[0]),a=d,(d=d[0]).push(2,0,a),a=0):i===" "||i==="	"||i===`
`||i==="\r"?(u(),a=2):o+=i),a===3&&o==="!--"&&(a=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var r=Pn.bind(je),yt,S,Mt,ve,pe=0,qe=[],y=$,fe=y.__b,_e=y.__r,he=y.diffed,$e=y.__c,me=y.unmount,ge=y.__;function We(t,e){y.__h&&y.__h(S,t,pe||e),pe=0;var n=S.__H||(S.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function ye(t,e){var n=We(yt++,3);!y.__s&&Ke(n.__H,e)&&(n.__=t,n.u=e,S.__H.__h.push(n))}function Ge(t,e){var n=We(yt++,7);return Ke(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function An(){for(var t;t=qe.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach($t),t.__H.__h.forEach(Wt),t.__H.__h=[]}catch(e){t.__H.__h=[],y.__e(e,t.__v)}}y.__b=function(t){S=null,fe&&fe(t)},y.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),ge&&ge(t,e)},y.__r=function(t){_e&&_e(t),yt=0;var e=(S=t.__c).__H;e&&(Mt===S?(e.__h=[],S.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach($t),e.__h.forEach(Wt),e.__h=[],yt=0)),Mt=S},y.diffed=function(t){he&&he(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(qe.push(e)!==1&&ve===y.requestAnimationFrame||((ve=y.requestAnimationFrame)||Nn)(An)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Mt=S=null},y.__c=function(t,e){e.some(function(n){try{n.__h.forEach($t),n.__h=n.__h.filter(function(i){return!i.__||Wt(i)})}catch(i){e.some(function(s){s.__h&&(s.__h=[])}),e=[],y.__e(i,n.__v)}}),$e&&$e(t,e)},y.unmount=function(t){me&&me(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(i){try{$t(i)}catch(s){e=s}}),n.__H=void 0,e&&y.__e(e,n.__v))};var be=typeof requestAnimationFrame=="function";function Nn(t){var e,n=function(){clearTimeout(i),be&&cancelAnimationFrame(e),setTimeout(t)},i=setTimeout(n,35);be&&(e=requestAnimationFrame(n))}function $t(t){var e=S,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),S=e}function Wt(t){var e=S;t.__c=t.__(),S=e}function Ke(t,e){return!t||t.length!==e.length||e.some(function(n,i){return n!==t[i]})}var Rn=Symbol.for("preact-signals");function Pt(){if(E>1)E--;else{for(var t,e=!1;Y!==void 0;){var n=Y;for(Y=void 0,Gt++;n!==void 0;){var i=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&Xe(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=i}}if(Gt=0,E--,e)throw t}}function Ln(t){if(E>0)return t();E++;try{return t()}finally{Pt()}}var _=void 0;function Ve(t){var e=_;_=void 0;try{return t()}finally{_=e}}var Y=void 0,E=0,Gt=0,bt=0;function Je(t){if(_!==void 0){var e=t.n;if(e===void 0||e.t!==_)return e={i:0,S:t,p:_.s,n:void 0,t:_,e:void 0,x:void 0,r:e},_.s!==void 0&&(_.s.n=e),_.s=e,t.n=e,32&_.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=_.s,e.n=void 0,_.s.n=e,_.s=e),e}}function w(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}w.prototype.brand=Rn;w.prototype.h=function(){return!0};w.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:Ve(function(){var i;(i=e.W)==null||i.call(e)}))};w.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,i=t.x;n!==void 0&&(n.x=i,t.e=void 0),i!==void 0&&(i.e=n,t.x=void 0),t===this.t&&(this.t=i,i===void 0&&Ve(function(){var s;(s=e.Z)==null||s.call(e)}))}};w.prototype.subscribe=function(t){var e=this;return rt(function(){var n=e.value,i=_;_=void 0;try{t(n)}finally{_=i}},{name:"sub"})};w.prototype.valueOf=function(){return this.value};w.prototype.toString=function(){return this.value+""};w.prototype.toJSON=function(){return this.value};w.prototype.peek=function(){var t=_;_=void 0;try{return this.value}finally{_=t}};Object.defineProperty(w.prototype,"value",{get:function(){var t=Je(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Gt>100)throw new Error("Cycle detected");this.v=t,this.i++,bt++,E++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Pt()}}}});function h(t,e){return new w(t,e)}function Xe(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function Ze(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Qe(t){for(var e=t.s,n=void 0;e!==void 0;){var i=e.p;e.i===-1?(e.S.U(e),i!==void 0&&(i.n=e.n),e.n!==void 0&&(e.n.p=i)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=i}t.s=n}function I(t,e){w.call(this,void 0),this.x=t,this.s=void 0,this.g=bt-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}I.prototype=new w;I.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===bt))return!0;if(this.g=bt,this.f|=1,this.i>0&&!Xe(this))return this.f&=-2,!0;var t=_;try{Ze(this),_=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return _=t,Qe(this),this.f&=-2,!0};I.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}w.prototype.S.call(this,t)};I.prototype.U=function(t){if(this.t!==void 0&&(w.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};I.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(I.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Je(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function xt(t,e){return new I(t,e)}function Ye(t){var e=t.u;if(t.u=void 0,typeof e=="function"){E++;var n=_;_=void 0;try{e()}catch(i){throw t.f&=-2,t.f|=8,se(t),i}finally{_=n,Pt()}}}function se(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,Ye(t)}function En(t){if(_!==this)throw new Error("Out-of-order effect");Qe(this),_=t,this.f&=-2,8&this.f&&se(this),Pt()}function K(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}K.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};K.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,Ye(this),Ze(this),E++;var t=_;return _=this,En.bind(this,t)};K.prototype.N=function(){2&this.f||(this.f|=2,this.o=Y,Y=this)};K.prototype.d=function(){this.f|=8,1&this.f||se(this)};K.prototype.dispose=function(){this.d()};function rt(t,e){var n=new K(t,e);try{n.c()}catch(s){throw n.d(),s}var i=n.d.bind(n);return i[Symbol.dispose]=i,i}var tn,pt,Dn=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,en=[];rt(function(){tn=this.N})();function V(t,e){$[t]=e.bind(null,$[t]||function(){})}function kt(t){if(pt){var e=pt;pt=void 0,e()}pt=t&&t.S()}function nn(t){var e=this,n=t.data,i=jn(n);i.value=n;var s=Ge(function(){for(var c=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=xt(function(){var v=i.value.value;return v===0?0:v===!0?"":v||""}),p=xt(function(){return!Array.isArray(u.value)&&!Re(u.value)}),l=rt(function(){if(this.N=sn,p.value){var v=u.value;c.__v&&c.__v.__e&&c.__v.__e.nodeType===3&&(c.__v.__e.data=v)}}),f=e.__$u.d;return e.__$u.d=function(){l(),f.call(this)},[p,u]},[]),a=s[0],o=s[1];return a.value?o.peek():o.value}nn.displayName="ReactiveTextNode";Object.defineProperties(w.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:nn},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});V("__b",function(t,e){if(typeof e.type=="string"){var n,i=e.props;for(var s in i)if(s!=="children"){var a=i[s];a instanceof w&&(n||(e.__np=n={}),n[s]=a,i[s]=a.peek())}}t(e)});V("__r",function(t,e){if(t(e),e.type!==ot){kt();var n,i=e.__c;i&&(i.__$f&=-2,(n=i.__$u)===void 0&&(i.__$u=n=(function(s,a){var o;return rt(function(){o=this},{name:a}),o.c=s,o})(function(){var s;Dn&&((s=n.y)==null||s.call(n)),i.__$f|=1,i.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),kt(n)}});V("__e",function(t,e,n,i){kt(),t(e,n,i)});V("diffed",function(t,e){kt();var n;if(typeof e.type=="string"&&(n=e.__e)){var i=e.__np,s=e.props;if(i){var a=n.U;if(a)for(var o in a){var c=a[o];c!==void 0&&!(o in i)&&(c.d(),a[o]=void 0)}else a={},n.U=a;for(var d in i){var u=a[d],p=i[d];u===void 0?(u=Mn(n,d,p),a[d]=u):u.o(p,s)}for(var l in i)s[l]=i[l]}}t(e)});function Mn(t,e,n,i){var s=e in t&&t.ownerSVGElement===void 0,a=h(n),o=n.peek();return{o:function(c,d){a.value=c,o=c.peek()},d:rt(function(){this.N=sn;var c=a.value.value;o!==c?(o=void 0,s?t[e]=c:c!=null&&(c!==!1||e[4]==="-")?t.setAttribute(e,c):t.removeAttribute(e)):o=void 0})}}V("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var i=n.U;if(i){n.U=void 0;for(var s in i){var a=i[s];a&&a.d()}}}e.__np=void 0}else{var o=e.__c;if(o){var c=o.__$u;c&&(o.__$u=void 0,c.d())}}t(e)});V("__h",function(t,e,n,i){(i<3||i===9)&&(e.__$f|=2),t(e,n,i)});Q.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,i=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var a=2&this.__$f;if(!(i||a||4&this.__$f)||1&this.__$f)return!0}else if(!(i||4&this.__$f)||3&this.__$f)return!0;for(var o in t)if(o!=="__source"&&t[o]!==this.props[o])return!0;for(var c in this.props)if(!(c in t))return!0;return!1};function jn(t,e){return Ge(function(){return h(t,e)},[])}var In=function(t){queueMicrotask(function(){queueMicrotask(t)})};function On(){Ln(function(){for(var t;t=en.shift();)tn.call(t)})}function sn(){en.push(this)===1&&($.requestAnimationFrame||In)(On)}const Un=["overview","board","activity","agents","tasks","journal","trpg"],an={tab:"overview",params:{},postId:null};function xe(t){return!!t&&Un.includes(t)}function Kt(t){try{return decodeURIComponent(t)}catch{return t}}function Vt(t){const e={};return t&&new URLSearchParams(t).forEach((i,s)=>{e[s]=i}),e}function Hn(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function on(t,e){const n=t[0],i=e.tab,s=xe(n)?n:xe(i)?i:"overview";let a=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?a=Kt(t[2]):t[0]==="post"&&t[1]&&(a=Kt(t[1]))),{tab:s,params:e,postId:a}}function wt(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return an;const n=Kt(e);let i=n,s;if(n.startsWith("?"))i="",s=n.slice(1);else{const c=n.indexOf("?");c>=0&&(i=n.slice(0,c),s=n.slice(c+1))}!s&&i.includes("=")&&!i.includes("/")&&(s=i,i="");const a=Vt(s),o=Hn(i);return on(o,a)}function zn(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const i=n.slice(1);if(i.length===0)return{...an,params:Vt(e.replace(/^\?/,""))};if(i[0]==="assets"||i[0]==="credits"||i[0]==="lodge")return null;const s=Vt(e.replace(/^\?/,""));return on(i,s)}function rn(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const i=new URLSearchParams(n);return`#${e}?${i.toString()}`}const A=h(wt(window.location.hash));window.addEventListener("hashchange",()=>{A.value=wt(window.location.hash)});function At(t,e){const n={tab:t,params:{},postId:null};window.location.hash=rn(n)}function Bn(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Fn(){if(window.location.hash&&window.location.hash!=="#"){A.value=wt(window.location.hash);return}const t=zn(window.location.pathname,window.location.search);if(t){A.value=t;const e=rn(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",A.value=wt(window.location.hash)}const qn=[{id:"overview",label:"Overview",icon:"🏠"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function Wn(){const t=A.value.tab;return r`
    <div class="main-tab-bar">
      ${qn.map(e=>r`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>At(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const ke="masc_dashboard_sse_session_id",Gn=1e3,Kn=15e3,G=h(!1),St=h(0),ln=h(null),Jt=h([]);function Vn(){let t=sessionStorage.getItem(ke);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(ke,t)),t}const Jn=200;function M(t,e){const n={agent:t,text:e,timestamp:Date.now()};Jt.value=[n,...Jt.value].slice(0,Jn)}let P=null,F=null,Xt=0;function cn(){F&&(clearTimeout(F),F=null)}function Xn(){if(F)return;Xt++;const t=Math.min(Xt,5),e=Math.min(Kn,Gn*Math.pow(2,t));F=setTimeout(()=>{F=null,un()},e)}function un(){cn(),P&&(P.close(),P=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),i=t.get("token");n&&e.set("agent",n),i&&e.set("token",i),e.set("session_id",Vn());const s=e.toString()?`/sse?${e.toString()}`:"/sse",a=new EventSource(s);P=a,a.onopen=()=>{P===a&&(Xt=0,G.value=!0)},a.onerror=()=>{P===a&&(G.value=!1,a.close(),P=null,Xn())},a.onmessage=o=>{try{const c=JSON.parse(o.data);St.value++,ln.value=c,Zn(c)}catch{}}}function Zn(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":M(n,"Joined");break;case"agent_left":M(n,"Left");break;case"broadcast":M(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":M(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":M(n,"New post");break;case"board_comment":M(n,"New comment");break;default:M(n,e)}}function Qn(){cn(),P&&(P.close(),P=null),G.value=!1}function Yn(){return new URLSearchParams(window.location.search)}function dn(){const t=Yn(),e={},n=t.get("token"),i=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),i&&(e["X-MASC-Agent"]=i),e}function ti(){return{...dn(),"Content-Type":"application/json"}}async function Nt(t){const e=await fetch(t,{headers:dn()});if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function lt(t,e){const n=await fetch(t,{method:"POST",headers:ti(),body:JSON.stringify(e)});if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}function ei(){return Nt("/api/v1/dashboard")}function ni(){return Nt("/api/v1/board")}function ii(t){return Nt(`/api/v1/board/${t}`)}function vn(t,e){return lt(`/api/v1/board/${t}/vote`,{direction:e})}function si(t,e,n){return lt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function ai(t){const e=t?`?room=${encodeURIComponent(t)}`:"";return Nt(`/api/v1/trpg/state${e}`)}function oi(t){return lt("/api/v1/trpg/rounds/run",{room:t})}function ri(t,e){return lt("/api/v1/trpg/dice/roll",{room:t,notation:e})}function li(t){return lt("/api/v1/trpg/turns/advance",{room:t})}const ct=h([]),Rt=h([]),pn=h([]),Lt=h([]),fn=h(null),Z=h(null),_n=h([]),we=h("hot"),hn=h(null),$n=h(""),Zt=h(!1),Qt=h(!1),Yt=h(!1),ci=xt(()=>ct.value.filter(t=>t.status==="active"||t.status==="idle")),mn=xt(()=>{const t=Rt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});let mt=null;const ui=5e3;function gn(){mt=null}function di(t){return Array.isArray(t)?t:t&&Array.isArray(t.keepers)?t.keepers:[]}async function Et(){var e,n,i;const t=Date.now();if(!(mt&&t-mt.time<ui)){Zt.value=!0;try{const s=await ei();mt={data:s,time:t},ct.value=((e=s.agents)==null?void 0:e.agents)??[],Rt.value=((n=s.tasks)==null?void 0:n.tasks)??[],pn.value=((i=s.messages)==null?void 0:i.messages)??[],Lt.value=di(s.keepers),fn.value=s.status??null,Z.value=s.perpetual??null}catch(s){console.error("Dashboard fetch error:",s)}finally{Zt.value=!1}}}async function O(){Qt.value=!0;try{const t=await ni();_n.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{Qt.value=!1}}async function q(){Yt.value=!0;try{const t=$n.value||void 0,e=await ai(t);hn.value=e}catch(t){console.error("TRPG fetch error:",t)}finally{Yt.value=!1}}let jt=null,It=null;function vi(){return ln.subscribe(e=>{e&&(gn(),jt||(jt=setTimeout(()=>{Et(),jt=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(It||(It=setTimeout(()=>{O(),It=null},500))))})}let tt=null;function pi(){tt||(tt=setInterval(()=>{gn(),Et()},1e4))}function fi(){tt&&(clearInterval(tt),tt=null)}function b({title:t,class:e,children:n}){return r`
    <div class="card ${e??""}">
      ${t?r`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function U({status:t,label:e}){return r`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function B({label:t,value:e,color:n}){return r`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function _i({agent:t}){return r`
    <div class="agent">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${U} status=${t.status} />
      ${t.current_task?r`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function hi({keeper:t}){return r`
    <div class="live-agent keeper-card">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${U} status=${t.status} />
          ${t.model?r`<span class="pill">${t.model}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>
        ${t.generation!=null?r`<div class="live-agent-meta">
              <span>Gen ${t.generation}</span>
              <span>Turn ${t.turn_count??0}</span>
              ${t.context_ratio!=null?r`<span class=${t.context_ratio>.7?"warn-metric":""}>
                    Ctx ${Math.round(t.context_ratio*100)}%
                  </span>`:null}
            </div>`:null}
      </div>
    </div>
  `}function Se(){const t=fn.value,e=ct.value,n=Lt.value,i=mn.value;return r`
    <div class="stats-grid">
      <${B} label="Agents" value=${e.length} />
      <${B} label="Active" value=${ci.value.length} color="#4ade80" />
      <${B} label="Keepers" value=${n.length} color="#22d3ee" />
      <${B} label="Tasks" value=${Rt.value.length} />
      <${B} label="In Progress" value=${i.inProgress.length} color="#fbbf24" />
      <${B} label="Done" value=${i.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${b} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?r`<div class="empty-state">No agents connected</div>`:e.map(s=>r`<${_i} key=${s.name} agent=${s} />`)}
        </div>
      <//>

      <${b} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?r`<div class="empty-state">No keepers active</div>`:n.map(s=>r`<${hi} key=${s.name} keeper=${s} />`)}
        </div>
      <//>
    </div>

    ${Z.value?r`
        <${b} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${Z.value.running?"Running":"Stopped"}</span>
            ${Z.value.goal?r`<span>Goal: ${Z.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?r`
        <${b} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            <span>Uptime: ${$i(t.uptime_seconds)}</span>
          </div>
        <//>
      `:null}
  `}function $i(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function mi(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),i=Math.floor((e-n)/1e3);if(i<60)return`${i}s ago`;const s=Math.floor(i/60);if(s<60)return`${s}m ago`;const a=Math.floor(s/60);return a<24?`${a}h ago`:`${Math.floor(a/24)}d ago`}function H({timestamp:t}){const e=mi(t);return r`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}function gi({text:t}){if(!t)return null;const e=yi(t);return r`<div class="markdown-content">${e}</div>`}function yi(t){const e=t.split(`
`),n=[];let i=0;for(;i<e.length;){const s=e[i];if(/^(`{3,}|~{3,})/.test(s)){const o=s.match(/^(`{3,}|~{3,})/)[0],c=s.slice(o.length).trim(),d=[];for(i++;i<e.length&&!e[i].startsWith(o);)d.push(e[i]),i++;i++,n.push(r`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const o=[],c=s.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&o.push(c),i++;i<e.length&&!e[i].includes("</think>");)o.push(e[i]),i++;if(i<e.length){const u=e[i].replace("</think>","").trim();u&&o.push(u),i++}const d=o.join(`
`).trim();n.push(r`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ot(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const o=[];for(;i<e.length&&e[i].startsWith("> ");)o.push(e[i].slice(2)),i++;n.push(r`<blockquote>${Ot(o.join(`
`))}</blockquote>`);continue}if(s.trim()===""){i++;continue}const a=[];for(;i<e.length;){const o=e[i];if(o.trim()===""||/^(`{3,}|~{3,})/.test(o)||o.startsWith("> ")||o.trim().startsWith("<think>"))break;a.push(o),i++}a.length>0&&n.push(r`<p>${Ot(a.join(`
`))}</p>`)}return n}function Ot(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let i=0,s;for(;(s=n.exec(t))!==null;){if(s.index>i&&e.push(t.slice(i,s.index)),s[1]){const a=s[1].slice(1,-1);e.push(r`<code>${a}</code>`)}else if(s[2]){const a=s[2].slice(2,-2);e.push(r`<strong>${a}</strong>`)}else if(s[3]){const a=s[3].slice(1,-1);e.push(r`<em>${a}</em>`)}else s[4]&&s[5]&&e.push(r`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);i=s.index+s[0].length}return i<t.length&&e.push(t.slice(i)),e.length>0?e:[t]}let bi=0;const ft=h([]);function N(t,e="success",n=4e3){const i=++bi;ft.value=[...ft.value,{id:i,message:t,type:e}],setTimeout(()=>{ft.value=ft.value.filter(s=>s.id!==i)},n)}const xi=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],et=h([]),nt=h(!1),it=h(""),ki=h("dashboard-user"),st=h(!1);async function yn(t){nt.value=!0,et.value=[];try{const e=await ii(t);et.value=e.comments??[]}catch{}finally{nt.value=!1}}async function Ce(t){const e=it.value.trim();if(e){st.value=!0;try{await si(t,ki.value,e),it.value="",N("Comment posted","success"),await yn(t),O()}catch{N("Failed to post comment","error")}finally{st.value=!1}}}function wi(){const t=we.value;return r`
    <div class="board-controls">
      ${xi.map(e=>r`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{we.value=e.id,O()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function bn({flair:t}){return t?r`<span class="post-flair ${t}">${t}</span>`:null}function Si({post:t}){const e=async(n,i)=>{i.stopPropagation(),await vn(t.id,n),O()};return r`
    <div class="board-post" onClick=${()=>Bn(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${bn} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${H} timestamp=${t.created_at} />
          ${t.comment_count>0?r`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?r`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function Ci({comments:t}){return t.length===0?r`<div class="empty-state" style="font-size:13px">No comments yet</div>`:r`
    <div class="comment-thread">
      ${t.map(e=>r`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${H} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Ti({postId:t}){return r`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${it.value}
        onInput=${e=>{it.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Ce(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${st.value}
      />
      <button
        onClick=${()=>Ce(t)}
        disabled=${st.value||it.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${st.value?"...":"Post"}
      </button>
    </div>
  `}function Pi({post:t}){et.value.length===0&&!nt.value&&yn(t.id);const e=async n=>{await vn(t.id,n),O()};return r`
    <div>
      <button class="back-btn" onClick=${()=>At("board")}>← Back to Board</button>
      <${b} title=${r`${t.title} <${bn} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${gi} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${H} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?r`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${b} title="Comments (${nt.value?"...":et.value.length})">
        ${nt.value?r`<div class="loading-indicator">Loading comments...</div>`:r`<${Ci} comments=${et.value} />`}
        <${Ti} postId=${t.id} />
      <//>
    </div>
  `}function Ai(){const t=_n.value,e=Qt.value,n=A.value.postId;if(n){const i=t.find(s=>s.id===n);return i?r`<${Pi} post=${i} />`:r`
          <div>
            <button class="back-btn" onClick=${()=>At("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return r`
    <${wi} />
    ${e?r`<div class="loading-indicator">Loading board...</div>`:t.length===0?r`<div class="empty-state">No posts yet</div>`:r`<div class="board-post-list">
            ${t.map(i=>r`<${Si} key=${i.id} post=${i} />`)}
          </div>`}
  `}function Ni({msg:t}){return r`
    <div class="message-row">
      <span class="message-author">${t.from??"system"}</span>
      <span class="message-content">${t.content}</span>
      <${H} timestamp=${t.timestamp} />
    </div>
  `}function Ri(){const t=pn.value;return r`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${t.length===0?r`<div class="empty-state">No recent activity</div>`:t.slice(0,50).map((e,n)=>r`<${Ni} key=${n} msg=${e} />`)}
      </div>
    </div>
  `}const ae=h(null);function Li(t){ae.value=t}function Te(){ae.value=null}function Ei({keeper:t}){const e=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return r`
    <div class="keeper-kpis">
      ${e.map(n=>r`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${n.label}</div>
          <div class="keeper-kpi-value">${n.value}</div>
          ${n.hint?r`<div class="keeper-kpi-hint">${n.hint}</div>`:null}
        </div>
      `)}
    </div>
  `}function Di({keeper:t}){const e=t.context_ratio;if(e==null)return null;const n=Math.round(e*100),i=n>80?"bad":n>60?"warn":"";return r`
    <div class="keeper-chart-card">
      <div class="keeper-chart-container" style="display: flex; align-items: flex-end; gap: 2px; padding: 0 20px;">
        <div style="flex:1; background: rgba(74,222,128,0.3); height: ${Math.min(n,100)}%; border-radius: 4px 4px 0 0; min-height: 4px; transition: height 0.3s;" />
        <div style="flex:1; background: rgba(255,255,255,0.06); height: 100%; border-radius: 4px 4px 0 0;" />
      </div>
      <div class="keeper-chart-meta">
        Context usage: <span class=${i}>${n}%</span>
        ${n>70?r` — <span class="warn">Compaction soon</span>`:null}
        ${n>85?r` — <span class="bad">Handoff imminent</span>`:null}
      </div>
    </div>
  `}const Ut=h("");function Mi({keeper:t}){var s,a;const e=Ut.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((a=t.interests)==null?void 0:a.join(", "))||"-"}],i=e?n.filter(o=>o.title.toLowerCase().includes(e)||o.key.includes(e)||o.value.toLowerCase().includes(e)):n;return r`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Ut.value}
        onInput=${o=>{Ut.value=o.target.value}}
      />
      ${i.map(o=>r`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${o.title}</span>
          <span class="keeper-field-key">${o.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${o.value}</span>
        </div>
      `)}
    </div>
  `}function ji({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return r`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(i=>r`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${i.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${i.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        Level ${t.level} — XP ${t.xp}
      </div>
    </div>
  `}function Ii({items:t}){return t.length===0?r`<div class="empty-state" style="font-size:13px">No equipment</div>`:r`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>r`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Oi({rels:t}){const e=Object.entries(t);return e.length===0?r`<div class="empty-state" style="font-size:13px">No relationships</div>`:r`
    <div class="keeper-k2k-list">
      ${e.map(([n,i])=>r`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${i}</span>
        </div>
      `)}
    </div>
  `}function Pe({traits:t,label:e}){return t.length===0?null:r`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>r`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Ui(){const t=ae.value;return t?r`
    <div
      class="keeper-detail-overlay"
      style="position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${e=>{e.target.classList.contains("keeper-detail-overlay")&&Te()}}
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
            <${U} status=${t.status} />
            ${t.model?r`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Te()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Ei} keeper=${t} />

        ${""}
        <${Di} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${b} title="Field Dictionary">
            <${Mi} keeper=${t} />
          <//>

          ${""}
          <${b} title="Profile">
            <${Pe} traits=${t.traits??[]} label="Traits" />
            <${Pe} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?r`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.last_heartbeat?r`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${H} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.trpg_stats?r`
              <${b} title="TRPG Stats">
                <${ji} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?r`
              <${b} title="Equipment (${t.inventory.length})">
                <${Ii} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?r`
              <${b} title="Relationships (${Object.keys(t.relationships).length})">
                <${Oi} rels=${t.relationships} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `:null}function Hi({agent:t}){return r`
    <div class="agent-card ${t.status}">
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?r`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${U} status=${t.status} />
      </div>
      ${t.current_task?r`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?r`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </div>
  `}function zi({keeper:t}){const e=t.context_ratio!=null?Math.round(t.context_ratio*100):null,n=e!=null?e>80?"bad":e>60?"warn":"":"";return r`
    <div class="live-agent keeper-card" onClick=${()=>Li(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${U} status=${t.status} />
          ${t.model?r`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?r`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="live-agent-meta">
          ${t.generation!=null?r`<span>Gen ${t.generation}</span>`:null}
          ${t.turn_count!=null?r`<span>Turn ${t.turn_count}</span>`:null}
          ${e!=null?r`<span class=${n?`${n}-metric`:""}>Ctx ${e}%</span>`:null}
        </div>
        ${e!=null?r`<div class="ctx-bar"><div class="ctx-fill ${n}" style="width: ${e}%"></div></div>`:null}
      </div>
    </div>
  `}function Bi(){const t=ct.value,e=Lt.value;return r`
    <div>
      ${e.length>0?r`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>r`<${zi} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?r`<div class="empty-state">No agents registered</div>`:r`
            <div class="agent-grid">
              ${t.map(n=>r`<${Hi} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Ht({task:t}){return r`
    <div class="task-row">
      <${U} status=${t.status} />
      <div class="task-info">
        <span class="task-title">${t.title}</span>
        ${t.assignee?r`<span class="task-assignee">${t.assignee}</span>`:null}
      </div>
      ${t.created_at?r`<${H} timestamp=${t.created_at} />`:null}
    </div>
  `}function Fi(){const{todo:t,inProgress:e,done:n}=mn.value;return r`
    <div class="grid-2col">
      <${b} title="In Progress (${e.length})" class="section">
        <div class="task-list">
          ${e.length===0?r`<div class="empty-state">No tasks in progress</div>`:e.map(i=>r`<${Ht} key=${i.id} task=${i} />`)}
        </div>
      <//>

      <${b} title="To Do (${t.length})" class="section">
        <div class="task-list">
          ${t.length===0?r`<div class="empty-state">No pending tasks</div>`:t.map(i=>r`<${Ht} key=${i.id} task=${i} />`)}
        </div>
      <//>
    </div>

    ${n.length>0?r`
        <${b} title="Done (${n.length})" class="section" style="margin-top: 20px">
          <div class="task-list">
            ${n.slice(0,20).map(i=>r`<${Ht} key=${i.id} task=${i} />`)}
            ${n.length>20?r`<div class="empty-state">...and ${n.length-20} more</div>`:null}
          </div>
        <//>
      `:null}
  `}function qi({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",i=t.message??t.content??t.status??"";return r`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${i}</span>
    </div>
  `}function Wi(){const t=Jt.value;return r`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?r`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>r`<${qi} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const zt=h("1d20"),_t=h("idle");function Gi(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Ki(t,e){return e>0?Math.round(t/e*100):0}function Vi({hp:t,max:e}){const n=Ki(t,e),i=Gi(t,e);return r`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${i}" style="width:${n}%" />
    </div>
  `}function Ji({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return r`
    <div class="trpg-actor-stats">
      ${e.map(n=>r`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Xi({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return r`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Zi({actor:t}){return r`
    <div class="trpg-actor">
      <div class="trpg-actor-info">
        <span class="trpg-actor-name">${t.name}</span>
        <${U} status=${t.status??"idle"} />
        <span class="pill">${t.role}</span>
        <${Xi} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?r`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?r`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Vi} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Ji} stats=${t.stats} />
          </div>
        `:null}
    </div>
  `}function Qi({mapStr:t}){return r`<pre class="trpg-map">${t}</pre>`}function Yi({events:t}){return t.length===0?r`<div class="empty-state" style="font-size:13px">No story events yet</div>`:r`
    <div class="trpg-story">
      ${t.slice(-30).map((e,n)=>{var i;return r`
        <div key=${n} class="trpg-event ${e.type??""}">
          ${e.actor?r`<strong>${e.actor}</strong>${" "}`:null}
          ${e.dice_roll?r`<span class="trpg-dice">[${e.dice_roll.notation}: ${(i=e.dice_roll.rolls)==null?void 0:i.join(",")} = ${e.dice_roll.total}${e.dice_roll.modifier?` +${e.dice_roll.modifier}`:""}]</span>${" "}`:null}
          <span class="trpg-event-text">${e.content??""}</span>
          <span style="float:right; font-size:10px; color:#555;"><${H} timestamp=${e.timestamp} /></span>
        </div>
      `})}
    </div>
  `}function ts({state:t}){const e=t.history??[];return e.length===0?null:r`
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
  `}function es({state:t}){var o;const e=$n.value||((o=t.session)==null?void 0:o.room)||"",n=_t.value,i=async()=>{if(!e){N("No room set","error");return}_t.value="running";try{await oi(e),_t.value="ok",N("Round executed","success"),q()}catch{_t.value="error",N("Round failed","error")}},s=async()=>{if(e)try{await li(e),N("Turn advanced","success"),q()}catch{N("Advance failed","error")}},a=async()=>{const c=zt.value.trim();if(!(!e||!c))try{await ri(e,c),N(`Rolled ${c}`,"success"),q()}catch{N("Dice roll failed","error")}};return r`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:flex; gap:4px;">
            <input
              type="text"
              value=${zt.value}
              onInput=${c=>{zt.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&a()}}
              placeholder="1d20+3"
              style="flex:1;"
            />
            <button class="trpg-run-btn secondary" onClick=${a}>Roll</button>
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button
              class="trpg-run-btn recommend"
              onClick=${i}
              disabled=${n==="running"}
            >
              ${n==="running"?"Running...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${s}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${n!=="idle"?r`<div class="trpg-run-status ${n}">${n==="running"?"Processing...":n==="ok"?"Done":"Failed"}</div>`:null}
    </div>
  `}function ns({state:t}){var n;const e=t.current_round;return e?r`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?r`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function is(){var s,a;const t=hn.value;if(Yt.value&&!t)return r`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return r`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>q()}>Refresh</button>
      </div>
    `;const n=t.party??[],i=t.story_log??[];return r`
    <div>
      ${""}
      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((s=t.session)==null?void 0:s.status)??"Active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((a=t.current_round)==null?void 0:a.round_number)??0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${n.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Events</div>
          <div class="stat-value">${i.length}</div>
        </div>
      </div>

      ${""}
      <${ns} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${b} title="Story Log (${i.length})">
            <${Yi} events=${i} />
          <//>

          ${""}
          ${t.map?r`
              <${b} title="Map" style="margin-top:16px;">
                <${Qi} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${b} title="Controls">
            <${es} state=${t} />
          <//>

          ${""}
          <${b} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(o=>r`<${Zi} key=${o.id??o.name} actor=${o} />`)}
              ${n.length===0?r`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?r`
              <${b} title="History (${t.history.length})" style="margin-top:16px;">
                <${ts} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}function ss(){const t=G.value;return r`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      ${St.value>0?r`<span class="event-count">${St.value} events</span>`:null}
    </div>
  `}const as=[{id:"overview",label:"Overview"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function os(){const t=A.value.tab,e=G.value;return r`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${as.map(n=>r`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>At(n.id)}
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
            <strong>${ct.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${Lt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${Rt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${St.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Et(),t==="board"&&O(),t==="trpg"&&q()}}
        >
          Refresh Now
        </button>
      </section>
    </aside>
  `}function rs(){switch(A.value.tab){case"overview":return r`<${Se} />`;case"board":return r`<${Ai} />`;case"activity":return r`<${Ri} />`;case"agents":return r`<${Bi} />`;case"tasks":return r`<${Fi} />`;case"journal":return r`<${Wi} />`;case"trpg":return r`<${is} />`;default:return r`<${Se} />`}}function ls(){return ye(()=>{Fn(),un(),Et();const t=vi();return pi(),()=>{Qn(),t(),fi()}},[]),ye(()=>{const t=A.value.tab;t==="board"&&O(),t==="trpg"&&q()},[A.value.tab]),r`
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
          <${ss} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${Wn} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${Zt.value&&!G.value?r`<div class="loading-indicator">Loading dashboard...</div>`:r`<${rs} />`}
        </main>
        <${os} />
      </div>

      <${Ui} />
    </div>
  `}const Ae=document.getElementById("app");Ae&&Tn(r`<${ls} />`,Ae);
