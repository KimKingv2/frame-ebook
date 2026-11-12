import {
  getReadingEvents, getReadingSetting, setReadingSetting, getPendingReadingEvents,
  markReadingEventsSynced, listBooks
} from "/assets/library-store.js";

const $ = id => document.getElementById(id);
const state = { period:"month", calendarDate:new Date(), goalMinutes:30, localEvents:[], activeEvents:[], remote:false, authenticated:false, remoteStats:null };
const DAY_MS = 86400000;

function dateKey(date) {
  const d = new Date(date.getFullYear(),date.getMonth(),date.getDate());
  return d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0");
}
function parseDay(key) {
  const [y,m,d]=String(key).split("-").map(Number);
  return new Date(y,m-1,d);
}
function startOfWeek(date) {
  const d=new Date(date.getFullYear(),date.getMonth(),date.getDate());
  const day=(d.getDay()+6)%7;
  d.setDate(d.getDate()-day);
  return d;
}
function periodRange(period) {
  const now=new Date();
  let start,end=new Date(now.getFullYear(),now.getMonth(),now.getDate());
  if(period==="week") start=startOfWeek(end);
  else if(period==="month") start=new Date(now.getFullYear(),now.getMonth(),1);
  else if(period==="year") start=new Date(now.getFullYear(),0,1);
  else start=new Date(2000,0,1);
  return {from:dateKey(start),to:dateKey(end),start,end};
}
function formatDuration(seconds) {
  const total=Math.max(0,Math.floor(Number(seconds)||0));
  const hours=Math.floor(total/3600), minutes=Math.floor((total%3600)/60);
  if(hours) return hours+" 小時 "+minutes+" 分鐘";
  return minutes+" 分鐘";
}
function formatShort(seconds) {
  const total=Math.max(0,Math.floor(Number(seconds)||0));
  const h=Math.floor(total/3600),m=Math.floor((total%3600)/60);
  return h ? h+"小時"+(m?m+"分":"") : m+"分鐘";
}
function localSummary(events) {
  const daySeconds={},bookSeconds={},bookTitles={},timeBands=[0,0,0,0],sessions=[];
  let totalSeconds=0;
  for(const event of events){
    const seconds=Math.max(0,Number(event.seconds)||0);
    totalSeconds+=seconds;
    daySeconds[event.dayKey]=(daySeconds[event.dayKey]||0)+seconds;
    bookSeconds[event.bookId]=(bookSeconds[event.bookId]||0)+seconds;
    bookTitles[event.bookId]=event.bookTitle||"未命名書籍";
    const hour=new Date(Number(event.startedAt)||Date.now()).getHours();
    const band=hour>=6&&hour<11?0:hour>=11&&hour<17?1:hour>=17&&hour<23?2:3;
    timeBands[band]+=seconds;
    sessions.push(event);
  }
  sessions.sort((a,b)=>(b.endedAt||0)-(a.endedAt||0));
  const topBooks=Object.keys(bookSeconds).map(id=>({bookId:id,title:bookTitles[id],seconds:bookSeconds[id]})).sort((a,b)=>b.seconds-a.seconds);
  return {totalSeconds,daySeconds,bookSeconds,topBooks,timeBands,sessions};
}
function selectedData(summary,range) {
  const keys=Object.keys(summary.daySeconds).filter(key=>key>=range.from&&key<=range.to);
  const daySeconds={};
  for(const key of keys)daySeconds[key]=summary.daySeconds[key];
  const totalSeconds=Object.values(daySeconds).reduce((sum,value)=>sum+value,0);
  const bookSeconds={},bookTitles={},timeBands=[0,0,0,0],sessions=summary.sessions.filter(item=>item.dayKey>=range.from&&item.dayKey<=range.to);
  for(const item of sessions){
    bookSeconds[item.bookId]=(bookSeconds[item.bookId]||0)+(Number(item.seconds)||0);
    bookTitles[item.bookId]=item.bookTitle||"未命名書籍";
    const hour=new Date(Number(item.startedAt)||Date.now()).getHours();
    const band=hour>=6&&hour<11?0:hour>=11&&hour<17?1:hour>=17&&hour<23?2:3;
    timeBands[band]+=Number(item.seconds)||0;
  }
  const topBooks=Object.keys(bookSeconds).map(id=>({bookId:id,title:bookTitles[id],seconds:bookSeconds[id]})).sort((a,b)=>b.seconds-a.seconds);
  return {totalSeconds,daySeconds,bookSeconds,topBooks,timeBands,sessions};
}
function countReadingDays(daySeconds) {
  return Object.keys(daySeconds).filter(key=>daySeconds[key]>=60).length;
}
function streakInfo(daySeconds) {
  const active=Object.keys(daySeconds).filter(key=>daySeconds[key]>=60).sort();
  const set=new Set(active);
  const today=dateKey(new Date()),yesterday=dateKey(new Date(Date.now()-DAY_MS));
  let current=0, cursor=parseDay(set.has(today)?today:yesterday);
  while(set.has(dateKey(cursor))){current++;cursor=new Date(cursor.getTime()-DAY_MS);}
  let best=0,run=0,previous=null;
  for(const key of active){
    const d=parseDay(key);
    if(previous && d.getTime()-previous.getTime()===DAY_MS)run++;
    else run=1;
    best=Math.max(best,run);
    previous=d;
  }
  return {current,best,total:active.length};
}
function periodDays(range) {
  return Math.max(1,Math.floor((range.end.getTime()-range.start.getTime())/DAY_MS)+1);
}
function renderBars(container,items,unit) {
  container.replaceChildren();
  const max=Math.max(1,...items.map(item=>item.seconds));
  items.forEach(item=>{
    const col=document.createElement("div");col.className="chart-column";
    const em=document.createElement("em");em.textContent=item.seconds?formatShort(item.seconds):"";
    const wrap=document.createElement("div");wrap.className="chart-bar-wrap";
    const bar=document.createElement("div");bar.className="chart-bar";bar.style.height=Math.max(2,item.seconds/max*100)+"%";
    bar.title=item.label+": "+formatDuration(item.seconds);
    wrap.appendChild(bar);
    const label=document.createElement("small");label.textContent=item.label;
    col.append(em,wrap,label);container.appendChild(col);
  });
  if(!items.length)container.innerHTML='<p class="empty-inline">目前還沒有閱讀紀錄。</p>';
}
function buildTrend(summary,range) {
  const items=[];
  const now=new Date(range.end);
  if(state.period==="week"||state.period==="month"){
    const total=state.period==="week"?7:periodDays(range);
    for(let i=0;i<total;i++){
      const d=new Date(range.start.getTime()+i*DAY_MS),key=dateKey(d);
      items.push({label:state.period==="week"?["一","二","三","四","五","六","日"][i]:String(d.getDate()),seconds:summary.daySeconds[key]||0});
    }
  } else if(state.period==="year"){
    for(let m=0;m<12;m++){
      let secs=0;
      Object.keys(summary.daySeconds).forEach(key=>{const d=parseDay(key);if(d.getFullYear()===now.getFullYear()&&d.getMonth()===m)secs+=summary.daySeconds[key];});
      items.push({label:(m+1)+"月",seconds:secs});
    }
  } else {
    const monthly={};
    Object.keys(summary.daySeconds).forEach(key=>{const d=parseDay(key),k=d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0");monthly[k]=(monthly[k]||0)+summary.daySeconds[key];});
    Object.keys(monthly).sort().slice(-12).forEach(key=>items.push({label:key.slice(5)+"月",seconds:monthly[key]}));
  }
  return items;
}
function renderCalendar(summary) {
  const month=state.calendarDate.getMonth(),year=state.calendarDate.getFullYear();
  $("calendar-month-label").textContent=year+" 年 "+(month+1)+" 月";
  const first=new Date(year,month,1),startOffset=(first.getDay()+6)%7,total=new Date(year,month+1,0).getDate();
  const grid=$("reading-calendar");grid.replaceChildren();
  for(let i=0;i<startOffset;i++){const blank=document.createElement("span");blank.textContent="";grid.appendChild(blank);}
  let monthTotal=0;
  const today=dateKey(new Date());
  for(let day=1;day<=total;day++){
    const d=new Date(year,month,day),key=dateKey(d),seconds=summary.daySeconds[key]||0;
    monthTotal+=seconds;
    const button=document.createElement("button");button.type="button";button.textContent=String(day);
    button.title=key+" · "+formatDuration(seconds);
    if(key===today)button.classList.add("today");
    if(seconds>=60){
      const max=7200;
      const level=seconds<900?1:seconds<1800?2:seconds<3600?3:4;
      button.classList.add("level-"+level);
      button.setAttribute("aria-label",key+" 閱讀 "+formatDuration(seconds));
    }
    grid.appendChild(button);
  }
  $("calendar-total").textContent="本月 "+formatDuration(monthTotal);
  $("calendar-prev").disabled=year<2000;
  $("calendar-next").disabled=year===new Date().getFullYear()&&month===new Date().getMonth();
}
function renderTopBooks(summary) {
  const root=$("top-books");root.replaceChildren();
  summary.topBooks.slice(0,5).forEach((book,index)=>{
    const row=document.createElement("div");row.className="top-book-row";
    const rank=document.createElement("span");rank.className="top-book-rank";rank.textContent=String(index+1).padStart(2,"0");
    const copy=document.createElement("div");copy.className="top-book-copy";
    const title=document.createElement("strong");title.textContent=book.title;
    const subtitle=document.createElement("span");subtitle.textContent="本期間累積閱讀";
    copy.append(title,subtitle);
    const time=document.createElement("span");time.className="top-book-time";time.textContent=formatDuration(book.seconds);
    row.append(rank,copy,time);root.appendChild(row);
  });
  if(!root.childElementCount)root.innerHTML='<p class="empty-inline">目前還沒有閱讀紀錄。</p>';
}
function renderTimeBands(summary) {
  const labels=["清晨／上午","白天","傍晚／夜間","深夜"];
  const root=$("time-of-day");root.replaceChildren();
  const max=Math.max(1,...summary.timeBands);
  labels.forEach((label,index)=>{
    const row=document.createElement("div");row.className="time-band";
    const name=document.createElement("span");name.textContent=label;
    const track=document.createElement("div");track.className="time-track";
    const fill=document.createElement("div");fill.className="time-fill";fill.style.width=(summary.timeBands[index]/max*100)+"%";track.appendChild(fill);
    const value=document.createElement("small");value.textContent=formatShort(summary.timeBands[index]);
    row.append(name,track,value);root.appendChild(row);
  });
}
function renderRecent(summary) {
  const root=$("recent-sessions");root.replaceChildren();
  summary.sessions.slice(0,6).forEach(item=>{
    const row=document.createElement("div");row.className="recent-session";
    const copy=document.createElement("div");
    const title=document.createElement("strong");title.textContent=item.bookTitle||"未命名書籍";
    const when=document.createElement("span");when.textContent=item.dayKey+" · "+(item.format||"EPUB");
    copy.append(title,when);
    const time=document.createElement("time");time.textContent=formatShort(item.seconds);
    row.append(copy,time);root.appendChild(row);
  });
  if(!root.childElementCount)root.innerHTML='<p class="empty-inline">完成第一次閱讀後，這裡就會留下紀錄。</p>';
}
function renderGoal(todaySeconds,goalDays) {
  const goalSeconds=state.goalMinutes*60;
  const percent=Math.min(100,Math.round(todaySeconds/goalSeconds*100));
  $("goal-ring").style.setProperty("--goal-progress",percent);
  $("goal-percent").textContent=percent+"%";
  $("today-time").textContent=formatDuration(todaySeconds);
  $("goal-target-label").textContent="每日目標 "+state.goalMinutes+" 分鐘";
  $("goal-select").value=String(state.goalMinutes);
  $("goal-foot-text").textContent=percent>=100?"今日目標已達成，做得很好。": "再讀 "+formatDuration(Math.max(0,goalSeconds-todaySeconds))+" 就達成今日目標。";
  $("goal-days-count").textContent=goalDays+" 天達標";
}
function renderSummary(summary,range,allData) {
  const total=summary.totalSeconds,days=countReadingDays(summary.daySeconds),naturalAverage=Math.round(total/periodDays(range)/60);
  $("period-time").innerHTML=Math.floor(total/3600)+'<span>小時</span> '+Math.floor((total%3600)/60)+'<span>分鐘</span>';
  $("period-time-note").textContent=state.period==="week"?"本週累積閱讀時間":state.period==="year"?"今年累積閱讀時間":state.period==="all"?"所有已記錄的閱讀時間":"本月累積閱讀時間";
  $("reading-days").innerHTML=days+'<span>天</span>';
  $("daily-average").innerHTML=naturalAverage+'<span>分鐘</span>';
  $("books-opened").innerHTML=String(summary.topBooks.length)+'<span>本</span>';
  const allStreak=streakInfo(allData.daySeconds);
  $("current-streak").textContent=allStreak.current;
  $("best-streak").textContent=allStreak.best;
  $("all-reading-days").textContent=allStreak.total;
  $("streak-note").textContent=allStreak.current>0?"連續閱讀第 "+allStreak.current+" 天，保持舒服的節奏。":"今天讀滿 1 分鐘，就能點亮今天的閱讀足跡。";
  const todayKey=dateKey(new Date());
  const todaySeconds=allData.daySeconds[todayKey]||0;
  const goalDays=Object.keys(allData.daySeconds).filter(key=>allData.daySeconds[key]>=state.goalMinutes*60).length;
  renderGoal(todaySeconds,goalDays);
  const bars=buildTrend(summary,range);
  renderBars($("reading-chart"),bars);
  renderTopBooks(summary);
  renderTimeBands(summary);
  renderRecent(summary);
  renderCalendar(allData);
  const mini=$("overview-bars");mini.replaceChildren();
  bars.slice(-14).forEach(item=>{const bar=document.createElement("i");bar.style.height=Math.max(3,item.seconds/Math.max(1,...bars.map(x=>x.seconds))*28)+"px";mini.appendChild(bar);});
}
async function fetchLocalData() {
  const end=dateKey(new Date());
  const events=await getReadingEvents("2000-01-01",end);
  return localSummary(events);
}
async function fetchCloudStats(range) {
  const url="/api/reading/stats?from="+encodeURIComponent(range.from)+"&to="+encodeURIComponent(range.to);
  const response=await fetch(url,{credentials:"same-origin"});
  if(!response.ok)throw new Error("雲端統計暫時無法讀取。");
  return response.json();
}
async function refresh() {
  try {
    state.goalMinutes=Number(await getReadingSetting("goalMinutes",30))||30;
    const allData=await fetchLocalData();
    const range=periodRange(state.period);
    let summary=selectedData(allData,range);
    if(state.authenticated){
      try{
        const remote=await fetchCloudStats(range);
        state.remoteStats=remote;
        const remoteDays={};
        (remote.days||[]).forEach(day=>remoteDays[day.dayKey]=Number(day.seconds)||0);
        const remoteAllDays={};
        (remote.allDays||[]).forEach(day=>remoteAllDays[day.dayKey]=Number(day.seconds)||0);
        const remoteSessions=(remote.topBooks||[]).map(book=>({bookId:book.bookId,bookTitle:book.title,seconds:book.seconds,dayKey:range.to,startedAt:Date.now(),format:""}));
        const remoteSummary=localSummary(remoteSessions);
        summary={totalSeconds:Number(remote.totalSeconds)||0,daySeconds:remoteDays,topBooks:(remote.topBooks||[]).map(book=>({bookId:book.bookId,title:book.title,seconds:book.seconds})),timeBands:remote.timeBands||[0,0,0,0],sessions:remote.recentEvents||[]};
        state.remote=true;
        const allDataForRender={daySeconds:Object.keys(remoteAllDays).length?remoteAllDays:allData.daySeconds};
      }catch(_){state.remote=false;summary=selectedData(allData,range);}
    } else state.remote=false;
    const rangeLabel=state.period==="week"?"本週":state.period==="month"?"本月":state.period==="year"?"今年":"累計";
    $("period-label").textContent=rangeLabel+" · "+range.from+" 至 "+range.to+(state.remote?" · 雲端合併":" · 本機紀錄");
    renderSummary(summary,range,(state.authenticated&&state.remote&&typeof allDataForRender!=="undefined")?allDataForRender:allData);
    $("cloud-sync-status").textContent=state.authenticated
      ? (state.remote?"雲端閱讀統計已同步，包含這個帳戶的其他裝置紀錄。":"已登入，雲端統計暫不可用，先顯示本機資料。")
      : "目前在這台設備記錄。登入雲端後，可以把閱讀紀錄同步到 D1。";
  }catch(error){
    $("cloud-sync-status").textContent="讀取統計失敗："+(error.message||String(error));
  }
}
async function checkSession() {
  try{
    const response=await fetch("/api/auth/session",{credentials:"same-origin"});
    if(!response.ok)return;
    const data=await response.json();
    state.authenticated=!!data.authenticated;
    $("cloud-login-form").hidden=state.authenticated;
    $("cloud-account-actions").hidden=!state.authenticated;
    if(state.authenticated){
      $("cloud-account-label").textContent=data.openListConfigured?"雲端閱讀統計已連線":"統計已登入，OpenList 尚未設定";
      const tracker=await import("/assets/reading-tracker.js");
      await tracker.syncPending(true);
    }
  }catch(_){}
}
async function login(event) {
  event.preventDefault();
  const password=$("cloud-password").value;
  if(!password)return;
  const button=$("cloud-login-form").querySelector("button");
  button.disabled=true;
  try{
    const response=await fetch("/api/auth/login",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json"},body:JSON.stringify({password})});
    const data=await response.json();
    if(!response.ok)throw new Error(data.error||"登入失敗。");
    state.authenticated=true;
    $("cloud-password").value="";
    $("cloud-login-form").hidden=true;
    $("cloud-account-actions").hidden=false;
    $("cloud-account-label").textContent=data.openListConfigured?"雲端統計已連線":"統計已登入，OpenList 尚未設定";
    const tracker=await import("/assets/reading-tracker.js");
    await tracker.syncPending(true);
    await refresh();
  }catch(error){$("cloud-sync-status").textContent=error.message||String(error);}
  finally{button.disabled=false;}
}
async function logout() {
  try{await fetch("/api/auth/logout",{method:"POST",credentials:"same-origin"});}catch(_){}
  state.authenticated=false;$("cloud-login-form").hidden=false;$("cloud-account-actions").hidden=true;
  await refresh();
}
function download(filename,type,content) {
  const blob=new Blob([content],{type});
  const url=URL.createObjectURL(blob);
  const link=document.createElement("a");link.href=url;link.download=filename;link.click();
  URL.revokeObjectURL(url);
}
async function exportData(kind) {
  const range=periodRange(state.period);
  const events=await getReadingEvents(range.from,range.to);
  const summary=localSummary(events);
  if(kind==="json"){
    download("frame-reader-reading-"+state.period+".json","application/json;charset=utf-8",JSON.stringify({period:state.period,from:range.from,to:range.to,summary,events},null,2));
  }else{
    const rows=[["日期","書名","格式","閱讀秒數","開始時間","結束時間"]];
    events.forEach(event=>rows.push([event.dayKey,event.bookTitle,event.format,event.seconds,new Date(event.startedAt).toISOString(),new Date(event.endedAt).toISOString()]));
    const csv=rows.map(row=>row.map(value=>'"'+String(value??"").replace(/"/g,'""')+'"').join(",")).join("\r\n");
    download("frame-reader-reading-"+state.period+".csv","text/csv;charset=utf-8","\uFEFF"+csv);
  }
}
document.querySelectorAll("[data-period]").forEach(button=>button.addEventListener("click",()=>{state.period=button.dataset.period;document.querySelectorAll("[data-period]").forEach(item=>item.setAttribute("aria-pressed",item===button?"true":"false"));refresh();}));
$("goal-select").addEventListener("change",async event=>{state.goalMinutes=Number(event.target.value)||30;await setReadingSetting("goalMinutes",state.goalMinutes);refresh();});
$("calendar-prev").addEventListener("click",()=>{state.calendarDate=new Date(state.calendarDate.getFullYear(),state.calendarDate.getMonth()-1,1);fetchLocalData().then(renderCalendar);});
$("calendar-next").addEventListener("click",()=>{state.calendarDate=new Date(state.calendarDate.getFullYear(),state.calendarDate.getMonth()+1,1);fetchLocalData().then(renderCalendar);});
$("cloud-login-form").addEventListener("submit",login);
$("cloud-sync-now").addEventListener("click",async()=>{const tracker=await import("/assets/reading-tracker.js");await tracker.syncPending(true);await refresh();});
$("cloud-logout").addEventListener("click",logout);
$("export-json").addEventListener("click",()=>exportData("json"));
$("export-csv").addEventListener("click",()=>exportData("csv"));
await checkSession();
await refresh();
window.addEventListener("focus",refresh);
window.addEventListener("frame-reader-reading-time",refresh);
