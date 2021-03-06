#
# Copyright (C) 2011 - 2014 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class Login::SamlController < ApplicationController
  include Login::Shared

  protect_from_forgery except: [:create, :destroy]

  before_filter :forbid_on_files_domain
  before_filter :run_login_hooks, :check_sa_delegated_cookie, only: [:new, :create]

  def new
    increment_saml_stat("login_attempt")
    reset_session_for_login
    settings = aac.saml_settings(request.host_with_port)
    request = Onelogin::Saml::AuthRequest.new(settings)
    forward_url = request.generate_request
    if aac.debugging? && !aac.debug_get(:request_id)
      aac.debug_set(:request_id, request.id)
      aac.debug_set(:to_idp_url, forward_url)
      aac.debug_set(:to_idp_xml, request.request_xml)
      aac.debug_set(:debugging, "Forwarding user to IdP for authentication")
    end
    redirect_to delegated_auth_redirect_uri(forward_url)
  end

  def create
    login_error_message = t("There was a problem logging in at %{institution}",
                            institution: @domain_root_account.display_name)

    unless params[:SAMLResponse]
      logger.error "saml_consume request with no SAMLResponse parameter"
      flash[:delegated_message] = login_error_message
      return redirect_to login_url
    end

    # Break up the SAMLResponse into chunks for logging (a truncated version was probably already
    # logged with the request when using syslog)
    chunks = params[:SAMLResponse].scan(/.{1,1024}/)
    chunks.each_with_index do |chunk, idx|
      logger.info "SAMLResponse[#{idx+1}/#{chunks.length}] #{chunk}"
    end

    increment_saml_stat('login_response_received')
    response = Onelogin::Saml::Response.new(params[:SAMLResponse])

    if @domain_root_account.account_authorization_configs.where(auth_type: 'saml').count > 1
      @aac = @domain_root_account.account_authorization_configs.
          where(auth_type: 'saml').
          where(idp_entity_id: response.issuer).
          first
      if @aac.nil?
        logger.error "Attempted SAML login for #{response.issuer} on account without that IdP"
        if @domain_root_account.auth_discovery_url
          flash[:delegated_message] = t("Canvas did not recognize your identity provider")
        else
          flash[:delegated_message] = t("The institution you logged in from is not configured on this account.")
        end
        return redirect_to login_url
      end
    end

    settings = aac.saml_settings(request.host_with_port)
    response.process(settings)

    unique_id = nil
    if aac.login_attribute == 'nameid'
      unique_id = response.name_id
    elsif aac.login_attribute == 'eduPersonPrincipalName'
      unique_id = response.saml_attributes["eduPersonPrincipalName"]
    elsif aac.login_attribute == 'eduPersonPrincipalName_stripped'
      unique_id = response.saml_attributes["eduPersonPrincipalName"]
      unique_id = unique_id.split('@', 2)[0]
    end

    logger.info "Attempting SAML login for #{aac.login_attribute} #{unique_id} in account #{@domain_root_account.id}"

    debugging = aac.debugging? && aac.debug_get(:request_id) == response.in_response_to
    if debugging
      aac.debug_set(:debugging, t('debug.redirect_from_idp', "Recieved LoginResponse from IdP"))
      aac.debug_set(:idp_response_encoded, params[:SAMLResponse])
      aac.debug_set(:idp_response_xml_encrypted, response.xml)
      aac.debug_set(:idp_response_xml_decrypted, response.decrypted_document.to_s)
      aac.debug_set(:idp_in_response_to, response.in_response_to)
      aac.debug_set(:idp_login_destination, response.destination)
      aac.debug_set(:fingerprint_from_idp, response.fingerprint_from_idp)
      aac.debug_set(:login_to_canvas_success, 'false')
    end

    if response.is_valid?
      aac.debug_set(:is_valid_login_response, 'true') if debugging

      if response.success_status?
        pseudonym = @domain_root_account.pseudonyms.active.by_unique_id(unique_id).first

        if pseudonym
          # We have to reset the session again here -- it's possible to do a
          # SAML login without hitting the #new action, depending on the
          # school's setup.
          reset_session_for_login
          # Successful login and we have a user
          @domain_root_account.pseudonym_sessions.create!(pseudonym, false)
          user = pseudonym.login_assertions_for_user

          if debugging
            aac.debug_set(:login_to_canvas_success, 'true')
            aac.debug_set(:logged_in_user_id, user.id)
          end
          increment_saml_stat("normal.login_success")

          session[:saml_unique_id] = unique_id
          session[:name_id] = response.name_id
          session[:name_qualifier] = response.name_qualifier
          session[:session_index] = response.session_index
          session[:return_to] = params[:RelayState] if params[:RelayState] && params[:RelayState] =~ /\A\/(\z|[^\/])/
          session[:login_aac] = aac.id

          successful_login(user, pseudonym)
        else
          unknown_user_url = aac.unknown_user_url.presence || login_url
          increment_saml_stat("errors.unknown_user")
          message = "Received SAML login request for unknown user: #{unique_id} redirecting to: #{unknown_user_url}."
          logger.warn message
          aac.debug_set(:canvas_login_fail_message, message) if debugging
          flash[:delegated_message] = t("Canvas doesn't have an account for user: %{user}",
                                        user: unique_id)
          redirect_to unknown_user_url
        end
      elsif response.auth_failure?
        increment_saml_stat("normal.login_failure")
        message = "Failed to log in correctly at IdP"
        logger.warn message
        aac.debug_set(:canvas_login_fail_message, message) if debugging
        flash[:delegated_message] = login_error_message
        redirect_to login_url
      elsif response.no_authn_context?
        increment_saml_stat("errors.no_authn_context")
        message = "Attempted SAML login for unsupported authn_context at IdP."
        logger.warn message
        aac.debug_set(:canvas_login_fail_message, message) if debugging
        flash[:delegated_message] = login_error_message
        redirect_to login_url
      else
        increment_saml_stat("errors.unexpected_response_status")
        message = "Unexpected SAML status code - status code: #{response.status_code || ''} - Status Message: #{response.status_message || ''}"
        logger.warn message
        aac.debug_set(:canvas_login_fail_message, message) if debugging
        flash[:delegated_message] = login_error_message
        redirect_to login_url
      end
    else
      increment_saml_stat("errors.invalid_response")
      if debugging
        aac.debug_set(:is_valid_login_response, 'false')
        aac.debug_set(:login_response_validation_error, response.validation_error)
      end
      logger.error "Failed to verify SAML signature: #{response.validation_error}"
      flash[:delegated_message] = login_error_message
      redirect_to login_url
    end
  end

  def destroy
    unless params[:SAMLResponse] || params[:SAMLRequest]
      return render status: :bad_request, text: "SAMLRequest or SAMLResponse required"
    end

    if params[:SAMLResponse]
      increment_saml_stat("logout_response_received")
      saml_response = Onelogin::Saml::LogoutResponse.parse(params[:SAMLResponse])

      aac = @domain_root_account.account_authorization_configs.where(idp_entity_id: saml_response.issuer).first
      return render status: :bad_request, text: "Could not find SAML Entity" unless aac

      settings = aac.saml_settings(request.host_with_port)
      saml_response.process(settings)

      if aac.debugging? && aac.debug_get(:logout_request_id) == saml_response.in_response_to
        aac.debug_set(:idp_logout_response_encoded, params[:SAMLResponse])
        aac.debug_set(:idp_logout_response_xml_encrypted, saml_response.xml)
        aac.debug_set(:idp_logout_response_in_response_to, saml_response.in_response_to)
        aac.debug_set(:idp_logout_response_destination, saml_response.destination)
        aac.debug_set(:debugging, t('debug.logout_response_redirect_from_idp', "Received LogoutResponse from IdP"))
      end

      redirect_to saml_login_url(id: aac.id)
    else
      increment_saml_stat("logout_request_received")
      saml_request = Onelogin::Saml::LogoutRequest.parse(params[:SAMLRequest])
      if (aac = @domain_root_account.account_authorization_configs.where(idp_entity_id: saml_request.issuer).first)
        settings = aac.saml_settings(request.host_with_port)
        saml_request.process(settings)

        if aac.debugging? && aac.debug_get(:logged_in_user_id) == @current_user.id
          aac.debug_set(:idp_logout_request_encoded, params[:SAMLRequest])
          aac.debug_set(:idp_logout_request_xml_encrypted, saml_request.request_xml)
          aac.debug_set(:idp_logout_request_name_id, saml_request.name_id)
          aac.debug_set(:idp_logout_request_session_index, saml_request.session_index)
          aac.debug_set(:idp_logout_request_destination, saml_request.destination)
          aac.debug_set(:debugging, t('debug.logout_request_redirect_from_idp', "Received LogoutRequest from IdP"))
        end

        settings.relay_state = params[:RelayState]
        saml_response = Onelogin::Saml::LogoutResponse.generate(saml_request.id, settings)

        # Seperate the debugging out because we want it to log the request even if the response dies.
        if aac.debugging? && aac.debug_get(:logged_in_user_id) == @current_user.id
          aac.debug_set(:idp_logout_request_encoded, saml_response.base64_assertion)
          aac.debug_set(:idp_logout_response_xml_encrypted, saml_response.xml)
          aac.debug_set(:idp_logout_response_status_code, saml_response.status_code)
          aac.debug_set(:idp_logout_response_status_message, saml_response.status_message)
          aac.debug_set(:idp_logout_response_destination, saml_response.destination)
          aac.debug_set(:idp_logout_response_in_response_to, saml_response.in_response_to)
          aac.debug_set(:debugging, t('debug.logout_response_redirect_to_idp', "Sending LogoutResponse to IdP"))
        end

        logout_current_user
        redirect_to(saml_response.forward_url)
      end
    end
  end

  protected

  def aac
    @aac ||= begin
      scope = @domain_root_account.account_authorization_configs.where(auth_type: 'saml')
      params[:id] ? scope.find(params[:id]) : scope.first!
    end
  end

  def increment_saml_stat(key)
    CanvasStatsd::Statsd.increment("saml.#{CanvasStatsd::Statsd.escape(request.host)}.#{key}")
  end
end
