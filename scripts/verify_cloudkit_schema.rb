#!/usr/bin/env ruby

require "open3"
require "optparse"
require "tmpdir"

EXPECTED_RECORD_FIELDS = {
  "Family" => {
    "id" => "STRING", "name" => "STRING",
    "createdAt" => "TIMESTAMP", "updatedAt" => "TIMESTAMP"
  },
  "Bag" => {
    "id" => "STRING", "name" => "STRING", "familyID" => "STRING",
    "createdAt" => "TIMESTAMP", "updatedAt" => "TIMESTAMP"
  },
  "Item" => {
    "id" => "STRING", "name" => "STRING", "janCode" => "STRING",
    "quantity" => "INT64", "expiryDate" => "TIMESTAMP", "locationNote" => "STRING",
    "notified30" => "INT64", "notified7" => "INT64", "notified1" => "INT64",
    "createdAt" => "TIMESTAMP", "updatedAt" => "TIMESTAMP",
    "bagID" => "STRING", "familyID" => "STRING"
  },
  "DeletionMarker" => {
    "id" => "STRING", "familyID" => "STRING", "entityType" => "STRING",
    "targetRecordID" => "STRING", "deletedAt" => "TIMESTAMP"
  }
}.freeze

options = {
  team_id: ENV.fetch("APPLE_TEAM_ID", "2L6CD9CNHL"),
  container_id: ENV.fetch("CLOUDKIT_CONTAINER_ID", "iCloud.com.stockpile-manager.app"),
  environment: ENV.fetch("CLOUDKIT_ENVIRONMENT", "production")
}

OptionParser.new do |parser|
  parser.banner = "Usage: verify_cloudkit_schema.rb [options]"
  parser.on("--team-id TEAM_ID") { |value| options[:team_id] = value }
  parser.on("--container-id CONTAINER_ID") { |value| options[:container_id] = value }
  parser.on("--environment ENVIRONMENT") { |value| options[:environment] = value }
  parser.on("--schema-file PATH") { |value| options[:schema_file] = value }
end.parse!

unless %w[development production].include?(options[:environment])
  warn "CloudKit environment must be development or production."
  exit 2
end

def export_schema(options)
  Dir.mktmpdir("stockpile-cloudkit-schema") do |directory|
    schema_path = File.join(directory, "production.ckdb")
    command = [
      "xcrun", "cktool", "export-schema",
      "--team-id", options.fetch(:team_id),
      "--container-id", options.fetch(:container_id),
      "--environment", options.fetch(:environment),
      "--output-file", schema_path
    ]
    _stdout, stderr, status = Open3.capture3(*command)
    unless status.success?
      warn stderr.strip unless stderr.strip.empty?
      warn <<~MESSAGE.strip
        CloudKit #{options.fetch(:environment)} schemaを取得できませんでした。
        CloudKit ConsoleでManagement Tokenを作成し、CLOUDKIT_MANAGEMENT_TOKENに設定してください。
      MESSAGE
      exit status.exitstatus || 1
    end
    return File.read(schema_path)
  end
end

schema = if options[:schema_file]
  File.read(options[:schema_file])
else
  export_schema(options)
end

errors = []
EXPECTED_RECORD_FIELDS.each do |record_type, required_fields|
  match = schema.match(/RECORD\s+TYPE\s+"?#{Regexp.escape(record_type)}"?\s*\((.*?)\)\s*;/mi)
  unless match
    errors << "record type #{record_type} がありません"
    next
  end

  body = match[1]
  required_fields.each do |field, expected_type|
    field_pattern = /(?:\A|,)\s*"?#{Regexp.escape(field)}"?\s+([A-Z][A-Z0-9_]*)\b/mi
    field_match = body.match(field_pattern)
    if field_match.nil?
      errors << "#{record_type}.#{field} がありません"
    elsif field_match[1].upcase != expected_type
      errors << "#{record_type}.#{field} の型が#{expected_type}ではありません (#{field_match[1].upcase})"
    end
  end

  record_id_pattern = /"?___recordID"?\s+REFERENCE\b[^,)]*\bQUERYABLE\b/i
  unless body.match?(record_id_pattern)
    errors << "#{record_type}.___recordID に QUERYABLE index がありません"
  end
end

unless errors.empty?
  warn "CloudKit #{options[:environment]} schemaがStockpileの共有モデルと一致しません:"
  errors.each { |error| warn "- #{error}" }
  warn "CloudKit ConsoleでDevelopmentの変更をProductionへDeployしてから再実行してください。"
  exit 1
end

puts "CloudKit #{options[:environment]} schema verified: #{EXPECTED_RECORD_FIELDS.keys.join(', ')}"
