require "test_helper"

class BankFile::ImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @user = users(:empty)
  end

  test "preview stages immutable provenance and confirmation is idempotent" do
    service = build_import
    assert_no_difference "Entry.count" do
      @upload = service.stage!
    end
    assert_equal @user.id, @upload.summary.dig("bank_file", "actor_id")
    first = BankFile::Import.new(import: @upload, user: @user).commit!
    assert_equal 1, first[:created]
    assert_no_difference "Entry.count" do
      again = BankFile::Import.new(import: @upload.reload, user: @user).commit!
      assert_equal first[:created], again[:created]
    end
    link = BankFile::AccountLink.find_by!(family: @family, entity: "personal")
    assert_not link.balance_verified
    assert link.account.exclude_from_reports
    assert_equal 0, link.account.balance
  end

  test "overlapping exports deduplicate by bank identity and survive account rename" do
    commit(build_import)
    link = BankFile::AccountLink.find_by!(family: @family, entity: "personal")
    link.account.update!(name: "Renamed by the owner")
    result = nil
    assert_no_difference [ "Entry.count", "Account.count" ] do
      result = commit(build_import)
    end
    assert_equal 1, result[:duplicates]
    assert_equal 0, result[:created]
  end

  test "same bank ID in personal and company files is scoped to separate accounts" do
    commit(build_import)
    assert_difference "BankFile::AccountLink.count", 1 do
      result = commit(build_import(entity: "business", owner_name: "Example Company"))
      assert_equal 1, result[:created]
    end
  end

  test "currency conversion is linked and fees remain spending" do
    row = history_row("Direction" => "NEUTRAL", "Target name" => "Example Person", "Source currency" => "GBP", "Source amount (after fees)" => "100", "Source fee amount" => "1", "Source fee currency" => "GBP", "Target amount (after fees)" => "45000")
    service = build_import(rows: [ row ])
    gbp = service.preview[:totals].find { |total| total[:currency] == "GBP" }
    assert_equal "1.0", gbp[:outflow]
    assert_difference "Transfer.count", 1 do
      assert_equal 3, commit(service)[:created]
    end
  end

  test "changed source values roll back the entire upload" do
    commit(build_import)
    service = build_import(rows: [ history_row("ID" => "NEW-2"), history_row("Source amount (after fees)" => "101") ])
    upload = service.stage!
    assert_no_difference "Entry.count" do
      assert_raises(BankFile::Error) { BankFile::Import.new(import: upload, user: @user).commit! }
    end
    assert upload.reload.pending?
  end

  test "later refunded-out conflict preserves the old record and reports review" do
    commit(build_import)
    rows = [ history_row("Status" => "REFUNDED"), history_row("ID" => "SECOND-2") ]
    result = commit(build_import(rows:))
    assert_equal 1, result[:review]
    assert result[:warnings].any? { |warning| warning.include?("previously imported") }
    assert BankFile::AccountLink.find_by!(family: @family, entity: "personal").needs_review
    assert_equal 100, @family.entries.find_by!(external_id: "TRANSFER-1:OUT:main").amount
  end

  test "wrong actor and another family cannot inspect a staged upload" do
    upload = build_import.stage!
    assert_raises(BankFile::Error) { BankFile::Import.new(import: upload, user: users(:sure_support_staff)) }
    assert_raises(BankFile::Error) { BankFile::Import.new(import: upload, user: users(:family_admin)) }
    assert_raises(BankFile::Error) { BankFile::Import.new(family: families(:dylan_family), user: @user, content: csv([ history_row ]), filename: "bank.csv", entity: "personal", owner_name: "Example") }
  end

  test "tampered staged bytes are refused before account or transaction creation" do
    upload = build_import.stage!
    upload.update!(raw_file_str: csv([ history_row("Source amount (after fees)" => "500") ]))
    assert_no_difference [ "Entry.count", "BankFile::AccountLink.count" ] do
      assert_raises(BankFile::Error) { BankFile::Import.new(import: upload, user: @user).commit! }
    end
  end

  test "an account with a live connection refuses CSV mutation" do
    commit(build_import)
    Account.any_instance.stubs(:linked?).returns(true)
    assert_no_difference "Entry.count" do
      assert_raises(BankFile::Error) { commit(build_import(rows: [ history_row("ID" => "NEW-3") ])) }
    end
  end

  private
    def build_import(rows: [ history_row ], entity: "personal", owner_name: "Example Person")
      BankFile::Import.new(family: @family, user: @user, content: csv(rows), filename: "synthetic-bank.csv", entity:, owner_name:)
    end

    def commit(service)
      upload = service.stage!
      BankFile::Import.new(import: upload, user: @user).commit!
    end

    def csv(rows)
      CSV.generate do |out|
        out << BankFile::Parser::WISE_HISTORY_HEADERS
        rows.each { |row| out << BankFile::Parser::WISE_HISTORY_HEADERS.map { |key| row[key] } }
      end
    end

    def history_row(overrides = {})
      { "ID" => "TRANSFER-1", "Status" => "COMPLETED", "Direction" => "OUT", "Created on" => "2026-01-02 10:00:00", "Finished on" => "2026-01-02 10:01:00",
        "Source fee amount" => "0", "Source fee currency" => "HUF", "Target fee amount" => "0", "Target fee currency" => "HUF",
        "Source name" => "Example Person", "Source amount (after fees)" => "100", "Source currency" => "HUF", "Target name" => "Example Merchant",
        "Target amount (after fees)" => "100", "Target currency" => "HUF" }.merge(overrides)
    end
end
