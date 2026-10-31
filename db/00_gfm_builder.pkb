create or replace package body gfm_builder
/**
 * GFM Builder - package body. See the specification for the public API.
 *
 * Structure of the body:
 *   1. Constants, types, package state
 *   2. Generic helpers (logging, parameters, naming, templates)
 *   3. Page generation, one procedure per group of components
 *   4. DDL generation
 *   5. Lists of values
 *   6. Form maintenance (copy, resequence, preferences, reset)
 *
 * Unsupported APEX internals used: wwv_flow_imp_page (section 3),
 * wwv_flow_id (section 3) and wwv_flow_t_plugin_attributes (function attrs).
 *
 * APEX 26.1 (v2.1):
 * - every call goes directly to wwv_flow_imp_page, the API used by the 26.1
 *   exports. wwv_flow_api is only a compatibility layer whose create_page_item
 *   passes a session state data type (P_DATA_TYPE) rejected by constraint
 *   STEP_ITEM_SS_DATA_TYPE_CK;
 * - component attributes use the named format of the exports (p_attributes,
 *   built by attrs) instead of p_attribute_01..25;
 * - application / page ids are passed explicitly (no wwv_flow_imp.import_begin
 *   context is opened).
 *
 * @author  P. Monaco - GPM Factory
 * @version 2.7 oct 2026 - remove_generated: pages and views of a deleted form
 *          2.6 oct 2026 - NUMBER / DATE storage columns (GFM_ITEMS.MAP_COL)
 *          2.5 oct 2026 - IG: reuse the report / view created with the grid
 *          2.4 oct 2026 - report view G$_<CODE>_R and interactive report page
 *          2.3 oct 2026 - explicit error for an inline list without values
 *          2.2 oct 2026 - list values sorted by GFM_LOV.SEQ
 *          2.1 oct 2026 - APEX 26.1: wwv_flow_imp_page, named attributes
 *          2.0 oct 2026 - refactoring, bug fixes, documentation
 */
as

-- =====================================================================
-- 1. CONSTANTS, TYPES, STATE
-- =====================================================================

-- Error codes
c_err_generate   constant pls_integer := -20201;  -- generate_form failure
c_err_param      constant pls_integer := -20202;  -- missing setup parameter
c_err_metadata   constant pls_integer := -20204;  -- inconsistent metadata / template
c_err_ddl        constant pls_integer := -20300;  -- generate_ddl failure

-- Naming
c_view_prefix    constant varchar2(3)  := 'G$_';        -- support views
c_inline_list    constant varchar2(30) := 'Inline List'; -- GFM_COMP.LIB of inline lists

-- Page id range used by getNewPageid
c_page_slot_min  constant pls_integer := 101;
c_page_slot_max  constant pls_integer := 400;

-- Page displayed after processing (branches)
c_return_page    constant pls_integer := 20;   -- when the form has no report page

-- Storage format of the dates in GFM_DATA (VARCHAR2), unless GFM_SETUP.DATE_FORMAT
c_date_format    constant varchar2(30) := 'MM/DD/YYYY';

-- Item types (GFM_COMP.CTYPE)
c_ct_text        constant varchar2(2) := 'CT';   -- text field
c_ct_textarea    constant varchar2(2) := 'CN';   -- text area
c_ct_number      constant varchar2(2) := 'NB';   -- number
c_ct_date        constant varchar2(2) := 'DA';   -- date
c_ct_list        constant varchar2(2) := 'LI';   -- static list (GFM_LOV)
c_ct_dyn_list    constant varchar2(2) := 'DL';   -- dynamic list (OBJ_SOURCE)

-- Item kinds (GFM_ITEMS.TCOMP)
c_tcomp_column   constant varchar2(1) := 'C';    -- regular column
c_tcomp_detail   constant varchar2(1) := 'D';    -- embedded detail form (IG)

type t_id_map   is table of number        index by varchar2(128);
type t_pref_map is table of varchar2(100) index by varchar2(100);
type t_id_list  is table of number;

-- Generation context, shared by the page generation procedures
type t_ctx is record (
    app_id             number,
    page_id            number,
    form               gfm_form%rowtype,
    prefs              t_pref_map,
    -- template ids of the target application
    ui_id              number,
    theme_no           number,       -- current theme of the target application
    page_tpl           number,
    region_tpl         number,       -- Region   STANDARD
    tabs_tpl           number,       -- Region   TABS_CONTAINER
    button_tpl         number,       -- Button   TEXT
    label_tpl          number,       -- default item label template ($ITEM_TEMPLATE)
    label_tpls         t_id_map,     -- REQUIRED[_xxx] / OPTIONAL[_xxx]
    -- generated components
    main_region_id     number,       -- region holding the native form
    section_parent_id  number,       -- parent of the section regions
    section_regions    t_id_map,     -- section name -> region id
    display_selector   varchar2(1),
    delete_button_id   number
);

-- Current step, used in error messages and debug traces
g_step varchar2(100);


-- =====================================================================
-- 2. GENERIC HELPERS
-- =====================================================================

procedure set_step (p_step in varchar2)
is
begin
    g_step := substr(p_step, 1, 100);
    apex_debug.trace('gfm_builder: %s', g_step);
end set_step;

procedure log_error (
    p_where     in varchar2,
    p_error     in varchar2,
    p_backtrace in varchar2 )
is
begin
    apex_debug.error('gfm_builder.%s [%s] %s %s', p_where, g_step, p_error, p_backtrace);
end log_error;

function to_boolean (p_string in varchar2)
return boolean
is
begin
    return case upper(p_string)
             when 'TRUE'  then true
             when 'FALSE' then false
           end;
end to_boolean;

/** Value of a GFM_SETUP parameter, null if the parameter does not exist. */
function get_param (p_name in varchar2)
return varchar2
is
    l_value gfm_setup_v.valeur%type;
begin
    select valeur
      into l_value
      from gfm_setup_v
     where parameter = p_name;
    return l_value;
exception
    when no_data_found then
        return null;
end get_param;

/** Name of the support view of a form (validated as a SQL name). */
function view_name (p_form_code in varchar2)
return varchar2
is
begin
    return dbms_assert.simple_sql_name(
               upper(c_view_prefix || replace(p_form_code, ' ', '_')) );
end view_name;

/** Name of the report view of a form: G$_<CODE>_R. */
function report_view_name (p_form_code in varchar2)
return varchar2
is
begin
    return dbms_assert.simple_sql_name(view_name(p_form_code) || '_R');
end report_view_name;

/** Storage format of the dates (GFM_SETUP.DATE_FORMAT, default MM/DD/YYYY). */
function date_format
return varchar2
is
begin
    return nvl(get_param('DATE_FORMAT'), c_date_format);
end date_format;

/** APEX page item name for a column code: P<page>_<CODE>. */
function item_name (p_ctx in t_ctx, p_code in varchar2)
return varchar2
is
begin
    return 'P' || p_ctx.page_id || '_' || upper(p_code);
end item_name;

/** Preference value, null if not defined. */
function pref (p_ctx in t_ctx, p_name in varchar2)
return varchar2
is
begin
    return case when p_ctx.prefs.exists(p_name) then p_ctx.prefs(p_name) end;
end pref;

/**
 * Template id from its type and internal name, in the CURRENT theme
 * (an upgraded application may still contain the templates of older themes).
 * p_name may also be a numeric template id (e.g. preference $PAGE_TEMPLATE),
 * which resolves templates sharing the same internal name.
 */
function get_template_id (
    p_app_id   in number,
    p_theme_no in number,
    p_type     in varchar2,
    p_name     in varchar2 )
return number
is
    l_id         number;
    l_candidates varchar2(4000);
begin
    if validate_conversion(p_name as number) = 1 then
        -- explicit template id
        select template_id
          into l_id
          from apex_application_templates
         where application_id = p_app_id
           and template_type  = p_type
           and template_id    = to_number(p_name);
    else
        select template_id
          into l_id
          from apex_application_templates
         where application_id = p_app_id
           and theme_number   = p_theme_no
           and template_type  = p_type
           and internal_name  = p_name;
    end if;
    return l_id;
exception
    when no_data_found then
        raise_application_error(c_err_metadata,
            'Template ' || p_type || ' / ' || p_name
            || ' introuvable dans le thème ' || p_theme_no
            || ' de l''application ' || p_app_id);
    when too_many_rows then
        select listagg(template_id || ' "' || template_name || '"', ', ')
                 within group (order by template_id)
          into l_candidates
          from apex_application_templates
         where application_id = p_app_id
           and theme_number   = p_theme_no
           and template_type  = p_type
           and internal_name  = p_name;
        raise_application_error(c_err_metadata,
            'Plusieurs templates ' || p_type || ' / ' || p_name
            || ' dans le thème ' || p_theme_no
            || ' de l''application ' || p_app_id
            || ' : ' || l_candidates
            || '. Indiquer l''id voulu dans la préférence du formulaire.');
end get_template_id;

/** Suffix of the label template names for the $ITEM_TEMPLATE preference. */
function label_suffix (p_ctx in t_ctx)
return varchar2
is
begin
    return case pref(p_ctx, '$ITEM_TEMPLATE')
             when 'BESIDE' then null
             when 'ABOVE'  then '_ABOVE'
             else               '_FLOATING'      -- FLOATING and default
           end;
end label_suffix;

/** Label template of an item depending on its mandatory flag. */
function label_template (p_ctx in t_ctx, p_mandatory in varchar2)
return number
is
begin
    return p_ctx.label_tpls(
               case when p_mandatory = 'Y' then 'REQUIRED' else 'OPTIONAL' end
               || label_suffix(p_ctx) );
end label_template;

/** Region of a section, main form region when the item has no section. */
function region_for_section (p_ctx in t_ctx, p_section in varchar2)
return number
is
begin
    if p_section is not null and p_ctx.section_regions.exists(p_section) then
        return p_ctx.section_regions(p_section);
    end if;
    return p_ctx.main_region_id;
end region_for_section;

/** Converts 'a:b:c' into an APEX static LOV 'STATIC:a;a,b;b,c;c'. */
function static_lov (p_values in varchar2)
return varchar2
is
    l_values  apex_t_varchar2 := apex_string.split(p_values, ':');
    l_entries apex_t_varchar2 := apex_t_varchar2();
begin
    for i in 1 .. l_values.count loop
        apex_string.push(l_entries, l_values(i) || ';' || l_values(i));
    end loop;
    return 'STATIC:' || apex_string.join(l_entries, ',');
end static_lov;

/**
 * Component attributes in the APEX 26.1 format (parameter p_attributes),
 * from a list of key/value pairs: apex_t_varchar2('key1','val1','key2','val2').
 * Same construct as in the 26.1 exports. Internal type wwv_flow_t_plugin_attributes.
 */
function attrs (p_pairs in apex_t_varchar2)
return clob
is
begin
    return wwv_flow_t_plugin_attributes(p_pairs).to_clob;
end attrs;


-- =====================================================================
-- 3. PAGE GENERATION
-- =====================================================================

-- ---------------------------------------------------------------------
-- 3.1 Context initialisation
-- ---------------------------------------------------------------------

procedure load_form (p_ctx in out nocopy t_ctx, p_form_id in number)
is
begin
    select *
      into p_ctx.form
      from gfm_form
     where id = p_form_id;
exception
    when no_data_found then
        raise_application_error(c_err_metadata, 'Formulaire ' || p_form_id || ' introuvable');
end load_form;

procedure load_prefs (p_ctx in out nocopy t_ctx, p_form_id in number)
is
begin
    -- defaults
    p_ctx.prefs('$ITEM_TEMPLATE')  := 'FLOATING';        -- FLOATING | ABOVE | BESIDE
    p_ctx.prefs('$REGION_SECTION') := 'TABS_CONTAINER';  -- TABS_CONTAINER | DISPLAY_SELECTOR | STANDARD
    p_ctx.prefs('$ITEM_HELP')      := 'N';               -- Y: item description used as help text
    p_ctx.prefs('$PAGE_TEMPLATE')  := 'STANDARD';        -- internal name of the page template

    -- form preferences override the defaults
    for r in ( select pref, val
                 from gfm_form_prefs
                where form_id = p_form_id ) loop
        p_ctx.prefs(r.pref) := r.val;
    end loop;
