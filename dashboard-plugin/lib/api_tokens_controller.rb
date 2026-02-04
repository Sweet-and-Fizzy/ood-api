# frozen_string_literal: true

# Controller for managing API tokens via the Dashboard UI.
# This is loaded as part of the ood-api Dashboard plugin.
class ApiTokensController < ApplicationController
  # GET /settings/api_tokens
  def index
    @tokens = ApiToken.all
    @new_token = nil
  end

  # POST /settings/api_tokens
  # Renders the index directly with @new_token set to avoid storing
  # the sensitive token in the session/flash.
  def create
    name = params.require(:api_token).permit(:name)[:name]

    if name.blank?
      redirect_to api_tokens_path, alert: t('dashboard.api_tokens.name_required')
      return
    end

    token = ApiToken.generate(name: name)
    @new_token = token.token
    @tokens = ApiToken.all
    flash.now[:notice] = t('dashboard.api_tokens.created_notice', name: token.name)
    render :index
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
  end
end
