#
# Copyright (C) 2011 Instructure, Inc.
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

require File.expand_path(File.dirname(__FILE__) + '/../config/canvas_rails3')
if CANVAS_RAILS2
  Spec::Example::ExampleGroupMethods.module_eval do
    def include_examples(*args)
      it_should_behave_like(*args)
    end
  end
end

unless CANVAS_RAILS2
  Spec.configure do |c|
   c.treat_symbols_as_metadata_keys_with_true_values = true
  end

  RSpec.configure do |c|
    c.around(:each) do |example|
      attempts = 0
      begin
        Timeout::timeout(180) {
          example.run
        }
        if ENV['AUTORERUN']
          e = @example.instance_variable_get('@exception')
          if !e.nil? && (attempts += 1) < 2 && !example.metadata[:no_retry]
            puts "FAILURE: #{@example.description} \n #{e}".red
            puts "RETRYING: #{@example.description}".yellow
            @example.instance_variable_set('@exception', nil)
            redo
          elsif e.nil? && attempts != 0
            puts "SUCCESS: retry passed for \n #{@example.description}".green
          end
        end
      end until true
    end
  end
end

begin
  ; require File.expand_path(File.dirname(__FILE__) + "/../parallelized_specs/lib/parallelized_specs.rb");
rescue LoadError;
end

ENV["RAILS_ENV"] = 'test'

require File.expand_path('../../config/environment', __FILE__) unless defined?(Rails)
if CANVAS_RAILS2
  require 'spec'
  # require 'spec/autorun'
  require 'spec/rails'

  # integration specs were renamed to request specs in rspec 2
  def describe_with_rspec2_types(*args, &block)
    unless args.last.is_a?(Hash)
      args << {}
    end
    raise "please use type: :request instead of type: :integration for rspec 2 compatibility" if args.last[:type] == :integration
    if args.last[:type] == :request
      args.last[:type] = :integration
    end
    args.last[:location] ||= caller(0)[1]
    describe_without_rspec2_types(*args, &block)
  end

  alias :describe_without_rspec2_types :describe
  alias :describe :describe_with_rspec2_types

  ActionController::TestProcess.module_eval do
    def process_with_use_route_shim(action, parameters = nil, session = nil, flash = nil, http_method = 'GET')
      if parameters.is_a?(Hash)
        parameters.delete(:use_route)
      end
      process_without_use_route_shim(action, parameters, session, flash, http_method)
    end

    alias_method_chain :process, :use_route_shim
  end

  Spec::Rails::Example::ViewExampleGroup.class_eval do
    alias :view :template

    def content_for(name)
      response.capture(name)
    end
  end
else
  require 'rspec/rails'

  ActionView::TestCase::TestController.view_paths = ApplicationController.view_paths

  module RSpec::Rails
    module ViewExampleGroup
      module ExampleMethods
        # normally in rspec 2, assigns returns a newly constructed hash
        # which means that 'assigns[:key] = value' in view specs does nothing
        def assigns
          @assigns ||= super
        end

        alias :view_assigns :assigns

        delegate :content_for, :to => :view

        def render_with_helpers(*args)
          controller_class = ("#{@controller.controller_path.camelize}Controller".constantize rescue nil) || ApplicationController

          controller_class.instance_variable_set(:@js_env, nil)
          # this extends the controller's helper methods to the view
          # however, these methods are delegated to the test controller
          view.singleton_class.class_eval do
            include controller_class._helpers unless included_modules.include?(controller_class._helpers)
          end

          # so create a "real_controller"
          # and delegate the helper methods to it
          @controller.singleton_class.class_eval do
            attr_accessor :real_controller

            controller_class._helper_methods.each do |helper|
              delegate helper, :to => :real_controller
            end
          end

          real_controller = controller_class.new
          real_controller.instance_variable_set(:@_request, @controller.request)
          @controller.real_controller = real_controller

          # just calling "render 'path/to/view'" by default looks for a partial
          if args.first && args.first.is_a?(String)
            file = args.shift
            args = [{:template => file}] + args
          end
          render_without_helpers(*args)
        end

        alias_method_chain :render, :helpers
      end
    end

    module Matchers
      class HaveTag
        include ActionDispatch::Assertions::SelectorAssertions
        include Test::Unit::Assertions

        def initialize(expected)
          @expected = expected
        end

        def matches?(html, &block)
          @selected = [HTML::Document.new(html).root]
          assert_select(*@expected, &block)
          return !@failed
        end

        def assert(val, msg=nil)
          unless !!val
            @msg = msg
            @failed = true
          end
        end

        def failure_message_for_should
          @msg
        end

        def failure_message_for_should_not
          @msg
        end
      end

      def have_tag(*args)
        HaveTag.new(args)
      end
    end
  end
end
require 'action_controller_test_process'
require File.expand_path(File.dirname(__FILE__) + '/mocha_rspec_adapter')
require File.expand_path(File.dirname(__FILE__) + '/mocha_extensions')
require File.expand_path(File.dirname(__FILE__) + '/ams_spec_helper')

require 'i18n_tasks'
require 'handlebars_tasks'

# if mocha was initialized before rails (say by another spec), CollectionProxy would have
# undef_method'd them; we need to restore them
unless CANVAS_RAILS2
  Mocha::ObjectMethods.instance_methods.each do |m|
    ActiveRecord::Associations::CollectionProxy.class_eval <<-RUBY
      def #{m}; end
      remove_method #{m.inspect}
    RUBY
  end
end

Dir.glob("#{File.dirname(__FILE__).gsub(/\\/, "/")}/factories/*.rb").each { |file| require file }

def pend_with_bullet
  if defined?(Bullet) && Bullet.enable?
    pending ('PENDING: Bullet')
  end
end

