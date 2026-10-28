#!/usr/bin/ucode
'use strict';

import { readfile, writefile, lsdir, stat, mkdir, unlink, popen } from 'fs';
import { cursor } from 'uci';
import * as uloop from 'uloop';

const TAG = 'proton2025-daemon';
const STORAGE_DIR = '/tmp/proton-services-history';
const HEARTBEAT_PATH = '/tmp/proton2025-daemon.heartbeat';
const USER_ACTIONS_PATH = STORAGE_DIR + '/.user_actions.json';
const EVENTS_PATH = STORAGE_DIR + '/_events.json';
const UCI_CONFIG_PATH = '/etc/config/proton2025';

const SAMPLE_INTERVAL = 10;
const FLUSH_INTERVAL = 30;
const HISTORY_MAX_AGE_HOURS = 24;
const MAX_EVENTS = 1000;
const STOP_ANALYSIS_WINDOW_SEC = 60;
const STOP_ANALYSIS_LOG_LINES = 200;
const MAX_DETAILS_LEN = 200;
const MAX_L7_PER_POLL = 2;

const SERVICE_NAME_RE = /^[A-Za-z0-9_-]{1,64}$/;
const MAX_POINTS_IN_MEMORY = 100000;

const PROCESS_NAME_MAP = { ubus: 'ubusd', rpcd: 'rpcd', sysntpd: 'ntpd' };

const VALID_EVENT_TYPES = [
    'crash', 'clean-exit', 'restart', 'user-stop',
    'health-fail', 'health-recovery', 'silent-death'
];

const CRASH_MARKERS = [
    'segfault', 'core dumped', 'killed by signal', 'terminated by signal',
    'not stopped on sigterm, sending sigkill', 'out of memory', 'oom-killer',
    'fatal error', 'panic', 'aborted', 'failed to start', 'failed to start up',
    'crash loop', 'failed to create'
];
const CRASH_SIGNAL_PATTERNS = ['signal 6', 'signal 7', 'signal 11'];
const CLEAN_EXIT_MARKERS = [
    'exiting on receipt of sigterm', 'received sigterm',
    'terminating on signal 15', 'graceful shutdown'
];
const RESTART_MARKERS = ['restarting', 'restarted'];

let state = {
    services: {},         // name -> { points, prevPid, prevL1, prevL7 }
    userActions: {},
    events: [],
    l7: {
        global: { enabled: false, interval: 60, timeout: 5, failures_threshold: 2, log_to_syslog: true },
        services: {},
        status: {},
        failures: {},
        lastRun: {}
    }
};

let _initActionCache = {};
let _userActionsMtime = 0;
let _userActionsDirty = false;
let _uciConfigMtime = 0;

let graceful_shutdown = false;
let poll_interval_handle = null;
let flush_interval_handle = null;

