'use strict';
const status = document.querySelector('#status');
const connect = document.querySelector('#connect');
// Fragment is never sent in HTTP requests; retain in tab memory for this app session only.
const parameters = new URLSearchParams(location.hash.slice(1));
const token = parameters.get('token');
const languageSelector = document.querySelector('#language');
let language = parameters.get('lang') === 'zh-CN' ? 'zh-CN' : 'en';
const messages = {
  en: {
    brand: 'SAYO · ON-DEVICE AI', language: 'Page language', title: 'Connect Gemini Nano',
    intro: 'Sayo uses Chrome’s built-in model to process text on this computer. No API key is needed. Keep this tab open while using this model.',
    limits: 'Official input and output languages: English, Japanese, Spanish, German and French. Sayo also allows Chinese and other languages as experimental use; translations may be incomplete or inaccurate.',
    languageNote: 'Page language changes this interface only. Choose the output language in Sayo.',
    connect: 'Connect model', details: 'Downloads, reconnecting and troubleshooting',
    help: 'Sayo provides this page locally; no website setup is needed. Chrome manages downloads and updates, which require internet access and may use several GB. After closing this tab or restarting Sayo, reconnect from model settings. For model details, open this address in Chrome:',
    checking: 'Checking Chrome…', disconnected: 'Sayo disconnected. Open a new connection from Sayo model settings.',
    missing: 'Prompt API is missing. Use Google Chrome 148 or later.',
    available: 'Model ready. Click Connect model.', unavailable: 'Model unavailable. Check hardware, browser policies and model status at chrome://on-device-internals.',
    downloadable: 'Model download needed. Connecting may download several GB.', downloading: 'Model download in progress. Click Connect model to follow it.',
    checkFailed: 'Could not check the model.', preparing: 'Preparing model…', progress: 'Downloading model: {percent}%',
    connected: 'Connected. Return to Sayo and test the connection.', prepareFailed: 'Could not prepare model ({name}). Check chrome://on-device-internals.',
    requestFailed: 'Request failed. See Sayo for details.', completed: 'Connected · {count} completed', processing: 'Processing locally…'
  },
  'zh-CN': {
    brand: 'SAYO · 本地 AI', language: '页面语言', title: '连接 Gemini Nano',
    intro: 'Sayo 通过 Chrome 内置模型在本机处理文本，无需 API Key。使用期间请保留此标签页。',
    limits: '官方支持的输入和输出语言：英语、日语、西班牙语、德语、法语。中文等其他语言可作为实验性功能使用，Sayo 不作语言限制，但翻译可能不完整或不准确。',
    languageNote: '页面语言仅影响此界面，输出语言请在 Sayo 中选择。',
    connect: '连接模型', details: '下载、重连与故障排查',
    help: '连接页由 Sayo 在本机提供，无需搭建网站。Chrome 负责模型下载和更新，需要联网，可能占用数 GB。关闭页面或重启 Sayo 后，请从模型设置重新连接。模型详情可在 Chrome 中打开以下地址查看：',
    checking: '正在检测 Chrome…', disconnected: 'Sayo 连接已断开，请从 Sayo 模型设置重新连接。',
    missing: '未检测到 Prompt API，请使用 Chrome 148 或更高版本。',
    available: '模型已就绪，请点击「连接模型」。', unavailable: '模型不可用，请在 chrome://on-device-internals 检查硬件、浏览器策略及模型状态。',
    downloadable: '需要下载模型，连接时可能下载数 GB。', downloading: '模型正在下载，点击「连接模型」可查看进度。',
    checkFailed: '无法检测模型。', preparing: '正在准备模型…', progress: '正在下载模型：{percent}%',
    connected: '已连接，请返回 Sayo 测试连接。', prepareFailed: '模型准备失败（{name}），请检查 chrome://on-device-internals。',
    requestFailed: '请求失败，请查看 Sayo 中的详细提示。', completed: '已连接 · 已完成 {count} 次请求', processing: '正在本机处理…'
  }
};
let currentStatus = {key: 'checking', values: {}};
function translate(key, values = {}) {
  return messages[language][key].replace(/\{(\w+)\}/g, (_, name) => String(values[name] ?? ''));
}
function showStatus(key, values = {}) {
  currentStatus = {key, values};
  status.textContent = translate(key, values);
}
function renderLanguage() {
  document.documentElement.lang = language;
  languageSelector.value = language;
  document.querySelectorAll('[data-i18n]').forEach(element => { element.textContent = translate(element.dataset.i18n); });
  showStatus(currentStatus.key, currentStatus.values);
}
languageSelector.onchange = () => {
  language = languageSelector.value === 'zh-CN' ? 'zh-CN' : 'en';
  renderLanguage();
};
renderLanguage();
history.replaceState(null, '', '/');
// Let the prompt choose the language. Optional language declarations reject some
// experimental languages before the model has a chance to process the text.
const defaults = {};
let connected = false;
let stopped = false;
let active = null;
let completed = 0;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function post(path, body) {
  const response = await fetch(path, {method: 'POST', headers: {'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json'}, body: JSON.stringify(body), signal: AbortSignal.timeout(5000), cache: 'no-store'});
  if (!response.ok) throw new Error('connection');
  return response.json();
}
function disconnect() {
  stopped = true;
  connected = false;
  active?.controller.abort();
  connect.disabled = true;
  showStatus('disconnected');
}
async function check() {
  if (!token) { disconnect(); return; }
  if (typeof LanguageModel === 'undefined') {
    showStatus('missing');
    return;
  }
  try {
    const availability = await LanguageModel.availability(defaults);
    showStatus(['available', 'unavailable', 'downloadable', 'downloading'].includes(availability) ? availability : 'checkFailed');
    connect.disabled = !['available', 'downloadable', 'downloading'].includes(availability);
  } catch { showStatus('checkFailed'); }
}
connect.onclick = async () => {
  connect.disabled = true;
  let session;
  try {
    showStatus('preparing');
    session = await LanguageModel.create({...defaults, monitor(monitor) {
      monitor.addEventListener('downloadprogress', event => {
        showStatus('progress', {percent: Math.round(event.loaded * 100)});
      });
    }});
    connected = true;
    showStatus('connected');
    void poll();
  } catch (error) {
    showStatus('prepareFailed', {name: error.name});
    connect.disabled = false;
  } finally { session?.destroy(); }
};
async function run(job, controller) {
  let session;
  let result;
  try {
    if (await LanguageModel.availability(defaults) !== 'available') {
      result = {id: job.id, error: 'unavailable'};
    } else {
      session = await LanguageModel.create({...defaults, signal: controller.signal, initialPrompts: [{role: 'system', content: job.prompt}]});
      // Discard no source text silently when the context window is too small.
      session.addEventListener('contextoverflow', () => controller.abort());
      const text = await session.prompt(job.text, {signal: controller.signal});
      result = {id: job.id, text};
    }
  } catch (error) {
    result = {id: job.id, error: error.name === 'QuotaExceededError' ? 'too-long' : error.name === 'NotSupportedError' ? 'unsupported' : 'inference'};
  } finally { session?.destroy(); }
  if (controller.signal.aborted || stopped) return;
  try {
    await post('/result', result);
    completed++;
    showStatus(result.error ? 'requestFailed' : 'completed', {count: completed});
  } catch { disconnect(); }
  finally { if (active?.id === job.id) active = null; }
}
async function poll() {
  while (!stopped && connected) {
    try {
      const {job, activeID} = await post('/poll', {ready: true});
      if (active && active.id !== activeID) { active.controller.abort(); active = null; }
      if (job) {
        active = {id: job.id, controller: new AbortController()};
        showStatus('processing');
        void run(job, active.controller);
      }
    } catch { disconnect(); return; }
    await sleep(500);
  }
}
window.addEventListener('pagehide', () => { stopped = true; active?.controller.abort(); });
void check();
