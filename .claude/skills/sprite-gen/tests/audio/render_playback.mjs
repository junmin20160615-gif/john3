// SPDX-License-Identifier: Apache-2.0
// node tests/audio/render_playback.mjs <cases.json> <output-dir> [chromium,webkit]
// PLAYWRIGHT_MODULE may name an installed Playwright entry point.
// PLAYWRIGHT_CHROMIUM_EXECUTABLE explicitly selects an installed Chromium browser.
import assert from 'node:assert/strict';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { dirname, resolve } from 'node:path';
const { chromium, webkit } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const [caseFile, outputDir, engineList = 'chromium,webkit'] = process.argv.slice(2);
const engines = engineList.split(',');
assert.ok(engines.length && new Set(engines).size===engines.length &&
  engines.every(name=>['chromium','webkit'].includes(name)), 'select chromium, webkit, or both');
const cases = JSON.parse(await readFile(caseFile, 'utf8'));
await mkdir(outputDir, { recursive: true });
const modulePath = resolve('sprite_gen/audio/sprite-gen-audio-v2.mjs');
const moduleBytes = await readFile(modulePath);
const digest = createHash('sha256').update(moduleBytes).digest('hex');
const reports = [];
const report = { module_sha256:digest, engines,
  chromium_executable:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || 'bundled', reports };
