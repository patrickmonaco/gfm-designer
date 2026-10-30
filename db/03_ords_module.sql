--------------------------------------------------------------------------------
-- GFM Designer - ORDS REST module
--
-- Run as the schema that owns the GFM tables and packages (e.g. DEMO),
-- after 01_gfm_api.pks and 02_gfm_api.pkb.
--
-- Base URL : https://<host>/ords/<schema alias>/gfm/v1/
-- Every handler is a PL/SQL block calling gfm_api, which writes the
-- HTTP status and the JSON body itself.
--
-- Edit c_origins: the origins (scheme://host:port) from which the
-- web client is served, comma separated (CORS).
--------------------------------------------------------------------------------
set define off

-- Uncomment if the schema is not REST enabled yet
-- begin
--     ords.enable_schema(p_enabled => true, p_url_mapping_type => 'BASE_PATH',
--                        p_url_mapping_pattern => lower(user), p_auto_rest_auth => true);
--     commit;
-- end;
-- /

declare
    c_module  constant varchar2(30)  := 'gfm.designer';
    c_origins constant varchar2(500) := 'http://localhost:8080';

    type t_patterns is table of boolean index by varchar2(100);
    l_templates t_patterns;

    /** Defines the template once, then the handler. */
    procedure handler (p_pattern in varchar2, p_method in varchar2, p_source in varchar2)
    is
    begin
        if not l_templates.exists(p_pattern) then
            ords.define_template(
                p_module_name => c_module,
                p_pattern     => p_pattern );
            l_templates(p_pattern) := true;
        end if;

        ords.define_handler(
            p_module_name    => c_module,
            p_pattern        => p_pattern,
            p_method         => p_method,
            p_source_type    => ords.source_type_plsql,
            p_source         => p_source,
            p_items_per_page => 0,
            p_mimes_allowed  => case when p_method in ('POST', 'PUT')
                                     then 'application/json' end );
    end handler;
begin
    ords.define_module(
        p_module_name     => c_module,
        p_base_path       => '/gfm/v1/',
        p_items_per_page  => 0,
        p_status          => 'PUBLISHED',
        p_comments        => 'GFM Designer - API of the external form designer' );

    -- CORS: origins allowed to call the module (not a define_module parameter)
    ords.set_module_origins_allowed(
        p_module_name     => c_module,
        p_origins_allowed => c_origins );

    -- Session ------------------------------------------------------------
    handler('info', 'GET', 'begin gfm_api.get_info(:current_user); end;');

    -- Forms ----------------------------------------------------------------
    handler('forms',              'GET',    'begin gfm_api.list_forms; end;');
    handler('forms',              'POST',   'begin gfm_api.create_form(:body_text); end;');
    handler('forms/:id',          'GET',    'begin gfm_api.get_form(:id); end;');
    handler('forms/:id',          'PUT',    'begin gfm_api.update_form(:id, :body_text); end;');
    handler('forms/:id',          'DELETE', 'begin gfm_api.delete_form(:id, :force); end;');
    handler('forms/:id/copy',     'POST',   'begin gfm_api.copy_form(:id); end;');
    handler('forms/:id/generate', 'POST',   'begin gfm_api.generate_form(:id); end;');
    handler('forms/:id/reset',    'POST',   'begin gfm_api.reset_form(:id); end;');
    handler('forms/:id/layout',   'PUT',    'begin gfm_api.save_layout(:id, :body_text); end;');
    handler('forms/:id/prefs',    'PUT',    'begin gfm_api.save_prefs(:id, :body_text); end;');

    -- Sections -------------------------------------------------------------
    handler('forms/:id/sections', 'POST',   'begin gfm_api.create_section(:id, :body_text); end;');
    handler('sections/:id',       'PUT',    'begin gfm_api.update_section(:id, :body_text); end;');
    handler('sections/:id',       'DELETE', 'begin gfm_api.delete_section(:id); end;');

    -- Items ----------------------------------------------------------------
    handler('forms/:id/items',    'POST',   'begin gfm_api.create_item(:id, :body_text); end;');
    handler('items/:id',          'PUT',    'begin gfm_api.update_item(:id, :body_text); end;');
    handler('items/:id',          'DELETE', 'begin gfm_api.delete_item(:id); end;');
    handler('items/:id/lov',      'GET',    'begin gfm_api.get_item_lov(:id); end;');

    -- Palette --------------------------------------------------------------
    handler('components',         'GET',    'begin gfm_api.list_components; end;');
    handler('components',         'POST',   'begin gfm_api.create_component(:body_text); end;');
    handler('components/:id',     'GET',    'begin gfm_api.get_component(:id); end;');
    handler('components/:id',     'PUT',    'begin gfm_api.update_component(:id, :body_text); end;');
    handler('components/:id',     'DELETE', 'begin gfm_api.delete_component(:id); end;');
    handler('components/:id/values',  'PUT', 'begin gfm_api.save_values(:id, :body_text); end;');
    handler('components/:id/preview', 'GET', 'begin gfm_api.preview_component(:id); end;');

    commit;
end;
/

-- Check
select t.uri_template, h.method
  from user_ords_templates t
  join user_ords_handlers  h on h.template_id = t.id
  join user_ords_modules   m on m.id = t.module_id
 where m.name = 'gfm.designer'
 order by t.uri_template, h.method;
