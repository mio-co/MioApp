// YouTube 双语字幕：json3 解析（手动 / 自动生成断句）与时间轴对齐、选轨、播放器叠加层、拦截播放器自己的 timedtext 请求
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadCore, loadPage, fakeNative, until, tick } from './translate-harness.mjs';

const C = loadCore();
const plain = (x) => JSON.parse(JSON.stringify(x));

const MANUAL_JSON3 = {
  wireMagic: 'pb3',
  events: [
    { tStartMs: 0, dDurationMs: 1500, segs: [{ utf8: 'Hello everyone,' }] },
    { tStartMs: 1500, dDurationMs: 2000, segs: [{ utf8: 'welcome to\nthe show.' }] },
    { tStartMs: 3000, dDurationMs: 2000, segs: [{ utf8: 'Today we talk about cats.' }] },
    { tStartMs: 6000, dDurationMs: 1000, segs: [{ utf8: '\n' }], aAppend: 1 },
    { tStartMs: 8000, dDurationMs: 1000, segs: [{ utf8: 'Today we talk about cats.' }] },
  ],
};

// 自动生成：逐词（tOffsetMs），事件互相重叠，换行事件 aAppend
const ASR_JSON3 = {
  events: [
    { tStartMs: 0, dDurationMs: 999999, id: 1, wpWinPosId: 1, wsWinStyleId: 1 },
    { tStartMs: 100, dDurationMs: 4000, wWinId: 1, segs: [{ utf8: 'so' }, { utf8: ' today', tOffsetMs: 300 }, { utf8: ' we', tOffsetMs: 600 }, { utf8: ' are', tOffsetMs: 800 }] },
    { tStartMs: 1200, dDurationMs: 3000, wWinId: 1, segs: [{ utf8: ' going', tOffsetMs: 0 }, { utf8: ' to', tOffsetMs: 200 }, { utf8: ' build', tOffsetMs: 400 }, { utf8: ' a', tOffsetMs: 600 }, { utf8: ' robot.', tOffsetMs: 800 }] },
    { tStartMs: 2100, dDurationMs: 2000, wWinId: 1, aAppend: 1, segs: [{ utf8: '\n' }] },
    { tStartMs: 5000, dDurationMs: 3000, wWinId: 1, segs: [{ utf8: 'first' }, { utf8: ' we', tOffsetMs: 250 }, { utf8: ' need', tOffsetMs: 500 }, { utf8: ' parts', tOffsetMs: 800 }] },
    { tStartMs: 6000, dDurationMs: 3000, wWinId: 1, segs: [{ utf8: ' and', tOffsetMs: 100 }, { utf8: ' tools', tOffsetMs: 300 }] },
  ],
};

test('json3 手动字幕：每个事件一条，合并换行，去掉换行事件，重叠截断，相邻重复合并', () => {
  const cues = C.parseJson3(MANUAL_JSON3);
  assert.deepEqual(plain(cues), [
    { start: 0, end: 1500, text: 'Hello everyone,' },
    { start: 1500, end: 3000, text: 'welcome to the show.' },
    { start: 3000, end: 5000, text: 'Today we talk about cats.' },
    { start: 8000, end: 9000, text: 'Today we talk about cats.' },
  ]);
});

test('json3 自动生成（ASR）：逐词按标点 / 停顿重新断句', () => {
  const cues = C.parseJson3(ASR_JSON3, { asr: true });
  assert.equal(cues.length, 2);
  assert.equal(cues[0].text, 'so today we are going to build a robot.');
  assert.equal(cues[0].start, 100);
  assert.ok(cues[0].end > 2000 && cues[0].end <= 5000);
  assert.equal(cues[1].text, 'first we need parts and tools');
  assert.equal(cues[1].start, 5000);
  // 不传 asr 时按 tOffsetMs 自动识别
  assert.equal(C.parseJson3(JSON.stringify(ASR_JSON3)).length, 2);
});

test('ASR 断句：超长 / 长停顿也会断开', () => {
  const words = [];
  for (let i = 0; i < 40; i++) words.push({ t: i * 200, text: ' word' + i, evEnd: i * 200 + 500 });
  words.push({ t: 20000, text: ' after', evEnd: 21000 });
  const cues = C.sentencesFromWords(words, { maxChars: 60 });
  assert.ok(cues.length >= 3);
  assert.ok(cues.every((c) => c.text.length <= 62));
  assert.equal(cues[cues.length - 1].text, 'after');
  for (let i = 0; i + 1 < cues.length; i++) assert.ok(cues[i].end <= cues[i + 1].start);
});

