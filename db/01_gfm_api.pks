create or replace package gfm_api
/**
 * GFM Designer - REST API layer.
 *
 * Called by the ORDS handlers of module gfm.designer (see 03_ords_module.sql).
 * Each public procedure reads its input (path parameters, JSON body),
 * works on the GFM metadata tables, and writes the HTTP response itself
 * (status + JSON body) through OWA/HTP.
 *
 * Responses
 *   - read operations return the requested resource,
 *   - every operation that changes a form returns the FULL form
 *     (see get_form) so that the client simply re-renders it,
 *   - creations return {"id": <new id>, "form": {...}} with status 201,
 *   - errors return {"error": "<message>"} with status
 *       404 not found, 409 conflict, 422 business error (ORA-20xxx),
 *       500 unexpected error.
 *
 * Page generation is delegated to gfm_builder (generate_ddl, generate_form).
 *
 * @author  P. Monaco - GPM Factory
 * @version 1.0 oct 2026
 */
authid definer
as

/** GET info - current user, target application. */
procedure get_info (p_user in varchar2);

/** GET forms - list of forms with counters. */
procedure list_forms;

/** GET forms/:id - full form: properties, sections, items, preferences. */
procedure get_form (p_id in number);

/**
 * POST forms - body {lib, notes, vtype: "M"|"D", authent: "Y"|"N"}.
 * The code is derived from the label, a free page id is reserved and the
 * default preferences are created.
 */
procedure create_form (p_body in clob);

/** PUT forms/:id - body: any of {lib, notes, vtype, authent}. */
procedure update_form (p_id in number, p_body in clob);

/**
 * DELETE forms/:id[?force=Y] - deletes the form definition.
 * 409 if data exists in GFM_DATA, unless force=Y (data deleted too).
 * The generated view and APEX page are left in place.
 */
procedure delete_form (p_id in number, p_force in varchar2 default 'N');

/** POST forms/:id/copy - duplicates the form (sections, items, preferences). */
procedure copy_form (p_id in number);

/**
 * POST forms/:id/generate - generates the view (generate_ddl) and, for a
 * master form, the APEX page (generate_form).
 * Response: {appId, pageId, message, form}.
 */
procedure generate_form (p_id in number);

/** POST forms/:id/reset - deletes the data and releases the slot columns. */
procedure reset_form (p_id in number);

/**
 * PUT forms/:id/layout - result of a drag & drop on the canvas:
 * {"unsectioned": [itemId...], "sections": [{"id": n, "items": [itemId...]}...]}
 * Section ranks, item sections and item sequences are rewritten
 * in the order received, in one transaction.
 */
procedure save_layout (p_id in number, p_body in clob);

/** PUT forms/:id/prefs - body {"prefs": {"$ITEM_TEMPLATE": "ABOVE", ...}}; null removes. */
procedure save_prefs (p_id in number, p_body in clob);

/** POST forms/:id/sections - body {name, rank?}. */
procedure create_section (p_form_id in number, p_body in clob);

/** PUT sections/:id - body {name}. */
procedure update_section (p_id in number, p_body in clob);

/** DELETE sections/:id - the items of the section become unsectioned. */
procedure delete_section (p_id in number);

/**
 * POST forms/:id/items - body {compId, tcomp?: "C"|"D", lib?, sectionId?, code?}.
 * tcomp "D": compId is the id of a detail form (embedded grid).
 */
procedure create_item (p_form_id in number, p_body in clob);

/**
 * PUT items/:id - body: any of {lib, code, description, vtype, lov, mandatory,
 * newRow, colSpan, icon, masterId, masterValue, notes}.
 */
procedure update_item (p_id in number, p_body in clob);

/** DELETE items/:id - dependent items lose their master. */
procedure delete_item (p_id in number);

/** GET items/:id/lov - values [{d, r}] of a list item (empty array otherwise). */
procedure get_item_lov (p_id in number);

/**
 * GET components - palette and catalogue:
 * {components: [{..., factory, objSource, itemCount, valueCount}], detailForms: [...]}.
 */
procedure list_components;

/** GET components/:id - component with its values (ordered by SEQ). */
procedure get_component (p_id in number);

/**
 * POST components - body {lib, notes?, ctype, vtype?, icon?, groupe?, objSource?}.
 * ctype: CT, CN, NB, DA, LI (values in GFM_LOV), DL (view with columns D, R).
 */
procedure create_component (p_body in clob);

/**
 * PUT components/:id - body: any of the creation attributes.
 * Factory components (FACTORY = 'Y'): label and type cannot change.
 * The type of a component used by items cannot change.
 */
procedure update_component (p_id in number, p_body in clob);

/** DELETE components/:id - 409 for a factory component or one used by items. */
procedure delete_component (p_id in number);

/**
 * PUT components/:id/values - full list of the values of a list component,
 * in display order: {"values": [{"id"?, "d", "r", "isDefault"}]}.
 * Values with an id are updated, without id inserted, missing ones deleted.
 */
procedure save_values (p_id in number, p_body in clob);

/**
 * GET components/:id/preview - values as displayed in a generated page
 * [{d, r}], at most 100; for a dynamic list, the result of its view.
 */
procedure preview_component (p_id in number);

end gfm_api;
/
