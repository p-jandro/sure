require "test_helper"

class FinanceWorkspaceControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    ensure_tailwind_build
  end

  test "workspace renders an actionable empty state without inventing balances" do
    get finance_workspace_url

    assert_response :success
    assert_select "[data-testid='finance-workspace']"
    assert_select "form[action='#{finance_workspace_imports_path}'] input[type=file]"
    assert_select "select[name='bank_file[entity]'] option[value=business]"
    assert_select "a[href='#{settings_providers_path}']"
    assert_includes response.body, I18n.t("finance_workspace.empty.title")
  end

  test "workspace requires an authenticated session" do
    reset!

    get finance_workspace_url

    assert_redirected_to new_session_url
  end

  test "missing upload has a clear error and creates no import" do
    assert_no_difference "Import.count" do
      post finance_workspace_imports_url, params: { bank_file: { entity: "personal", owner_name: "Example Holder" } }
    end

    assert_redirected_to finance_workspace_url
    assert_equal I18n.t("finance_workspace.errors.missing_file"), flash[:alert]
  end

  test "a staged file is scoped to both family and original uploader" do
    other_import = staged_import(user: users(:family_member))

    get finance_workspace_import_url(other_import)
    assert_response :not_found
    post confirm_finance_workspace_import_url(other_import)
    assert_response :not_found
    delete finance_workspace_import_url(other_import)
    assert_response :not_found
    assert Import.exists?(other_import.id)

    outside_import = staged_import(user: users(:empty))
    get finance_workspace_import_url(outside_import)
    assert_response :not_found
  end

  test "preview renders cash directions and warnings before offering confirmation" do
    import = staged_import(user: @user)
    BankFile::Import.any_instance.stubs(:preview).returns(
      bank: "wise", format: "wise_history", row_count: 2, transaction_count: 2,
      skipped_count: 0, review_count: 1, date_from: "2026-01-02", date_to: "2026-01-03",
      warnings: [ "One row needs review." ], currencies: [ "EUR" ],
      totals: [ { currency: "EUR", inflow: "100.00", outflow: "25.00", fees: "0.25", net: "75.00" } ],
      sample_rows: [ { date: "2026-01-02", name: "Example activity", amount: "-100.00", currency: "EUR", kind: "standard" } ]
    )

    get finance_workspace_import_url(import)

    assert_response :success
    assert_select "[data-testid='bank-file-preview']"
    assert_includes response.body, "One row needs review."
    assert_select "form[action='#{confirm_finance_workspace_import_path(import)}'][method=post]"
    assert_includes response.body, I18n.t("finance_workspace.preview.balance_notice")
  end

  test "confirmation uses the staged import rather than replacement request data" do
    import = staged_import(user: @user)
    importer = mock("bank file importer")
    BankFile::Import.expects(:new).with(import: import, user: @user).returns(importer)
    importer.expects(:commit!).returns(created: 2, duplicates: 1, skipped: 0, review: 0, accounts: [], warnings: [])

    post confirm_finance_workspace_import_url(import), params: { bank_file: { owner_name: "Replacement", entity: "business", content: "changed" } }

    assert_redirected_to finance_workspace_url(entity: "personal")
    assert_equal I18n.t("finance_workspace.import.complete", created: 2, duplicates: 1, skipped: 0, review: 0), flash[:notice]
  end

  test "repeated confirmation cannot reimport a completed record" do
    import = staged_import(user: @user)
    import.update!(status: :complete)
    BankFile::Import.expects(:new).never

    post confirm_finance_workspace_import_url(import)

    assert_redirected_to finance_workspace_url
    assert_equal I18n.t("finance_workspace.import.already_complete"), flash[:notice]
  end

  test "discard only removes an untouched preview" do
    import = staged_import(user: @user)

    assert_difference "Import.count", -1 do
      delete finance_workspace_import_url(import)
    end
    assert_redirected_to finance_workspace_url

    completed = staged_import(user: @user)
    completed.update!(status: :complete)
    assert_no_difference "Import.count" do
      delete finance_workspace_import_url(completed)
    end
    assert_equal I18n.t("finance_workspace.errors.cannot_discard"), flash[:alert]
  end

  test "guest cannot stage bank files" do
    sign_in users(:intro_user)
    BankFile::Import.expects(:new).never

    assert_no_difference "Import.count" do
      post finance_workspace_imports_url, params: { bank_file: { entity: "personal", owner_name: "Example Holder" } }
    end
    assert_redirected_to accounts_url
  end

  private
    def staged_import(user:)
      user.family.imports.create!(type: "TransactionImport", summary: {
        bank_file: { actor_id: user.id.to_s, entity: "personal", owner_name: "Example Holder", filename: "example.csv", version: 1 }
      })
    end
end
