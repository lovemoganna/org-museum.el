// Canonical providers only; URL content never becomes executable HTML.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const script = fs.readFileSync(require('node:path').join(__dirname,'../resources/org-museum-theme.js'),'utf8').split('/* Shared media:')[1];
const context = {window:{MutationObserver:function(){}}, document:{baseURI:'https://notes.example/pages/note.html',readyState:'loading',addEventListener(){}},URL};
vm.runInNewContext('/* Shared media:'+script,context);
const parse = context.window.orgMuseumMedia.describe;
for (const link of ['https://youtu.be/ag3RnEaB3zM','https://www.youtube.com/watch?v=ag3RnEaB3zM','https://www.youtube.com/embed/ag3RnEaB3zM','https://m.youtube.com/shorts/ag3RnEaB3zM']) {
  assert.equal(parse(link).key,'youtube:ag3RnEaB3zM');
  assert.match(parse(link).src,/autoplay=0/);
}
assert.match(parse('https://youtu.be/ag3RnEaB3zM?t=1h2m3s').src,/start=3723$/);
assert.match(parse('https://www.bilibili.com/video/BV1B7411m7LV?p=2&t=42').src,/bvid=BV1B7411m7LV&p=2&autoplay=0&t=42$/);
assert.match(parse('https://www.bilibili.com/video/av123456/').src,/aid=123456/);
assert.match(parse('https://player.bilibili.com/player.html?bvid=BV1B7411m7LV').src,/bvid=BV1B7411m7LV/);
for(const ext of ['mp3','wav','ogg','m4a','mp4','webm']) assert(parse('../media/test.'+ext+'?version=1'));
assert.equal(parse('../media/test.MP4').kind,'video');
for(const url of ['javascript:alert(1)','data:video/mp4;base64,xxx','https://youtube.com.evil.example/watch?v=ag3RnEaB3zM','https://evil.example/?url=x.mp4','https://www.youtube.com/watch?v=<script>','https://user:secret@www.youtube.com/watch?v=ag3RnEaB3zM','https://www.bilibili.com/video/not-video','https://b23.tv/unknown']) assert.equal(parse(url),null,url);
console.log('PASS: media formats, provider allowlist, canonical identities, timestamps and unsafe URL rejection');
