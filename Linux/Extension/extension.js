// ClaudeMonitor — GNOME-Shell-Extension (CM-42). Zeichnet Panel-Anzeige und Popover
// aus dem Zustand des Tray-Prozesses (`org.claudemonitor.Popover`, Protokoll 1).
// Sie rechnet nichts selbst: alle Texte kommen fertig, die einzige verarbeitete Zahl
// ist `fraction` (Balkenbreite). Regeln stehen in popoverState.js.
//
// Mac-Vorbild der Maße: MonitorPopoverView.swift:32,39-50,126 · AccountCardView.swift:23-85 ·
// LimitWindowRowView.swift:25-55 (Abstand 6 :30, `?? 0` :37, leere Spalte :47-49) ·
// IssueBannerView.swift:11-41 (Innenabstand 10 :28, Abstand 4 :12, Farbe :36-40) ·
// Stufenfarben StatusAppearance.swift:19-25, hier gleich dem Tray-Symbol (TrayIconPixmap.swift:83-89).

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import Pango from 'gi://Pango';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {PANEL_MODES, panelModeFor, parseState, slotFor, statusClass} from './popoverState.js';

const TRAY_NAME = 'org.claudemonitor.Tray';
const TRAY_PATH = '/Popover';
const OWN_NAME = 'org.claudemonitor.Popover';

// Nur die Popover1-Schnittstelle (TrayPopoverState.swift:40-47) in eigenem <node>:
// makeProxyWrapper nimmt die erste Schnittstelle, und im Tray-XML steht davor Introspectable.
const POPOVER_XML = `<node>
  <interface name="org.claudemonitor.Tray.Popover1">
    <method name="GetState"><arg name="state" type="s" direction="out"/></method>
    <method name="Invoke">
      <arg name="key" type="s" direction="in"/>
      <arg name="accepted" type="b" direction="out"/>
    </method>
    <method name="Opened"/>
    <signal name="StateChanged"><arg name="state" type="s"/></signal>
  </interface>
</node>`;
const PopoverProxy = Gio.DBusProxy.makeProxyWrapper(POPOVER_XML);

const SCROLL_MAX_HEIGHT = 460;   // MonitorPopoverView.swift:32
const BAR_TRACK_WIDTH = 116;     // 320 − 2·12 (Popover) − 2·8 (Kärtchen) − 62 − 36 − 48 − 3·6 (Abstände)

function log(line) {
    console.log(`[ClaudeMonitor] ${line}`);
}

function makeLabel(styleClass, text = '') {
    return new St.Label({
        style_class: styleClass,
        text,
        y_align: Clutter.ActorAlign.CENTER,
    });
}

function setVisibleText(label, text) {
    const shown = typeof text === 'string' && text !== '';
    label.text = shown ? text : '';
    label.visible = shown;
}

function setStatusClass(actor, status) {
    for (const cls of ['cm-green', 'cm-yellow', 'cm-red', 'cm-neutral'])
        actor.remove_style_class_name(cls);
    actor.add_style_class_name(statusClass(status));
}

/**
 * Gleicht die Kinder von `container` mit `items` ab, ohne Gerüst oder Scrollstand
 * anzufassen: gleicher Schlüssel ⇒ vorhandenes Widget aktualisieren, neuer ⇒ bauen,
 * verschwundener ⇒ zerstören; die Reihenfolge ist die gelieferte.
 */
function reconcile(container, entries, items, keyOf, create, update) {
    const wanted = new Map(items.map(item => [keyOf(item), item]));
    for (const [key, entry] of [...entries]) {
        if (!wanted.has(key)) {
            entry.actor.destroy();
            entries.delete(key);
        }
    }
    items.forEach((item, index) => {
        const key = keyOf(item);
        let entry = entries.get(key);
        if (!entry) {
            entry = create(item);
            entries.set(key, entry);
            container.add_child(entry.actor);
        }
        container.set_child_at_index(entry.actor, index);
        update(entry, item);
    });
}

