module Straight

  # Employs many adapters and runs requests simultaneously.
  # How many adapters are employed is determined by var passed to #initializer (default 2).
  # If all adapters fail it raises an exception.
  class BlockchainAdaptersDispatcher

    class AdaptersTimeoutError < TimeoutError; end
    class AdaptersError < StraightError; end

    TIMEOUT = 60
    attr_reader :adapters, :result, :defer_result, :tasks_parallel_limit

    def initialize(adapters, tasks_parallel_limit: 2, &block)
      @defer_result         = Concurrent::IVar.new
      @tasks_parallel_limit = tasks_parallel_limit
      @adapters             = adapters
      @result               = run_requests(block) if block_given?
    end

    def run_requests(block)
      execute_in_parallel(block, @adapters.dup)
      Timeout.timeout(TIMEOUT, AdaptersTimeoutError) do
        @defer_result.wait
        raise @defer_result.reason if @defer_result.rejected?
        @defer_result.value
      end
    end
    
  private

    def execute_in_parallel(block, adapters)
      adapters_to_run  = adapters.shift(@tasks_parallel_limit)
      attempts_counter = Concurrent::MVar.new(adapters_to_run.size)
      pool             = Concurrent::ThreadPoolExecutor.new
      adapters_to_run.each do |adapter|
        p = Concurrent::Promise.new(executor: pool) { block.call(adapter) }
        p.on_success do |result|
          @defer_result.set(result)
          pool.kill
        end
        p.rescue do |reason|
          attempts_counter.modify { |v| v-1 }
          @defer_result.fail(AdaptersError) if attempts_counter.value.zero? && adapters.empty?
          execute_in_parallel(block, adapters) if attempts_counter.value.zero?
        end
        p.execute
      end
    end
  end
end