end load_prefs;

procedure load_templates (p_ctx in out nocopy t_ctx)
is
    l_label_names apex_t_varchar2 := apex_t_varchar2(
        'OPTIONAL', 'REQUIRED',
        'OPTIONAL_ABOVE', 'REQUIRED_ABOVE',
        'OPTIONAL_FLOATING', 'REQUIRED_FLOATING' );
begin
    -- User interface: the one used by most pages (some pages, such as the
    -- global page, may have a null user_interface_id)
    set_step('load templates / user interface');
    begin
        select user_interface_id
          into p_ctx.ui_id
          from apex_application_pages
         where application_id    = p_ctx.app_id
           and user_interface_id is not null
         group by user_interface_id
         order by count(*) desc
         fetch first 1 row only;
    exception
        when no_data_found then
            raise_application_error(c_err_metadata,
                'Aucune interface utilisateur trouvée pour l''application ' || p_ctx.app_id);
    end;

    -- Current theme: upgraded applications may keep older themes
    set_step('load templates / current theme');
    begin
        select theme_number
          into p_ctx.theme_no
          from apex_application_themes
         where application_id = p_ctx.app_id
           and is_current     = 'Yes';
    exception
        when no_data_found or too_many_rows then
            raise_application_error(c_err_metadata,
                'Thème courant introuvable ou ambigu pour l''application ' || p_ctx.app_id);
    end;

    set_step('load templates / templates');
    p_ctx.page_tpl   := get_template_id(p_ctx.app_id, p_ctx.theme_no, 'Page',   pref(p_ctx, '$PAGE_TEMPLATE'));
    p_ctx.region_tpl := get_template_id(p_ctx.app_id, p_ctx.theme_no, 'Region', 'STANDARD');
    p_ctx.tabs_tpl   := get_template_id(p_ctx.app_id, p_ctx.theme_no, 'Region', 'TABS_CONTAINER');
    p_ctx.button_tpl := get_template_id(p_ctx.app_id, p_ctx.theme_no, 'Button', 'TEXT');

    for i in 1 .. l_label_names.count loop
        p_ctx.label_tpls(l_label_names(i)) :=
            get_template_id(p_ctx.app_id, p_ctx.theme_no, 'Item Label', l_label_names(i));
    end loop;

    p_ctx.label_tpl := p_ctx.label_tpls('OPTIONAL' || label_suffix(p_ctx));
end load_templates;

/**
 * Legacy: GFM_FORM.SECTIONS (ordered list "s1:s2") is still filled when empty,
 * although the generation now relies on GFM_SECTIONS.RANK.
 * @return number of distinct sections used by the items
 */
function sync_legacy_sections (p_form_id in number)
return pls_integer
is
    l_nb_sections pls_integer;
    l_sections    gfm_form.sections%type;
begin
    select count(distinct section_id)
      into l_nb_sections
      from gfm_items
     where form_id = p_form_id;

    if l_nb_sections > 0 then
        select sections into l_sections from gfm_form where id = p_form_id;

        if l_sections is null then
            select listagg(distinct section, ':') within group (order by section)
              into l_sections
              from gfm_items
             where form_id = p_form_id;

            update gfm_form
               set sections = l_sections
             where id = p_form_id;
        end if;
    end if;

    return l_nb_sections;
end sync_legacy_sections;

/** Gives a sequence (after the current max) to the items without one. */
procedure ensure_item_sequences (p_form_id in number)
is
begin
    merge into gfm_items t
    using ( select id,
                   ( select nvl(max(seq), 0)
                       from gfm_items
                      where form_id = p_form_id )
                   + 10 * row_number() over (order by id) as new_seq
              from gfm_items
             where form_id = p_form_id
               and seq is null ) s
       on ( t.id = s.id )
     when matched then
        update set t.seq = s.new_seq;
end ensure_item_sequences;

-- ---------------------------------------------------------------------
-- 3.2 Page
-- ---------------------------------------------------------------------

procedure create_page (p_ctx in out nocopy t_ctx)
is
begin
    -- Any existing version of the page is removed: custom changes are lost
    set_step('remove page');
    wwv_flow_imp_page.remove_page(p_flow_id => p_ctx.app_id, p_page_id => p_ctx.page_id);

    set_step('create page');
    wwv_flow_imp_page.create_page(
         p_id                        => p_ctx.page_id
        ,p_flow_id                   => p_ctx.app_id
        ,p_user_interface_id         => p_ctx.ui_id
        ,p_name                      => p_ctx.form.lib
        ,p_alias                     => replace(p_ctx.form.lib, ' ', '')
        ,p_step_title                => p_ctx.form.lib
        ,p_step_template             => p_ctx.page_tpl
        ,p_autocomplete_on_off       => 'OFF'
        ,p_javascript_code           => 'var htmldb_delete_message=''"DELETE_CONFIRM_MSG"'';'
        -- radio group alignment in Redwood Light, optional labels
        ,p_inline_css                => apex_string.join(apex_t_varchar2(
             '.t-Form-fieldContainer:not(.t-Form-fieldContainer--stacked):not(.t-Form-fieldContainer--floatingLabel) .apex-item-group--rc input + label {',
             '    margin-top: 14px;',
             '    margin-bottom: 8px;',
             '}'), chr(10))
        ,p_page_template_options     => '#DEFAULT#'
        -- public page unless the form requires authentication
        ,p_page_is_public_y_n        => case when p_ctx.form.authent = 'Y' then 'N' else 'Y' end
        ,p_last_updated_by           => nvl(v('APP_USER'), user)
        ,p_last_upd_yyyymmddhh24miss => to_char(sysdate, 'YYYYMMDDHH24MISS')
    );
end create_page;

-- ---------------------------------------------------------------------
-- 3.3 Regions: main form region, optional selector / tabs, sections
-- ---------------------------------------------------------------------

procedure create_regions (
    p_ctx         in out nocopy t_ctx,
    p_form_id     in number,
    p_nb_sections in pls_integer )
is
    l_layout        varchar2(100) := pref(p_ctx, '$REGION_SECTION');
    l_multi         boolean       := p_nb_sections > 1;
    l_region_id     number;
    l_options       varchar2(1000);
    l_position      varchar2(100);
begin
    -- Main region: native form on the support view
    set_step('create main region');
    p_ctx.main_region_id    := wwv_flow_id.next_val;
    p_ctx.section_parent_id := p_ctx.main_region_id;
    p_ctx.display_selector  := 'N';

    wwv_flow_imp_page.create_page_plug(
         p_id                      => p_ctx.main_region_id
        ,p_flow_id                 => p_ctx.app_id
        ,p_page_id                 => p_ctx.page_id
        ,p_plug_name               => nvl(p_ctx.form.notes, p_ctx.form.lib)
        ,p_region_template_options => '#DEFAULT#:t-TabsRegion-mod--simple'
        ,p_plug_template           => p_ctx.region_tpl
        ,p_plug_display_sequence   => 0
        ,p_plug_display_point      => 'BODY'
        ,p_plug_item_display_point => 'ABOVE'
        ,p_query_type              => 'TABLE'
        ,p_query_table             => view_name(p_ctx.form.code)
        ,p_include_rowid_column    => false
        ,p_is_editable             => true
        ,p_edit_operations         => 'i:u:d'
        ,p_lost_update_check_type  => 'VALUES'
        ,p_plug_source_type        => 'NATIVE_FORM'
    );

    -- More than one section: display selector or tabs container
    if l_multi and l_layout = 'DISPLAY_SELECTOR' then
        set_step('create selector region');
        wwv_flow_imp_page.create_page_plug(
             p_id                      => wwv_flow_id.next_val
            ,p_flow_id                 => p_ctx.app_id
            ,p_page_id                 => p_ctx.page_id
            ,p_plug_name               => 'Selector'
            ,p_parent_plug_id          => p_ctx.main_region_id
            ,p_region_template_options => '#DEFAULT#:t-Region--removeHeader js-removeLandmark:t-Region--noUI:t-Region--scrollBody'
            ,p_plug_template           => p_ctx.region_tpl
            ,p_plug_display_sequence   => 6
            ,p_plug_display_point      => 'BODY'
            ,p_plug_item_display_point => 'ABOVE'
            ,p_plug_source_type        => 'NATIVE_DISPLAY_SELECTOR'
            -- attribute keys of the display selector not confirmed by an
            -- export yet: default settings are used
        );
        p_ctx.display_selector := 'Y';

    elsif l_multi and l_layout = 'TABS_CONTAINER' then
        set_step('create tabs region');
        l_region_id := wwv_flow_id.next_val;
        wwv_flow_imp_page.create_page_plug(
             p_id                      => l_region_id
            ,p_flow_id                 => p_ctx.app_id
            ,p_page_id                 => p_ctx.page_id
            ,p_plug_name               => 'Tabs Container'
            ,p_parent_plug_id          => p_ctx.main_region_id
            ,p_region_template_options => '#DEFAULT#'
            ,p_plug_template           => p_ctx.tabs_tpl
            ,p_plug_display_sequence   => 4
            ,p_plug_display_point      => 'SUB_REGIONS'
            ,p_plug_item_display_point => 'ABOVE'
            ,p_attributes              => attrs(apex_t_varchar2(
                                              'expand_shortcuts', 'N',
                                              'output_as',        'HTML'))
        );
        -- the tabs container becomes the parent of the section regions
        p_ctx.section_parent_id := l_region_id;
    end if;

    -- Look of the section regions
    case l_layout
        when 'STANDARD' then
            l_options  := '#DEFAULT#:t-Region--noUI:t-Region--scrollBody:margin-top-md';
            l_position := 'BODY';
        when 'DISPLAY_SELECTOR' then
            l_options  := '#DEFAULT#:t-Region--removeHeader js-removeLandmark:t-Region--noUI:t-Region--scrollBody:margin-top-md';
            l_position := 'BODY';
        else
            l_options  := '#DEFAULT#';
            l_position := 'SUB_REGIONS';
    end case;

    -- One region per section actually used by at least one item
    for r in ( select s.section_name, s.rank * 10 as display_seq
                 from gfm_sections s
                where s.form_id = p_form_id
                  and exists ( select 1
                                 from gfm_items i
                                where i.form_id    = p_form_id
                                  and i.section_id = s.id )
                order by s.rank ) loop

        set_step('create section region ' || r.section_name);
        l_region_id := wwv_flow_id.next_val;
        p_ctx.section_regions(r.section_name) := l_region_id;

        wwv_flow_imp_page.create_page_plug(
             p_id                          => l_region_id
            ,p_flow_id                     => p_ctx.app_id
            ,p_page_id                     => p_ctx.page_id
            ,p_plug_name                   => r.section_name
            ,p_parent_plug_id              => p_ctx.section_parent_id
            ,p_region_template_options     => l_options
            ,p_plug_template               => p_ctx.region_tpl
            ,p_plug_display_sequence       => r.display_seq
            ,p_include_in_reg_disp_sel_yn  => p_ctx.display_selector
            ,p_plug_display_point          => l_position
            ,p_plug_item_display_point     => 'ABOVE'
            ,p_attributes                  => attrs(apex_t_varchar2(
                                                  'expand_shortcuts', 'N',
                                                  'output_as',        'HTML'))
        );
    end loop;
end create_regions;

-- ---------------------------------------------------------------------
-- 3.4 Buttons and branches
-- ---------------------------------------------------------------------

/**
 * Creates a button in the main region.
 * p_condition_type, when given, applies to item P<page>_UPD_ID
 * (not null = existing row, null = new row).
 */
function add_button (
    p_ctx                 in t_ctx,
    p_name                in varchar2,
    p_sequence            in number,
    p_action              in varchar2,
    p_label               in varchar2,
    p_is_hot              in varchar2 default 'N',
    p_condition_type      in varchar2 default null,
    p_database_action     in varchar2 default null,
    p_redirect_url        in varchar2 default null,
    p_execute_validations in varchar2 default 'Y' )
return number
is
    l_id number := wwv_flow_id.next_val;
