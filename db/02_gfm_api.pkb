create or replace package body gfm_api
/**
 * GFM Designer - REST API layer, package body. See the specification.
 *
 * Structure
 *   1. HTTP output and error handling
 *   2. JSON input helpers
 *   3. Metadata helpers (setup, codes, ownership checks)
 *   4. JSON documents (form, list, components)
 *   5. Public operations
 *
 * Source file encoded in UTF-8 (accented characters in to_code):
 * install it with SQLcl / SQL Developer using a UTF-8 client.
 */
as

-- =====================================================================
-- 1. HTTP OUTPUT AND ERROR HANDLING
-- =====================================================================

c_err_business constant pls_integer := -20400;   -- business rule, HTTP 422
c_err_notfound constant pls_integer := -20404;   -- HTTP 404
c_err_conflict constant pls_integer := -20409;   -- HTTP 409

c_inline_list  constant varchar2(30) := 'Inline List';   -- GFM_COMP.LIB of inline lists

/** Writes the HTTP status, the JSON content type and the body. */
procedure emit (p_json in clob, p_status in pls_integer default 200)
is
    c_chunk constant pls_integer := 8000;          -- characters (< 32767 bytes)
    l_len   pls_integer := nvl(dbms_lob.getlength(p_json), 0);
    l_off   pls_integer := 1;
begin
    owa_util.status_line(nstatus => p_status, creason => null, bclose_header => false);
    owa_util.mime_header(ccontent_type => 'application/json', bclose_header => false,
                         ccharset => 'UTF-8');
    owa_util.http_header_close;
    while l_off <= l_len loop
        htp.prn(dbms_lob.substr(p_json, c_chunk, l_off));
        l_off := l_off + c_chunk;
    end loop;
end emit;

procedure emit_error (p_status in pls_integer, p_message in varchar2)
is
    l_json varchar2(4000);
begin
    select json_object('error' value p_message) into l_json from dual;
    emit(l_json, p_status);
end emit_error;

/**
 * Translates the current exception into an HTTP error.
 * Must be called from an exception handler, after the rollback.
 */
procedure handle_error (
    p_code      in pls_integer,
    p_message   in varchar2,
    p_backtrace in varchar2 )
is
    l_status  pls_integer;
    l_message varchar2(4000) := p_message;
begin
    l_status := case
                  when p_code in (100, -1403, c_err_notfound) then 404
                  when p_code in (-1, -2292, c_err_conflict)  then 409
                  when p_code between -20999 and -20000      then 422
                  else 500
                end;

    -- user messages: drop the leading "ORA-2xxxx: "
    if p_code between -20999 and -20000 then
        l_message := regexp_replace(l_message, '^ORA-2\d{4}: ', '');
    elsif p_code in (100, -1403) then
        l_message := 'Ressource introuvable';
    elsif p_code = -1 then
        l_message := 'Valeur déjà utilisée (doublon) : ' || l_message;
    end if;

    apex_debug.error('gfm_api: %s %s', p_message, p_backtrace);
    emit_error(l_status, substr(l_message, 1, 2000));
end handle_error;

procedure fail (p_code in pls_integer, p_message in varchar2)
is
begin
    raise_application_error(p_code, p_message);
end fail;


-- =====================================================================
-- 2. JSON INPUT HELPERS
-- =====================================================================

function parse (p_body in clob)
return json_object_t
is
begin
    if p_body is null or dbms_lob.getlength(p_body) = 0 then
        return json_object_t();
    end if;
    return json_object_t.parse(p_body);
exception
    when others then
        fail(c_err_business, 'Corps de requête JSON invalide');
end parse;

/** String value of a key; p_default when the key is absent. */
function j_str (o in json_object_t, k in varchar2, p_default in varchar2 default null)
return varchar2
is
    l_el json_element_t;
begin
    if not o.has(k) then
        return p_default;
    end if;
    l_el := o.get(k);
    if l_el.is_null then
        return null;
    elsif l_el.is_string then
        return o.get_string(k);
    elsif l_el.is_boolean then
        return case when l_el.is_true then 'Y' else 'N' end;
    else
        return l_el.to_string;
    end if;
end j_str;

function j_num (o in json_object_t, k in varchar2, p_default in number default null)
return number
is
    l_el json_element_t;
begin
    if not o.has(k) then
        return p_default;
    end if;
    l_el := o.get(k);
    if l_el.is_null then
        return null;
    elsif l_el.is_number then
        return o.get_number(k);
    else
        return to_number(o.get_string(k));
    end if;
exception
    when value_error or invalid_number then
        fail(c_err_business, 'Valeur numérique attendue pour "' || k || '"');
end j_num;

/** 'Y' / 'N' flag (accepts true/false, "Y"/"N"). */
function j_yn (o in json_object_t, k in varchar2, p_default in varchar2 default null)
return varchar2
is
    l_val varchar2(10) := upper(j_str(o, k, p_default));
begin
    return case
             when l_val in ('Y', 'TRUE', '1')  then 'Y'
             when l_val in ('N', 'FALSE', '0') then 'N'
             when l_val is null                then null
             else 'N'
           end;
end j_yn;


-- =====================================================================
-- 3. METADATA HELPERS
-- =====================================================================

function setup_value (p_name in varchar2)
return varchar2
is
    l_value gfm_setup_v.valeur%type;
begin
    select valeur into l_value from gfm_setup_v where parameter = p_name;
    return l_value;
exception
    when no_data_found then
        return null;
end setup_value;

function app_id
return number
is
begin
    return to_number(setup_value('APP_RUN_ID'));
end app_id;

/**
 * Sets the APEX workspace (security group) required by the internal APEX
 * APIs used by gfm_builder, as ORDS calls run outside any APEX session.
 * Workspace: GFM_SETUP parameter WORKSPACE, otherwise the workspace of APP_RUN_ID.
 */
procedure set_apex_workspace
is
    l_workspace varchar2(255) := setup_value('WORKSPACE');
    l_app       number        := app_id;
