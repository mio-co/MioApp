'use strict';
const test = require('node:test');
const assert = require('node:assert');
const u = require('../src/util');

test('hostOf', () => {
  assert.equal(u.hostOf('https://WWW.Example.com./a'), 'www.example.com');
  assert.equal(u.hostOf('mailto:a@b.c'), '');
  assert.equal(u.hostOf('nonsense'), '');
});

test('hostMatches / hostInList', () => {
  assert.ok(u.hostMatches('a.example.com', 'example.com'));
  assert.ok(u.hostMatches('example.com', 'example.com'));
  assert.ok(!u.hostMatches('badexample.com', 'example.com'));
  assert.ok(u.hostMatches('sakune.cloudflareaccess.com', '*.cloudflareaccess.com'));
  assert.ok(!u.hostMatches('cloudflareaccess.com', '*.cloudflareaccess.com'));
  assert.ok(u.hostInList('mio.300031.xyz', ['mio.300031.xyz', 'github.com']));
  assert.ok(!u.hostInList('evil.com', ['mio.300031.xyz']));
});

test('normalizeWhitelistEntry', () => {
  assert.equal(u.normalizeWhitelistEntry('https://www.YouTube.com/watch?v=1'), 'youtube.com');
  assert.equal(u.normalizeWhitelistEntry('example.org'), 'example.org');
  assert.equal(u.normalizeWhitelistEntry('  sub.example.org/path '), 'sub.example.org');
  assert.equal(u.normalizeWhitelistEntry('not a host'), '');
  assert.equal(u.normalizeWhitelistEntry(''), '');
});

test('addressToUrl', () => {
  const s = 'https://www.google.com/search?q=';
  assert.equal(u.addressToUrl('https://a.com/x', s), 'https://a.com/x');
  assert.equal(u.addressToUrl('example.com', s), 'https://example.com');
  assert.equal(u.addressToUrl('example.com/a?b=1', s), 'https://example.com/a?b=1');
  assert.equal(u.addressToUrl('localhost:8080', s), 'https://localhost:8080');
  assert.equal(u.addressToUrl('hello world', s), s + 'hello%20world');
  assert.equal(u.addressToUrl('javascript:alert(1)', s), s + encodeURIComponent('javascript:alert(1)'));
  assert.equal(u.addressToUrl('中文', s), s + encodeURIComponent('中文'));
});

test('filter list helpers', () => {
  assert.ok(!u.looksLikeFilterList('<html>' + 'x'.repeat(2000)));
  assert.ok(u.looksLikeFilterList('! Version: 1.2\n' + '||ads.example^\n'.repeat(100)));
  assert.equal(u.countRules('! c\n[Adblock]\n||a^\n\n##.b\n'), 2);
  assert.equal(u.listVersion('! Title: x\n! Version: 2.0.1\n'), '2.0.1');
});
