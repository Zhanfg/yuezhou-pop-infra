#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json, re, shutil, subprocess
from collections import deque
from pathlib import Path

roots={'vendor':Path('/mnt/auralis_vendor'),'odm':Path('/mnt/auralis_odm')}
out=Path('work/out/donor'); out.mkdir(parents=True,exist_ok=True)
patterns=[
 r'/lib64/soundfx/.*(?:dap|dolby|dlb|spatializer|gamedap).*\.so$',
 r'/lib64/hw/libaudioeffecthal\.qti\.so$',
 r'/lib64/hw/libaudiocorehal\.(?:qti|default)\.so$',
 r'/lib64/(?:libaudio_aidl_conversion_common_ndk|android\.hardware\.audio|android\.media\.audio).*\.so$',
 r'/bin/hw/(?:vendor\.dolby\..*|dvs-aidl-service|dolbycodecservice)$',
 r'/lib64/(?:libcodec2.*(?:dolby|ac4|ddp)|c2\.dolby\..*|libdapparamstorage.*|libdlbpreg.*|libdmshal.*|libdeccfg.*|libdlbdsservice.*|libdolby.*|vendor\.dolby\..*)\.so$',
 r'/etc/dolby/.*',r'/etc/.*(?:dolby|dax|dms|dvs).*\.(?:xml|conf|cfg|json|rc)$',
 r'/etc/(?:audio/[^/]+/)?audio_effects.*\.(?:xml|conf)$',r'/etc/media_codecs.*\.(?:xml|conf)$',
 r'/etc/init/.*(?:dolby|dax|dms|dvs).*\.rc$',r'/etc/vintf/manifest/.*(?:dolby|dax|dms|dvs).*\.xml$',
 r'/etc/audio_algos_ver/.*']
rx=[re.compile(x,re.I) for x in patterns]
common={'libc.so','libm.so','libdl.so','liblog.so','libc++.so','libbase.so','libutils.so','libcutils.so','libbinder_ndk.so','libhidlbase.so','libfmq.so','libhardware.so'}
all_files=[]
for part,root in roots.items():
 for p in root.rglob('*'):
  if p.is_file() or p.is_symlink(): all_files.append((part,root,p))
by_name={}
for part,root,p in all_files: by_name.setdefault(p.name,[]).append((part,root,p))
selected={}
for part,root,p in all_files:
 logical='/' + part + '/' + p.relative_to(root).as_posix()
 hits=[r.pattern for r in rx if r.search(logical)]
 if hits: selected[p]=['target:'+h for h in hits]
def is_elf(p):
 try:
  with p.open('rb') as f:return f.read(4)==b'\x7fELF'
 except OSError:return False
def dynamic(p):
 r=subprocess.run(['readelf','-d',str(p)],text=True,capture_output=True)
 n=re.findall(r'\(NEEDED\).*?\[(.*?)\]',r.stdout); m=re.search(r'\(SONAME\).*?\[(.*?)\]',r.stdout)
 return n,m.group(1) if m else None
def build_id(p):
 r=subprocess.run(['readelf','-n',str(p)],text=True,capture_output=True); m=re.search(r'Build ID:\s*([0-9a-fA-F]+)',r.stdout)
 return m.group(1).lower() if m else None
q=deque([p for p in selected if is_elf(p)]); scanned=set(); unresolved={}
while q:
 elf=q.popleft()
 if elf in scanned:continue
 scanned.add(elf); needed,_=dynamic(elf)
 for dep in needed:
  cands=by_name.get(dep,[])
  if not cands:
   if dep not in common:unresolved.setdefault(str(elf),set()).add(dep)
   continue
  for part,root,p in cands:
   if p not in selected:
    selected[p]=[f'dependency-of:{elf.name}']
    if is_elf(p):q.append(p)
def sha256(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
records=[]
for p in sorted(selected,key=str):
 part=next(k for k,v in roots.items() if p.is_relative_to(v)); root=roots[part]; rel=p.relative_to(root)
 dst=out/'files'/part/rel; dst.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(p,dst,follow_symlinks=True)
 rec={'partition':part,'path':rel.as_posix(),'size':dst.stat().st_size,'sha256':sha256(dst),'reasons':selected[p],'is_elf':is_elf(dst)}
 if rec['is_elf']:
  needed,soname=dynamic(dst);rec.update(build_id=build_id(dst),soname=soname,needed=needed)
  s=' '.join(needed)
  if 'android.hardware.audio.effect-V3-ndk' in s:rec['effect_aidl_generation']='V3'
  elif 'android.hardware.audio.effect-V2-ndk' in s:rec['effect_aidl_generation']='V2'
  elif 'android.hardware.audio.effect' in s:rec['effect_aidl_generation']='unknown-aidl'
 records.append(rec)
manifest={'schema':'auralis-xiaomi-donor-v1','source':{'device':'Xiaomi 15','codename':'dada','build':'OS3.0.303.0.WOCCNXM','android':'16','expected_md5':'527efd383850b9f11b53196b4b6fb89e'},'files':records,'unresolved_noncommon_dependencies':{k:sorted(v) for k,v in unresolved.items()}}
(out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
with (out/'sha256sums.txt').open('w') as f:
 for r in records:f.write(f"{r['sha256']}  files/{r['partition']}/{r['path']}\n")
roles=['libhwdapaidl.so','libswdapaidl.so','libdlbvolaidl.so','libswspatializeraidl.so','libswgamedapaidl.so','libcodec2_soft_ac4dec.so','libcodec2_soft_ddpdec.so','libcodec2_store_dolby.so','vendor.dolby.dms.service']
lines=['# Xiaomi 15 Dolby donor','',f'- files: {len(records)}',f'- ELF: {sum(1 for r in records if r["is_elf"])}','','## Roles']
for role in roles:
 hits=[f"/{r['partition']}/{r['path']}" for r in records if r['path'].endswith(role)]
 lines.append(f"- `{role}`: "+(', '.join(f'`{x}`' for x in hits) if hits else '**missing**'))
(out/'README.md').write_text('\n'.join(lines)+'\n');print('\n'.join(lines))
