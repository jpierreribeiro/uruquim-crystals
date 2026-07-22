-- uruquim:no_transaction
CREATE INDEX CONCURRENTLY mig_missing_idx ON mig_absent_table (col);
