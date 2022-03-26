-- Create the initial table to store streams
CREATE TABLE streams (
  id VARCHAR(16) PRIMARY KEY,
  org_id VARCHAR(16) NOT NULL,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL,

  CONSTRAINT streams_uniq_orgid_name UNIQUE (org_id, name)
);

-- Create the initial table to store annotations
CREATE TABLE annotations (
  id VARCHAR(16) PRIMARY KEY,
  org_id VARCHAR(16) NOT NULL,
  stream_id VARCHAR(16) NOT NULL,
  summary TEXT NOT NULL,
  message TEXT NOT NULL,
  stickers TEXT NOT NULL,
  duration TEXT NOT NULL,
  lower TIMESTAMP NOT NULL,
  upper TIMESTAMP NOT NULL,

  FOREIGN KEY (stream_id) REFERENCES streams(id) ON DELETE CASCADE
);

-- Create indexes for stream_id and stickers to support fast queries
CREATE INDEX idx_annotations_stream ON annotations (stream_id);
CREATE INDEX idx_annotations_stickers ON annotations (stickers);
