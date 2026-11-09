require "test_helper"

class BankFile::UnverifiedBalanceTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @unverified = create_account("Imported history", exclude_from_reports: true)
    @link = link_account(@unverified, balance_verified: false)
  end

  test "direct refresh cannot materialize a balance from unverified history" do
    @unverified.entries.create!(
      entryable: Transaction.new, date: 2.days.ago.to_date, amount: 125, currency: "EUR", name: "Example payment"
    )
    original_balances = @unverified.attributes.slice("balance", "cash_balance")
    Account::MarketDataImporter.any_instance.expects(:import_all).never
    Balance::Materializer.any_instance.expects(:materialize_balances).never

    assert_no_difference [ "Balance.count", "Holding.count" ] do
      Account::Syncer.new(@unverified).perform_sync(stub(window_start_date: nil))
    end

    assert_equal original_balances, @unverified.reload.attributes.slice("balance", "cash_balance")
    assert_not @link.reload.balance_verified
    assert_equal 125, @unverified.entries.sole.amount
  end

  test "family refresh schedules ordinary and verified accounts while skipping unverified history" do
    ordinary = create_account("Ordinary account")
    verified = create_account("Reconciled history")
    link_account(verified, entity: "business", balance_verified: true)
    family_sync = @family.syncs.create!
    @family.stubs(:sync_trial_status!)

    assert_difference -> { family_sync.children.count }, 2 do
      Family::Syncer.new(@family).perform_sync(family_sync)
    end

    assert_equal [ ordinary.id, verified.id ].sort,
      family_sync.children.where(syncable_type: "Account").pluck(:syncable_id).sort
    assert_empty @unverified.syncs
  end

  test "native reports exclude unverified history even when its exclusion checkbox is cleared" do
    ordinary = create_account("Ordinary account")
    verified = create_account("Reconciled history")
    link_account(verified, entity: "business", balance_verified: true)
    @unverified.update!(exclude_from_reports: false)

    assert_equal [ ordinary.id, verified.id ].sort, @family.accounts.included_in_reports.pluck(:id).sort
    assert @unverified.bank_file_balance_unverified?
    assert_not ordinary.bank_file_balance_unverified?
    assert_not verified.bank_file_balance_unverified?

    verified.update!(exclude_from_reports: true)
    assert_equal [ ordinary.id ], @family.accounts.included_in_reports.pluck(:id)
  end

  private
    def create_account(name, exclude_from_reports: false)
      @family.accounts.create!(
        owner: users(:empty), name:, currency: "EUR", balance: 0, cash_balance: 0,
        accountable: Depository.new(subtype: "checking"), exclude_from_reports:
      )
    end

    def link_account(account, entity: "personal", balance_verified:)
      BankFile::AccountLink.create!(
        family: @family, account:, provider: "wise", entity:, currency: account.currency,
        owner_name: "Example owner", balance_verified:
      )
    end
end
