
BEGIN;

INSERT INTO config.upgrade_log (version) VALUES ('0200'); -- miker

CREATE OR REPLACE FUNCTION biblio.extract_metabib_field_entry ( rid BIGINT, default_joiner TEXT ) RETURNS SETOF metabib.field_entry_template AS $func$
DECLARE
    bib     biblio.record_entry%ROWTYPE;
    idx     config.metabib_field%ROWTYPE;
    xfrm        config.xml_transform%ROWTYPE;
    prev_xfrm   TEXT;
    transformed_xml TEXT;
    xml_node    TEXT;
    xml_node_list   TEXT[];
    raw_text    TEXT;
    joiner      TEXT := default_joiner; -- XXX will index defs supply a joiner?
    output_row  metabib.field_entry_template%ROWTYPE;
BEGIN

    -- Get the record
    SELECT INTO bib * FROM biblio.record_entry WHERE id = rid;

    -- Loop over the indexing entries
    FOR idx IN SELECT * FROM config.metabib_field ORDER BY format LOOP

        SELECT INTO xfrm * from config.xml_transform WHERE name = idx.format;

        -- See if we can skip the XSLT ... it's expensive
        IF prev_xfrm IS NULL OR prev_xfrm <> xfrm.name THEN
            -- Can't skip the transform
            IF xfrm.xslt <> '---' THEN
                transformed_xml := oils_xslt_process(bib.marc,xfrm.xslt);
            ELSE
                transformed_xml := bib.marc;
            END IF;

            prev_xfrm := xfrm.name;
        END IF;

        xml_node_list := oils_xpath( idx.xpath, transformed_xml, ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]] );

        raw_text := NULL;
        FOR xml_node IN SELECT x FROM explode_array(xml_node_list) AS x LOOP
            IF raw_text IS NOT NULL THEN
                raw_text := raw_text || joiner;
            END IF;
            raw_text := COALESCE(raw_text,'') || ARRAY_TO_STRING(oils_xpath( '//text()', REGEXP_REPLACE(xml_node,'&(?!amp;)','&amp;','g')), ' ');
        END LOOP;

        CONTINUE WHEN raw_text IS NULL;

        output_row.field_class = idx.field_class;
        output_row.field = idx.id;
        output_row.source = rid;
        output_row.value = BTRIM(REGEXP_REPLACE(raw_text, E'\\s+', ' ', 'g'));

        RETURN NEXT output_row;

    END LOOP;

END;
$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION biblio.flatten_marc ( rid BIGINT ) RETURNS SETOF metabib.full_rec AS $func$
DECLARE
    bib biblio.record_entry%ROWTYPE;
    output  metabib.full_rec%ROWTYPE;
    field   RECORD;
BEGIN
    SELECT INTO bib * FROM biblio.record_entry WHERE id = rid;

    FOR field IN SELECT * FROM biblio.flatten_marc( bib.marc ) LOOP
        output.record := rid;
        output.ind1 := field.ind1;
        output.ind2 := field.ind2;
        output.tag := field.tag;
        output.subfield := field.subfield;
        IF field.subfield IS NOT NULL AND field.tag NOT IN ('020','022','024') THEN -- exclude standard numbers and control fields
            output.value := naco_normalize(field.value, field.subfield);
        ELSE
            output.value := field.value;
        END IF;

        CONTINUE WHEN output.value IS NULL;

        RETURN NEXT output;
    END LOOP;
END;
$func$ LANGUAGE PLPGSQL;

COMMIT;