begin
    if l_workspace is null then
        begin
            select workspace
              into l_workspace
              from apex_applications
             where application_id = l_app;
        exception
            when no_data_found then
                fail(c_err_business,
                     'Espace de travail APEX introuvable : renseigner le paramètre WORKSPACE dans GFM_SETUP');
        end;
    end if;
    apex_util.set_workspace(p_workspace => l_workspace);
end set_apex_workspace;

/** Raises 404 when the form does not exist. */
procedure check_form (p_form_id in number)
is
    l_count pls_integer;
begin
    select count(*) into l_count from gfm_form where id = p_form_id;
    if l_count = 0 then
        fail(c_err_notfound, 'Formulaire ' || p_form_id || ' introuvable');
    end if;
end check_form;

/**
 * Turns a label into a valid code: upper case, no accents, [A-Z0-9_],
 * starting with a letter, at most p_max characters.
 */
function to_code (p_text in varchar2, p_max in pls_integer, p_default in varchar2)
return varchar2
is
    l_code varchar2(4000);
begin
    l_code := translate(p_text,
                  'àâäáãåçéèêëíìîïñóòôöõúùûüýÿÀÂÄÁÃÅÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜÝœŒæÆ',
                  'aaaaaaceeeeiiiinooooouuuuyyAAAAAACEEEEIIIINOOOOOUUUUYoOaA');
    l_code := upper(l_code);
    l_code := regexp_replace(l_code, '[^A-Z0-9_]+', '_');
    l_code := trim(both '_' from l_code);
    if l_code is null then
        l_code := p_default;
    elsif regexp_like(l_code, '^[0-9]') then
        l_code := 'C_' || l_code;
    end if;
    return substr(l_code, 1, p_max);
end to_code;

/** Item code unique within the form (p_exclude_id: item being renamed). */
function item_code (
    p_form_id    in number,
    p_text       in varchar2,
    p_exclude_id in number default null )
return varchar2
is
    c_max  constant pls_integer := 26;
    l_base varchar2(30) := to_code(p_text, c_max, 'CHAMP');
    l_code varchar2(30);
    l_n    pls_integer := 1;
    l_used pls_integer;
begin
    -- names used by the support view and the generated page
    if l_base in ('SEQ_ID', 'FORM_ID', 'PARENT_ID', 'UPD_ID') then
        l_base := l_base || '_X';
    end if;

    l_code := l_base;
    loop
        select count(*)
          into l_used
          from gfm_items
         where form_id = p_form_id
           and upper(code) = l_code
           and id <> nvl(p_exclude_id, -1);
        exit when l_used = 0;
        l_n    := l_n + 1;
        l_code := substr(l_base, 1, c_max) || '_' || l_n;
    end loop;
    return l_code;
end item_code;

/** Form code unique among forms (GFM_FORM.CODE, 25 characters). */
function form_code (p_text in varchar2)
return varchar2
is
    c_max  constant pls_integer := 22;
    l_base varchar2(30) := to_code(p_text, c_max, 'FORM');
    l_code varchar2(30) := l_base;
    l_n    pls_integer := 1;
    l_used pls_integer;
begin
    loop
        select count(*) into l_used from gfm_form where code = l_code;
        exit when l_used = 0;
        l_n    := l_n + 1;
        l_code := l_base || '_' || l_n;
    end loop;
    return l_code;
end form_code;

/** Section name, after checking that the section belongs to the form. */
function section_name (p_form_id in number, p_section_id in number)
return varchar2
is
    l_name gfm_sections.section_name%type;
begin
    if p_section_id is null then
        return null;
    end if;
    select section_name
      into l_name
      from gfm_sections
     where id = p_section_id
       and form_id = p_form_id;
    return l_name;
exception
    when no_data_found then
        fail(c_err_business, 'Section ' || p_section_id || ' inconnue pour ce formulaire');
end section_name;


-- =====================================================================
-- 4. JSON DOCUMENTS
-- =====================================================================

/** Full form document. */
function form_json (p_id in number)
return clob
is
    l_json clob;
    l_app  number := app_id;
begin
    select json_object(
             'id'              value f.id,
             'lib'             value f.lib,
             'code'            value f.code,
             'notes'           value f.notes,
             'vtype'           value nvl(f.vtype, 'M'),
             'authent'         value nvl(f.authent, 'Y'),
             'pageId'          value f.page_id,
             'appId'           value l_app,
             'lastBuild'       value to_char(f.last_updated_on, 'YYYY-MM-DD"T"HH24:MI:SS'),
             'isViewGenerated' value nvl(f.is_view_generated, 'N'),
             'isFormGenerated' value nvl(f.is_form_generated, 'N'),
             'dataCount'       value ( select count(*) from gfm_data d where d.form_id = f.id ),
             'sections'        value nvl((
                 select json_arrayagg(
                          json_object(
                            'id'   value s.id,
                            'name' value s.section_name,
                            'rank' value s.rank )
                          order by s.rank, s.id returning clob)
                   from gfm_sections s
                  where s.form_id = f.id ), to_clob('[]')) format json,
             'items'           value nvl((
                 select json_arrayagg(
                          json_object(
                            'id'          value i.id,
                            'lib'         value i.lib,
                            'code'        value i.code,
                            'description' value i.description,
                            'tcomp'       value nvl(i.tcomp, 'C'),
                            'compId'      value i.comp,
                            'compLib'     value case when i.tcomp = 'D' then df.lib else c.lib end,
                            'ctype'       value case when i.tcomp = 'D' then 'SF' else c.ctype end,
                            'isInline'    value case when c.lib = 'Inline List' then 'Y' else 'N' end,
                            'vtype'       value i.vtype,
                            'lov'         value i.lov,
                            'sectionId'   value i.section_id,
                            'seq'         value i.seq,
                            'newRow'      value nvl(i.new_row, 'Y'),
                            'mandatory'   value nvl(i.mandatory, 'N'),
                            'colSpan'     value i.col_span,
                            'icon'        value i.icon,
                            'compIcon'    value c.icon,
                            'masterId'    value i.master_id,
                            'masterValue' value i.master_value,
                            'mapId'       value i.map_id
                            returning clob )
                          order by i.seq, i.id returning clob)
                   from gfm_items i
                   left join gfm_comp c  on c.id  = i.comp and nvl(i.tcomp, 'C') = 'C'
                   left join gfm_form df on df.id = i.comp and i.tcomp = 'D'
                  where i.form_id = f.id ), to_clob('[]')) format json,
             'prefs'           value nvl((
                 select json_arrayagg(
                          json_object(
                            'pref'    value c.lib,
                            'notes'   value c.notes,
                            'val'     value p.val,
                            'options' value nvl((
                                select json_arrayagg(
                                         json_object('d' value l.lib_value, 'r' value l.c_value)
                                         order by l.seq nulls last, l.lib_value returning clob)
                                  from gfm_lov l
                                 where l.comp_id = c.id ), to_clob('[]')) format json
                            returning clob )
                          order by c.lib returning clob)
                   from gfm_comp c
                   left join gfm_form_prefs p on p.form_id = f.id and p.pref = c.lib
                  where c.lib like '$%'
                    and c.internal = 'Y'
                    and c.lib <> '$PREFERENCES' ), to_clob('[]')) format json
             returning clob )
      into l_json
      from gfm_form f
     where f.id = p_id;
    return l_json;
