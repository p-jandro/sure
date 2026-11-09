require "json"

config = JSON.parse(File.read(ENV.fetch("SURE_BOOTSTRAP_FILE", "/bootstrap/bootstrap.json")))
abort "Refusing to bootstrap a non-local instance" unless Rails.application.config.app_mode.self_hosted?

User.transaction do
  User.lock_first_user_role!
  if User.exists?
    # Existing instances keep their accounts even while encrypted fields are
    # being backfilled or the owner has changed their original login email.
    puts JSON.generate(status: "existing_instance")
  else
    family = Family.create!(
      name: config.fetch("family_name", "My finances"),
      country: "HU", currency: "HUF", enabled_currencies: %w[HUF EUR GBP USD INR],
      date_format: "%Y.%m.%d", timezone: "Europe/Budapest", locale: "en",
      default_account_sharing: "private", auto_match_transfers_disabled: true,
      auto_sync_on_login: false, recurring_transactions_disabled: true,
      data_enrichment_enabled: false, assistant_type: "mcp_only"
    )
    user = family.users.create!(
      email: config.fetch("email"), password: config.fetch("password"),
      password_confirmation: config.fetch("password"),
      first_name: config.fetch("first_name", "Owner"), last_name: config.fetch("last_name", ""),
      role: :super_admin, locale: "en", theme: "system", ui_layout: "dashboard",
      ai_enabled: false, show_ai_sidebar: false, onboarded_at: Time.current,
      set_onboarding_goals_at: Time.current, set_onboarding_preferences_at: Time.current
    )
    puts JSON.generate(status: "created", user_id: user.id, family_id: family.id)
  end
end
