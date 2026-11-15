// Ein Tray-Zustand ohne die Form, die die Zeichnung braucht, gilt als ungültig, statt die Zeichnung zu sprengen.
import {parseState} from '../popoverState.js';

const minimal = '{"protocol":1,"header":"h","content":"accounts","accounts":[],"controls":[],' +
    '"panel":{"activeAccount":{"segments":[]},"overview":{"segments":[]}}}';

const gueltig = parseState(minimal);
if (gueltig.ok !== true)
    throw new Error(`vollständiger Zustand: ok=${gueltig.ok} reason=${gueltig.reason}`);

const rueckfall = parseState('{"protocol":1}');
if (rueckfall.ok !== false || rueckfall.reason !== 'shape')
    throw new Error(`Rückfall {"protocol":1}: ok=${rueckfall.ok} reason=${rueckfall.reason}`);
