class SettingsController < ApplicationController
  before_filter :require_logged_in_user

  TOTP_SESSION_TIMEOUT = (60 * 15)

  def index
    @title = t('.accountsettings')

    @edit_user = @user.dup
  end

  def delete_account
    if @user.try(:authenticate, params[:user][:password].to_s)
      @user.delete!
      reset_session
      flash[:success] = t('.deleteaccountflash')
      return redirect_to "/"
    end

    flash[:error] = t('.verifypasswordflash')
    return redirect_to settings_path
  end

  def update
    @edit_user = @user.clone

    if params[:user][:password].empty? ||
    @user.authenticate(params[:current_password].to_s)
      if @edit_user.update_attributes(user_params)
        flash.now[:success] = t('.updatesettingsflash')
        @user = @edit_user
      end
    else
      flash[:error] = t('.passwordnotcorrect')
    end

    render :action => "index"
  end

  def twofa
    @title = t('.title')
  end

  def twofa_auth
    if @user.authenticate(params[:user][:password].to_s)
      session[:last_authed] = Time.now.to_i
      session.delete(:totp_secret)

      if @user.has_2fa?
        @user.disable_2fa!
        flash[:success] = t('.2fahasbeendisabled')
        return redirect_to "/settings"
      else
        return redirect_to twofa_enroll_url
      end
    else
      flash[:error] = t('.2fapassnotcorrect')
      return redirect_to twofa_url
    end
  end

  def twofa_enroll
    @title = t('.title')

    if (Time.now.to_i - session[:last_authed].to_i) > TOTP_SESSION_TIMEOUT
      flash[:error] = t('.enrollmenttimeout')
      return redirect_to twofa_url
    end

    if !session[:totp_secret]
      session[:totp_secret] = ROTP::Base32.random_base32
    end

    totp = ROTP::TOTP.new(session[:totp_secret],
      :issuer => Rails.application.name)
    totp_url = totp.provisioning_uri(@user.email)

    # no option for inline svg, so just strip off leading <?xml> tag
    qrcode = RQRCode::QRCode.new(totp_url)
    qr = qrcode.as_svg(:offset => 0, color: "000", :module_size => 5,
      :shape_rendering => "crispEdges").gsub(/^<\?xml.*>/, "")

    @qr_svg = "<a href=\"#{totp_url}\">#{qr}</a>"
  end

  def twofa_verify
    @title = t('.title')

    if ((Time.now.to_i - session[:last_authed].to_i) > TOTP_SESSION_TIMEOUT) ||
    !session[:totp_secret]
      flash[:error] = t('.enrollmenttimeout')
      return redirect_to twofa_url
    end
  end

  def twofa_update
    if ((Time.now.to_i - session[:last_authed].to_i) > TOTP_SESSION_TIMEOUT) ||
    !session[:totp_secret]
      flash[:error] = t('.enrollmenttimeout')
      return redirect_to twofa_url
    end

    @user.totp_secret = session[:totp_secret]
    if @user.authenticate_totp(params[:totp_code])
      # re-roll, just in case
      @user.session_token = nil
      @user.save!

      session[:u] = @user.session_token

      flash[:success] = t('.2fahasbeenenabled')
      session.delete(:totp_secret)
      return redirect_to "/settings"
    else
      flash[:error] = t('.totpinvalid')
      return redirect_to twofa_verify_url
    end
  end

  # external services

  def pushover_auth
    if !Pushover.SUBSCRIPTION_CODE
      flash[:error] = "Questo sito non è configurato per Pushover"
      return redirect_to "/settings"
    end

    session[:pushover_rand] = SecureRandom.hex

    return redirect_to Pushover.subscription_url({
      :success => "#{Rails.application.root_url}settings/pushover_callback?" <<
        "rand=#{session[:pushover_rand]}",
      :failure => "#{Rails.application.root_url}settings/",
    })
  end

  def pushover_callback
    if !session[:pushover_rand].to_s.present?
      flash[:error] = "Nessun random token nella sessione"
      return redirect_to "/settings"
    end

    if !params[:rand].to_s.present?
      flash[:error] = "Nessun random token nell'URL"
      return redirect_to "/settings"
    end

    if params[:rand].to_s != session[:pushover_rand].to_s
      raise "rand param #{params[:rand].inspect} != " <<
        session[:pushover_rand].inspect
    end

    @user.pushover_user_key = params[:pushover_user_key].to_s
    @user.save!

    if @user.pushover_user_key.present?
      flash[:success] = "Il tuo account è abilitato alle notifiche Pushover."
    else
      flash[:success] = "Il tuo account ha disabilitato le notifiche Pushover."
    end

    return redirect_to "/settings"
  end

  def github_auth
    session[:github_state] = SecureRandom.hex
    return redirect_to Github.oauth_auth_url(session[:github_state])
  end

  def github_callback
    if !session[:github_state].present? || !params[:code].present? ||
    (params[:state].to_s != session[:github_state].to_s)
      flash[:error] = "Invalid OAuth state"
      return redirect_to "/settings"
    end

    session.delete(:github_state)

    tok, username = Github.token_and_user_from_code(params[:code])
    if tok.present? && username.present?
      @user.github_oauth_token = tok
      @user.github_username = username
      @user.save!
      flash[:success] = "Il tuo account è stato collegato all'utente GitHub " <<
        "#{username}."
    else
      return github_disconnect
    end

    return redirect_to "/settings"
  end

  def github_disconnect
    @user.github_oauth_token = nil
    @user.github_username = nil
    @user.save!
    flash[:success] = "La tua associazione con GitHub è stata rimossa."
    return redirect_to "/settings"
  end

  def twitter_auth
    session[:twitter_state] = SecureRandom.hex
    return redirect_to Twitter.oauth_auth_url(session[:twitter_state])
  end

  def twitter_callback
    if !session[:twitter_state].present? ||
    (params[:state].to_s != session[:twitter_state].to_s)
      flash[:error] = "Stato OAuth non valido"
      return redirect_to "/settings"
    end

    session.delete(:twitter_state)

    tok, sec, username = Twitter.token_secret_and_user_from_token_and_verifier(
      params[:oauth_token], params[:oauth_verifier])
    if tok.present? && username.present?
      @user.twitter_oauth_token = tok
      @user.twitter_oauth_token_secret = sec
      @user.twitter_username = username
      @user.save!
      flash[:success] = "Il tuo account è stato collegato all'account Twitter @" <<
        "#{username}."
    else
      return twitter_disconnect
    end

    return redirect_to "/settings"
  end

  def twitter_disconnect
    @user.twitter_oauth_token = nil
    @user.twitter_username = nil
    @user.twitter_oauth_token_secret = nil
    @user.save!
    flash[:success] = "La tua associazione con Twitter è stata rimossa."
    return redirect_to "/settings"
  end

private

  def user_params
    params.require(:user).permit(
      :username, :email, :password, :password_confirmation, :about,
      :email_replies, :email_messages, :email_mentions,
      :pushover_replies, :pushover_messages, :pushover_mentions,
      :mailing_list_mode, :show_avatars, :show_story_previews,
      :show_submitted_story_threads, :hide_dragons
    )
  end
end
