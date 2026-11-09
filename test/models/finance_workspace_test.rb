require "test_helper"

class FinanceWorkspaceTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @period = Date.current.prev_month.beginning_of_month
    @personal = create_link("personal", "USD")
    @business = create_link("business", "HUF")
  end

  test "cashflows preserve currencies and exclude movements, future entries and excluded entries" do
    create_entry(@personal.account, -200, @period)
    create_entry(@personal.account, 50, @period + 1.day)
    create_entry(@personal.account, 500, @period + 2.days, kind: "funds_movement")
    create_entry(@personal.account, 999, @period + 3.days, excluded: true)
    create_entry(@personal.account, 888, Date.current + 2.months)
    create_entry(@business.account, -100_000, @period)
    create_entry(@business.account, 20_000, @period + 1.day)

    workspace = FinanceWorkspace.new(user: @user)
    rows = workspace.cashflows.index_by { |row| row[:currency] }

    assert_equal @period, workspace.month
    assert_equal 200.to_d, rows.fetch("USD")[:inflow].amount
    assert_equal 50.to_d, rows.fetch("USD")[:outflow].amount
    assert_equal 150.to_d, rows.fetch("USD")[:net].amount
    assert_equal 80_000.to_d, rows.fetch("HUF")[:net].amount
    assert_equal 5, workspace.transaction_count
  end

  test "entity filter cannot expose another user's unshared account or another family's account" do
    private_link = create_link("personal", "EUR", owner: users(:family_member))
    outside_link = create_link("personal", "GBP", owner: users(:empty))
    create_entry(private_link.account, -999, @period)
    create_entry(outside_link.account, -888, @period)
    create_entry(@personal.account, -20, @period)
    create_entry(@business.account, -30, @period)

    workspace = FinanceWorkspace.new(user: @user, entity: "personal")

    assert_equal [ @personal.account_id ], workspace.account_ids
    assert_equal 1, workspace.transaction_count
    assert_equal [ "USD" ], workspace.cashflows.map { |row| row[:currency] }
  end

  test "coverage describes history without treating unverified balances as wealth" do
    create_entry(@personal.account, -100, @period)
    create_entry(@personal.account, 25, @period + 10.days)
    workspace = FinanceWorkspace.new(user: @user, entity: "personal", month: "invalid")

    assert_equal @period, workspace.first_activity_on
    assert_equal @period + 10.days, workspace.last_activity_on
    assert_equal @period, workspace.month
    assert_not workspace.account_coverages.first[:link].balance_verified?
    assert @personal.account.exclude_from_reports?
  end

  private
    def create_link(entity, currency, owner: @user)
      account = Account.create!(family: owner.family, owner: owner, name: "#{entity} #{currency}", currency: currency,
        balance: 0, accountable: Depository.new, status: :active, exclude_from_reports: true)
      BankFile::AccountLink.create!(family: owner.family, account: account, provider: "wise", entity: entity,
        currency: currency, owner_name: "Example Holder", balance_verified: false)
    end

    def create_entry(account, amount, date, kind: "standard", excluded: false)
      account.entries.create!(amount: amount, currency: account.currency, date: date, name: "Example activity",
        excluded: excluded, entryable: Transaction.new(kind: kind))
    end
end