exception
    when no_data_found then
        fail(c_err_notfound, 'Formulaire ' || p_id || ' introuvable');
end form_json;

/** {"id": n, "form": {...}} returned by the creations. */
function created_json (p_new_id in number, p_form_id in number)
return clob
is
    l_json clob;
    l_form clob := form_json(p_form_id);
begin
    select json_object('id' value p_new_id, 'form' value l_form format json returning clob)
      into l_json
      from dual;
    return l_json;
end created_json;


-- =====================================================================
-- 5. PUBLIC OPERATIONS
-- =====================================================================

procedure get_info (p_user in varchar2)
is
    l_app  number := app_id;
    l_json varchar2(4000);
begin
    select json_object(
             'user'    value p_user,
             'appId'   value l_app,
             'version' value '1.0' )
      into l_json
      from dual;
    emit(l_json);
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end get_info;

procedure list_forms
is
    l_json clob;
begin
    select json_arrayagg(
             json_object(
               'id'           value f.id,
               'lib'          value f.lib,
               'code'         value f.code,
               'notes'        value f.notes,
               'vtype'        value nvl(f.vtype, 'M'),
               'authent'      value nvl(f.authent, 'Y'),
               'pageId'       value f.page_id,
               'lastBuild'    value to_char(f.last_updated_on, 'YYYY-MM-DD"T"HH24:MI:SS'),
               'itemCount'    value ( select count(*) from gfm_items i    where i.form_id = f.id ),
               'sectionCount' value ( select count(*) from gfm_sections s where s.form_id = f.id ),
               'dataCount'    value ( select count(*) from gfm_data d     where d.form_id = f.id )
               returning clob )
             order by upper(f.lib) returning clob )
      into l_json
      from gfm_form f;
    emit(nvl(l_json, to_clob('[]')));
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end list_forms;

procedure get_form (p_id in number)
is
begin
    emit(form_json(p_id));
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end get_form;

procedure create_form (p_body in clob)
is
    o       json_object_t := parse(p_body);
    l_lib   gfm_form.lib%type := trim(j_str(o, 'lib'));
    l_vtype gfm_form.vtype%type := nvl(upper(j_str(o, 'vtype')), 'M');
    l_notes   gfm_form.notes%type;
    l_code    gfm_form.code%type;
    l_authent gfm_form.authent%type;
    l_page    gfm_form.page_id%type;
    l_id      gfm_form.id%type;
    l_rc      number;
begin
    if l_lib is null then
        fail(c_err_business, 'Le libellé du formulaire est obligatoire');
    end if;
    if l_vtype not in ('M', 'D') then
        fail(c_err_business, 'Type de formulaire attendu : M (maître) ou D (détail)');
    end if;

    -- private functions cannot be called from SQL: values computed first
    l_notes   := j_str(o, 'notes');
    l_code    := form_code(l_lib);
    l_authent := nvl(j_yn(o, 'authent'), 'Y');
    l_page    := gfm_builder.getNewPageid(app_id);

    insert into gfm_form (lib, notes, code, vtype, authent, page_id)
    values (l_lib, l_notes, l_code, l_vtype, l_authent, l_page)
    returning id into l_id;

    l_rc := gfm_builder.init_prefs(l_id);      -- commits
    commit;
    emit(created_json(l_id, l_id), 201);
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end create_form;

procedure update_form (p_id in number, p_body in clob)
is
    o     json_object_t := parse(p_body);
    l_row gfm_form%rowtype;
begin
    select * into l_row from gfm_form where id = p_id for update;

    l_row.lib     := nvl(trim(j_str(o, 'lib', l_row.lib)), l_row.lib);
    l_row.notes   := j_str(o, 'notes', l_row.notes);
    l_row.vtype   := nvl(upper(j_str(o, 'vtype', l_row.vtype)), 'M');
    l_row.authent := nvl(j_yn(o, 'authent', l_row.authent), 'Y');

    if l_row.vtype not in ('M', 'D') then
        fail(c_err_business, 'Type de formulaire attendu : M (maître) ou D (détail)');
    end if;

    update gfm_form
       set lib     = l_row.lib,
           notes   = l_row.notes,
           vtype   = l_row.vtype,
           authent = l_row.authent
     where id = p_id;

    commit;
    emit(form_json(p_id));
exception
    when no_data_found then
        rollback;
        emit_error(404, 'Formulaire ' || p_id || ' introuvable');
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end update_form;

procedure delete_form (p_id in number, p_force in varchar2 default 'N')
is
    l_data  pls_integer;
    l_used  pls_integer;
