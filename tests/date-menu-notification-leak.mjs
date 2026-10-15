import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../mmcalendar.js', import.meta.url), 'utf8');
const classStart = source.indexOf('class MultiMonitorsDateMenuButton extends');
const classEnd = source.indexOf('\n    };', classStart);
assert.ok(classStart >= 0 && classEnd > classStart, 'find MultiMonitorsDateMenuButton');
const methods = source.slice(source.indexOf('\n        _init(', classStart), classEnd);

class Emitter {
    constructor() {
        this.handlers = new Map();
        this.nextId = 1;
        this.disposed = false;
    }

    connect(signal, handler) {
        assert.ok(!this.disposed, `connect '${signal}' on a disposed object`);
        const id = this.nextId++;
        this.handlers.set(id, { signal, handler });
        return id;
    }

    disconnect(id) {
        assert.ok(!this.disposed, 'disconnect on a disposed object');
        assert.ok(this.handlers.delete(id), `handler ${id} is connected`);
    }

    emit(signal, ...args) {
        for (const { signal: name, handler } of [...this.handlers.values()]) {
            if (name === signal)
                handler(this, ...args);
        }
    }

    connectedSignals() {
        return [...this.handlers.values()].map(({ signal }) => signal);
    }
}

class Clock extends Emitter {
    bind_property() { return { unbind() {} }; }
}

class Source extends Emitter {
    get unseenCount() { return 1; }
}

class MessageTray extends Emitter {
    constructor() {
        super();
        this.sources = [];
        this.queueCount = 0;
    }

    getSources() { return [...this.sources]; }

    add(source) {
        this.sources.push(source);
        this.emit('source-added', source);
    }

    remove(source) {
        this.sources.splice(this.sources.indexOf(source), 1);
        this.emit('source-removed', source);
        source.disposed = true;
    }
}

const messageTray = new MessageTray();
const sessionMode = new Emitter();
const appSystem = new Emitter();
const syncErrors = [];

// The connect pattern of upstream dateMenu.js MessagesIndicator (GNOME 50):
// plain connect()s on the tray and on every source, settings nulled on destroy.
class UpstreamMessagesIndicator {
    constructor() {
        this._sources = [];
        this._settings = { get_boolean: () => true };
        messageTray.connect('source-added', this._onSourceAdded.bind(this));
        messageTray.connect('source-removed', this._onSourceRemoved.bind(this));
        messageTray.connect('queue-changed', this._updateCount.bind(this));
        messageTray.getSources().forEach(source => this._onSourceAdded(null, source));
    }

    _onSourceAdded(tray, source) {
        source.connect('notify::count', this._updateCount.bind(this));
        this._sources.push(source);
        this._updateCount();
    }

    _onSourceRemoved(tray, source) {
        this._sources.splice(this._sources.indexOf(source), 1);
        this._updateCount();
    }

    _updateCount() {
        if (!this._settings) {
            syncErrors.push('this._settings is null');
            return;
        }
        this._count = this._sources.reduce((count, source) => count + source.unseenCount, 0);
    }
}

class UpstreamDateMenuButton {
    _init() {
        sessionMode.connect('updated', () => {});
        this._clock = new Clock();
        this._indicator = new UpstreamMessagesIndicator();
    }

    _onDestroy() {
        this._indicator._settings = null;
    }
}

const context = vm.createContext({
    DateMenu: { DateMenuButton: class {} },
    MainRef: { messageTray, sessionMode },
    Shell: { AppSystem: { get_default: () => appSystem } },
});
const DateMenuButton = vm.runInContext(`Base => class extends Base {${methods}}`, context)(
    UpstreamDateMenuButton);
const createDateMenuButton = () => {
    const button = new DateMenuButton();
    button._syncMultiMonitorPanelStyle = () => {};
    button._init();
    return button;
};

const removedBeforeBuild = new Source();
messageTray.add(removedBeforeBuild);
messageTray.remove(removedBeforeBuild);

const existingSource = new Source();
messageTray.add(existingSource);

const button = createDateMenuButton();

const laterSource = new Source();
messageTray.add(laterSource);
const removedSource = new Source();
messageTray.add(removedSource);
messageTray.remove(removedSource);

assert.deepEqual(existingSource.connectedSignals(), ['notify::count'],
    'the indicator counts sources that existed before the menu was built');
assert.deepEqual(laterSource.connectedSignals(), ['notify::count'],
    'the indicator counts sources added after the menu was built');

button._onDestroy();

assert.deepEqual(messageTray.connectedSignals(), [], 'no message tray handlers survive the menu');
assert.deepEqual(sessionMode.connectedSignals(), [], 'no session mode handlers survive the menu');
assert.deepEqual(existingSource.connectedSignals(), [],
    'no handlers on a pre-existing notification source survive the menu');
assert.deepEqual(laterSource.connectedSignals(), [],
    'no handlers on a later notification source survive the menu');

existingSource.emit('notify::count');
laterSource.emit('notify::count');
messageTray.add(new Source());
assert.deepEqual(syncErrors, [], 'a destroyed date menu never reacts to notifications');

for (let i = 0; i < 3; i++)
    createDateMenuButton()._onDestroy();
assert.deepEqual(existingSource.connectedSignals(), [],
    'rebuilding the date menu on monitor changes does not accumulate handlers');
console.log('Date menu notification source cleanup checks passed');
