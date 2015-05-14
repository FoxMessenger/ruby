require 'pubnub/configuration'
require 'pubnub/parser'
require 'pubnub/envelope'
require 'pubnub/crypto'
require 'pubnub/uuid'
require 'pubnub/exceptions'
require 'pubnub/event'
require 'pubnub/formatter'
require 'pubnub/validator'
require 'pubnub/pam'
require 'pubnub/origin_manager'

module Pubnub
  class Client
    include Configuration

    attr_reader :env
    attr_accessor :single_event_connection, :subscribe_event_connection, :uuid, :async_events, :origin_manager

    EVENTS = %w(publish subscribe presence leave history here_now audit grant revoke time heartbeat where_now state set_state channel_registration)
    VERSION = Pubnub::VERSION

    EVENTS.each do |event_name|
      require File.join('pubnub', 'events', event_name)
    end

    EVENTS.each do |event_name|
      define_method event_name do |params = {}, &block|
        params[:callback] = block if params[:callback].nil?
        event = Pubnub.const_get(classify_method(event_name)).new(params, self)
        Pubnub.logger.debug(:pubnub){'Created event ' + event.class.to_s}
        event.fire(self)
      end
    end
    alias_method :unsubscribe, :leave

    def initialize(options)
      validate!(options)
      setup_app(options) # After that we have to use @env in that method instead of options
      create_connections(@env)
      create_subscriptions_pools(@env)
    end

    def paged_history(options = {}, &block)
      channel  = options[:channel]
      page     = options[:page]      || 1
      limit    = options[:limit]     || 100
      callback = options[:callback]  || block
      sync     = options[:http_sync] ? true : false
      start_tt = options[:start]     || nil
      end_tt   = options[:end]       || nil

      current_start_tt = start_tt

      if sync

          puts "page = #{page}"
          envelopes = nil
          page.times do
            envelopes = self.history(:channel => channel, :http_sync => true, :count => limit, :start => current_start_tt, :end => end_tt)
            current_start_tt = envelopes.last.history_start.to_i - 1
          end

          envelopes.each do |envelope|
            callback.call envelope
          end if callback


      else
        EM.defer do
          until msgs.size <= page * entries
            msgs.merge!(self.history(:channel => channel, :http_sync => true, :start => start_tt, :end => end_tt, :limit => entries))
          end

          msgs.reverse[0..entries].each do |envelope|
            callback.call envelope
          end

        end
      end

      envelopes

    end

    def state_for(origin = DEFAULT_ORIGINS_POOL.first)
      @env[:state][origin]
    end

    def shutdown(stop_em = false)
      @single_event_connection.each do |origin, conn|
        conn.shutdown_in_all_threads
        conn = nil
      end
      @single_event_connection = Hash.new

      @subscribe_event_connection.each do |origin, conn|
        conn.shutdown_in_all_threads
        conn = nil
      end
      @subscribe_event_connection = Hash.new

      @env[:callback_pool] = Hash.new

      EM.stop if stop_em

      Pubnub.logger.info(:pubnub){'Bye!'}
    end

    def stop_async
      Pubnub.logger.debug(:pubnub){'Pubnub::Client#stop_async | fired'}
      @env[:subscribe_railgun].cancel unless @env[:subscribe_railgun].blank?
      @env[:respirator].cancel        unless @env[:respirator].blank?
      @env[:subscribe_railgun].cancel unless @env[:subscribe_railgun].blank?

      @env[:subscribe_railgun] = nil
      @env[:respirator] = nil
      @env[:subscribe_railgun] = nil

      EM.stop

      Pubnub.logger.debug(:pubnub){'Pubnub::Client#stop_async | timers killed'}
    end

    def restore_async
      start_event_machine
      start_subscribe unless @env[:subscriptions].blank?
      start_railgun
    end

    def start_respirator
      Pubnub.logger.debug(:pubnub){'Pubnub::Client#start_respirator | fired'}
      if @env[:heartbeat]
        Pubnub.logger.debug(:pubnub){'Pubnub::Client#start_respirator | starting'}

        if @env[:heartbeat] != @env[:respirator].interval
          Pubnub.logger.debug(:pubnub){'Pubnub::Client#start_respirator | destroy old respirator'}
          @env[:respirator].cancel
          @env[:respirator] = nil
        end if @env[:respirator]

        @env[:respirator] = EM.add_periodic_timer((@env[:heartbeat].to_i/2) - 1) do
          # @env[:subscriptions].each do |origin, subscribe|
          #   Pubnub.logger.debug('Pubnub'){'Pubnub::Client#start_respirator | BUM'}
            EM.defer { heartbeat(:channel => @env[:subscriptions].get_channels, :group => @env[:subscriptions].get_channel_groups ){ |e| Pubnub.logger.debug('Pubnub::Client#start_respirator | bum') } }
          # end
        end unless @env[:respirator]

        Pubnub.logger.debug(:pubnub){'Pubnub::Client#start_respirator | started'}
      end
    end

    def start_subscribe(override = false)
      begin
        start_event_machine
        start_respirator if @env[:heartbeat]
        start_origin_manager unless @origin_manager || @env[:disable_origin_manager]

        if @env[:subscribe_railgun] && @subscribe_deffered_thread
          Pubnub.logger.debug('Pubnub'){'Pubnub::Client#start_subscribe | Aborting previous request'}
          @subscribe_deffered_thread.kill
          Thread.pass until @subscribe_deffered_thread.status == false
        end

        if override
          Pubnub.logger.debug('Pubnub'){'Pubnub::Client#start_subscribe | Override'}
          @env[:subscribe_railgun].cancel
          @env[:subscribe_railgun] = nil
        end

        @env[:wait_for_response] = false
        unless @env[:subscribe_railgun]
          @env[:subscribe_railgun] = EM.add_periodic_timer(PERIODIC_TIMER_INTERVAL) do
            begin
              unless @env[:wait_for_response]
                @env[:wait_for_response] = true

                Pubnub.logger.debug(:pubnub){'Async subscription running'}
                Pubnub.logger.debug(:pubnub){"timetoken: #{@env[:timetoken]}"}

                EM.defer do
                  @subscribe_deffered_thread = Thread.current
                  @env[:subscriptions].start_event(self) if @env[:subscriptions]
                end

              end
            rescue => e
              Pubnub.logger.error(:pubnub){e}
              Pubnub.logger.error(:pubnub){e.backtrace}
            end
          end
        end
      rescue => e
        Pubnub.logger.error(:pubnub){ "Critical error, subscription crashed. Error: #{e}\n#{e.backtrace}" }
      end
    end

    def subscription_running?
      @env[:subscribe_railgun] && !@env[:subscriptions] ? true : false
    end

    def create_subscriptions_pools(_env)
      @env[:callbacks_pool]       = Hash.new
      @env[:error_callbacks_pool] = Hash.new
    end

    def update_timetoken(timetoken)
      @env[:timetoken] = timetoken.to_i
      Pubnub.logger.debug(:pubnub){"Pubnub::Client#update_timetoken | Current timetoken is eq #{@env[:timetoken]}"}
    end

    def set_uuid(uuid)
      leave_all if @env[:subscriptions]
      @env[:uuid] = uuid
      start_subscribe(true) if @env[:subscriptions]
    end
    alias_method :session_uuid=, :set_uuid
    alias_method :uuid=, :set_uuid

    def uuid
      @env[:uuid]
    end

    def set_auth_key(auth_key)
      leave_all if @env[:subscriptions]
      @env[:auth_key] = auth_key
      start_subscribe(true) if @env[:subscriptions]
    end
    alias_method :auth_key=, :set_auth_key

    def set_heartbeat(heartbeat = nil)
      if heartbeat
        @env[:heartbeat] = heartbeat
      end
      @env[:heartbeat]
    end
    alias_method :heartbeat=, :set_heartbeat

    def get_heartbeat
      @env[:heartbeat]
    end

    def set_cipher_key(cipher_key)
      @env[:cipher_key] = cipher_key
    end
    alias_method :cipher_key=, :set_cipher_key

    def start_railgun
      start_event_machine(@env)
      if @env[:railgun]
        Pubnub.logger.debug(:pubnub){'Pubnub::Client#start_railgun | Railgun already initialized'}
      else
        Pubnub.logger.debug('Pubnub'){'Pubnub::Client#start_railgun | Initializing railgun'}
        @env[:railgun] = EM.add_periodic_timer(0.01) do
          begin
            if !async_halted? || !@env[:queue_on_origin_change]
              @async_events.each do |event|
                EM.defer do
                  event.fire(self) unless event.fired?
                end
              end
              @async_events.delete_if {|event| event.finished? }
            end
          rescue => e
            Pubnub.logger.error(:pubnub){e}
          end
        end
      end
    end

    def disabled_persistent_connection?
      @env[:disable_persistent_connection].present?
    end

    def start_origin_manager
      @origin_manager = OriginManager.new(self)
      @origin_manager.start
    end

    def async_halted?
      @async_halted ? true : false
    end

    def halt_async
      Pubnub.logger.debug(:pubnub){'Pubnub::Client#halt_async | Stopping async events execution'}
      @async_halted = true
    end

    def start_async
      Pubnub.logger.debug(:pubnub){'Pubnub::Client#start_async | Restoring async events execution'}
      @async_halted = false
    end

    private

    def leave_all

      leave(
          :channel => @env[:subscriptions].get_channels.map{|c| c.to_s}.join(','),
          :http_sync => true,
          :skip_remove => true
      )

      @env[:subscriptions].set_timetoken(0)

    end

    def start_event_machine(options = nil)
      Pubnub.logger.debug(:pubnub){'Pubnub::Client#start_event_machine | starting EM in new thread'}
      if defined?(Thin)
        Pubnub.logger.debug(:pubnub){'Pubnub::Client#start_event_machine | We\'re running on thin'}
      else
        Pubnub.logger.debug(:pubnub){'Pubnub::Client#start_event_machine | We aren\'t running on thin'}
      end
      if EM.reactor_running?
        Pubnub.logger.debug(:pubnub){'Pubnub::Client#start_event_machine | EM already running'}
      else
        Thread.new { EM.run {} }
        Thread.pass until EM.reactor_running?
        Pubnub.logger.debug(:pubnub){'Pubnub::Client#start_event_machine | EM started in new thread'}
      end
    end

    def setup_app(options)
      Pubnub.logger = options[:logger] || Logger.new('pubnub.log')
      @env = symbolize_options_keys(options)
      @env = set_default_values(@env)
      @env.delete_if { |_,v| v.blank? } # nillify if blank
      @async_events = Array.new
      Pubnub.logger.debug(:pubnub){"\n\nCreated new Pubnub::Client #{VERSION} instance"}
    end

    def create_connections(_options)
      @subscribe_event_connection = nil
      @single_event_connection    = nil
    end

    def set_default_values(env)
      defaults = {
          :error_callback                          => DEFAULT_ERROR_CALLBACK,
          :connect_callback                        => DEFAULT_CONNECT_CALLBACK,
          :ssl                                     => DEFAULT_SSL,
          :timetoken                               => DEFAULT_TIMETOKEN,
          :uuid                                    => UUID.new.generate,
          :port                                    => DEFAULT_CONNECTION_PORT,
          :subscribe_timeout                       => DEFAULT_SUBSCRIBE_TIMEOUT,
          :timeout                                 => DEFAULT_NON_SUBSCRIBE_TIMEOUT,
          :max_retries                             => MAX_RETRIES,
          :non_subscribe_timeout                   => DEFAULT_NON_SUBSCRIBE_TIMEOUT,
          :reconnect_max_attempts                  => DEFAULT_RECONNECT_ATTEMPTS,
          :reconnect_retry_interval                => DEFAULT_RECONNECT_INTERVAL,
          :reconnect_response_timeout              => DEFAULT_RECONNECT_RESPONSE_TIMEOUT,
          :origin_heartbeat_interval               => DEFAULT_ORIGIN_HEARTBEAT_INTERVAL,
          :origin_heartbeat_interval_after_failure => DEFAULT_ORIG_INTERVAL_AFTER_F,
          :origin_heartbeat_max_retries            => DEFAULT_ORIG_HEARTBEAT_MAX_RETRIES,
          :ttl                                     => DEFAULT_TTL,
          :secret_key                              => 0,
          :origins_pool                            => DEFAULT_ORIGINS_POOL
      }

      # Let's fill missing keys with default values
      Pubnub.logger.debug(:pubnub){'Setting default values'}
      defaults.each do |key,default_value|
        env[key] = default_value if @env[key].nil?
      end

      env
    end

    def symbolize_options_keys(options)
      Pubnub.logger.debug(:pubnub){'Symbolizing options keys'}
      symbolized_options = {}
      options.each_key { |k| symbolized_options.merge!({ k.to_sym => options[k] }) }
      symbolized_options
    end

    def classify_method(method)
      method.split('_').map{ |w| w.capitalize }.join
    end

    def validate!(parameters)
      raise InitializationError.new(:object => self, :message => ':origins_pool parameter is not valid. Should be array of Strings')         unless parameters[:origins_pool].is_a?(Array) || parameters[:origins_pool].is_a?(NilClass)
      raise InitializationError.new(:object => self, :message => 'Missing required :subscribe_key parameter')                                unless parameters[:subscribe_key]
      raise InitializationError.new(:object => self, :message => 'Subscribe key parameter is not valid. Should be type of String or Symbol') unless [String, Symbol].include?(parameters[:subscribe_key].class)
      raise InitializationError.new(:object => self, :message => 'Publish key parameter is not valid. Should be type of String or Symbol')   unless [String, Symbol].include?(parameters[:publish_key].class) || parameters[:publish_key].blank?
    end

  end
end
