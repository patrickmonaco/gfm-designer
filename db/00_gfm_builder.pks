create or replace package gfm_builder
/**
 * GFM Builder - generation of APEX form pages from user-defined metadata.
 *
 * Reads the form definition entered by end users (GFM_FORM, GFM_SECTIONS,
 * GFM_ITEMS, GFM_COMP, GFM_LOV, GFM_FORM_PREFS) and builds, component by
 * component, a complete form page inside an existing APEX application,
 * the same way an application import would.
 *
 * Data is stored generically in GFM_DATA (slot columns C001..Cnnn, N001);
 * generate_ddl creates, for each form, a typed view G$_<CODE> over GFM_DATA
 * that the generated page uses as its form source.
 *
 * WARNING: the page generation relies on UNSUPPORTED internal APEX APIs
 * (wwv_flow_imp_page.*, wwv_flow_id, wwv_flow_t_plugin_attributes), written
 * for APEX 26.1. Re-test after every APEX upgrade.
 *
 * Typical sequence for a new form:
 *   1. init_prefs(form_id)          -- default preferences
 *   2. generate_ddl(form_id)        -- view + trigger + UI defaults
 *   3. generate_form(form_id, page) -- APEX page
 *
 * @author  P. Monaco - GPM Factory
 * @version 2.1  oct 2026 - APEX 26.1: wwv_flow_imp_page, named attributes
 *          2.0  oct 2026 - refactoring, bug fixes, documentation
 *          1.2  sep 2022
 *          1.1  jan 2022
 *          1.0  oct 2021
 */
as

/**
 * Generates (or regenerates) the APEX form page of a form.
 *
 * The target application is read from GFM_SETUP (parameter APP_RUN_ID).
 * If the page already exists it is REMOVED first: any manual change made
 * in Page Designer on that page is lost.
 * All the work is done in a single transaction, committed on success and
 * rolled back on error.
 *
 * @param  fid  form id (GFM_FORM.ID)
 * @param  pid  target page id; when null, a new id is taken from GFM_PAGE_SEQ
 * @return 0 on success
 * @raises ORA-20201 "<step> - <error>" on any failure (transaction rolled back)
 */
function generate_form(fid number, pid number DEFAULT null)
return number;

/**
 * Generates the database objects supporting a form:
 *   - allocates a GFM_DATA slot column (MAP_ID) to each new item,
 *   - creates the view G$_<CODE> mapping slot columns to item codes,
 *   - adds a disabled primary key on SEQ_ID (needed by the APEX form region),
 *   - creates the INSTEAD OF INSERT trigger G$_<CODE>_TRG,
 *   - synchronises APEX UI defaults (labels, help texts).
 *
 * Note: DDL statements commit implicitly.
 *
 * @param  fid    form id
 * @param  ptype  'M' master form (default) or 'D' detail form: adds a PARENT_ID
 *                column mapped to GFM_DATA.N001 (used by interactive grids)
 * @raises ORA-20300 "<view>.<step> - <error>" on failure
 */
procedure generate_ddl (fid number, ptype varchar2 default 'M');

/**
 * Returns the SQL query of the list of values of an item.
 * Called at runtime by the generated pages (LOV of type
 * "PL/SQL function body returning SQL query").
 *
 * - component type 'LI': values stored in GFM_LOV for the item component,
 * - otherwise: query on the view/table named in GFM_COMP.OBJ_SOURCE,
 *   which must expose columns D (display) and R (return).
 *
 * @param  id  item id (GFM_ITEMS.ID)
 * @return a "select d, r ..." query
 */
function get_lov (id number) 
return varchar2;

/**
 * Returns the SQL query of a GFM_LOV list identified by its component label.
 *
 * @param  plov  component label (GFM_COMP.LIB)
 * @return a "select d, r ..." query
 */
function get_lov (plov varchar2) 
return varchar2;

/**
 * Returns the SQL query of a GFM_LOV list identified by its component id.
 *
 * @param  id  component id (GFM_LOV.COMP_ID)
 * @return a "select d, r ..." query
 */
function get_lov_master (id varchar2) 
return varchar2;

/**
 * Returns the first free page id in the generation range (101..400):
 * not used by a page of the application nor reserved by a GFM_FORM row.
 *
 * @param  fid  APPLICATION id (despite the parameter name)
 * @return free page id, or null if the range is full
 */
function getNewPageid (fid number)
return number;

/**
 * Duplicates a form definition (form, sections, items). LIB and CODE are
 * suffixed with _HH24MISS; a free page id of the application is reserved.
 * The copy is not generated: run generate_ddl / generate_form on it.
 *
 * @param  fid    source form id
 * @param  appid  application id used to reserve a free page id
 * @return new form id, or -1 on error (transaction rolled back, error logged
 *         in APEX debug)
 */
function copyForm(fid number, appid number)
return number;

/**
 * Copies all the items of a form into another existing form.
 * Sections are matched by name in the target form.
 *
 * @param  fid  source form id
 * @param  tid  target form id
 * @return 0 on success, -1 on error (rolled back, logged)
 */
function copyItems(fid number       --origin form
                    , tid number    -- target form
                  )
return number;

/**
 * Renumbers the display sequence of the items of a form (10, 20, 30...)
 * following the order of a colon-separated list of item ids.
 *
 * @param  pid    FORM id (despite the parameter name)
 * @param  plist  item ids in display order, e.g. '12:7:9'
 * @return 0 on success, 1 on error (rolled back, logged)
 */
function reseq (pid number, plist varchar2)
return number;

/**
 * Bootstraps the preferences of a form from the internal components
 * named '$...' in GFM_COMP (default value = GFM_LOV row with IS_DEFAULT='Y').
 * Existing preferences are kept (safe to call several times).
 *
 * @param  fid  form id
 * @return 0 on success
 */
function init_prefs(fid number)    -- form id
return number;

/**
 * Resets a form: deletes all its data in GFM_DATA and releases the slot
 * columns allocated to its items (MAP_ID / MAP_LASTID).
 * Run generate_ddl afterwards to rebuild the view.
 *
 * @param  fid  form id
 * @return 0 on success, 1 on error (rolled back, logged)
 */
function reset_form(fid number)    -- form id
return number;

end gfm_builder;
/
