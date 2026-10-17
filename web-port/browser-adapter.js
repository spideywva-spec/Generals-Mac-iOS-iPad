/* Browser adapter for the original Generals X launcher. Never loaded by native iOS. */
(() => {
  const dbName = 'generals-x-browser-assets-v1';
  const defaults = ['enhanced','contra-x','contra-007','contra-009'];
  let active = null;
  const state = {engineVersion:'WASM',launcherVersion:'Generals X',launcherWebVersion:'browser',build:'web',online:{profileId:'online',installed:false,healthy:true},mods:defaults.map(profileId=>({profileId,installed:false,healthy:true})),download:{busy:false}};
  const db = () => new Promise((resolve,reject)=>{
    const req=indexedDB.open(dbName,1);
    req.onupgradeneeded=()=>{const d=req.result;d.createObjectStore('files');d.createObjectStore('profiles');};
    req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error);
  });
  async function store(name,mode,fn){
    const d=await db();try{return await new Promise((resolve,reject)=>{
      const tx=d.transaction(name,mode),q=fn(tx.objectStore(name));
      tx.oncomplete=()=>resolve(q?.result);tx.onerror=()=>reject(tx.error);
    });}finally{d.close();}
  }
  const event=(name,payload)=>window.GeneralsXNative?._receive({type:'event',name,payload});
  const update=()=>event('stateChanged',structuredClone(state));
  async function restore(){
    const d=await db();try{const tx=d.transaction('profiles','readonly'),q=tx.objectStore('profiles').getAllKeys();
      await new Promise((resolve,reject)=>{tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);});
      for(const id of q.result){const item=id==='online'?state.online:state.mods.find(m=>m.profileId===id);if(item)item.installed=true;}
    }finally{d.close();}update();
  }
  function chooseFile(){return new Promise((resolve,reject)=>{
    const input=document.createElement('input');input.type='file';input.accept='.zip,.big,.meg,.dat,.ini,.map,.str,.wnd,.csf,.tga,.dds,.w3d';
    input.style.display='none';document.body.append(input);
    input.onchange=()=>{const f=input.files?.[0];input.remove();f?resolve(f):reject(new Error('Файл не выбран'));};
    input.click();
  });}
  async function download(url,id){
    const controller=new AbortController();active.controller=controller;
    const response=await fetch(url,{signal:controller.signal});
    if(!response.ok)throw new Error('HTTP '+response.status);
    const total=Number(response.headers.get('content-length'))||0;
    const reader=response.body?.getReader();if(!reader)return await response.blob();
    const parts=[];let received=0;
    while(true){
      const {done,value}=await reader.read();if(done)break;
      while(active?.paused)await new Promise(r=>setTimeout(r,100));
      if(active?.cancelled)throw new DOMException('Cancelled','AbortError');
      parts.push(value);received+=value.byteLength;
      state.download={busy:true,profileId:id,received,total,fraction:total?received/total:0,paused:false};
      event('downloadProgress',state.download);
    }
    return new Blob(parts);
  }
  async function install(id,url){
    if(active)throw new Error('Другая загрузка уже выполняется');
    active={id,paused:false,cancelled:false};
    state.download={busy:true,profileId:id,fraction:0,received:0,total:0,paused:false};update();
    try{
      const file=url?await download(url,id):await chooseFile();
      const name=file.name||new URL(url).pathname.split('/').pop()||'package.zip';
      const bytes=await file.arrayBuffer();
      const zip=/\.zip$/i.test(name);
      if(zip && !window.JSZip)throw new Error('ZIP библиотека не загружена');
      const entries=zip?Object.entries((await JSZip.loadAsync(bytes)).files).filter(([,v])=>!v.dir):[[name,null]];
      if(entries.length>20000)throw new Error('Слишком много файлов в архиве');
      let done=0;
      for(const [path,entry] of entries){
        if(active.cancelled)throw new DOMException('Cancelled','AbortError');
        while(active.paused)await new Promise(r=>setTimeout(r,100));
        if(path.startsWith('/')||path.split('/').includes('..'))throw new Error('Небезопасный путь в архиве');
        const data=entry?await entry.async('blob'):new Blob([bytes]);
        await store('files','readwrite',s=>s.put(data,id+'/'+path));
        done++;
        const fraction=done/entries.length;
        state.download={busy:true,profileId:id,fraction,received:done,total:entries.length,paused:false,phase:'extract'};
        event('downloadProgress',state.download);
      }
      await store('profiles','readwrite',s=>s.put({installedAt:Date.now(),files:done},id));
      const item=id==='online'?state.online:state.mods.find(m=>m.profileId===id);
      if(item)item.installed=true;
      event('installComplete',{profileId:id});return structuredClone(state);
    }catch(e){event(e.name==='AbortError'?'downloadCancelled':'installError',{profileId:id,error:e.message});throw e;}
    finally{active=null;state.download={busy:false};update();}
  }
  async function dispatch(action,payload={}){
    const id=payload.profileId||'online';
    switch(action){
      case 'getState':case 'refreshCatalog':return structuredClone(state);
      case 'install':case 'chooseFile':return await install(id,payload.url||((id==='online'?state.online:state.mods.find(m=>m.profileId===id))?.packageURL));
      case 'pauseDownload':if(active)active.paused=true;state.download.paused=true;return structuredClone(state);
      case 'resumeDownload':if(active)active.paused=false;state.download.paused=false;return structuredClone(state);
      case 'cancelDownload':if(active){active.cancelled=true;active.controller?.abort();}return structuredClone(state);
      case 'remove':await store('profiles','readwrite',s=>s.delete(id));{
        const item=id==='online'?state.online:state.mods.find(m=>m.profileId===id);if(item)item.installed=false;
      }update();return structuredClone(state);
      case 'play':if(!state.online.installed)throw new Error('Сначала установите игровые ресурсы');
        window.GeneralsXWebGame.open();return {ok:true};
      case 'settingsGet':return {values:JSON.parse(localStorage.getItem('gx-settings-'+id)||'{}')};
      case 'settingsSave':localStorage.setItem('gx-settings-'+id,JSON.stringify(payload.values||{}));return {ok:true};
      case 'diagnostics':return {report:'Browser IndexedDB / WASM',fileCount:0};
      case 'setChannel':return structuredClone(state);
      default:throw new Error('Браузерная операция не поддерживается: '+action);
    }
  }
  window.webkit={...(window.webkit||{}),messageHandlers:{...(window.webkit?.messageHandlers||{}),generalsX:{postMessage:async ({id,action,payload})=>{
    try{const result=await dispatch(action,payload);window.GeneralsXNative?._receive({type:'response',id,ok:true,result});}
    catch(e){window.GeneralsXNative?._receive({type:'response',id,ok:false,error:e.message});}
  }}}};
  document.addEventListener('DOMContentLoaded',()=>restore().catch(console.error));
})();