begin
    check_form(p_id);

    -- used as an embedded grid by another form?
    select count(*)
      into l_used
      from gfm_items
     where tcomp = 'D'
       and comp  = p_id
       and form_id <> p_id;
    if l_used > 0 then
        fail(c_err_conflict, 'Ce formulaire est utilisé comme sous-formulaire par '
                             || l_used || ' champ(s) : supprimez-les d''abord');
    end if;

    select count(*) into l_data from gfm_data where form_id = p_id;
    if l_data > 0 and nvl(upper(p_force), 'N') <> 'Y' then
        fail(c_err_conflict, 'Le formulaire contient ' || l_data
                             || ' enregistrement(s) : confirmez pour les supprimer aussi');
    end if;

    delete gfm_data where form_id = p_id;
    delete gfm_form where id = p_id;       -- cascade: sections, items, prefs
    commit;
    emit('{"deleted":' || p_id || '}');
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end delete_form;

procedure copy_form (p_id in number)
is
    l_new_id number;
begin
    check_form(p_id);
    l_new_id := gfm_builder.copyForm(p_id, app_id);     -- commits
    if l_new_id < 0 then
        fail(c_err_business, 'La copie a échoué (détail dans le debug APEX)');
    end if;

    insert into gfm_form_prefs (form_id, pref, val)
    select l_new_id, pref, val
      from gfm_form_prefs
     where form_id = p_id;

    commit;
    emit(created_json(l_new_id, l_new_id), 201);
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end copy_form;

procedure generate_form (p_id in number)
is
    l_form    gfm_form%rowtype;
    l_page    number;
    l_rc      number;
    l_message varchar2(400);
    l_app     number := app_id;
    l_form_js clob;
    l_json    clob;
    l_empty   varchar2(4000);
begin
    select * into l_form from gfm_form where id = p_id;

    -- inline lists without values would produce a broken page
    select listagg('« ' || i.lib || ' »', ', ') within group (order by i.seq)
      into l_empty
      from gfm_items i
      join gfm_comp  c on c.id = i.comp
     where i.form_id = p_id
       and nvl(i.tcomp, 'C') = 'C'
       and c.lib = c_inline_list
       and replace(trim(i.lov), ':') is null;
    if l_empty is not null then
        fail(c_err_business, 'Listes sans valeur : ' || l_empty
                             || '. Ajoutez au moins une valeur à chacune avant de générer.');
    end if;

    set_apex_workspace;

    -- 1. support view (commits: DDL)
    gfm_builder.generate_ddl(p_id, nvl(l_form.vtype, 'M'));
    update gfm_form set is_view_generated = 'Y' where id = p_id;
    commit;

    -- 2. APEX page, master forms only (a detail form is displayed as a
    --    grid inside the pages of its master forms)
    if nvl(l_form.vtype, 'M') = 'M' then
        l_page := l_form.page_id;
        if l_page is null then
            l_page := gfm_builder.getNewPageid(l_app);
            update gfm_form set page_id = l_page where id = p_id;
            commit;
        end if;

        l_rc := gfm_builder.generate_form(p_id, l_page);   -- commits
        update gfm_form set is_form_generated = 'Y' where id = p_id;
        commit;
        l_message := 'Page ' || l_page || ' générée dans l''application ' || l_app;
    else
        l_message := 'Vue générée. Régénérez les formulaires maîtres qui utilisent ce sous-formulaire';
    end if;

    l_form_js := form_json(p_id);
    select json_object(
             'appId'   value l_app,
             'pageId'  value l_page,
             'message' value l_message,
             'form'    value l_form_js format json
             returning clob )
      into l_json
      from dual;
    emit(l_json);
exception
    when no_data_found then
        rollback;
        emit_error(404, 'Formulaire ' || p_id || ' introuvable');
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end generate_form;

procedure reset_form (p_id in number)
is
    l_rc number;
begin
    check_form(p_id);
    l_rc := gfm_builder.reset_form(p_id);                -- commits
    if l_rc <> 0 then
        fail(c_err_business, 'La réinitialisation a échoué (détail dans le debug APEX)');
    end if;
    update gfm_form set is_view_generated = 'N' where id = p_id;
    commit;
    emit(form_json(p_id));
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end reset_form;

procedure save_layout (p_id in number, p_body in clob)
is
    o          json_object_t := parse(p_body);
    l_sections json_array_t;
    l_items    json_array_t;
    l_section  json_object_t;
    l_sec_id   number;
    l_sec_name gfm_sections.section_name%type;
    l_seq      pls_integer := 0;

    procedure place_items (p_items in json_array_t, p_section_id in number, p_name in varchar2) is
        l_item_id number;
    begin
        if p_items is null then
            return;
        end if;
        for i in 0 .. p_items.get_size - 1 loop
            l_item_id := p_items.get_number(i);
            l_seq     := l_seq + 10;
            update gfm_items
               set section_id = p_section_id,
                   section    = p_name,
                   seq        = l_seq
             where id      = l_item_id
               and form_id = p_id;
            if sql%rowcount = 0 then
                fail(c_err_business, 'Champ ' || l_item_id || ' inconnu pour ce formulaire');
            end if;
        end loop;
    end place_items;
begin
    check_form(p_id);

    -- unsectioned items first: they are displayed above the sections
    if o.has('unsectioned') then
        place_items(o.get_array('unsectioned'), null, null);
    end if;

    if o.has('sections') then
        l_sections := o.get_array('sections');
        for s in 0 .. l_sections.get_size - 1 loop
            l_section  := treat(l_sections.get(s) as json_object_t);
            l_sec_id   := l_section.get_number('id');
            l_sec_name := section_name(p_id, l_sec_id);

            update gfm_sections set rank = s + 1 where id = l_sec_id;

            if l_section.has('items') then
                l_items := l_section.get_array('items');
            else
                l_items := null;
            end if;
            place_items(l_items, l_sec_id, l_sec_name);
        end loop;
    end if;

    commit;
    emit(form_json(p_id));
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end save_layout;

procedure save_prefs (p_id in number, p_body in clob)
is
    o       json_object_t := parse(p_body);
    l_prefs json_object_t;
    l_keys  json_key_list;
    l_pref  varchar2(100);
    l_val   varchar2(100);
    l_known pls_integer;
