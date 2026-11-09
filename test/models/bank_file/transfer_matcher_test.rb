require "test_helper"

class BankFile::TransferMatcherTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @user = users(:empty)
  end

  test "second import matches exact company-to-personal principal without spending the fee" do
    first = import_transfer(direction: "OUT", entity: "business", fee: "1")
    assert_equal 0, first[:matched_transfers]
    result = nil
    assert_difference "Transfer.count", 1 do
      result = import_transfer(direction: "IN", entity: "personal")
    end
    assert_equal 1, result[:matched_transfers]
    outflow = entry("OUT")
    inflow = entry("IN")
    assert_equal "funds_movement", outflow.transaction.kind
    assert_equal "funds_movement", inflow.transaction.kind
    assert outflow.transaction.transfer.confirmed?
    assert_equal inflow.transaction.transfer, outflow.transaction.transfer
    assert_equal "General", outflow.transaction.category.name
    fee = @family.entries.find_by!(source: "bank_file_wise_history", external_id: "TRANSFER-EXACT:OUT:fee")
    assert_equal "standard", fee.transaction.kind
    assert_equal "Bank fees", fee.transaction.category.name
    assert_nil fee.transaction.transfer

    assert_no_difference "Transfer.count" do
      assert_equal 0, import_transfer(direction: "IN", entity: "personal")[:matched_transfers]
    end
  end

  test "different principal amounts stay ordinary transactions" do
    import_transfer(direction: "OUT", entity: "business")
    assert_no_difference "Transfer.count" do
      assert_equal 0, import_transfer(direction: "IN", entity: "personal", amount: "99")[:matched_transfers]
    end
    assert_equal "standard", entry("OUT").transaction.kind
    assert_equal "standard", entry("IN").transaction.kind
  end

  test "an unrelated source holder is never matched even with the same bank ID and amount" do
    import_transfer(direction: "OUT", entity: "business")
    assert_no_difference "Transfer.count" do
      assert_equal 0, import_transfer(direction: "IN", entity: "personal", source_name: "Unrelated Company")[:matched_transfers]
    end
    assert_nil entry("OUT").transaction.transfer
    assert_nil entry("IN").transaction.transfer
  end

  test "an inaccessible counterpart account is not mutated" do
    import_transfer(direction: "OUT", entity: "business", user: users(:sure_support_staff))
    outflow = entry("OUT")
    assert_not @family.accounts.writable_by(@user).exists?(id: outflow.account_id)
    assert_no_difference "Transfer.count" do
      assert_equal 0, import_transfer(direction: "IN", entity: "personal")[:matched_transfers]
    end
    assert_equal "standard", outflow.transaction.reload.kind
    assert_nil outflow.transaction.transfer
  end

  test "rejected exact matches remain rejected on later imports" do
    import_transfer(direction: "OUT", entity: "business")
    import_transfer(direction: "IN", entity: "personal")
    entry("OUT").transaction.transfer.reject!
    assert_no_difference "Transfer.count" do
      assert_equal 0, import_transfer(direction: "IN", entity: "personal")[:matched_transfers]
    end
    assert_equal "standard", entry("OUT").transaction.kind
  end

  test "exact IDs more than thirty days apart are not matched" do
    import_transfer(direction: "OUT", entity: "business")
    assert_no_difference "Transfer.count" do
      assert_equal 0, import_transfer(direction: "IN", entity: "personal", date: "2026-03-01 10:01:00")[:matched_transfers]
    end
  end

  private
    def entry(direction)
      @family.entries.find_by!(source: "bank_file_wise_history", external_id: "TRANSFER-EXACT:#{direction}:main")
    end

    def import_transfer(direction:, entity:, amount: "100", fee: "0", source_name: "Example Company", date: "2026-01-02 10:01:00", user: @user)
      row = { "ID" => "TRANSFER-EXACT", "Status" => "COMPLETED", "Direction" => direction,
        "Created on" => date, "Finished on" => date, "Source fee amount" => fee, "Source fee currency" => "HUF",
        "Target fee amount" => "0", "Target fee currency" => "HUF", "Source name" => source_name,
        "Source amount (after fees)" => amount, "Source currency" => "HUF", "Target name" => "Example Person",
        "Target amount (after fees)" => amount, "Target currency" => "HUF", "Category" => "General" }
      headers = BankFile::Parser::WISE_HISTORY_HEADERS + [ "Category" ]
      content = CSV.generate { |csv| csv << headers; csv << headers.map { |key| row[key] } }
      service = BankFile::Import.new(family: @family, user:, content:, filename: "synthetic-transfer.csv",
        entity:, owner_name: entity == "business" ? "Example Company" : "Example Person")
      upload = service.stage!
      BankFile::Import.new(import: upload, user:).commit!
    end
end
