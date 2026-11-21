# frozen_string_literal: true

# Controller for managing API tokens via the Dashboard UI.
# This is loaded as part of the ood-api Dashboard plugin.
class ApiTokensController < ApplicationController
  # Every token record lives in one JSON array that ood-api rewrites on every
  # authenticated request, so an unbounded name is a self-inflicted denial of
  # service on the user's own API access and home quota.
  MAX_NAME_LENGTH = 100

  # GET /settings/api_tokens
  def index
    @tokens = ApiToken.all
    @new_token = nil
  end

  # POST /settings/api_tokens
  # Renders the index directly with @new_token set to avoid storing
  # the sensitive token in the session/flash.
  def create
    permitted = params.require(:api_token).permit(:name, :lifetime)
    name = sanitize_name(permitted[:name])
    problem = name_problem(name)
    return redirect_to(api_tokens_path, alert: problem) if problem

    token, @new_token = ApiToken.generate(name: name, lifetime: chosen_lifetime(permitted[:lifetime]))
    @tokens = ApiToken.all
    flash.now[:notice] = t('dashboard.api_tokens.created_notice', name: token.name)
    render :index
  rescue SystemCallError, IOError => e
    Rails.logger.error("Failed to write API token store: #{e.class}")
    redirect_to api_tokens_path, alert: t('dashboard.api_tokens.write_failed')
  end

  # DELETE /settings/api_tokens/:id
  def destroy
    token = ApiToken.find(params[:id])
    unless token
      redirect_to api_tokens_path, alert: t('dashboard.api_tokens.not_found')
      return
    end

    name = token.name
    token.destroy
    redirect_to api_tokens_path, notice: t('dashboard.api_tokens.revoked', name: name)
  rescue SystemCallError, IOError => e
    Rails.logger.error("Failed to write API token store: #{e.class}")
    redirect_to api_tokens_path, alert: t('dashboard.api_tokens.write_failed')
  end

  private

  # @return [String, nil] what is wrong with the name, if anything
  def name_problem(name)
    return t('dashboard.api_tokens.name_required') if name.blank?

    t('dashboard.api_tokens.name_too_long', max: MAX_NAME_LENGTH) if name.length > MAX_NAME_LENGTH
  end

  # Only a lifetime the form offered is accepted; anything else gets the default.
  def chosen_lifetime(value)
    ApiToken.lifetime_options.include?(value.to_s) ? value.to_s : ApiToken.default_lifetime
  end

  # Control characters would round-trip through JSON intact and render as
  # invisible or line-breaking text in the token list.
  def sanitize_name(value)
    value.to_s.gsub(/[[:cntrl:]]/, '').strip
  end
end