begin
    set_step('create button ' || p_name);
    wwv_flow_imp_page.create_page_button(
         p_id                         => l_id
        ,p_flow_id                    => p_ctx.app_id
        ,p_flow_step_id               => p_ctx.page_id
        ,p_button_sequence            => p_sequence
        ,p_button_plug_id             => p_ctx.main_region_id
        ,p_button_name                => p_name
        ,p_button_action              => p_action
        ,p_button_template_options    => '#DEFAULT#'
        ,p_button_template_id         => p_ctx.button_tpl
        ,p_button_is_hot              => p_is_hot
        ,p_button_image_alt           => p_label
        ,p_button_position            => 'TOP'
        ,p_button_alignment           => 'RIGHT'
        ,p_button_redirect_url        => p_redirect_url
        ,p_button_execute_validations => p_execute_validations
        ,p_button_condition           => case when p_condition_type is not null
                                              then item_name(p_ctx, 'UPD_ID') end
        ,p_button_condition_type      => p_condition_type
        ,p_database_action            => p_database_action
    );
    return l_id;
end add_button;

procedure create_buttons_and_branches (p_ctx in out nocopy t_ctx)
is
    l_id number;
begin
    -- REDIRECT_URL: the 26.1 export converts the former REDIRECT_PAGE + URL
    l_id := add_button(p_ctx, 'CANCEL', 10, 'REDIRECT_URL', 'Cancel',
                       p_redirect_url => 'javascript:window.close();');

    p_ctx.delete_button_id :=
            add_button(p_ctx, 'DELETE', 20, 'REDIRECT_URL', 'Delete',
                       p_condition_type      => 'ITEM_IS_NOT_NULL',
                       p_database_action     => 'DELETE',
                       p_redirect_url        => 'javascript:apex.confirm(htmldb_delete_message,''DELETE'');',
                       p_execute_validations => 'N');

    l_id := add_button(p_ctx, 'SAVE', 30, 'SUBMIT', 'Apply Changes',
                       p_is_hot          => 'Y',
                       p_condition_type  => 'ITEM_IS_NOT_NULL',
                       p_database_action => 'UPDATE');

    l_id := add_button(p_ctx, 'CREATE', 40, 'SUBMIT', 'Submit',
                       p_is_hot          => 'Y',
                       p_condition_type  => 'ITEM_IS_NULL',
                       p_database_action => 'INSERT');

    set_step('create branches');
    wwv_flow_imp_page.create_page_branch(
         p_id               => wwv_flow_id.next_val
        ,p_flow_id          => p_ctx.app_id
        ,p_flow_step_id     => p_ctx.page_id
        ,p_branch_action    => 'f?p=&APP_ID.:' || nvl(p_ctx.form.report_page_id, c_return_page)
                               || ':&SESSION.::&DEBUG.&success_msg=#SUCCESS_MSG#'
        ,p_branch_point     => 'AFTER_PROCESSING'
        ,p_branch_type      => 'REDIRECT_URL'
        ,p_branch_sequence  => 1
    );

    wwv_flow_imp_page.create_page_branch(
         p_id                    => wwv_flow_id.next_val
        ,p_flow_id               => p_ctx.app_id
        ,p_flow_step_id          => p_ctx.page_id
        ,p_branch_name           => 'AfterDelete'
        ,p_branch_action         => 'f?p=&APP_ID.:' || nvl(p_ctx.form.report_page_id, c_return_page)
                                    || ':&SESSION.::&DEBUG.:::&success_msg=#SUCCESS_MSG#'
        ,p_branch_point          => 'AFTER_PROCESSING'
        ,p_branch_type           => 'REDIRECT_URL'
        ,p_branch_when_button_id => p_ctx.delete_button_id
        ,p_branch_sequence       => 11
    );
end create_buttons_and_branches;

-- ---------------------------------------------------------------------
-- 3.5 Items
-- ---------------------------------------------------------------------

/** Technical items: SEQ_ID (primary key) and UPD_ID (insert/update switch). */
procedure create_key_items (p_ctx in t_ctx)
is
begin
    set_step('create item SEQ_ID');
    wwv_flow_imp_page.create_page_item(
         p_id                       => wwv_flow_id.next_val
        ,p_flow_id                  => p_ctx.app_id
        ,p_flow_step_id             => p_ctx.page_id
        ,p_name                     => item_name(p_ctx, 'SEQ_ID')
        ,p_source_data_type         => 'NUMBER'
        ,p_is_primary_key           => true
        ,p_item_sequence            => 5
        ,p_item_plug_id             => p_ctx.main_region_id
        ,p_item_source_plug_id      => p_ctx.main_region_id
        ,p_use_cache_before_default => 'NO'
        ,p_item_default             => 'GFM_DATA_SEQ.nextval'
        ,p_item_default_type        => 'EXPRESSION'
        ,p_item_default_language    => 'PLSQL'
        ,p_prompt                   => 'Seq Id'
        ,p_source                   => 'SEQ_ID'
        ,p_source_type              => 'REGION_SOURCE_COLUMN'
        ,p_display_as               => 'NATIVE_HIDDEN'
        ,p_label_alignment          => 'RIGHT'
        ,p_field_template           => p_ctx.label_tpl
        ,p_item_template_options    => '#DEFAULT#'
        ,p_is_persistent            => 'N'
        ,p_protection_level         => 'S'
        ,p_attributes               => attrs(apex_t_varchar2('value_protected', 'Y'))
    );

    -- Copy of SEQ_ID set before header: not null = existing row
    set_step('create item UPD_ID');
    wwv_flow_imp_page.create_page_item(
         p_id            => wwv_flow_id.next_val
        ,p_flow_id       => p_ctx.app_id
        ,p_flow_step_id  => p_ctx.page_id
        ,p_name          => item_name(p_ctx, 'UPD_ID')
        ,p_item_sequence => 2
        ,p_item_plug_id  => p_ctx.main_region_id
        ,p_source_type   => 'ALWAYS_NULL'
        ,p_display_as    => 'NATIVE_HIDDEN'
        ,p_attributes    => attrs(apex_t_varchar2('value_protected', 'N'))
    );
end create_key_items;

/** One page item per regular column item (TCOMP = 'C') of the form. */
procedure create_items (p_ctx in t_ctx, p_form_id in number)
is
    l_region_id     number;
    l_label_tpl     number;
    l_tpl_options   varchar2(200);
    l_help          varchar2(4000);
    l_display_null  varchar2(3);
    l_display_as    varchar2(100);
    l_attributes    apex_t_varchar2;
    l_multi_type    varchar2(30);
    l_multi_sep     varchar2(1);
    l_lov           varchar2(4000);
    l_lov_language  varchar2(10);
begin
    for r in ( select i.id,
                      upper(i.code)           as code,
                      c.ctype,
                      c.lib                   as comp_lib,
                      i.lov,                  -- inline list values 'a:b:c'
                      i.lib                   as label,
                      s.section_name,
                      i.vtype,                -- list display type
                      nvl(i.seq, 10)          as seq,
                      i.new_row,
                      i.mandatory,
                      nullif(i.col_span, 0) * 2 as col_span,
                      coalesce(i.icon, c.icon)  as icon,
                      i.description,
                      substr(i.map_col, 1, 1)   as family   -- C, N or D
                 from gfm_items i
                 join gfm_comp  c on c.id = i.comp
                 left join gfm_sections s on s.id = i.section_id
                where i.form_id = p_form_id
                  and i.tcomp   = c_tcomp_column
                order by i.seq ) loop

        set_step('create item ' || r.code);

        -- Common attributes
        l_region_id   := region_for_section(p_ctx, r.section_name);
        l_label_tpl   := label_template(p_ctx, r.mandatory);
        l_help        := case when pref(p_ctx, '$ITEM_HELP') = 'Y' then r.description end;
        l_tpl_options := case
                           when r.ctype = c_ct_number then '#DEFAULT#'
                           when r.mandatory = 'Y'     then '#DEFAULT#:t-Form-fieldContainer--indicatorAsterisk'
                           else                            '#DEFAULT#'
                         end;

        case
        -- -------------------------------- Text field / text area
        when r.ctype in (c_ct_text, c_ct_textarea) then
            wwv_flow_imp_page.create_page_item(
                 p_id                       => wwv_flow_id.next_val
                ,p_flow_id                  => p_ctx.app_id
                ,p_flow_step_id             => p_ctx.page_id
                ,p_name                     => item_name(p_ctx, r.code)
                ,p_source_data_type         => 'VARCHAR2'
                ,p_item_sequence            => r.seq
                ,p_item_plug_id             => l_region_id
                ,p_item_source_plug_id      => p_ctx.main_region_id
                ,p_use_cache_before_default => 'NO'
                ,p_prompt                   => r.label
                ,p_is_required              => to_boolean(case when r.mandatory = 'Y' then 'TRUE' else 'FALSE' end)
                ,p_item_icon_css_classes    => r.icon
                ,p_source                   => r.code
                ,p_source_type              => 'REGION_SOURCE_COLUMN'
                ,p_display_as               => case r.ctype when c_ct_textarea then 'NATIVE_TEXTAREA'
                                                                               else 'NATIVE_TEXT_FIELD' end
                ,p_cSize                    => case r.ctype when c_ct_textarea then 1000 else 60 end
                ,p_cMaxlength               => 100
                ,p_colspan                  => r.col_span
                ,p_cHeight                  => case r.ctype when c_ct_textarea then 3 else 1 end
                ,p_begin_on_new_line        => r.new_row
                ,p_label_alignment          => 'RIGHT'
                ,p_field_template           => l_label_tpl
                ,p_item_template_options    => l_tpl_options
                ,p_is_persistent            => 'N'
                ,p_help_text                => l_help
                -- text area: attribute keys not confirmed by an export yet,
                -- APEX defaults are used
                ,p_attributes               => case r.ctype
                                                 when c_ct_text then attrs(apex_t_varchar2(
                                                     'disabled',                  'N',
                                                     'send_on_page_submit',       'N',
                                                     'submit_when_enter_pressed', 'N',
                                                     'subtype',                   'TEXT',
                                                     'trim_spaces',               'BOTH'))
                                               end
            );

        -- -------------------------------- Number
        when r.ctype = c_ct_number then
            wwv_flow_imp_page.create_page_item(
                 p_id                       => wwv_flow_id.next_val
                ,p_flow_id                  => p_ctx.app_id
                ,p_flow_step_id             => p_ctx.page_id
                ,p_name                     => item_name(p_ctx, r.code)
                -- NUMBER column, or VARCHAR2 for the items stored as text
                ,p_source_data_type         => case r.family when 'N' then 'NUMBER' else 'VARCHAR2' end
                ,p_item_sequence            => r.seq
                ,p_item_plug_id             => l_region_id
                ,p_item_source_plug_id      => p_ctx.main_region_id
                ,p_use_cache_before_default => 'NO'
                ,p_prompt                   => r.label
                ,p_is_required              => to_boolean(case when r.mandatory = 'Y' then 'TRUE' else 'FALSE' end)
                ,p_source                   => r.code
                ,p_item_icon_css_classes    => r.icon
                ,p_source_type              => 'REGION_SOURCE_COLUMN'
                ,p_display_as               => 'NATIVE_NUMBER_FIELD'
                ,p_cSize                    => 30
                ,p_colspan                  => r.col_span
                ,p_begin_on_new_line        => r.new_row
                ,p_label_alignment          => 'RIGHT'
                ,p_field_template           => p_ctx.label_tpl   -- v1.x behaviour: default template
                ,p_item_template_options    => l_tpl_options
                ,p_is_persistent            => 'N'
                ,p_help_text                => l_help
                ,p_attributes               => attrs(apex_t_varchar2(
                                                   'number_alignment', 'right',
                                                   'virtual_keyboard', 'decimal'))
            );

        -- -------------------------------- Date
        -- v1.x: no source type => the item was ALWAYS_NULL and never saved
        -- NATIVE_DATE_PICKER_JET is replaced by NATIVE_DATE_PICKER_APEX
        when r.ctype = c_ct_date then
            wwv_flow_imp_page.create_page_item(
                 p_id                    => wwv_flow_id.next_val
                ,p_flow_id               => p_ctx.app_id
                ,p_flow_step_id          => p_ctx.page_id
                ,p_name                  => item_name(p_ctx, r.code)
                ,p_source_data_type      => case r.family when 'D' then 'DATE' else 'VARCHAR2' end
                ,p_item_sequence         => r.seq
                ,p_item_plug_id          => l_region_id
                ,p_item_source_plug_id   => p_ctx.main_region_id
                ,p_prompt                => r.label
                ,p_is_required           => to_boolean(case when r.mandatory = 'Y' then 'TRUE' else 'FALSE' end)
                ,p_source                => r.code
                ,p_source_type           => 'REGION_SOURCE_COLUMN'
                ,p_display_as            => 'NATIVE_DATE_PICKER_APEX'
                -- text storage: fixed format (report view); DATE storage:
                -- format of the application
                ,p_format_mask           => case when r.family = 'D' then null else date_format end
                ,p_item_icon_css_classes => r.icon
                ,p_cSize                 => 30
                ,p_colspan               => r.col_span
                ,p_begin_on_new_line     => r.new_row
                ,p_field_template        => l_label_tpl
                ,p_item_template_options => l_tpl_options
                ,p_is_persistent         => 'N'
                ,p_help_text             => l_help
                ,p_attributes            => attrs(apex_t_varchar2(
                                                'display_as',      'POPUP',
                                                'max_date',        'NONE',
                                                'min_date',        'NONE',
                                                'multiple_months', 'N',
                                                'show_time',       'N',
                                                'use_defaults',    'Y'))
            );

        -- -------------------------------- Lists
        when r.ctype in (c_ct_list, c_ct_dyn_list) then
            -- display type and its attributes
            l_multi_type := null;
            l_multi_sep  := null;
            case r.vtype
                when 'RADIO' then
                    l_display_as := 'NATIVE_RADIOGROUP';
                    l_attributes := apex_t_varchar2('number_of_columns', '6',
                                                    'page_action_on_selection', 'NONE');
                when 'LIST' then
                    l_display_as := 'NATIVE_SELECT_LIST';
                    l_attributes := apex_t_varchar2('page_action_on_selection', 'NONE');
                when 'CHECKBOX' then
                    l_display_as := 'NATIVE_CHECKBOX';
                    l_attributes := apex_t_varchar2('number_of_columns', '10');
                    l_multi_type := 'SEPARATED';          -- several values 'a:b'
                    l_multi_sep  := ':';
                when 'NATIVE_SINGLE_CHECKBOX' then
                    l_display_as := 'NATIVE_SINGLE_CHECKBOX';
                    l_attributes := apex_t_varchar2('use_defaults', 'Y');
                when 'POPUP' then
                    l_display_as := 'NATIVE_POPUP_LOV';
                    l_attributes := null;                 -- APEX defaults
                else
                    raise_application_error(c_err_metadata,
                        'Type d''affichage "' || r.vtype || '" non géré pour la liste ' || r.code);
            end case;

            -- no null entry for mandatory items, radio groups and checkboxes
            l_display_null := case when r.mandatory = 'N'
                                    and r.vtype not in ('RADIO', 'CHECKBOX')
                                   then 'YES' else 'NO' end;

            -- inline list => static LOV, otherwise SQL built at runtime by get_lov
            if r.comp_lib = c_inline_list then
                -- an empty static LOV ('STATIC:') breaks the generated page
                if replace(trim(r.lov), ':') is null then
                    raise_application_error(c_err_metadata,
                        'La liste inline ' || r.code || ' n''a aucune valeur');
                end if;
                l_lov          := static_lov(r.lov);
                l_lov_language := null;
            else
                l_lov          := 'return gfm_builder.get_lov(' || r.id || ')';
                l_lov_language := 'PLSQL';
            end if;

            wwv_flow_imp_page.create_page_item(
                 p_id                    => wwv_flow_id.next_val
                ,p_flow_id               => p_ctx.app_id
                ,p_flow_step_id          => p_ctx.page_id
                ,p_name                  => item_name(p_ctx, r.code)
                ,p_source_data_type      => 'VARCHAR2'
                ,p_item_sequence         => r.seq
                ,p_item_plug_id          => l_region_id
                ,p_item_source_plug_id   => p_ctx.main_region_id
                ,p_prompt                => r.label
                ,p_source                => r.code
                ,p_is_required           => to_boolean(case when r.mandatory = 'Y' then 'TRUE' else 'FALSE' end)
                ,p_source_type           => 'REGION_SOURCE_COLUMN'
                ,p_display_as            => l_display_as
                ,p_colspan               => r.col_span
                ,p_item_icon_css_classes => r.icon
                ,p_begin_on_new_line     => r.new_row
                ,p_lov_display_null      => l_display_null
                ,p_lov_language          => l_lov_language
                ,p_lov                   => l_lov
                ,p_field_template        => l_label_tpl
                ,p_item_template_options => l_tpl_options
                ,p_is_persistent         => 'N'
                ,p_help_text             => l_help
                ,p_lov_display_extra     => 'NO'
                ,p_attributes            => case when l_attributes is not null
                                                 then attrs(l_attributes) end
                ,p_multi_value_type      => l_multi_type
                ,p_multi_value_separator => l_multi_sep
            );

        else
            apex_debug.warn('gfm_builder: item %s ignored, unknown type %s', r.code, r.ctype);
        end case;
    end loop;