class WindowRow {
    constructor() {
        this.actor = new St.BoxLayout({style_class: 'cm-window-row'});
        this._name = makeLabel('cm-window-name');
        this._track = new St.Widget({style_class: 'cm-bar-track', width: BAR_TRACK_WIDTH, y_align: Clutter.ActorAlign.CENTER});
        this._fill = new St.Widget({style_class: 'cm-bar-fill', x_align: Clutter.ActorAlign.START, y_expand: true});
        this._track.add_child(this._fill);
        this._percent = makeLabel('cm-window-percent');
        this._reset = makeLabel('cm-window-reset');
        for (const child of [this._name, this._track, this._percent, this._reset])
            this.actor.add_child(child);
    }

    update(window) {
        this._name.text = window.name ?? '';
        // `fraction === null` ⇒ leere Spur (Mac `?? 0`, LimitWindowRowView.swift:37)
        const fraction = typeof window.fraction === 'number' ? Math.min(Math.max(window.fraction, 0), 1) : 0;
        this._fill.width = Math.round(fraction * BAR_TRACK_WIDTH);
        setStatusClass(this._fill, window.status);
        // `percentText === null` ⇒ leere Spalte gleicher Breite (:47-49), die Balken bleiben bündig
        this._percent.text = window.percentText ?? '';
        setStatusClass(this._percent, window.status);
        this._reset.text = window.resetText ?? '';
    }
}

class AccountCard {
    constructor() {
        this.actor = new St.BoxLayout({style_class: 'cm-card', vertical: true});
        const head = new St.BoxLayout({style_class: 'cm-card-head'});
        this._dot = new St.Widget({style_class: 'cm-dot', y_align: Clutter.ActorAlign.CENTER});
        this._marker = makeLabel('cm-card-marker');
        this._name = makeLabel('cm-card-name');
        this._name.clutter_text.ellipsize = Pango.EllipsizeMode.MIDDLE;
        this._number = makeLabel('cm-dim cm-small');
        this._binding = makeLabel('cm-card-binding');
        this._binding.x_expand = true;
        this._binding.x_align = Clutter.ActorAlign.END;
        for (const child of [this._dot, this._marker, this._name, this._number, this._binding])
            head.add_child(child);
        this._statusText = makeLabel('cm-dim cm-small');
        this._statusText.clutter_text.line_wrap = true;
        this._windows = new St.BoxLayout({style_class: 'cm-windows', vertical: true});
        this._noData = makeLabel('cm-dim');
        this._updated = makeLabel('cm-dim cm-small');
        for (const child of [head, this._statusText, this._windows, this._noData, this._updated])
            this.actor.add_child(child);
        this._rows = new Map();
    }

    update(account) {
        setStatusClass(this._dot, account.status);
        setVisibleText(this._marker, account.marker);
        this._name.text = account.name ?? '';
        this._name.style_class = account.isActive ? 'cm-card-name cm-bold' : 'cm-card-name';
        this._number.text = account.number ?? '';
        this._binding.text = account.binding ?? '';
        this._binding.style_class = account.binding === '–' ? 'cm-card-binding cm-dim' : 'cm-card-binding';
        setVisibleText(this._statusText, account.statusText);
        reconcile(this._windows, this._rows, account.windows ?? [], window => window.id,
            () => new WindowRow(), (row, window) => row.update(window));
        setVisibleText(this._noData, account.noDataText);
        setVisibleText(this._updated, account.updatedText);
    }
}

class PanelSegment {
    constructor() {
        this.actor = new St.BoxLayout({style_class: 'cm-segment', y_align: Clutter.ActorAlign.CENTER});
        this._marker = makeLabel('cm-panel-marker cm-bold');
        this._dot = new St.Widget({style_class: 'cm-dot cm-panel-dot', y_align: Clutter.ActorAlign.CENTER});
        this._numbers = makeLabel('cm-panel-numbers');
        this._reset = makeLabel('cm-panel-reset cm-dim');
        for (const child of [this._marker, this._dot, this._numbers, this._reset])
            this.actor.add_child(child);
    }

    update(segment) {
        setVisibleText(this._marker, segment.marker);
        setStatusClass(this._dot, segment.status);
        this._numbers.text = segment.numbersText ?? '';
        // aktiver Account (`marker !== null`) ⇒ Zahlen fett (FE-6)
        this._numbers.style_class = segment.marker != null ? 'cm-panel-numbers cm-bold' : 'cm-panel-numbers';
        setVisibleText(this._reset, segment.resetText);
    }
}

