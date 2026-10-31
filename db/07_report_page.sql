--------------------------------------------------------------------------------
-- GFM Designer - page of the interactive report of a form
--
-- Run once, before recompiling 00_gfm_builder.pkb (v2.4) and 02_gfm_api.pkb.
--------------------------------------------------------------------------------
declare
    l_count pls_integer;
begin
    select count(*) into l_count
      from user_tab_columns
     where table_name = 'GFM_FORM' and column_name = 'REPORT_PAGE_ID';
    if l_count = 0 then
        execute immediate 'alter table gfm_form add (report_page_id number)';
        execute immediate 'alter table gfm_form add constraint gfm_form_report_page_uk unique (report_page_id)';
    end if;
end;
/