test('srv3 XML 解析（播放器有时请求 XML 格式）', () => {
  const xml = '<?xml version="1.0"?><timedtext format="3"><body><p t="0" d="1200">Tom &amp; Jerry</p><p t="1500" d="900"><s>Hi</s><s t="200"> there</s></p></body></timedtext>';
  assert.deepEqual(plain(C.parseTimedXml(xml)), [{ start: 0, end: 1200, text: 'Tom & Jerry' }, { start: 1500, end: 2400, text: 'Hi there' }]);
  assert.equal(C.parseTimedtext('').length, 0);
  assert.equal(C.parseTimedtext('<transcript><text start="1.5" dur="2">Old &#39;format&#39;</text></transcript>')[0].text, "Old 'format'");
});

test('cueIndexAt：二分对齐时间轴（空隙返回 -1）', () => {
  const cues = C.parseJson3(MANUAL_JSON3);
  assert.equal(C.cueIndexAt(cues, 0), 0);
  assert.equal(C.cueIndexAt(cues, 1499), 0);
  assert.equal(C.cueIndexAt(cues, 1500), 1);
  assert.equal(C.cueIndexAt(cues, 4999), 2);
  assert.equal(C.cueIndexAt(cues, 6000), -1);
  assert.equal(C.cueIndexAt(cues, 8500), 3);
  assert.equal(C.cueIndexAt([], 10), -1);
});

test('cueBatches：连续句子成批（带上下文），不超过 Bing 单请求上限', () => {
  const cues = Array.from({ length: 100 }, (_, i) => ({ start: i * 1000, end: i * 1000 + 900, text: 'line number ' + i + ' with words' }));
  const b = C.cueBatches(cues);
  assert.deepEqual([].concat(...plain(b)), cues.map((_, i) => i));
  for (const batch of b) {
    assert.ok(batch.length <= 24);
    assert.ok(batch.map((i) => cues[i].text).join('\n').length <= 900);
  }
});

test('选轨：优先与自动字幕同语言的人工字幕，其次自动字幕；源语言已是目标语言时不处理', () => {
  const asr = { baseUrl: 'u1', languageCode: 'en', kind: 'asr', vssId: 'a.en' };
  const en = { baseUrl: 'u2', languageCode: 'en', vssId: '.en' };
  const de = { baseUrl: 'u3', languageCode: 'de', vssId: '.de' };
  const zh = { baseUrl: 'u4', languageCode: 'zh-Hans', vssId: '.zh-Hans' };
  assert.equal(C.pickCaptionTrack([de, asr, en], 'zh-CN'), en);
  assert.equal(C.pickCaptionTrack([de, asr], 'zh-CN'), asr);
  assert.equal(C.pickCaptionTrack([de], 'zh-CN'), de);
  assert.equal(C.pickCaptionTrack([zh, de], 'zh-CN'), de);
  assert.equal(C.pickCaptionTrack([{ baseUrl: 'x', languageCode: 'zh-CN', kind: 'asr' }], 'zh-CN'), null);
  assert.equal(C.pickCaptionTrack([], 'zh-CN'), null);
  assert.equal(C.pickCaptionTrack(undefined, 'zh-CN'), null);
});

