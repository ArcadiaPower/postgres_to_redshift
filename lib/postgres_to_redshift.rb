require "postgres_to_redshift/version"
require 'pg'
require 'uri'
require 'aws-sdk'
require 'zlib'
require 'tempfile'
require "postgres_to_redshift/table"
require "postgres_to_redshift/column"

class PostgresToRedshift
  class << self
    attr_accessor :source_uri, :target_uri
  end

  attr_reader :source_connection, :target_connection, :s3

  KILOBYTE = 1024
  MEGABYTE = KILOBYTE * 1024
  GIGABYTE = MEGABYTE * 1024

  def self.update_tables(except: [])
    update_tables = PostgresToRedshift.new

    update_tables.tables(except: except).each do |table|
      target_connection.exec("CREATE TABLE IF NOT EXISTS #{schema}.#{target_connection.quote_ident(table.target_table_name)} (#{table.columns_for_create})")

      update_tables.copy_table(table)

      update_tables.import_table(table)
    end
  end

  def self.source_uri
    @source_uri ||= URI.parse(ENV['POSTGRES_TO_REDSHIFT_SOURCE_URI'])
  end

  def self.target_uri
    @target_uri ||= URI.parse(ENV['POSTGRES_TO_REDSHIFT_TARGET_URI'])
  end

  def self.source_connection
    unless instance_variable_defined?(:"@source_connection")
      @source_connection = PG::Connection.new(host: source_uri.host, port: source_uri.port, user: source_uri.user || ENV['USER'], password: source_uri.password, dbname: source_uri.path[1..-1])
      @source_connection.exec("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY;")
    end

    @source_connection
  end

  def self.target_connection
    unless instance_variable_defined?(:"@target_connection")
      @target_connection = PG::Connection.new(host: target_uri.host, port: target_uri.port, user: target_uri.user || ENV['USER'], password: target_uri.password, dbname: target_uri.path[1..-1])
    end

    @target_connection
  end

  def self.schema
    ENV.fetch('POSTGRES_TO_REDSHIFT_TARGET_SCHEMA')
  end

  def source_connection
    self.class.source_connection
  end

  def target_connection
    self.class.target_connection
  end

  def tables(except: [])
    source_connection.exec("SELECT * FROM information_schema.tables WHERE table_schema = 'public' AND table_type in ('BASE TABLE', 'VIEW') ORDER BY table_name ASC").map do |table_attributes|
      table = Table.new(attributes: table_attributes)
      next if except.include?(table.name) || table.name =~ /^pg_/
      table.columns = column_definitions(table)
      table
    end.compact
  end

  def column_definitions(table)
    source_connection.exec("SELECT * FROM information_schema.columns WHERE table_schema='public' AND table_name='#{table.name}' order by ordinal_position")
  end

  def s3
    @s3 ||= Aws::S3::Client.new(access_key_id: ENV['S3_DATABASE_EXPORT_ID'], secret_access_key: ENV['S3_DATABASE_EXPORT_KEY'])
  end

  def bucket
    @bucket ||= Aws::S3::Bucket.new(ENV['S3_DATABASE_EXPORT_BUCKET'], client: s3)
  end

  def copy_table(table)
    tmpfile = Tempfile.new("psql2rs")
    tmpfile.binmode
    zip = Zlib::GzipWriter.new(tmpfile)
    chunksize = 5 * GIGABYTE # uncompressed
    chunk = 1
    bucket.objects({ prefix: "export/#{table.target_table_name}.psv.gz" }).each { |object| object.delete }

    begin
      puts "Downloading #{table}"
      copy_command = "COPY (SELECT #{table.columns_for_copy} FROM #{table.name}) TO STDOUT WITH DELIMITER '|'"
      key = "export/#{table.target_table_name}.psv.gz"
      multipart_upload = s3.create_multipart_upload(bucket: bucket.name, key: key)

      options = {
        bucket: bucket.name,
        key: key,
        upload_id: multipart_upload.upload_id
      }

      source_connection.copy_data(copy_command) do
        while row = source_connection.get_copy_data
          zip.write(row)
          if (zip.pos > chunksize)
            zip.finish
            tmpfile.rewind
            upload_table(table, tmpfile, chunk, options)
            chunk += 1
            zip.close unless zip.closed?
            tmpfile.unlink
            tmpfile = Tempfile.new("psql2rs")
            tmpfile.binmode
            zip = Zlib::GzipWriter.new(tmpfile)
          end
        end
      end
      zip.finish
      tmpfile.rewind
      upload_table(table, tmpfile, chunk, options)

      all_parts = s3.list_parts(options)

      options.merge!(
        multipart_upload: {
          parts:
            all_parts.parts.map do |part|
              { part_number: part.part_number, etag: part.etag }
            end
        }
      )

      s3.complete_multipart_upload(options)

      source_connection.reset
    rescue Aws::S3::Errors::NoSuchBucket
      puts 'That *bucket* does not exist.'
    rescue Aws::S3::Errors::NoSuchKey
      puts 'That *file* does not exist.'
    rescue Aws::S3::Errors::ServiceError => e
      puts 'Unknown problem.'
      puts "#{e.class}"
      puts "#{e.message}"
      if multipart_upload.upload_id
        s3.abort_multipart_upload(
          bucket: bucket.name,
          key: key,
          upload_id: multipart_upload.upload_id
        )
      end
    ensure
      zip.close unless zip.closed?
      tmpfile.unlink
    end
  end

  def upload_table(table, file, part, options)
    puts "Uploading #{table.target_table_name}.#{part}"

    s3.upload_part(
      body:        file,
      bucket:      options[:bucket],
      key:         options[:key],
      part_number: part,
      upload_id:   options[:upload_id]
    )
  end

  def import_table(table)
    puts "Importing #{table.target_table_name}"
    schema = self.class.schema

    target_connection.exec("DROP TABLE IF EXISTS #{schema}.#{table.target_table_name}_updating CASCADE")

    target_connection.exec("BEGIN;")

    target_connection.exec("ALTER TABLE #{schema}.#{target_connection.quote_ident(table.target_table_name)} RENAME TO #{table.target_table_name}_updating")

    target_connection.exec("CREATE TABLE #{schema}.#{target_connection.quote_ident(table.target_table_name)} (#{table.columns_for_create})")

    target_connection.exec("COPY #{schema}.#{target_connection.quote_ident(table.target_table_name)} FROM 's3://#{ENV['S3_DATABASE_EXPORT_BUCKET']}/export/#{table.target_table_name}.psv.gz' CREDENTIALS 'aws_access_key_id=#{ENV['S3_DATABASE_EXPORT_ID']};aws_secret_access_key=#{ENV['S3_DATABASE_EXPORT_KEY']}' GZIP TRUNCATECOLUMNS ESCAPE DELIMITER as '|';")

    target_connection.exec("COMMIT;")
  end
end