def require_webmock
  # pull in webmock for selected tests, but leave it disabled by default.
  # funky require order is to skip typhoeus because of an incompatibility
  # see: https://github.com/typhoeus/typhoeus/issues/196
  require 'webmock/util/version_checker'
  require 'webmock/http_lib_adapters/http_lib_adapter_registry'
  require 'webmock/http_lib_adapters/http_lib_adapter'
  require 'webmock/http_lib_adapters/typhoeus_hydra_adapter'
  WebMock::HttpLibAdapterRegistry.instance.http_lib_adapters.delete :typhoeus
  require 'webmock/rspec'
end

# rspec aliases :describe to :context in a way that it's pretty much defined
# globally on every object. :context is already heavily used in our application,
# so we remove rspec's definition. This does not prevent 'context' from being
# used within a 'describe' block.

if defined?(Spec::DSL::Main)
  module Spec::DSL::Main
    remove_method :context if respond_to? :context
  end
end

def truncate_table(model)
  case model.connection.adapter_name
    when "SQLite"
      model.delete_all
      begin
        model.connection.execute("delete from sqlite_sequence where name='#{model.connection.quote_table_name(model.table_name)}';")
        model.connection.execute("insert into sqlite_sequence (name, seq) values ('#{model.connection.quote_table_name(model.table_name)}', #{rand(100)});")
      rescue
      end
    when "PostgreSQL"
      begin
        old_proc = model.connection.raw_connection.set_notice_processor {}
        model.connection.execute("TRUNCATE TABLE #{model.connection.quote_table_name(model.table_name)} CASCADE")
      ensure
        model.connection.raw_connection.set_notice_processor(&old_proc)
      end
    else
      model.connection.execute("SET FOREIGN_KEY_CHECKS=0")
      model.connection.execute("TRUNCATE TABLE #{model.connection.quote_table_name(model.table_name)}")
      model.connection.execute("SET FOREIGN_KEY_CHECKS=1")
  end
end

def truncate_all_tables
  models_by_connection = ActiveRecord::Base.all_models.group_by { |m| m.connection }
  models_by_connection.each do |connection, models|
    if connection.adapter_name == "PostgreSQL"
      table_names = connection.tables & models.map(&:table_name)
      connection.execute("TRUNCATE TABLE #{table_names.map { |t| connection.quote_table_name(t) }.join(',')}")
    else
      table_names = connection.tables
      models.each { |model| truncate_table(model) if table_names.include?(model.table_name) }
    end
  end
end

def truncate_all_cassandra_tables
  Canvas::Cassandra::DatabaseBuilder.config_names.each do |cass_config|
    db = Canvas::Cassandra::DatabaseBuilder.from_config(cass_config)
    db.tables.each do |table|
      db.execute("TRUNCATE #{table}")
    end
  end
end

# wipe out the test db, in case some non-transactional tests crapped out before
# cleaning up after themselves
truncate_all_tables

# Make AR not puke if MySQL auto-commits the transaction
module MysqlOutsideTransaction
  def outside_transaction?
    # MySQL ignores creation of savepoints outside of a transaction; so if we can create one
    # and then can't release it because it doesn't exist, we're not in a transaction
    execute('SAVEPOINT outside_transaction')
    !!execute('RELEASE SAVEPOINT outside_transaction') rescue true
  end
end

module ActiveRecord::ConnectionAdapters
  if defined?(MysqlAdapter)
    MysqlAdapter.send(:include, MysqlOutsideTransaction)
  end
  if defined?(Mysql2Adapter)
    Mysql2Adapter.send(:include, MysqlOutsideTransaction)
  end
end

# Be sure to actually test serializing things to non-existent caches,
# but give Mocks a pass, since they won't exist in dev/prod
Mocha::Mock.class_eval do
  def marshal_dump
    nil
  end

  def marshal_load(data)
    raise "Mocks aren't really serializeable!"
  end

  def respond_to_with_marshalling?(symbol, include_private = false)
    return true if [:marshal_dump, :marshal_load].include?(symbol)
    respond_to_without_marshalling?(symbol, include_private)
  end

  alias_method_chain :respond_to?, :marshalling
end

[ActiveSupport::Cache::MemoryStore, (CANVAS_RAILS2 ? NilStore : ActiveSupport::Cache::NullStore)].each do |store|
  store.class_eval do
    def write_with_serialization_check(name, value, options = nil)
      Marshal.dump(value)
      write_without_serialization_check(name, value, options)
    end

    alias_method_chain :write, :serialization_check
  end
end

unless CANVAS_RAILS2
  ActiveSupport::Cache::NullStore.class_eval do
    def fetch_with_serialization_check(name, options = {}, &block)
      result = fetch_without_serialization_check(name, options, &block)
      Marshal.dump(result) if result
      result
    end

    alias_method_chain :fetch, :serialization_check
  end
end

matchers_module = (CANVAS_RAILS2 ? Spec::Matchers : RSpec::Matchers)
matchers_module.define :encompass do |expected|
  match do |actual|
    if expected.is_a?(Array) && actual.is_a?(Array)
      expected.size == actual.size && expected.zip(actual).all? { |e, a| a.slice(*e.keys) == e }
    elsif expected.is_a?(Hash) && actual.is_a?(Hash)
      actual.slice(*expected.keys) == expected
    else
      false
    end
  end
end

matchers_module.define :match_ignoring_whitespace do |expected|
  def whitespaceless(str)
    str.gsub(/\s+/, '')
  end

  match do |actual|
    whitespaceless(actual) == whitespaceless(expected)
  end
end

module Helpers
  def message(opts={})
    m = Message.new
    m.to = opts[:to] || 'some_user'
    m.from = opts[:from] || 'some_other_user'
    m.subject = opts[:subject] || 'a message for you'
    m.body = opts[:body] || 'nice body'
    m.sent_at = opts[:sent_at] || 5.days.ago
    m.workflow_state = opts[:workflow_state] || 'sent'
    m.user_id = opts[:user_id] || opts[:user].try(:id)
    m.path_type = opts[:path_type] || 'email'
    m.root_account_id = opts[:account_id] || Account.default.id
    m.save!
    m
  end
end