end create_items;

-- ---------------------------------------------------------------------
-- 3.6 Page processes
-- ---------------------------------------------------------------------

/** Attributes of the native Form DML / IG DML processes. */
function dml_attributes
return clob
is
begin
    return attrs(apex_t_varchar2(
               'lock_row',                         'Y',
               'prevent_lost_updates',             'Y',
               'return_primary_keys_after_insert', 'N',
               'target_type',                      'REGION_SOURCE'));
end dml_attributes;

procedure create_processes (p_ctx in t_ctx)
is
    l_id number;
begin
    set_step('create process UPD_ID');
    l_id := wwv_flow_id.next_val;
    wwv_flow_imp_page.create_page_process(
         p_id                     => l_id
        ,p_flow_id                => p_ctx.app_id
        ,p_flow_step_id           => p_ctx.page_id
        ,p_process_sequence       => 5
        ,p_process_point          => 'BEFORE_HEADER'
        ,p_process_type           => 'NATIVE_PLSQL'
        ,p_process_name           => 'New'
        ,p_process_sql_clob       => apex_string.join(apex_t_varchar2(
             'if :' || item_name(p_ctx, 'SEQ_ID') || ' is not null then',
             '    :' || item_name(p_ctx, 'UPD_ID') || ' := :' || item_name(p_ctx, 'SEQ_ID') || ';',
             'end if;'), chr(10))
        ,p_process_clob_language  => 'PLSQL'
        ,p_error_display_location => 'INLINE_IN_NOTIFICATION'
        ,p_internal_uid           => l_id
    );

    set_step('create process form init');
    l_id := wwv_flow_id.next_val;
    wwv_flow_imp_page.create_page_process(
         p_id               => l_id
        ,p_flow_id          => p_ctx.app_id
        ,p_flow_step_id     => p_ctx.page_id
        ,p_process_sequence => 10
        ,p_process_point    => 'BEFORE_HEADER'
        ,p_region_id        => p_ctx.main_region_id
        ,p_process_type     => 'NATIVE_FORM_INIT'
        ,p_process_name     => 'Initialize form fiche' || p_ctx.page_id
        ,p_internal_uid     => l_id
    );

    set_step('create process form DML');
    l_id := wwv_flow_id.next_val;
    wwv_flow_imp_page.create_page_process(
         p_id                     => l_id
        ,p_flow_id                => p_ctx.app_id
        ,p_flow_step_id           => p_ctx.page_id
        ,p_process_sequence       => 10
        ,p_process_point          => 'AFTER_SUBMIT'
        ,p_region_id              => p_ctx.main_region_id
        ,p_process_type           => 'NATIVE_FORM_DML'
        ,p_process_name           => 'Process form fiche' || p_ctx.page_id
        ,p_attributes             => dml_attributes
        ,p_error_display_location => 'INLINE_IN_NOTIFICATION'
        ,p_internal_uid           => l_id
    );
end create_processes;

-- ---------------------------------------------------------------------
-- 3.7 Dynamic actions: dependent items (MASTER_ID / MASTER_VALUE)
-- ---------------------------------------------------------------------

/**
 * Items with a MASTER_ID are hidden on page load and shown when the master
 * item equals MASTER_VALUE (or is not null when MASTER_VALUE is null).
 */
procedure create_dynamic_actions (p_ctx in t_ctx, p_form_id in number)
is
    l_hidden   varchar2(4000);
    l_event_id number;
begin
    select listagg('P' || p_ctx.page_id || '_' || upper(code), ',') within group (order by seq)
      into l_hidden
      from gfm_items
     where form_id = p_form_id
       and master_id is not null;

    if l_hidden is null then
        return;                                   -- no dependent item
    end if;

    set_step('create DA HideItems');
    l_event_id := wwv_flow_id.next_val;
    wwv_flow_imp_page.create_page_da_event(
         p_id              => l_event_id
        ,p_flow_id         => p_ctx.app_id
        ,p_page_id         => p_ctx.page_id
        ,p_name            => 'HideItems'
        ,p_event_sequence  => 10
        ,p_bind_type       => 'bind'
        ,p_execution_type  => 'IMMEDIATE'
        ,p_bind_event_type => 'ready'
    );
    wwv_flow_imp_page.create_page_da_action(
         p_id                     => wwv_flow_id.next_val
        ,p_flow_id                => p_ctx.app_id
        ,p_page_id                => p_ctx.page_id
        ,p_event_id               => l_event_id
        ,p_event_result           => 'TRUE'
        ,p_action_sequence        => 10
        ,p_action                 => 'NATIVE_HIDE'
        ,p_affected_elements_type => 'ITEM'
        ,p_affected_elements      => l_hidden
    );

    for r in ( select upper(a.code) as code,
                      upper(m.code) as master_code,
                      a.master_value
                 from gfm_items a
                 join gfm_items m on m.id = a.master_id
                where a.form_id = p_form_id ) loop

        set_step('create DA ChangeItem ' || r.code);
        l_event_id := wwv_flow_id.next_val;
        wwv_flow_imp_page.create_page_da_event(
             p_id                        => l_event_id
            ,p_flow_id                   => p_ctx.app_id
            ,p_page_id                   => p_ctx.page_id
            ,p_name                      => 'ChangeItem'
            ,p_event_sequence            => 20
            ,p_triggering_element_type   => 'ITEM'
            ,p_triggering_element        => item_name(p_ctx, r.master_code)
            ,p_condition_element         => item_name(p_ctx, r.master_code)
            ,p_triggering_condition_type => case when r.master_value is null
                                                 then 'NOT_NULL' else 'EQUALS' end
            ,p_triggering_expression     => r.master_value
            ,p_bind_type                 => 'bind'
            ,p_execution_type            => 'IMMEDIATE'
            ,p_bind_event_type           => 'change'
        );
        wwv_flow_imp_page.create_page_da_action(
             p_id                     => wwv_flow_id.next_val
            ,p_flow_id                => p_ctx.app_id
            ,p_page_id                => p_ctx.page_id
            ,p_event_id               => l_event_id
            ,p_event_result           => 'TRUE'
            ,p_action_sequence        => 10
            ,p_execute_on_page_init   => 'Y'
            ,p_action                 => 'NATIVE_SHOW'
            ,p_affected_elements_type => 'ITEM'
            ,p_affected_elements      => item_name(p_ctx, r.code)
        );
        wwv_flow_imp_page.create_page_da_action(
             p_id                     => wwv_flow_id.next_val
            ,p_flow_id                => p_ctx.app_id
            ,p_page_id                => p_ctx.page_id
            ,p_event_id               => l_event_id
            ,p_event_result           => 'FALSE'
            ,p_action_sequence        => 10
            ,p_execute_on_page_init   => 'Y'
            ,p_action                 => 'NATIVE_HIDE'
            ,p_affected_elements_type => 'ITEM'
            ,p_affected_elements      => item_name(p_ctx, r.code)
        );
    end loop;
end create_dynamic_actions;

-- ---------------------------------------------------------------------
-- 3.8 Detail forms embedded as interactive grids (TCOMP = 'D')
-- ---------------------------------------------------------------------