begin
    check_form(p_id);
    if not o.has('prefs') then
        fail(c_err_business, 'Attribut "prefs" attendu');
    end if;

    l_prefs := o.get_object('prefs');
    l_keys  := l_prefs.get_keys;
    for i in 1 .. l_keys.count loop
        l_pref := l_keys(i);
        select count(*)
          into l_known
          from gfm_comp
         where lib = l_pref
           and internal = 'Y'
           and lib like '$%';
        if l_known = 0 then
            fail(c_err_business, 'Préférence inconnue : ' || l_pref);
        end if;

        l_val := j_str(l_prefs, l_pref);
        if l_val is null then
            delete gfm_form_prefs where form_id = p_id and pref = l_pref;
        else
            merge into gfm_form_prefs p
            using ( select p_id as form_id, l_pref as pref, l_val as val from dual ) s
               on ( p.form_id = s.form_id and p.pref = s.pref )
             when matched then update set p.val = s.val
             when not matched then insert (form_id, pref, val) values (s.form_id, s.pref, s.val);
        end if;
    end loop;

    commit;
    emit(form_json(p_id));
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end save_prefs;

procedure create_section (p_form_id in number, p_body in clob)
is
    o      json_object_t := parse(p_body);
    l_name gfm_sections.section_name%type := nvl(trim(j_str(o, 'name')), 'Nouvelle section');
    l_rank number := j_num(o, 'rank');
    l_id   number;
begin
    check_form(p_form_id);

    if l_rank is null then
        select nvl(max(rank), 0) + 1 into l_rank from gfm_sections where form_id = p_form_id;
    else
        update gfm_sections
           set rank = rank + 1
         where form_id = p_form_id
           and rank >= l_rank;
    end if;

    insert into gfm_sections (form_id, section_name, rank)
    values (p_form_id, l_name, l_rank)
    returning id into l_id;

    commit;
    emit(created_json(l_id, p_form_id), 201);
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end create_section;

procedure update_section (p_id in number, p_body in clob)
is
    o         json_object_t := parse(p_body);
    l_form_id number;
    l_name    gfm_sections.section_name%type;
begin
    select form_id, section_name into l_form_id, l_name from gfm_sections where id = p_id;
    l_name := nvl(trim(j_str(o, 'name', l_name)), l_name);

    update gfm_sections set section_name = l_name where id = p_id;
    update gfm_items    set section      = l_name where section_id = p_id;  -- legacy column

    commit;
    emit(form_json(l_form_id));
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end update_section;

procedure delete_section (p_id in number)
is
    l_form_id number;
begin
    select form_id into l_form_id from gfm_sections where id = p_id;

    update gfm_items set section_id = null, section = null where section_id = p_id;
    delete gfm_sections where id = p_id;

    commit;
    emit(form_json(l_form_id));
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end delete_section;

procedure create_item (p_form_id in number, p_body in clob)
is
    o          json_object_t := parse(p_body);
    l_tcomp    varchar2(1)  := nvl(upper(j_str(o, 'tcomp')), 'C');
    l_comp_id  number       := j_num(o, 'compId');
    l_lib      gfm_items.lib%type := trim(j_str(o, 'lib'));
    l_sec_id   number       := j_num(o, 'sectionId');
    l_sec_name gfm_sections.section_name%type;
    l_vtype    gfm_items.vtype%type;
    l_comp     gfm_comp%rowtype;
    l_detail   gfm_form%rowtype;
    l_seq      number;
    l_code     gfm_items.code%type;
    l_mand     gfm_items.mandatory%type;
    l_new_row  gfm_items.new_row%type;
    l_descr    gfm_items.description%type;
    l_id       number;
begin
    check_form(p_form_id);
    l_sec_name := section_name(p_form_id, l_sec_id);

    if l_tcomp = 'C' then
        begin
            select * into l_comp from gfm_comp where id = l_comp_id and nvl(internal, 'N') = 'N';
        exception
            when no_data_found then
                fail(c_err_business, 'Composant ' || l_comp_id || ' inconnu');
        end;
        l_lib   := nvl(l_lib, l_comp.lib);
        l_vtype := case when l_comp.ctype in ('LI', 'DL')
                        then nvl(j_str(o, 'vtype'), nvl(l_comp.vtype, 'LIST')) end;

    elsif l_tcomp = 'D' then
        begin
            select * into l_detail from gfm_form where id = l_comp_id and vtype = 'D';
        exception
            when no_data_found then
                fail(c_err_business, 'Sous-formulaire ' || l_comp_id || ' inconnu (type D attendu)');
        end;
        if l_comp_id = p_form_id then
            fail(c_err_business, 'Un formulaire ne peut pas s''inclure lui-même');
        end if;
        l_lib := nvl(l_lib, l_detail.lib);
    else
        fail(c_err_business, 'tcomp attendu : C (champ) ou D (sous-formulaire)');
    end if;

    select nvl(max(seq), 0) + 10 into l_seq from gfm_items where form_id = p_form_id;

    l_code    := item_code(p_form_id, nvl(j_str(o, 'code'), l_lib));
    l_mand    := nvl(j_yn(o, 'mandatory'), 'N');
    l_new_row := nvl(j_yn(o, 'newRow'), 'Y');
    l_descr   := j_str(o, 'description');

    insert into gfm_items (
           form_id, lib, code, comp, tcomp, vtype, section_id, section,
           seq, mandatory, new_row, description )
    values (
           p_form_id, l_lib, l_code, l_comp_id, l_tcomp, l_vtype, l_sec_id, l_sec_name,
           l_seq, l_mand, l_new_row, l_descr )
    returning id into l_id;

    commit;
    emit(created_json(l_id, p_form_id), 201);
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end create_item;

procedure update_item (p_id in number, p_body in clob)
is
    o          json_object_t := parse(p_body);
    l_row      gfm_items%rowtype;
    l_master   gfm_items%rowtype;
    l_col_span number;
