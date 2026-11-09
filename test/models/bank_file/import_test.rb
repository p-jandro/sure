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

  test "refunds share the expense category and are an informational cash-in subset" do
    rows = [
      history_row("Category" => "Shopping", "Source fee amount" => "1"),
      history_row("ID" => "REFUND-2", "Status" => "REFUNDED", "Direction" => "IN", "Source name" => "Example Merchant", "Target name" => "Example Person", "Target amount (after fees)" => "25", "Category" => "Shopping"),
      history_row("ID" => "INCOME-3", "Direction" => "IN", "Source name" => "Example Client", "Target name" => "Example Person", "Target amount (after fees)" => "200", "Category" => "General")
    ]
    service = build_import(rows:)
    summary = service.preview
    totals = summary[:totals].first
    assert_equal "225.0", totals[:inflow]
    assert_equal "101.0", totals[:outflow]
    assert_equal "25.0", totals[:refunds]
    assert_equal "124.0", totals[:net]
    assert_equal [ "standard", "fee", "refund", "standard" ], summary[:sample_rows].map { |row| row[:kind] }

    commit(service)
    entries = @family.entries.where(source: "bank_file_wise_history").index_by(&:external_id)
    expense = entries.fetch("TRANSFER-1:OUT:main")
    refund = entries.fetch("REFUND-2:IN:main")
    assert_equal expense.transaction.category_id, refund.transaction.category_id
    assert_equal "Shopping", refund.transaction.category.name
    assert_equal 75, expense.amount + refund.amount
    assert_equal "Bank fees", entries.fetch("TRANSFER-1:OUT:fee").transaction.category.name
    assert_equal "Income · General", entries.fetch("INCOME-3:IN:main").transaction.category.name

    personal_category = @family.categories.create!(name: "My edited category", color: Category::COLORS.first, lucide_icon: "home")
    expense.transaction.update!(category: personal_category)
    commit(build_import(rows:))
    assert_equal personal_category, expense.transaction.reload.category
  end

  test "different overlapping ID-less Revolut export requires review but exact replay is safe" do
    header = "Type,Started Date,Completed Date,Description,Amount,Fee,Currency,State\n"
    row = "CARD_PAYMENT,2026-01-02 12:00:00,2026-01-02 12:00:00,Cafe,-4.50,0,EUR,COMPLETED\n"
    original = header + row
    build = ->(content) { BankFile::Import.new(family: @family, user: @user, content:, filename: "revolut.csv", entity: "personal", owner_name: "Example Person") }
    commit(build.call(original))
    assert_no_difference "Entry.count" do
      assert_equal 1, commit(build.call(original))[:duplicates]
      assert_raises(BankFile::Error) { commit(build.call(original.sub("Cafe", "Edited bank description"))) }
    end
  end

  test "existing upload requires its actor even if the metadata actor was removed" do
    upload = build_import.stage!
    metadata = upload.summary.deep_dup
    metadata.fetch("bank_file").delete("actor_id")
    upload.update!(summary: metadata)
    assert_raises(BankFile::Error) { BankFile::Import.new(import: upload, user: @user) }
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
        headers = BankFile::Parser::WISE_HISTORY_HEADERS + [ "Category" ]
        out << headers
        rows.each { |row| out << headers.map { |key| row[key] } }
      end
    end

    def history_row(overrides = {})
      { "ID" => "TRANSFER-1", "Status" => "COMPLETED", "Direction" => "OUT", "Created on" => "2026-01-02 10:00:00", "Finished on" => "2026-01-02 10:01:00",
        "Source fee amount" => "0", "Source fee currency" => "HUF", "Target fee amount" => "0", "Target fee currency" => "HUF",
        "Source name" => "Example Person", "Source amount (after fees)" => "100", "Source currency" => "HUF", "Target name" => "Example Merchant",
        "Target amount (after fees)" => "100", "Target currency" => "HUF" }.merge(overrides)
    end
end