class PopoverButton {
    /**
     * @param {Gio.Settings} settings
     * @param {{invoke: function(string), opened: function(), }} hooks
     */
    constructor(settings, hooks) {
        this._settings = settings;
        this._hooks = hooks;
        this._segments = new Map();
        this._cards = new Map();
        this._controls = new Map();
        this._modeButtons = new Map();

        this.button = new PanelMenu.Button(0.5, 'ClaudeMonitor', false);
        this._panelBox = new St.BoxLayout({style_class: 'cm-panel', y_align: Clutter.ActorAlign.CENTER});
        this._ring = new St.Widget({style_class: 'cm-dot cm-ring cm-neutral cm-panel-dot', y_align: Clutter.ActorAlign.CENTER});
        this._segmentBox = new St.BoxLayout({y_align: Clutter.ActorAlign.CENTER});
        this._panelBox.add_child(this._segmentBox);
        this._panelBox.add_child(this._ring);
        this.button.add_child(this._panelBox);

        this._buildScaffold();
        this._openId = this.button.menu.connect('open-state-changed', (_menu, open) => {
            if (open)
                this._hooks.opened();   // FE-9: genau ein `Opened` je Öffnen, Schließen sendet nichts
        });
    }

    // Gerüst einmal je Knopf (Auflage 4): Kopf, Hinweisbalken, ScrollView, Modus-Zeile, Fuß.
    _buildScaffold() {
        const menu = this.button.menu;
        const top = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const root = new St.BoxLayout({style_class: 'cm-popover', vertical: true});
        top.add_child(root);

        const head = new St.BoxLayout({style_class: 'cm-head'});
        this._title = makeLabel('cm-title cm-bold');
        this._title.x_expand = true;
        this._refresh = new St.Button({style_class: 'cm-icon-button', can_focus: true, visible: false,
            child: new St.Icon({icon_name: 'view-refresh-symbolic', icon_size: 16})});
        this._refresh.connect('clicked', () => {
            if (this._refreshKey)
                this._hooks.invoke(this._refreshKey);
        });
        head.add_child(this._title);
        head.add_child(this._refresh);
        root.add_child(head);
        root.add_child(new St.Widget({style_class: 'cm-separator', height: 1}));

        // Hinweisbalken (IssueBannerView.swift:11-41)
        this._banner = new St.BoxLayout({style_class: 'cm-banner', vertical: true, visible: false});
        const bannerHead = new St.BoxLayout({style_class: 'cm-banner-head'});
        this._bannerIcon = new St.Icon({icon_name: 'dialog-warning-symbolic', icon_size: 16, style_class: 'cm-banner-icon'});
        this._bannerTitle = makeLabel('cm-banner-title');
        bannerHead.add_child(this._bannerIcon);
        bannerHead.add_child(this._bannerTitle);
        this._bannerText = makeLabel('cm-dim cm-small');
        this._bannerText.clutter_text.line_wrap = true;
        this._bannerText.clutter_text.ellipsize = Pango.EllipsizeMode.NONE;
        this._banner.add_child(bannerHead);
        this._banner.add_child(this._bannerText);
        root.add_child(this._banner);

        this._contentText = makeLabel('cm-dim');
        this._contentText.visible = false;
        root.add_child(this._contentText);

        this._scroll = new St.ScrollView({
            style_class: 'cm-scroll',
            hscrollbar_policy: St.PolicyType.NEVER,
            vscrollbar_policy: St.PolicyType.AUTOMATIC,
            overlay_scrollbars: true,
            visible: false,
        });
        this._scroll.set_style(`max-height: ${SCROLL_MAX_HEIGHT}px;`);
        this._cardList = new St.BoxLayout({style_class: 'cm-cards', vertical: true});
        this._scroll.set_child(this._cardList);
        root.add_child(this._scroll);

        // Modus-Zeile: schreibt nur GSettings, kein Tray-Aufruf (FE-5)
        this._modeRow = new St.BoxLayout({style_class: 'cm-mode-row', visible: false});
        this._modeTitle = makeLabel('cm-dim');
        this._modeTitle.x_expand = true;
        this._modeRow.add_child(this._modeTitle);
        for (const mode of PANEL_MODES) {
            const toggle = new St.Button({style_class: 'cm-mode-button button', toggle_mode: true, can_focus: true});
            toggle.connect('clicked', () => this._settings.set_string('panel-mode', mode));
            this._modeRow.add_child(toggle);
            this._modeButtons.set(mode, toggle);
        }
        root.add_child(new St.Widget({style_class: 'cm-separator', height: 1}));
        root.add_child(this._modeRow);
        menu.addMenuItem(top);

        // Bedienelemente in gelieferter Reihenfolge (FE-8)
        this._controlSection = new PopupMenu.PopupMenuSection();
        menu.addMenuItem(this._controlSection);

        const footer = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const footerBox = new St.BoxLayout({style_class: 'cm-footer', x_expand: true});
        this._checked = makeLabel('cm-dim cm-small');
        this._checked.x_expand = true;
        this._quit = new St.Button({style_class: 'cm-icon-button', can_focus: true, visible: false,
            child: new St.Icon({icon_name: 'application-exit-symbolic', icon_size: 16})});
        this._quit.connect('clicked', () => {
            if (this._quitKey)
                this._hooks.invoke(this._quitKey);
        });
        footerBox.add_child(this._checked);
        footerBox.add_child(this._quit);
        footer.add_child(footerBox);
        menu.addMenuItem(footer);
    }