begin
    select * into l_row from gfm_items where id = p_id for update;

    if o.has('lib') then
        l_row.lib := nvl(trim(j_str(o, 'lib')), l_row.lib);
    end if;
    if o.has('code') and j_str(o, 'code') is not null then
        l_row.code := item_code(l_row.form_id, j_str(o, 'code'), p_id);
    end if;
    l_row.description  := j_str(o, 'description', l_row.description);
    l_row.vtype        := j_str(o, 'vtype',       l_row.vtype);
    l_row.lov          := j_str(o, 'lov',         l_row.lov);
    l_row.mandatory    := nvl(j_yn(o, 'mandatory', l_row.mandatory), 'N');
    l_row.new_row      := nvl(j_yn(o, 'newRow',    l_row.new_row),   'Y');
    l_row.icon         := j_str(o, 'icon',        l_row.icon);
    l_row.notes        := j_str(o, 'notes',       l_row.notes);
    l_row.master_value := j_str(o, 'masterValue', l_row.master_value);

    if o.has('colSpan') then
        l_col_span := j_num(o, 'colSpan');
        if l_col_span is not null and l_col_span not between 1 and 6 then
            fail(c_err_business, 'Largeur attendue entre 1 et 6 (sixièmes de ligne)');
        end if;
        l_row.col_span := l_col_span;
    end if;

    if o.has('masterId') then
        l_row.master_id := j_num(o, 'masterId');
        if l_row.master_id is not null then
            if l_row.master_id = p_id then
                fail(c_err_business, 'Un champ ne peut pas dépendre de lui-même');
            end if;
            begin
                select * into l_master from gfm_items
                 where id = l_row.master_id and form_id = l_row.form_id;
            exception
                when no_data_found then
                    fail(c_err_business, 'Champ maître inconnu pour ce formulaire');
            end;
        else
            l_row.master_value := null;
        end if;
    end if;

    update gfm_items
       set lib          = l_row.lib,
           code         = l_row.code,
           description  = l_row.description,
           vtype        = l_row.vtype,
           lov          = l_row.lov,
           mandatory    = l_row.mandatory,
           new_row      = l_row.new_row,
           col_span     = l_row.col_span,
           icon         = l_row.icon,
           notes        = l_row.notes,
           master_id    = l_row.master_id,
           master_value = l_row.master_value
     where id = p_id;

    commit;
    emit(form_json(l_row.form_id));
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end update_item;

procedure delete_item (p_id in number)
is
    l_form_id number;
begin
    select form_id into l_form_id from gfm_items where id = p_id;

    update gfm_items set master_id = null, master_value = null where master_id = p_id;
    delete gfm_items where id = p_id;

    commit;
    emit(form_json(l_form_id));
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end delete_item;

procedure get_item_lov (p_id in number)
is
    l_item  gfm_items%rowtype;
    l_ctype gfm_comp.ctype%type;
    l_clib  gfm_comp.lib%type;
    l_json  clob;
begin
    select * into l_item from gfm_items where id = p_id;

    if nvl(l_item.tcomp, 'C') = 'C' then
        select ctype, lib into l_ctype, l_clib from gfm_comp where id = l_item.comp;
    end if;

    if l_clib = 'Inline List' then
        select json_arrayagg(json_object('d' value column_value, 'r' value column_value) returning clob)
          into l_json
          from table(apex_string.split(l_item.lov, ':'))
         where column_value is not null;
    elsif l_ctype in ('LI', 'DL') then
        -- same query as the generated page (gfm_builder.get_lov: columns d, r)
        execute immediate
            'select json_arrayagg(json_object(''d'' value d, ''r'' value r) returning clob) from ('
            || gfm_builder.get_lov(p_id) || ')'
            into l_json;
    end if;

    emit(nvl(l_json, to_clob('[]')));
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end get_item_lov;

procedure list_components
is
    l_comps   clob;
    l_details clob;
    l_json    clob;
begin
    select json_arrayagg(
             json_object(
               'id'       value c.id,
               'lib'      value c.lib,
               'notes'    value c.notes,
               'ctype'    value c.ctype,
               'vtype'    value c.vtype,
               'icon'     value c.icon,
               'groupe'     value c.groupe,
               'objSource'  value c.obj_source,
               'factory'    value nvl(c.factory, 'N'),
               'isInline'   value case when c.lib = 'Inline List' then 'Y' else 'N' end,
               'itemCount'  value ( select count(*) from gfm_items i
                                     where i.comp = c.id and nvl(i.tcomp, 'C') = 'C' ),
               'valueCount' value ( select count(*) from gfm_lov l where l.comp_id = c.id )
               returning clob )
             order by c.ctype, upper(c.lib) returning clob )
      into l_comps
      from gfm_comp c
     where nvl(c.internal, 'N') = 'N';

    select json_arrayagg(
             json_object('id' value f.id, 'lib' value f.lib, 'code' value f.code)
             order by upper(f.lib) returning clob )
      into l_details
      from gfm_form f
     where f.vtype = 'D';

    select json_object(
             'components'  value nvl(l_comps,   to_clob('[]')) format json,
             'detailForms' value nvl(l_details, to_clob('[]')) format json
             returning clob )
      into l_json
      from dual;
    emit(l_json);
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end list_components;

-- ---------------------------------------------------------------------
-- Components and list values
-- ---------------------------------------------------------------------


/** Component document with its values. */
function component_json (p_id in number)
return clob
is
    l_json clob;
begin
    select json_object(
             'id'         value c.id,
             'lib'        value c.lib,
             'notes'      value c.notes,
             'ctype'      value c.ctype,
             'vtype'      value c.vtype,
             'icon'       value c.icon,
             'groupe'     value c.groupe,
             'objSource'  value c.obj_source,
             'factory'    value nvl(c.factory, 'N'),
             'isInline'   value case when c.lib = c_inline_list then 'Y' else 'N' end,
             'itemCount'  value ( select count(*) from gfm_items i
                                   where i.comp = c.id and nvl(i.tcomp, 'C') = 'C' ),
             'forms'      value nvl((
                 select json_arrayagg(json_object('id' value f.id, 'lib' value f.lib)
                                      order by upper(f.lib) returning clob)
                   from gfm_form f
                  where f.id in ( select i.form_id from gfm_items i
                                   where i.comp = c.id and nvl(i.tcomp, 'C') = 'C' )
                 ), to_clob('[]')) format json,
             'values'     value nvl((
                 select json_arrayagg(
                          json_object(
                            'id'        value l.id,
                            'd'         value l.lib_value,
                            'r'         value l.c_value,
                            'isDefault' value nvl(l.is_default, 'N') )
                          order by l.seq nulls last, l.lib_value, l.id returning clob)
                   from gfm_lov l
                  where l.comp_id = c.id ), to_clob('[]')) format json
             returning clob )
      into l_json
      from gfm_comp c
     where c.id = p_id
       and nvl(c.internal, 'N') = 'N';
    return l_json;