procedure create_detail_grids (p_ctx in t_ctx, p_form_id in number)
is
    l_region_id number;
    l_grid_id   number;
    l_report_id  number;
    l_view_id    number;
    l_process_id number;
    l_col_count  pls_integer;
    l_columns   t_id_list;

    procedure add_column (p_id in number) is
    begin
        l_columns.extend;
        l_columns(l_columns.count) := p_id;
    end add_column;
begin
    -- GFM_ITEMS.COMP holds the id of the detail FORM for TCOMP = 'D'
    for r in ( select upper(i.code) as code,
                      i.comp        as detail_form_id,
                      s.section_name,
                      f.code        as detail_code,
                      f.lib         as detail_label
                 from gfm_items i
                 join gfm_form  f on f.id = i.comp
                 left join gfm_sections s on s.id = i.section_id
                where i.form_id = p_form_id
                  and i.tcomp   = c_tcomp_detail ) loop

        l_columns := t_id_list();

        set_step('create IG region ' || r.code);
        l_region_id := wwv_flow_id.next_val;
        wwv_flow_imp_page.create_page_plug(
             p_id                         => l_region_id
            ,p_flow_id                    => p_ctx.app_id
            ,p_page_id                    => p_ctx.page_id
            ,p_plug_name                  => r.detail_label
            ,p_parent_plug_id             => region_for_section(p_ctx, r.section_name)
            ,p_region_template_options    => '#DEFAULT#:t-Region--noUI:t-Region--scrollBody'
            ,p_component_template_options => '#DEFAULT#'
            ,p_plug_template              => p_ctx.region_tpl
            ,p_plug_display_sequence      => 10
            ,p_plug_item_display_point    => 'ABOVE'
            ,p_query_type                 => 'TABLE'
            ,p_query_table                => view_name(r.detail_code)
            ,p_query_where                => 'PARENT_ID = :' || item_name(p_ctx, 'SEQ_ID')
            ,p_include_rowid_column       => false
            ,p_plug_source_type           => 'NATIVE_IG'
            ,p_ajax_items_to_submit       => item_name(p_ctx, 'SEQ_ID')
        );

        -- Row action column
        set_step('create IG columns ' || r.code);
        add_column(wwv_flow_id.next_val);
        wwv_flow_imp_page.create_region_column(
             p_id                      => l_columns(l_columns.count)
            ,p_flow_id                 => p_ctx.app_id
            ,p_page_id                 => p_ctx.page_id
            ,p_region_id               => l_region_id
            ,p_name                    => 'APEX$ROW_ACTION'
            ,p_session_state_data_type => 'VARCHAR2'
            ,p_item_type               => 'NATIVE_ROW_ACTION'
            ,p_display_sequence        => 5
            ,p_include_in_export       => true
        );

        -- Primary key
        add_column(wwv_flow_id.next_val);
        wwv_flow_imp_page.create_region_column(
             p_id                      => l_columns(l_columns.count)
            ,p_flow_id                 => p_ctx.app_id
            ,p_page_id                 => p_ctx.page_id
            ,p_region_id               => l_region_id
            ,p_name                    => 'SEQ_ID'
            ,p_source_type             => 'DB_COLUMN'
            ,p_source_expression       => 'SEQ_ID'
            ,p_data_type               => 'NUMBER'
            ,p_session_state_data_type => 'VARCHAR2'
            ,p_is_query_only           => false
            ,p_item_type               => 'NATIVE_HIDDEN'
            ,p_display_sequence        => 8
            ,p_attributes              => attrs(apex_t_varchar2('value_protected', 'Y'))
            ,p_filter_is_required      => false
            ,p_use_as_row_header       => false
            ,p_enable_sort_group       => true
            ,p_enable_control_break    => true
            ,p_is_primary_key          => true
            ,p_duplicate_value         => true
            ,p_include_in_export       => false
        );

        -- Columns of the detail form
        for s in ( select upper(i.code) as code, i.lib, i.seq,
                          case substr(i.map_col, 1, 1) when 'N' then 'NUMBER'
                                                       when 'D' then 'DATE'
                                                       else 'VARCHAR2' end as data_type
                     from gfm_items i
                    where i.form_id = r.detail_form_id
                      and i.tcomp   = c_tcomp_column
                    order by i.seq ) loop
            add_column(wwv_flow_id.next_val);
            wwv_flow_imp_page.create_region_column(
                 p_id                      => l_columns(l_columns.count)
                ,p_flow_id                 => p_ctx.app_id
                ,p_page_id                 => p_ctx.page_id
                ,p_region_id               => l_region_id
                ,p_name                    => s.code
                ,p_source_type             => 'DB_COLUMN'
                ,p_source_expression       => s.code
                ,p_data_type               => s.data_type
                ,p_session_state_data_type => 'VARCHAR2'
                ,p_is_query_only           => false
                ,p_item_type               => case s.data_type when 'NUMBER' then 'NATIVE_NUMBER_FIELD'
                                                                when 'DATE'   then 'NATIVE_DATE_PICKER_APEX'
                                                                else 'NATIVE_TEXT_FIELD' end
                ,p_heading                 => s.lib
                ,p_heading_alignment       => case s.data_type when 'NUMBER' then 'RIGHT' else 'LEFT' end
                ,p_display_sequence        => s.seq
                ,p_value_alignment         => case s.data_type when 'NUMBER' then 'RIGHT' else 'LEFT' end
                ,p_attributes              => case s.data_type when 'VARCHAR2'
                                                   then attrs(apex_t_varchar2('trim_spaces', 'BOTH')) end
                ,p_is_required             => false
                ,p_max_length              => case s.data_type when 'VARCHAR2' then 100 end
                ,p_enable_filter           => true
                -- text operators for text columns; APEX defaults for numbers and dates
                ,p_filter_operators        => case s.data_type when 'VARCHAR2'
                                                   then 'C:S:CASE_INSENSITIVE:REGEXP' end
                ,p_filter_is_required      => false
                ,p_filter_text_case        => case s.data_type when 'VARCHAR2' then 'MIXED' end
                ,p_filter_lov_type         => 'NONE'
                ,p_use_as_row_header       => false
                ,p_enable_sort_group       => false
                ,p_enable_hide             => true
                ,p_is_primary_key          => false
                ,p_duplicate_value         => true
                ,p_include_in_export       => true
            );
        end loop;

        -- Foreign key to the master row, defaulted from P<page>_SEQ_ID
        add_column(wwv_flow_id.next_val);
        wwv_flow_imp_page.create_region_column(
             p_id                      => l_columns(l_columns.count)
            ,p_flow_id                 => p_ctx.app_id
            ,p_page_id                 => p_ctx.page_id
            ,p_region_id               => l_region_id
            ,p_name                    => 'PARENT_ID'
            ,p_source_type             => 'DB_COLUMN'
            ,p_source_expression       => 'PARENT_ID'
            ,p_data_type               => 'NUMBER'
            ,p_session_state_data_type => 'VARCHAR2'
            ,p_is_query_only           => false
            ,p_item_type               => 'NATIVE_HIDDEN'
            ,p_display_sequence        => 80
            ,p_attributes              => attrs(apex_t_varchar2('value_protected', 'Y'))
            ,p_filter_is_required      => false
            ,p_use_as_row_header       => false
            ,p_enable_sort_group       => true
            ,p_enable_control_break    => true
            ,p_is_primary_key          => false
            ,p_default_type            => 'ITEM'
            ,p_default_expression      => item_name(p_ctx, 'SEQ_ID')
            ,p_duplicate_value         => true
            ,p_include_in_export       => false
        );

        set_step('create interactive grid ' || r.code);
        l_grid_id := wwv_flow_id.next_val;
        wwv_flow_imp_page.create_interactive_grid(
             p_id                        => l_grid_id
            ,p_internal_uid              => l_grid_id
            ,p_flow_id                   => p_ctx.app_id
            ,p_page_id                   => p_ctx.page_id
            ,p_region_id                 => l_region_id
            ,p_is_editable               => true
            ,p_edit_operations           => 'i:u:d'
            ,p_lost_update_check_type    => 'VALUES'
            ,p_add_row_if_empty          => false
            ,p_submit_checked_rows       => false
            ,p_lazy_loading              => false
            ,p_requires_filter           => false
            ,p_select_first_row          => true
            ,p_fixed_row_height          => true
            ,p_pagination_type           => 'SCROLL'
            ,p_show_total_row_count      => false
            ,p_no_data_found_message     => 'No data'
            ,p_show_toolbar              => true
            ,p_toolbar_buttons           => null
            ,p_add_button_label          => 'Add a row'
            ,p_enable_save_public_report => false
            ,p_enable_subscriptions      => true
            ,p_enable_flashback          => false
            ,p_define_chart_view         => false
            ,p_enable_download           => false
            ,p_download_formats          => null
            ,p_enable_mail_download      => true
            ,p_fixed_header              => 'PAGE'
            ,p_show_icon_view            => false
            ,p_show_detail_view          => false
        );

        -- Primary report, its grid view and its columns. Depending on the
        -- context, create_interactive_grid may already have created some of
        -- them (unique constraint IG_RPT_NAME_UK): what exists is reused,
        -- only what is missing is created, as in a 26.1 export.
        set_step('create IG report ' || r.code);
        select max(report_id)
          into l_report_id
          from apex_appl_page_ig_rpts
         where application_id = p_ctx.app_id
           and page_id        = p_ctx.page_id
           and region_id      = l_region_id;

        if l_report_id is null then
            l_report_id := wwv_flow_id.next_val;
            wwv_flow_imp_page.create_ig_report(
                 p_id                     => l_report_id
                ,p_flow_id                => p_ctx.app_id
                ,p_page_id                => p_ctx.page_id
                ,p_interactive_grid_id    => l_grid_id
                ,p_type                   => 'PRIMARY'
                ,p_default_view           => 'GRID'
                ,p_show_row_number        => false
                ,p_settings_area_expanded => true
            );
        end if;

        set_step('create IG report view ' || r.code);
        -- the dictionary may return the display value ('Grid'): any view of
        -- the report is accepted, the grid view first
        select max(view_id) keep (dense_rank first
                   order by case when upper(view_type) like 'GRID%' then 0 else 1 end)
          into l_view_id
          from apex_appl_page_ig_rpt_views
         where application_id = p_ctx.app_id
           and page_id        = p_ctx.page_id
           and report_id      = l_report_id;

        if l_view_id is null then
            l_view_id := wwv_flow_id.next_val;
            begin
                wwv_flow_imp_page.create_ig_report_view(
                     p_id                       => l_view_id
                    ,p_flow_id                  => p_ctx.app_id
                    ,p_page_id                  => p_ctx.page_id
                    ,p_report_id                => l_report_id
                    ,p_view_type                => 'GRID'
                    ,p_stretch_columns          => true
                    ,p_srv_exclude_null_values  => false
                    ,p_srv_only_display_columns => true
                    ,p_edit_mode                => false
                );
            exception
                when others then
                    -- view already created by APEX but not found above
                    if sqlerrm not like '%ORA-00001%' then
                        raise;
                    end if;
                    select max(view_id)
                      into l_view_id
                      from apex_appl_page_ig_rpt_views
                     where application_id = p_ctx.app_id
                       and page_id        = p_ctx.page_id
                       and region_id      = l_region_id;
                    if l_view_id is null then
                        raise_application_error(c_err_metadata,
                            'Vue du rapport de la grille ' || r.code || ' introuvable dans APEX_APPL_PAGE_IG_RPT_VIEWS');
                    end if;
            end;
        end if;

        set_step('create IG report columns ' || r.code);
        for j in 1 .. l_columns.count loop
            select count(*)
              into l_col_count
              from apex_appl_page_ig_rpt_columns
             where application_id = p_ctx.app_id
               and page_id        = p_ctx.page_id
               and view_id        = l_view_id
               and column_id      = l_columns(j);

            if l_col_count = 0 then
                begin
                    wwv_flow_imp_page.create_ig_report_column(
                         p_id          => wwv_flow_id.next_val
                        ,p_view_id     => l_view_id
                        ,p_display_seq => j
                        ,p_column_id   => l_columns(j)
                        ,p_is_visible  => true
                        ,p_is_frozen   => false
                    );
                exception
                    when others then
                        -- column already created by APEX with the view
                        if sqlerrm not like '%ORA-00001%' then
                            raise;
                        end if;
                end;
            end if;
        end loop;

        set_step('create IG process ' || r.code);
        l_process_id := wwv_flow_id.next_val;
        wwv_flow_imp_page.create_page_process(
             p_id                     => l_process_id
            ,p_flow_id                => p_ctx.app_id
            ,p_flow_step_id           => p_ctx.page_id
            ,p_process_sequence       => 20
            ,p_process_point          => 'AFTER_SUBMIT'
            ,p_region_id              => l_region_id
            ,p_process_type           => 'NATIVE_IG_DML'
            ,p_process_name           => r.code || ' Save Data'
            ,p_attributes             => dml_attributes
            ,p_error_display_location => 'INLINE_IN_NOTIFICATION'
            ,p_internal_uid           => l_process_id
        );
    end loop;
