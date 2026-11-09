require "digest"

class BankFile::Import
  ENTITIES = %w[personal business].freeze
  VERSION = 1

  def initialize(family: nil, user:, content: nil, filename: nil, entity: nil, owner_name: nil, import: nil)
    @user = user
    @import = import
    if import
      @family = import.family
      metadata = import.summary["bank_file"]
      raise BankFile::Error, "This is not a bank-file upload." unless metadata.is_a?(Hash) && metadata["version"] == VERSION
      @content = import.raw_file_str.to_s
      @filename = metadata["filename"]
      @entity = metadata["entity"]
      @owner_name = metadata["owner_name"]
      @actor_id = metadata["actor_id"]
    else
      @family = family
      @content = content.to_s
      @filename = filename.to_s.tr("\\", "/").split("/").last.to_s.first(255)
      @entity = entity.to_s
      @owner_name = owner_name.to_s.strip.first(200)
    end
    authorize!
  end

  def preview
    result = parsed
    warnings = result.warnings.dup
    if result.review_count.positive?
      warnings << "#{result.review_count} outgoing refunded rows need review. They were not booked as spending or refunds; cashflow coverage is incomplete."
    end
    {
      format: result.format, bank: result.bank, row_count: result.row_count,
      transaction_count: result.rows.length, skipped_count: result.skipped_count,
      review_count: result.review_count, currencies: result.rows.map(&:currency).uniq.sort,
      date_from: result.rows.map(&:date).min&.iso8601, date_to: result.rows.map(&:date).max&.iso8601,
      totals: totals, warnings:, account_holder: result.account_holder,
      sample_rows: result.rows.first(12).map { |row| { date: row.date.iso8601, name: row.name, amount: row.amount.to_s("F"), currency: row.currency, kind: row.kind } }
    }
  end

  def stage!
    raise BankFile::Error, "This upload is already staged." if @import
    authorize!
    summary = preview
    @import = TransactionImport.create!(
      family: @family, raw_file_str: @content.dup.force_encoding(Encoding::UTF_8),
      checksum: checksum, rows_count: parsed.rows.length, date_format: "%Y-%m-%d", signage_convention: "inflows_negative",
      summary: { "bank_file" => { "version" => VERSION, "actor_id" => @user.id, "entity" => @entity,
        "owner_name" => @owner_name, "filename" => @filename, "format" => parsed.format, "bank" => parsed.bank,
        "account_holder" => parsed.account_holder, "preview" => summary } }
    )
    @actor_id = @user.id
    @import
  end

  def commit!
    raise BankFile::Error, "Preview the file before importing it." unless @import&.persisted?
    result = nil
    @family.with_lock do
      @import.lock!
      authorize!
      raise BankFile::Error, "The stored upload changed. Upload it again." unless ActiveSupport::SecurityUtils.secure_compare(checksum, @import.checksum.to_s)
      if @import.complete?
        result = @import.summary.fetch("bank_file").fetch("result").symbolize_keys
        next
      end
      raise BankFile::Error, "This upload is not ready to import." unless @import.pending? || @import.failed?

      @import.update!(status: :importing, error: nil)
      result = perform_import
      metadata = @import.summary.fetch("bank_file").merge("result" => result, "committed_at" => Time.current.iso8601)
      @import.update!(status: :complete, summary: @import.summary.merge("bank_file" => metadata))
    end
    result
  rescue BankFile::Error => error
    capture_failure(error)
    raise
  end

  private
    def authorize!
      unless @family&.persisted? && @user&.persisted? && @user.family_id == @family.id && !@user.guest?
        raise BankFile::Error, "You cannot import into this workspace."
      end
      if @actor_id && @actor_id != @user.id
        raise BankFile::Error, "Only the person who uploaded this file may open or import it."
      end
      raise BankFile::Error, "Choose personal or business finances." unless ENTITIES.include?(@entity)
      raise BankFile::Error, "Enter an account label." if @owner_name.blank?
    end

    def parsed
      @parsed ||= BankFile::Parser.new(content: @content).call
    end

    def checksum
      Digest::SHA256.hexdigest(@content.b)
    end

    def totals
      parsed.rows.group_by(&:currency).sort.map do |currency, rows|
        cashflow = rows.reject { |row| row.kind == "funds_movement" }
        inflow = -cashflow.select { |row| row.amount.negative? }.sum(0.to_d, &:amount)
        outflow = cashflow.select { |row| row.amount.positive? }.sum(0.to_d, &:amount)
        fees = rows.select { |row| row.metadata["fee"] }.sum(0.to_d, &:amount)
        transfer_movement = -rows.select { |row| row.kind == "funds_movement" }.sum(0.to_d, &:amount)
        { currency:, inflow: inflow.to_s("F"), outflow: outflow.to_s("F"), fees: fees.to_s("F"), transfers: transfer_movement.to_s("F"), net: (inflow - outflow).to_s("F") }
      end
    end

    def perform_import
      links = parsed.rows.map(&:currency).uniq.to_h { |code| [ code, resolve_account(code) ] }
      created = 0
      duplicates = 0
      imported_entries = {}

      parsed.rows.each do |row|
        link = links.fetch(row.currency)
        account = link.account
        existing = account.entries.find_by(source: source, external_id: row.external_id)
        if existing
          unless existing.amount == row.amount && existing.currency == row.currency && existing.date == row.date
            raise BankFile::Error, "An existing bank transaction differs from this export. Review the account statement before importing; no changes were made."
          end
          duplicates += 1
          imported_entries[[ row.currency, row.external_id ]] = existing
          next
        end

        transaction = Transaction.new(kind: row.kind,
          extra: { "bank_file" => row.metadata.merge("version" => VERSION, "bank" => parsed.bank, "format" => parsed.format,
            "entity" => @entity, "owner_name" => @owner_name, "upload_id" => @import.id, "checksum" => @import.checksum) })
        entry = account.entries.create!(entryable: transaction, date: row.date, amount: row.amount, currency: row.currency,
          name: row.name, notes: row.notes, source:, external_id: row.external_id, import: @import, import_locked: true)
        imported_entries[[ row.currency, row.external_id ]] = entry
        created += 1
      end

      link_conversions(imported_entries)
      warnings = preview[:warnings].dup
      conflicts = refunded_conflicts(links)
      warnings << "#{conflicts} previously imported payments now appear as outgoing refunded rows. Their earlier entries were preserved for review; cashflow is incomplete." if conflicts.positive?
      links.each_value do |link|
        dates = parsed.rows.select { |row| row.currency == link.currency }.map(&:date)
        link.update!(coverage_start_on: [ link.coverage_start_on, dates.min ].compact.min,
          coverage_end_on: [ link.coverage_end_on, dates.max ].compact.max,
          needs_review: link.needs_review || parsed.review_count.positive?,
          metadata: link.metadata.merge("last_import_id" => @import.id, "last_imported_at" => Time.current.iso8601,
            "formats" => (Array(link.metadata["formats"]) + [ parsed.format ]).uniq,
            "account_holder" => parsed.account_holder))
      end
      { created:, duplicates:, skipped: parsed.skipped_count, review: parsed.review_count, accounts: links.length, warnings: }
    end

    def resolve_account(currency)
      link = BankFile::AccountLink.find_by(family: @family, provider: parsed.bank, entity: @entity, currency:)
      if link
        unless @family.accounts.writable_by(@user).where(id: link.account_id).exists?
          raise BankFile::Error, "You do not have write access to the target account."
        end
        if link.account.linked?
          raise BankFile::Error, "This account now has a live bank connection. Reconcile its existing history before importing overlapping CSV data."
        end
        existing_holder = link.metadata["account_holder"]
        if existing_holder.present? && parsed.account_holder.present? && existing_holder != parsed.account_holder
          raise BankFile::Error, "This account label is already used for another account holder."
        end
        formats = Array(link.metadata["formats"])
        if formats.any? && !formats.include?(parsed.format)
          raise BankFile::Error, "This account already contains another export format. Reconcile the histories before switching formats; mixing them can duplicate transactions."
        end
        return link
      end

      account = @family.accounts.create!(owner: @user, name: "#{parsed.bank.capitalize} · #{@owner_name} · #{currency}",
        currency:, balance: 0, cash_balance: 0, accountable: Depository.new(subtype: "checking"),
        institution_name: parsed.bank.capitalize, exclude_from_reports: true,
        notes: "Imported transaction history only. Current balance is unverified; excluded from net-worth reports.")
      BankFile::AccountLink.create!(family: @family, account:, provider: parsed.bank, entity: @entity,
        currency:, owner_name: @owner_name, balance_verified: false,
        metadata: { "formats" => [ parsed.format ], "account_holder" => parsed.account_holder })
    end

    def link_conversions(imported_entries)
      parsed.rows.select(&:transfer_key).group_by(&:transfer_key).each_value do |rows|
        outflow = rows.find { |row| row.amount.positive? }
        inflow = rows.find { |row| row.amount.negative? }
        next unless outflow && inflow
        out_entry = imported_entries.fetch([ outflow.currency, outflow.external_id ])
        in_entry = imported_entries.fetch([ inflow.currency, inflow.external_id ])
        next if out_entry.transaction.transfer_as_outflow || in_entry.transaction.transfer_as_inflow
        Transfer.create!(outflow_transaction: out_entry.transaction, inflow_transaction: in_entry.transaction,
          amount: inflow.amount.abs, status: :confirmed, notes: "Currency conversion explicitly identified by the bank export.")
      end
    end

    def refunded_conflicts(links)
      parsed.review_records.count do |record|
        account = links[record["currency"]]&.account || BankFile::AccountLink.find_by(family: @family, provider: parsed.bank, entity: @entity, currency: record["currency"])&.account
        account&.entries&.exists?(source:, external_id: record["external_id"])
      end
    end

    def source
      "bank_file_#{parsed.format}"
    end

    def capture_failure(error)
      return unless @family && @user && @user.family_id == @family.id
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Bank file import needs review",
        source: self.class.name, family: @family, provider_key: "bank_file",
        metadata: { import_id: @import&.id, error_class: error.class.name })
    end
end
