require "minitest/autorun"
require "open3"
require "rbconfig"
require "tempfile"

class VerifyCloudKitSchemaTest < Minitest::Test
  SCRIPT = File.expand_path("../verify_cloudkit_schema.rb", __dir__)

  COMPLETE_SCHEMA = <<~SCHEMA
    DEFINE SCHEMA
      RECORD TYPE Family (
        "___recordID" REFERENCE,
        id STRING,
        name STRING,
        createdAt TIMESTAMP,
        updatedAt TIMESTAMP
      );
      RECORD TYPE Bag (
        "___recordID" REFERENCE,
        id STRING,
        name STRING,
        familyID STRING,
        createdAt TIMESTAMP,
        updatedAt TIMESTAMP
      );
      RECORD TYPE Item (
        "___recordID" REFERENCE,
        id STRING,
        name STRING,
        janCode STRING,
        quantity INT64,
        expiryDate TIMESTAMP,
        locationNote STRING,
        category STRING,
        notified30 INT64,
        notified7 INT64,
        notified1 INT64,
        createdAt TIMESTAMP,
        updatedAt TIMESTAMP,
        bagID STRING,
        familyID STRING
      );
      RECORD TYPE DeletionMarker (
        "___recordID" REFERENCE,
        id STRING,
        familyID STRING,
        entityType STRING,
        targetRecordID STRING,
        deletedAt TIMESTAMP
      );
  SCHEMA

  def test_accepts_complete_schema
    stdout, stderr, status = run_verifier(COMPLETE_SCHEMA)

    assert status.success?, stderr
    assert_includes stdout, "CloudKit production schema verified"
  end

  def test_rejects_missing_record_type
    _stdout, stderr, status = run_verifier(
      COMPLETE_SCHEMA.sub(/\s*RECORD TYPE DeletionMarker \(.*?\);/m, "")
    )

    refute status.success?
    assert_includes stderr, "record type DeletionMarker がありません"
  end

  def test_rejects_missing_field
    _stdout, stderr, status = run_verifier(
      COMPLETE_SCHEMA.sub(/\s*locationNote STRING,/, "")
    )

    refute status.success?
    assert_includes stderr, "Item.locationNote がありません"
  end

  def test_rejects_missing_category_field
    _stdout, stderr, status = run_verifier(
      COMPLETE_SCHEMA.sub(/\s*category STRING,/, "")
    )

    refute status.success?
    assert_includes stderr, "Item.category がありません"
  end

  def test_rejects_wrong_field_type
    _stdout, stderr, status = run_verifier(
      COMPLETE_SCHEMA.sub("quantity INT64", "quantity STRING")
    )

    refute status.success?
    assert_includes stderr, "Item.quantity の型がINT64ではありません (STRING)"
  end

  private

  def run_verifier(schema)
    Tempfile.create(["schema", ".ckdb"]) do |file|
      file.write(schema)
      file.flush
      return Open3.capture3(
        RbConfig.ruby,
        SCRIPT,
        "--schema-file",
        file.path,
        "--environment",
        "production"
      )
    end
  end
end