end create_detail_grids;

-- ---------------------------------------------------------------------
-- 3.9 Build stamp
-- ---------------------------------------------------------------------

procedure stamp_form (p_ctx in t_ctx, p_form_id in number)
is
    l_last_update date;
begin
    set_step('update build date');
    select last_updated_on
      into l_last_update
      from apex_application_pages
     where application_id = p_ctx.app_id
       and page_id        = p_ctx.page_id;

    update gfm_form
       set last_updated_on = l_last_update
     where id = p_form_id;
end stamp_form;

-- ---------------------------------------------------------------------
-- 3.10 Entry point
-- ---------------------------------------------------------------------

function generate_form(fid number, pid number DEFAULT null)
return number
is
    l_ctx         t_ctx;
    l_nb_sections pls_integer;
begin
    set_step('get application id');
    apex_debug.info('gfm_builder.generate_form form=%s page=%s', fid, pid);

    l_ctx.app_id := to_number(get_param('APP_RUN_ID'));
    if l_ctx.app_id is null then
        raise_application_error(c_err_param,
            'Paramètre APP_RUN_ID (application cible) introuvable dans GFM_SETUP');
    end if;

    if pid is null then
        l_ctx.page_id := gfm_page_seq.nextval;
    else
        l_ctx.page_id := pid;
    end if;

    set_step('load metadata');
    load_form(l_ctx, fid);
    load_prefs(l_ctx, fid);

    set_step('load templates');
    load_templates(l_ctx);

    set_step('prepare items');
    l_nb_sections := sync_legacy_sections(fid);
    ensure_item_sequences(fid);

    create_page(l_ctx);
    create_regions(l_ctx, fid, l_nb_sections);
    create_buttons_and_branches(l_ctx);
    create_key_items(l_ctx);
    create_items(l_ctx, fid);
    create_processes(l_ctx);
    create_dynamic_actions(l_ctx, fid);
    create_detail_grids(l_ctx, fid);
    stamp_form(l_ctx, fid);

    commit;
    apex_debug.info('gfm_builder.generate_form done, page %s', l_ctx.page_id);
    return 0;

exception
    when others then
        rollback;
        log_error('generate_form', sqlerrm, dbms_utility.format_error_backtrace);
        raise_application_error(c_err_generate, substr(g_step || ' - ' || sqlerrm, 1, 2000));
end generate_form;


-- ---------------------------------------------------------------------
-- 3.11 Interactive report page (master forms)
-- ---------------------------------------------------------------------

/** IR column identifier: 1 -> A, 26 -> Z, 27 -> AA ... */
function col_ident (p_n in pls_integer)
return varchar2
is
begin
    if p_n <= 26 then
        return chr(64 + p_n);
    end if;
    return chr(64 + trunc((p_n - 1) / 26)) || chr(65 + mod(p_n - 1, 26));
end col_ident;

/** Heading of a column of the report view. */
function report_label (p_form_id in number, p_column in varchar2)
return varchar2
is
    l_label gfm_items.lib%type;
begin
    case p_column
        when 'SEQ_ID'         then return 'N°';
        when 'GFM$CREATED_ON' then return 'Créé le';
        when 'GFM$CREATED_BY' then return 'Créé par';
        when 'GFM$UPDATED_ON' then return 'Modifié le';
        when 'GFM$UPDATED_BY' then return 'Modifié par';
        else
            select max(lib) into l_label
              from gfm_items
             where form_id = p_form_id
               and upper(code) = p_column;
            return nvl(l_label, initcap(replace(p_column, '_', ' ')));
    end case;
end report_label;

function generate_report(fid number, pid number default null, pforce varchar2 default 'N')
return number
is
    l_ctx       t_ctx;
    l_view      varchar2(128);
    l_form_page number;
    l_ir_tpl    number;
    l_region_id number;
    l_ws_id     number;
    l_exists    pls_integer;
    l_diff      pls_integer;
    l_n         pls_integer := 0;
    l_type      varchar2(10);
    l_label     varchar2(4000);
    l_visible   apex_t_varchar2 := apex_t_varchar2();
    -- expected columns of the report: name, heading, type
    l_exp_names  apex_t_varchar2 := apex_t_varchar2();
    l_exp_labels apex_t_varchar2 := apex_t_varchar2();
    l_exp_types  apex_t_varchar2 := apex_t_varchar2();
    l_expected   apex_t_varchar2 := apex_t_varchar2();   -- name TAB heading TAB type
begin
    set_step('report: application');
    l_ctx.app_id := to_number(get_param('APP_RUN_ID'));
    if l_ctx.app_id is null then
        raise_application_error(c_err_param,
            'Paramètre APP_RUN_ID (application cible) introuvable dans GFM_SETUP');
    end if;

    set_step('report: load metadata');
    load_form(l_ctx, fid);
    load_prefs(l_ctx, fid);
    l_ctx.page_id := nvl(pid, l_ctx.form.report_page_id);
    if l_ctx.page_id is null then
        raise_application_error(c_err_metadata, 'Numéro de page du rapport non défini');
    end if;
    l_view      := report_view_name(l_ctx.form.code);
    l_form_page := l_ctx.form.page_id;

    -- expected columns, from the report view
    for c in ( select column_name, data_type
                 from user_tab_columns
                where table_name = l_view
                order by column_id ) loop
        apex_string.push(l_exp_names,  c.column_name);
        apex_string.push(l_exp_labels, report_label(fid, c.column_name));
        apex_string.push(l_exp_types,  case c.data_type when 'NUMBER' then 'NUMBER'
                                                        when 'DATE'   then 'DATE'
                                                        else 'STRING' end);
        apex_string.push(l_expected, l_exp_names(l_exp_names.count) || chr(9)
                                     || l_exp_labels(l_exp_labels.count) || chr(9)
                                     || l_exp_types(l_exp_types.count));
    end loop;
    if l_exp_names.count = 0 then
        raise_application_error(c_err_metadata, 'Vue ' || l_view || ' introuvable : générez d''abord la vue');
    end if;

    -- Unchanged columns: the page is kept, with the reports saved by the users
    set_step('report: compare columns');
    select count(*) into l_exists
      from apex_application_pages
     where application_id = l_ctx.app_id
       and page_id        = l_ctx.page_id;

    if l_exists > 0 and nvl(upper(pforce), 'N') <> 'Y' then
        select count(*)
          into l_diff
          from ( ( select column_value from table(l_expected)
                   minus
                   select column_alias || chr(9) || report_label || chr(9) || column_type
                     from apex_application_page_ir_col
                    where application_id = l_ctx.app_id
                      and page_id        = l_ctx.page_id )
                 union all
                 ( select column_alias || chr(9) || report_label || chr(9) || column_type
                     from apex_application_page_ir_col
                    where application_id = l_ctx.app_id
                      and page_id        = l_ctx.page_id
                   minus
                   select column_value from table(l_expected) ) );
        if l_diff = 0 then
            apex_debug.info('gfm_builder.generate_report: page %s unchanged', l_ctx.page_id);
            return 1;
        end if;
    end if;

    set_step('report: load templates');
    load_templates(l_ctx);
    begin
        l_ir_tpl := get_template_id(l_ctx.app_id, l_ctx.theme_no, 'Region', 'INTERACTIVE_REPORT');
    exception
        when others then
            l_ir_tpl := l_ctx.region_tpl;
    end;

    set_step('report: remove page');
    wwv_flow_imp_page.remove_page(p_flow_id => l_ctx.app_id, p_page_id => l_ctx.page_id);

    set_step('report: create page');
    wwv_flow_imp_page.create_page(
         p_id                        => l_ctx.page_id
        ,p_flow_id                   => l_ctx.app_id
        ,p_user_interface_id         => l_ctx.ui_id
        ,p_name                      => substr(l_ctx.form.lib || ' - données', 1, 255)
        ,p_alias                     => 'GFM-' || replace(l_ctx.form.code, '_', '-') || '-DATA'
        ,p_step_title                => l_ctx.form.lib
        ,p_step_template             => l_ctx.page_tpl
        ,p_autocomplete_on_off       => 'OFF'
        ,p_page_template_options     => '#DEFAULT#'
        ,p_page_is_public_y_n        => case when l_ctx.form.authent = 'Y' then 'N' else 'Y' end
        ,p_protection_level          => 'C'
        ,p_last_updated_by           => nvl(v('APP_USER'), user)
        ,p_last_upd_yyyymmddhh24miss => to_char(sysdate, 'YYYYMMDDHH24MISS')
    );

    set_step('report: create region');
    l_region_id := wwv_flow_id.next_val;
    wwv_flow_imp_page.create_page_plug(
         p_id                      => l_region_id
        ,p_flow_id                 => l_ctx.app_id
        ,p_page_id                 => l_ctx.page_id
        ,p_plug_name               => l_ctx.form.lib
        ,p_region_template_options => '#DEFAULT#:t-IRR-region--hideHeader js-addHiddenHeadingRoleDesc'
        ,p_plug_template           => l_ir_tpl
        ,p_plug_display_sequence   => 10
        ,p_plug_display_point      => 'BODY'
        ,p_plug_item_display_point => 'ABOVE'
        ,p_query_type              => 'TABLE'
        ,p_query_table             => l_view
        ,p_include_rowid_column    => false
        ,p_plug_source_type        => 'NATIVE_IR'
    );

    set_step('report: create worksheet');
    l_ws_id := wwv_flow_id.next_val;
    wwv_flow_imp_page.create_worksheet(
         p_id                     => l_ws_id
        ,p_flow_id                => l_ctx.app_id
        ,p_page_id                => l_ctx.page_id
        ,p_region_id              => l_region_id
        ,p_max_row_count_message  => 'Le rapport est limité à #MAX_ROW_COUNT# lignes. Ajoutez un filtre.'
        ,p_no_data_found_message  => 'Aucune donnée.'
        ,p_pagination_type        => 'ROWS_X_TO_Y'
        ,p_pagination_display_pos => 'BOTTOM_RIGHT'
        ,p_report_list_mode       => 'TABS'
        ,p_lazy_loading           => false
        ,p_show_detail_link       => 'N'
        ,p_show_notify            => 'Y'
        ,p_download_formats       => 'CSV:HTML:XLSX:PDF'
        ,p_enable_mail_download   => 'Y'
        ,p_internal_uid           => l_ws_id
    );

    -- one column per column of the report view, in the view order
    for i in 1 .. l_exp_names.count loop
        l_n     := i;
        l_type  := l_exp_types(i);
        l_label := l_exp_labels(i);
        set_step('report: column ' || l_exp_names(i));
        wwv_flow_imp_page.create_worksheet_column(
             p_id                   => wwv_flow_id.next_val
            ,p_flow_id              => l_ctx.app_id
            ,p_page_id              => l_ctx.page_id
            ,p_worksheet_id         => l_ws_id
            ,p_db_column_name       => l_exp_names(i)
            ,p_display_order        => l_n * 10
            ,p_column_identifier    => col_ident(l_n)
            ,p_column_label         => l_label
            ,p_column_type          => l_type
            ,p_heading_alignment    => case l_type when 'NUMBER' then 'RIGHT' else 'LEFT' end
            ,p_column_alignment     => case l_type when 'NUMBER' then 'RIGHT' else 'LEFT' end
            -- the record number opens the form page
            ,p_column_link          => case when l_exp_names(i) = 'SEQ_ID' and l_form_page is not null
                                            then 'f?p=&APP_ID.:' || l_form_page || ':&SESSION.::&DEBUG.:'
                                                 || l_form_page || ':P' || l_form_page || '_SEQ_ID:#SEQ_ID#' end
            ,p_column_linktext      => case when l_exp_names(i) = 'SEQ_ID' then '#SEQ_ID#' end
            ,p_use_as_row_header    => 'N'
            ,p_available_clientside => 'N'
        );
        -- audit columns available but hidden in the default report
        if l_exp_names(i) not like 'GFM$%' then
            apex_string.push(l_visible, l_exp_names(i));
        end if;
    end loop;

    set_step('report: default report');
    wwv_flow_imp_page.create_worksheet_rpt(
         p_id               => wwv_flow_id.next_val
        ,p_flow_id          => l_ctx.app_id
        ,p_page_id          => l_ctx.page_id
        ,p_worksheet_id     => l_ws_id
        ,p_application_user => 'APXWS_DEFAULT'
        ,p_report_seq       => 10
        ,p_report_alias     => 'primary'
        ,p_status           => 'PUBLIC'
        ,p_is_default       => 'Y'
        ,p_report_columns   => apex_string.join(l_visible, ':')
    );

    if l_form_page is not null then
        set_step('report: button create');
        wwv_flow_imp_page.create_page_button(
             p_id                      => wwv_flow_id.next_val
            ,p_flow_id                 => l_ctx.app_id
            ,p_flow_step_id            => l_ctx.page_id
            ,p_button_sequence         => 10
            ,p_button_plug_id          => l_region_id
            ,p_button_name             => 'CREATE'
            ,p_button_action           => 'REDIRECT_URL'
            ,p_button_template_options => '#DEFAULT#'
            ,p_button_template_id      => l_ctx.button_tpl
            ,p_button_is_hot           => 'Y'
            ,p_button_image_alt        => 'Nouveau'
            ,p_button_position         => 'RIGHT_OF_IR_SEARCH_BAR'
            ,p_button_redirect_url     => 'f?p=&APP_ID.:' || l_form_page || ':&SESSION.::&DEBUG.:'
                                          || l_form_page || '::'
        );
    end if;

    commit;
    apex_debug.info('gfm_builder.generate_report done, page %s', l_ctx.page_id);
    return 0;

