class BankFile::AccountLink < ApplicationRecord
  self.table_name = "bank_file_account_links"

  belongs_to :family
  belongs_to :account

  validates :provider, inclusion: { in: %w[wise revolut] }
  validates :entity, inclusion: { in: %w[personal business] }
  validates :currency, :owner_name, presence: true
  validates :account_id, uniqueness: true
  validates :currency, uniqueness: { scope: [ :family_id, :provider, :entity ] }
  validate :account_matches_scope

  private
    def account_matches_scope
      return unless account
      errors.add(:account, "must belong to this family") if account.family_id != family_id
      errors.add(:currency, "must match the account currency") if account.currency != currency
    end
end