# Make sure extensions will work with dynamically created shards
if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL' &&
    ActiveRecord::Base.connection.schema_search_path == 'public'
  %w{pg_trgm pg_collkey}.each do |extension|
    current_schema = ActiveRecord::Base.connection.select_value("SELECT nspname FROM pg_extension INNER JOIN pg_namespace ON extnamespace=pg_namespace.oid WHERE extname='#{extension}'")
    if current_schema && current_schema == 'public'
      ActiveRecord::Base.connection.execute("ALTER EXTENSION #{extension} SET SCHEMA pg_catalog") rescue nil
    end
  end
end

(CANVAS_RAILS2 ? Spec::Runner : RSpec).configure do |config|
  # If you're not using ActiveRecord you should remove these
  # lines, delete config/database.yml and disable :active_record
  # in your config/boot.rb
  config.use_transactional_fixtures = true
  config.use_instantiated_fixtures = false
  config.fixture_path = Rails.root+'spec/fixtures/'

  ((config.debug = true) rescue nil) unless CANVAS_RAILS2

  config.include Helpers

  config.before :all do
    # so before(:all)'s don't get confused
    Account.clear_special_account_cache!
    Notification.after_create { Notification.reset_cache! }
    AdheresToPolicy::Cache.clear

    # allow tests to still run in non-draft state even though it's hard-coded on
    Feature.definitions["draft_state"].send(:instance_variable_set, '@state', 'allowed')
  end

  def delete_fixtures!
    # noop for now, needed for plugin spec tweaks. implementation coming
    # in g/24755
  end

  # UTC for tests, cuz it's easier :P
  Account.time_zone_attribute_defaults[:default_time_zone] = 'UTC'

  config.before :each do
    I18n.locale = :en
    Time.zone = 'UTC'
    Account.clear_special_account_cache!
    Setting.reset_cache!
    ConfigFile.unstub
    HostUrl.reset_cache!
    Notification.reset_cache!
    ActiveRecord::Base.reset_any_instantiation!
    Attachment.clear_cached_mime_ids
    RoleOverride.clear_cached_contexts
    Delayed::Job.redis.flushdb if Delayed::Job == Delayed::Backend::Redis::Job
    truncate_all_cassandra_tables
    Rails::logger.try(:info, "Running #{self.class.description} #{@method_name}")
    Attachment.domain_namespace = nil
  end

  # flush redis before the first spec, and before each spec that comes after
  # one that used redis
  class << Canvas
    attr_accessor :redis_used

    def redis_with_track_usage(*a, &b)
      self.redis_used = true
      redis_without_track_usage(*a, &b)
    end

    alias_method_chain :redis, :track_usage
    Canvas.redis_used = true
  end
  config.before :each do
    if Canvas.redis_enabled? && Canvas.redis_used
      Canvas.redis.flushdb rescue nil
    end
    Canvas.redis_used = false
  end

  def account_with_cas(opts={})
    @account = opts[:account]
    @account ||= Account.create!
    config = AccountAuthorizationConfig.new
    cas_url = opts[:cas_url] || "https://localhost/cas"
    config.auth_type = "cas"
    config.auth_base = cas_url
    config.log_in_url = opts[:cas_log_in_url] if opts[:cas_log_in_url]
    @account.account_authorization_configs << config
    @account
  end

  def account_with_saml(opts={})
    @account = opts[:account]
    @account ||= Account.create!
    config = AccountAuthorizationConfig.new
    config.auth_type = "saml"
    config.log_in_url = opts[:saml_log_in_url] if opts[:saml_log_in_url]
    @account.account_authorization_configs << config
    @account
  end

  def course(opts={})
    account = opts[:account] || Account.default
    account.shard.activate do
      @course = Course.create!(:name => opts[:course_name], :account => account)
      @course.offer! if opts[:active_course] || opts[:active_all]
      if opts[:active_all]
        u = User.create!
        u.register!
        e = @course.enroll_teacher(u)
        e.workflow_state = 'active'
        e.save!
        @teacher = u
      end
      if opts[:draft_state]
        account.allow_feature!(:draft_state)
        @course.enable_feature!(:draft_state)
      end
    end
    @course
  end

  def account_admin_user_with_role_changes(opts={})
    account = opts[:account] || Account.default
    if opts[:role_changes]
      opts[:role_changes].each_pair do |permission, enabled|
        account.role_overrides.create(:permission => permission.to_s, :enrollment_type => opts[:membership_type] || 'AccountAdmin', :enabled => enabled)
      end
    end
    RoleOverride.clear_cached_contexts
    account_admin_user(opts)
  end

  def account_admin_user(opts={:active_user => true})
    account = opts[:account] || Account.default
    @user = opts[:user] || account.shard.activate { user(opts) }
    @admin = @user
    account_user = @user.account_users.build(:account => account, :membership_type => opts[:membership_type] || 'AccountAdmin')
    account_user.shard = account.shard
    account_user.save!
    @user
  end

  def site_admin_user(opts={})
    @user = opts[:user] || user(opts)
    @admin = @user
    Account.site_admin.add_user(@user, opts[:membership_type] || 'AccountAdmin')
    @user
  end

  def user(opts={})
    @user = User.create!(opts.slice(:name, :short_name))
    if opts[:active_user] || opts[:active_all]
      @user.accept_terms
      @user.register!
    end
    @user.update_attribute :workflow_state, opts[:user_state] if opts[:user_state]
    @user
  end

  def user_with_pseudonym(opts={})
    user(opts) unless opts[:user]
    user = opts[:user] || @user
    @pseudonym = pseudonym(user, opts)
    user
  end

  def communication_channel(user, opts={})
    username = opts[:username] || "nobody@example.com"
    @cc = user.communication_channels.create!(:path_type => 'email', :path => username) do |cc|
      cc.workflow_state = 'active' if opts[:active_cc] || opts[:active_all]
      cc.workflow_state = opts[:cc_state] if opts[:cc_state]
    end
    @cc.should_not be_nil
    @cc.should_not be_new_record
    @cc
  end

  def user_with_communication_channel(opts={})
    user(opts) unless opts[:user]
    user = opts[:user] || @user
    @cc = communication_channel(user, opts)
    user
  end

  def pseudonym(user, opts={})
    @spec_pseudonym_count ||= 0
    username = opts[:username] || (@spec_pseudonym_count > 0 ? "nobody+#{@spec_pseudonym_count}@example.com" : "nobody@example.com")
    opts[:username] ||= username
    @spec_pseudonym_count += 1 if username =~ /nobody(\+\d+)?@example.com/
    password = opts[:password] || "asdfasdf"
    password = nil if password == :autogenerate
    account = opts[:account] || Account.default
    @pseudonym = account.pseudonyms.build(:user => user, :unique_id => username, :password => password, :password_confirmation => password)
    @pseudonym.save_without_session_maintenance
    @pseudonym.communication_channel = communication_channel(user, opts)
    @pseudonym
  end

  def managed_pseudonym(user, opts={})
    other_account = opts[:account] || account_with_saml
    if other_account.password_authentication?
      config = other_account.account_authorization_configs.build
      config.auth_type = "saml"
      config.log_in_url = opts[:saml_log_in_url] if opts[:saml_log_in_url]
      config.save!
    end
    opts[:account] = other_account
    pseudonym(user, opts)
    @pseudonym.sis_user_id = opts[:sis_user_id] || "U001"
    @pseudonym.save!
    @pseudonym.should be_managed_password
    @pseudonym
  end

  def user_with_managed_pseudonym(opts={})
    user(opts) unless opts[:user]
    user = opts[:user] || @user
    managed_pseudonym(user, opts)
    user
  end

  def course_with_user(enrollment_type, opts={})
    @course = opts[:course] || course(opts)
    @user = opts[:user] || @course.shard.activate { user(opts) }
    @enrollment = @course.enroll_user(@user, enrollment_type, opts)
    @user.save!
    @enrollment.course = @course # set the reverse association
    if opts[:active_enrollment] || opts[:active_all]
      @enrollment.workflow_state = 'active'
      @enrollment.save!
    end
    @course.reload
    @enrollment
  end

  def course_with_student(opts={})
    course_with_user('StudentEnrollment', opts)
    @student = @user
    @enrollment
  end

  def course_with_ta(opts={})
    course_with_user("TaEnrollment", opts)
    @ta = @user
    @enrollment
  end

  def course_with_student_logged_in(opts={})
    course_with_student(opts)
    user_session(@user)
  end

  def student_in_course(opts={})
    opts[:course] = @course if @course && !opts[:course]
    course_with_student(opts)
  end

  def student_in_section(section, opts={})
    student = opts.fetch(:user) { user }
    enrollment = section.course.enroll_user(student, 'StudentEnrollment', :section => section)
    student.save!
    enrollment.workflow_state = 'active'
    enrollment.save!
    student
  end

  def teacher_in_course(opts={})
    opts[:course] = @course if @course && !opts[:course]
    course_with_teacher(opts)
  end

  def course_with_teacher(opts={})
    course_with_user('TeacherEnrollment', opts)
    @teacher = @user
    @enrollment
  end

  def course_with_designer(opts={})
    course_with_user('DesignerEnrollment', opts)
    @designer = @user
    @enrollment
  end

  def course_with_teacher_logged_in(opts={})
    course_with_teacher(opts)
    user_session(@user)
  end

  def course_with_observer(opts={})
    course_with_user('ObserverEnrollment', opts)
    @observer = @user
    @enrollment
  end

  def course_with_observer_logged_in(opts={})
    course_with_observer(opts)
    user_session(@user)
  end

  def course_with_student_submissions(opts={})
    course_with_teacher_logged_in(opts)
    student_in_course
    submission_count = opts[:submissions] || 1
    submission_count.times do |s|
      assignment = @course.assignments.create!(:title => "test #{s} assignment")
      submission = assignment.submissions.create!(:assignment_id => assignment.id, :user_id => @student.id)
      submission.update_attributes!(score: '5') if opts[:submission_points]
    end
  end

  def set_course_draft_state(enabled=true, opts={})
    course = opts[:course] || @course
    account = opts[:account] || course.account

    account.allow_feature!(:draft_state)
    course.set_feature_flag!(:draft_state, enabled ? 'on' : 'off')

    enabled
  end

  def add_section(section_name)
    @course_section = @course.course_sections.create!(:name => section_name)
    @course.reload
  end

  def multiple_student_enrollment(user, section)
    @enrollment = @course.enroll_student(user,
                                         :enrollment_state => "active",
                                         :section => section,
                                         :allow_multiple_enrollments => true)
  end

  def enter_student_view(opts={})
    course = opts[:course] || @course || course(opts)
    @fake_student = course.student_view_student
    post "/users/#{@fake_student.id}/masquerade"
    session[:become_user_id].should == @fake_student.id.to_s
  end

  def account_notification(opts={})
    req_service = opts[:required_account_service] || nil
    roles = opts[:roles] || []
    message = opts[:message] || "hi there"
    @account = opts[:account] || Account.default
    @announcement = @account.announcements.build(message: message, required_account_service: req_service)
    @announcement.start_at = opts[:start_at] || 5.minutes.ago.utc
    @announcement.account_notification_roles.build(roles.map { |r| {account_notification_id: @announcement.id, role_type: r} }) unless roles.empty?
    @announcement.save!
  end

  VALID_GROUP_ATTRIBUTES = [:name, :context, :max_membership, :group_category, :join_level, :description, :is_public, :avatar_attachment]

  def group(opts={})
    context = opts[:group_context] || opts[:context] || Account.default
    @group = context.groups.create! opts.slice(*VALID_GROUP_ATTRIBUTES)
  end

  def group_with_user(opts={})
    group(opts)
    u = opts[:user] || user(opts)
    workflow_state = opts[:active_all] ? 'accepted' : nil
    @group.add_user(u, workflow_state, opts[:moderator])
  end

  def group_with_user_logged_in(opts={})
    group_with_user(opts)
    user_session(@user)
  end

  def group_category(opts = {})
    context = opts[:context] || @course
    @group_category = context.group_categories.create!(name: opts[:name] || 'foo')
  end

  def custom_role(base, name, opts={})
    account = opts[:account] || @account
    role = account.roles.find_by_name(name)
    role ||= account.roles.create :name => name
    role.base_role_type = base
    role.save!
    role
  end

  def custom_student_role(name, opts={})
    custom_role('StudentEnrollment', name, opts)
  end

  def custom_teacher_role(name, opts={})
    custom_role('TeacherEnrollment', name, opts)
  end

  def custom_ta_role(name, opts={})
    custom_role('TaEnrollment', name, opts)
  end

  def custom_designer_role(name, opts={})
    custom_role('DesignerEnrollment', name, opts)
  end

  def custom_observer_role(name, opts={})
    custom_role('ObserverEnrollment', name, opts)
  end

  def custom_account_role(name, opts={})
    custom_role(AccountUser::BASE_ROLE_NAME, name, opts)
  end

  def user_session(user, pseudonym=nil)
    unless pseudonym
      pseudonym = stub('Pseudonym', :record => user, :user_id => user.id, :user => user, :login_count => 1)
      # at least one thing cares about the id of the pseudonym... using the
      # object_id should make it unique (but obviously things will fail if
      # it tries to load it from the db.)
      pseudonym.stubs(:id).returns(pseudonym.object_id)
    end

    session = stub('PseudonymSession', :record => pseudonym, :session_credentials => nil, :used_basic_auth? => false)

    PseudonymSession.stubs(:find).returns(session)
  end

  def remove_user_session
    PseudonymSession.unstub(:find)
  end

  def login_as(username = "nobody@example.com", password = "asdfasdf")
    post_via_redirect "/login",
                      "pseudonym_session[unique_id]" => username,
                      "pseudonym_session[password]" => password
    assert_response :success
    request.fullpath.should eql("/?login_success=1")
  end

  def assignment_quiz(questions, opts={})
    course = opts[:course] || course(:active_course => true)
    user = opts[:user] || user(:active_user => true)
    course.enroll_student(user, :enrollment_state => 'active') unless user.enrollments.any? { |e| e.course_id == course.id }
    @assignment = course.assignments.create(:title => "Test Assignment")
    @assignment.workflow_state = "published"
    @assignment.submission_types = "online_quiz"
    @assignment.save
    @quiz = Quizzes::Quiz.find_by_assignment_id(@assignment.id)
    @questions = questions.map { |q| @quiz.quiz_questions.create!(q) }
    @quiz.generate_quiz_data
    @quiz.published_at = Time.now
    @quiz.workflow_state = "available"
    @quiz.save!
  end

  # The block should return the submission_data. A block is used so
  # that we have access to the @questions variable that is created
  # in this method
  def quiz_with_graded_submission(questions, opts={}, &block)
    assignment_quiz(questions, opts)
    @quiz_submission = @quiz.generate_submission(@user)
    @quiz_submission.mark_completed
    @quiz_submission.submission_data = yield if block_given?
    Quizzes::SubmissionGrader.new(@quiz_submission).grade_submission
  end

  def survey_with_submission(questions, &block)
    course_with_student(:active_all => true)
    @assignment = @course.assignments.create(:title => "Test Assignment")
    @assignment.workflow_state = "published"
    @assignment.submission_types = "online_quiz"
    @assignment.save
    @quiz = Quizzes::Quiz.find_by_assignment_id(@assignment.id)
    @quiz.anonymous_submissions = true
    @quiz.quiz_type = "graded_survey"
    @questions = questions.map { |q| @quiz.quiz_questions.create!(q) }
    @quiz.generate_quiz_data
    @quiz.save!
    @quiz_submission = @quiz.generate_submission(@user)
    @quiz_submission.mark_completed
    @quiz_submission.submission_data = yield if block_given?
  end

  def group_discussion_assignment
    course = @course || course(:active_all => true)
    group_category = course.group_categories.create!(:name => "category")
    @group1 = course.groups.create!(:name => "group 1", :group_category => group_category)
    @group2 = course.groups.create!(:name => "group 2", :group_category => group_category)

    @topic = course.discussion_topics.build(:title => "topic")
    @topic.group_category = group_category
    @assignment = course.assignments.build(:submission_types => 'discussion_topic', :title => @topic.title)
    @assignment.infer_times
    @assignment.saved_by = :discussion_topic
    @topic.assignment = @assignment
    @topic.save!
  end

  def rubric_for_course
    @rubric = Rubric.new(:title => 'My Rubric', :context => @course)
    @rubric.data = [
        {
            :points => 3,
            :description => "First row",
            :long_description => "The first row in the rubric",
            :id => 1,
            :ratings => [
                {
                    :points => 3,
                    :description => "Rockin'",
                    :criterion_id => 1,
                    :id => 2
                },
                {
                    :points => 2,
                    :description => "Rockin'",
                    :criterion_id => 1,
                    :id => 3
                },
                {
                    :points => 0,
                    :description => "Lame",
                    :criterion_id => 1,
                    :id => 4
                }
            ]
        }
    ]
    @rubric.save!
  end

  def outcome_with_rubric(opts={})
    @outcome_group ||= @course.root_outcome_group
    @outcome = @course.created_learning_outcomes.create!(:description => '<p>This is <b>awesome</b>.</p>', :short_description => 'new outcome')
    @outcome_group.add_outcome(@outcome)
    @outcome_group.save!

    rubric_params = {
        :title => 'My Rubric',
        :hide_score_total => false,
        :criteria => {
            "0" => {
                :points => 3,
                :mastery_points => opts[:mastery_points] || 0,
                :description => "Outcome row",
                :long_description => @outcome.description,
                :ratings => {
                    "0" => {
                        :points => 3,
                        :description => "Rockin'",
                    },
                    "1" => {
                        :points => 0,
                        :description => "Lame",
                    }
                },
                :learning_outcome_id => @outcome.id
            },
            "1" => {
                :points => 5,
                :description => "no outcome row",
                :long_description => 'non outcome criterion',
                :ratings => {
                    "0" => {
                        :points => 5,
                        :description => "Amazing",
                    },
                    "1" => {
                        :points => 3,
                        :description => "not too bad",
                    },
                    "2" => {
                        :points => 0,
                        :description => "no bueno",
                    }
                }
            }
        }
    }

    @rubric = @course.rubrics.build
    @rubric.update_criteria(rubric_params)
    @rubric.reload
  end

  def grading_standard_for(context, opts={})
    @standard = context.grading_standards.create!(
        :title => opts[:title] || "My Grading Standard",
        :standard_data => {
            "scheme_0" => {:name => "A", :value => "0.9"},
            "scheme_1" => {:name => "B", :value => "0.8"},
            "scheme_2" => {:name => "C", :value => "0.7"}
        })
  end

  def eportfolio(opts={})
    user(opts)
    @portfolio = @user.eportfolios.create!
  end

  def eportfolio_with_user(opts={})
    eportfolio(opts)
  end

  def eportfolio_with_user_logged_in(opts={})
    eportfolio_with_user(opts)
    user_session(@user)
  end

  def conversation(*users)
    options = users.last.is_a?(Hash) ? users.pop : {}
    @conversation = (options.delete(:sender) || @me || users.shift).initiate_conversation(users, options.delete(:private))
    @message = @conversation.add_message('test')
    @conversation.update_attributes(options)
    @conversation.reload
  end

  def media_object(opts={})
    mo = MediaObject.new
    mo.media_id = opts[:media_id] || "1234"
    mo.media_type = opts[:media_type] || "video"
    mo.context = opts[:context] || @course
    mo.user = opts[:user] || @user
    mo.save!
    mo
  end

  def assert_status(status=500)
    response.status.to_i.should eql(status)
  end

  def assert_unauthorized
    assert_status(401) #unauthorized
    #    response.headers['Status'].should eql('401 Unauthorized')
    response.should render_template("shared/unauthorized")
  end

  def assert_page_not_found(&block)
    if CANVAS_RAILS2
      block.should raise_exception(ActiveRecord::RecordNotFound)
    else
      yield
      assert_status(404)
    end
  end

  def assert_require_login
    response.should be_redirect
    flash[:warning].should eql("You must be logged in to access this page")
  end

  def fixture_file_upload(path, mime_type=nil, binary=false)
    Rack::Test::UploadedFile.new(File.join(ActionController::TestCase.fixture_path, path), mime_type, binary)
  end

  def default_uploaded_data
    fixture_file_upload('scribd_docs/doc.doc', 'application/msword', true)
  end

  def valid_gradebook_csv_content
    File.read(File.expand_path(File.join(File.dirname(__FILE__), %w(fixtures default_gradebook.csv))))
  end

  def factory_with_protected_attributes(ar_klass, attrs, do_save = true)
    obj = ar_klass.respond_to?(:new) ? ar_klass.new : ar_klass.build
    attrs.each { |k, v| obj.send("#{k}=", attrs[k]) }
    obj.save! if do_save
    obj
  end

  def update_with_protected_attributes!(ar_instance, attrs)
    attrs.each { |k, v| ar_instance.send("#{k}=", attrs[k]) }
    ar_instance.save!
  end

  def update_with_protected_attributes(ar_instance, attrs)
    update_with_protected_attributes!(ar_instance, attrs) rescue false
  end

  def process_csv_data(*lines)
    opts = lines.extract_options!
    opts.reverse_merge!(allow_printing: false)
    account = opts[:account] || @account || account_model

    tmp = Tempfile.new("sis_rspec")
    path = "#{tmp.path}.csv"
    tmp.close!
    File.open(path, "w+") { |f| f.puts lines.flatten.join "\n" }
    opts[:files] = [path]

    importer = SIS::CSV::Import.process(account, opts)

    File.unlink path

    importer
  end

  def process_csv_data_cleanly(*lines_or_opts)
    importer = process_csv_data(*lines_or_opts)
    importer.errors.should == []
    importer.warnings.should == []
  end

  def enable_cache(new_cache=:memory_store)
    new_cache ||= :null_store
    if CANVAS_RAILS2 && new_cache == :null_store
      require 'nil_store'
      new_cache = NilStore.new
    end
    new_cache = ActiveSupport::Cache.lookup_store(new_cache)
    previous_cache = Rails.cache
    Rails.stubs(:cache).returns(new_cache)
    ActionController::Base.stubs(:cache_store).returns(new_cache)
    ActionController::Base.any_instance.stubs(:cache_store).returns(new_cache)
    previous_perform_caching = ActionController::Base.perform_caching
    ActionController::Base.stubs(:perform_caching).returns(true)
    ActionController::Base.any_instance.stubs(:perform_caching).returns(true)
    if block_given?
      begin
        yield
      ensure
        Rails.stubs(:cache).returns(previous_cache)
        ActionController::Base.stubs(:cache_store).returns(previous_cache)
        ActionController::Base.any_instance.stubs(:cache_store).returns(previous_cache)
        ActionController::Base.stubs(:perform_caching).returns(previous_perform_caching)
        ActionController::Base.any_instance.stubs(:perform_caching).returns(previous_perform_caching)
      end
    end
  end

  # enforce forgery protection, so we can verify usage of the authenticity token
  def enable_forgery_protection(enable = true)
    old_value = ActionController::Base.allow_forgery_protection
    ActionController::Base.stubs(:allow_forgery_protection).returns(enable)
    ActionController::Base.any_instance.stubs(:allow_forgery_protection).returns(enable)

    yield if block_given?

  ensure
    if block_given?
      ActionController::Base.stubs(:allow_forgery_protection).returns(old_value)
      ActionController::Base.any_instance.stubs(:allow_forgery_protection).returns(old_value)
    end
  end

  def stub_kaltura
    # trick kaltura into being activated
    CanvasKaltura::ClientV3.stubs(:config).returns({
                                                 'domain' => 'kaltura.example.com',
                                                 'resource_domain' => 'kaltura.example.com',
                                                 'partner_id' => '100',
                                                 'subpartner_id' => '10000',
                                                 'secret_key' => 'fenwl1n23k4123lk4hl321jh4kl321j4kl32j14kl321',
                                                 'user_secret_key' => '1234821hrj3k21hjk4j3kl21j4kl321j4kl3j21kl4j3k2l1',
                                                 'player_ui_conf' => '1',
                                                 'kcw_ui_conf' => '1',
                                                 'upload_ui_conf' => '1'
                                             })
  end

  def attachment_obj_with_context(obj, opts={})
    @attachment = factory_with_protected_attributes(Attachment, valid_attachment_attributes.merge(opts))
    @attachment.context = obj
    @attachment
  end

  def attachment_with_context(obj, opts={})
    attachment_obj_with_context(obj, opts)
    @attachment.save!
    @attachment
  end

  def json_parse(json_string = response.body)
    JSON.parse(json_string.sub(%r{^while\(1\);}, ''))
  end

  # inspired by http://blog.jayfields.com/2007/08/ruby-calling-methods-of-specific.html
  module AttachmentStorageSwitcher
    BACKENDS = %w{FileSystem S3}.map { |backend| Technoweenie::AttachmentFu::Backends.const_get(:"#{backend}Backend") }.freeze

    class As #:nodoc:
      private *instance_methods.select { |m| m !~ /(^__|^\W|^binding$)/ }

      def initialize(subject, ancestor)
        @subject = subject
        @ancestor = ancestor
      end

      def method_missing(sym, *args, &blk)
        @ancestor.instance_method(sym).bind(@subject).call(*args, &blk)
      end
    end

    def self.included(base)
      base.cattr_accessor :current_backend
      base.current_backend = (base.ancestors & BACKENDS).first

      # make sure we have all the backends
      BACKENDS.each do |backend|
        base.send(:include, backend) unless base.ancestors.include?(backend)
      end
      # remove the duplicate callbacks added by multiple backends
      base.before_update.uniq!

      BACKENDS.map(&:instance_methods).flatten.uniq.each do |method|
        # overridden by Attachment anyway; don't re-overwrite it
        next if Attachment.instance_method(method).owner == Attachment
        if method.to_s[-1..-1] == '='
          base.class_eval <<-CODE
          def #{method}(arg)
            self.as(self.class.current_backend).#{method} arg
          end
          CODE
        else
          base.class_eval <<-CODE
          def #{method}(*args, &block)
            self.as(self.class.current_backend).#{method}(*args, &block)
          end
          CODE
        end
      end
    end

    def as(ancestor)
      @__as ||= {}
      unless r = @__as[ancestor]
        r = (@__as[ancestor] = As.new(self, ancestor))
      end
      r
    end
  end

  def s3_storage!(opts = {:stubs => true})
    Attachment.send(:include, AttachmentStorageSwitcher) unless Attachment.ancestors.include?(AttachmentStorageSwitcher)
    Attachment.stubs(:current_backend).returns(Technoweenie::AttachmentFu::Backends::S3Backend)

    Attachment.stubs(:s3_storage?).returns(true)
    Attachment.stubs(:local_storage?).returns(false)
    if opts[:stubs]
      conn = mock('AWS::S3::Client')
      AWS::S3::S3Object.any_instance.stubs(:client).returns(conn)
      AWS::Core::Configuration.any_instance.stubs(:access_key_id).returns('stub_id')
      AWS::Core::Configuration.any_instance.stubs(:secret_access_key).returns('stub_key')
      AWS::S3::Bucket.any_instance.stubs(:name).returns('no-bucket')
    else
      if Attachment.s3_config.blank? || Attachment.s3_config[:access_key_id] == 'access_key'
        pending "Please put valid S3 credentials in config/amazon_s3.yml"
      end
    end
    Attachment.s3_storage?.should eql(true)
    Attachment.local_storage?.should eql(false)
  end

  def local_storage!
    Attachment.send(:include, AttachmentStorageSwitcher) unless Attachment.ancestors.include?(AttachmentStorageSwitcher)
    Attachment.stubs(:current_backend).returns(Technoweenie::AttachmentFu::Backends::FileSystemBackend)

    Attachment.stubs(:s3_storage?).returns(false)
    Attachment.stubs(:local_storage?).returns(true)
    Attachment.local_storage?.should eql(true)
    Attachment.s3_storage?.should eql(false)
    Attachment.local_storage?.should eql(true)
  end

  def run_job(job)
    Delayed::Worker.new.perform(job)
  end

  def run_jobs
    while job = Delayed::Job.get_and_lock_next_available(
        'spec run_jobs',
        Delayed::Worker.queue,
        0,
        Delayed::MAX_PRIORITY)
      run_job(job)
    end
  end

  def track_jobs
    @jobs_tracking = Delayed::JobTracking.track { yield }
  end

  def created_jobs
    @jobs_tracking.created
  end

  def expects_job_with_tag(tag, count = 1)
    track_jobs do
      yield
    end
    created_jobs.count { |j| j.tag == tag }.should == count
  end

  # send a multipart post request in an integration spec post_params is
  # an array of [k,v] params so that the order of the params can be
  # defined
  def send_multipart(url, post_params = {}, http_headers = {}, method = :post)
    mp = Multipart::Post.new
    query, headers = mp.prepare_query(post_params)

    # A bug in the testing adapter in Rails 3-2-stable doesn't corretly handle
    # translating this header to the Rack/CGI compatible version:
    # (https://github.com/rails/rails/blob/3-2-stable/actionpack/lib/action_dispatch/testing/integration.rb#L289)
    #
    # This issue is fixed in Rails 4-0 stable, by using a newer version of
    # ActionDispatch Http::Headers which correctly handles the merge
    headers = headers.dup.tap { |h| h['CONTENT_TYPE'] ||= h.delete('Content-type') }

    send(method, url, query, headers.merge(http_headers))
  end

  def force_string_encoding(str, encoding = "UTF-8")
    if str.respond_to?(:force_encoding)
      str.force_encoding(encoding)
    end
    str
  end

  # from minitest, MIT licensed
  def capture_io
    orig_stdout, orig_stderr = $stdout, $stderr
    $stdout, $stderr = StringIO.new, StringIO.new
    yield
    return $stdout.string, $stderr.string
  ensure
    $stdout, $stderr = orig_stdout, orig_stderr
  end

  def verify_post_matches(post_lines, expected_post_lines)
    # first lines should match
    post_lines[0].should == expected_post_lines[0]

    # now extract the headers
    post_headers = post_lines[1..post_lines.index("")]
    expected_post_headers = expected_post_lines[1..expected_post_lines.index("")]
    expected_post_headers << "User-Agent: Ruby"
    post_headers.sort.should == expected_post_headers.sort

    # now check payload
    post_lines[post_lines.index(""), -1].should ==
        expected_post_lines[expected_post_lines.index(""), -1]
  end

  def compare_json(actual, expected)
    if actual.is_a?(Hash)
      actual.each do |k, v|
        expected_v = expected[k]
        compare_json(v, expected_v)
      end
    elsif actual.is_a?(Array)
      actual.zip(expected).each do |a, e|
        compare_json(a, e)
      end
    else
      if actual.is_a?(Fixnum) || actual.is_a?(Float)
        actual.should == expected
      else
        actual.to_json.should == expected.to_json
      end
    end
  end

  class FakeHttpResponse
    def initialize(code, body = nil, headers={})
      @code = code
      @body = body
      @headers = headers
    end

    def read_body(io)
      io << @body
    end

    def code
      @code.to_s
    end

    def [](arg)
      @headers[arg]
    end

    def content_type
      self['content-type']
    end
  end

  def intify_timestamps(object)
    case object
      when Time
        object.to_i
      when Hash
        object.inject({}) { |memo, (k, v)| memo[intify_timestamps(k)] = intify_timestamps(v); memo }
      when Array
        object.map { |v| intify_timestamps(v) }
      else
        object
    end
  end

  def web_conference_plugin_mock(id, settings)
    mock = mock("WebConferencePlugin")
    mock.stubs(:id).returns(id)
    mock.stubs(:settings).returns(settings)
    mock.stubs(:valid_settings?).returns(true)
    mock.stubs(:enabled?).returns(true)
    mock.stubs(:base).returns(nil)
    mock
  end

  def dummy_io
    fixture_file_upload('scribd_docs/doc.doc', 'application/msword', true)
  end

  def create_attachment_for_file_upload_submission!(submission, opts={})
    submission.attachments.create! opts.merge(
                                       :filename => "doc.doc",
                                       :display_name => "doc.doc", :user => @user,
                                       :uploaded_data => dummy_io)
  end

  def course_quiz(active=false)
    @quiz = @course.quizzes.create
    @quiz.workflow_state = "available" if active
    @quiz.save!
    @quiz
  end

  def n_students_in_course(n, opts={})
    opts.reverse_merge active_all: true
    n.times.map { student_in_course(opts); @student }
  end

  def consider_all_requests_local(value)
    if CANVAS_RAILS2
      ActionController::Base.consider_all_requests_local = value
    else
      Rails.application.config.consider_all_requests_local = value
    end
  end

  def page_view_for(opts={})
    @account = opts[:account] || Account.default
    @context = opts[:context] || course(opts)

    @request_id = opts[:request_id] || RequestContextGenerator.request_id
    unless @request_id
      @request_id = CanvasUUID.generate
      RequestContextGenerator.stubs(:request_id => @request_id)
    end

    Setting.set('enable_page_views', 'db')

    @page_view = PageView.new { |p|
      p.assign_attributes({
                              :id => @request_id,
                              :url => "http://test.one/",
                              :session_id => "phony",
                              :context => @context,
                              :controller => opts[:controller] || 'courses',
                              :action => opts[:action] || 'show',
                              :user_request => true,
                              :render_time => 0.01,
                              :user_agent => 'None',
                              :account_id => @account.id,
                              :request_id => request_id,
                              :interaction_seconds => 5,
                              :user => @user,
                              :remote_ip => '192.168.0.42'
                          }, :without_protection => true)
    }
    @page_view.save!
    @page_view
  end

  # a fast way to create a record, especially if you don't need the actual
  # ruby object. since it just does a straight up insert, you need to
  # provide any non-null attributes or things that would normally be
  # inferred/defaulted prior to saving
  def create_record(klass, attributes, return_type = :id)
    create_records(klass, [attributes], return_type)[0]
  end

  # a little wrapper around bulk_insert that gives you back records or ids
  # in order
  # NOTE: if you decide you want to go add something like this to canvas
  # proper, make sure you have it handle concurrent inserts (this does
  # not, because READ COMMITTED is the default transaction isolation
  # level)
  def create_records(klass, records, return_type = :id)
    return [] if records.empty?
    klass.transaction do
      klass.connection.bulk_insert klass.table_name, records
      scope = klass.order("id DESC").limit(records.size)
      return_type == :record ?
        scope.all.reverse :
        scope.pluck(:id).reverse
    end
  end
end

class String
  def red; colorize(self, "\e[1m\e[31m"); end
  def green; colorize(self, "\e[1m\e[32m"); end
  def dark_green; colorize(self, "\e[32m"); end
  def yellow; colorize(self, "\e[1m\e[33m"); end
  def blue; colorize(self, "\e[1m\e[34m"); end
  def dark_blue; colorize(self, "\e[34m"); end
  def pur; colorize(self, "\e[1m\e[35m"); end
  def colorize(text, color_code)  "#{color_code}#{text}\e[0m" end
end

Dir[Rails.root+'vendor/plugins/*/spec_canvas/spec_helper.rb'].each do |f|
  require f
end
