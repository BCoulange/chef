#
# Copyright:: Copyright 2018-2019, Chef Software Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "chef/event_dispatch/base"

class Chef
  class ActionCollection < EventDispatch::Base
    include Enumerable

    class ActionRecord

      # The "new_resource" or declared state that we (ab)use for the after-state since
      # we have no explicit after_resource.  XXX: this object may be mutated by the
      # user and the state may change and result in buggy output.
      #
      attr_accessor :new_resource

      # The loaded current_resource (before-state).  This can be nil in the case of
      # non-why-run-safe resources in why-run mode, or in the case where
      # load_current_resource threw an exception (which is bad practice, but happens).
      #
      attr_accessor :current_resource

      # The action that was run (or scheduled to run in the case of "unprocessed" resources).
      #
      attr_accessor :action

      # The exception that was thrown
      #
      attr_accessor :exception

      # The elapsed time in seconds with machine precision
      #
      attr_accessor :elapsed_time

      # The conditional that caused the resource to be skipped
      #
      attr_accessor :conditional

      # The status of the resource:
      #   updated:     ran and converged
      #   up_to_date:  skipped due to idempotency
      #   skipped:     skipped due to a conditional
      #   failed:      failed with an exception
      #   unprocessed: resources that were not touched by a run that failed
      #
      attr_accessor :status

      # The "nesting" level.  Outer resources in recipe context are 0 here, while for every
      # sub-resource_collection inside of a custom resource this number is incremented by 1.
      #
      attr_accessor :nesting_level

      def initialize(new_resource, action, nesting_level)
        @new_resource = new_resource
        @action = action
        @nesting_level = nesting_level
      end

      def success?
        !exception
      end
    end

    attr_reader :action_records
    attr_reader :total_res_count
    attr_reader :pending_updates
    attr_reader :pending_update
    attr_reader :status
    attr_reader :run_status
    attr_reader :run_context
    attr_reader :consumers
    attr_reader :events

    def initialize(events)
      @action_records = []
      @total_res_count    = 0
      @pending_updates    = []
      @consumers          = []
      @events             = events
    end

    def each(&block)
      action_records.each(&block)
    end

    # allows getting at the action_records collection filtered by nesting level and status
    #
    def filtered_collection(max_nesting: nil, up_to_date: true, skipped: true, updated: true, failed: true, unprocessed: true)
      action_records.select do |rec|
        ( max_nesting.nil? || rec.nesting_level <= max_nesting ) &&
          ( rec.status == :up_to_date && up_to_date ||
            rec.status == :skipped && skipped ||
            rec.status == :updated && updated ||
            rec.status == :failed && failed ||
            rec.status == :unprocessed && unprocessed )
      end
    end

    def run_started(run_status)
      @run_status = run_status
    end

    def cookbook_compilation_start(run_context)
      run_context.action_collection = self
      # fire the action_colleciton_registration hook after cookbook_compilation_start -- last chance for consumers to register
      run_context.events.enqueue(:action_collection_registration, self)
      @run_context = run_context
    end

    # Consumers must call register -- either directly or through the action_collection_registration hook.  If
    # nobody has registered any interest, then no action tracking will be done.
    #
    def register(object)
      consumers << object
    end

    def converge_complete
      return if consumers.empty?
      detect_unprocessed_resources
    end

    def converge_failed(exception)
      return if consumers.empty?
      detect_unprocessed_resources
    end

    def resource_action_start(new_resource, action, notification_type = nil, notifier = nil)
      return if consumers.empty?
      pending_updates << ActionRecord.new(new_resource, action, pending_updates.length)
    end

    def resource_current_state_loaded(new_resource, action, current_resource)
      return if consumers.empty?
      current_record.current_resource = current_resource
    end

    def resource_up_to_date(new_resource, action)
      return if consumers.empty?
      current_record.status = :up_to_date
      @total_res_count += 1
    end

    def resource_skipped(resource, action, conditional)
      return if consumers.empty?
      current_record.status = :skipped
      current_record.conditional = conditional
      @total_res_count += 1
    end

    def resource_updated(new_resource, action)
      return if consumers.empty?
      current_record.status = :updated
      @total_res_count += 1
    end

    def resource_failed(new_resource, action, exception)
      return if consumers.empty?
      current_record.status = :failed
      current_record.exception = exception

      @total_res_count += 1
    end

    def resource_completed(new_resource)
      return if consumers.empty?
      current_record.elapsed_time = new_resource.elapsed_time

      # Verify if the resource has sensitive data and create a new blank resource with only
      # the name so we can report it back without sensitive data
      # XXX?: what about sensitive data in the current_resource?
      # FIXME: this needs to be display-logic
      if current_record.new_resource.sensitive
        klass = current_record.new_resource.class
        resource_name = current_record.new_resource.name
        current_record.new_resource = klass.new(resource_name)
      end

      action_records << pending_updates.pop
    end

    private

    # This is the current record we are working on at the top of the "pending_updates" stack.
    #
    def current_record
      pending_updates[-1]
    end

    # If the chef-client run fails in the middle, we are left with a half-completed resource_collection, this
    # method is responsible for adding all of the resources which have not yet been touched.  They are marked
    # as being "unprocessed".
    #
    def detect_unprocessed_resources
      run_context.resource_collection.all_resources.select { |resource| resource.executed_by_runner == false }.each do |resource|
        Array(resource.action).each do |action|
          record = ActionRecord.new(resource, action, 0)
          record.status = :unprocessed
          action_records << record
        end
      end
    end
  end
end