    /** Zeichnet Panel und Popover aus einem gültigen Zustand; wirft bei einem Fehler. */
    render(state) {
        this._state = state;
        this._renderPanel();

        setVisibleText(this._title, state.header);
        const refresh = state.controls.find(control => slotFor(control) === 'header');
        this._refreshKey = refresh?.key ?? null;
        this._refresh.visible = refresh !== undefined;
        this._refresh.accessible_name = refresh?.label ?? '';
        this._refresh.reactive = refresh?.enabled !== false;

        const issue = state.issue ?? null;
        this._banner.visible = issue !== null;
        if (issue !== null) {
            this._bannerTitle.text = issue.title ?? '';
            this._bannerText.text = issue.explanation ?? '';
            // rot nur bei `isSevere === true`; fehlt der Schlüssel (älterer Tray), orange (FE-10)
            this._bannerIcon.style_class = issue.isSevere === true ? 'cm-banner-icon cm-red' : 'cm-banner-icon cm-yellow';
        }

        // `loading`/`empty` ⇒ eine gedämpfte Zeile; `issueOnly` ⇒ nichts; `accounts` ⇒ Kärtchen (FE-10)
        const showsCards = state.content === 'accounts';
        const lineText = state.content === 'loading' || state.content === 'empty' ? state.contentText : null;
        setVisibleText(this._contentText, lineText);
        const scrollValue = this._scroll.vadjustment?.value ?? 0;
        reconcile(this._cardList, this._cards, showsCards ? state.accounts : [], account => account.id,
            () => new AccountCard(), (card, account) => card.update(account));
        this._scroll.visible = showsCards && state.accounts.length > 0;
        if (this._scroll.visible && scrollValue > 0)
            this._scroll.vadjustment.value = scrollValue;

        this._renderModeRow();
        this._renderControls(state.controls);

        const footerText = state.footer?.checkedText ?? null;
        setVisibleText(this._checked, footerText);
        const quit = state.controls.find(control => slotFor(control) === 'footer');
        this._quitKey = quit?.key ?? null;
        this._quit.visible = quit !== undefined;
        this._quit.accessible_name = quit?.label ?? '';
        this._quit.reactive = quit?.enabled !== false;
    }

    /** Nur die Leiste und die Modus-Knöpfe neu (`changed::panel-mode`). */
    renderMode() {
        if (!this._state)
            return;
        this._renderPanel();
        this._renderModeRow();
    }

    _currentMode() {
        const mode = this._settings.get_string('panel-mode');
        return PANEL_MODES.includes(mode) ? mode : PANEL_MODES[0];
    }

