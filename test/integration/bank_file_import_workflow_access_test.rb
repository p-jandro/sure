require "test_helper"

class BankFileImportWorkflowAccessTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @actor = users(:family_admin)
    @import = imports(:transaction)
    @row = import_rows(:one)
    @mapping = import_mappings(:one)
    @private_name = "BANK_FILE_PRIVATE_SENTINEL"
    @import.update_columns(
      raw_file_str: "date,amount,name\n2026-01-01,-100,#{@private_name}\n",
      summary: { "bank_file" => { "actor_id" => @actor.id } }
    )
    ensure_tailwind_build
  end

  test "generic read and mutation routes reject bank files for their owner and another family member" do
    original_import = @import.reload.attributes
    original_row = @row.reload.attributes
    original_mapping = @mapping.reload.attributes

    [ @actor, users(:family_member) ].each do |user|
      sign_in user

      assert_no_enqueued_jobs only: [ ImportJob, RevertImportJob ] do
        generic_requests.each do |method, path, payload|
          public_send(method, path, params: payload || {})

          assert_response :not_found
          assert_not_includes response.body, @private_name
        end
      end

      assert_equal original_import, @import.reload.attributes
      assert_equal original_row, @row.reload.attributes
      assert_equal original_mapping, @mapping.reload.attributes
    end
  end

  test "generic import list and resume link omit bank files but retain ordinary imports" do
    sign_in @actor
    VectorStore::Registry.stubs(:adapter).returns(nil)
    ordinary = @actor.family.imports.create!(type: "TransactionImport")
    @import.update_columns(created_at: 1.minute.from_now)

    get imports_path

    assert_response :success
    assert_select "##{dom_id(@import)}", count: 0
    assert_select "##{dom_id(ordinary)}", count: 1

    get new_import_path

    assert_response :success
    assert_select "a[href=?]", import_path(@import), count: 0
    assert_select "a[href=?]", import_path(ordinary), count: 1
  end

  test "bank file marker is hidden even when its value is empty or malformed" do
    sign_in @actor

    [ nil, false, "", [], {} ].each do |metadata|
      @import.update_columns(summary: { "bank_file" => metadata })

      get import_upload_path(@import)

      assert_response :not_found
      assert_not_includes response.body, @private_name
    end
  end

  test "ordinary imports still permit row access and updates" do
    sign_in @actor
    @import.update_columns(summary: {})

    get import_row_path(@import, @row)

    assert_response :success

    patch import_row_path(@import, @row), params: { import_row: { name: "Reviewed transaction" } }

    assert_redirected_to import_row_path(@import, @row)
    assert_equal "Reviewed transaction", @row.reload.name
  end

  private
    def generic_requests
      [
        [ :get, import_path(@import) ],
        [ :get, summary_import_path(@import) ],
        [ :get, import_upload_path(@import) ],
        [ :get, import_configuration_path(@import) ],
        [ :get, import_clean_path(@import) ],
        [ :get, import_confirm_path(@import) ],
        [ :get, import_qif_category_selection_path(@import) ],
        [ :get, import_row_path(@import, @row) ],
        [ :patch, import_path(@import), { import: { account_id: accounts(:depository).id } } ],
        [ :post, publish_import_path(@import) ],
        [ :put, revert_import_path(@import) ],
        [ :put, apply_template_import_path(@import) ],
        [ :post, cancel_import_path(@import) ],
        [ :delete, import_path(@import) ],
        [ :patch, import_upload_path(@import), { import: { raw_file_str: "date,amount\n2026-01-02,-20", col_sep: "," } } ],
        [ :patch, import_configuration_path(@import), { import: { date_col_label: "date", amount_col_label: "amount" } } ],
        [ :patch, import_qif_category_selection_path(@import), { date_format: "%Y-%m-%d" } ],
        [ :patch, import_row_path(@import, @row), { import_row: { name: "Changed" } } ],
        [ :patch, import_mapping_path(@import, @mapping), { import_mapping: { mappable_type: "Category", mappable_id: categories(:income).id } } ]
      ]
    end
end
