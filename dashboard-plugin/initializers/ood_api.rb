# frozen_string_literal: true

# OOD API Dashboard Plugin
# Adds token management UI to the Dashboard when ood-api app is installed.

# Add routes for token management. Use `append` (not `draw`) so the plugin's
# routes merge with the Dashboard's routes instead of replacing them — `draw`
# calls `clear!` on the route set, which would wipe out every Dashboard route.
Rails.application.routes.append do
  scope 'settings' do
    resources :api_tokens, only: [:index, :create, :destroy]
  end
end

# Register the plugin's locale files with Rails' I18n load path. We can't call
# `I18n.backend.store_translations` directly here: the Rails I18n railtie later
# assigns `I18n.load_path += config.i18n.load_path`, which invokes the
# `load_path=` setter and that calls `backend.reload!` — wiping any translations
# stored inline. Registering via `config.i18n.load_path` avoids that entirely.
plugin_locales = File.expand_path('../locales/*.{yml,rb}', __dir__)
Rails.application.config.i18n.load_path += Dir[plugin_locales]

Rails.logger.info 'OOD API plugin loaded: Token management available at /settings/api_tokens'
