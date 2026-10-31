--------------------------------------------------------------------------------
-- GFM Designer - typed storage columns
--
--   * GFM_DATA: NUMBER columns N001..N020 and DATE columns D001..D020
--     (existing columns are kept, only the missing ones are added);
--   * GFM_ITEMS.MAP_COL: storage column of each item (C003, N002, D005...),
--     filled for the existing items from MAP_ID (C + 3 digits): their data
--     stays where it is.
--
-- Run once, before recompiling 00_gfm_builder.pkb (v2.6) and 02_gfm_api.pkb.
--------------------------------------------------------------------------------
declare
    procedure add_column (p_table in varchar2, p_column in varchar2, p_type in varchar2) is
        l_count pls_integer;
    begin
        select count(*) into l_count
          from user_tab_columns
         where table_name = p_table and column_name = p_column;
        if l_count = 0 then
            execute immediate 'alter table ' || p_table || ' add (' || p_column || ' ' || p_type || ')';
        end if;
    end add_column;
begin
    for i in 1 .. 20 loop
        add_column('GFM_DATA', 'N' || lpad(i, 3, '0'), 'NUMBER');
        add_column('GFM_DATA', 'D' || lpad(i, 3, '0'), 'DATE');
    end loop;
    add_column('GFM_ITEMS', 'MAP_COL', 'VARCHAR2(30)');
end;
/

-- existing items: column deduced from MAP_ID, as before
update gfm_items
   set map_col = 'C' || lpad(to_char(map_id), 3, '0')
 where map_id is not null
   and map_col is null;

commit;
