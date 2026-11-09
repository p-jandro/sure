class FinanceWorkspace
  ENTITIES = %w[all personal business].freeze

  attr_reader :user, :entity, :month

  def initialize(user:, entity: nil, month: nil)
    @user = user
    @entity = entity.presence_in(ENTITIES) || "all"
    @month = parse_month(month) || last_activity_on&.beginning_of_month || Date.current.beginning_of_month
  end

  def links
    @links ||= begin
      scope = BankFile::AccountLink.where(family_id: user.family_id, account_id: user.accessible_accounts.visible.select(:id))
      scope = scope.where(entity: entity) unless entity == "all"
      scope.includes(:account).order(:entity, :provider, :currency).to_a
    end
  end

  def entries
    @entries ||= Entry.where(account_id: links.map(&:account_id), entryable_type: "Transaction", excluded: false)
      .excluding_pending.excluding_scheduled.excluding_split_parents
  end

  def first_activity_on
    @first_activity_on ||= entries.minimum(:date)
  end

  def last_activity_on
    @last_activity_on ||= entries.maximum(:date)
  end

  def stale?
    last_activity_on.present? && last_activity_on < 7.days.ago.to_date
  end

  def transaction_count
    @transaction_count ||= entries.count
  end

  def period_transaction_count
    @period_transaction_count ||= period_entries.count
  end

  def months
    @months ||= ([ month ] + entries.distinct.pluck(:date).compact.map(&:beginning_of_month)).uniq.sort.reverse
  end

  def cashflows
    @cashflows ||= external_transactions.group("entries.currency").order("entries.currency").pluck(
      "entries.currency",
      Arel.sql("SUM(CASE WHEN entries.amount < 0 THEN -entries.amount ELSE 0 END)"),
      Arel.sql("SUM(CASE WHEN entries.amount > 0 THEN entries.amount ELSE 0 END)")
    ).map do |currency, inflow, outflow|
      {
        currency: currency,
        inflow: Money.new(inflow, currency),
        outflow: Money.new(outflow, currency),
        net: Money.new(inflow.to_d - outflow.to_d, currency)
      }
    end
  end

  def categories
    @categories ||= external_transactions.left_joins(:category)
      .group("entries.currency", "categories.name")
      .having("SUM(entries.amount) > 0")
      .pluck("entries.currency", "categories.name", Arel.sql("SUM(entries.amount)"))
      .group_by(&:first).sort.flat_map do |currency, rows|
        rows.sort_by { |row| -row.last.to_d }.first(5).map do |_, name, total|
          { currency: currency, name: name, amount: Money.new(total, currency) }
        end
      end
  end

  def recent_entries
    @recent_entries ||= period_entries.includes(:account, entryable: :category).order(date: :desc, created_at: :desc, id: :desc).limit(12)
  end

  def account_coverages
    @account_coverages ||= begin
      totals = entries.group(:account_id).pluck(:account_id, Arel.sql("COUNT(*)"), Arel.sql("MIN(date)"), Arel.sql("MAX(date)")).index_by(&:first)
      links.map do |link|
        _, count, first_date, last_date = totals[link.account_id]
        { link: link, count: count || 0, first_date: first_date, last_date: last_date }
      end
    end
  end

  def imports
    @imports ||= user.family.imports.where(type: "TransactionImport")
      .where("summary -> 'bank_file' ->> 'actor_id' = ?", user.id.to_s)
      .order(created_at: :desc).limit(6)
  end

  def pending_imports
    imports.select(&:pending?)
  end

  def account_ids
    links.map(&:account_id)
  end

  private
    def period_entries
      entries.where(date: month.all_month)
    end

    def external_transactions
      Transaction.joins(:entry).merge(period_entries).where.not(kind: Transaction::BUDGET_EXCLUDED_KINDS)
    end

    def parse_month(value)
      value = value.to_s
      return if value.blank? || !value.match?(/\A\d{4}-\d{2}\z/)

      Date.strptime(value, "%Y-%m").beginning_of_month
    rescue ArgumentError
      nil
    end
end
