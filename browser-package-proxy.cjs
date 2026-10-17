// Generals X package streaming proxy. Allowlisted catalog IDs only; no arbitrary URL proxying.
const http=require("node:http");
const fs=require("node:fs");
const path=require("node:path");
const {Readable}=require("node:stream");
const catalog=JSON.parse(fs.readFileSync(path.join(__dirname,"launcher_web/hub-catalog.json"),"utf8"));
const origins=new Set(["https://generals-x-web-integrated.onrender.com","https://test-spideywv-generals-x.onrender.com"]);
const server=http.createServer(async(req,res)=>{
  const origin=req.headers.origin;
  if(origin&&origins.has(origin)){res.setHeader("Access-Control-Allow-Origin",origin);res.setHeader("Vary","Origin");}
  res.setHeader("Access-Control-Allow-Methods","GET,HEAD,OPTIONS");
  res.setHeader("Access-Control-Allow-Headers","Range");
  res.setHeader("Access-Control-Expose-Headers","Content-Length,Content-Range,Accept-Ranges");
  if(req.method==="OPTIONS"){res.writeHead(origin&&!origins.has(origin)?403:204);res.end();return;}
  if(req.url==="/health"){res.writeHead(200,{"Content-Type":"text/plain"});res.end("ok");return;}
  const match=/^\/api\/packages\/([a-z0-9-]+)$/.exec(req.url||"");
  if(!match||!["GET","HEAD"].includes(req.method)){res.writeHead(404);res.end("Not found");return;}
  const item=catalog.mods.find(x=>x.profileId===match[1]);
  const url=item?.channels?.stable?.packageURL;
  if(!url||new URL(url).hostname!=="pub-08941af8fe30421ba31f2314049303cb.r2.dev"){res.writeHead(404);res.end("Unknown package");return;}
  const headers={};if(req.headers.range)headers.Range=req.headers.range;
  const abort=new AbortController();req.on("aborted",()=>abort.abort());
  try{
    const upstream=await fetch(url,{headers,signal:abort.signal});
    const out={};for(const h of ["content-type","content-length","content-range","accept-ranges","etag","last-modified"])if(upstream.headers.has(h))out[h]=upstream.headers.get(h);
    res.writeHead(upstream.status,out);
    if(req.method==="HEAD"||!upstream.body){res.end();return;}
    const stream=Readable.fromWeb(upstream.body);stream.on("error",()=>res.destroy());stream.pipe(res);
  }catch(e){if(!res.headersSent)res.writeHead(502,{"Content-Type":"text/plain"});res.end("R2 upstream error");console.error(e.message);}
});
server.listen(Number(process.env.PORT||10000),"0.0.0.0");