function log_info(msg) {
    system("logger -t " + TAG + " '" + replace(msg, /'/g, "'\\''") + "' 2>/dev/null");
}
function log_err(msg) {
    system("logger -t " + TAG + " -p daemon.err '" + replace(msg, /'/g, "'\\''") + "' 2>/dev/null");
}

function ensureStorageDir() {
    let s = stat(STORAGE_DIR);
    if (!s || s.type != 'directory') mkdir(STORAGE_DIR, 0o755);
}

function readJsonFile(path) {
    let raw = readfile(path);
    if (!raw) return null;
    try { return json(raw); } catch (e) { return null; }
}

function writeJsonFile(path, data) {
    ensureStorageDir();
    let raw = sprintf('%.J', data);
    if (raw == null) return false;
    return writefile(path, raw) !== false;
}

function validServiceName(name) {
    if (!name || type(name) != 'string') return false;
    if (match(name, SERVICE_NAME_RE) == null) return false;
    return true;
}

// --- Heartbeat --------------------------------------------------------------

function writeHeartbeat() { writefile(HEARTBEAT_PATH, '' + time() + '\n'); }
function removeHeartbeat() { unlink(HEARTBEAT_PATH); }

// --- UCI --------------------------------------------------------------------

function getSelectedServices() {
    let uci = cursor();
    uci.load('proton2025');
    let raw = uci.get('proton2025', 'settings', 'services_selected');
    if (!raw) return [];
    try {
        let arr = json(raw);
        if (type(arr) == 'array') {
            let out = [];
            for (let name in arr) if (validServiceName(name)) push(out, name);
            return out;
        }
    } catch (e) {}
    return [];
}

// --- user_actions -----------------------------------------------------------

function readUserActionsFromDisk() {
    let s = stat(USER_ACTIONS_PATH);
    let mtime = s && s.mtime ? +s.mtime : 0;

    if (!s) {
        if (length(keys(state.userActions)) > 0) {
            state.userActions = {};
            _userActionsMtime = 0;
            _userActionsDirty = false;
        }
        return;
    }
    if (mtime === _userActionsMtime) return;

    let data = readJsonFile(USER_ACTIONS_PATH);
    if (data && type(data) == 'object') {
        let clean = {};
        for (let k in data) {
            let v = data[k];
            if (v && type(v) == 'object' && v.action != null) clean[k] = v;
        }
        state.userActions = clean;
    } else {
        state.userActions = {};
    }
    _userActionsMtime = mtime;
    _userActionsDirty = false;
}

// --- L7 config --------------------------------------------------------------

function reloadL7ConfigIfChanged() {
    let s = stat(UCI_CONFIG_PATH);
    let mtime = s && s.mtime ? +s.mtime : 0;
    if (mtime === _uciConfigMtime) return;
    _uciConfigMtime = mtime;

    let uci = cursor();
    uci.load('proton2025');

    let g = {
        enabled: (uci.get('proton2025', 'settings', 'health_check_enabled') ?? '0') == '1',
        interval: +(uci.get('proton2025', 'settings', 'health_check_interval') ?? '60'),
        timeout: +(uci.get('proton2025', 'settings', 'health_check_timeout') ?? '5'),
        failures_threshold: +(uci.get('proton2025', 'settings', 'health_check_failures_threshold') ?? '2'),
        log_to_syslog: (uci.get('proton2025', 'settings', 'health_check_log_to_syslog') ?? '1') == '1'
    };
    if (g.interval != g.interval || g.interval < 30) g.interval = 60;
    if (g.timeout != g.timeout || g.timeout < 2) g.timeout = 5;
    if (g.failures_threshold != g.failures_threshold || g.failures_threshold < 1) g.failures_threshold = 2;

    state.l7.global = g;
    state.l7.services = {};

    uci.foreach('proton2025', 'health_check', function(s) {
        let name = s['.name'];
        if (!validServiceName(name)) return;
        let method = s.method ?? '';
        if (!method) return;
        let fields = {};
        for (let k in s) {
            if (k == '.name' || k == '.type' || k == 'enabled' || k == 'method') continue;
            fields[k] = '' + s[k];
        }
        state.l7.services[name] = { enabled: (s.enabled ?? '0') == '1', method: method, fields: fields };
    });

    let svcCount = length(keys(state.l7.services));
    log_info('L7 config loaded: global=' + (g.enabled ? 'on' : 'off') + ', interval=' + g.interval + ', services=' + svcCount);
}

// --- L1 ---------------------------------------------------------------------

function runInitAction(path, action) {
    let h = popen(path + ' ' + action + ' 2>/dev/null', 'r');
    if (!h) return null;
    h.read('all');
    let code = h.close();
    if (code == 0) return 1;
    if (code == 126 || code == 127) return null;
    return 0;
}

function getPidForService(name) {
    let processName = PROCESS_NAME_MAP[name] ?? name;
    let h = popen('/bin/pidof ' + processName + ' 2>/dev/null', 'r');
    if (!h) return 0;
    let out = trim(h.read('all') ?? '');
    h.close();
    if (!out) return 0;
    let parts = split(out, ' ');
    if (length(parts) < 1) return 0;
    let pid = +(parts[0] ?? 0);
    if (pid != pid || pid <= 0) return 0;
    return int(pid);
}

function checkServiceL1(name) {
    if (!validServiceName(name)) return { status: 2, pid: 0 };
    let path = '/etc/init.d/' + name;
    let preferred = _initActionCache[name];
    if (preferred == 'running' || preferred == 'status') {
        let r = runInitAction(path, preferred);
        if (r == 1) return { status: 1, pid: getPidForService(name) };
        delete _initActionCache[name];
    }
    for (let action in ['running', 'status']) {
        let r = runInitAction(path, action);
        if (r == 1) {
            _initActionCache[name] = action;
            return { status: 1, pid: getPidForService(name) };
        }
    }
    let pid = getPidForService(name);
    if (pid > 0) return { status: 1, pid: pid };
    return { status: 0, pid: 0 };
}

// composeStatus: L1 != 1 → L1; L7 == 'fail' → 3; иначе 1.
function composeStatus(l1Status, l7Status) {
    if (l1Status != 1) return l1Status;
    if (l7Status == 'fail') return 3;
    return 1;
}

// --- analyzeStopReason -----------------------------------------------------

function parseLogreadTs(line) {
    let open = index(line, '[');
    if (open < 0) return null;
    let tail = substr(line, open + 1);
    let dot = index(tail, '.');
    if (dot < 0) return null;
    let raw = substr(tail, 0, dot);
    let ts = +raw;
    if (ts != ts || ts <= 0) return null;
    return ts;
}

function serviceInLine(line, name) {
    if (!line || !name) return false;
    if (index(line, name + '[') >= 0) return true;
    if (index(line, name + ':') >= 0) return true;
    if (index(line, ' ' + name + ' ') >= 0) return true;
    if (index(line, name + '.service') >= 0) return true;
    return false;
}

function matchMarker(line, markers) {
    if (!line) return null;
    let lower = lc(line);
    for (let m in markers) if (index(lower, m) >= 0) return m;
    return null;
}

function matchNonZeroExit(line) {
    if (!line) return null;
    let lower = lc(line);
    let anchor = index(lower, 'exited with code ');
    if (anchor < 0) return null;
    let tail = substr(line, anchor + 17);
    let parts = split(trim(tail), /[ \t;,)]/);
    if (length(parts) < 1) return null;
    let code = +(parts[0]);
    if (code != code) return null;
    return { code: code };
}

function stripLogreadPrefix(line) {
    let close = index(line, ']');
    if (close < 0) return trim(line);
    return trim(substr(line, close + 1));
}

function sanitizeDetails(s) {
    if (s == null) return '';
    let str = '' + s;
    str = replace(str, /\n/g, ' ');
    str = replace(str, /\r/g, ' ');
    str = replace(str, /\t/g, ' ');
    str = trim(str);
    if (length(str) > MAX_DETAILS_LEN) str = substr(str, 0, MAX_DETAILS_LEN - 3) + '...';
    return str;
}

function analyzeFromUbus(name) {
    let h = popen('ubus call service list \'{"name":"' + name + '"}\'', 'r');
    if (!h) return null;
    let output = h.read('all') ?? '';
    h.close();
    if (!output) return null;
    let data = null;
    try { data = json(output); } catch (e) { return null; }
    if (!data || type(data) != 'object') return null;
    let svc = data[name];
    if (!svc || !svc.instances || type(svc.instances) != 'object') return null;
    let bestExitCode = null;
    let bestPid = null;
    let sawRunning = false;
    for (let iname in svc.instances) {
        let inst = svc.instances[iname];
        if (!inst || type(inst) != 'object') continue;
        if (inst.running === true) {
            sawRunning = true;
            if (inst.pid != null) {
                let p = +inst.pid;
                if (p == p && p > 0) bestPid = p;
            }
            continue;
        }
        if (inst.exit_code != null) {
            let code = +inst.exit_code;
            if (code != code) continue;
            bestExitCode = code;
        }
    }
    if (sawRunning) return { type: 'running', hint: 0, pid: bestPid, details: 'service is running' };
    if (bestExitCode == null) return null;
    if (bestExitCode === 0) return { type: 'clean-exit', hint: 2, pid: null, details: 'clean-exit: exited with code 0' };
    return { type: 'crash', hint: 3, pid: null, details: 'crashed: exited with code ' + bestExitCode };
}

function classifyMatched(matched, name) {
    if (!length(matched)) {
        return { type: 'silent-death', hint: 0, details: 'no log lines for ' + name + ' in last ' + STOP_ANALYSIS_WINDOW_SEC + 's' };
    }
    for (let i = length(matched) - 1; i >= 0; i--) {
        let line = matched[i].line;
        let sig = matchMarker(line, CRASH_SIGNAL_PATTERNS);
        if (sig) return { type: 'crash', hint: 3, details: 'crashed: ' + sig };
        let crash = matchMarker(line, CRASH_MARKERS);
        if (crash) return { type: 'crash', hint: 3, details: 'crashed: ' + crash };
        let exitInfo = matchNonZeroExit(line);
        if (exitInfo) {
            if (exitInfo.code == 0) return { type: 'clean-exit', hint: 2, details: 'clean-exit: exited with code 0' };
            return { type: 'crash', hint: 3, details: 'crashed: exited with code ' + exitInfo.code };
        }
        let clean = matchMarker(line, CLEAN_EXIT_MARKERS);
        if (clean) return { type: 'clean-exit', hint: 2, details: 'clean-exit: ' + clean };
        let lower = lc(line);
        if (index(lower, 'service ') >= 0 && index(lower, ' stopped') >= 0) {
            return { type: 'clean-exit', hint: 2, details: 'clean-exit: service stopped' };
        }
        let restart = matchMarker(line, RESTART_MARKERS);
        if (restart) return { type: 'restart', hint: 1, details: 'restarted' };
    }
    return { type: 'silent-death', hint: 3, details: 'stopped: ' + stripLogreadPrefix(matched[0].line) };
}

function analyzeFromLogread(name) {
    let h = popen('/sbin/logread -t -l ' + STOP_ANALYSIS_LOG_LINES + ' 2>/dev/null', 'r');
    if (!h) return { type: 'silent-death', hint: 0, details: 'logread unavailable', source: 'none' };
    let output = h.read('all') ?? '';
    h.close();
    if (!output) return { type: 'silent-death', hint: 0, details: 'logread empty', source: 'logread' };

    let now = time();
    let matched = [];
    for (let line in split(output, '\n')) {
        if (!line) continue;
        let ts = parseLogreadTs(line);
        if (ts == null) continue;
        if (now - ts > STOP_ANALYSIS_WINDOW_SEC) continue;
        if (!serviceInLine(line, name)) continue;
        push(matched, { ts: ts, line: trim(line) });
    }
    matched = sort(matched, (a, b) => b.ts - a.ts);
    let verdict = classifyMatched(matched, name);
    verdict.source = 'logread';
    return verdict;
}

function analyzeStopReason(name) {
    let ua = state.userActions[name];
    if (ua && ua.action == 'stop') {
        return { type: 'user-stop', hint: 4, details: 'stopped by user', source: 'user_actions' };
    }
    let ubusVerdict = analyzeFromUbus(name);
    if (ubusVerdict) {
        if (ubusVerdict.type == 'running') return null;
        return { type: ubusVerdict.type, hint: ubusVerdict.hint, details: ubusVerdict.details, source: 'ubus' };
    }
    return analyzeFromLogread(name);
}

// --- Events ----------------------------------------------------------------

function filterEventsByAge(events, maxAgeHours) {
    if (!events || type(events) != 'array') return [];
    if (maxAgeHours <= 0) return events;
    let now = time();
    let cutoff = now - (maxAgeHours * 3600);
    let out = [];
    for (let e in events) {
        if (!e || type(e) != 'array' || length(e) < 1) continue;
        let t = +e[0];
        if (t != t) continue;
        if (t >= cutoff) push(out, e);
    }
    return out;
}

function appendEvent(service, evType, hint, details) {
    if (!validServiceName(service)) return false;
    let validType = false;
    for (let t in VALID_EVENT_TYPES) if (t == evType) { validType = true; break; }
    if (!validType) return false;
    let now = time();
    let cleanDetails = sanitizeDetails(details);
    let newEvent = [now, service, evType, hint, cleanDetails];

    let events = state.events;
    if (type(events) != 'array') events = [];
    let replaced = false;
    for (let i = 0; i < length(events); i++) {
        let e = events[i];
        if (!e || type(e) != 'array' || length(e) < 2) continue;
        if (+e[0] === now && '' + e[1] === service) {
            events[i] = newEvent;
            replaced = true;
            break;
        }
    }
    if (!replaced) push(events, newEvent);
    events = filterEventsByAge(events, HISTORY_MAX_AGE_HOURS);
    if (length(events) > MAX_EVENTS) events = slice(events, length(events) - MAX_EVENTS);
    state.events = events;
    return true;
}

function clearUserAction(name) {
    if (state.userActions[name]) {
        delete state.userActions[name];
        _userActionsDirty = true;
        return true;
    }
    return false;
}

// --- L7 ---------------------------------------------------------------------

function l7CallRunCheck(name) {
    let h = popen('ubus call luci.proton-healthcheck runCheck \'{"name":"' + name + '"}\'', 'r');
    if (!h) return null;
    let output = h.read('all') ?? '';
    h.close();
    if (!output) return null;
    try { return json(output); } catch (e) { return null; }
}

function l7FormatDetails(res) {
    let err = (res && type(res.error) == 'string') ? trim(res.error) : '';
    let det = (res && type(res.details) == 'string') ? trim(res.details) : '';
    if (err && det) return err + ' (' + det + ')';
    if (err) return err;
    if (det) return det;
    return 'health check failed';
}

function runL7ForService(name) {
    if (!validServiceName(name)) return;
    let cfg = state.l7.services[name];
    if (!cfg || !cfg.enabled || !cfg.method) return;

    let res = null;
    try { res = l7CallRunCheck(name); }
    catch (e) { log_err('L7 runCheck(' + name + ') failed: ' + (e?.message ?? '' + e)); return; }

    if (!res || res.success !== true) return;

    if (res.ok === true) {
        let wasFail = state.l7.status[name] == 'fail';
        let prevFailuresRaw = state.l7.failures[name];
        let prevFailures = (prevFailuresRaw != null) ? prevFailuresRaw : 0;
        state.l7.failures[name] = 0;
        state.l7.status[name] = 'ok';

        if (wasFail) {
            let recDetails = 'ok';
            if (prevFailures > 0) recDetails += ' (after ' + prevFailures + ' failures)';
            appendEvent(name, 'health-recovery', 0, recDetails);
            log_info('L7 recovery: ' + name + ' ' + recDetails);
        }
        return;
    }

    let failuresRaw = state.l7.failures[name];
    let failures = ((failuresRaw != null) ? failuresRaw : 0) + 1;
    state.l7.failures[name] = failures;
    let threshold = state.l7.global.failures_threshold;
    if (threshold < 1) threshold = 1;
    if (failures < threshold) return;

    let wasAlreadyFailed = state.l7.status[name] == 'fail';
    state.l7.status[name] = 'fail';
    if (wasAlreadyFailed) return;

    let details = l7FormatDetails(res);
    appendEvent(name, 'health-fail', 0, details);
    log_info('L7 → health-failed: ' + name + ' ' + details);
}

function runL7Cycle() {
    if (!state.l7.global.enabled) return;

    let now = time();
    let interval = state.l7.global.interval;
    if (interval < 30) interval = 60;

    let selected = getSelectedServices();
    let queue = [];

    for (let name in selected) {
        if (!validServiceName(name)) continue;
        let cfg = state.l7.services[name];
        if (!cfg || !cfg.enabled || !cfg.method) continue;
        let svc = state.services[name];
        if (!svc || svc.prevL1 != 1) continue;
        let lastRaw = state.l7.lastRun[name];
        let last = (lastRaw != null) ? lastRaw : 0;
        if (now - last < interval) continue;
        push(queue, { name: name, last: last });
    }

    queue = sort(queue, (a, b) => a.last - b.last);

    let ran = 0;
    for (let item in queue) {
        if (ran >= MAX_L7_PER_POLL) break;
        state.l7.lastRun[item.name] = now;
        runL7ForService(item.name);
        ran++;
    }

    let selectedSet = {};
    for (let n in selected) selectedSet[n] = true;
    for (let n in state.l7.lastRun) if (!selectedSet[n]) delete state.l7.lastRun[n];
}

// --- loadState --------------------------------------------------------------

function loadState() {
    ensureStorageDir();

    let files = lsdir(STORAGE_DIR);
    if (files) {
        for (let f in files) {
            if (type(f) != 'string') continue;
            if (index(f, '.json') != length(f) - 5) continue;
            if (f == '_events.json') continue;
            if (f == '.user_actions.json') continue;
            let name = substr(f, 0, length(f) - 5);
            if (!validServiceName(name)) continue;
            let data = readJsonFile(STORAGE_DIR + '/' + f);
            if (!data || type(data) != 'object') continue;
            if (!data.points || type(data.points) != 'array') continue;

            let prevPid = 0;
            let prevL1 = null;
            let prevL7 = null;
            if (length(data.points) > 0) {
                let last = data.points[length(data.points) - 1];
                if (type(last) == 'array' && length(last) >= 3) {
                    let p = +last[2];
                    if (p == p && p > 0) prevPid = int(p);
                    let st = +last[1];
                    if (st == st) {
                        let composite = int(st);
                        if (composite == 3) { prevL1 = 1; prevL7 = 'fail'; }
                        else if (composite == 1) { prevL1 = 1; prevL7 = 'ok'; }
                        else if (composite == 0) { prevL1 = 0; prevL7 = null; }
                        else { prevL1 = 2; prevL7 = null; }
                    }
                }
            }

            state.services[name] = { points: data.points, prevPid: prevPid, prevL1: prevL1, prevL7: prevL7 };
        }
    }

    readUserActionsFromDisk();
    reloadL7ConfigIfChanged();

    let eventsData = readJsonFile(EVENTS_PATH);
    if (eventsData && eventsData.events && type(eventsData.events) == 'array') {
        state.events = eventsData.events;
    }

    for (let name in state.services) {
        let svc = state.services[name];
        if (svc.prevL7 == 'fail') {
            state.l7.status[name] = 'fail';
            let threshold = state.l7.global.failures_threshold;
            if (threshold < 1) threshold = 1;
            state.l7.failures[name] = threshold;
        } else if (svc.prevL7 == 'ok') {
            state.l7.status[name] = 'ok';
            state.l7.failures[name] = 0;
        }
    }

    let loaded = length(keys(state.services));
    let actionsCount = length(keys(state.userActions));
    let eventsCount = length(state.events);
    log_info('state loaded: ' + loaded + ' services, ' + actionsCount + ' user actions, ' + eventsCount + ' events');
}

// --- flush ------------------------------------------------------------------

function filterPointsByAge(points, maxAgeHours) {
    if (!points || type(points) != 'array') return [];
    if (maxAgeHours <= 0) return points;
    let now = time();
    let cutoff = now - (maxAgeHours * 3600);
    let out = [];
    for (let p in points) {
        if (!p || type(p) != 'array' || length(p) < 1) continue;
        let t = +p[0];
        if (t != t) continue;
        if (t >= cutoff) push(out, p);
    }
    return out;
}

function flushEvents() {
    let payload = {
        max_age_hours: HISTORY_MAX_AGE_HOURS,
        events: filterEventsByAge(state.events, HISTORY_MAX_AGE_HOURS)
    };
    if (length(payload.events) > MAX_EVENTS) {
        payload.events = slice(payload.events, length(payload.events) - MAX_EVENTS);
    }
    return writeJsonFile(EVENTS_PATH, payload);
}

function flush() {
    let written = 0;
    for (let name in state.services) {
        let svc = state.services[name];
        if (!svc || !svc.points) continue;
        let filtered = filterPointsByAge(svc.points, HISTORY_MAX_AGE_HOURS);
        if (length(filtered) > MAX_POINTS_IN_MEMORY) filtered = slice(filtered, length(filtered) - MAX_POINTS_IN_MEMORY);
        svc.points = filtered;
        let payload = {
            service: name,
            sample_interval: SAMPLE_INTERVAL,
            max_age_hours: HISTORY_MAX_AGE_HOURS,
            points: filtered
        };
        if (writeJsonFile(STORAGE_DIR + '/' + name + '.json', payload)) written++;
        else log_err('flush failed for service: ' + name);
    }

    if (_userActionsDirty) {
        if (writeJsonFile(USER_ACTIONS_PATH, state.userActions)) {
            let s = stat(USER_ACTIONS_PATH);
            if (s && s.mtime) _userActionsMtime = +s.mtime;
            _userActionsDirty = false;
        } else {
            log_err('flush failed for user_actions');
        }
    }

    if (!flushEvents()) log_err('flush failed for events');
    return written;
}

// --- handleTransition -------------------------------------------------------
//
// Переходы:
//   1→0 и 3→0 : analyzeStopReason (clean-exit/crash/user-stop/silent-death).
//               L7-статус СОХРАНЯЕТСЯ (не сбрасываем при остановке).
//   0→1       : clearUserAction + restart (L7='ok' уже, composeStatus=1).
//   0→3       : clearUserAction + restart (hint=1) + log "health-failed carried over".
//               L7='fail' сохранён с прошлой жизни сервиса.
//   1→3, 3→1  : пропускаем (обработано в runL7ForService).
//   2→...     : без изменений.
//   null → X  : первое обнаружение, без событий.
//
function handleTransition(name, svc, prevComposite, newComposite, prevL1, newL1) {
    // 1→0 или 3→0: L1 упал
    if ((prevComposite == 1 || prevComposite == 3) && newComposite == 0) {
        let verdict = null;
        try { verdict = analyzeStopReason(name); }
        catch (e) { log_err('analyzeStopReason(' + name + ') failed: ' + (e?.message ?? '' + e)); }
        if (verdict) {
            try { appendEvent(name, verdict.type, verdict.hint, verdict.details); }
            catch (e) { log_err('appendEvent(' + name + ',' + verdict.type + ') failed: ' + (e?.message ?? '' + e)); }
            let suffix = (prevComposite == 3) ? ' (was health-failed)' : '';
            log_info('transition ' + name + ': running→stopped' + suffix + ', type=' + verdict.type + ', hint=' + verdict.hint + ', source=' + (verdict.source ?? '?'));
            return verdict.hint;
        }
        try { appendEvent(name, 'silent-death', 0, 'unable to determine stop reason'); }
        catch (e) { log_err('appendEvent(' + name + ',silent-death) failed: ' + (e?.message ?? '' + e)); }
        return 0;
    }

    // 0→1: L1 поднялся, L7='ok'
    if (prevComposite == 0 && newComposite == 1) {
        let hadUserAction = false;
        try { hadUserAction = clearUserAction(name); }
        catch (e) { log_err('clearUserAction(' + name + ') failed: ' + (e?.message ?? '' + e)); }
        let hint = 1;
        let details = hadUserAction ? 'service started after user stop' : 'service returned to running';
        try { appendEvent(name, 'restart', hint, details); }
        catch (e) { log_err('appendEvent(' + name + ',restart) failed: ' + (e?.message ?? '' + e)); }
        log_info('transition ' + name + ': stopped→running, restart');
        return hint;
    }

    // 0→3: L1 поднялся, но L7='fail' сохранён
    if (prevComposite == 0 && newComposite == 3) {
        let hadUserAction = false;
        try { hadUserAction = clearUserAction(name); }
        catch (e) { log_err('clearUserAction(' + name + ') failed: ' + (e?.message ?? '' + e)); }
        let hint = 1;
        let details = hadUserAction
            ? 'service started after user stop (health-failed carried over)'
            : 'service returned to running (health-failed carried over)';
        try { appendEvent(name, 'restart', hint, details); }
        catch (e) { log_err('appendEvent(' + name + ',restart) failed: ' + (e?.message ?? '' + e)); }
        log_info('transition ' + name + ': stopped→running (health-failed carried over)');
        return hint;
    }

    // 1↔3: обработано в runL7ForService. Остальные: не должны случаться.
    return 0;
}

// --- poll -------------------------------------------------------------------

function poll_one(name, now) {
    if (!state.services[name]) {
        state.services[name] = { points: [], prevPid: 0, prevL1: null, prevL7: null };
    }
    let svc = state.services[name];

    let l1 = checkServiceL1(name);
    let l1Status = l1.status;
    let pid = l1.pid;

    let prevL1 = svc.prevL1;
    let prevL7 = svc.prevL7;
    let prevComposite = (prevL1 != null) ? composeStatus(prevL1, prevL7) : null;

    // ВАЖНО: НЕ сбрасываем L7-статус при L1-остановке.
    // Если сервис был health-failed и упал — при следующем 0→1
    // composite будет 3 (health-failed), пока L7 не подтвердит восстановление.

    // L7-статус: если L1 != running, L7 не применяется.
    // (но prevL7 в svc сохраняется для восстановления при 0→1)
    let l7StatusRaw = state.l7.status[name];
    let l7Status = (l1Status == 1)
        ? (l7StatusRaw != null ? l7StatusRaw : 'ok')
        : null;

    let newComposite = composeStatus(l1Status, l7Status);

    let hint = 0;
    if (prevComposite != null && prevComposite != newComposite) {
        hint = handleTransition(name, svc, prevComposite, newComposite, prevL1, l1Status);
    }

    if (l1Status == 1 && pid > 0) svc.prevPid = pid;
    svc.prevL1 = l1Status;
    // prevL7 в svc сохраняем: при l1Status==1 — актуальный L7,
    // при l1Status!=1 — тот, что был (для восстановления composite при 0→1).
    if (l1Status == 1) {
        svc.prevL7 = (state.l7.status[name] != null ? state.l7.status[name] : 'ok');
    }
    // при l1Status != 1 — svc.prevL7 НЕ трогаем (сохраняем старое значение).

    push(svc.points, [now, newComposite, pid, hint]);
    if (length(svc.points) > MAX_POINTS_IN_MEMORY) {
        svc.points = slice(svc.points, length(svc.points) - MAX_POINTS_IN_MEMORY);
    }
}

function poll() {
    readUserActionsFromDisk();
    reloadL7ConfigIfChanged();

    let selected = getSelectedServices();
    let now = time();

    for (let name in selected) {
        if (!validServiceName(name)) continue;
        try { poll_one(name, now); }
        catch (e) { log_err('poll(' + name + ') failed: ' + (e?.message ?? '' + e)); }
    }

    try { runL7Cycle(); }
    catch (e) { log_err('L7 cycle failed: ' + (e?.message ?? '' + e)); }

    writeHeartbeat();
}

// --- Signals ---------------------------------------------------------------

function onSignal() {
    if (graceful_shutdown) return;
    graceful_shutdown = true;
    log_info('stopped gracefully');
    try { flush(); } catch (e) { log_err('flush on shutdown failed: ' + (e?.message ?? '' + e)); }
    removeHeartbeat();
    if (poll_interval_handle) poll_interval_handle.cancel();
    if (flush_interval_handle) flush_interval_handle.cancel();
    uloop.end();
}

// --- main -------------------------------------------------------------------

try {
    uloop.signal(15, onSignal);
    uloop.signal(2,  onSignal);
    uloop.signal(1,  onSignal);

    loadState();
    poll();

    let pid = '';
    let pid_stat = trim(readfile('/proc/self/stat') ?? '');
    if (length(pid_stat)) {
        let sp = index(pid_stat, ' ');
        if (sp > 0) pid = substr(pid_stat, 0, sp);
    }
    log_info('started (pid ' + pid + ')');

    poll_interval_handle = uloop.interval(SAMPLE_INTERVAL * 1000, poll);
    flush_interval_handle = uloop.interval(FLUSH_INTERVAL * 1000, flush);

    uloop.init();
    uloop.run();

    log_info('main loop exited');
} catch (e) {
    log_err('crashed during init: ' + (e?.message ?? '' + e));
    exit(1);
}