exception
    when others then
        rollback;
        log_error('generate_report', sqlerrm, dbms_utility.format_error_backtrace);
        raise_application_error(c_err_generate, substr(g_step || ' - ' || sqlerrm, 1, 2000));
end generate_report;


-- ---------------------------------------------------------------------
-- 3.12 Removal of the generated objects
-- ---------------------------------------------------------------------

function remove_generated(fid number)
return varchar2
is
    l_form gfm_form%rowtype;
    l_app  number := to_number(get_param('APP_RUN_ID'));
    l_msg  apex_t_varchar2 := apex_t_varchar2();

    procedure remove_page (p_page_id in number, p_table in varchar2) is
        l_regions pls_integer;
        l_pages   pls_integer;
    begin
        if p_page_id is null or l_app is null then
            return;
        end if;
        select count(*) into l_pages
          from apex_application_pages
         where application_id = l_app
           and page_id        = p_page_id;
        if l_pages = 0 then
            return;
        end if;

        -- only a page generated for this form: a region on its view
        select count(*) into l_regions
          from apex_application_page_regions
         where application_id = l_app
           and page_id        = p_page_id
           and upper(table_name) = p_table;

        if l_regions > 0 then
            set_step('remove page ' || p_page_id);
            wwv_flow_imp_page.remove_page(p_flow_id => l_app, p_page_id => p_page_id);
            apex_string.push(l_msg, 'page ' || p_page_id || ' supprimée');
        else
            apex_string.push(l_msg, 'page ' || p_page_id
                                    || ' conservée (elle ne porte pas sur ' || p_table || ')');
        end if;
    end remove_page;

    procedure drop_view (p_view in varchar2) is
    begin
        set_step('drop view ' || p_view);
        execute immediate 'drop view ' || p_view;
        apex_string.push(l_msg, 'vue ' || p_view || ' supprimée');
    exception
        when others then
            if sqlcode <> -942 then        -- view never generated
                raise;
            end if;
    end drop_view;
begin
    set_step('read form');
    select * into l_form from gfm_form where id = fid;

    remove_page(l_form.page_id,        view_name(l_form.code));
    remove_page(l_form.report_page_id, report_view_name(l_form.code));
    commit;

    drop_view(report_view_name(l_form.code));
    drop_view(view_name(l_form.code));

    return apex_string.join(l_msg, ', ');
exception
    when others then
        rollback;
        log_error('remove_generated', sqlerrm, dbms_utility.format_error_backtrace);
        raise_application_error(c_err_generate, substr(g_step || ' - ' || sqlerrm, 1, 2000));
end remove_generated;


-- =====================================================================
-- 4. DDL GENERATION
-- =====================================================================

/**
 * Storage column of an item in GFM_DATA, checked against the table.
 * MAP_COL (C003, N002, D005...) or, for items mapped before MAP_COL existed,
 * C + MAP_ID on 3 digits.
 */
function item_column (p_map_col in varchar2, p_map_id in number)
return varchar2
is
    l_column varchar2(30) := nvl(p_map_col, 'C' || lpad(to_char(p_map_id), 3, '0'));
    l_count  pls_integer;
begin
    select count(*)
      into l_count
      from user_tab_columns
     where table_name  = 'GFM_DATA'
       and column_name = l_column;

    if l_count = 0 then
        raise_application_error(c_err_ddl, 'Colonne ' || l_column || ' absente de GFM_DATA');
    end if;
    return l_column;
end item_column;

/** Family of a storage column: C (VARCHAR2), N (NUMBER) or D (DATE). */
function column_family (p_column in varchar2)
return varchar2
is
begin
    return substr(p_column, 1, 1);
end column_family;

/**
 * First free column of a family (C, N or D) for a form: a column of GFM_DATA
 * of the right type that no item of the form uses. N001 is reserved for the
 * link of the detail forms to their master (PARENT_ID).
 */
function free_column (p_form_id in number, p_family in varchar2)
return varchar2
is
    l_column varchar2(30);
begin
    select min(c.column_name) keep (dense_rank first order by to_number(substr(c.column_name, 2)))
      into l_column
      from user_tab_columns c
     where c.table_name = 'GFM_DATA'
       and regexp_like(c.column_name, '^' || p_family || '[0-9]{3}$')
       and c.data_type = case p_family when 'N' then 'NUMBER'
                                       when 'D' then 'DATE'
                                       else 'VARCHAR2' end
       and c.column_name <> 'N001'
       and not exists ( select 1
                          from gfm_items i
                         where i.form_id = p_form_id
                           and i.map_col = c.column_name );
    return l_column;
end free_column;

/**
 * Report view G$_<CODE>_R: typed and readable columns for the interactive report.
 *   numbers -> NUMBER ('.' or ',' as decimal separator), dates -> DATE (date_format),
 *   lists   -> labels (several values 'a:b' -> 'label a, label b'),
 *   plus the audit columns of GFM_DATA (GFM$CREATED_ON ...).
 * Values that cannot be converted are shown empty.
 */
procedure create_report_view (p_form_id in number, p_form_code in varchar2)
is
    l_view  varchar2(128) := report_view_name(p_form_code);
    l_fmt   varchar2(100) := dbms_assert.enquote_literal(replace(date_format, '''', ''''''));
    l_cols  apex_t_varchar2 := apex_t_varchar2('SEQ_ID');
    l_exprs apex_t_varchar2 := apex_t_varchar2('d.seq_id');
    l_col    varchar2(40);
    l_expr   varchar2(4000);
    l_family varchar2(1);
begin
    for r in ( select upper(i.code) as code, i.map_id, i.map_col, c.id as comp_id, c.ctype,
                      c.lib as comp_lib, c.obj_source
                 from gfm_items i
                 join gfm_comp  c on c.id = i.comp
                where i.form_id = p_form_id
                  and i.tcomp   = c_tcomp_column
                  and i.map_id is not null
                order by i.seq, i.id ) loop
        l_family := column_family(item_column(r.map_col, r.map_id));
        l_col    := 'd.' || item_column(r.map_col, r.map_id);
        l_expr   := case
            -- NUMBER / DATE storage: already typed
            when l_family in ('N', 'D') then
                l_col
            -- older items stored as text: converted
            when r.ctype = c_ct_number then
                q'[to_number(replace(trim(]' || l_col || q'[), ',', '.') default null on conversion error, ]'
                || q'['99999999999999999999D9999999999', 'NLS_NUMERIC_CHARACTERS=''.,''')]'
            when r.ctype = c_ct_date then
                'to_date(trim(' || l_col || ') default null on conversion error, ' || l_fmt || ')'
            when r.ctype = c_ct_list and r.comp_lib = c_inline_list then
                'replace(' || l_col || q'[, ':', ', ')]'
            when r.ctype = c_ct_list then
                q'[nvl((select listagg(l.lib_value, ', ') within group (order by l.seq, l.lib_value)]'
                || ' from gfm_lov l where l.comp_id = ' || to_char(r.comp_id)
                || q'[ and instr(':' || ]' || l_col || q'[ || ':', ':' || l.c_value || ':') > 0), ]'
                || l_col || ')'
            when r.ctype = c_ct_dyn_list then
                q'[nvl((select listagg(to_char(s.d), ', ') within group (order by to_char(s.d))]'
                || ' from ' || dbms_assert.qualified_sql_name(r.obj_source) || ' s'
                || q'[ where instr(':' || ]' || l_col || q'[ || ':', ':' || to_char(s.r) || ':') > 0), ]'
                || l_col || ')'
            else l_col
        end;
        apex_string.push(l_cols,  dbms_assert.simple_sql_name(r.code));
        apex_string.push(l_exprs, l_expr);
    end loop;

    -- audit columns (GFM_DATA_T1)
    apex_string.push(l_cols, 'GFM$CREATED_ON');  apex_string.push(l_exprs, 'd.created_on');
    apex_string.push(l_cols, 'GFM$CREATED_BY');  apex_string.push(l_exprs, 'd.created_by');
    apex_string.push(l_cols, 'GFM$UPDATED_ON');  apex_string.push(l_exprs, 'd.updated_on');
    apex_string.push(l_cols, 'GFM$UPDATED_BY');  apex_string.push(l_exprs, 'd.updated_by');

    execute immediate 'create or replace view ' || l_view
                   || ' (' || apex_string.join(l_cols, ', ') || ')'
                   || ' as select ' || apex_string.join(l_exprs, ', ')
                   || ' from gfm_data d where d.form_id = ' || to_char(p_form_id);
end create_report_view;

procedure generate_ddl (fid number, ptype varchar2 default 'M')
is
    l_form      gfm_form%rowtype;
    l_view      varchar2(128);
    l_family    varchar2(1);
    l_column    varchar2(30);
    l_sql       varchar2(32767);
    -- view definition: <view_cols> as select <data_cols> from gfm_data
    l_view_cols apex_t_varchar2 := apex_t_varchar2('SEQ_ID');
    l_data_cols apex_t_varchar2 := apex_t_varchar2('SEQ_ID');
    -- insert of the INSTEAD OF trigger
    l_ins_cols  apex_t_varchar2 := apex_t_varchar2('COLLECTION_NAME', 'FORM_ID', 'SEQ_ID');
    l_ins_vals  apex_t_varchar2;
