require "csv"
require "bigdecimal"
require "digest"
require "date"

class BankFile::Parser
  MAX_BYTES = 10.megabytes
  MAX_ROWS = 10_000
  WISE_HISTORY_HEADERS = [ "ID", "Status", "Direction", "Created on", "Finished on", "Source fee amount", "Source fee currency", "Target fee amount", "Target fee currency", "Source name", "Source amount (after fees)", "Source currency", "Target name", "Target amount (after fees)", "Target currency" ].freeze
  WISE_STATEMENT_HEADERS = [ "TransferWise ID", "Date", "Amount", "Currency", "Description" ].freeze
  REVOLUT_HEADERS = [ "Type", "Started Date", "Completed Date", "Description", "Amount", "Fee", "Currency", "State" ].freeze

  Row = Struct.new(:external_id, :source_id, :date, :amount, :currency, :name, :notes, :kind, :metadata, :transfer_key, keyword_init: true)
  Result = Struct.new(:format, :bank, :rows, :row_count, :skipped_count, :review_count, :warnings, :review_records, :account_holder, keyword_init: true)

  def initialize(content:)
    @content = content.to_s.dup
    @rows = []
    @warnings = []
    @review_records = []
    @skipped_count = 0
    @seen = {}
    @occurrences = Hash.new(0)
    @holders = []
  end

  def call
    raise BankFile::Error, "The file is empty." if @content.empty?
    raise BankFile::Error, "Choose a CSV smaller than 10 MB." if @content.bytesize > MAX_BYTES

    @content.force_encoding(Encoding::UTF_8)
    raise BankFile::Error, "Save the export as UTF-8 CSV before importing it." unless @content.valid_encoding?
    @content.delete_prefix!("\uFEFF")

    table = read_table
    headers = table.headers.compact
    raise BankFile::Error, "The CSV contains repeated column names." if headers.uniq.length != headers.length
    @format, @bank = detect_format(headers)
    raise BankFile::Error, "The CSV has no transactions." if table.empty?
    raise BankFile::Error, "Import at most 10,000 source rows at a time." if table.length > MAX_ROWS

    table.each_with_index do |row, index|
      @row_number = index + 2
      case @format
      when "wise_history" then parse_wise_history(row)
      when "wise_statement" then parse_wise_statement(row)
      when "revolut" then parse_revolut(row)
      end
    end

    holders = @holders.reject(&:blank?).map(&:strip).uniq
    raise BankFile::Error, "This file contains more than one account holder. Import separate account exports." if holders.length > 1

    @warnings << "Transaction history does not prove your current balance. These accounts are excluded from net-worth reports until balances are verified."
    @warnings << "Dates without an explicit timezone are kept on the calendar date printed in the export."
    if @format == "revolut" && @used_fingerprint
      @warnings << "This Revolut export has no transaction IDs. Identical rows are counted separately; overlapping imports use their full row fingerprint and occurrence count."
    end
    Result.new(format: @format, bank: @bank, rows: @rows, row_count: table.length, skipped_count: @skipped_count,
      review_count: @review_records.length, warnings: @warnings.uniq, review_records: @review_records, account_holder: holders.first)
  rescue CSV::MalformedCSVError
    raise BankFile::Error, "The CSV is malformed. Export it again without editing its columns."
  end

  private
    def read_table
      separators = [ ",", ";" ]
      separators.each do |separator|
        table = CSV.parse(@content, headers: true, col_sep: separator, skip_blanks: true)
        return table if recognized_headers?(table.headers)
      rescue CSV::MalformedCSVError
        next
      end
      raise BankFile::Error, "Unsupported bank file. Use an English Wise transaction-history or currency-statement CSV, or a Revolut account CSV. Excel workbooks need to be saved as CSV first."
    end

    def recognized_headers?(headers)
      [ WISE_HISTORY_HEADERS, WISE_STATEMENT_HEADERS, REVOLUT_HEADERS ].any? { |required| (required - headers).empty? }
    end

    def detect_format(headers)
      return [ "wise_history", "wise" ] if (WISE_HISTORY_HEADERS - headers).empty?
      return [ "wise_statement", "wise" ] if (WISE_STATEMENT_HEADERS - headers).empty?
      return [ "revolut", "revolut" ] if (REVOLUT_HEADERS - headers).empty?
      raise BankFile::Error, "Unsupported CSV columns."
    end

    def parse_wise_history(row)
      id = required(row, "ID")
      status = required(row, "Status").upcase
      direction = required(row, "Direction").upcase
      raise BankFile::Error, "Row #{@row_number}: unknown transaction direction." unless %w[IN OUT NEUTRAL].include?(direction)

      source_currency = currency(row["Source currency"])
      target_currency = currency(row["Target currency"])
      source_amount = decimal(row["Source amount (after fees)"])
      target_amount = decimal(row["Target amount (after fees)"])
      raise BankFile::Error, "Row #{@row_number}: Wise history amounts must be non-negative." if source_amount.negative? || target_amount.negative?

      holder = direction == "IN" ? row["Target name"] : row["Source name"]
      @holders << holder
      if status == "REFUNDED" && direction == "OUT"
        @skipped_count += 1
        if source_amount.positive?
          @review_records << { "source_id" => id, "currency" => source_currency, "reason" => "refunded_out", "external_id" => "#{id}:OUT:main" }
        end
        return
      end
      unless status == "COMPLETED" || (status == "REFUNDED" && direction == "IN")
        @skipped_count += 1
        @warnings << "Unsettled or cancelled rows were skipped."
        return
      end
      if source_amount.zero? && target_amount.zero?
        @skipped_count += 1
        return
      end

      date = parse_date(row["Finished on"].presence || row["Created on"], iso_only: true)
      source_fee = decimal(row["Source fee amount"], blank_zero: true)
      target_fee = decimal(row["Target fee amount"], blank_zero: true)
      raise BankFile::Error, "Row #{@row_number}: a fee cannot be negative." if source_fee.negative? || target_fee.negative?
      source_fee_currency = source_fee.positive? ? currency(row["Source fee currency"]) : source_currency
      target_fee_currency = target_fee.positive? ? currency(row["Target fee currency"]) : target_currency
      metadata = {
        "source_id" => id, "status" => status, "direction" => direction,
        "source_name" => row["Source name"].to_s, "target_name" => row["Target name"].to_s,
        "source_amount" => source_amount.to_s("F"), "source_currency" => source_currency,
        "target_amount" => target_amount.to_s("F"), "target_currency" => target_currency,
        "source_fee" => source_fee.to_s("F"), "target_fee" => target_fee.to_s("F"),
        "exchange_rate" => row["Exchange rate"].to_s, "created_on" => row["Created on"].to_s,
        "finished_on" => row["Finished on"].to_s, "category" => row["Category"].to_s
      }
      notes = [ row["Reference"], row["Note"] ].compact_blank.join(" · ")

      case direction
      when "OUT"
        add_row(id:, suffix: "OUT:main", date:, amount: source_amount, currency: source_currency,
          name: row["Target name"].presence || "Wise payment", notes:, kind: "standard", metadata:)
        add_fee(id:, suffix: "OUT:fee", date:, amount: source_fee, currency: source_fee_currency, metadata:)
      when "IN"
        if target_fee.positive? && target_fee_currency != target_currency
          raise BankFile::Error, "Row #{@row_number}: incoming fee currency needs statement-level reconciliation."
        end
        add_row(id:, suffix: "IN:main", date:, amount: -(target_amount + target_fee), currency: target_currency,
          name: row["Source name"].presence || "Wise receipt", notes:, kind: "standard", metadata:)
        add_fee(id:, suffix: "IN:fee", date:, amount: target_fee, currency: target_currency, metadata:)
      when "NEUTRAL"
        unless normalized_name(row["Source name"]) == normalized_name(row["Target name"]) && source_currency != target_currency
          raise BankFile::Error, "Row #{@row_number}: unsupported neutral movement; use currency statements for this movement."
        end
        add_row(id:, suffix: "FX:out", date:, amount: source_amount, currency: source_currency,
          name: "Wise conversion #{source_currency} → #{target_currency}", notes:, kind: "funds_movement", metadata:, transfer_key: id)
        add_row(id:, suffix: "FX:in", date:, amount: -(target_amount + target_fee), currency: target_currency,
          name: "Wise conversion #{source_currency} → #{target_currency}", notes:, kind: "funds_movement", metadata:, transfer_key: id)
        add_fee(id:, suffix: "FX:fee", date:, amount: source_fee, currency: source_fee_currency, metadata:)
        add_fee(id:, suffix: "FX:target_fee", date:, amount: target_fee, currency: target_fee_currency, metadata:)
      end
    end

    def parse_wise_statement(row)
      id = required(row, "TransferWise ID")
      date = parse_date(required(row, "Date"))
      amount = decimal(row["Amount"])
      code = currency(row["Currency"])
      fee = decimal(row["Total fees"], blank_zero: true)
      raise BankFile::Error, "Row #{@row_number}: statement fee cannot be negative." if fee.negative?
      if amount.zero?
        @skipped_count += 1
        return
      end
      # Statement debits include their fees. A credit is already the net receipt.
      booked_fee = amount.negative? ? fee : 0.to_d
      raise BankFile::Error, "Row #{@row_number}: the fee exceeds the statement debit." if booked_fee > amount.abs
      amount_for_entry = amount.negative? ? amount.abs - booked_fee : -amount
      type = row["Transaction type"].to_s.upcase
      is_exchange = id.start_with?("BALANCE_TRANSACTION-") || type == "CONVERSION"
      metadata = { "source_id" => id, "statement_type" => type, "statement_fee" => fee.to_s("F"), "direction" => amount.negative? ? "OUT" : "IN" }
      # A refund can reuse the original reference; direction and timestamp keep it distinct.
      identity = "#{id}:#{amount.negative? ? 'OUT' : 'IN'}:#{required(row, 'Date')}"
      add_row(id:, identity:, suffix: "main", date:, amount: amount_for_entry, currency: code,
        name: row["Description"].presence || "Wise transaction", notes: row["Payment Reference"].to_s,
        kind: is_exchange ? "funds_movement" : "standard", metadata:)
      add_fee(id:, identity:, suffix: "fee", date:, amount: booked_fee, currency: code, metadata:)
    end

    def parse_revolut(row)
      status = required(row, "State").upcase
      unless status == "COMPLETED"
        @skipped_count += 1
        @warnings << "Revolut pending, reverted or declined rows were skipped."
        return
      end
      date = parse_date(row["Completed Date"].presence || row["Started Date"], iso_only: true)
      amount = decimal(row["Amount"])
      fee = decimal(row["Fee"], blank_zero: true)
      code = currency(row["Currency"])
      raise BankFile::Error, "Row #{@row_number}: a Revolut fee cannot be negative." if fee.negative?
      id = row["ID"].presence || row["Transaction ID"].presence
      unless id
        @used_fingerprint = true
        signature = Digest::SHA256.hexdigest([ row["Type"], row["Product"], row["Started Date"], row["Completed Date"], row["Description"], amount.to_s("F"), fee.to_s("F"), code, row["Balance"] ].to_json)
        @occurrences[signature] += 1
        id = "fingerprint:#{signature}:#{@occurrences[signature]}"
      end
      type = row["Type"].to_s.upcase
      metadata = { "source_id" => id, "status" => status, "type" => type, "started_on" => row["Started Date"].to_s, "finished_on" => row["Completed Date"].to_s, "fingerprint_id" => id.start_with?("fingerprint:") }
      kind = type == "EXCHANGE" ? "funds_movement" : "standard"
      add_row(id:, suffix: "main", date:, amount: -amount, currency: code, name: row["Description"].presence || "Revolut transaction", notes: "", kind:, metadata:)
      add_fee(id:, suffix: "fee", date:, amount: fee, currency: code, metadata:)
    end

    def add_fee(id:, suffix:, date:, amount:, currency:, metadata:, identity: nil)
      return if amount.zero?
      add_row(id:, identity:, suffix:, date:, amount:, currency:, name: "#{@bank.capitalize} fee", notes: "", kind: "standard", metadata: metadata.merge("fee" => true))
    end

    def add_row(id:, suffix:, date:, amount:, currency:, name:, notes:, kind:, metadata:, transfer_key: nil, identity: nil)
      return if amount.zero?
      external_id = "#{identity || id}:#{suffix}"
      key = [ currency, external_id ]
      signature = [ amount.to_s("F"), date.iso8601, kind ]
      if @seen.key?(key)
        raise BankFile::Error, "Row #{@row_number}: the same bank ID has conflicting values within one currency. Review a currency statement." unless @seen[key] == signature
        @skipped_count += 1
        @warnings << "Repeated identical bank IDs within the file were imported once."
        return
      end
      @seen[key] = signature
      @rows << Row.new(external_id:, source_id: id, date:, amount:, currency:, name: name.to_s.strip,
        notes:, kind:, metadata: metadata.merge("source_row" => @row_number), transfer_key:)
    end

    def decimal(raw, blank_zero: false)
      value = raw.to_s.strip
      return BigDecimal("0") if blank_zero && value.empty?
      raise BankFile::Error, "Row #{@row_number}: an amount is not a plain decimal number." unless value.match?(/\A-?\d+(?:\.\d+)?\z/)
      number = BigDecimal(value)
      raise BankFile::Error, "Row #{@row_number}: an amount exceeds the supported precision." if number.abs >= BigDecimal("1000000000000000") || number.frac != number.frac.round(4)
      number
    end

    def currency(raw)
      value = raw.to_s.strip.upcase
      raise BankFile::Error, "Row #{@row_number}: invalid currency code." unless value.match?(/\A[A-Z]{3}\z/) && Money::Currency.new(value).iso_code == value
      value
    rescue ArgumentError
      raise BankFile::Error, "Row #{@row_number}: unsupported currency code."
    end

    def required(row, key)
      value = row[key].to_s.strip
      raise BankFile::Error, "Row #{@row_number}: #{key} is missing." if value.empty?
      value
    end

    def parse_date(raw, iso_only: false)
      value = raw.to_s.strip
      if value.match?(/\A\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?\z/)
        date = Date.iso8601(value.first(10))
      elsif !iso_only && value.match?(/\A\d{2}-\d{2}-\d{4}\z/)
        date = Date.strptime(value, "%d-%m-%Y")
      elsif !iso_only && value.match?(/\A\d{2}\/\d{2}\/\d{4}(?: \d{2}:\d{2}:\d{2})?\z/)
        date = Date.strptime(value.first(10), "%d/%m/%Y")
      else
        raise BankFile::Error, "Row #{@row_number}: use an ISO date or a Wise day/month/year statement date."
      end
      raise BankFile::Error, "Row #{@row_number}: transaction date is outside the supported range." unless (Date.new(1970, 1, 2)..Date.current).cover?(date)
      date
    rescue Date::Error
      raise BankFile::Error, "Row #{@row_number}: invalid transaction date."
    end

    def normalized_name(value)
      value.to_s.unicode_normalize(:nfkc).strip.downcase.gsub(/\s+/, " ")
    end
end
