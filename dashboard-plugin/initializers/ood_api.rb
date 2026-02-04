# frozen_string_literal: true

# OOD API Dashboard Plugin
# Adds token management UI to the Dashboard when ood-api app is installed.

# Add routes for token management
Rails.application.routes.draw do
  scope 'settings' do
    resources :api_tokens, only: [:index, :create, :destroy]
  end
end

# Add localization strings
I18n.backend.store_translations(:en, {
  dashboard: {
    api_tokens: {
      title:             'API Tokens',
      description:       'Manage API tokens for programmatic access to Open OnDemand.',
      your_tokens:       'Your Tokens',
      no_tokens:         'You have no API tokens. Create one to get started.',
      name:              'Name',
      created:           'Created',
      last_used:         'Last Used',
      never:             'Never',
      revoke:            'Revoke',
      revoke_confirm:    'Are you sure you want to revoke this token? This action cannot be undone.',
      create_new:        'Create New Token',
      token_name:        'Token Name',
      name_placeholder:  'e.g., My Script, CI Pipeline',
      name_help:         'Give your token a descriptive name to help you identify it later.',
      name_required:     'Token name is required.',
      generate:          'Generate Token',
      token_created:     'Token Created Successfully',
      copy_warning:      'Copy this token now and store it securely.',
      copy:              'Copy',
      created_notice:    "Token '%<name>s' created successfully.",
      revoked:           "Token '%<name>s' has been revoked.",
      not_found:         'Token not found.',
      usage:             'API Usage',
      usage_description: 'Include this header in your API requests:'
    }
  }
})

Rails.logger.info 'OOD API plugin loaded: Token management available at /settings/api_tokens'