begin
    set_step('read form');
    select * into l_form from gfm_form where id = fid;
    l_view := view_name(l_form.code);

    -- Storage column of every item that has none yet: NUMBER column for a
    -- number, DATE column for a date, VARCHAR2 column otherwise, or when the
    -- typed columns are exhausted. A column freed by a deleted item can be
    -- given again: it is emptied first (the old values were not reachable).
    set_step('allocate columns');
    update gfm_items                            -- items mapped before MAP_COL
       set map_col = 'C' || lpad(to_char(map_id), 3, '0')
     where form_id = fid
       and map_col is null
       and map_id is not null;

    for r in ( select i.id, upper(i.code) as code, c.ctype
                 from gfm_items i
                 join gfm_comp  c on c.id = i.comp
                where i.form_id = fid
                  and i.tcomp   = c_tcomp_column
                  and i.map_col is null
                order by i.seq, i.id ) loop
        l_family := case r.ctype when c_ct_number then 'N'
                                 when c_ct_date   then 'D'
                                 else 'C' end;
        l_column := free_column(fid, l_family);
        if l_column is null and l_family <> 'C' then
            l_column := free_column(fid, 'C');
        end if;
        if l_column is null then
            raise_application_error(c_err_ddl,
                'Plus de colonne disponible dans GFM_DATA pour le champ ' || r.code);
        end if;

        execute immediate 'update gfm_data set ' || dbms_assert.simple_sql_name(l_column)
                       || ' = null where form_id = :form_id'
          using fid;

        update gfm_items
           set map_col = l_column,
               map_id  = to_number(substr(l_column, 2))
         where id = r.id;
    end loop;

    -- Column lists
    set_step('build column lists');
    l_ins_vals := apex_t_varchar2(
                      dbms_assert.enquote_literal(replace(l_form.code, '''', '''''')),
                      to_char(fid),
                      ':new.SEQ_ID' );

    for r in ( select upper(code) as code, map_id, map_col
                 from gfm_items
                where form_id = fid
                  and tcomp   = c_tcomp_column
                order by map_id ) loop
        l_column := item_column(r.map_col, r.map_id);
        apex_string.push(l_view_cols, dbms_assert.simple_sql_name(r.code));
        apex_string.push(l_data_cols, l_column);
        apex_string.push(l_ins_cols,  l_column);
        apex_string.push(l_ins_vals,  ':new.' || r.code);
    end loop;

    if ptype = 'D' then                         -- detail form: link to master row
        apex_string.push(l_view_cols, 'PARENT_ID');
        apex_string.push(l_data_cols, 'N001');
        apex_string.push(l_ins_cols,  'N001');
        apex_string.push(l_ins_vals,  ':new.PARENT_ID');
    end if;

    apex_string.push(l_view_cols, 'FORM_ID');
    apex_string.push(l_data_cols, 'FORM_ID');

    -- View
    set_step('create view');
    l_sql := 'create or replace view ' || l_view
          || ' (' || apex_string.join(l_view_cols, ', ') || ')'
          || ' as select ' || apex_string.join(l_data_cols, ', ')
          || ' from gfm_data where form_id = ' || to_char(fid);
    execute immediate l_sql;

    -- Disabled PK: required by the APEX form region on a view
    set_step('add primary key');
    execute immediate 'alter view ' || l_view
                   || ' add constraint ' || l_view || '_PK primary key (SEQ_ID) disable';

    -- INSTEAD OF INSERT trigger (update/delete go straight through the view)
    set_step('create trigger');
    l_sql := 'create or replace trigger ' || l_view || '_TRG' || chr(10)
          || 'instead of insert on ' || l_view || chr(10)
          || 'begin' || chr(10)
          || '    insert into gfm_data (' || apex_string.join(l_ins_cols, ', ') || ')' || chr(10)
          || '    values (' || apex_string.join(l_ins_vals, ', ') || ');' || chr(10)
          || 'end;';
    execute immediate l_sql;

    -- Report view of a master form (interactive report page)
    if nvl(ptype, 'M') = 'M' then
        set_step('create report view');
        create_report_view(fid, l_form.code);
    end if;

    -- APEX UI defaults: labels and help texts
    set_step('UI defaults');
    apex_ui_default_update.synch_table(p_table_name => l_view);
    commit;

    for r in ( select upper(code) as code, lib, description
                 from gfm_items
                where form_id = fid
                  and tcomp   = c_tcomp_column ) loop
        set_step('UI defaults ' || r.code);
        apex_ui_default_update.upd_column(
            p_table_name  => l_view,
            p_column_name => r.code,
            p_label       => r.lib,
            p_help_text   => r.description );
    end loop;
    commit;

exception
    when others then
        rollback;
        log_error('generate_ddl', sqlerrm, dbms_utility.format_error_backtrace);
        raise_application_error(c_err_ddl, substr(l_view || '.' || g_step || ' - ' || sqlerrm, 1, 2000));
end generate_ddl;


-- =====================================================================
-- 5. LISTS OF VALUES
-- =====================================================================

function get_lov (id number) 
return varchar2
as
    l_item_id number := id;
    l_ctype   gfm_comp.ctype%type;
    l_source  gfm_comp.obj_source%type;
begin
    select c.ctype, c.obj_source
      into l_ctype, l_source
      from gfm_comp  c
      join gfm_items i on i.comp = c.id
     where i.id = l_item_id;

    if l_ctype = c_ct_list then                 -- values stored in GFM_LOV
        return 'select lib_value d, c_value r'
            || ' from gfm_lov'
            || ' where comp_id = (select comp from gfm_items where id = ' || to_char(l_item_id) || ')'
            || ' order by seq nulls last, lib_value';
    else                                        -- dynamic list on an object (columns D, R)
        return 'select d, r from ' || dbms_assert.qualified_sql_name(l_source) || ' order by d';
    end if;
end get_lov;

function get_lov (plov varchar2) 
return varchar2
as
begin
    return 'select lib_value d, c_value r'
        || ' from gfm_lov'
        || ' where comp_id in (select id from gfm_comp where lib = '
        ||     dbms_assert.enquote_literal(replace(plov, '''', '''''')) || ')'
        || ' order by seq nulls last, lib_value';
end get_lov;

function get_lov_master (id varchar2) 
return varchar2
as
    l_comp_id varchar2(4000) := id;
begin
    return 'select lib_value d, c_value r'
        || ' from gfm_lov'
        || ' where comp_id = ' || dbms_assert.enquote_literal(replace(l_comp_id, '''', ''''''))
        || ' order by seq nulls last, lib_value';
end get_lov_master;


-- =====================================================================
-- 6. FORM MAINTENANCE
-- =====================================================================

function getNewPageid (fid number)
return number
as
    l_app_id number := fid;           -- parameter is an APPLICATION id
    l_slot   number;
begin
    select min(s.slot)
      into l_slot
      from ( select level + c_page_slot_min - 1 as slot
               from dual
            connect by level <= c_page_slot_max - c_page_slot_min + 1 ) s
     where not exists ( select 1
                          from apex_application_pages p
                         where p.application_id = l_app_id
                           and p.page_id        = s.slot )
       and not exists ( select 1
                          from gfm_form f
                         where s.slot in (f.page_id, f.report_page_id) );
    return l_slot;
end getNewPageid;

function copyForm(fid number, appid number)
return number
is
    l_src    gfm_form%rowtype;
    l_new_id gfm_form.id%type;
    l_page   gfm_form.page_id%type;
    l_suffix varchar2(7) := '_' || to_char(sysdate, 'HH24MISS');
begin
    set_step('copy form');
    select * into l_src from gfm_form where id = fid;
    l_page := getNewPageid(appid);

    insert into gfm_form (
           lib, notes, scope, code, page_id, sections, items,
           is_published, is_form_generated, is_view_generated,
           vtype, authent, map_lastid )
    values (
           -- truncated so that the suffix fits in LIB (200) and CODE (25)
           substr(l_src.lib, 1, 193) || l_suffix, l_src.notes, l_src.scope,
           substr(l_src.code, 1, 18) || l_suffix,
           l_page, l_src.sections, l_src.items,
           l_src.is_published, l_src.is_form_generated, l_src.is_view_generated,
           l_src.vtype, l_src.authent,
           null )                       -- slots are re-allocated by generate_ddl
    returning id into l_new_id;

    set_step('copy sections');
    insert into gfm_sections (form_id, section_name, rank)
    select l_new_id, section_name, rank
      from gfm_sections
     where form_id = fid;

    set_step('copy items');
    insert into gfm_items (
           lib, description, vtype, comp, notes, section, form_id, code,
           new_row, seq, master_id, master_value, mandatory, tcomp, icon,
           map_id, col_span, section_id )
    select i.lib, i.description, i.vtype, i.comp, i.notes,
           null,                        -- legacy SECTION column
           l_new_id, i.code,
           i.new_row, i.seq, i.master_id, i.master_value, i.mandatory, i.tcomp, i.icon,
           null,                        -- MAP_ID
           i.col_span,
           ( select n.id                -- same section in the copy
               from gfm_sections n
               join gfm_sections o on o.section_name = n.section_name
              where n.form_id = l_new_id
                and o.id      = i.section_id )
      from gfm_items i
     where i.form_id = fid;

    -- MASTER_ID still points to items of the source form: remap by code
    set_step('remap master items');
    update gfm_items c
       set c.master_id = ( select n.id
                             from gfm_items n
                             join gfm_items o on o.code = n.code
                            where n.form_id = l_new_id
                              and o.id      = c.master_id
                              and rownum    = 1 )
     where c.form_id = l_new_id
       and c.master_id is not null;

    commit;
    return l_new_id;

exception
    when others then
        rollback;
        log_error('copyForm', sqlerrm, dbms_utility.format_error_backtrace);
        return -1;
end copyForm;

function copyItems(fid number       --origin form
                  ,tid number    -- target form
                  )
return number
is
    l_target_id number := tid;
begin
    set_step('copy items');
    insert into gfm_items (
           lib, description, vtype, comp, notes, section, form_id, code,
           new_row, seq, master_id, master_value, mandatory, tcomp, icon,
           map_id, col_span, section_id )
    select i.lib, i.description, i.vtype, i.comp, i.notes, i.section,
           l_target_id, i.code,
           i.new_row, i.seq, i.master_id, i.master_value, i.mandatory, i.tcomp, i.icon,
           null,                        -- MAP_ID
           i.col_span,
           ( select n.id                -- section of the same name in the target form
               from gfm_sections n
               join gfm_sections o on o.section_name = n.section_name
              where n.form_id = l_target_id
                and o.id      = i.section_id )
      from gfm_items i
     where i.form_id = fid;

    commit;
    return 0;

exception
    when others then
        rollback;
        log_error('copyItems', sqlerrm, dbms_utility.format_error_backtrace);
        return -1;
end copyItems;

function reseq (pid number, plist varchar2)
return number
is
    l_form_id number          := pid;   -- parameter is a FORM id
    l_ids     apex_t_varchar2 := apex_string.split(plist, ':');
begin
    set_step('reseq');
    for i in 1 .. l_ids.count loop
        update gfm_items
           set seq = 10 * i
         where form_id = l_form_id
           and id      = to_number(l_ids(i));
    end loop;

    commit;
    return 0;

exception
    when others then
        rollback;
        log_error('reseq', sqlerrm, dbms_utility.format_error_backtrace);
        return 1;
end reseq;

function init_prefs(fid number)    -- form id
return number
is
    l_form_id number := fid;
begin
    set_step('init prefs');
    merge into gfm_form_prefs p
    using ( select c.lib as pref,
                   ( select l.c_value
                       from gfm_lov l
                      where l.comp_id    = c.id
                        and l.is_default = 'Y' ) as val
              from gfm_comp c
             where c.lib like '$%'
               and c.internal = 'Y'
               and c.lib <> '$PREFERENCES' ) s
       on ( p.form_id = l_form_id and p.pref = s.pref )
     when not matched then
        insert (form_id, pref, val)
        values (l_form_id, s.pref, s.val);

    commit;
    return 0;
end init_prefs;

function reset_form(fid number)    -- form id
return number
is
    l_form_id number := fid;
begin
    set_step('reset form');
    delete gfm_data where form_id = l_form_id;         -- form data

    update gfm_form                                    -- last allocated slot
       set map_lastid = null
     where id = l_form_id;

    update gfm_items                                   -- release all the columns
       set map_id  = null,
           map_col = null
     where form_id = l_form_id;

    commit;
    return 0;

exception
    when others then
        rollback;
        log_error('reset_form', sqlerrm, dbms_utility.format_error_backtrace);
        return 1;
end reset_form;

end gfm_builder;
/
