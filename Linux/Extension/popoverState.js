// Regeln des Popover-Vertrags (Protokoll 1) — ohne Shell-Importe, mit `gjs -m` ladbar.
// Die Zeichnung steht in extension.js; hier steht, was gilt (CM-42, FE-4/5/6/8).

export const PROTOCOL = 1;

/** Werte des Schlüssels `panel-mode` = JSON-Schlüssel `panel.<modus>`. */
export const PANEL_MODES = ['activeAccount', 'overview'];

/** Stufe → CSS-Klasse. `null` und `noData` sind neutral (nie grün). */
export const STATUS_CLASS = {
    green: 'cm-green',
    yellow: 'cm-yellow',
    red: 'cm-red',
    neutral: 'cm-neutral',
    noData: 'cm-neutral',
};

export function statusClass(status) {
    return STATUS_CLASS[status] ?? 'cm-neutral';
}

function isObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * Prüft Text → Zustand. `{ok: true, state}` oder `{ok: false, reason}` mit
 * `parse` (kein String, kein JSON-Objekt), `protocol` (nicht die Zahl 1) oder
 * `shape` (Form, die die Zeichnung braucht, fehlt — z. B. der Rückfall
 * `{"protocol":1}` des Tray bei einem Codier-Fehler).
 */
export function parseState(text) {
    if (typeof text !== 'string')
        return {ok: false, reason: 'parse'};
    let state;
    try {
        state = JSON.parse(text);
    } catch (e) {
        return {ok: false, reason: 'parse'};
    }
    if (!isObject(state))
        return {ok: false, reason: 'parse'};
    if (state.protocol !== PROTOCOL)
        return {ok: false, reason: 'protocol'};
    const shapeOk = typeof state.header === 'string' &&
        typeof state.content === 'string' &&
        Array.isArray(state.accounts) &&
        Array.isArray(state.controls) &&
        isObject(state.panel) &&
        PANEL_MODES.every(mode =>
            isObject(state.panel[mode]) && Array.isArray(state.panel[mode].segments));
    if (!shapeOk)
        return {ok: false, reason: 'shape'};
    return {ok: true, state};
}

/** Die Leiste im gewählten Modus; ein unbekannter Modus fällt auf den Standard. */
export function panelModeFor(state, mode) {
    return state.panel[PANEL_MODES.includes(mode) ? mode : PANEL_MODES[0]];
}

/** Platz eines Bedienelements nach `role` (FE-8). */
export function slotFor(control) {
    switch (control.role) {
    case 'refresh': return 'header';
    case 'quit': return 'footer';
    case 'startAtLogin':
    case 'automaticUpdates': return 'switch';
    case 'checkForUpdates': return 'link';
    case 'information': return 'info';
    case 'separator': return 'separator';
    default: return 'plain';
    }
}
