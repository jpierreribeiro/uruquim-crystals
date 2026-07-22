CREATE TABLE notes (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    slug       text NOT NULL UNIQUE,
    title      text NOT NULL,
    body       text,
    created_at timestamptz NOT NULL DEFAULT now()
);
