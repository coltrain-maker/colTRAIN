// Persist only Supabase auth credentials, and only after explicit personal-device consent.
const CHOICE='coltrain-remember-device',MODE='coltrain-device-mode';
const parse=value=>{try{return JSON.parse(value);}catch{return null;}};
const read=(store,key)=>{try{return store?.getItem(key)??null;}catch{return null;}};
const remove=(store,key)=>{try{store?.removeItem(key);}catch{}};
export function createPersonalSessionStorage({session,local,authKey}){
 const keys=[authKey,authKey+'-code-verifier',authKey+'-user'];
 let remembered=read(local,CHOICE)==='yes'&&read(local,MODE)==='personal',failed=false;
 let person=parse(read(session,authKey))?.user?.id||null;
 const permitted=()=>remembered&&read(local,CHOICE)==='yes'&&read(local,MODE)==='personal';
 const samePerson=value=>!person||!parse(value)?.user?.id||parse(value).user.id===person;
 const write=(store,key,value)=>{try{if(!store)return false;store.setItem(key,value);return store.getItem(key)===value;}catch{return false;}};
 function getItem(key){
  if(!keys.includes(key))return read(session,key);
  if(permitted()){
   const token=read(local,authKey);
   // Another tab's account must never replace the account currently displayed here.
   if(token&&samePerson(token)||!token&&!person){
    person ||= parse(token)?.user?.id||null;
    const value=read(local,key);if(value!==null)write(session,key,value);return value;
   }
  }
  const value=read(session,key);if(key===authKey&&value)person ||= parse(value)?.user?.id||null;
  return value;
 }
 function setItem(key,value){
  if(key===authKey)person=parse(value)?.user?.id||person;
  write(session,key,value);
  if(keys.includes(key)&&permitted()){
   const existing=read(local,authKey);
   if(existing&&!samePerson(existing)){remembered=false;return;}
   if(!write(local,key,value)){failed=true;remembered=false;remove(local,CHOICE);for(const saved of keys)remove(local,saved);}
  }
 }
 function removeItem(key){
  remove(session,key);
  if(keys.includes(key)&&samePerson(read(local,authKey)))remove(local,key);
 }
 function setRemember(enabled){
  // First preserve the current session before moving/clearing any persistent copy.
  const current=read(local,authKey);
  const values=keys.map(key=>[key,remembered&&current&&samePerson(current)?read(local,key):getItem(key)]);
  for(const [key,value] of values)if(value!==null)write(session,key,value);
  if(!enabled){
   remembered=false;
   if(samePerson(read(local,authKey))){for(const key of keys)remove(local,key);remove(local,CHOICE);}
   failed=false;return true;
  }
  if(read(local,MODE)!=='personal'){failed=true;remembered=false;return false;}
  if(!write(local,CHOICE,'yes')){failed=true;remembered=false;return false;}
  remembered=true;failed=false;
  for(const [key,value] of values){
   if(value===null)remove(local,key);
   else if(!write(local,key,value)){failed=true;remembered=false;remove(local,CHOICE);for(const saved of keys)remove(local,saved);return false;}
  }
  return true;
 }
 function clear(){
  const current=read(local,authKey),mine=samePerson(current);
  for(const key of keys)remove(session,key);
  if(mine){for(const key of keys)remove(local,key);remove(local,CHOICE);}
  remembered=false;person=null;
 }
 // No upgrade silently enrolls an existing user in persistent sign-in.
 return {getItem,setItem,removeItem,setRemember,clear,isRemembered:permitted,failed:()=>failed};
}