exception
    when no_data_found then
        fail(c_err_notfound, 'Composant ' || p_id || ' introuvable');
end component_json;

/**
 * Checks the source of a dynamic list: existing view or table exposing
 * columns D (displayed) and R (returned). Returns the validated name.
 */
function check_source (p_source in varchar2)
return varchar2
is
    l_name varchar2(200);
begin
    if p_source is null then
        fail(c_err_business, 'Une liste dynamique doit indiquer sa vue source (colonnes D et R)');
    end if;
    begin
        l_name := dbms_assert.sql_object_name(upper(trim(p_source)));
    exception
        when others then
            fail(c_err_business, 'Vue ou table « ' || p_source || ' » introuvable');
    end;
    begin
        execute immediate 'select d, r from ' || l_name || ' where 1 = 0';
    exception
        when others then
            fail(c_err_business, 'La vue « ' || p_source || ' » doit exposer les colonnes D (libellé) et R (valeur)');
    end;
    return l_name;
end check_source;

procedure check_ctype (p_ctype in varchar2, p_vtype in varchar2)
is
begin
    if p_ctype is null or p_ctype not in ('CT', 'CN', 'NB', 'DA', 'LI', 'DL') then
        fail(c_err_business, 'Type attendu : CT, CN, NB, DA, LI ou DL');
    end if;
    if p_vtype is not null
       and p_vtype not in ('RADIO', 'LIST', 'CHECKBOX', 'NATIVE_SINGLE_CHECKBOX', 'POPUP') then
        fail(c_err_business, 'Affichage de liste inconnu : ' || p_vtype);
    end if;
end check_ctype;

procedure get_component (p_id in number)
is
begin
    emit(component_json(p_id));
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end get_component;

procedure create_component (p_body in clob)
is
    o        json_object_t := parse(p_body);
    l_lib    gfm_comp.lib%type        := trim(j_str(o, 'lib'));
    l_ctype  gfm_comp.ctype%type      := upper(j_str(o, 'ctype'));
    l_vtype  gfm_comp.vtype%type      := upper(j_str(o, 'vtype'));
    l_notes  gfm_comp.notes%type      := j_str(o, 'notes');
    l_icon   gfm_comp.icon%type       := j_str(o, 'icon');
    l_groupe gfm_comp.groupe%type     := j_str(o, 'groupe');
    l_source gfm_comp.obj_source%type := j_str(o, 'objSource');
    l_id     number;
begin
    if l_lib is null then
        fail(c_err_business, 'Le libellé du composant est obligatoire');
    end if;
    if l_lib like '$%' or l_lib = c_inline_list then
        fail(c_err_business, 'Libellé réservé : ' || l_lib);
    end if;
    check_ctype(l_ctype, l_vtype);

    if l_ctype in ('LI', 'DL') then
        l_vtype := nvl(l_vtype, 'LIST');
    else
        l_vtype := null;
    end if;
    if l_ctype = 'DL' then
        l_source := check_source(l_source);
    else
        l_source := null;
    end if;

    insert into gfm_comp (lib, notes, ctype, vtype, icon, groupe, obj_source, internal, factory)
    values (l_lib, l_notes, l_ctype, l_vtype, l_icon, l_groupe, l_source, 'N', 'N')
    returning id into l_id;

    commit;
    emit(component_json(l_id), 201);
exception
    when dup_val_on_index then
        rollback;
        emit_error(409, 'Un composant porte déjà le libellé « ' || l_lib || ' »');
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end create_component;

procedure update_component (p_id in number, p_body in clob)
is
    o       json_object_t := parse(p_body);
    l_row   gfm_comp%rowtype;
    l_lib   gfm_comp.lib%type;
    l_ctype gfm_comp.ctype%type;
    l_used  pls_integer;
begin
    begin
        select * into l_row from gfm_comp
         where id = p_id and nvl(internal, 'N') = 'N'
           for update;
    exception
        when no_data_found then
            fail(c_err_notfound, 'Composant ' || p_id || ' introuvable');
    end;

    l_lib   := nvl(trim(j_str(o, 'lib', l_row.lib)), l_row.lib);
    l_ctype := upper(nvl(j_str(o, 'ctype', l_row.ctype), l_row.ctype));

    if nvl(l_row.factory, 'N') = 'Y' and (l_lib <> l_row.lib or l_ctype <> l_row.ctype) then
        fail(c_err_conflict, 'Composant standard : son libellé et son type ne peuvent pas changer');
    end if;
    if l_lib <> l_row.lib and (l_lib like '$%' or l_lib = c_inline_list) then
        fail(c_err_business, 'Libellé réservé : ' || l_lib);
    end if;
    if l_ctype <> l_row.ctype then
        select count(*) into l_used from gfm_items where comp = p_id and nvl(tcomp, 'C') = 'C';
        if l_used > 0 then
            fail(c_err_conflict, 'Le type ne peut pas changer : composant utilisé par '
                                 || l_used || ' champ(s)');
        end if;
    end if;

    l_row.lib        := l_lib;
    l_row.ctype      := l_ctype;
    l_row.notes      := j_str(o, 'notes',     l_row.notes);
    l_row.icon       := j_str(o, 'icon',      l_row.icon);
    l_row.groupe     := j_str(o, 'groupe',    l_row.groupe);
    l_row.vtype      := upper(j_str(o, 'vtype', l_row.vtype));
    l_row.obj_source := j_str(o, 'objSource', l_row.obj_source);
    check_ctype(l_row.ctype, l_row.vtype);

    if l_row.ctype in ('LI', 'DL') then
        l_row.vtype := nvl(l_row.vtype, 'LIST');
    else
        l_row.vtype := null;
    end if;
    if l_row.ctype = 'DL' then
        l_row.obj_source := check_source(l_row.obj_source);
    else
        l_row.obj_source := null;
    end if;

    update gfm_comp
       set lib        = l_row.lib,
           notes      = l_row.notes,
           ctype      = l_row.ctype,
           vtype      = l_row.vtype,
           icon       = l_row.icon,
           groupe     = l_row.groupe,
           obj_source = l_row.obj_source
     where id = p_id;

    commit;
    emit(component_json(p_id));
