class FinanceWorkspaceController < ApplicationController
  before_action :require_non_guest!, only: %i[upload confirm discard]
  before_action :set_bank_import, only: %i[preview confirm discard]

  def index
    @workspace = FinanceWorkspace.new(user: Current.user, entity: params[:entity], month: params[:month])
    @upload_entity = @workspace.entity == "business" ? "business" : "personal"
    @owner_name = if @upload_entity == "business"
      ENV["SURE_BUSINESS_ACCOUNT_NAME"].to_s
    else
      ENV["SURE_PERSONAL_ACCOUNT_NAME"].presence || Current.user.display_name
    end
  end

  def upload
    attributes = params.require(:bank_file).permit(:file, :entity, :owner_name)
    file = attributes[:file]
    return redirect_to(finance_workspace_path, alert: t("finance_workspace.errors.missing_file")) unless file.respond_to?(:read)
    return redirect_to(finance_workspace_path, alert: t("finance_workspace.errors.file_too_large")) if file.size > Import::MAX_CSV_SIZE

    content = file.read(Import::MAX_CSV_SIZE + 1)
    return redirect_to(finance_workspace_path, alert: t("finance_workspace.errors.file_too_large")) if content.bytesize > Import::MAX_CSV_SIZE

    staged = BankFile::Import.new(
      family: Current.family,
      user: Current.user,
      content: content,
      filename: File.basename(file.original_filename.to_s.tr("\\", "/")),
      entity: attributes[:entity],
      owner_name: attributes[:owner_name]
    ).stage!

    redirect_to finance_workspace_import_path(staged), status: :see_other
  rescue ActionController::ParameterMissing
    redirect_to finance_workspace_path, alert: t("finance_workspace.errors.missing_file"), status: :see_other
  rescue BankFile::Error => error
    redirect_to finance_workspace_path, alert: error.message, status: :see_other
  end

  def preview
    @metadata = @bank_import.summary.fetch("bank_file").deep_symbolize_keys
    @preview = BankFile::Import.new(import: @bank_import, user: Current.user).preview.deep_symbolize_keys
  rescue BankFile::Error => error
    redirect_to finance_workspace_path, alert: error.message, status: :see_other
  end

  def confirm
    if @bank_import.complete?
      redirect_to finance_workspace_path, notice: t("finance_workspace.import.already_complete"), status: :see_other
      return
    end

    result = BankFile::Import.new(import: @bank_import, user: Current.user).commit!.deep_symbolize_keys
    redirect_to finance_workspace_path(entity: @bank_import.summary.dig("bank_file", "entity")),
      notice: t("finance_workspace.import.complete", created: result[:created], duplicates: result[:duplicates], skipped: result[:skipped], review: result[:review]),
      status: :see_other
  rescue BankFile::Error => error
    redirect_to finance_workspace_import_path(@bank_import), alert: error.message, status: :see_other
  end

  def discard
    @bank_import.with_lock do
      unless @bank_import.pending? && !@bank_import.entries.exists? && !@bank_import.accounts.exists?
        redirect_to finance_workspace_path, alert: t("finance_workspace.errors.cannot_discard"), status: :see_other
        return
      end

      @bank_import.destroy!
    end

    redirect_to finance_workspace_path, notice: t("finance_workspace.import.discarded"), status: :see_other
  end

  private
    def set_bank_import
      @bank_import = Current.family.imports.where(type: "TransactionImport")
        .where("summary -> 'bank_file' ->> 'actor_id' = ?", Current.user.id.to_s)
        .find(params[:id])
    end
end