    _renderPanel() {
        const mode = panelModeFor(this._state, this._currentMode());
        const segments = mode.segments;
        reconcile(this._segmentBox, this._segments, segments, segment => segment.id,
            () => new PanelSegment(), (entry, segment) => entry.update(segment));
        this._ring.visible = segments.length === 0;   // ohne Segmente nur der neutrale Ring
        this.button.accessible_name = mode.accessibleText ?? 'ClaudeMonitor';
    }

    _renderModeRow() {
        const panel = this._state.panel;
        const labels = PANEL_MODES.map(mode => panel[mode].label);
        const hasRow = typeof panel.title === 'string' && labels.every(label => typeof label === 'string');
        this._modeRow.visible = hasRow;   // älterer Tray ohne additive Schlüssel: keine Modus-Zeile (FE-10)
        if (!hasRow)
            return;
        this._modeTitle.text = panel.title;
        const current = this._currentMode();
        for (const mode of PANEL_MODES) {
            const toggle = this._modeButtons.get(mode);
            toggle.label = panel[mode].label;
            toggle.checked = mode === current;
        }
    }

    _renderControls(controls) {
        const items = controls.filter(control => {
            const slot = slotFor(control);
            return slot !== 'header' && slot !== 'footer';
        });
        const section = this._controlSection;
        const wanted = new Map(items.map(control => [`${control.key}|${slotFor(control)}`, control]));
        for (const [key, entry] of [...this._controls]) {
            if (!wanted.has(key)) {
                entry.item.destroy();
                this._controls.delete(key);
            }
        }
        items.forEach((control, index) => {
            const slot = slotFor(control);
            const key = `${control.key}|${slot}`;
            let entry = this._controls.get(key);
            if (!entry) {
                entry = {item: this._makeControl(control, slot)};
                this._controls.set(key, entry);
                section.addMenuItem(entry.item, index);
            } else {
                section.moveMenuItem(entry.item, index);
            }
            this._updateControl(entry.item, control, slot);
        });
    }

    _makeControl(control, slot) {
        const key = control.key;
        switch (slot) {
        case 'switch': {
            const item = new PopupMenu.PopupSwitchMenuItem(control.label, control.checked === true);
            // Kein optimistisches Umschalten: nur `Invoke`; die Stellung kommt aus dem Zustand (FE-8)
            item.activate = () => this._hooks.invoke(key);
            return item;
        }
        case 'separator':
            return new PopupMenu.PopupSeparatorMenuItem();
        case 'info': {
            const item = new PopupMenu.PopupMenuItem(control.label, {reactive: false, can_focus: false});
            item.label.add_style_class_name('cm-dim');
            return item;
        }
        default: {
            const item = new PopupMenu.PopupMenuItem(control.label);
            item.connect('activate', () => this._hooks.invoke(key));
            return item;
        }
        }
    }

    _updateControl(item, control, slot) {
        if (slot === 'separator')
            return;
        item.label.text = control.label ?? '';
        if (slot === 'switch')
            item.setToggleState(control.checked === true);
        if (slot !== 'info')
            item.setSensitive(control.enabled !== false);
    }

    destroy() {
        if (this._openId) {
            this.button.menu.disconnect(this._openId);
            this._openId = 0;
        }
        this.button.destroy();
    }
}

export default class ClaudeMonitorExtension extends Extension {
    enable() {
        this._active = true;
        this._generation = 0;
        this._ownId = 0;
        this._popover = null;
        this._proxy = null;
        this._stateSignal = 0;
        this._settings = null;
        try {
            this._settings = this.getSettings();   // wirft, wenn das Schema nicht kompiliert ist
        } catch (e) {
            return;   // FE-2: Name nie besessen, der Tray bleibt `Active`
        }
        this._cancellable = new Gio.Cancellable();
        this._modeId = this._settings.connect('changed::panel-mode', () => this._guard(() => this._popover?.renderMode()));
        this._watchId = Gio.bus_watch_name(Gio.BusType.SESSION, TRAY_NAME, Gio.BusNameWatcherFlags.NONE,
            () => this._connect(), () => this._hide('trayAbsent'));
    }

