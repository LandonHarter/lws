export type PgColumn = {
  name: string;
  dataType: string;
  nullable: boolean;
  default: string | null;
  isPrimaryKey: boolean;
};

export type TableStructure = {
  columns: PgColumn[];
  primaryKey: string[];
  rowEstimate: number;
};

export type Row = Record<string, unknown>;
