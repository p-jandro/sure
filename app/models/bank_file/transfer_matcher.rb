class BankFile::TransferMatcher
  MAX_SOURCE_IDS = 10_000

  def initialize(family:, user:)
    @family = family
    @user = user
  end

  def match!(source_ids:)
    unless @family&.persisted? && @user&.persisted? && @user.family_id == @family.id && @user.active? && !@user.guest?
      raise BankFile::Error, "You cannot reconcile transfers in this workspace."
    end
    ids = Array(source_ids).map(&:to_s).reject(&:blank?).uniq
    raise BankFile::Error, "Reconcile at most 10,000 bank IDs at a time." if ids.length > MAX_SOURCE_IDS
    return 0 if ids.empty?

    @family.with_lock { match_entries(ids) }
  end

  private
    def match_entries(source_ids)
      writable = @family.accounts.writable_by(@user).select(:id)
      links = BankFile::AccountLink.where(family: @family, provider: "wise", account_id: writable)
        .includes(:account).index_by(&:account_id)
      return 0 if links.size < 2

      entries = @family.entries.where(account_id: links.keys, source: "bank_file_wise_history",
        entryable_type: "Transaction", excluded: false, user_modified: false, parent_entry_id: nil)
        .joins("INNER JOIN transactions bank_transactions ON bank_transactions.id = entries.entryable_id")
        .where("bank_transactions.extra -> 'bank_file' ->> 'source_id' IN (?)", source_ids)
        .includes(entryable: [ :transfer_as_inflow, :transfer_as_outflow ]).to_a

      entries.select { |entry| eligible?(entry) }
        .group_by { |entry| [ metadata(entry)["source_id"], entry.currency ] }
        .count do |_key, candidates|
          next false unless candidates.length == 2
          outflow = candidates.find { |entry| entry.amount.positive? && metadata(entry)["direction"] == "OUT" }
          inflow = candidates.find { |entry| entry.amount.negative? && metadata(entry)["direction"] == "IN" }
          next false unless exact_pair?(outflow, inflow, links)
          next false if RejectedTransfer.exists?(outflow_transaction_id: outflow.entryable_id, inflow_transaction_id: inflow.entryable_id)

          # Keep original categories so rejecting this match restores the user's
          # classification. Confirmed transfer kinds exclude both principal legs.
          transfer = Transfer.create!(outflow_transaction: outflow.transaction,
            inflow_transaction: inflow.transaction, amount: outflow.amount, status: :confirmed,
            notes: "Matched by exact Wise ID, account holders, currency and principal amount.")
          transfer.confirm!
          true
        end
    end

    def eligible?(entry)
      data = metadata(entry)
      data.is_a?(Hash) && data["bank"] == "wise" && data["format"] == "wise_history" &&
        data["status"] == "COMPLETED" && !data["fee"] &&
        entry.transaction.transfer.nil? && !entry.transaction.locked?(:kind) &&
        !entry.locked?(:amount) && !entry.locked?(:currency) && !entry.locked?(:date)
    end

    def exact_pair?(outflow, inflow, links)
      return false unless outflow && inflow && outflow.account_id != inflow.account_id
      return false unless outflow.currency == inflow.currency && outflow.amount + inflow.amount == 0
      return false if (outflow.date - inflow.date).abs > 30

      source = links.fetch(outflow.account_id)
      target = links.fetch(inflow.account_id)
      return false unless source.entity != target.entity && [ source.entity, target.entity ].sort == %w[business personal]
      source_holder = normalize_name(source.metadata["account_holder"])
      target_holder = normalize_name(target.metadata["account_holder"])
      return false if source_holder.empty? || target_holder.empty?

      [ outflow, inflow ].all? do |entry|
        data = metadata(entry)
        normalize_name(data["source_name"]) == source_holder && normalize_name(data["target_name"]) == target_holder
      end
    end

    def metadata(entry)
      entry.transaction.extra["bank_file"]
    end

    def normalize_name(value)
      value.to_s.unicode_normalize(:nfkc).strip.downcase.gsub(/\s+/, " ")
    end
end