test('videoIdFromUrl：watch / embed / shorts(不处理) / 其他站点', () => {
  assert.equal(C.videoIdFromUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1'), 'dQw4w9WgXcQ');
  assert.equal(C.videoIdFromUrl('https://m.youtube.com/watch?v=abcdefghijk'), 'abcdefghijk');
  assert.equal(C.videoIdFromUrl('https://www.youtube.com/embed/abcdefghijk'), 'abcdefghijk');
  assert.equal(C.videoIdFromUrl('https://www.youtube.com/shorts/abcdefghijk'), null);
  assert.equal(C.videoIdFromUrl('https://www.youtube.com/'), null);
  assert.equal(C.videoIdFromUrl('https://example.com/watch?v=x'), null);
});

// ---------------------------------------------------------------- 播放器运行时

const VID = 'abcdefghijk';
const PLAYER_PAGE = `<!doctype html><html><body>
<div id="movie_player" class="html5-video-player"><video></video><div class="ytp-chrome-bottom"><div class="ytp-right-controls"><button class="ytp-subtitles-button"></button></div></div></div>
</body></html>`;

function mockResponse(body, ok = true) {
  return { ok, status: ok ? 200 : 404, text: async () => body, clone() { return mockResponse(body, ok); } };
}

function youtubePage({ tracks, directBody = JSON.stringify(MANUAL_JSON3), playerFetchBody, native, html = PLAYER_PAGE, url = `https://www.youtube.com/watch?v=${VID}` } = {}) {
  const fetched = [];
  let video;
  const page = loadPage(html, {
    url,
    native,
    beforeScript: (w) => {
      w.fetch = async (u) => { fetched.push(String(u)); return mockResponse(String(u).includes('pot=') ? playerFetchBody : directBody); };
      w.ytInitialPlayerResponse = {
        videoDetails: { videoId: VID },
        captions: tracks === null ? undefined : { playerCaptionsTracklistRenderer: { captionTracks: tracks || [{ baseUrl: `https://www.youtube.com/api/timedtext?v=${VID}&lang=en&caps=asr`, languageCode: 'en', vssId: '.en' }] } },
      };
      const player = w.document.getElementById('movie_player');
      if (player) {
        Object.defineProperty(player, 'clientHeight', { value: 480 });
        player.setOptionCalls = [];
        player.loadModule = () => {};
        // 模拟播放器自己加载字幕：请求带 pot 的 URL（经过我们包装后的 fetch）
        player.setOption = (mod, key, val) => { player.setOptionCalls.push([mod, key, val]); w.fetch(`https://www.youtube.com/api/timedtext?v=${VID}&lang=${val.languageCode}${val.kind ? '&kind=' + val.kind : ''}&fmt=json3&pot=XYZ`); };
        video = w.document.querySelector('video');
        let t = 0;
        Object.defineProperty(video, 'currentTime', { get: () => t, set: (v) => { t = v; } });
        Object.defineProperty(video, 'paused', { get: () => true });
      }
    },
  });
  const seek = (sec) => { video.currentTime = sec; video.dispatchEvent(new page.window.Event('timeupdate')); };
  return { ...page, fetched, seek, video, player: page.document.getElementById('movie_player') };
}

const overlayLines = (doc) => {
  const o = [...doc.querySelectorAll('mio-tr-ui')].find((e) => e.children.length === 2 && e.style.position === 'absolute');
  return o && o.style.display !== 'none' ? [...o.children].filter((c) => c.style.display !== 'none').map((c) => c.textContent) : null;
};

test('YouTube：读 captionTracks → 拉 json3 → 批量翻译 → 叠加原文 + 译文两行，跟随播放时间', async () => {
  const yt = youtubePage();
  assert.ok(await until(() => yt.api.state().youtube && yt.api.state().youtube.cues === 4));
  assert.ok(yt.fetched[0].includes('fmt=json3'));
  assert.ok(yt.player.classList.contains('mio-ytsub-on'), '隐藏原生字幕');
  yt.seek(1.6);
  assert.ok(await until(() => { const l = overlayLines(yt.document); return l && l.length === 2; }));
  assert.deepEqual(overlayLines(yt.document), ['welcome to the show.', '[译]welcome to the show.']);
  yt.seek(6.2);
  await tick(20);
  assert.equal(overlayLines(yt.document), null, '字幕空隙里不显示');
  yt.seek(0.2);
  await tick(20);
  assert.deepEqual(overlayLines(yt.document), ['Hello everyone,', '[译]Hello everyone,']);
  // 同一批字幕只翻译一次（带上下文的一批）
  const tt = yt.native.fetches().filter((r) => r.url.includes('ttranslatev3'));
  assert.equal(tt.length, 1);
  assert.equal(new URLSearchParams(tt[0].body).get('text').split('\n').length, 3, '4 句里有一句重复，去重后 3 行');
  // 播放器控制栏里的开关
  const toggle = yt.document.querySelector('.ytp-right-controls mio-tr-ui[data-mio-yt-toggle]');
  assert.ok(toggle);
  toggle.dispatchEvent(new yt.window.MouseEvent('click', { bubbles: true, cancelable: true }));
  await tick(10);
  assert.equal(overlayLines(yt.document), null);
  assert.ok(!yt.player.classList.contains('mio-ytsub-on'), '关掉后恢复原生字幕');
  assert.equal(yt.native.prefs.ytSubs, false);
  assert.equal(toggle.getAttribute('aria-pressed'), 'false');
});

test('YouTube：直接请求拿不到（需要 pot）→ 让播放器加载字幕，从它的请求里截获', async () => {
  const yt = youtubePage({
    tracks: [{ baseUrl: `https://www.youtube.com/api/timedtext?v=${VID}&lang=en&kind=asr`, languageCode: 'en', kind: 'asr', vssId: 'a.en' }],
    directBody: '',
    playerFetchBody: JSON.stringify(ASR_JSON3),
  });
  assert.ok(await until(() => yt.api.state().youtube && yt.api.state().youtube.cues === 2));
  assert.deepEqual(plain(yt.player.setOptionCalls[0]), ['captions', 'track', { languageCode: 'en', kind: 'asr', vss_id: 'a.en' }]);
  yt.seek(5.5);
  assert.ok(await until(() => { const l = overlayLines(yt.document); return l && l[1] === '[译]first we need parts and tools'; }));
});

test('YouTube：无字幕的视频不处理（无叠加层 / 无开关）', async () => {
  const yt = youtubePage({ tracks: null });
  await tick(300);
  assert.equal(yt.document.querySelector('mio-tr-ui[data-mio-yt-toggle]'), null);
  assert.equal(overlayLines(yt.document), null);
  assert.equal(yt.fetched.length, 0);
  assert.equal(yt.api.state().youtube.cues, 0);
});

test('YouTube：字幕已经是目标语言时不处理；关闭 YouTube 双语设置时不注入', async () => {
  const yt = youtubePage({ tracks: [{ baseUrl: `https://www.youtube.com/api/timedtext?v=${VID}&lang=zh-Hans`, languageCode: 'zh-Hans', vssId: '.zh-Hans' }] });
  await tick(300);
  assert.equal(yt.fetched.length, 0);
  const native = fakeNative();
  const off = loadPage(PLAYER_PAGE, { url: `https://www.youtube.com/watch?v=${VID}`, native, config: { youtube: false } });
  await tick(100);
  assert.equal(off.api.state().youtube, null);
});

test('YouTube：设置里关掉开关（ytSubs=false）时不显示，但仍可在播放器里打开', async () => {
  const native = fakeNative();
  const fetched = [];
  const page = loadPage(PLAYER_PAGE, {
    url: `https://www.youtube.com/watch?v=${VID}`,
    native,
    config: { ytSubs: false },
    beforeScript: (w) => {
      w.fetch = async (u) => { fetched.push(u); return mockResponse(JSON.stringify(MANUAL_JSON3)); };
      w.ytInitialPlayerResponse = { videoDetails: { videoId: VID }, captions: { playerCaptionsTracklistRenderer: { captionTracks: [{ baseUrl: `https://www.youtube.com/api/timedtext?v=${VID}&lang=en`, languageCode: 'en' }] } } };
    },
  });
  assert.ok(await until(() => page.api.state().youtube.cues === 4));
  assert.equal(page.api.state().youtube.enabled, false);
  assert.ok(!page.document.getElementById('movie_player').classList.contains('mio-ytsub-on'));
  page.api.configure({ ytSubs: true });
  assert.equal(page.api.state().youtube.enabled, true);
});

test('与 YouTube 防沉迷脚本共存：两边的 history 钩子都生效', async () => {
  const { extractScript } = await import('./harness.mjs');
  const focus = extractScript('youtubeFocus').replace('__MIO_YT_INTERVAL_MS__', '60000');
  const yt = youtubePage({ html: PLAYER_PAGE });
  yt.window.eval(focus);
  assert.ok(await until(() => yt.api.state().youtube.cues === 4));
  yt.window.history.pushState({}, '', '/shorts/xyz');
  await tick(100);
  assert.equal(yt.window.__mioYTReminderCount, 1, '防沉迷提醒照常');
  assert.equal(yt.api.state().youtube.video, null, '离开视频页：字幕叠加层拆掉');
  assert.equal(yt.document.querySelector('mio-tr-ui[data-mio-yt-toggle]'), null);
  yt.window.close(); // 防沉迷脚本的定时提醒计时器
});
