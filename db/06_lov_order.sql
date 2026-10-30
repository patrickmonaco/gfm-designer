--------------------------------------------------------------------------------
-- GFM Designer - display order of the list values (GFM_LOV.SEQ)
--
-- Run once, BEFORE recompiling 00_gfm_builder.pkb (v2.2) and 02_gfm_api.pkb:
-- gfm_builder.get_lov now sorts the values by SEQ, then by label.
-- The current alphabetical order is kept as the initial order.
--------------------------------------------------------------------------------
declare
    l_count pls_integer;
begin
    select count(*) into l_count
      from user_tab_columns
     where table_name = 'GFM_LOV' and column_name = 'SEQ';
    if l_count = 0 then
        execute immediate 'alter table gfm_lov add (seq number)';
    end if;
end;
/

merge into gfm_lov t
using ( select id, 10 * row_number() over (partition by comp_id order by lib_value, id) as seq
          from gfm_lov ) s
   on ( t.id = s.id )
 when matched then update set t.seq = s.seq
 where t.seq is null;

commit;
