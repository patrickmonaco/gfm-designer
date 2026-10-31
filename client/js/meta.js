// Labels and icons of the GFM metadata codes.

// GFM_COMP.CTYPE (+ SF = sub-form, GFM_ITEMS.TCOMP = 'D')
export const CTYPES = {
    CT: { label: 'Texte', icon: 'bi-input-cursor-text' },
    CN: { label: 'Zone de texte', icon: 'bi-textarea-t' },
    NB: { label: 'Nombre', icon: 'bi-123' },
    DA: { label: 'Date', icon: 'bi-calendar-event' },
    LI: { label: 'Liste', icon: 'bi-list-ul' },
    DL: { label: 'Liste dynamique', icon: 'bi-database' },
    SF: { label: 'Sous-formulaire', icon: 'bi-table' },
};

// GFM_ITEMS.VTYPE of list items
export const VTYPES = {
    RADIO: { label: 'Boutons radio', icon: 'bi-ui-radios' },
    LIST: { label: 'Liste déroulante', icon: 'bi-menu-down' },
    CHECKBOX: { label: 'Cases à cocher', icon: 'bi-ui-checks' },
    NATIVE_SINGLE_CHECKBOX: { label: 'Case à cocher unique', icon: 'bi-check2-square' },
    POPUP: { label: 'Liste popup', icon: 'bi-window-stack' },
};

export const isList = (item) => item.ctype === 'LI' || item.ctype === 'DL';

export function itemIcon(item) {
    if (isList(item) && VTYPES[item.vtype]) return VTYPES[item.vtype].icon;
    return (CTYPES[item.ctype] || CTYPES.CT).icon;
}

export function itemTypeLabel(item) {
    if (item.tcomp === 'D') return 'Sous-formulaire';
    if (isList(item) && VTYPES[item.vtype]) return VTYPES[item.vtype].label;
    return item.compLib || (CTYPES[item.ctype] || {}).label || item.ctype;
}

// Width: GFM_ITEMS.COL_SPAN is in sixths of a row (1..6), the APEX grid has
// 12 columns (gfm_builder sets colspan = col_span * 2). Without a width APEX
// shares the row: approximated here by a half row when the item does not
// start a new row, a full row otherwise.
export function gridSpan(item) {
    if (item.colSpan) return Math.min(12, Math.max(2, item.colSpan * 2));
    return item.newRow === 'N' ? 6 : 12;
}

export const WIDTHS = [
    { value: '', label: 'Automatique' },
    { value: 1, label: '1/6 de ligne' },
    { value: 2, label: '1/3 de ligne' },
    { value: 3, label: '1/2 ligne' },
    { value: 4, label: '2/3 de ligne' },
    { value: 5, label: '5/6 de ligne' },
    { value: 6, label: 'Ligne entière' },
];

export const PREF_LABELS = {
    $ITEM_TEMPLATE: 'Position des libellés',
    $REGION_SECTION: 'Affichage des sections',
    $ITEM_HELP: 'Aide sur les champs',
    $PAGE_TEMPLATE: 'Modèle de page',
};

/** Blocking problem of an item for the generation, or null. */
export function itemProblem(item) {
    if (item.isInline === 'Y' && !(item.lov || '').split(':').some((v) => v.trim())) {
        return 'Liste sans valeur : ajoutez au moins une valeur';
    }
    return null;
}
