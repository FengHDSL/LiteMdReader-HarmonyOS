#!/usr/bin/env node
/**
 * shields.io 静态徽章 URL 语义探测（一次性调研工具）
 * ================================================
 * 本地离线渲染铭牌前必须钉死两件事：
 *  ① 路径参数 `label-message-color` 的切分规则（几段、最后一段算不算颜色）；
 *  ② 命名颜色的**真实色值**（shields 的橙色不是 CSS 的 orange，必须实测）。
 *
 * 用法：node tools/probe-shields.js            （联网抓 SVG，结果打印到 stdout）
 * 结果整理后写进 ArkTS 侧的 Badge.ets 颜色表。
 */
'use strict';

const https = require('https');
const fs = require('fs');
const path = require('path');

const CACHE = path.join(__dirname, '.probe-shields-cache');
if (!fs.existsSync(CACHE)) { fs.mkdirSync(CACHE, { recursive: true }); }

function get(url, tries) {
  const key = path.join(CACHE, Buffer.from(url).toString('base64url') + '.svg');
  if (fs.existsSync(key)) { return Promise.resolve(fs.readFileSync(key, 'utf8')); }
  return new Promise((resolve) => {
    const req = https.get(url, { timeout: 20000, headers: { 'user-agent': 'curl/8' } }, (res) => {
      let body = '';
      res.on('data', (d) => { body = body + d; });
      res.on('end', () => {
        if (res.statusCode === 200) { fs.writeFileSync(key, body); }
        resolve(body);
      });
    });
    req.on('timeout', () => { req.destroy(); resolve(''); });
    req.on('error', () => resolve(''));
  }).then((body) => {
    if (body.length === 0 && tries > 0) { return get(url, tries - 1); }
    return body;
  });
}

function summarize(svg) {
  if (svg.length === 0) { return '(no response)'; }
  if (svg.indexOf('<svg') < 0) { return svg.trim().slice(0, 60); }
  const label = (svg.match(/aria-label="([^"]*)"/) || ['', ''])[1];
  const w = (svg.match(/<svg[^>]*width="([^"]*)"/) || ['', '?'])[1];
  const h = (svg.match(/<svg[^>]*height="([^"]*)"/) || ['', '?'])[1];
  const fills = [];
  const re = /<rect[^>]*width="([\d.]+)"[^>]*fill="(#[0-9a-fA-F]{3,8})"/g;
  let m;
  while ((m = re.exec(svg)) !== null) { fills.push(m[1] + 'px/' + m[2]); }
  const texts = [];
  const re2 = /<text[^>]*x="([\d.]+)"[^>]*y="[\d.]+"[^>]*textLength="([\d.]+)"[^>]*>([^<]*)</g;
  while ((m = re2.exec(svg)) !== null) { texts.push(m[3] + '(' + m[2] + ')'); }
  return 'aria="' + label + '" ' + w + 'x' + h + ' rects=[' + fills.join(' ') + '] texts=[' + texts.join(' ') + ']';
}

const CASES = [
  // 段落数语义
  'badge/foo', 'badge/foo-blue', 'badge/version-1.4.1', 'badge/foo-bar-baz',
  'badge/a-b-c-d', 'badge/-red', 'badge/foo--bar-blue', 'badge/a--b--c-green',
  'badge/hello_world__x-y--z-red', 'badge/just%20the%20message-8A2BE2',
  'badge/any_text-you_like-blue', 'badge/PRs-welcome-brightgreen.svg',
  // 命名颜色实测色值
  'badge/c-brightgreen', 'badge/c-green', 'badge/c-yellowgreen', 'badge/c-yellow',
  'badge/c-orange', 'badge/c-red', 'badge/c-blue', 'badge/c-grey', 'badge/c-gray',
  'badge/c-lightgrey', 'badge/c-lightgray', 'badge/c-success', 'badge/c-important',
  'badge/c-critical', 'badge/c-informational', 'badge/c-inactive', 'badge/c-blueviolet',
  'badge/c-ff69b4', 'badge/c-8A2BE2', 'badge/c-abcdef',
  // 查询参数
  'badge/x-y-blue?style=flat-square', 'badge/x-y-blue?style=for-the-badge',
  'badge/x-y-blue?label=Z&color=red', 'badge/x-y-blue?logo=github',
  'static/v1?label=build&message=passing&color=green',
  'badge/x-y-blue?labelColor=abcdef'
];

(async () => {
  for (const c of CASES) {
    const url = 'https://img.shields.io/' + c;
    const svg = await get(url, 2);
    console.log(c.padEnd(52) + ' → ' + summarize(svg));
  }
})();