    disable() {
        this._active = false;
        this._generation++;
        // FE-3: Name zuerst frei, danach alles andere
        this._releaseName();
        this._cancellable?.cancel();
        this._cancellable = null;
        if (this._watchId) {
            Gio.bus_unwatch_name(this._watchId);
            this._watchId = 0;
        }
        if (this._settings && this._modeId) {
            this._settings.disconnect(this._modeId);
            this._modeId = 0;
        }
        this._dropProxy();
        const wasShown = this._popover !== null;
        this._destroyButton();
        if (wasShown)
            log('popover=hidden reason=disabled');
        this._settings = null;
    }

    // --- Verbindung zum Tray ---

    _connect() {
        if (!this._active)
            return;
        const generation = ++this._generation;
        this._dropProxy();
        new PopoverProxy(Gio.DBus.session, TRAY_NAME, TRAY_PATH, (proxy, error) => {
            if (!this._active || generation !== this._generation)
                return;
            if (error) {
                this._hide('call');
                return;
            }
            this._proxy = proxy;
            this._stateSignal = proxy.connectSignal('StateChanged', (_proxy, _sender, [text]) => {
                if (this._active && generation === this._generation)
                    this._apply(text);
            });
            this._fetchState(generation);
        }, this._cancellable);
    }

    _fetchState(generation) {
        this._proxy.GetStateAsync().then(reply => {
            if (!this._active || generation !== this._generation)
                return;
            // Eine leere Antwort (alter Tray ohne /Popover) ist kein String ⇒ `call`
            if (!Array.isArray(reply) || typeof reply[0] !== 'string') {
                this._hide('call');
                return;
            }
            this._apply(reply[0]);
        }).catch(() => {
            if (this._active && generation === this._generation)
                this._hide('call');
        });
    }

    _dropProxy() {
        if (this._proxy && this._stateSignal)
            this._proxy.disconnectSignal(this._stateSignal);
        this._stateSignal = 0;
        this._proxy = null;
    }

    // --- Zeichnen (jeder Pfad in try/catch, Auflage 1) ---

    _apply(text) {
        const parsed = parseState(text);
        if (!parsed.ok) {
            this._hide(parsed.reason);
            return;
        }
        this._guard(() => {
            if (!this._popover) {
                this._popover = new PopoverButton(this._settings, {
                    invoke: key => this._invoke(key),
                    opened: () => this._opened(),
                });
                Main.panel.addToStatusArea(this.uuid, this._popover.button);
            }
            this._popover.render(parsed.state);
            const mode = this._settings.get_string('panel-mode');
            const shownMode = PANEL_MODES.includes(mode) ? mode : PANEL_MODES[0];
            log(`popover=shown protocol=1 mode=${shownMode} segments=${panelModeFor(parsed.state, shownMode).segments.length}`);
            if (!this._ownId)
                this._ownName();   // als Letztes (FE-2)
        });
    }

    _guard(draw) {
        try {
            draw();
        } catch (e) {
            console.error(`[ClaudeMonitor] draw failed: ${e.message}`);
            this._hide('render');
        }
    }

    // --- Abbau ---

    _hide(reason) {
        this._releaseName();
        this._destroyButton();
        if (reason === 'call' || reason === 'trayAbsent')
            this._dropProxy();
        log(`popover=hidden reason=${reason}`);
    }

    _destroyButton() {
        if (this._popover) {
            const popover = this._popover;
            this._popover = null;
            try {
                popover.destroy();
            } catch (e) {
                console.error(`[ClaudeMonitor] destroy failed: ${e.message}`);
            }
        }
    }

    _ownName() {
        this._ownId = Gio.bus_own_name(Gio.BusType.SESSION, OWN_NAME, Gio.BusNameOwnerFlags.NONE, null,
            () => log('name=owned'),
            () => {
                if (!this._ownId)
                    return;
                log('name=lost');
                this._ownId = 0;
                this._destroyButton();
            });
    }

    _releaseName() {
        if (!this._ownId)
            return;
        Gio.bus_unown_name(this._ownId);
        this._ownId = 0;
        log('name=released');
    }

    // --- Aufrufe an den Tray ---

    _invoke(key) {
        this._proxy?.InvokeAsync(key).catch(() => {});
    }

    _opened() {
        this._proxy?.OpenedAsync().catch(() => {});
    }
}
