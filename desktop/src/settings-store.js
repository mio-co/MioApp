'use strict';
// 设置（userData/settings.json）：拦截开关、白名单、外链用系统浏览器、后台播放
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { normalizeWhitelistEntry, hostInList } = require('./util');

const DEFAULTS = {
  adblockEnabled: true,
  whitelist: [],
  preferSystemBrowser: false,
  backgroundPlayback: true,
  // YouTube 防沉迷（共享脚本 shared/scripts/youtube-focus.js）
  youtubeFocus: true,
  youtubeFocusInterval: 60,
  youtubeFocusPlayables: true,
  // YouTube SponsorBlock（src/media.js）：总开关 + 逗号分隔的分类
  sponsorBlock: true,
  sponsorBlockCategories: 'sponsor,selfpromo,interaction',
};

class SettingsStore extends EventEmitter {
  constructor(file) {
    super();
    this.file = file;
    this.data = { ...DEFAULTS };
    try {
      const j = JSON.parse(fs.readFileSync(file, 'utf8'));
      for (const k of Object.keys(DEFAULTS)) if (k in j && typeof j[k] === typeof DEFAULTS[k]) this.data[k] = j[k];
      if (!Array.isArray(this.data.whitelist)) this.data.whitelist = [];
    } catch {
      // 首次启动 / 文件损坏：默认值
    }
  }

  get(key) {
    return this.data[key];
  }

  all() {
    return { ...this.data, whitelist: [...this.data.whitelist] };
  }

  save() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2));
    fs.renameSync(tmp, this.file);
    this.emit('change', this.all());
  }

  /** 只接受已知键、同类型的值 */
  set(key, value) {
    if (!(key in DEFAULTS) || key === 'whitelist') throw new Error(`unknown setting ${key}`);
    if (typeof value !== typeof DEFAULTS[key]) throw new Error(`bad value for ${key}`);
    if (key === 'youtubeFocusInterval' && !(Number.isFinite(value) && value >= 5 && value <= 3600)) throw new Error(`bad value for ${key}`);
    this.data[key] = value;
    this.save();
  }

  isWhitelisted(host) {
    return !!host && hostInList(host, this.data.whitelist);
  }

  addWhitelist(input) {
    const h = normalizeWhitelistEntry(input);
    if (!h) throw new Error('无效的域名');
    if (!this.data.whitelist.includes(h)) {
      this.data.whitelist.push(h);
      this.data.whitelist.sort();
      this.save();
    }
    return h;
  }

  removeWhitelist(host) {
    const before = this.data.whitelist.length;
    this.data.whitelist = this.data.whitelist.filter((h) => h !== host);
    if (this.data.whitelist.length !== before) this.save();
  }

  /** 当前站点开关：关闭 = 把站点（去掉 www.）加入白名单；打开 = 移除所有匹配它的白名单条目 */
  setSiteEnabled(host, enabled) {
    if (!host) return;
    if (enabled) {
      const { hostMatches } = require('./util');
      const keep = this.data.whitelist.filter((p) => !hostMatches(host, p));
      if (keep.length !== this.data.whitelist.length) {
        this.data.whitelist = keep;
        this.save();
      }
    } else {
      this.addWhitelist(host);
    }
  }
}

module.exports = { SettingsStore, DEFAULTS };
