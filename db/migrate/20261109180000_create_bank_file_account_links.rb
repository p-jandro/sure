class CreateBankFileAccountLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :bank_file_account_links, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :provider, null: false
      t.string :entity, null: false
      t.string :currency, null: false
      t.string :owner_name, null: false
      t.boolean :balance_verified, null: false, default: false
      t.boolean :needs_review, null: false, default: false
      t.date :coverage_start_on
      t.date :coverage_end_on
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :bank_file_account_links, [ :family_id, :provider, :entity, :currency ], unique: true, name: "index_bank_file_links_on_scope"
    add_check_constraint :bank_file_account_links, "entity IN ('personal', 'business')", name: "bank_file_links_entity"
    add_check_constraint :bank_file_account_links, "provider IN ('wise', 'revolut')", name: "bank_file_links_provider"
  end
end