for (const name of engines) {
  const engine = { chromium, webkit }[name];
  const browser = await engine.launch({ headless: true,
    ...(name==='chromium' && process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ?
      {executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE} : {}) });
  try {
    const page = await browser.newPage();
    await page.goto('about:blank');
    for (const rate of [44100, 48000]) {
      const synthetic = await page.evaluate(async ({ code, rate }) => {
        const { prepareAudioBuffer, createAudioSource } = await import(code);
        const check = (ok, message) => { if (!ok) throw new Error(message); };
        // Non-zero origin and a frame count whose independent rounding differs.
        const meta = { version: 2, sample_rate: 48000, start_frame: 13,
          end_frame: 144019, overlap_frames: 12010 };
        const first = Math.floor(meta.start_frame * rate / 48000);
        const n = Math.floor(meta.end_frame*rate/48000)-first;
        const length = Math.round((meta.end_frame-meta.start_frame-meta.overlap_frames)*rate/48000);
        const count = n-length;
        if (rate===44100) check(n-Math.round(meta.overlap_frames*rate/48000)!==length, 'rounding counterexample missing');
        const input = new AudioBuffer({ sampleRate: rate, length: first+n, numberOfChannels: 2 });
        for (let c=0;c<2;c++) {
          const x=input.getChannelData(c);
          for (let i=0;i<x.length;i++) x[i]=.2*Math.cos(2*Math.PI*(c ? 73 : 1000)*i/rate)+.1*i/x.length;
        }
        // Exercise both integer and fractional resampled lengths through the
        // real decoder and the public source factory, for one-shots and loops.
        const resampling=[];
        for (const waveFrames of [48000, 144003]) {
          const wave=new ArrayBuffer(44+waveFrames*2), view=new DataView(wave);
          const ascii=(offset,text)=>{for(let i=0;i<text.length;i++) view.setUint8(offset+i,text.charCodeAt(i));};
          ascii(0,'RIFF'); view.setUint32(4,36+waveFrames*2,true); ascii(8,'WAVE');
          ascii(12,'fmt '); view.setUint32(16,16,true); view.setUint16(20,1,true);
          view.setUint16(22,1,true); view.setUint32(24,48000,true); view.setUint32(28,96000,true);
          view.setUint16(32,2,true); view.setUint16(34,16,true); ascii(36,'data');
          view.setUint32(40,waveFrames*2,true);
          for(let i=0;i<waveFrames;i++) view.setInt16(44+2*i,Math.round(5000*Math.sin(2*Math.PI*317*i/48000)),true);
          const waveDecoded=await new OfflineAudioContext(1,1,rate).decodeAudioData(wave);
          const waveMeta={version:2,sample_rate:48000,start_frame:0,end_frame:waveFrames,overlap_frames:12000};
          const completeFrames=Math.floor(waveFrames*rate/48000);
          for (const loop of [false, true]) {
            const coordinates={...waveMeta,overlap_frames:loop ? 12000 : 0};
            // The decoder exercises its own rounding. Constructed buffers also
            // enforce the one-frame tolerance and reject two missing frames.
            for (const delta of [null, -1, 0, 7, -2]) {
              const raw=delta===null ? waveDecoded : new AudioBuffer({sampleRate:rate,
                length:completeFrames+delta,numberOfChannels:1});
              if (delta!==null) raw.copyToChannel(waveDecoded.getChannelData(0).subarray(0,raw.length),0);
              const expected=loop ? Math.round((waveFrames-12000)*rate/48000) : Math.min(completeFrames,raw.length);
              const context=new OfflineAudioContext(1,expected*2,rate);
              if (delta===-2) {
                let error;
                try { createAudioSource(context,raw,{loop,playback:coordinates}); } catch (caught) { error=caught; }
                check(error instanceof RangeError && /playback interval/.test(error.message),'two missing frames must be an interval error');
                continue;
              }
              const prepared=prepareAudioBuffer(raw,coordinates);
              const node=createAudioSource(context,raw,{loop,playback:coordinates});
              check(prepared.length===expected,'resampled playback duration changed');
              check(node.loop===loop && node.loopEnd===expected/rate,'source interval is wrong');
              if (!loop) check(prepared.getChannelData(0).every((v,i)=>v===raw.getChannelData(0)[i]),'one-shot samples changed');
              node.connect(context.destination); node.start();
              const rendered=(await context.startRendering()).getChannelData(0), samples=prepared.getChannelData(0);
              let renderError=0;
              for(let i=0;i<rendered.length;i++) renderError=Math.max(renderError,Math.abs(rendered[i]-(loop ? samples[i%expected] : (i<expected ? samples[i] : 0))));
              check(renderError<1e-7,'resampled source rendering changed');
              if (loop) {
                const overlap=Math.min(completeFrames,raw.length)-expected, x=raw.getChannelData(0);
                check((rendered[expected]-rendered[expected-1])-(x[overlap]-x[overlap-1])===0,'resampled wrap error');
                const join=expected-overlap;
                check((samples[join]-samples[join-1])-(x[expected]-x[expected-1])===0,'resampled join error');
              }
              resampling.push({source_frames:waveFrames,complete_frames:completeFrames,
                decoded_frames:raw.length,delta,loop,length:prepared.length,render_error:renderError});
            }
          }
        }
        for (const overlap of [0, 1]) {
          const coordinates=overlap ? {version:2,sample_rate:rate,start_frame:0,end_frame:12,overlap_frames:2}
            : {version:2,sample_rate:rate*2,start_frame:0,end_frame:24,overlap_frames:2};
          const raw=new AudioBuffer({sampleRate:rate,length:11,numberOfChannels:1});
          let error;
          try { createAudioSource(new OfflineAudioContext(1,12,rate),raw,{loop:true,playback:coordinates}); }
          catch (caught) { error=caught; }
          check(error instanceof RangeError && /overlap too short after decoder one-frame shortfall/.test(error.message),
            `mapped overlap ${overlap} must be an explicit shortfall error`);
        }
        const minimumRateInput=new AudioBuffer({sampleRate:8000,length:7999,numberOfChannels:1});
        for(let i=0;i<minimumRateInput.length;i++) minimumRateInput.getChannelData(0)[i]=.1*Math.sin(i/5);
        const minimumRateMeta={version:2,sample_rate:48000,start_frame:0,end_frame:48005,overlap_frames:21};
        const minimumRateBuffer=prepareAudioBuffer(minimumRateInput,minimumRateMeta);
        check(minimumRateBuffer.length===7997,'minimum supported rate lost the declared loop length');
        check(minimumRateBuffer.getChannelData(0).every(Number.isFinite),'minimum overlap generated nonfinite samples');
        const before = input.getChannelData(0).slice();
        const out = prepareAudioBuffer(input, meta);
        check(out.length === length, 'one-frame rounding drift');
        check(prepareAudioBuffer(input, meta) === out, 'decoded input was prepared twice');
        check(prepareAudioBuffer(out, meta) === out, 'prepared output was crossfaded twice');
        check(input.getChannelData(0).every((v,i)=>v===before[i]), 'decoded source mutated');
        for (let c=0;c<2;c++) {
          const x=input.getChannelData(c), y=out.getChannelData(c);
          const expected=x[first+count]-x[first+count-1];
          check((y[0]-y.at(-1))-expected === 0, 'added wrap error');
          const middle=n-2*count;
          check((y[middle]-y[middle-1])-(x[first+n-count]-x[first+n-count-1])===0, 'added join error');
          // The detector must reject an artificial discontinuity, even though
          // a high-frequency signal's normal adjacent difference is allowed.
          const control=y.slice(); control[0]+=.125;
          check(Math.abs((control[0]-control.at(-1))-expected)>.12, 'broken negative control');
        }
        let rejected=false;
        try { prepareAudioBuffer(out, { ...meta, overlap_frames: 12011 }); } catch { rejected=true; }
        check(rejected, 'changed metadata reused prepared audio');
        const ctx=new OfflineAudioContext(2, length*3, rate);
        const source=createAudioSource(ctx,input,{loop:true,playback:meta});
        check(source.buffer.length===out.length+1 && source.loop && source.loopStart===0 && source.loopEnd===out.duration, 'source bypasses preparation');
        check(createAudioSource(ctx,out,{loop:true,playback:meta}).buffer===source.buffer, 'guarded playback buffer was rebuilt');
        for(let c=0;c<2;c++) {
          const data=source.buffer.getChannelData(c);
          check(data[length]===out.getChannelData(c)[0], 'missing cyclic interpolation sample');
          check(data.subarray(0,length).every((v,i)=>v===out.getChannelData(c)[i]), 'guard changed the prepared samples');
        }
        source.connect(ctx.destination); source.start();
        const rendered=await ctx.startRendering();
        let maxError=0;
        for(let c=0;c<2;c++) for(let i=0;i<rendered.length;i++) {
          maxError=Math.max(maxError,Math.abs(rendered.getChannelData(c)[i]-out.getChannelData(c)[i%length]));
        }
        check(maxError<1e-7, 'rendered looping differs from prepared buffer');
        // Choose synthetic lengths on both sides of the duration round-trip.
        const roundTrips=[];
        for(const direction of [-1,1]) {
          let frames=rate;
          while(frames<2*rate && Math.sign((frames/rate)*rate-frames)!==direction) frames++;
          check(frames<2*rate, 'duration round-trip counterexample missing');
          const raw=new AudioBuffer({sampleRate:rate,length:frames+128,numberOfChannels:1});
          const data=raw.getChannelData(0);
          for(let i=0;i<data.length;i++) data[i]=.2*Math.cos(2*Math.PI*317*i/rate)+.1;
          const coordinates={version:2,sample_rate:rate,start_frame:0,end_frame:raw.length,overlap_frames:128};
          const prepared=prepareAudioBuffer(raw,coordinates);
          const renderContext=new OfflineAudioContext(1,frames*4,rate);
          const node=createAudioSource(renderContext,raw,{loop:true,playback:coordinates});
          node.connect(renderContext.destination);node.start();
          const samples=(await renderContext.startRendering()).getChannelData(0);
          const baseline=data[128]-data[127];
          for(let lap=1;lap<4;lap++) {
            const at=lap*frames;
            check((samples[at]-samples[at-1])-baseline===0, 'duration round-trip changed the rendered seam');
          }
          let error=0;
          for(let i=0;i<samples.length;i++) error=Math.max(error,Math.abs(samples[i]-prepared.getChannelData(0)[i%frames]));
          check(error<1e-7, 'duration round-trip changed the loop samples');
          roundTrips.push({frames,duration_frames:(frames/rate)*rate,render_error:error});
        }
        const corrupted = new AudioBuffer({ sampleRate:rate, length, numberOfChannels:2 });
        for(let c=0;c<2;c++) {
          corrupted.copyToChannel(out.getChannelData(c),c);
          corrupted.getChannelData(c)[0]+=.125;
        }
        const controlContext=new OfflineAudioContext(2,length*3,rate);
        const controlSource=controlContext.createBufferSource();
        controlSource.buffer=corrupted; controlSource.loop=true;
        controlSource.loopStart=0; controlSource.loopEnd=corrupted.duration;
        controlSource.connect(controlContext.destination); controlSource.start();
        const controlRender=await controlContext.startRendering();
        let controlError=0, controls=0;
        for(let c=0;c<2;c++) {
          const x=input.getChannelData(c), r=controlRender.getChannelData(c);
          const baseline=x[first+count]-x[first+count-1];
          for(let lap=1;lap<3;lap++) {
            const at=lap*length, error=Math.abs((r[at]-r[at-1])-baseline);
            controlError=Math.max(controlError,error);
            if(error>.12) controls++;
          }
        }
        check(controls===4, 'rendered discontinuity control escaped detection');
        return { length, count, duration_round_trips:roundTrips, added_wrap_error:0, added_join_error:0,
          controls_detected:controls, control_added_wrap_error:controlError, render_error:maxError,
          resampling };
      }, { code: `data:text/javascript;base64,${moduleBytes.toString('base64')}`, rate });
      reports.push({ browser:name, browser_version:browser.version(), rate, synthetic });
      for (const item of cases) {
        const manifestPath = resolve(dirname(caseFile), item.manifest);
        const pack = JSON.parse(await readFile(manifestPath,'utf8'));
        const record = item.id ? pack.audio[item.id] : pack;
        const shipped = record.player ? await readFile(resolve(dirname(manifestPath), record.player.path)) : moduleBytes;
        assert.equal(createHash('sha256').update(shipped).digest('hex'), digest);
        if (record.player) assert.equal(record.player.sha256, digest);
        for (const fmt of ['ogg','m4a']) {
          const bytes = await readFile(resolve(dirname(manifestPath),record.files[fmt].path));
          assert.equal(createHash('sha256').update(bytes).digest('hex'),record.files[fmt].sha256);
          const result = await page.evaluate(async ({code,encoded,record,rate}) => {
            const { prepareAudioBuffer, createAudioSource } = await import(code);
            const data=Uint8Array.from(atob(encoded),c=>c.charCodeAt(0));
            const decoder=new OfflineAudioContext(2,1,rate);
            const decoded=await decoder.decodeAudioData(data.buffer);
            const buffer=prepareAudioBuffer(decoded,record.playback);
            const m=record.playback, map=f=>f*decoded.sampleRate/m.sample_rate;
            const first=Math.floor(map(m.start_frame)), last=Math.floor(map(m.end_frame));
            if (decoded.length<last-1) throw new Error('decoded interval is more than one frame short');
            const n=Math.min(last,decoded.length)-first;
            const length=m.overlap_frames ? Math.round(map(m.end_frame-m.start_frame-m.overlap_frames)) : n, count=n-length;
            if (buffer.length!==length) throw new Error('wrong prepared duration');
            const context=new OfflineAudioContext(buffer.numberOfChannels,length*3,rate);
            const source=createAudioSource(context,decoded,record);
            source.connect(context.destination); source.start();
            const rendered=await context.startRendering();
            let wrap=0, join=0, renderError=0, controls=0;
            for (let c=0;c<buffer.numberOfChannels;c++) {
              const x=decoded.getChannelData(c), y=buffer.getChannelData(c), r=rendered.getChannelData(c);
              if (record.loop) {
                const baseline=x[first+count]-x[first+count-1];
                for(let lap=1;lap<3;lap++) {
                  const at=lap*length;
                  wrap=Math.max(wrap,Math.abs((r[at]-r[at-1])-baseline));
                  if(Math.abs((r[at]+.125-r[at-1])-baseline)>.12) controls++;
                }
                const at=n-2*count;
                join=Math.max(join,Math.abs((y[at]-y[at-1])-(x[first+n-count]-x[first+n-count-1])));
              }
              for(let i=0;i<r.length;i++) {
                const expected=record.loop ? y[i%length] : (i<length ? y[i] : 0);
                renderError=Math.max(renderError,Math.abs(r[i]-expected));
              }
            }
            const pcmFrames=record.loop ? rendered.length : buffer.length;
            const interleaved=new Float32Array(pcmFrames*rendered.numberOfChannels);
            for(let i=0;i<pcmFrames;i++) for(let c=0;c<rendered.numberOfChannels;c++)
              interleaved[i*rendered.numberOfChannels+c]=rendered.getChannelData(c)[i];
            const u8=new Uint8Array(interleaved.buffer);
            let binary=''; for(let i=0;i<u8.length;i+=16384) binary+=String.fromCharCode(...u8.subarray(i,i+16384));
            return { decoded_frames:decoded.length, length, overlap:count, channels:rendered.numberOfChannels,
              added_wrap_error:wrap, added_join_error:join, render_error:renderError, controls_detected:controls,
              pcm:btoa(binary) };
          },{code:`data:text/javascript;base64,${shipped.toString('base64')}`,encoded:bytes.toString('base64'),record,rate});
          assert.equal(result.added_wrap_error,0);
          assert.equal(result.added_join_error,0);
          assert.ok(result.render_error<1e-7);
          if(record.loop) assert.equal(result.controls_detected,result.channels*2);
          const pcmName=`${item.name}-${name}-${rate}-${fmt}.f32`;
          await writeFile(resolve(outputDir,pcmName),Buffer.from(result.pcm,'base64'));
          delete result.pcm;
          reports.push({ name:item.name,browser:name,rate,fmt,loop:record.loop,target_lufs:record.target_lufs,pcm:pcmName,...result });
          await writeFile(resolve(outputDir,'render.json'),JSON.stringify(report,null,2));
        }
      }
    }
  } finally { await browser.close(); }
}
for (const item of cases) for (const rate of [44100,48000]) {
  const rows=reports.filter(row=>row.name===item.name && row.rate===rate);
  assert.equal(rows.length,engines.length*2, 'both codecs must render in every selected engine');
  if(rows[0].loop) assert.equal(new Set(rows.map(row=>row.length)).size,1, 'engine or codec changed the loop length');
  else assert.ok(Math.max(...rows.map(row=>row.length))-Math.min(...rows.map(row=>row.length))<=1,
    'one-shot lengths differ by more than the single-frame decode tolerance');
}
await writeFile(resolve(outputDir,'render.json'),JSON.stringify(report,null,2));
console.log(JSON.stringify({passed:reports.length,module_sha256:digest}));