exception
    when dup_val_on_index then
        rollback;
        emit_error(409, 'Un composant porte déjà le libellé « ' || l_lib || ' »');
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end update_component;

procedure delete_component (p_id in number)
is
    l_row  gfm_comp%rowtype;
    l_used pls_integer;
begin
    begin
        select * into l_row from gfm_comp where id = p_id and nvl(internal, 'N') = 'N';
    exception
        when no_data_found then
            fail(c_err_notfound, 'Composant ' || p_id || ' introuvable');
    end;
    if nvl(l_row.factory, 'N') = 'Y' then
        fail(c_err_conflict, 'Composant standard : il ne peut pas être supprimé');
    end if;

    select count(*) into l_used from gfm_items where comp = p_id and nvl(tcomp, 'C') = 'C';
    if l_used > 0 then
        fail(c_err_conflict, 'Composant utilisé par ' || l_used
                             || ' champ(s) : supprimez-les ou changez leur composant d''abord');
    end if;

    delete gfm_comp where id = p_id;          -- cascade: GFM_LOV
    commit;
    emit('{"deleted":' || p_id || '}');
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end delete_component;

procedure save_values (p_id in number, p_body in clob)
is
    o          json_object_t := parse(p_body);
    l_values   json_array_t;
    l_val      json_object_t;
    l_comp     gfm_comp%rowtype;
    l_keep     apex_t_number := apex_t_number();
    l_seen     apex_t_varchar2 := apex_t_varchar2();
    l_val_id   number;
    l_d        gfm_lov.lib_value%type;
    l_r        gfm_lov.c_value%type;
    l_default  varchar2(1);
    l_has_def  boolean := false;
begin
    begin
        select * into l_comp from gfm_comp where id = p_id and nvl(internal, 'N') = 'N';
    exception
        when no_data_found then
            fail(c_err_notfound, 'Composant ' || p_id || ' introuvable');
    end;
    if l_comp.ctype <> 'LI' or l_comp.lib = c_inline_list then
        fail(c_err_business, 'Seules les listes statiques ont des valeurs enregistrées');
    end if;
    if not o.has('values') then
        fail(c_err_business, 'Attribut "values" attendu');
    end if;
    l_values := o.get_array('values');

    -- 1. validation, ids kept
    for i in 0 .. l_values.get_size - 1 loop
        l_val := treat(l_values.get(i) as json_object_t);
        l_r   := trim(j_str(l_val, 'r'));
        if l_r is null then
            fail(c_err_business, 'Valeur ' || (i + 1) || ' : la valeur enregistrée est obligatoire');
        end if;
        if l_r member of l_seen then
            fail(c_err_business, 'Valeur « ' || l_r || ' » en double');
        end if;
        apex_string.push(l_seen, l_r);
        l_val_id := j_num(l_val, 'id');
        if l_val_id is not null then
            apex_string.push(l_keep, l_val_id);
        end if;
    end loop;

    -- 2. removed values
    delete gfm_lov
     where comp_id = p_id
       and id not in ( select column_value from table(l_keep) );

    -- 3. updates and inserts, in the order received
    for i in 0 .. l_values.get_size - 1 loop
        l_val     := treat(l_values.get(i) as json_object_t);
        l_val_id  := j_num(l_val, 'id');
        l_r       := trim(j_str(l_val, 'r'));
        l_d       := nvl(trim(j_str(l_val, 'd')), l_r);
        l_default := case when j_yn(l_val, 'isDefault') = 'Y' and not l_has_def then 'Y' else 'N' end;
        l_has_def := l_has_def or l_default = 'Y';

        if l_val_id is not null then
            update gfm_lov
               set lib_value  = l_d,
                   c_value    = l_r,
                   is_default = l_default,
                   value_type = 'C',
                   seq        = (i + 1) * 10
             where id      = l_val_id
               and comp_id = p_id;
            if sql%rowcount = 0 then
                fail(c_err_business, 'Valeur ' || l_val_id || ' inconnue pour ce composant');
            end if;
        else
            insert into gfm_lov (comp_id, value_type, lib_value, c_value, is_default, seq)
            values (p_id, 'C', l_d, l_r, l_default, (i + 1) * 10);
        end if;
    end loop;

    commit;
    emit(component_json(p_id));
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end save_values;

procedure preview_component (p_id in number)
is
    l_comp gfm_comp%rowtype;
    l_json clob;
begin
    begin
        select * into l_comp from gfm_comp where id = p_id and nvl(internal, 'N') = 'N';
    exception
        when no_data_found then
            fail(c_err_notfound, 'Composant ' || p_id || ' introuvable');
    end;

    if l_comp.ctype = 'LI' then
        select json_arrayagg(json_object('d' value lib_value, 'r' value c_value)
                             order by seq nulls last, lib_value returning clob)
          into l_json
          from gfm_lov
         where comp_id = p_id;
    elsif l_comp.ctype = 'DL' then
        execute immediate
            'select json_arrayagg(json_object(''d'' value d, ''r'' value r) returning clob) from ('
            || 'select d, r from ' || check_source(l_comp.obj_source)
            || ' order by d fetch first 100 rows only)'
            into l_json;
    end if;

    emit(nvl(l_json, to_clob('[]')));
exception
    when others then
        rollback;
        handle_error(sqlcode, sqlerrm, dbms_utility.format_error_backtrace);
end preview_component;

end gfm_api;
/
