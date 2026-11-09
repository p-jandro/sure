require "test_helper"

class BankFile::ParserTest < ActiveSupport::TestCase
  test "Wise split-funded purchase keeps each currency leg and its fee" do
    result = parse_history([
      history_row("ID" => "CARD_TRANSACTION-1", "Source currency" => "USD", "Source amount (after fees)" => "10.25", "Source fee amount" => "0.10", "Source fee currency" => "USD"),
      history_row("ID" => "CARD_TRANSACTION-1", "Source currency" => "HUF", "Source amount (after fees)" => "2000")
    ])

    assert_equal 3, result.rows.length
    assert_equal [ "USD", "USD", "HUF" ], result.rows.map(&:currency)
    assert_equal [ BigDecimal("10.25"), BigDecimal("0.10"), BigDecimal("2000") ], result.rows.map(&:amount)
    assert result.rows.second.metadata["fee"]
  end

  test "Wise conversion produces two transfer legs and a separate real fee" do
    result = parse_history([ history_row("Direction" => "NEUTRAL", "Target name" => "Example Person", "Source currency" => "GBP", "Source amount (after fees)" => "100", "Target amount (after fees)" => "45000", "Source fee amount" => "1", "Source fee currency" => "GBP") ])

    assert_equal [ "funds_movement", "funds_movement", "standard" ], result.rows.map(&:kind)
    assert_equal [ BigDecimal("100"), BigDecimal("-45000"), BigDecimal("1") ], result.rows.map(&:amount)
    assert_equal 2, result.rows.count(&:transfer_key)
  end

  test "own-account receipts and payments are movements but fees remain spending" do
    result = parse_history([
      history_row("ID" => "OWN-1", "Target name" => "  EXAMPLE PERSON  ", "Source fee amount" => "1"),
      history_row("ID" => "OWN-2", "Direction" => "IN", "Target name" => "Example Person")
    ])
    assert_equal [ "funds_movement", "standard", "funds_movement" ], result.rows.map(&:kind)
    assert result.rows.first.metadata["internal_transfer"]
  end

  test "conversion fees in another currency are not added to the target amount" do
    row = history_row("Direction" => "NEUTRAL", "Target name" => "Example Person", "Source currency" => "GBP", "Target fee amount" => "2", "Target fee currency" => "EUR")
    assert_raises(BankFile::Error) { parse_history([ row ]) }
  end

  test "actual refund credits import but outgoing refunded amounts require review" do
    result = parse_history([
      history_row("ID" => "REFUND-1", "Direction" => "IN", "Status" => "REFUNDED", "Source name" => "Merchant", "Target name" => "Example Person", "Target amount (after fees)" => "25"),
      history_row("ID" => "CANCEL-1", "Status" => "REFUNDED", "Source amount (after fees)" => "25"),
      history_row("ID" => "CANCEL-2", "Status" => "REFUNDED", "Source amount (after fees)" => "0", "Target amount (after fees)" => "0")
    ])

    assert_equal 1, result.rows.length
    assert_equal BigDecimal("-25"), result.rows.first.amount
    assert_equal 2, result.skipped_count
    assert_equal 1, result.review_count
  end

  test "ambiguous currency-scoped Wise IDs fail instead of dropping a purchase" do
    assert_raises(BankFile::Error) do
      parse_history([ history_row, history_row("Source amount (after fees)" => "101") ])
    end
  end

  test "plain decimals retain precision and reject locale guesses" do
    result = parse_history([ history_row("Source amount (after fees)" => "100.1250") ])
    assert_equal BigDecimal("100.125"), result.rows.first.amount
    [ "1,25", "1e3", "NaN", "-2", "1.12345" ].each do |amount|
      assert_raises(BankFile::Error) { parse_history([ history_row("Source amount (after fees)" => amount) ]) }
    end
  end

  test "BOM and semicolon exports preserve dates printed by the bank" do
    csv = "\uFEFF" + CSV.generate(col_sep: ";") do |out|
      out << BankFile::Parser::WISE_HISTORY_HEADERS
      row = history_row("Finished on" => "2026-03-29 00:15:00")
      out << BankFile::Parser::WISE_HISTORY_HEADERS.map { |key| row[key] }
    end
    result = BankFile::Parser.new(content: csv).call
    assert_equal Date.new(2026, 3, 29), result.rows.first.date
  end

  test "statement debit fees are split without changing the movement" do
    csv = "TransferWise ID,Date,Amount,Currency,Description,Total fees\nTRANSFER-5,02/01/2026,-101.50,EUR,Example payment,1.50\n"
    result = BankFile::Parser.new(content: csv).call
    assert_equal "wise_statement", result.format
    assert_equal [ BigDecimal("100"), BigDecimal("1.50") ], result.rows.map(&:amount)
    assert_equal Date.new(2026, 1, 2), result.rows.first.date
  end

  test "Wise statement identity does not change with its supported date format" do
    csv = "TransferWise ID,Date,Amount,Currency,Description\nTRANSFER-5,02/01/2026,-100,EUR,Example payment\n"
    first = BankFile::Parser.new(content: csv).call
    second = BankFile::Parser.new(content: csv.sub("02/01/2026", "2026-01-02")).call
    assert_equal first.rows.first.external_id, second.rows.first.external_id
  end

  test "Revolut identical purchases without IDs remain two purchases" do
    row = "CARD_PAYMENT,2026-01-02 12:00:00,2026-01-02 12:00:00,Cafe,-4.50,0,EUR,COMPLETED\n"
    csv = "Type,Started Date,Completed Date,Description,Amount,Fee,Currency,State\n" + row + row
    first = BankFile::Parser.new(content: csv).call
    second = BankFile::Parser.new(content: csv).call
    assert_equal 2, first.rows.length
    assert_equal 2, first.rows.map(&:external_id).uniq.length
    assert_equal first.rows.map(&:external_id), second.rows.map(&:external_id)
  end

  test "pending rows and empty authorizations do not become expenses" do
    result = parse_history([ history_row("Status" => "PENDING"), history_row("ID" => "ZERO-2", "Source amount (after fees)" => "0", "Target amount (after fees)" => "0") ])
    assert_empty result.rows
    assert_equal 2, result.skipped_count
  end

  test "Revolut fee rows are held for review instead of guessing the balance impact" do
    csv = "Type,Started Date,Completed Date,Description,Amount,Fee,Currency,State\nCARD_PAYMENT,2026-01-02 12:00:00,2026-01-02 12:00:00,Cafe,-4.50,0.50,EUR,COMPLETED\n"
    result = BankFile::Parser.new(content: csv).call
    assert_empty result.rows
    assert_equal 1, result.review_count
    assert_equal 1, result.skipped_count
  end

  test "invalid dates currencies and duplicate column names are rejected" do
    assert_raises(BankFile::Error) { parse_history([ history_row("Finished on" => "2026-02-31 00:00:00") ]) }
    assert_raises(BankFile::Error) { parse_history([ history_row("Source currency" => "XYZ") ]) }
    csv = CSV.generate do |out|
      out << BankFile::Parser::WISE_HISTORY_HEADERS + [ "ID" ]
      out << BankFile::Parser::WISE_HISTORY_HEADERS.map { |key| history_row[key] } + [ "SECOND" ]
    end
    assert_raises(BankFile::Error) { BankFile::Parser.new(content: csv).call }
  end

  private
    def parse_history(rows)
      csv = CSV.generate do |out|
        out << BankFile::Parser::WISE_HISTORY_HEADERS
        rows.each { |row| out << BankFile::Parser::WISE_HISTORY_HEADERS.map { |key| row[key] } }
      end
      BankFile::Parser.new(content: csv).call
    end

    def history_row(overrides = {})
      { "ID" => "TRANSFER-1", "Status" => "COMPLETED", "Direction" => "OUT", "Created on" => "2026-01-02 10:00:00", "Finished on" => "2026-01-02 10:01:00",
        "Source fee amount" => "0", "Source fee currency" => "HUF", "Target fee amount" => "0", "Target fee currency" => "HUF",
        "Source name" => "Example Person", "Source amount (after fees)" => "100", "Source currency" => "HUF", "Target name" => "Example Merchant",
        "Target amount (after fees)" => "100", "Target currency" => "HUF" }.merge(overrides)
    end
end
