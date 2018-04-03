class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception
  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :set_paper_trail_whodunnit

  before_action :load_object, if: :is_required_controller?
  after_action :keep_activity, only: [:update, :destroy], if: :is_required_controller?

  require 'permissions'

  class NotAuthorized < StandardError; end

  rescue_from NotAuthorized do |exception|
    if user_signed_in?
      respond_to do |format|
        format.html { render 'not_authorized', :status => 403 }
        format.all { render :text => 'You are not authorized to access this section.', :status => 403 }
      end
    else
      error_msg = 'You must be logged in to access this section.'
      respond_to do |format|
        format.html { flash.now[:error] = error_msg; redirect_to new_user_session_path }
        format.all { render :text => error_msg, :status => 401 }
      end
    end
  end

  helper_method :can?, :get_can

  def can?(action, resource)
    if not block_given?
      is_authorized(action, resource, get_permissions)
    else
      if can?(action, resource)
        res = yield
        #log(action, resource) if res and action != :read
        return res
      else
        raise NotAuthorized
      end
    end
  end

  def normalize_resource_path(resource)
    File.expand_path(resource, '/') + '/'
  end

  def denormalize_resource_path(resource, resource_prefix)
    resource_prefix = normalize_resource_path(resource_prefix)
    prefix = suffix = 0
    if resource.start_with?(resource_prefix)
      prefix = resource_prefix.length
    end

    if resource[prefix, 1] == '/'
      prefix += 1
    end
    if resource.end_with? '/'
      suffix = 1
    end
    return resource[prefix .. (-1 - suffix)]
  end

  def get_permissions
    case Rails.configuration.auth_method
    when :db
      fetch_permissions_from_db
    end

    roles = []
    if user_signed_in?
      roles.concat(Rails.configuration.users[current_user.username]['roles'])
    end

    @permissions ||= Rails.cache.fetch("#{roles}_permisions", :expires_in => 60.seconds) do
      permissions = []
      roles.each do |role|
        if Rails.configuration.permissions.has_key?(role)
          # do not concat directly to avoid modifying original permissions during normalization
          Rails.configuration.permissions[role].map do |a|
            permissions << a.dup
          end
        end
      end

      permissions = [['read', 1, '/home']] if permissions.blank?
      normalize_permissions(permissions)
    end
  end

  def fetch_permissions_from_db
    roles = Role.all
    Rails.configuration.permissions = {}

    roles.each do |role|
      Rails.configuration.permissions[role.name] = Array.new
      role.privileges.each do |privilege|
        Rails.configuration.permissions[role.name].push([privilege.action, privilege.weight, privilege.resource])
      end
    end

    users = User.all
    Rails.configuration.users = {}

    users.each do |user|
      Rails.configuration.users[user.username] = Hash.new
      Rails.configuration.users[user.username]["password"] = user.password
      Rails.configuration.users[user.username]["roles"] = Array.new
      user.roles.each do |role|
        Rails.configuration.users[user.username]["roles"].push(role.name)
      end
    end
  end

  protected
  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_in, keys: [:username, :password, :remember_me])
    devise_parameter_sanitizer.permit(:account_update, keys: [
      :username, :email, :password, :password_confirmation, :current_password
    ])
  end

  def is_required_controller?
    required_controllers = [
      'presets', 'objects', 'provisions', 'virtual_parameters', 'files'
    ]
    required_controllers.include? controller_name
  end

  def keep_activity
    object_changes = ApplicationHelper.diff_hashes(@before_change, @changed)

    if ['create', 'update'].include?(@action) && !@changed.blank?
      PaperTrail::Version.create(event: @action, whodunnit: current_user.id, item_type: controller_name,
            item_id: @id, object: @before_change, object_changes: object_changes, ip: current_user.current_sign_in_ip)

    elsif @action == 'destroy' && !@before_change.blank?
      PaperTrail::Version.create(event: @action, whodunnit: current_user.id, item_type: controller_name,
            item_id: @id, object: @before_change, object_changes: object_changes, ip: current_user.current_sign_in_ip)
    end
  end

  def load_object
    @id = params['name']&.strip || params[:id]
    res = query_resource(create_api_conn(), controller_name, {'_id' => @id })
    @before_change = res[:result][0]&.merge({ _id: params['name'] })

    @action = @before_change.blank? ? 'create' : action_name
  end
end
